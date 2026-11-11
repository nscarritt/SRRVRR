# Records one sample of the SMB session list, open-file list and share list for the test fixtures, with every name,
# address, account and path replaced before anything is written. The owner runs it once, as administrator, on the
# server while a PC has files open on a share. It writes three JSON files to -OutFolder (never inside the repo) and
# compares their key shapes with tests\fixtures\transfers\cim\.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Export-TransferSample.ps1 [-OutFolder <folder>]
# -FromFolder reads sessions.json, openfiles.json and shares.json from a folder instead of the machine (for the
# tool's own tests), and then needs no administrator. Exit code: 0 written, 2 refused.
param(
    [string]$OutFolder = (Join-Path $env:TEMP 'srrvrr-transfer-sample'),
    [string]$FromFolder
)

$root = Split-Path -Parent $PSScriptRoot
# ConvertFrom-Json hands a whole array over as one object in 5.1: assign it first, then unroll it.
function Read-JsonList([string]$Path) { $list = ConvertFrom-Json ([IO.File]::ReadAllText($Path)); @($list) }
$fixtures = Join-Path $root 'tests\fixtures\transfers\cim'

$outFull = [IO.Path]::GetFullPath($OutFolder).TrimEnd('\')
if ($outFull -eq $root.TrimEnd('\') -or $outFull.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "Nothing was written: $outFull is inside the SRRVRR repo. Choose a folder outside it with -OutFolder."
    exit 2
}

if ($FromFolder) {
    $sessions = @(Read-JsonList (Join-Path $FromFolder 'sessions.json'))
    $files = @(Read-JsonList (Join-Path $FromFolder 'openfiles.json'))
    $shares = @(Read-JsonList (Join-Path $FromFolder 'shares.json'))
} else {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host 'This tool reads the SMB session and open-file lists, which need administrator. Open PowerShell as administrator and run it again.'
        exit 2
    }
    Import-Module -Name (Join-Path $root 'modules\Settings.psm1') -Force
    Import-Module -Name (Join-Path $root 'modules\DataFolder.psm1') -Force
    $sessions = @(Get-SmbSessionList)
    $files = @(Get-SmbOpenFileList)
    $shares = @(Get-ShareList)
}

# The same real thing always becomes the same made-up thing, so folders still nest and sessions still match.
$addressMap = @{}; $accountMap = @{}; $partMap = @{}; $driveMap = @{}; $shareMap = @{}
function Get-Mapped([hashtable]$Map, [string]$Real, [scriptblock]$Make) {
    $k = $Real.ToLowerInvariant()
    if (-not $Map.ContainsKey($k)) { $Map[$k] = & $Make ($Map.Count + 1) }
    $Map[$k]
}
function Convert-Address([string]$Real) {
    if (-not $Real) { return $Real }
    $text = ($Real.Trim() -replace '^\[|\]$', '') -replace '%.*$', ''
    $ip = $null
    $v6 = [Net.IPAddress]::TryParse($text, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetworkV6' -and -not $ip.IsIPv4MappedToIPv6
    # A host name or anything else that isn't an address is replaced too, as an address.
    Get-Mapped $addressMap ($(if ($ip -and $ip.IsIPv4MappedToIPv6) { $ip.MapToIPv4().ToString() } else { $text })) { param($n) if ($v6) { "2001:db8::$n" } else { "192.0.2.$($n + 9)" } }
}
function Convert-Account([string]$Real) {
    if (-not $Real) { return $Real }
    Get-Mapped $accountMap $Real { param($n) "TESTLAB\user-$n" }
}
function Convert-Part([string]$Real) { Get-Mapped $partMap $Real { param($n) "folder-$n" } }
# A path with its drive letter and every part replaced; the last part of a file path becomes file-N.
function Convert-PcPath([string]$Real, [bool]$IsFile) {
    if (-not $Real) { return $Real }
    $drive = ''
    if ($Real -match '^([A-Za-z]):\\?(.*)$') {
        $letter = $Matches[1].ToUpperInvariant(); $rest = $Matches[2]
        $drive = (Get-Mapped $driveMap $letter { param($n) [string][char](67 + $n) }) + ':\'
    } else { $rest = $Real.TrimStart('\') }
    $parts = @($rest.Split('\') | Where-Object { $_ })
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($IsFile -and $i -eq $parts.Count - 1) { $out.Add((Get-Mapped $partMap ('file:' + $parts[$i]) { param($n) "file-$n" })) }
        else { $out.Add((Convert-Part $parts[$i])) }
    }
    $drive + ($out -join '\')
}
function Convert-ShareName([string]$Real) {
    if (-not $Real -or $Real -eq 'IPC$') { return $Real }
    $suffix = if ($Real.EndsWith('$')) { '$' } else { '' }
    Get-Mapped $shareMap $Real { param($n) "share-$n$suffix" }
}

# Shares first: they define the folders the open files nest in.
$outShares = @($shares | ForEach-Object { [pscustomobject]@{ Name = (Convert-ShareName ([string]$_.Name)); Path = (Convert-PcPath ([string]$_.Path) $false); Type = [long]$_.Type } })
$outSessions = @($sessions | ForEach-Object {
    [pscustomobject]@{ SessionId = [string]$_.SessionId; ClientComputerName = (Convert-Address ([string]$_.ClientComputerName)); ClientUserName = (Convert-Account ([string]$_.ClientUserName)); Dialect = [string]$_.Dialect }
})
$outFiles = @($files | ForEach-Object {
    [pscustomobject]@{
        SessionId = [string]$_.SessionId; Path = (Convert-PcPath ([string]$_.Path) $true); ShareRelativePath = (Convert-PcPath ([string]$_.ShareRelativePath) $true)
        Permissions = [long]$_.Permissions; Signed = [bool]$_.Signed; Encrypted = [bool]$_.Encrypted
    }
})

New-Item -ItemType Directory -Force -Path $outFull | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$lists = @(@('sessions.json', $outSessions), @('openfiles.json', $outFiles), @('shares.json', $outShares))
foreach ($l in $lists) {
    $json = if ($l[1].Count) { ConvertTo-Json -InputObject @($l[1]) -Depth 4 } else { '[]' }
    [IO.File]::WriteAllText((Join-Path $outFull $l[0]), $json, $utf8)
}
Write-Host "Wrote $($lists.Count) files to $outFull (names, addresses, accounts and paths replaced)."

# Do the recorded records have the keys the fixtures have?
$same = $true
foreach ($l in $lists) {
    $fixturePath = Join-Path $fixtures $l[0]
    if (-not (Test-Path -LiteralPath $fixturePath) -or -not $l[1].Count) { continue }
    $fx = @(Read-JsonList $fixturePath)
    $want = @($fx[0].PSObject.Properties.Name | Sort-Object)
    $have = @($l[1][0].PSObject.Properties.Name | Sort-Object)
    if (($want -join ',') -ne ($have -join ',')) { $same = $false; Write-Host "Key shapes differ for $($l[0]): fixtures have $($want -join ', '); the sample has $($have -join ', ')." }
}
if ($same) { Write-Host 'Key shapes match the fixtures.' }
exit 0
