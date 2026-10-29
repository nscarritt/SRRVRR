# Parses every PowerShell file, then compiles every literal Add-Type -TypeDefinition block with the
# .NET Framework C# compiler that Windows PowerShell 5.1's Add-Type uses (C# 5), so newer C# fails here and not
# at start. Nothing is loaded into this process. Exit code: 0 clean, 1 errors found.
param([string]$Root)

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }   # not in the param default: empty there under -File on 5.1
$Root = (Resolve-Path -LiteralPath $Root).Path
$errorsFound = 0
$compiled = 0
# Filter by extension here: -Include is ignored with -LiteralPath on Windows PowerShell 5.1.
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and $_.FullName -notmatch '\\(\.git|out|lib)\\' })

$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$references = @('System.dll', 'System.Core.dll', [psobject].Assembly.Location)

foreach ($f in $files) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErrors)
    foreach ($e in $parseErrors) {
        Write-Output ('{0}:{1}: {2}' -f $rel, $e.Extent.StartLineNumber, $e.Message)
        $errorsFound++
    }
    if ($parseErrors) { continue }

    $calls = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' }, $true)
    foreach ($call in $calls) {
        $els = $call.CommandElements
        for ($i = 1; $i -lt $els.Count - 1; $i++) {
            if ($els[$i] -is [Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'TypeDefinition') {
                $arg = $els[$i + 1]
                if ($arg -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                    Write-Output ('{0}:{1}: Add-Type block is not a literal string; not compiled' -f $rel, $arg.Extent.StartLineNumber)
                    continue
                }
                $options = New-Object System.CodeDom.Compiler.CompilerParameters
                $options.GenerateInMemory = $false
                $options.WarningLevel = 4   # what Add-Type compiles with on 5.1, where a warning is an error
                $options.OutputAssembly = Join-Path $env:TEMP ('srrvrr-parse-' + [guid]::NewGuid().ToString('n') + '.dll')
                $references | ForEach-Object { [void]$options.ReferencedAssemblies.Add($_) }
                $result = $provider.CompileAssemblyFromSource($options, $arg.Value)
                Remove-Item -LiteralPath $options.OutputAssembly -ErrorAction SilentlyContinue
                $compiled++
                # Warnings count too: Windows PowerShell 5.1's Add-Type fails on them ("Warning as Error").
                foreach ($ce in $result.Errors) {
                    # Here-string content starts on the line after the opening @'.
                    $line = $arg.Extent.StartLineNumber + $ce.Line
                    Write-Output ('{0}:{1}: C# {2}: {3} (block at line {4})' -f $rel, $line, $ce.ErrorNumber, $ce.ErrorText, $call.Extent.StartLineNumber)
                    $errorsFound++
                }
            }
        }
    }
}
Write-Output ('Files parsed: {0}, Add-Type blocks compiled: {1}, errors: {2}' -f @($files).Count, $compiled, $errorsFound)
if ($errorsFound) { exit 1 } else { exit 0 }
