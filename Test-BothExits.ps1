<#
.SYNOPSIS
手动反复触发的双出口对比测试：每按一次回车，就分别测一次"拨号出口"和"Wi-Fi 出口"。

.DESCRIPTION
两个出口都要测，就不能靠默认路由（默认路由只有一个）。所以用 /32 主机路由把 canary 的
IPv4 分别钉到目标接口上，测完立刻删掉 —— **不改默认路由、不干扰你正在用的那条**。
这个机制在本轮已经实测验证过（指拨号→源是拨号；指 Wi-Fi→源是 Wi-Fi）。

用法：跑一次（会弹一次 UAC），然后在那个窗口里反复按回车。输入 q 回车退出。

每次触发做两件事，各测一次：
  1. 拨号出口：canary 的 /32 指向拨号接口
  2. Wi-Fi 出口：canary 的 /32 指向 WLAN 接口（下一跳取 WLAN 的网关）
两者都额外做一次"出口源地址确认"（curl 读 %{local_ip}），证明这次测量确实走的是那个出口。

因为要加删路由，需要管理员权限，所以非管理员启动时会自提权（弹一次 UAC）。
结果同时追加到 logs\exit-compare.log，方便你攒一堆之后看规律。
#>

[CmdletBinding()]
param(
    [string]$DialName,
    [string]$WifiName,
    [ValidateRange(1, 10)] [int]$ProbeCount = 2,
    [ValidateRange(1, 60)] [int]$TimeoutSeconds = 2,
    [string]$LogPath,
    # -Once：只测一轮就退出（供 GUI / 脚本调用，不进入 Read-Host 循环）。
    [switch]$Once,
    # -Json：配合 -Once 用，把结果以 JSON 输出而不是给人看的表格。
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SelfPath = $PSCommandPath
$script:LogFile = $null
$script:CanaryUris = @()

if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'logs\exit-compare.log' }

# 自提权重开时必须带上原参数，否则 -Once -Json 会丢：
# 父进程 exit 0 → GUI 只拿到空输出（"拿不到 JSON"），
# 而提权后的子进程因为没有这些参数会掉进 Read-Host 循环，弹个卡住的孤儿窗口。
$script:RelaunchArgs = @()
foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [System.Management.Automation.SwitchParameter]) {
        if ($v.IsPresent) { $script:RelaunchArgs += ('-' + $k) }
    }
    elseif ($null -ne $v) {
        $script:RelaunchArgs += ('-' + $k)
        $script:RelaunchArgs += [string]$v
    }
}

