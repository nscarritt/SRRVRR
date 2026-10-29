# Lists every non-ASCII byte in PowerShell and batch files, and every .bat file that isn't CRLF.
# Windows PowerShell 5.1 reads scripts without a BOM as ANSI, so code files stay pure ASCII; web\ may be UTF-8.
# Exit code: 0 clean, 1 problems found.
param([string]$Root)

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }   # not in the param default: empty there under -File on 5.1
$Root = (Resolve-Path -LiteralPath $Root).Path
$problems = 0
# Filter by extension here: -Include is ignored with -LiteralPath on Windows PowerShell 5.1.
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.bat' -and $_.FullName -notmatch '\\(\.git|web|out|lib)\\' })
foreach ($f in $files) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $line = 1; $col = 1
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -gt 127) {
            Write-Output ('{0}:{1}:{2}: non-ASCII byte 0x{3:X2}' -f $rel, $line, $col, $b)
            $problems++
        }
        if ($b -eq 10) {
            if ($f.Extension -eq '.bat' -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) {
                Write-Output ('{0}:{1}: line ends with LF only; .bat files must be CRLF' -f $rel, $line)
                $problems++
            }
            $line++; $col = 1
        } else { $col++ }
    }
}
Write-Output ('Files checked: {0}, problems: {1}' -f @($files).Count, $problems)
if ($problems) { exit 1 } else { exit 0 }
