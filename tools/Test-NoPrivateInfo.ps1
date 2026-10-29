# Scans tracked files for details that must not be published: IPv4 addresses outside private, loopback and
# documentation ranges, UNC paths, e-mail addresses other than GitHub noreply, and any word in a local deny list
# ($env:SRRVRR_DENYLIST, ';'-separated, or .git\info\private-words.txt, one per line; never committed).
# Exit code: 0 clean, 1 findings.
param([string]$Root, [string[]]$Path)

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }   # not in the param default: empty there under -File on 5.1
$Root = (Resolve-Path -LiteralPath $Root).Path
# powershell -File passes a list as one comma-separated string.
if ($Path) { $Path = @($Path | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
else { $Path = @(& git -C $Root ls-files) }

$deny = @()
if ($env:SRRVRR_DENYLIST) { $deny += $env:SRRVRR_DENYLIST -split ';' }
$localList = Join-Path $Root '.git\info\private-words.txt'
if (Test-Path -LiteralPath $localList) { $deny += Get-Content -LiteralPath $localList }
$deny = @($deny | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

function Test-PublicIPv4([string]$ip) {
    $o = @($ip.Split('.') | ForEach-Object { [int]$_ })
    if ($o | Where-Object { $_ -gt 255 }) { return $false }
    if ($o[0] -in 0, 10, 127) { return $false }
    if ($o[0] -eq 169 -and $o[1] -eq 254) { return $false }
    if ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) { return $false }
    if ($o[0] -eq 192 -and $o[1] -eq 168) { return $false }
    if ("$($o[0]).$($o[1]).$($o[2])" -in '192.0.2', '198.51.100', '203.0.113') { return $false }
    if ($o[0] -ge 224) { return $false }
    $true
}

# Global unicast (2000::/3) outside the documentation block 2001:db8::/32; private, link-local and loopback pass. private-check: allow
function Test-PublicIPv6([string]$Text) {
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Text, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetworkV6') { return $false }
    $b = $ip.GetAddressBytes()
    if (($b[0] -band 0xE0) -ne 0x20) { return $false }
    -not ($b[0] -eq 0x20 -and $b[1] -eq 0x01 -and $b[2] -eq 0x0D -and $b[3] -eq 0xB8)
}

$findings = 0
foreach ($p in $Path) {
    $full = Join-Path $Root $p
    foreach ($w in $deny) {
        if ($p.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Write-Output "${p}: a word from the private deny list in the file name"; $findings++ }
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    if ($p -match '\.(png|jpg|ico|zip|dll)$') { continue }
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($full)) {
        $n++
        # A line marked 'private-check: allow' is a deliberate public test address; only the address checks skip it.
        if ($line -notmatch 'private-check: allow') {
            foreach ($m in [regex]::Matches($line, '\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b')) {
                if (Test-PublicIPv4 $m.Value) { Write-Output "${p}:${n}: public IPv4 address $($m.Value)"; $findings++ }
            }
            foreach ($m in [regex]::Matches($line, '(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])')) {
                if (Test-PublicIPv6 $m.Value) { Write-Output "${p}:${n}: public IPv6 address $($m.Value)"; $findings++ }
            }
        }
        if ($line -match '(?<![\w"''`])\\\\[A-Za-z0-9_.-]+\\[A-Za-z0-9_$ .-]+') { Write-Output "${p}:${n}: UNC path"; $findings++ }
        # A real profile folder names a person; placeholders like C:\Users\<name> and %USERPROFILE% are fine.
        if ($line -match '\b[A-Za-z]:\\Users\\(?!<|Public\\|Default\\)[^\\\s<>"''`]+') { Write-Output "${p}:${n}: user profile path"; $findings++ }
        foreach ($m in [regex]::Matches($line, '[\w.+-]+@[\w-]+\.[\w.-]+')) {
            if ($m.Value -notmatch '@users\.noreply\.github\.com$|@anthropic\.com$') { Write-Output "${p}:${n}: e-mail address"; $findings++ }
        }
        foreach ($w in $deny) {
            if ($line.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Write-Output "${p}:${n}: a word from the private deny list"; $findings++ }
        }
    }
}
Write-Output ('Files scanned: {0}, findings: {1}, deny-list words: {2}' -f @($Path).Count, $findings, $deny.Count)
if ($findings) { exit 1 } else { exit 0 }