function Write-Line {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    # 加删 /32 路由需要管理员。脚本路径必须在脚本作用域取好：函数里的 $MyInvocation.MyCommand
    # 指的是函数本身，取 .Path 在 StrictMode 下会直接抛错。
    if (-not $script:SelfPath) {
        Write-Line '拿不到脚本自身路径，请用管理员身份手动运行。' 'Red'
        return
    }
    Write-Line '需要管理员权限（加删 /32 引导路由），正在请求提权...' 'Yellow'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs `
        -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:SelfPath) + $script:RelaunchArgs)
}

# ---------------------------------------------------------------- 接口与 canary

function Get-WifiAdapter {
    if (-not [string]::IsNullOrWhiteSpace($WifiName)) {
        return Get-NetAdapter -Name $WifiName -ErrorAction SilentlyContinue
    }
    return Get-NetAdapter -Physical |
        Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' -or $_.PhysicalMediaType -eq 'Wireless LAN' } |
        Select-Object -First 1
}

function Resolve-DialName {
    if (-not [string]::IsNullOrWhiteSpace($DialName)) { return $DialName }
    $names = @()
    foreach ($p in @((Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'), (Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'))) {
        if (Test-Path -LiteralPath $p) {
            $names += @(Select-String -LiteralPath $p -Pattern '^\s*\[(.+?)\]\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        }
    }
    $names = @($names | Select-Object -Unique)
    if ($names.Count -eq 1) { return $names[0] }
    return '宽带连接'
}

function Get-IPv4Of {
    param([int]$InterfaceIndex)
    $a = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($a) { return $a.IPAddress }
    return $null
}

function Get-CanaryUris {
    # 从判据脚本里正则读出 canary 列表，跟管理器保持一致（探针脚本本身只读不改）。
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
        catch { }
    }
    return @($addresses | Select-Object -Unique)
}

# ---------------------------------------------------------------- 引导路由

function Add-Steer {
    param([string]$Address, [int]$InterfaceIndex, [string]$NextHop)
    $common = @{ DestinationPrefix = "$Address/32"; InterfaceIndex = $InterfaceIndex; PolicyStore = 'ActiveStore'; ErrorAction = 'Stop' }
    try {
        New-NetRoute @common -NextHop $NextHop | Out-Null
        return $true
    }
    catch {
        if ($NextHop -ne '0.0.0.0') { return $false }
    }
    try {
        New-NetRoute @common | Out-Null
        return $true
    }
    catch { return $false }
}

function Remove-Steer {
    param([string]$Address, [int]$InterfaceIndex)
    Remove-NetRoute -DestinationPrefix "$Address/32" -InterfaceIndex $InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
}

Add-Type -AssemblyName System.Net.Http

# ---------------------------------------------------------------- 测速

function Measure-XidianBandwidth {
    # 【复制自 Redial-UntilCampusReady.ps1】那份文件保持零改动，需要改动就改这里。
    # 它不绑接口：调用前必须先测速主机的 A 记录 /32 钉到目标出口。
    $uri = 'https://test.xidian.edu.cn/backend/garbage.php'
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $cts = [System.Threading.CancellationTokenSource]::new()
    $cts.CancelAfter([TimeSpan]::FromSeconds(5))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $bytes = [int64]0
    $note = ''
    try {
        $buffer = New-Object byte[] (128 * 1024)
        while (-not $cts.IsCancellationRequested) {
            $response = $null
            $stream = $null
            try {
                $requestUri = "$uri`?r=$([Guid]::NewGuid().ToString('N'))&ckSize=100"
                $response = $client.GetAsync($requestUri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
                [void]$response.EnsureSuccessStatusCode()
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                while (-not $cts.IsCancellationRequested) {
                    $read = $stream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()
                    if ($read -le 0) { break }
                    $bytes += $read
                }
            }
            catch [System.OperationCanceledException] {
                break
            }
            finally {
                if ($stream) { $stream.Dispose() }
                if ($response) { $response.Dispose() }
            }
        }
        $note = "读取 $bytes 字节"
    }
    catch [System.OperationCanceledException] {
        $note = '达到 5 秒测速窗口'
    }
    catch {
        $note = $_.Exception.Message
    }
    finally {
        $sw.Stop()
        $cts.Dispose()
        $client.Dispose()
    }

    $seconds = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
    $mbps = ($bytes * 8.0) / $seconds / 1e6
    [pscustomobject]@{
        Mbps = $mbps
        Bytes = $bytes
        Seconds = $seconds
        Succeeded = ($bytes -gt 0)
        Note = $note
    }
}

function Resolve-SpeedHostIpv4 {
    # 运行时解析、一次拿全部 A —— 写死地址会被 DNS 轮换坑：
    # 轮到没钉的地址上，流量就从别的出口溜出去，测出来的是"谁"就不知道了。
    try {
        return @([System.Net.Dns]::GetHostAddresses('test.xidian.edu.cn') |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            ForEach-Object { $_.IPAddressToString })
    }
    catch { return @() }
}

# ---------------------------------------------------------------- 探测

function Invoke-Probe {
    param([int]$Count, [int]$Timeout)
    $probe = Join-Path $PSScriptRoot 'Test-CampusExit.ps1'
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -TimeoutSeconds $Timeout -Count $Count 2>&1 | Out-String

    $rows = @()
    foreach ($line in ($output -split "`r?`n" | Where-Object { $_ -match '^\s*\d+\s+https?://' })) {
        if ($line -match '^\s*(\d+)\s+(https?://\S+)\s+(True|False)\s+(\d+)') {
            $rows += [pscustomobject]@{
                Host = ([Uri]$Matches[2]).Host.Split('.')[0]
                Ok   = ($Matches[3] -eq 'True')
                Ms   = [int]$Matches[4]
            }
        }
    }
    $passed = -1
    $total = -1
    $m = [regex]::Match($output, 'probe passed (\d+) of (\d+)')
    if ($m.Success) { $passed = [int]$m.Groups[1].Value; $total = [int]$m.Groups[2].Value }
    return [pscustomobject]@{ Rows = $rows; Passed = $passed; Total = $total }
}

