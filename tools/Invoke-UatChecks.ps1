# Read-only checks for one story's UAT checklist (docs\uat\<story>-*.md), against a running test copy. Prints one
# PASS / FAIL line per check, numbered like the checklist's steps. Exit code: 0 all passed, 1 any failed.
param([Parameter(Mandatory)][ValidateSet(47)][int]$Story, [string]$BaseUrl = 'http://localhost:8091')

$failed = 0
function Get-Url([string]$Path, [string]$Method = 'GET') {
    $req = [Net.HttpWebRequest]::Create("$BaseUrl$Path"); $req.Method = $Method; $req.Timeout = 10000
    if ($Method -eq 'POST') { $req.ContentLength = 0 }
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw } }
    try {
        $ms = New-Object IO.MemoryStream; $s = $resp.GetResponseStream(); if ($s) { $s.CopyTo($ms) }
        @{ Status = [int]$resp.StatusCode; Type = $resp.ContentType; Nosniff = $resp.Headers['X-Content-Type-Options']; Body = [Text.Encoding]::UTF8.GetString($ms.ToArray()) }
    } finally { $resp.Close() }
}
function Test-Step([string]$Step, [string]$Text, [scriptblock]$Check) {
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $ok = $false }
    if (-not $ok) { $script:failed++ }
    Write-Output ('{0} {1} {2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Step, $Text)
}

if ($Story -eq 47) {
    $stats = Get-Url '/stats'
    $doc = $stats.Body | ConvertFrom-Json
    Test-Step '2' '/stats answers, is ready and reports tickMs' { $stats.Status -eq 200 -and $doc.ready -and $doc.tickMs -is [int] }
    # One reading swings (40-65 ms on the server), so the budget is checked on the median of 10, a second apart.
    $ticks = @(foreach ($i in 1..10) { [int]((Get-Url '/stats').Body | ConvertFrom-Json).tickMs; if ($i -lt 10) { Start-Sleep -Milliseconds 1000 } }) | Sort-Object
    $median = $ticks[[int][Math]::Floor($ticks.Count / 2)]
    Test-Step '2' "tickMs median $median ms of 10 readings is within the #47 budget (44 ms, +10% or 5 ms: 49 ms)" { $median -le 49 }
    $page = Get-Url '/'
    Test-Step '3' 'the page is served from web\ as UTF-8 HTML with nosniff' { $page.Status -eq 200 -and $page.Type -eq 'text/html; charset=utf-8' -and $page.Nosniff -eq 'nosniff' }
    $css = Get-Url '/style.css'
    $images = @([regex]::Matches($css.Body, 'url\((/img/[^)]+)\)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    Test-Step '3' "app.js, style.css and all $($images.Count) logos load" { (Get-Url '/app.js').Status -eq 200 -and $css.Status -eq 200 -and $images.Count -gt 0 -and -not ($images | Where-Object { (Get-Url $_).Status -ne 200 }) }
    Test-Step '5' 'an unknown path gets 404, not the page' { (Get-Url '/no-such-page').Status -eq 404 }
    Test-Step '5' 'a POST gets 405' { (Get-Url '/' 'POST').Status -eq 405 }
}
if ($failed) { exit 1 } else { exit 0 }
