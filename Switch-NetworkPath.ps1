<#
.SYNOPSIS
维持"永远至少有一个可用网络出口"：拨号（PPPoE）为主用，Wi-Fi 为保底，主备自动切换。

.DESCRIPTION
核心：**找出口的整个过程你都在 Wi-Fi 上（无感），只有通过了三轮确认的出口才被提为主用。**

机制由三部分组成，全部经过实机验证（见 .mimocode/plans/1789133737010-windows-network-failover.md）：

  1. 【一次性安装，需提权】把拨号条目在电话簿里的 IpPrioritizeRemote 从 1 改成 0。
     语义是"在远程网络上使用默认网关"关掉 —— 拨号仍然正常连接（拿到 IP、链路可用），
     但**不安装默认路由**。RAS 只在连接时读这个值，所以改完要重连一次才生效。
     由此得到"停放态"：拨号连着，流量走 Wi-Fi。

  2. 【运行时，需提权】两个方向都不重连、拨号 IP 不变：
       promote = New-NetRoute 加一条指向拨号的默认路由（RouteMetric 取到让拨号有效跃点胜出）
       demote  = Remove-NetRoute 删掉那条

  3. 【运行时，需提权】探测停放中的拨号出口：拨号没有默认路由时探针会跟着走 Wi-Fi，
     所以探测前给 canary 的 IPv4 装 /32 主机路由指向拨号接口，探完删掉。

判定只用**行为真相**：curl 读 socket 实际用的源地址（%{local_ip}）。
不要用 Find-NetRoute —— 实测它对跃点变化不敏感，会给出假结论。

探测沿用 Test-CampusExit.ps1，脚本本身零修改。canary 列表从它里面正则读出，保证两边一致。

因为要改 pbk、加删路由，本脚本需要管理员权限：非管理员启动时会自提权（弹一次 UAC）。
开机自启请用 Set-AutoStart.bat 注册"最高权限计划任务"，否则每次登录都会弹 UAC。
#>

[CmdletBinding()]
param(
    [string]$DialName,
    [string]$WifiName,
    [ValidateRange(1, 60)] [int]$TimeoutSeconds = 4,
    [ValidateRange(1, 10)] [int]$ProbeCount = 2,
    [ValidateRange(0, 300)] [int]$SettleSeconds = 3,
    [ValidateRange(0, 300)] [int]$ConfirmIntervalSeconds = 12,
    [ValidateRange(0, 600)] [int]$ThirdIntervalSeconds = 30,
    [ValidateRange(1, 3600)] [int]$HealthIntervalSeconds = 3,
    [ValidateRange(0, 10)] [int]$HealthPassThreshold = 0,
    [ValidateRange(1, 60)] [int]$HealthTimeoutSeconds = 2,
    [ValidateRange(1, 100)] [int]$FailThreshold = 1,
    [ValidateRange(1, 600)] [int]$PauseSeconds = 2,
    [ValidateRange(1, 3600)] [int]$MaxDialBackoffSeconds = 60,
    [string]$LogPath,
    [switch]$KeepParkedOnExit,
    [switch]$RestoreDialPriority,
    [switch]$Status,
    [switch]$StatusJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogMaxBytes = 1MB
$script:Pbk = 'C:\ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk'
$script:LogFile = $null
$script:WifiIfIndex = $null
$script:CanaryUris = @()
$script:PbkBackup = $null
$script:LastProbeSummary = ''
$script:LastProbeMode = ''
$script:LastProbePassed = -1
$script:LastProbeTotal = -1

# 给 GUI / 外部脚本消费的状态（见 Get-StatusObject / Write-StatusFile）。
$script:StatusFile = $null          # logs\status.json
$script:StopFile = $null            # logs\stop.req —— 存在就优雅退出
$script:RuntimeState = 'starting'   # starting/dialing/verifying/parked/primary/stopping
$script:HealthySeconds = 0
$script:LastCheckResult = ''
# 给 GUI 看的计数器：本会话一共拨了多少次（**没成功就一直往上加**），以及当前连续失败了几次。
# $dialFailCount 在循环里会被重置，这里先初始化一次，好让免提权的 -StatusJson 也能读到。
$script:DialAttempts = 0
$dialFailCount = 0
# Wi-Fi 存活探测要 ping（约 1 秒），而状态文件每 3 秒就要写一次，所以缓存起来、
# 最多 15 秒真探一次；真正做决策的路径（停放前、降级前）仍然直接调 Test-WifiAlive 拿实时值。
$script:WifiAliveCache = $null
$script:WifiAliveCheckedAt = [datetime]::MinValue

# 在脚本作用域就把这两样取好，供 Restart-Elevated 使用（原因见该函数内的注释）。
$script:ManagerPath = $PSCommandPath
$script:SubmitArgs = $PSBoundParameters

if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'logs\network-path.log' }

$script:PendingStatusLen = 0

function Clear-HealthLine {
    # 收尾控制台里那行原地刷新的健康状态，避免和正式日志行糊在一起。
    if ($script:PendingStatusLen -gt 0) {
        Write-Host ("`r" + (' ' * $script:PendingStatusLen) + "`r") -NoNewline
        $script:PendingStatusLen = 0
    }
}

function Write-HealthLine {
    # 只在控制台原地刷新一行，**不写日志文件**。
    param([string]$Text)
    $pad = ''
    if ($Text.Length -lt $script:PendingStatusLen) { $pad = ' ' * ($script:PendingStatusLen - $Text.Length) }
    Write-Host ("`r{0}{1}" -f $Text, $pad) -NoNewline -ForegroundColor DarkGray
    $script:PendingStatusLen = $Text.Length
}

function Format-Duration {
    param([TimeSpan]$Span)
    # 注意 [int] 是四舍五入不是截断（[int]23.9997 = 24），必须用 Floor，
    # 否则 23小时59分59秒 会显示成 "24小时59分"。
    if ($Span.TotalHours -ge 1) { return ('{0}小时{1:D2}分' -f [Math]::Floor($Span.TotalHours), $Span.Minutes) }
    if ($Span.TotalMinutes -ge 1) { return ('{0}分{1:D2}秒' -f [Math]::Floor($Span.TotalMinutes), $Span.Seconds) }
    return ('{0}秒' -f [Math]::Floor($Span.TotalSeconds))
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')] [string]$Level = 'INFO')

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    if ($script:LogFile) {
        $item = Get-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt $LogMaxBytes) {
            Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.1') -Force
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }

    # 正式日志行之前先把原地刷新的健康行擦掉。
    Clear-HealthLine

    $color = switch ($Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------- 权限

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    # 改电话簿、加删默认路由、加 /32 引导都需要管理员权限。
    #
    # 注意：脚本路径和脚本入参必须在【脚本作用域】先取好（见文件上方 $script:ManagerPath /
    # $script:SubmitArgs）。函数内部的 $MyInvocation 指的是函数自己被调用这件事，
    # $MyInvocation.MyCommand 是那个函数而不是脚本文件，取 .Path 在 StrictMode 下会直接抛
    # "在此对象上找不到属性 Path"；同理 $PSBoundParameters 在函数里也是空集的。
    if (-not $script:ManagerPath) {
        Write-Host '拿不到脚本自身路径，无法自动提权。请用管理员身份手动运行本脚本。' -ForegroundColor Red
        return
    }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ManagerPath)
    foreach ($key in $script:SubmitArgs.Keys) {
        if ($key -eq 'Status') { continue }
        $value = $script:SubmitArgs[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $arguments += "-$key" }
        }
        else {
            $arguments += @("-$key", "$value")
        }
    }
    Write-Host '需要管理员权限（改拨号条目、加删路由），正在请求提权...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
}