function Get-EgressSource {
    param([int]$Timeout)
    $raw = & curl.exe -s -o NUL -4 --max-time $Timeout --write-out '%{local_ip}' $script:CanaryUris[0] 2>&1 | Out-String
    return $raw.Trim()
}

function Test-OneExit {
    param([string]$Name, [int]$InterfaceIndex, [string]$NextHop, [string]$ExpectIp)

    # @(...) 包一下：Resolve-CanaryIpv4 只解析出 1 个地址时会被拆包成字符串，
    # 那样 $targets.Count 和遍历都会出问题。
    $targets = @(Resolve-CanaryIpv4)
    if ($targets.Count -eq 0) {
        return [pscustomobject]@{ Name = $Name; Error = 'canary 一个 IPv4 都解析不出来'; ExpectIp = $ExpectIp; Passed = -1; Total = -1; Detail = ''; Egress = ''; Ok = $false; Mbps = $null; SpeedNote = '' }
    }

    $installed = @()
    foreach ($ip in $targets) {
        if (Add-Steer -Address $ip -InterfaceIndex $InterfaceIndex -NextHop $NextHop) { $installed += $ip }
    }
    if ($installed.Count -ne $targets.Count) {
        foreach ($ip in $installed) { Remove-Steer -Address $ip -InterfaceIndex $InterfaceIndex }
        return [pscustomobject]@{ Name = $Name; Error = '引导路由没装全'; ExpectIp = $ExpectIp; Passed = -1; Total = -1; Detail = ''; Egress = ''; Ok = $false; Mbps = $null; SpeedNote = '' }
    }

    try {
        $r = Invoke-Probe -Count $ProbeCount -Timeout $TimeoutSeconds
        $egress = Get-EgressSource -Timeout $TimeoutSeconds
        $detail = @($r.Rows | ForEach-Object { '{0} {1} {2}ms' -f $_.Host, $(if ($_.Ok) { 'ok' } else { 'FAIL' }), $_.Ms }) -join '  '

        # 网速：先用源地址证明这次测量确实钉在这个出口上，再谈"它有多快"。
        # （路由表/钉路由只是手段，curl 的 %{local_ip} 才是真相 —— 源地址都不对，Mbps 就是别人的。）
        $mbps = $null
        $speedNote = ''
        if ($egress -ne $ExpectIp) {
            $speedNote = '出口源地址不符，跳过测速'
        }
        else {
            $speedIps = @(Resolve-SpeedHostIpv4)
            if ($speedIps.Count -eq 0) {
                $speedNote = '测速主机解析不出 IPv4'
            }
            else {
                $got = @()
                foreach ($ip in $speedIps) {
                    if (Add-Steer -Address $ip -InterfaceIndex $InterfaceIndex -NextHop $NextHop) { $got += $ip }
                }
                # 记进 $installed：外层 finally 一定会清（哪怕测速抛异常）
                $installed = @($installed) + $got
                if ($got.Count -ne $speedIps.Count) {
                    $speedNote = '测速主机的引导路由没装全'
                }
                else {
                    try {
                        $m = Measure-XidianBandwidth
                        if ($m.Succeeded) { $mbps = [Math]::Round($m.Mbps, 2); $speedNote = $m.Note }
                        elseif ($m.Bytes -le 0) { $speedNote = '测速服务器 0 字节（这条出口到它取不到数据）' }
                        else { $speedNote = $m.Note }
                    }
                    catch { $speedNote = ('测速异常：{0}' -f $_.Exception.Message) }
                }
            }
        }

        return [pscustomobject]@{
            Name      = $Name
            Error     = ''
            ExpectIp  = $ExpectIp
            Passed    = $r.Passed
            Total     = $r.Total
            Detail    = $detail
            Egress    = $egress
            Ok        = ($r.Passed -ge 0 -and $r.Total -gt 0 -and $r.Passed -ge $r.Total -and $egress -eq $ExpectIp)
            Mbps      = $mbps
            SpeedNote = $speedNote
        }
    }
    finally {
        foreach ($ip in $installed) { Remove-Steer -Address $ip -InterfaceIndex $InterfaceIndex }
    }
}

