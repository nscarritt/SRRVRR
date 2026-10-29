# Shared code for the tools in this folder.

# The P-th percentile (nearest rank) of a list of numbers.
function Get-Percentile {
    param([double[]]$Values, [double]$P)
    $sorted = @($Values | Sort-Object)
    if (-not $sorted.Count) { return $null }
    $rank = [Math]::Ceiling($P / 100 * $sorted.Count)
    $sorted[[Math]::Max(0, [Math]::Min($sorted.Count, $rank) - 1)]
}

function Compare-Budget {
    param([double]$Value, [double]$Max)
    if ($Value -lt $Max) { 'under' } elseif ($Value -eq $Max) { 'equal' } else { 'over' }
}

# The SRRVRR process running the SRRVRR.ps1 in -Folder (not a -Stop call). HttpListener's port belongs to the
# System process, so the port can't identify SRRVRR; the command line can.
function Find-SRRVRRProcess {
    param([Parameter(Mandatory)][string]$Folder, [object[]]$Processes)
    if (-not $PSBoundParameters.ContainsKey('Processes')) { $Processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'") }
    $script = [IO.Path]::Combine($Folder.TrimEnd('\'), 'SRRVRR.ps1')
    foreach ($p in $Processes) {
        $cmd = [string]$p.CommandLine
        if (-not $cmd -or $cmd -match '\s-Stop\b') { continue }
        if ($cmd.IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $p }
    }
}

Export-ModuleMember -Function Get-Percentile, Compare-Budget, Find-SRRVRRProcess
