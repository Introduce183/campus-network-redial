<# Check whether the current campus-network exit is a good exit. #>
[CmdletBinding()]
param(
    [ValidateRange(1, 60)] [int]$TimeoutSeconds = 4,
    [ValidateRange(1, 10)] [int]$Count = 3,
    # Stop as soon as one probe fails instead of waiting out the remaining timeouts.
    # Only correct when the caller's verdict is "every probe must pass" (a round that has
    # already lost one probe can never reach that), which is how this script is judged.
    # Default off, so existing callers keep exactly the previous behaviour.
    [switch]$StopOnFailure
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

# Detection uses Douyu's API hosts as a canary: good exits reach them quickly,
# bad exits throttle them until the request times out.
$uris = @('https://abvolcapi.douyucdn.cn/', 'https://apiv2.douyucdn.cn/')

# A list (not the pipeline) so the optional early exit below stays unambiguous.
$results = New-Object System.Collections.ArrayList
foreach ($i in 1..$Count) {
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
    [void]$results.Add([pscustomobject]@{ Try = $i; Url = $uri; Ok = $ok; ElapsedMs = [int]$sw.ElapsedMilliseconds; Note = $note })

    if ($StopOnFailure -and -not $ok) { break }
}

$results | Format-Table -AutoSize
$passed = @($results | Where-Object Ok).Count
$stopped = $StopOnFailure -and ($results.Count -lt $Count)
$suffix = if ($stopped) { ' Stopped at the first failure.' } else { '' }
Write-Host "Campus exit probe passed $passed of $($results.Count).$suffix" -ForegroundColor $(if ($passed -ge $results.Count) { 'Green' } else { 'Red' })
if ($passed -lt $results.Count) { exit 1 }