# ---------------------------------------------------------------- 显示

function Format-ExitLine {
    param([pscustomobject]$Result, [string]$Tag)

    if ($Result.Error) {
        return ('  {0,-14} {1}' -f $Tag, $Result.Error)
    }
    $verdict = if ($Result.Passed -ge $Result.Total -and $Result.Total -gt 0) { '通过' } else { '未通过' }
    $egressNote = if ($Result.Egress) {
        if ($Result.Egress -eq $Result.ExpectIp) { '{0} ✓' -f $Result.Egress } else { '{0}（与预期 {1} 不符！）' -f $Result.Egress, $Result.ExpectIp }
    }
    else { '(拿不到)' }
    $speed = if ($null -ne $Result.Mbps) { ('{0:N2} Mbps' -f $Result.Mbps) } elseif ($Result.SpeedNote) { $Result.SpeedNote } else { '' }
    return ('  {0,-14} {1} {2}/{3}   {4}   测速 {5}   出口源地址 {6}' -f $Tag, $verdict, $Result.Passed, $Result.Total, $Result.Detail, $speed, $egressNote)
}

function Invoke-OneRound {
    # 测一轮：拨号出口 + Wi-Fi 出口各一次，并追加日志。
    # 抽成函数是为了让"交互循环"和 `-Once`（GUI 调用）走同一段逻辑，避免两处实现漂移。
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $dialIf = Get-NetIPInterface -AddressFamily IPv4 -InterfaceAlias $DialName -ErrorAction SilentlyContinue | Select-Object -First 1
    $dialIp = $null
    $dialResult = $null
    $dialNote = ''
    if ($dialIf) {
        $dialIp = Get-IPv4Of -InterfaceIndex $dialIf.ifIndex
        $dialResult = Test-OneExit -Name '拨号' -InterfaceIndex $dialIf.ifIndex -NextHop '0.0.0.0' -ExpectIp $dialIp
    }
    else {
        $dialNote = ('拨号未连接（先 rasdial {0} 再测）' -f $DialName)
    }

    $wifiIp = $null
    $wifiResult = $null
    $wifiNote = ''
    if ($wifiAdapter -and $wifiAdapter.Status -eq 'Up') {
        $wifiRoute = Get-NetRoute -InterfaceIndex $wifiAdapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
        $wifiIp = Get-IPv4Of -InterfaceIndex $wifiAdapter.ifIndex
        if ($wifiRoute -and $wifiRoute.NextHop -ne '0.0.0.0') {
            $wifiResult = Test-OneExit -Name 'Wi-Fi' -InterfaceIndex $wifiAdapter.ifIndex -NextHop $wifiRoute.NextHop -ExpectIp $wifiIp
        }
        else {
            $wifiNote = 'Wi-Fi 没有默认路由（网卡连着但没拿到网关）'
        }
    }
    else {
        $wifiNote = 'Wi-Fi 网卡不可用'
    }

    $dOk = [bool]($dialResult -and $dialResult.Ok)
    $wOk = [bool]($wifiResult -and $wifiResult.Ok)
    $verdict = if ($dOk -and $wOk) { '两个出口都可用' }
    elseif ($dOk) { '只有拨号可用' }
    elseif ($wOk) { '只有 Wi-Fi 可用' }
    else { '两个出口都不可用' }

    if ($script:LogFile) {
        foreach ($pair in @(@('pppoe', $dialResult, $dialIp), @('wifi', $wifiResult, $wifiIp))) {
            $tag = $pair[0]; $res = $pair[1]; $ip = $pair[2]
            $line = if ($res) {
                $speed = if ($null -ne $res.Mbps) { ('{0:N2}Mbps' -f $res.Mbps) } else { '-' }
                '{0}  {1,-6} {2,-16} 通过 {3}/{4} 测速={5}  {6}  源={7}' -f $stamp, $tag, $ip, $res.Passed, $res.Total, $speed, $res.Detail, $res.Egress
            }
            else {
                '{0}  {1,-6} {2,-16} 未测（不可用）' -f $stamp, $tag, $ip
            }
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        }
        Add-Content -LiteralPath $script:LogFile -Value ('{0}  ==> {1}' -f $stamp, $verdict) -Encoding UTF8
    }

    return [pscustomobject]@{
        Time      = $stamp
        Dial      = $dialResult
        DialIp    = $dialIp
        DialNote  = $dialNote
        Wifi      = $wifiResult
        WifiIp    = $wifiIp
        WifiNote  = $wifiNote
        DialOk    = $dOk
        WifiOk    = $wOk
        Verdict   = $verdict
    }
}

