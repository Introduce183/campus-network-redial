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
    [ValidateRange(1, 10)] [int]$ProbeCount = 3,
    [ValidateRange(0, 300)] [int]$SettleSeconds = 3,
    [ValidateRange(0, 300)] [int]$ConfirmIntervalSeconds = 12,
    [ValidateRange(0, 600)] [int]$ThirdIntervalSeconds = 30,
    [ValidateRange(5, 3600)] [int]$HealthIntervalSeconds = 5,
    [ValidateRange(1, 100)] [int]$FailThreshold = 2,
    [ValidateRange(1, 600)] [int]$PauseSeconds = 2,
    [ValidateRange(1, 3600)] [int]$MaxDialBackoffSeconds = 60,
    [string]$LogPath,
    [switch]$KeepParkedOnExit,
    [switch]$Status
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

    & ping.exe -n 1 -w 1000 $route.NextHop > $null 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Connect-Dialup {
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

    if (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIf.ifIndex -ErrorAction SilentlyContinue) {
        Remove-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIf.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    }

    foreach ($i in 1..4) {
        if (-not (Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $dialIf.ifIndex -ErrorAction SilentlyContinue)) {
            $path = Get-CurrentPath
            if ($path -eq 'wifi' -or $path -eq 'unknown') { return $true }
            Write-Log ("停放后承载仍为 {0}，继续等待。" -f $path) 'WARN'
        }
        Start-Sleep -Milliseconds 800
    }
    Write-Log '无法把拨号停放（默认路由删不掉），为安全起见不晋升。' 'ERROR'
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
    $probe = Join-Path $PSScriptRoot 'Test-CampusExit.ps1'
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -TimeoutSeconds $TimeoutSeconds -Count $ProbeCount 2>&1 | Out-String
    $passed = ($LASTEXITCODE -eq 0)
    $summary = @($output -split "`r?`n" | Where-Object { $_ -match 'probe passed' } | Select-Object -Last 1)
    if ($summary.Count -gt 0) { $summary = $summary[0].Trim() } else { $summary = '（探针没有输出结果行）' }
    return [pscustomobject]@{ Passed = $passed; Summary = $summary }
}

