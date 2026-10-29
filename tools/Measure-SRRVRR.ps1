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

function Get-Timed([string]$Path) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $req = [Net.HttpWebRequest]::Create("$BaseUrl$Path"); $req.Method = 'GET'; $req.Timeout = 10000
    $resp = $req.GetResponse()
    try { $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms) } finally { $resp.Close() }
    @{ Ms = $sw.Elapsed.TotalMilliseconds; Bytes = $ms.Length; Body = [Text.Encoding]::UTF8.GetString($ms.ToArray()) }
}

$proc = @(Find-SRRVRRProcess -Folder $Folder) | Select-Object -First 1
$cores = [Environment]::ProcessorCount
$cpuStart = $null
if ($proc) { $p = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue; if ($p) { $cpuStart = $p.TotalProcessorTime.TotalSeconds; $memStart = $p.PrivateMemorySize64 } }

# Poll /stats twice a second for the window, as a page does.
$statsMs = @(); $ticks = @(); $statsBytes = 0
$until = [DateTime]::UtcNow.AddSeconds($Seconds)
$clock = [Diagnostics.Stopwatch]::StartNew()
while ([DateTime]::UtcNow -lt $until) {
    $r = Get-Timed '/stats'
    $statsMs += $r.Ms; $statsBytes = $r.Bytes
    try { $t = ($r.Body | ConvertFrom-Json).tickMs; if ($null -ne $t) { $ticks += [double]$t } } catch { $null = $_ }
    Start-Sleep -Milliseconds 500
}
$window = $clock.Elapsed.TotalSeconds

# The page and every file it references.
$pageMs = @()
foreach ($i in 1..5) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $page = Get-Timed '/'
    $refs = @([regex]::Matches($page.Body, '(?:href|src)="(/[^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $css = $refs | Where-Object { $_ -like '*.css' } | ForEach-Object { (Get-Timed $_).Body }
    $refs += @([regex]::Matches(($css -join ''), 'url\((/img/[^)]+)\)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $pageBytes = $page.Bytes
    foreach ($ref in $refs) { $pageBytes += (Get-Timed $ref).Bytes }
    $pageMs += $sw.Elapsed.TotalMilliseconds
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
$tickMedian = Get-Percentile $ticks 50
$tickMax = if ($b.TickMsBaseline) { [math]::Max($b.TickMsBaseline * (1 + $b.TickMedianTolerancePercent / 100), $b.TickMsBaseline + $b.TickMedianToleranceMs) } else { $null }
Add-Row 'CPU (SRRVRR, % of machine)' $cpu '%' $b.ProcessCpuPercentOfMachineMax $b.Baseline.ProcessCpu
Add-Row 'Memory (private, end of window)' $mem 'MB' $null $b.Baseline.PrivateMB
Add-Row '/stats p95' ([math]::Round((Get-Percentile $statsMs 95), 1)) 'ms' $b.StatsP95MsMax $b.Baseline.StatsP95Ms
Add-Row '/stats median' ([math]::Round((Get-Percentile $statsMs 50), 1)) 'ms' $null $null
Add-Row '/stats size' $statsBytes 'bytes' $null $b.Baseline.StatsBytes
Add-Row 'Page load (median, with every file)' ([math]::Round((Get-Percentile $pageMs 50), 1)) 'ms' $b.PageLoadMsMax $b.Baseline.PageLoadMs
Add-Row 'Page size (with every file)' $pageBytes 'bytes' $null $b.Baseline.PageBytes
Add-Row 'Tick median' $tickMedian 'ms' $tickMax $(if ($b.TickMsBaseline) { $b.TickMsBaseline } else { $null })

$table = @("Measured $([math]::Round($window)) s against $BaseUrl ($cores logical CPUs).", '', '| Measure | Now | Budget | Baseline | Result |', '|---|---|---|---|---|') + $rows
$table | ForEach-Object { Write-Output $_ }
if ($OutFile) { [IO.File]::WriteAllLines($OutFile, [string[]]$table) }
if ($over -and -not $Informational) { exit 1 } else { exit 0 }