function Show-Round {
    param([pscustomobject]$Round, [int]$Index)

    Write-Line ''
    Write-Line '──────────────────────────────────────────────────────────────'
    Write-Line ("[{0}] 第 {1} 次" -f (Get-Date -Format 'HH:mm:ss'), $Index) 'Cyan'

    if ($Round.Dial) {
        Write-Line (Format-ExitLine -Result $Round.Dial -Tag ('拨号 {0}' -f $Round.DialIp)) $(if ($Round.DialOk) { 'Green' } else { 'Red' })
    }
    else {
        Write-Line ("  拨号          {0}" -f $Round.DialNote) 'Yellow'
    }

    if ($Round.Wifi) {
        Write-Line (Format-ExitLine -Result $Round.Wifi -Tag ('Wi-Fi {0}' -f $Round.WifiIp)) $(if ($Round.WifiOk) { 'Green' } else { 'Red' })
    }
    else {
        Write-Line ("  Wi-Fi         {0}" -f $Round.WifiNote) 'Yellow'
    }

    Write-Line ("  => {0}" -f $Round.Verdict) $(if ($Round.DialOk -or $Round.WifiOk) { 'Gray' } else { 'Red' })
}

function ConvertTo-RoundJson {
    # 给 GUI 消费的精简结构（不把内部的 ExpectIp/Error 之类全抖出去）。
    param([pscustomobject]$Round)

    $dial = [pscustomobject]@{
        ok        = $Round.DialOk
        ip        = $Round.DialIp
        passed    = $(if ($Round.Dial) { $Round.Dial.Passed } else { $null })
        total     = $(if ($Round.Dial) { $Round.Dial.Total } else { $null })
        ms        = $(if ($Round.Dial) { @($Round.Dial.Detail -split '\s+' | Where-Object { $_ -match 'ms$' }) } else { @() })
        egress    = $(if ($Round.Dial) { $Round.Dial.Egress } else { $null })
        mbps      = $(if ($Round.Dial) { $Round.Dial.Mbps } else { $null })
        speedNote = $(if ($Round.Dial) { $Round.Dial.SpeedNote } else { '' })
        note      = $(if ($Round.Dial) { '' } else { $Round.DialNote })
    }
    $wifi = [pscustomobject]@{
        ok        = $Round.WifiOk
        ip        = $Round.WifiIp
        passed    = $(if ($Round.Wifi) { $Round.Wifi.Passed } else { $null })
        total     = $(if ($Round.Wifi) { $Round.Wifi.Total } else { $null })
        ms        = $(if ($Round.Wifi) { @($Round.Wifi.Detail -split '\s+' | Where-Object { $_ -match 'ms$' }) } else { @() })
        egress    = $(if ($Round.Wifi) { $Round.Wifi.Egress } else { $null })
        mbps      = $(if ($Round.Wifi) { $Round.Wifi.Mbps } else { $null })
        speedNote = $(if ($Round.Wifi) { $Round.Wifi.SpeedNote } else { '' })
        note      = $(if ($Round.Wifi) { '' } else { $Round.WifiNote })
    }
    return [pscustomobject]@{ time = $Round.Time; dial = $dial; wifi = $wifi; verdict = $Round.Verdict }
}

# ---------------------------------------------------------------- 启动

$DialName = Resolve-DialName
$wifiAdapter = Get-WifiAdapter
$script:CanaryUris = Get-CanaryUris

if (-not (Test-Elevated)) {
    Restart-Elevated
    exit 0
}

