<# Check whether the current campus-network exit is a good exit. #>
[CmdletBinding()]
param(
    [ValidateRange(1, 60)] [int]$TimeoutSeconds = 4,
    [ValidateRange(1, 10)] [int]$Count = 3
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

# Detection uses Douyu's API hosts as a canary: good exits reach them quickly,
# bad exits throttle them until the request times out.
$uris = @('https://abvolcapi.douyucdn.cn/', 'https://apiv2.douyucdn.cn/')

$results = foreach ($i in 1..$Count) {
    $uri = $uris[($i - 1) % $uris.Count]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $false
    $note = ''
    $resp = $null
    $client = [System.Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $resp = $client.GetAsync($uri).GetAwaiter().GetResult()
        $ok = $true
        $note = "HTTP $([int]$resp.StatusCode)"
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $note = $inner.Message
    }
    finally {
        if ($resp) { $resp.Dispose() }
        $client.Dispose()
    }
    $sw.Stop()
    [pscustomobject]@{ Try = $i; Url = $uri; Ok = $ok; ElapsedMs = [int]$sw.ElapsedMilliseconds; Note = $note }
}

$results | Format-Table -AutoSize
$passed = @($results | Where-Object Ok).Count
Write-Host "Campus exit probe passed $passed of $($results.Count)." -ForegroundColor $(if ($passed -ge $Count) { 'Green' } else { 'Red' })
if ($passed -lt $Count) { exit 1 }
