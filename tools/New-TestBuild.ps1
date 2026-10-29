# Builds an SRRVRR test copy from a branch, tag or commit into its own folder: only the runtime files (git archive
# honours export-ignore), a test config, and TESTBUILD.txt, which marks the folder as a test copy. Never reads or
# copies the live config.
param(
    [Parameter(Mandatory)][string]$Ref,
    [Parameter(Mandatory)][string]$Destination,
    [int]$Port = 8091,
    [string]$DataPath = '',
    [string]$LiveFolder = $env:SRRVRR_LIVE_FOLDER,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dest = [IO.Path]::GetFullPath($Destination).TrimEnd('\')

if ($LiveFolder) {
    $live = [IO.Path]::GetFullPath($LiveFolder).TrimEnd('\')
    if ($dest -eq $live -or $dest.StartsWith($live + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Output "Refused: $dest is inside the live install ($live). Test copies need their own folder."; exit 1
    }
}
if ((Test-Path -LiteralPath $dest) -and (Get-ChildItem -LiteralPath $dest -Force | Select-Object -First 1)) {
    if (-not $Force) { Write-Output "Refused: $dest is not empty. Use -Force to replace an earlier test copy."; exit 1 }
    if (-not (Test-Path -LiteralPath (Join-Path $dest 'TESTBUILD.txt'))) {
        Write-Output "Refused: $dest has no TESTBUILD.txt, so it isn't a test copy; -Force only replaces test copies."; exit 1
    }
    Remove-Item -LiteralPath $dest -Recurse -Force
}

$commit = (& git -C $repo rev-parse "$Ref^{commit}").Trim()
if ($LASTEXITCODE -ne 0) { Write-Output "Refused: '$Ref' isn't a branch, tag or commit."; exit 1 }
$zip = Join-Path $env:TEMP ("srrvrr-build-" + [guid]::NewGuid().ToString('n') + '.zip')
try {
    & git -C $repo archive --format=zip -o $zip $commit
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
} finally { Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue }

$config = "# Test copy settings, written by tools\New-TestBuild.ps1.`r`n@{`r`n    Port = $Port`r`n"
if ($DataPath) { $config += "    DataPath = '$($DataPath.Replace("'", "''"))'`r`n" }
$config += "}`r`n"
[IO.File]::WriteAllText((Join-Path $dest 'SRRVRR.config.psd1'), $config)
[IO.File]::WriteAllText((Join-Path $dest 'TESTBUILD.txt'), "SRRVRR test copy`r`nref $Ref`r`ncommit $commit`r`nbuilt $([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz'))`r`n")
Write-Output "Test copy of $Ref ($($commit.Substring(0, 7))) in $dest, port $Port. Start it with `"$dest\Start SRRVRR.bat`"."
exit 0
