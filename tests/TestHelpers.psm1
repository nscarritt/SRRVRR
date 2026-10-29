# Shared helpers for SRRVRR's Pester tests. Imported by every test file:
#   BeforeAll { Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force }
# Functions are added by the task that first needs them (see docs/plans/2026-10-29-srrvrr-core-test-plan.md, 4.1).

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-RepoRoot {
    $script:RepoRoot
}

# A fresh folder under %TEMP%\srrvrr-tests for one test; Remove-TestDataPath deletes only folders under it.
function New-TestDataPath {
    $root = Join-Path $env:TEMP 'srrvrr-tests'
    $path = Join-Path $root ([guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path (Join-Path $path 'state') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $path 'logs') | Out-Null
    $path
}

function Remove-TestDataPath([string]$Path) {
    $root = Join-Path $env:TEMP 'srrvrr-tests'
    if ($Path -and $Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

# The parsed syntax tree of a script, without running it.
function Get-ScriptAst([string]$Path) {
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw "Parse errors in ${Path}: $($errors[0].Message)" }
    $ast
}

# Runs a script file in a new Windows PowerShell 5.1 process. Returns @{ ExitCode; Output }.
function Invoke-InChildPowerShell {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 120)
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out = Join-Path $env:TEMP ("srrvrr-child-" + [guid]::NewGuid().ToString('n') + '.txt')
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $File + '" ' + ($quoted -join ' ')
    $p = Start-Process -FilePath $exe -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput $out
    $null = $p.Handle   # caches the handle, or ExitCode reads as $null after WaitForExit(timeout)
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { $p.Kill(); throw "Timed out: $File" }
    $text = if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out) } else { '' }
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    @{ ExitCode = $p.ExitCode; Output = $text }
}

Export-ModuleMember -Function Get-RepoRoot, New-TestDataPath, Remove-TestDataPath, Get-ScriptAst, Invoke-InChildPowerShell