# ---------------------------------------------------------------- 电话簿

function Get-PbkText {
    # 该文件是 UTF-8 无 BOM、纯 CRLF。已验证：UTF-8 解码再编码逐字节一致。
    return [System.Text.UTF8Encoding]::new($false).GetString([System.IO.File]::ReadAllBytes($script:Pbk))
}

function Set-PbkValue {
    param([string]$Text, [string]$Key, [string]$Value)
    # 注意用 [^\r\n]* 而不是 .* —— 后者会把 \r 一起吃掉，改出来会变成裸 LF。
    return ($Text -replace "(?m)^$Key=[^\r\n]*", "$Key=$Value")
}

function Get-PbkValue {
    param([string]$Text, [string]$Key)
    $m = [regex]::Match($Text, "(?m)^$Key=(.*)$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

function Assert-PbkSane {
    param([string]$Text, [string]$ExpectedKey, [string]$ExpectedValue)
    # 写盘后必须先自检：一旦把 pbk 写坏，RAS 会报 623「找不到电话簿项目」。
    $sectionOk = $Text -match '(?m)^\[' + [regex]::Escape($DialName) + '\]\s*$'
    $bareLf = ([regex]::Matches($Text, "(?<!`r)`n")).Count
    $keyOk = $true
    if ($ExpectedKey) {
        $keyOk = ((Get-PbkValue -Text $Text -Key $ExpectedKey) -eq $ExpectedValue)
    }
    return [pscustomobject]@{
        Section = $sectionOk
        Key     = $keyOk
        BareLf  = $bareLf
        Ok      = ($sectionOk -and $keyOk -and $bareLf -eq 0)
    }
}

function Set-ParkSetting {
    param([ValidateSet('0', '1')] [string]$Value)

    $text = Get-PbkText
    $current = Get-PbkValue -Text $text -Key 'IpPrioritizeRemote'
    if ($current -eq $Value) { return $true }

    if (-not (Test-Path -LiteralPath $script:PbkBackup)) {
        [System.IO.File]::WriteAllBytes($script:PbkBackup, [System.IO.File]::ReadAllBytes($script:Pbk))
        Write-Log ("电话簿已备份到 {0}" -f $script:PbkBackup)
    }

    $new = Set-PbkValue -Text $text -Key 'IpPrioritizeRemote' -Value $Value
    [System.IO.File]::WriteAllBytes($script:Pbk, [System.Text.UTF8Encoding]::new($false).GetBytes($new))

    $check = Assert-PbkSane -Text (Get-PbkText) -ExpectedKey 'IpPrioritizeRemote' -ExpectedValue $Value
    Write-Log ("写入电话簿 IpPrioritizeRemote={0}；自检 段落头={1} 键={2} 裸LF={3}" -f $Value, $check.Section, $check.Key, $check.BareLf)
    if (-not $check.Ok) {
        [System.IO.File]::WriteAllBytes($script:Pbk, [System.IO.File]::ReadAllBytes($script:PbkBackup))
        Write-Log '电话簿自检不通过，已回滚。' 'ERROR'
        return $false
    }
    return $true
}

# ---------------------------------------------------------------- 接口

function Get-DialupName {
    $names = @()
    foreach ($p in @((Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'), (Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'))) {
        if (Test-Path -LiteralPath $p) {
            $names += @(Select-String -LiteralPath $p -Pattern '^\s*\[(.+?)\]\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        }
    }
    return @($names | Select-Object -Unique)
}

function Resolve-DialName {
    if (-not [string]::IsNullOrWhiteSpace($DialName)) { return $DialName }

    $names = @(Get-DialupName)
    if ($names.Count -eq 1) { return $names[0] }
    if ($names.Count -gt 1) {
        $active = & rasdial.exe 2>$null | Out-String
        foreach ($n in $names) {
            if ($active -like "*$n*") { return $n }
        }
        throw "发现多个拨号连接（$($names -join ', ')），请用 -DialName 指定一个。"
    }
    return '宽带连接'
}

function Get-WifiAdapter {
    if (-not [string]::IsNullOrWhiteSpace($WifiName)) {
        return Get-NetAdapter -Name $WifiName -ErrorAction SilentlyContinue
    }
    return Get-NetAdapter -Physical |
        Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' -or $_.PhysicalMediaType -eq 'Wireless LAN' } |
        Select-Object -First 1
}

function Get-IPv4Address {
    param([int]$InterfaceIndex)
    $addr = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($addr) { return $addr.IPAddress }
    return $null
}

function Get-DialInterface {
    return Get-NetIPInterface -AddressFamily IPv4 -InterfaceAlias $DialName -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Test-DialConnected {
    return $null -ne (Get-DialInterface)
}

function Get-WifiInterface {
    if (-not $script:WifiIfIndex) { return $null }
    return Get-NetIPInterface -InterfaceIndex $script:WifiIfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-DefaultRoutes {
    return Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
}

function Get-BestDefaultRoute {
    # 纯路由表计算：有效跃点 = RouteMetric + InterfaceMetric，取最小。
    # 只用于"预选"，最终结论必须用行为验证（curl 源地址）。
    return Get-DefaultRoutes | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
}

function Get-DialDefaultRoute {
    $dialIf = Get-DialInterface
    if (-not $dialIf) { return $null }
    return Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIf.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-CurrentPath {
    $best = Get-BestDefaultRoute
    if (-not $best) { return 'unknown' }
    if ($best.InterfaceAlias -eq $DialName) { return 'pppoe' }
    if ($script:WifiIfIndex -and $best.InterfaceIndex -eq $script:WifiIfIndex) { return 'wifi' }
    return "other:$($best.InterfaceAlias)"
}

function Test-WifiAlive {
    $adapter = Get-WifiAdapter
    if (-not $adapter -or $adapter.Status -ne 'Up') { return $false }

    $route = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $route -or $route.NextHop -eq '0.0.0.0') { return $false }

    # 给两次机会再判死：这是"敢不敢把拨号停放"的硬闸，而单包 ping 太脆 ——
    # 丢一个包就把 Wi-Fi 判成不可用，用户看到的就是"明明连着热点却开不了游戏模式"。
    # 真断的网关两次都过不了，所以放宽到两次不会让这个闸失去意义。
    foreach ($attempt in 1..2) {
        & ping.exe -n 1 -w 1000 $route.NextHop > $null 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}

function Connect-Dialup {
    $script:DialAttempts++
    $output = & rasdial.exe $DialName 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Log ("拨号失败：{0}" -f ($output.Trim() -replace "`r?`n", ' / ')) 'WARN'
    return $false
}

function Disconnect-Dialup {
    & rasdial.exe $DialName /disconnect 2>&1 | Out-Null
    foreach ($i in 1..20) {
        if (-not (Test-DialConnected)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    Write-Log '断开拨号后接口仍然存在，可能没有真正断开。' 'WARN'
    return $false
}

function Restart-Dialup {
    [void](Disconnect-Dialup)
    Start-Sleep -Seconds 3
    if (-not (Connect-Dialup)) { return $false }
    foreach ($i in 1..15) {
        if (Test-DialConnected) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

# ---------------------------------------------------------------- 切换

function Enter-Parked {
    # 停放 = 拨号没有默认路由。装上 IpPrioritizeRemote=0 之后，拨上去天然就是这个状态；
    # 这里只是兜底把它删掉（比如上一次运行被硬杀留下了残留）。
    $dialIf = Get-DialInterface
    if (-not $dialIf) { return $true }

    # 删掉这条默认路由**本身就是切换动作** —— 流量立刻就回到 Wi-Fi，不用等下面那段确认。
    if (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIf.ifIndex -ErrorAction SilentlyContinue) {
        Remove-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIf.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    }

    # 下面只是确认，不是切换本身，所以间隔压短（250ms × 8 ≈ 最多 2 秒）。
    foreach ($i in 1..8) {
        if (-not (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIf.ifIndex -ErrorAction SilentlyContinue)) {
            $path = Get-CurrentPath
            if ($path -eq 'wifi' -or $path -eq 'unknown') { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Log '无法把拨号停放（默认路由删不掉或承载没回到 Wi-Fi），为安全起见不晋升。' 'ERROR'
    return $false
}

function Add-DialDefaultRoute {
    $dialIf = Get-DialInterface
    if (-not $dialIf) { return $false }

    $wifiIf = Get-WifiInterface
    $wifiMetric = 4255
    if ($wifiIf) { $wifiMetric = $wifiIf.InterfaceMetric }

    # 让拨号的有效跃点比 Wi-Fi 小 1 以上即可胜出。
    $routeMetric = [Math]::Max(0, $wifiMetric - $dialIf.InterfaceMetric - 1)
    Write-Log ("晋升：给拨号加默认路由 RouteMetric={0}（拨号接口跃点={1} → 有效 {2}；Wi-Fi={3} → {4}）" -f $routeMetric, $dialIf.InterfaceMetric, ($routeMetric + $dialIf.InterfaceMetric), $wifiMetric, (0 + $wifiMetric))
    try {
        New-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIf.ifIndex -NextHop '0.0.0.0' -RouteMetric $routeMetric -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Log ("加默认路由失败：{0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Enter-Primary {
    # 接口索引只取一次：中途拨号掉了的话 (Get-DialInterface) 会变成 $null，
    # 直接取 .ifIndex 在 StrictMode 下会抛错。
    $dialIf = Get-DialInterface
    if (-not $dialIf) { return $false }
    $dialIndex = $dialIf.ifIndex

    if (-not (Add-DialDefaultRoute)) { return $false }

    foreach ($i in 1..4) {
        if ((Get-CurrentPath) -eq 'pppoe') { break }
        Start-Sleep -Milliseconds 800
    }
    if ((Get-CurrentPath) -ne 'pppoe') {
        Write-Log '加了默认路由但承载没变成拨号，放弃晋升。' 'ERROR'
        Remove-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIndex -Confirm:$false -ErrorAction SilentlyContinue
        return $false
    }

    # 行为断言：实际出口源地址必须是拨号地址。
    $dialIp = Get-IPv4Address -InterfaceIndex $dialIndex
    $src = Test-EgressSource -Uri $script:CanaryUris[0]
    if ($src -eq $dialIp) {
        Write-Log ("晋升确认：实际出口源地址 {0} = 拨号地址 ✓" -f $src) 'OK'
        return $true
    }
    Write-Log ("晋升确认失败：实际出口源地址是 '{0}'，期望 {1}。回退停放。" -f $src, $dialIp) 'ERROR'
    Remove-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIndex -Confirm:$false -ErrorAction SilentlyContinue
    return $false
}

function Test-EgressSource {
    # 行为真相：socket 实际用的源地址。拿不到就返回空串。
    param([string]$Uri)
    $raw = & curl.exe -s -o NUL -4 --max-time $TimeoutSeconds --write-out '%{http_code}|%{local_ip}' $Uri 2>&1 | Out-String
    $parts = $raw.Trim() -split '\|'
    if ($parts.Count -ge 2) { return $parts[1] }
    return ''
}

# ---------------------------------------------------------------- /32 引导

function Get-CanaryUris {
    $probe = Join-Path $PSScriptRoot 'Test-CampusExit.ps1'
    $text = Get-Content -LiteralPath $probe -Raw -Encoding UTF8
    $found = @([regex]::Matches($text, 'https?://[^/\s''"]+') | ForEach-Object { $_.Value } | Select-Object -Unique)
    $found = @($found | Where-Object { $text -match [regex]::Escape("'" + $_ + "/'") })
    if ($found.Count -eq 0) { throw '没能从 Test-CampusExit.ps1 里读出 canary 列表。' }
    return $found
}

function Resolve-CanaryIpv4 {
    $addresses = @()
    foreach ($uri in $script:CanaryUris) {
        try {
            $addresses += @([System.Net.Dns]::GetHostAddresses(([Uri]$uri).Host) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.IPAddressToString })
        }
        catch {
            Write-Log ("canary 域名解析失败：{0}" -f $_.Exception.Message) 'WARN'
        }
    }
    return @($addresses | Select-Object -Unique)
}

function Add-SteerRoute {
    param([string]$Address, [int]$InterfaceIndex)
    $common = @{ DestinationPrefix = "$Address/32"; InterfaceIndex = $InterfaceIndex; PolicyStore = 'ActiveStore'; ErrorAction = 'Stop' }
    try {
        New-NetRoute @common -NextHop '0.0.0.0' | Out-Null
        return $true
    }
    catch {
        try {
            New-NetRoute @common | Out-Null
            return $true
        }
        catch {
            Write-Log ("加 /32 引导失败 {0}：{1}" -f $Address, $_.Exception.Message) 'ERROR'
            return $false
        }
    }
}

function Remove-SteerRoute {
    param([string]$Address, [int]$InterfaceIndex)
    Remove-NetRoute -DestinationPrefix "$Address/32" -InterfaceIndex $InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-RatifiedProbeResult {
    # 探针脚本零修改：只调用它、读它的输出。
    return Invoke-ProbeRound -Count $ProbeCount -Timeout $TimeoutSeconds
}

function Invoke-ProbeRound {
    param([int]$Count, [int]$Timeout, [switch]$StopOnFailure)

    $probe = Join-Path $PSScriptRoot 'Test-CampusExit.ps1'
    $probeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probe, '-TimeoutSeconds', $Timeout, '-Count', $Count)
    if ($StopOnFailure) { $probeArgs += '-StopOnFailure' }
    $output = & powershell.exe @probeArgs 2>&1 | Out-String
    $passed = ($LASTEXITCODE -eq 0)
    $summary = @($output -split "`r?`n" | Where-Object { $_ -match 'probe passed' } | Select-Object -Last 1)
    if ($summary.Count -gt 0) { $summary = $summary[0].Trim() } else { $summary = '（探针没有输出结果行）' }

    # 从探针输出里把"通过几个 / 共几个"抠出来。判定要按计数比阈值，光有退出码不够。
    # 光有退出码不够。抠不出来时 PassedCount 保持 -1，调用方退回退出码语义。
    $passedCount = -1
    $totalCount = -1
    $m = [regex]::Match($summary, 'probe passed (\d+) of (\d+)')
    if ($m.Success) {
        $passedCount = [int]$m.Groups[1].Value
        $totalCount = [int]$m.Groups[2].Value
    }
    return [pscustomobject]@{ Passed = $passed; Summary = $summary; PassedCount = $passedCount; TotalCount = $totalCount }
}

function Test-HealthRound {
    # 健康检查专用：主用态下直连探测（拨号自己握着默认路由，canary 天然走拨号）。
    #
    # 判据（用户定的）：**只要有一个探针挂就立刻切 Wi-Fi** ——
    # 也就是这一轮必须全部通过。HealthPassThreshold 默认 0（表示"全部"），
    # 想放宽就传正整数（例如 3 个探针时传 2 = 容忍一个挂）。
    #
    # ProbeCount 默认 2，两个 canary 主机各占一票、等权。
    # （之前是 3 个探针，而轮转 $uris[(i-1) % 2] 会让 abvolcapi 拿到两个位置、
    #   apiv2 只拿一个，投票权重 2:1 —— 那个重复采样已经删掉了。）
    #
    # 超时用 HealthTimeoutSeconds（默认 2s），比晋升验证的 4s 短：
    # 实测健康出口的单探针 150-460ms，2 秒是 4-13 倍余量。
    $dialIf = Get-DialInterface
    if (-not $dialIf) { Write-Log '拨号未连接，无法探测。' 'WARN'; return $false }

    # 廉价断言：最优默认路由必须在拨号上。否则探针会溜到 Wi-Fi 上，得出假的"健康"。
    $best = Get-BestDefaultRoute
    if (-not $best -or $best.InterfaceAlias -ne $DialName) {
        Write-Log ('健康检查：最优默认路由不在拨号上（{0}），本轮不通过。' -f $(if ($best) { $best.InterfaceAlias } else { '无' })) 'ERROR'
        return $false
    }

    # 判据是"必须全部通过"，所以第一个探针一挂这一轮就已经输了 ——
    # 让探针脚本 StopOnFailure 提前收手，不用再等剩下的超时。
    $r = Invoke-ProbeRound -Count $ProbeCount -Timeout $HealthTimeoutSeconds -StopOnFailure
    $script:LastProbeSummary = $r.Summary
    $script:LastProbeMode = '直连探测'
    $script:LastProbePassed = $r.PassedCount
    $script:LastProbeTotal = $r.TotalCount

    # 抠得出计数就按阈值比（0 = 全部通过），抠不出就退回退出码语义。
    if ($r.PassedCount -ge 0) {
        $threshold = if ($HealthPassThreshold -le 0) { $ProbeCount } else { [Math]::Min($HealthPassThreshold, $ProbeCount) }
        return ($r.PassedCount -ge $threshold)
    }
    return $r.Passed
}

function Test-DialExitPath {
    # 验证"停放中的拨号出口"（快判 / 确认 用）。
    #
    # 此刻拨号没有默认路由，探针会跟着默认路由走 Wi-Fi，所以必须给 canary 的 IPv4 装
    # /32 主机路由指向拨号接口，测的才是拨号出口。
    #
    # 判据用最严格的一档：这一轮 ProbeCount 个探针必须**全部**通过 —— 这是晋升基准，别动。
    # 健康检查不在这个函数里，见 Test-HealthRound（它跑在主用态、不需要引导）。
    param([string]$Label, [switch]$CheckEgress)

    $dialIf = Get-DialInterface
    if (-not $dialIf) { Write-Log '拨号未连接，无法探测。' 'WARN'; return $false }

    $targets = Resolve-CanaryIpv4
    if ($targets.Count -eq 0) { Write-Log 'canary 一个 IPv4 都解析不出来。' 'ERROR'; return $false }

    $installed = @()
    foreach ($ip in $targets) {
        if (Add-SteerRoute -Address $ip -InterfaceIndex $dialIf.ifIndex) { $installed += $ip }
    }
    if ($installed.Count -ne $targets.Count) {
        foreach ($ip in $installed) { Remove-SteerRoute -Address $ip -InterfaceIndex $dialIf.ifIndex }
        Write-Log '引导路由没装全，本轮不通过（不能相信探测结果）。' 'ERROR'
        return $false
    }

    try {
        # 断言：直接读表确认每个 /32 都在拨号接口上。/32 是最具体前缀，必然胜过默认路由。
        foreach ($ip in $installed) {
            $r = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "$ip/32" -InterfaceIndex $dialIf.ifIndex -ErrorAction SilentlyContinue
            if (-not $r) {
                Write-Log ("引导断言失败：{0}/32 不在拨号接口上，本轮不通过。" -f $ip) 'ERROR'
                return $false
            }
        }

        $result = Get-RatifiedProbeResult
        $script:LastProbeSummary = $result.Summary
        $script:LastProbeMode = '/32 引导'
        $script:LastProbePassed = $result.PassedCount
        $script:LastProbeTotal = $result.TotalCount

        if ($result.Passed) { Write-Log ("{0}：通过 —— {1}（/32 引导）" -f $Label, $result.Summary) }
        else { Write-Log ("{0}：未通过 —— {1}（/32 引导）" -f $Label, $result.Summary) 'WARN' }
        if (-not $result.Passed) { return $false }

        if ($CheckEgress) {
            # 行为闸：确认探针确实从拨号出口发出（DNS 解析到没被 /32 覆盖的 IP 也能被抓到）。
            $dialIp = Get-IPv4Address -InterfaceIndex $dialIf.ifIndex
            $src = Test-EgressSource -Uri $script:CanaryUris[0]
            if ($src -eq $dialIp) {
                Write-Log ("出口源地址确认：{0} = 拨号地址 ✓" -f $src) 'OK'
                return $true
            }
            Write-Log ("出口源地址确认失败：拿到 '{0}'，期望 {1}。不晋升。" -f $src, $dialIp) 'ERROR'
            return $false
        }
        return $true
    }
    finally {
        foreach ($ip in $installed) { Remove-SteerRoute -Address $ip -InterfaceIndex $dialIf.ifIndex }
    }
}

function Confirm-ExitPath {
    # 快判先行：坏出口在一轮内就被丢弃，省掉后面两段确认间隔的时间。
    # 两段间隔（默认 12s / 30s）用 Wait-WithStop 等，这样停止请求不会卡在这段睡眠里。
    if (-not (Test-DialExitPath -Label '快判')) { return $false }
    if (-not (Wait-WithStop -Seconds $ConfirmIntervalSeconds)) { return $false }
    if (-not (Test-DialExitPath -Label '确认 1/2')) { return $false }
    if (-not (Wait-WithStop -Seconds $ThirdIntervalSeconds)) { return $false }
    if (-not (Test-DialExitPath -Label '确认 2/2' -CheckEgress)) { return $false }
    return $true
}

function Get-DialBackoffSeconds {
    param([int]$FailCount)
    if ($FailCount -le 1) { return $PauseSeconds }
    return [int][Math]::Min($PauseSeconds * [Math]::Pow(2, $FailCount - 1), $MaxDialBackoffSeconds)
}

# ---------------------------------------------------------------- 状态

function Test-StopRequested {
    # GUI（或用户）可以通过创建 logs\stop.req 让管理器**优雅退出** ——
    # 走 finally，该还原电话簿 / 清残留路由的都会做。直接杀进程则不会执行 finally。
    if (-not $script:StopFile) { return $false }
    return Test-Path -LiteralPath $script:StopFile
}

function Wait-WithStop {
    param([int]$Seconds)
    # 按秒切片地等，期间一出现停止请求就立刻返回 $false，让调用方去走优雅退出。
    foreach ($i in 1..$Seconds) {
        if (Test-StopRequested) { return $false }
        Start-Sleep -Seconds 1
    }
    return $true
}

function Get-WifiAliveCached {
    param([int]$MaxAgeSeconds = 15)
    if ($null -ne $script:WifiAliveCache -and ((Get-Date) - $script:WifiAliveCheckedAt).TotalSeconds -lt $MaxAgeSeconds) {
        return $script:WifiAliveCache
    }
    $script:WifiAliveCache = Test-WifiAlive
    $script:WifiAliveCheckedAt = Get-Date
    return $script:WifiAliveCache
}

function Get-StatusObject {
    # 机器可读状态：-StatusJson 和 logs\status.json 共用这一份，避免两处口径不一致。
    $dialIf = Get-DialInterface
    $adapter = Get-WifiAdapter
    $best = Get-BestDefaultRoute

    $dialIp = $null
    if ($dialIf) { $dialIp = Get-IPv4Address -InterfaceIndex $dialIf.ifIndex }
    $wifiIp = $null
    if ($adapter) { $wifiIp = Get-IPv4Address -InterfaceIndex $adapter.ifIndex }

    [pscustomobject]@{
        time               = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        state              = $script:RuntimeState
        carrier            = (Get-CurrentPath)
        # parkSwitch 与 dialHoldsDefault 必须分开报：电话簿说"停放"、而拨号仍握着默认路由，
        # 正是之前"启动即报错"那个 bug 的形态，GUI 也要能看见这种不一致。
        parkSwitch         = (Get-PbkValue -Text (Get-PbkText) -Key 'IpPrioritizeRemote')
        dialHoldsDefault   = ($null -ne (Get-DialDefaultRoute))
        dialConnected      = ($null -ne $dialIf)
        dialName           = $DialName
        dialIp             = $dialIp
        wifiName           = $(if ($adapter) { $adapter.Name } else { $null })
        wifiStatus         = $(if ($adapter) { [string]$adapter.Status } else { 'missing' })
        wifiIp             = $wifiIp
        wifiAlive          = (Get-WifiAliveCached)
        bestDefaultIfIndex = $(if ($best) { $best.InterfaceIndex } else { $null })
        bestDefaultAlias   = $(if ($best) { $best.InterfaceAlias } else { $null })
        healthySeconds     = $script:HealthySeconds
        dialAttempts       = $script:DialAttempts
        dialFailStreak     = $dialFailCount
        lastCheck          = $script:LastCheckResult
        logPath            = $script:LogFile
    }
}

function Write-StatusFile {
    # 给 GUI 轮询用。每轮健康检查写一次，成本可忽略；GUI 就不必每几秒 spawn 一个 powershell。
    if (-not $script:StatusFile) { return }
    try {
        $json = Get-StatusObject | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($script:StatusFile, $json, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-Log ("写状态文件失败：{0}" -f $_.Exception.Message) 'WARN'
    }
}

function Write-Status {
    $dialIf = Get-DialInterface
    $adapter = Get-WifiAdapter

    Write-Host ''
    Write-Host '--- 电话簿（停放开关）---'
    if (Test-Path -LiteralPath $script:Pbk) {
        $text = Get-PbkText
        Write-Host ("  IpPrioritizeRemote = {0}   （0 = 拨号不抢默认路由 / 停放态；1 = 拨号当默认网关）" -f (Get-PbkValue -Text $text -Key 'IpPrioritizeRemote'))
        Write-Host ("  IpInterfaceMetric  = {0}" -f (Get-PbkValue -Text $text -Key 'IpInterfaceMetric'))
    }
    else { Write-Host '  找不到电话簿文件' }

    Write-Host '--- 拨号 ---'
    if ($dialIf) {
        Write-Host ("  已连接  {0}  ifIndex={1}  IP={2}  接口跃点={3}" -f $DialName, $dialIf.ifIndex, (Get-IPv4Address -InterfaceIndex $dialIf.ifIndex), $dialIf.InterfaceMetric)
    }
    else { Write-Host ("  未连接  {0}" -f $DialName) }

    Write-Host '--- Wi-Fi ---'
    if ($adapter) {
        $wifiIf = Get-WifiInterface
        $metric = if ($wifiIf) { $wifiIf.InterfaceMetric } else { '-' }
        Write-Host ("  {0}  {1}  ifIndex={2}  IP={3}  接口跃点={4}" -f $adapter.Name, $adapter.Status, $adapter.ifIndex, (Get-IPv4Address -InterfaceIndex $adapter.ifIndex), $metric)
        Write-Host ("  保底可用：{0}" -f (Test-WifiAlive))
    }
    else { Write-Host '  没找到无线网卡' }

    Write-Host '--- 默认路由（按有效跃点排序）---'
    foreach ($r in (Get-DefaultRoutes | Sort-Object { $_.RouteMetric + $_.InterfaceMetric })) {
        Write-Host ("  ifIndex={0,-4} {1,-12} nh={2,-14} 有效跃点={3}" -f $r.InterfaceIndex, $r.InterfaceAlias, $r.NextHop, ($r.RouteMetric + $r.InterfaceMetric))
    }
    Write-Host ("--- 当前承载：{0} ---" -f (Get-CurrentPath))
    Write-Host ("--- 权限：{0} ---" -f $(if (Test-Elevated) { '管理员' } else { '普通用户（只读；改配置会失败）' }))
    Write-Host ''
}

# ---------------------------------------------------------------- 启动

$DialName = Resolve-DialName
$wifiAdapter = Get-WifiAdapter
$script:WifiIfIndex = if ($wifiAdapter) { $wifiAdapter.ifIndex } else { $null }
$script:CanaryUris = Get-CanaryUris

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = $LogPath
$script:PbkBackup = Join-Path $logDir 'rasphone.pbk.bak'
$script:StatusFile = Join-Path $logDir 'status.json'
$script:StopFile = Join-Path $logDir 'stop.req'

# -StatusJson：给 GUI / 脚本消费的机器可读状态。免提权可跑，和 -Status 一样只读。
if ($StatusJson) {
    # 一次性查询没有在跑循环，所以 state 报 idle 而不是循环里那个初始值 starting。
    $script:RuntimeState = 'idle'
    Get-StatusObject | ConvertTo-Json -Depth 3
    exit 0
}

if ($Status) {
    Write-Host "拨号连接名：$DialName"
    Write-Status
    exit 0
}

if (-not (Test-Elevated)) {
    Restart-Elevated
    exit 0
}

$mutex = [System.Threading.Mutex]::new($false, 'Local\CampusNetworkPath')
$mutexObtained = $false
try {
    $mutexObtained = $mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    # 上一个实例是被硬杀的（没释放互斥体），OS 会把它标记成"遗弃"并在下次等待时抛异常。
    # 既然是被遗弃的，就说明**没有实例在跑**，这里算正常拿到。
    # 不处理这一条会自我锁死：管理器每次启动都直接死在这一行。
    $mutexObtained = $true
}
if (-not $mutexObtained) {
    Write-Host '已经有一个网络管理器在运行，本次退出。' -ForegroundColor Yellow
    exit 1
}

# 一次性"恢复拨号优先级"：正常退出时 finally 会自动还原，但如果管理器是被硬杀的
# （关窗口 / 结束进程），finally 不会执行，电话簿就会留在停放态（IpPrioritizeRemote=0）
# —— 最直接的后果是拨号再也不抢默认路由，机器一直待在 Wi-Fi 上。
# 这个开关就是那种情况下的恢复入口：把开关写回 1 并重连。
if ($RestoreDialPriority) {
    $curVal = Get-PbkValue -Text (Get-PbkText) -Key 'IpPrioritizeRemote'
    Write-Log ("--RestoreDialPriority：当前 IpPrioritizeRemote={0}，目标 1（拨号当默认网关）" -f $curVal)
    if ($curVal -eq '1') {
        Write-Log '已经是拨号优先，无需改动。' 'OK'
    }
    else {
        if (-not (Set-ParkSetting -Value '1')) {
            Write-Log '写回电话簿失败，未能恢复。' 'ERROR'
            $mutex.ReleaseMutex(); $mutex.Dispose()
            exit 1
        }
        # RAS 只在连接时读这个值，所以要重连一次才生效。
        if (Test-DialConnected) {
            if (Restart-Dialup) { Write-Log '已重连，拨号重新成为默认网关。' 'OK' }
            else { Write-Log '电话簿已还原，但重连失败；下次连上后即生效。' 'WARN' }
        }
        else {
            Write-Log '电话簿已还原；拨号连上后即成为默认网关。' 'OK'
        }
    }
    Write-Status
    $mutex.ReleaseMutex(); $mutex.Dispose()
    exit 0
}

if (-not $wifiAdapter) {
    Write-Log '没找到无线网卡，保底路径不存在；拨号失效时可能没有可用出口。' 'ERROR'
}

$wifiLabel = if ($wifiAdapter) { $wifiAdapter.Name } else { '无' }
Write-Log '==================== 网络管理器启动 ===================='
Write-Log ("拨号：{0}；Wi-Fi：{1}；当前承载：{2}；canary：{3}" -f $DialName, $wifiLabel, (Get-CurrentPath), ($script:CanaryUris -join ' '))
# 把"一轮到底怎么判"算成一句话打进日志，避免语义只存在于代码里。
$healthRule = '只要有一个探针挂就算不健康（须全部通过）'
if ($HealthPassThreshold -gt 0 -and $HealthPassThreshold -lt $ProbeCount) {
    $healthRule = ('通过 >= {0} 个才算健康（容忍 {1} 个挂）' -f $HealthPassThreshold, ($ProbeCount - $HealthPassThreshold))
}
Write-Log ("验证（晋升判据）：快判 + 确认(间隔 {0}s / {1}s，每轮 {2} 个探针须**全部**通过、单探针超时 {3}s，末轮含出口源地址确认)。" -f $ConfirmIntervalSeconds, $ThirdIntervalSeconds, $ProbeCount, $TimeoutSeconds)
Write-Log ("健康检查（已连接后的判据）：每 {0}s 一轮、每轮 {1} 个探针（每轮：{2}）、单探针超时 {3}s；连续失败 {4} 次后降级切 Wi-Fi。" -f $HealthIntervalSeconds, $ProbeCount, $healthRule, $HealthTimeoutSeconds, $FailThreshold)
Write-Log '健康检查路径：主用态直连探测（canary 天然走拨号，不装 /32 引导、不做出口确认）；停放态验证才用 /32 引导。'
Write-Log '注意：本脚本只保证一直都有可用网络，可能会在校园网与热点之间切换，不保证游戏时的稳定性。' 'WARN'

# 硬前提：Wi-Fi（热点）必须是可用的。
# 本脚本靠"把拨号停放到 Wi-Fi 旁边、流量跑在 Wi-Fi 上"来做到无感切换，
# Wi-Fi 没连上时停放等于把流量丢进黑洞 —— 拨号让出了默认路由，而 Wi-Fi 给不出路由，
# 结果是彻底没有网络出口。所以这里直接拒绝启动，而且**不做任何改动**。
if (-not (Test-WifiAlive)) {
    Write-Log 'Wi-Fi（热点）当前不可用，拒绝启动：本脚本的前提是流量跑在 Wi-Fi 上、拨号只做后台候选。' 'ERROR'
    Write-Log '请先连上热点再启动本脚本。现在退出，电话簿与路由都不会被改动。' 'ERROR'
    Write-Host ''
    Write-Host '请先连上热点（Wi-Fi）再运行本脚本。' -ForegroundColor Yellow
    $mutex.ReleaseMutex(); $mutex.Dispose()
    exit 1
}

# 确保进入"停放态"：电话簿开关必须是 0，而且**拨号不能握着默认路由**。
#
# 这里刻意不再用"电话簿开关的值"去推断"会话是不是停放态"，因为这两件事会脱节：
#   1) 拨号会话是 RAS 在**连接时**读 IpPrioritizeRemote 决定的 —— 值改了但没重连，旧会话照样握着默认路由；
#   2) 上一次运行"晋升"时用 New-NetRoute 给拨号加的那条默认路由是**运行时残留**，
#      退出（尤其被硬杀）不会自动消失，也不受电话簿开关控制。
# 判据改成"拨号实际有没有默认路由"这个行为事实。只要它握着，就重连一次：
# 重连会销毁并重建 PPP 接口，接口上 ActiveStore 的残留路由会跟着一起消失 ——
# 于是"陈旧会话"和"残留路由"两个问题一次解决，也不会再出现"每次启动都失败"的死锁。
$needRestart = $false

if ((Get-PbkValue -Text (Get-PbkText) -Key 'IpPrioritizeRemote') -ne '0') {
    Write-Log '安装停放开关：IpPrioritizeRemote -> 0（改完需要重连一次让 RAS 生效）'
    if (-not (Set-ParkSetting -Value '0')) {
        Write-Log '停放开关安装失败，无法保证"验证期间走 Wi-Fi"。为安全起见退出。' 'ERROR'
        $mutex.ReleaseMutex(); $mutex.Dispose()
        exit 1
    }
    $needRestart = $true
}
elseif ($null -ne (Get-DialDefaultRoute)) {
    Write-Log '拨号会话仍握着默认路由（多半是上一次晋升留下的残留路由，或该会话是用旧设置拨上的），重连一次清理。' 'WARN'
    $needRestart = $true
}

if ($needRestart) {
    if (-not (Restart-Dialup)) {
        Write-Log '拨号重连失败，下面会再复查一次停放是否真的生效。' 'WARN'
    }
}

# 复查：拨号必须没有默认路由，否则"验证期间走 Wi-Fi"这个假设不成立，宁可退出也不要带着错假设跑。
if ($null -ne (Get-DialDefaultRoute)) {
    Write-Log '拨号仍握着默认路由，无法确认停放已生效（多半是上面那次重连失败），为安全起见退出。' 'ERROR'
    $mutex.ReleaseMutex(); $mutex.Dispose()
    exit 1
}
$parkDialIf = Get-DialInterface
if ($parkDialIf) {
    Write-Log ('停放开关已生效：拨号已连接 {0}，且不抢默认路由。' -f (Get-IPv4Address -InterfaceIndex $parkDialIf.ifIndex)) 'OK'
}

# 清掉上次遗留的停止请求（否则一启动就会被它立刻停掉），然后把初始状态写给 GUI。
if (Test-Path -LiteralPath $script:StopFile) {
    Write-Log '发现上次遗留的停止请求文件，清掉它。' 'WARN'
    Remove-Item -LiteralPath $script:StopFile -Force -ErrorAction SilentlyContinue
}
$script:RuntimeState = 'parked'
Write-StatusFile

$dialFailCount = 0
$nextDelay = 0
$consecutiveFailures = 0
$badExitCount = 0

try {
    while ($true) {
        # 优雅停止：GUI 会创建 logs\stop.req 来要求退出（直接杀进程不会执行 finally，
        # 电话簿会留在停放态、晋升残留路由也会留下）。
        if (Test-StopRequested) {
            Write-Log '收到停止请求（logs\stop.req），优雅退出。' 'WARN'
            break
        }

        if (-not (Test-DialConnected)) {
            if ($nextDelay -gt 0) {
                Write-Log ("{0} 秒后重新拨号。" -f $nextDelay)
                if (-not (Wait-WithStop -Seconds $nextDelay)) {
                    Write-Log '收到停止请求，优雅退出。' 'WARN'
                    break
                }
                $nextDelay = 0
            }
            $script:RuntimeState = 'dialing'
            Write-StatusFile
            Write-Log '开始拨号。'
            if (-not (Connect-Dialup)) {
                $dialFailCount++
                $nextDelay = Get-DialBackoffSeconds -FailCount $dialFailCount
                Write-Log ("连续第 {0} 次拨号失败，退避 {1} 秒。" -f $dialFailCount, $nextDelay) 'WARN'
                Write-StatusFile
                continue
            }
            $dialFailCount = 0
        }

        if (-not (Enter-Parked)) { $nextDelay = $MaxDialBackoffSeconds; Disconnect-Dialup; continue }

        Write-Log ("等待 {0} 秒让新出口稳定后开始验证（此时承载：{1}）。" -f $SettleSeconds, (Get-CurrentPath))
        Start-Sleep -Seconds $SettleSeconds

        if (-not (Confirm-ExitPath)) {
            Disconnect-Dialup
            $badExitCount++
            Write-Log ("当前出口不可用，换一个出口重拨（连续第 {0} 个坏出口）。你在 Wi-Fi 上，不受影响。" -f $badExitCount) 'WARN'
            $nextDelay = $PauseSeconds
            $consecutiveFailures = 0
            continue
        }

        if (-not (Enter-Primary)) {
            [void](Enter-Parked)
            Disconnect-Dialup
            $nextDelay = $MaxDialBackoffSeconds
            continue
        }

        $script:RuntimeState = 'primary'
        $script:LastCheckResult = '刚晋升'
        $script:HealthySeconds = 0
        Write-StatusFile
        Write-Log ("好了喵 —— 拨号已确认为可用出口并成为主用（当前承载：{0}）。" -f (Get-CurrentPath)) 'OK'
        $dialFailCount = 0
        $nextDelay = 0
        $consecutiveFailures = 0
        $badExitCount = 0

        # 健康计时：健康时只在控制台原地刷一行（不写日志文件），
        # 真的坏了才写正式日志，并把"此前已健康多久"带上。
        $healthySince = Get-Date
        $failedBefore = $false

        while ($true) {
            # 用切片等待，这样 GUI 的停止请求（logs\stop.req）最多 1 秒内就会被响应。
            if (-not (Wait-WithStop -Seconds $HealthIntervalSeconds)) {
                Write-Log '收到停止请求，优雅退出。' 'WARN'
                break
            }

            $script:HealthySeconds = [int](((Get-Date) - $healthySince).TotalSeconds)

            if (-not (Test-DialConnected)) {
                Write-Log '拨号连接已断开。' 'WARN'
                break
            }

            # 一轮健康检查的判定（用户定的策略）：
            #   >= HealthPassThreshold 个探针通过（默认 2/3，多数即算健康）→ 健康，继续
            #   <  阈值                 → 直接降级切 Wi-Fi，不要求"连续失败两次"
            # 检查本身出错（DNS 挂、CIM 报错等）也按不健康处理 ——
            # 判不了健康就退回保底，而且不能因为一次异常把整个进程带走。
            $healthy = $false
            $checkError = $null
            try {
                $healthy = Test-HealthRound
            }
            catch {
                $checkError = $_.Exception.Message
            }

            if ($healthy) {
                $script:LastCheckResult = ('通过 {0}/{1}' -f $script:LastProbePassed, $script:LastProbeTotal)
                Write-StatusFile
                if ($failedBefore) {
                    Write-Log ("健康检查：已恢复 —— {0}（{1}）。本段从 {2} 重新计时。" -f $script:LastProbeSummary, $script:LastProbeMode, (Get-Date -Format 'HH:mm:ss')) 'OK'
                    $failedBefore = $false
                    $healthySince = Get-Date
                    $consecutiveFailures = 0
                    continue
                }
                $consecutiveFailures = 0
                Write-HealthLine ('[{0}] 健康 · 已持续 {1}' -f (Get-Date -Format 'HH:mm:ss'), (Format-Duration ((Get-Date) - $healthySince)))
                continue
            }

            $consecutiveFailures++
            $failedBefore = $true
            $script:LastCheckResult = ('未通过 {0}/{1}' -f $script:LastProbePassed, $script:LastProbeTotal)
            Write-StatusFile
            $healthyFor = Format-Duration ((Get-Date) - $healthySince)
            if ($checkError) {
                Write-Log ("健康检查：出错 —— {0}。按不健康处理，直接切 Wi-Fi。此前已健康 {1}。" -f $checkError, $healthyFor) 'ERROR'
            }
            else {
                # 提前中止时 LastProbeTotal 会小于本轮应有的探针数，日志里说清楚，
                # 免得看到"通过 0/1（阈值 2）"以为哪里不对。
                $aborted = if ($script:LastProbeTotal -ge 0 -and $script:LastProbeTotal -lt $ProbeCount) { '，首个失败即中止' } else { '' }
                Write-Log ("健康检查：未通过 —— 通过 {0}/{1}（本轮 {2} 个探针{3}）（{4}）。此前已健康 {5}。" -f $script:LastProbePassed, $script:LastProbeTotal, $ProbeCount, $aborted, $script:LastProbeMode, $healthyFor) 'WARN'
            }
            if ($consecutiveFailures -lt $FailThreshold) { continue }

            if (Test-WifiAlive) {
                # 降级不需要断开：把拨号那条默认路由删掉，流量立刻回到 Wi-Fi，拨号 IP 都不变。
                # Enter-Parked 里"删路由"就是切换动作本身，所以日志放在它之后，写的才是真实状态。
                if (Enter-Parked) {
                    Write-Log '已降级：流量已回到 Wi-Fi（拨号 IP 不变），现在断开重拨换出口。' 'WARN'
                    Disconnect-Dialup
                    $nextDelay = $PauseSeconds
                }
                else {
                    Write-Log '降级失败（没能切回 Wi-Fi），直接断开重拨。' 'ERROR'
                    Disconnect-Dialup
                    $nextDelay = 0
                }
            }
            else {
                Write-Log 'Wi-Fi 保底不可用！断开后会短暂没有任何网络出口，将立刻重拨。' 'ERROR'
                Disconnect-Dialup
                $nextDelay = 0
            }
            $script:RuntimeState = 'parked'
            Write-StatusFile
            break
        }

        $consecutiveFailures = 0
    }
}
finally {
    Clear-HealthLine
    $script:RuntimeState = 'stopping'
    Write-StatusFile
    # 不留副作用：把停放开关还原，让用户在没有管理器时也能正常用拨号。
    $cur = Get-PbkValue -Text (Get-PbkText) -Key 'IpPrioritizeRemote'
    if ($cur -eq '0') {
        if ($KeepParkedOnExit) {
            # "保留停放"必须是真的没在承载：晋升时用 New-NetRoute 加的那条默认路由是**运行时残留**，
            # 不会自己消失（它只存在于 ActiveStore，跟电话簿开关无关）。留着它＝拨号仍在抢默认路由，
            # 名义上"停放"、实际还在用拨号 —— 而且下次启动时它会喂给停放守卫，造成启动即报错的死锁。
            if ($null -ne (Get-DialDefaultRoute)) {
                Write-Log '按 -KeepParkedOnExit 保留停放开关；先删掉上一次晋升留下的拨号默认路由，让它真正停放。'
                [void](Enter-Parked)
            }
            else {
                Write-Log '按 -KeepParkedOnExit 保留停放开关（IpPrioritizeRemote=0）。'
            }
            # 停放态应该是"拨号连着、但不承载"。要是正好停在"断开换出口"的中间，这里补拨一次。
            if (-not (Test-DialConnected)) {
                Write-Log '退出时拨号是断开的，补拨一次让它保持"连着但不抢默认路由"。'
                [void](Connect-Dialup)
            }
        }
        else {
            Write-Log '还原停放开关：IpPrioritizeRemote -> 1，并重连让 RAS 生效。'
            if (-not (Set-ParkSetting -Value '1')) {
                Write-Log '写回电话簿失败；稍后可以用 -RestoreDialPriority 手动恢复。' 'ERROR'
            }
            elseif (Test-DialConnected) {
                # 重连会重建 PPP 接口，晋升留下的残留路由也会随之消失。
                if (-not (Restart-Dialup)) {
                    Write-Log '重连失败；电话簿已是 1，拨号下次连上时会成为默认网关。' 'WARN'
                }
            }
            else {
                # 退出时拨号可能是断的（正好卡在"断开换出口"的中间），用户看到的就是"退出后没有拨号"。
                # 电话簿已经是 1，这里补拨一次，让"退出即拨号优先"在行为上真的成立。
                Write-Log '退出时拨号是断开的，补拨一次让它成为默认网关。'
                if (-not (Connect-Dialup)) {
                    Write-Log '补拨失败；电话簿已是 1，下次拨上时会自动成为默认网关。' 'WARN'
                }
            }
        }
    }
    # 清掉停止请求文件，否则下次启动会被它立刻停掉。
    if (Test-Path -LiteralPath $script:StopFile) {
        Remove-Item -LiteralPath $script:StopFile -Force -ErrorAction SilentlyContinue
    }
    $script:RuntimeState = 'stopped'
    Write-StatusFile
    Write-Log ("网络管理器退出。当前承载：{0}" -f (Get-CurrentPath))
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
