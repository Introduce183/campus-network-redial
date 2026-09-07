<#
.SYNOPSIS
Redials a Windows dial-up connection until the current exit is a good exit.

.DESCRIPTION
Each dial-up session is assigned a different egress. Good exits are unthrottled;
bad exits throttle a canary service's API hosts. The throttle can take a few
seconds to apply after a fresh dial, so this waits before judging and confirms
the probe three times (with a longer wait before the third check) before
trusting the exit.

The dial-up connection must already exist in Windows and have its credentials
saved. If -DialName is omitted, the connection name is detected automatically
(falls back to "宽带连接").

Use -200MbpsMode to keep redialling until the Xidian LibreSpeed download test
exceeds 150 Mbps.
#>

[CmdletBinding()]
param(
    [string]$DialName,
    [switch]$TestOnly,
    [switch]$200MbpsMode,
    [ValidateRange(1, 60)] [int]$TimeoutSeconds = 4,
    [ValidateRange(1, 10)] [int]$ProbeCount = 3,
    [ValidateRange(0, 300)] [int]$SettleSeconds = 3,
    [ValidateRange(0, 300)] [int]$ConfirmIntervalSeconds = 12,
    [ValidateRange(0, 600)] [int]$ThirdIntervalSeconds = 30,
    [ValidateRange(1, 600)] [int]$PauseSeconds = 2,
    [ValidateRange(0, 10000)] [int]$MaxAttempts = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Test-CampusExit {
    foreach ($round in 1..3) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-CampusExit.ps1') -TimeoutSeconds $TimeoutSeconds -Count $ProbeCount | Out-Host
        if ($LASTEXITCODE -ne 0) { return $false }
        if ($round -eq 1) { Start-Sleep -Seconds $ConfirmIntervalSeconds }
        elseif ($round -eq 2) { Start-Sleep -Seconds $ThirdIntervalSeconds }
    }
    return $true
}

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
    param([string]$DialName)
    if (-not [string]::IsNullOrWhiteSpace($DialName)) { return $DialName }
    $names = Get-DialupName
    if ($names.Count -eq 1) { return $names[0] }
    if ($names.Count -gt 1) {
        $active = & rasdial.exe 2>$null | Out-String
        foreach ($n in $names) {
            if ($active -like "*$n*") { return $n }
        }
        throw "Multiple dial-up connections found ($($names -join ', ')). Specify one with -DialName."
    }
    return '宽带连接'
}

function Disconnect-Dialup {
    & rasdial.exe $DialName /disconnect 2>$null | Out-Host
}

function Connect-Dialup {
    & rasdial.exe $DialName | Out-Host
    return ($LASTEXITCODE -eq 0)
}

function Measure-XidianBandwidth {
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

function Get-HighBandwidthExit {
     $result = Measure-XidianBandwidth
        Write-Host ("测速结果：{0:N2} Mbps，耗时 {1:N2} 秒（{2}）。" -f $result.Mbps, $result.Seconds, $result.Note)
        if ($result.Succeeded -and $result.Mbps -gt 150) {
            Write-Host '已达到 150 Mbps 目标，停止重拨。' -ForegroundColor Green
            return $true
        }
    $attempt = 0
    while ($true) {
        $attempt++
        Write-Host "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] 200Mbps 模式：第 $attempt 次连接尝试" -ForegroundColor Cyan
        Disconnect-Dialup
        Start-Sleep -Seconds 2

        if (-not (Connect-Dialup)) {
            Write-Warning "拨号失败，将在 $PauseSeconds 秒后重试。"
            Start-Sleep -Seconds $PauseSeconds
            continue
        }

        Write-Host "等待 $SettleSeconds 秒后开始测速（目标 > 150 Mbps）..."
        Start-Sleep -Seconds $SettleSeconds
        $result = Measure-XidianBandwidth
        Write-Host ("测速结果：{0:N2} Mbps，耗时 {1:N2} 秒（{2}）。" -f $result.Mbps, $result.Seconds, $result.Note)
        if ($result.Succeeded -and $result.Mbps -gt 150) {
            Write-Host '已达到 150 Mbps 目标，停止重拨。' -ForegroundColor Green
            return $true
        }

        Write-Warning '带宽未超过 150 Mbps，将重新拨号。'
        Start-Sleep -Seconds $PauseSeconds
    }
}

function Get-GoodExit {
    for ($attempt = 1; ($MaxAttempts -eq 0) -or ($attempt -le $MaxAttempts); $attempt++) {
        Write-Host "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Attempt $attempt" -ForegroundColor Cyan
        Disconnect-Dialup
        Start-Sleep -Seconds 2

        if (-not (Connect-Dialup)) {
            Write-Warning "Dial-up failed. Retrying in $PauseSeconds seconds."
            Start-Sleep -Seconds $PauseSeconds
            continue
        }

        Write-Host "Waiting $SettleSeconds seconds for the new exit to settle before probing..."
        Start-Sleep -Seconds $SettleSeconds
        if (Test-CampusExit) {
            Write-Host 'Good campus-network exit found and confirmed.' -ForegroundColor Green
            Write-Host '好了喵' -ForegroundColor Green
            Write-Host '-- introduce'
            return $true
        }

        Write-Warning "This exit is throttled; redialling in $PauseSeconds seconds."
        Start-Sleep -Seconds $PauseSeconds
    }
    return $false
}

if ($TestOnly -and ${200MbpsMode}) {
    throw '-200MbpsMode 不能与 -TestOnly 同时使用。'
}

if ($TestOnly) {
    if (Test-CampusExit) {
        Write-Host 'Current exit is a good campus-network exit.' -ForegroundColor Green
        exit 0
    }
    Write-Host 'Current exit is a bad campus-network exit.' -ForegroundColor Red
    exit 1
}

$DialName = Resolve-DialName -DialName $DialName
Write-Host "Using dial-up connection: $DialName"

if (${200MbpsMode}) {
    [void](Get-HighBandwidthExit)
    exit 0
}

if (-not (Get-GoodExit)) {
    Write-Error "No good exit was found after $MaxAttempts attempts."
    exit 1
}

while ($true) {
    $choice = Read-Host "是否继续测速或者重新拨号？输入 Y 继续，其它任意键退出"
    if ($choice -notmatch '^[Yy]$') {
        exit 0
    }

    if (Test-CampusExit) {
        Write-Host '测速通过：当前仍为好出口。' -ForegroundColor Green
    }
    else {
        Write-Warning '测速失败：当前出口已被限速，正在重新拨号...'
        if (-not (Get-GoodExit)) {
            Write-Error "No good exit was found after $MaxAttempts attempts."
            exit 1
        }
    }
}