function Test-DialExitPath {
    param([string]$Label, [switch]$CheckEgress, [switch]$Quiet)

    $dialIf = Get-DialInterface
    if (-not $dialIf) { Write-Log '拨号未连接，无法探测。' 'WARN'; return $false }

    # 是否需要用 /32 把 canary 引导到拨号。
    #
    # 主用态（拨号自己握着最优默认路由）时**不需要**引导：canary 天然走拨号。
    # 省掉这一段能砍掉每轮 18 次路由表操作 —— 健康检查设成 5 秒一次就必须省，
    # 否则每分钟要做约 170 次路由增删。这时用一个廉价断言代替：
    # 确认最优默认路由确实是拨号（读一次路由表），拿不准就当本轮不通过。
    #
    # 停放态（Wi-Fi 握着默认路由）时必须引导，否则探针会测到 Wi-Fi 的出口。
    $needSteering = (Get-CurrentPath) -ne 'pppoe'
    $mode = if ($needSteering) { '/32 引导' } else { '直连探测' }

    if (-not $needSteering) {
        # 再确认一次拨号的最优默认路由确实在表里 —— 万一它的默认路由被别人删了，
        # 探针就会溜到 Wi-Fi 上，那样会得出假的"通过"。
        $best = Get-BestDefaultRoute
        if (-not $best -or $best.InterfaceAlias -ne $DialName) {
            Write-Log ("{0}：最优默认路由不在拨号上（{1}），本轮不通过。" -f $Label, $(if ($best) { $best.InterfaceAlias } else { '无' })) 'ERROR'
            return $false
        }
    }

    $installed = @()
    if ($needSteering) {
        $targets = Resolve-CanaryIpv4
        if ($targets.Count -eq 0) { Write-Log 'canary 一个 IPv4 都解析不出来。' 'ERROR'; return $false }

        foreach ($ip in $targets) {
            if (Add-SteerRoute -Address $ip -InterfaceIndex $dialIf.ifIndex) { $installed += $ip }
        }
        if ($installed.Count -ne $targets.Count) {
            foreach ($ip in $installed) { Remove-SteerRoute -Address $ip -InterfaceIndex $dialIf.ifIndex }
            Write-Log '引导路由没装全，本轮不通过（不能相信探测结果）。' 'ERROR'
            return $false
        }
    }

    try {
        if ($needSteering) {
            # 断言：直接读表确认每个 /32 都在拨号接口上。/32 是最具体前缀，必然胜过默认路由。
            foreach ($ip in $installed) {
                $r = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "$ip/32" -InterfaceIndex $dialIf.ifIndex -ErrorAction SilentlyContinue
                if (-not $r) {
                    Write-Log ("引导断言失败：{0}/32 不在拨号接口上，本轮不通过。" -f $ip) 'ERROR'
                    return $false
                }
            }
        }

        $result = Get-RatifiedProbeResult
        # 把结果与模式留在脚本作用域，供 -Quiet 的调用方（健康检查）取用。
        $script:LastProbeSummary = $result.Summary
        $script:LastProbeMode = $mode
        if (-not $Quiet) {
            if ($result.Passed) { Write-Log ("{0}：通过 —— {1}（{2}）" -f $Label, $result.Summary, $mode) }
            else { Write-Log ("{0}：未通过 —— {1}（{2}）" -f $Label, $result.Summary, $mode) 'WARN' }
        }
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
    if (-not (Test-DialExitPath -Label '快判')) { return $false }
    Start-Sleep -Seconds $ConfirmIntervalSeconds
    if (-not (Test-DialExitPath -Label '确认 1/2')) { return $false }
    Start-Sleep -Seconds $ThirdIntervalSeconds
    if (-not (Test-DialExitPath -Label '确认 2/2' -CheckEgress)) { return $false }
    return $true
}

function Get-DialBackoffSeconds {
    param([int]$FailCount)
    if ($FailCount -le 1) { return $PauseSeconds }
    return [int][Math]::Min($PauseSeconds * [Math]::Pow(2, $FailCount - 1), $MaxDialBackoffSeconds)
}

# ---------------------------------------------------------------- 状态

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
if (-not $mutex.WaitOne(0)) {
    Write-Host '已经有一个网络管理器在运行，本次退出。' -ForegroundColor Yellow
    exit 1
}

if (-not $wifiAdapter) {
    Write-Log '没找到无线网卡，保底路径不存在；拨号失效时可能没有可用出口。' 'ERROR'
}

$wifiLabel = if ($wifiAdapter) { $wifiAdapter.Name } else { '无' }
Write-Log '==================== 网络管理器启动 ===================='
Write-Log ("拨号：{0}；Wi-Fi：{1}；当前承载：{2}；canary：{3}" -f $DialName, $wifiLabel, (Get-CurrentPath), ($script:CanaryUris -join ' '))
Write-Log ("验证：快判 + 确认(间隔 {0}s / {1}s，末轮含出口源地址确认)；健康检查每 {2}s，连续失败 {3} 次降级。" -f $ConfirmIntervalSeconds, $ThirdIntervalSeconds, $HealthIntervalSeconds, $FailThreshold)
Write-Log ("健康检查路径：主用态直连探测（省掉 /32 引导与出口确认，避免每 {0}s 做一轮路由增删）；停放态用 /32 引导。" -f $HealthIntervalSeconds)
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

# 一次性安装停放开关：把 IpPrioritizeRemote 改成 0，让拨号不再抢默认路由。
if ((Get-PbkValue -Text (Get-PbkText) -Key 'IpPrioritizeRemote') -ne '0') {
    Write-Log '安装停放开关：IpPrioritizeRemote -> 0（改完需要重连一次让 RAS 生效）'
    if (-not (Set-ParkSetting -Value '0')) {
        Write-Log '停放开关安装失败，无法保证"验证期间走 Wi-Fi"。为安全起见退出。' 'ERROR'
        $mutex.ReleaseMutex(); $mutex.Dispose()
        exit 1
    }
    [void](Restart-Dialup)
}

# 装完必须复查：如果拨号仍然带着默认路由，说明停放开关没生效，
# 那就无法保证"验证期间走 Wi-Fi"，宁可退出也不要带着错误假设跑。
$stillHasDefault = $null -ne (Get-DialDefaultRoute)
if ($stillHasDefault) {
    Write-Log '停放开关已写入但拨号仍抢默认路由（IpPrioritizeRemote 未生效），退出。' 'ERROR'
    $mutex.ReleaseMutex(); $mutex.Dispose()
    exit 1
}
$parkDialIf = Get-DialInterface
if ($parkDialIf) {
    Write-Log ('停放开关已生效：拨号已连接 {0}，且不抢默认路由。' -f (Get-IPv4Address -InterfaceIndex $parkDialIf.ifIndex)) 'OK'
}

$dialFailCount = 0
$nextDelay = 0
$consecutiveFailures = 0
$badExitCount = 0

try {
    while ($true) {
        if (-not (Test-DialConnected)) {
            if ($nextDelay -gt 0) {
                Write-Log ("{0} 秒后重新拨号。" -f $nextDelay)
                Start-Sleep -Seconds $nextDelay
                $nextDelay = 0
            }
            Write-Log '开始拨号。'
            if (-not (Connect-Dialup)) {
                $dialFailCount++
                $nextDelay = Get-DialBackoffSeconds -FailCount $dialFailCount
                Write-Log ("连续第 {0} 次拨号失败，退避 {1} 秒。" -f $dialFailCount, $nextDelay) 'WARN'
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
            Start-Sleep -Seconds $HealthIntervalSeconds

            if (-not (Test-DialConnected)) {
                Write-Log '拨号连接已断开。' 'WARN'
                break
            }

            if (Test-DialExitPath -Label '健康检查' -Quiet) {
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
            Write-Log ("健康检查：未通过 —— {0}（{1}）。此前已健康 {2}。" -f $script:LastProbeSummary, $script:LastProbeMode, (Format-Duration ((Get-Date) - $healthySince))) 'WARN'
            if ($consecutiveFailures -lt $FailThreshold) { continue }

            if (Test-WifiAlive) {
                # 降级不需要断开：把拨号那条默认路由删掉，流量立刻回到 Wi-Fi，拨号 IP 都不变。
                Write-Log 'Wi-Fi 保底正常：降级为停放态（不要重连，流量立刻回 Wi-Fi），再后台换出口。' 'WARN'
                if (Enter-Parked) {
                    Disconnect-Dialup
                    $nextDelay = $PauseSeconds
                }
                else {
                    $nextDelay = 0
                }
            }
            else {
                Write-Log 'Wi-Fi 保底不可用！断开后会短暂没有任何网络出口，将立刻重拨。' 'ERROR'
                Disconnect-Dialup
                $nextDelay = 0
            }
            break
        }

        $consecutiveFailures = 0
    }
}
finally {
    Clear-HealthLine
    # 不留副作用：把停放开关还原，让用户在没有管理器时也能正常用拨号。
    $cur = Get-PbkValue -Text (Get-PbkText) -Key 'IpPrioritizeRemote'
    if ($cur -eq '0') {
        if ($KeepParkedOnExit) {
            Write-Log '按 -KeepParkedOnExit 保留停放开关（IpPrioritizeRemote=0）。'
        }
        else {
            Write-Log '还原停放开关：IpPrioritizeRemote -> 1，并重连让 RAS 生效。'
            [void](Set-ParkSetting -Value '1')
            if (Test-DialConnected) { [void](Restart-Dialup) }
        }
    }
    Write-Log ("网络管理器退出。当前承载：{0}" -f (Get-CurrentPath))
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
