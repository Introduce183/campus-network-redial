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
#>

[CmdletBinding()]
param(
    [string]$DialName,
    [switch]$TestOnly,
    [ValidateRange(1, 60)] [int]$TimeoutSeconds = 4,
    [ValidateRange(1, 10)] [int]$ProbeCount = 3,
    [ValidateRange(0, 300)] [int]$SettleSeconds = 10,
    [ValidateRange(0, 300)] [int]$ConfirmIntervalSeconds = 12,
    [ValidateRange(0, 600)] [int]$ThirdIntervalSeconds = 30,
    [ValidateRange(1, 600)] [int]$PauseSeconds = 8,
    [ValidateRange(0, 10000)] [int]$MaxAttempts = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        exit 0
    }

    Write-Warning "This exit is throttled; redialling in $PauseSeconds seconds."
    Start-Sleep -Seconds $PauseSeconds
}

Write-Error "No good exit was found after $MaxAttempts attempts."
exit 1
