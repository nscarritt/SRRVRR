# The one entry point for SRRVRR's checks, used locally and by CI: parse, ASCII, private details, path length,
# PSScriptAnalyzer and Pester, with the tool versions pinned here.
# Exit code: 0 all passed, 1 failures, 2 a pinned tool isn't installed.
param(
    # A list or one comma-separated string: powershell -File passes "Unit,Integration" as a single value.
    [string[]]$Level = @('Static', 'Unit', 'Integration'),
    [switch]$Smoke,
    [switch]$Elevated,
    [switch]$Coverage,
    [switch]$CI,
    [string[]]$Path
)

$Level = @($Level | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Path) { $Path = @($Path | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$unknown = @($Level | Where-Object { $_ -notin 'Static', 'Unit', 'Integration' })
if ($unknown) { Write-Host "Unknown -Level: $($unknown -join ', '). Use Static, Unit and/or Integration."; exit 2 }

$PesterVersion = '6.2.0'
$AnalyzerVersion = '1.25.0'

$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'out'
New-Item -ItemType Directory -Force -Path $out | Out-Null

if ($Elevated -and -not $env:GITHUB_ACTIONS) {
    Write-Host 'The -Elevated tests change firewall rules and shares, so they run only on the throwaway CI runner.'
    exit 2
}
foreach ($m in @(@{ Name = 'Pester'; Version = $PesterVersion }, @{ Name = 'PSScriptAnalyzer'; Version = $AnalyzerVersion })) {
    Remove-Module $m.Name -ErrorAction SilentlyContinue
    try { Import-Module $m.Name -RequiredVersion $m.Version -Force -ErrorAction Stop }
    catch {
        Write-Host "$($m.Name) $($m.Version) isn't installed. Install it with:"
        Write-Host "  Install-Module $($m.Name) -RequiredVersion $($m.Version) -Scope CurrentUser -Force -SkipPublisherCheck"
        exit 2
    }
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Name, [bool]$Passed, [string]$Detail) {
    $results.Add([pscustomobject]@{ Check = $Name; Result = $(if ($Passed) { 'pass' } else { 'FAIL' }); Detail = $Detail })
}
function Invoke-Tool([string]$Name, [string]$Script, [string[]]$Arguments) {
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $Script) @Arguments
    $code = $LASTEXITCODE
    $output | Where-Object { $_ } | ForEach-Object { Write-Host "  $_" }
    Add-Result $Name ($code -eq 0) (@($output)[-1])
}

if (-not $Path -and $Level -contains 'Static') {
    Write-Host 'Parse and C# compile'; Invoke-Tool 'Parse' 'Test-Parse.ps1' @('-Root', $root)
    Write-Host 'ASCII';                Invoke-Tool 'ASCII' 'Test-Ascii.ps1' @('-Root', $root)
    Write-Host 'Private details';      Invoke-Tool 'Private details' 'Test-NoPrivateInfo.ps1' @('-Root', $root)
    Write-Host 'Path length';          Invoke-Tool 'Path length' 'Test-PathLength.ps1' @('-Root', $root)
    Write-Host 'PSScriptAnalyzer'
    $findings = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Settings (Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'))
    $findings | ForEach-Object { Write-Host ('  {0}:{1} {2} {3}' -f $_.ScriptName, $_.Line, $_.Severity, $_.RuleName) }
    $errorCount = @($findings | Where-Object { $_.Severity -eq 'Error' }).Count
    Add-Result 'PSScriptAnalyzer' ($errorCount -eq 0) ('{0} errors, {1} warnings' -f $errorCount, ($findings.Count - $errorCount))
}

$config = New-PesterConfiguration -Hashtable (Import-PowerShellDataFile (Join-Path $root 'tests\PesterConfiguration.psd1'))
$config.Run.Path = if ($Path) { $Path } else { Join-Path $root 'tests' }
$config.TestResult.OutputPath = Join-Path $out 'test-results.xml'
$exclude = @()
if (-not $Smoke) { $exclude += 'Smoke' }
if (-not $Elevated) { $exclude += 'Elevated' }
if ($Level -notcontains 'Integration') { $exclude += 'Integration' }
$config.Filter.ExcludeTag = $exclude
if ($Coverage) {
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = @(Join-Path $root 'modules\*.psm1')
    $config.CodeCoverage.OutputPath = Join-Path $out 'coverage.xml'
}
Write-Host 'Pester'
$run = Invoke-Pester -Configuration $config
Add-Result 'Pester' ($run.Result -eq 'Passed') ('{0} passed, {1} failed, {2} skipped' -f $run.PassedCount, $run.FailedCount, $run.SkippedCount)
if ($Coverage -and $run.CodeCoverage) {
    $pct = [math]::Round($run.CodeCoverage.CoveragePercent, 1)
    Add-Result 'Coverage' ($pct -ge 100 -or -not $CI) "$pct% of module commands"
}

$node = Get-Command node -ErrorAction SilentlyContinue
$jsTests = Join-Path $root 'tests\js'
if (-not $Path -and (Test-Path $jsTests)) {
    if ($node) {
        Write-Host 'JavaScript'
        & $node.Source --test $jsTests
        Add-Result 'JavaScript' ($LASTEXITCODE -eq 0) 'node --test tests\js'
    } elseif ($CI) { Add-Result 'JavaScript' $false 'node not found' }
    else { Add-Result 'JavaScript' $true 'skipped: node not installed (CI runs these)' }
}

$table = @('| Check | Result | Detail |', '|---|---|---|') + @($results | ForEach-Object { "| $($_.Check) | $($_.Result) | $($_.Detail) |" })
[IO.File]::WriteAllLines((Join-Path $out 'summary.md'), $table)
$table | ForEach-Object { Write-Host $_ }
if ($results | Where-Object { $_.Result -eq 'FAIL' }) { exit 1 } else { exit 0 }
