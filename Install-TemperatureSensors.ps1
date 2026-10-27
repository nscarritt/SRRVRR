# Installs what SRRVRR needs to show CPU and memory temperatures. Windows has no built-in way to
# read them, so SRRVRR uses two open, signed components:
#   1. LibreHardwareMonitor's sensor library (MPL-2.0), copied to lib\LibreHardwareMonitor next to
#      this script. Only the library and the files it needs are kept, not the app.
#   2. The PawnIO driver (by namazso, signed), which the library uses to read the sensors.
# Both downloads are pinned to one version and checked against a known SHA-256 hash, so a changed
# or damaged download is refused. Needs administrator; it asks when started without.
# Close SRRVRR first (it keeps the library open). Safe to run again: it replaces the library and
# installs PawnIO only when it's missing or older.
param(
    [switch]$NoPause,       # don't wait for a key at the end
    [string]$LogPath        # also write everything shown to this file
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is much slower with its progress bar

$lhm = @{
    Version = '0.9.6'
    Url     = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip'
    Sha256  = '086D9F1B5A99E643EDC2CFAAAC16051685B551E4C5AC0B32A57C58C0E529C001'
}
$pawnIO = @{
    Version = [version]'2.2.0'
    Url     = 'https://github.com/namazso/PawnIO.Setup/releases/download/2.2.0/PawnIO_setup.exe'
    Sha256  = '1F519A22E47187F70A1379A48CA604981C4FCF694F4E65B734AAA74A9FBA3032'
    Signer  = 'CN=namazso.eu'
}
# The app's own files; SRRVRR only needs the library.
$skip = 'LibreHardwareMonitor.exe*', 'Aga.Controls.dll', 'OxyPlot*.dll', 'Microsoft.Win32.TaskScheduler.dll'
$libDir = Join-Path $PSScriptRoot 'lib\LibreHardwareMonitor'

# --- Administrator -------------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Installing the drivers and files needs administrator; Windows will ask.'
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($NoPause) { $argList += ' -NoPause' }
    if ($LogPath) { $argList += " -LogPath `"$LogPath`"" }
    try { Start-Process powershell -Verb RunAs -ArgumentList $argList }
    catch { Write-Host 'Nothing was installed: the administrator prompt was declined.'; exit 1 }
    return
}
if ($LogPath) { Start-Transcript -LiteralPath $LogPath -Force | Out-Null }

$work = Join-Path $env:TEMP ('SRRVRR-sensors-' + [guid]::NewGuid().ToString('N'))
$ok = $false
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Downloads a file into the work folder and refuses it unless its SHA-256 hash matches.
    function Get-Pinned([string]$url, [string]$sha256) {
        $file = Join-Path $work ([IO.Path]::GetFileName($url))
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($hash -ne $sha256) { throw "$([IO.Path]::GetFileName($file)) doesn't match its known SHA-256 hash (got $hash), so it was not used." }
        Write-Host "  SHA-256 hash checked: $hash"
        $file
    }

    # --- 1. The sensor library -----------------------------------------------------
    Write-Host "[1/3] LibreHardwareMonitor sensor library $($lhm.Version)"
    $zip = Get-Pinned $lhm.Url $lhm.Sha256
    if (Test-Path -LiteralPath $libDir) {
        try { Get-ChildItem -LiteralPath $libDir -File | Remove-Item -Force }
        catch { throw "Couldn't replace the files in $libDir. Close SRRVRR (it keeps them open) and run this again." }
    } else { New-Item -ItemType Directory -Path $libDir | Out-Null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries) {
            # Top-level files only (the subfolders are translations of the app).
            if ($entry.FullName -ne $entry.Name -or -not $entry.Name) { continue }
            $keep = ($entry.Name -like '*.dll' -or $entry.Name -like 'LICENSE*') -and -not ($skip | Where-Object { $entry.Name -like $_ })
            if ($keep) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $libDir $entry.Name), $true) }
        }
    } finally { $archive.Dispose() }
    Get-ChildItem -LiteralPath $libDir -File | Unblock-File
    Write-Host "  Copied $(@(Get-ChildItem -LiteralPath $libDir -File).Count) files to $libDir"

    # --- 2. The PawnIO driver --------------------------------------------------------
    Write-Host "[2/3] PawnIO driver $($pawnIO.Version)"
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO'
    $installed = $null
    try { $installed = [version](Get-ItemProperty -LiteralPath $key -Name DisplayVersion -ErrorAction Stop).DisplayVersion } catch { }
    if ($installed -and $installed -ge $pawnIO.Version) {
        Write-Host "  Already installed (version $installed)"
    } else {
        $setup = Get-Pinned $pawnIO.Url $pawnIO.Sha256
        $sig = Get-AuthenticodeSignature -LiteralPath $setup
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike "*$($pawnIO.Signer)*") {
            throw "PawnIO_setup.exe isn't validly signed by namazso.eu ($($sig.Status)), so it was not run."
        }
        Write-Host "  Signature checked: $($sig.SignerCertificate.Subject)"
        $p = Start-Process -FilePath $setup -ArgumentList '-install', '-silent' -Wait -PassThru
        try { $installed = [version](Get-ItemProperty -LiteralPath $key -Name DisplayVersion -ErrorAction Stop).DisplayVersion } catch { }
        if (-not $installed) { throw "PawnIO setup finished (exit code $($p.ExitCode)) but PawnIO doesn't show as installed." }
        Write-Host "  Installed (version $installed)"
    }

    # --- 3. Self-test ----------------------------------------------------------------
    Write-Host '[3/3] Reading the temperatures once'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
// Lets the library find the files it needs in its own folder.
public static class SrrvrrSensorLoader {
    static string dir;
    public static void Init(string folder) {
        if (dir != null) return;
        dir = folder;
        AppDomain.CurrentDomain.AssemblyResolve += (s, e) => {
            string path = Path.Combine(dir, new AssemblyName(e.Name).Name + ".dll");
            return File.Exists(path) ? Assembly.LoadFrom(path) : null;
        };
    }
}
'@
    [SrrvrrSensorLoader]::Init($libDir)
    [void][Reflection.Assembly]::LoadFrom((Join-Path $libDir 'LibreHardwareMonitorLib.dll'))
    $computer = New-Object LibreHardwareMonitor.Hardware.Computer
    $computer.IsCpuEnabled = $true
    $computer.IsMemoryEnabled = $true
    $computer.Open()
    try {
        # The same readings SRRVRR shows: the CPU package (AMD: Tctl) and each memory stick.
        $found = 0
        foreach ($hw in $computer.Hardware) {
            $hw.Update()
            foreach ($s in $hw.Sensors) {
                if ([string]$s.SensorType -ne 'Temperature' -or $null -eq $s.Value) { continue }
                if (([string]$hw.HardwareType -eq 'Cpu' -and $s.Name -match 'Package|Tctl') -or ([string]$hw.HardwareType -eq 'Memory' -and $s.Name -match '^DIMM')) {
                    Write-Host ("  {0}, {1}: {2:0} C" -f $hw.Name, $s.Name, $s.Value)
                    $found++
                }
            }
        }
        if (-not $found) { Write-Host '  No CPU or memory temperature sensor answered. SRRVRR will show the temperature as unavailable.' }
    } finally { $computer.Close() }
    $ok = $true
    Write-Host 'Done. Restart SRRVRR to show the temperatures.'
} catch {
    Write-Host "Install stopped: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    if ($LogPath) { Stop-Transcript | Out-Null }
    if (-not $NoPause) { Write-Host 'Press Enter to close.'; [void][Console]::ReadLine() }
}
if (-not $ok) { exit 1 }
