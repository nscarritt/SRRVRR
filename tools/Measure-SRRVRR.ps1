# Measures a running SRRVRR against the spec's budgets, read-only: HTTP GETs, process information and file sizes.
# Prints a markdown table (for the PR description) with the budget and the v0.6.0 baseline beside each number.
# Exit code: 0 within budget (always 0 with -Informational), 1 over budget.
param(
    [string]$BaseUrl = 'http://localhost:8091',
    [Parameter(Mandatory)][string]$Folder,
    [int]$Seconds = 60,
    [string]$Budgets,
    [string]$OutFile,
    [switch]$Informational
)

# $PSScriptRoot is empty in parameter defaults under powershell -File on 5.1, so defaults are resolved here.
if (-not $Budgets) { $Budgets = Join-Path $PSScriptRoot 'budgets.psd1' }
Import-Module (Join-Path $PSScriptRoot 'SRRVRR.Tools.psm1') -Force
$b = Import-PowerShellDataFile $Budgets

# One GET. A request that fails (no answer, or not 200) is counted in $script:failures and returns $null,
# so it's never timed as if it had worked.
$script:failures = 0
function Get-Timed([string]$Path) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $req = [Net.HttpWebRequest]::Create("$BaseUrl$Path"); $req.Method = 'GET'; $req.Timeout = 10000
        $resp = $req.GetResponse()
        try { $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms) } finally { $resp.Close() }
        @{ Ms = $sw.Elapsed.TotalMilliseconds; Bytes = $ms.Length; Body = [Text.Encoding]::UTF8.GetString($ms.ToArray()) }
    } catch { $script:failures++; $null }
}

$proc = @(Find-SRRVRRProcess -Folder $Folder) | Select-Object -First 1
if (-not $proc) { Write-Output "Note: no SRRVRR found running from $Folder, so CPU and memory can't be measured." }
$cores = [Environment]::ProcessorCount
$cpuStart = $null
if ($proc) { $p = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue; if ($p) { $cpuStart = $p.TotalProcessorTime.TotalSeconds; $memStart = $p.PrivateMemorySize64 } }

# Poll /stats twice a second for the window, as a page does.
$statsMs = @(); $ticks = @(); $statsBytes = 0
$until = [DateTime]::UtcNow.AddSeconds($Seconds)
$clock = [Diagnostics.Stopwatch]::StartNew()
while ([DateTime]::UtcNow -lt $until) {
    $r = Get-Timed '/stats'
    if ($r) {
        $statsMs += $r.Ms; $statsBytes = $r.Bytes
        try { $t = ($r.Body | ConvertFrom-Json).tickMs; if ($null -ne $t) { $ticks += [double]$t } } catch { $null = $_ }
    }
    Start-Sleep -Milliseconds 500
}
$window = $clock.Elapsed.TotalSeconds

# The page and every file it references.
$pageMs = @()
foreach ($i in 1..5) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $page = Get-Timed '/'
    if (-not $page) { continue }
    $refs = @([regex]::Matches($page.Body, '(?:href|src)="(/[^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $css = $refs | Where-Object { $_ -like '*.css' } | ForEach-Object { $c = Get-Timed $_; if ($c) { $c.Body } }
    $refs += @([regex]::Matches(($css -join ''), 'url\((/img/[^)]+)\)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $pageBytes = $page.Bytes
    $complete = $true
    foreach ($ref in $refs) { $f = Get-Timed $ref; if ($f) { $pageBytes += $f.Bytes } else { $complete = $false } }
    if ($complete) { $pageMs += $sw.Elapsed.TotalMilliseconds }
}

$cpu = $null; $mem = $null
if ($null -ne $cpuStart) {
    $p = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
    if ($p) { $cpu = [math]::Round(100 * ($p.TotalProcessorTime.TotalSeconds - $cpuStart) / ($window * $cores), 2); $mem = [math]::Round($p.PrivateMemorySize64 / 1MB) }
}

$rows = New-Object System.Collections.Generic.List[object]
$over = $false
function Add-Row([string]$Name, $Value, [string]$Unit, $Max, $Baseline) {
    $status = if ($null -eq $Value) { 'n/a' } elseif ($null -eq $Max) { 'recorded' } else { Compare-Budget -Value $Value -Max $Max }
    if ($status -eq 'over') { $script:over = $true }
    $rows.Add("| $Name | $(if ($null -eq $Value) { 'n/a' } else { "$Value $Unit" }) | $(if ($null -eq $Max) { '-' } else { "$Max $Unit" }) | $(if ($null -eq $Baseline) { '-' } else { "$Baseline $Unit" }) | $status |")
}
# A number that was never measured stays $null ("n/a"); [math]::Round would turn it into 0.
function Get-Rounded($Value) { if ($null -eq $Value) { $null } else { [math]::Round($Value, 1) } }
$tickMedian = Get-Percentile $ticks 50
$tickMax = if ($b.TickMsBaseline) { [math]::Max($b.TickMsBaseline * (1 + $b.TickMedianTolerancePercent / 100), $b.TickMsBaseline + $b.TickMedianToleranceMs) } else { $null }
Add-Row 'CPU (SRRVRR, % of machine)' $cpu '%' $b.ProcessCpuPercentOfMachineMax $b.Baseline.ProcessCpu
Add-Row 'Memory (private, end of window)' $mem 'MB' $null $b.Baseline.PrivateMB
Add-Row '/stats p95' (Get-Rounded (Get-Percentile $statsMs 95)) 'ms' $b.StatsP95MsMax $b.Baseline.StatsP95Ms
Add-Row '/stats median' (Get-Rounded (Get-Percentile $statsMs 50)) 'ms' $null $null
Add-Row '/stats size' $(if ($statsMs.Count) { $statsBytes } else { $null }) 'bytes' $null $b.Baseline.StatsBytes
Add-Row 'Page load (median, with every file)' (Get-Rounded (Get-Percentile $pageMs 50)) 'ms' $b.PageLoadMsMax $b.Baseline.PageLoadMs
Add-Row 'Page size (with every file)' $(if ($pageMs.Count) { $pageBytes } else { $null }) 'bytes' $null $b.Baseline.PageBytes
Add-Row 'Tick median' $tickMedian 'ms' $tickMax $(if ($b.TickMsBaseline) { $b.TickMsBaseline } else { $null })
$rows.Add("| Failed requests | $($script:failures) | 0 | - | $(if ($script:failures) { 'over' } else { 'under' }) |")
# A run that couldn't measure everything isn't a pass: failed requests, or no SRRVRR process found.
if ($script:failures -or -not $proc) { $over = $true }

$table = @("Measured $([math]::Round($window)) s against $BaseUrl ($cores logical CPUs).", '', '| Measure | Now | Budget | Baseline | Result |', '|---|---|---|---|---|') + $rows
$table | ForEach-Object { Write-Output $_ }
if ($OutFile) { [IO.File]::WriteAllLines($OutFile, [string[]]$table) }
if ($over -and -not $Informational) { exit 1 } else { exit 0 }