# 管理器在跑的时候不要同时动路由 —— 它会自己加删默认路由，两边会互相干扰。
$mutex = [System.Threading.Mutex]::new($false, 'Local\CampusNetworkPath')
$managerRunning = -not $mutex.WaitOne(0)
if (-not $managerRunning) { $mutex.ReleaseMutex(); $mutex.Dispose() }

# -Once -Json 不走上面那个给人看的横幅（JSON 模式不许往 stdout 打非 JSON 的东西），
# 所以这条警告改走 stderr —— GUI 会把它原样显示成橙色提示。
if ($Once -and $Json -and $managerRunning) {
    [Console]::Error.WriteLine('WARN: 网络管理器正在运行；两边都会改路由，结果可能受它干扰。')
}

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = $LogPath

if (-not $Once) {
    Write-Line ''
    Write-Line '==================== 双出口对比测试 ====================' 'Cyan'
    Write-Line ("拨号：{0}    Wi-Fi：{1}" -f $DialName, $(if ($wifiAdapter) { $wifiAdapter.Name } else { '没找到无线网卡' }))
    Write-Line ("每轮：每出口 {0} 个探针、单探针超时 {1}s；canary：{2}" -f $ProbeCount, $TimeoutSeconds, ($script:CanaryUris -join ' '))
    Write-Line ("日志追加到：{0}" -f $LogPath)
    if ($managerRunning) {
        Write-Line ''
        Write-Line '⚠ 检测到网络管理器正在运行。两边都会改路由，建议先停掉它（Ctrl+C）再测。' 'Yellow'
        Write-Line '  仍然继续测，但结果可能受它干扰。' 'Yellow'
    }
    Write-Line ''
    Write-Line '在下面反复按【回车】测一轮；输入 q 回车退出。' 'Green'
    Write-Line ''
}

$round = 0
$lastRound = $null

if ($Once) {
    # 单次模式：给 GUI / 脚本调用，测一轮就退出（不碰 Read-Host）。
    $round = 1
    $lastRound = Invoke-OneRound
    if ($Json) {
        ConvertTo-RoundJson -Round $lastRound | ConvertTo-Json -Depth 4 -Compress
    }
    else {
        Show-Round -Round $lastRound -Index $round
    }
}
else {
    while ($true) {
        $answer = Read-Host '回车=测一轮 / q=退出'
        if ($answer -match '^\s*q\s*$') { break }

        $round++
        $lastRound = Invoke-OneRound
        Show-Round -Round $lastRound -Index $round
    }
    Write-Line ''
    Write-Line ("共测了 {0} 轮，日志在 {1}" -f $round, $script:LogFile) 'Cyan'
}

# 收尾：确认没有残留的 /32 引导路由（两种模式都要查）。
# 只看"可能是我们钉的" /32：系统自带的自路由必须排掉，否则必然误报。
# 实测踩过：127.*（回环）、169.254.*（链路本地自/广播）都会被当残留列出来。
$left = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -like '*/32' -and $_.DestinationPrefix -notlike '10.*' -and $_.DestinationPrefix -notlike '172.29*' -and $_.DestinationPrefix -notlike '127.*' -and $_.DestinationPrefix -notlike '169.254.*' -and $_.DestinationPrefix -ne '255.255.255.255/32' })
if ($left.Count) {
    if ($Once -and $Json) {
        # JSON 模式：这条不能混进 JSON 正文，走 stderr。
        [Console]::Error.WriteLine(('WARN: {0} leftover /32 route(s)' -f $left.Count))
    }
    else {
        Write-Line '确认没有残留的 /32 引导路由：'
        $left | ForEach-Object { Write-Line ('  残留 {0} ifIndex={1}' -f $_.DestinationPrefix, $_.InterfaceIndex) 'Red' }
    }
}
elseif (-not ($Once -and $Json)) {
    Write-Line '确认没有残留的 /32 引导路由：'
    Write-Line '  无 ✓' 'Green'
}

# -Once 给出退出码方便调用方判断：两个出口都可用才 0。
if ($Once) {
    if ($lastRound -and $lastRound.DialOk -and $lastRound.WifiOk) { exit 0 }
    exit 1
}
