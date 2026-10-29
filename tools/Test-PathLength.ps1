# Fails if any file under Root would have a full path over 259 characters once installed at InstallFolder
# (Windows PowerShell 5.1 can't open longer paths without the long-path prefix).
param([string]$Root = (Split-Path -Parent $PSScriptRoot), [int]$InstallFolderLength = 40)

$Root = (Resolve-Path -LiteralPath $Root).Path
$long = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    Where-Object { ($InstallFolderLength + $_.FullName.Length - $Root.Length) -gt 259 })
foreach ($f in $long) { Write-Output "too long once installed: $($f.FullName.Substring($Root.Length))" }
Write-Output ('Paths over the limit: {0}' -f $long.Count)
if ($long.Count) { exit 1 } else { exit 0 }
