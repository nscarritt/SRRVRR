# The page moved out of SRRVRR.ps1 into web\ (spec section 1) with nothing else changed.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $script:Root = Get-RepoRoot
    $script:Web = Join-Path $Root 'web'
    $script:ExportBlock = '(?s)\n// For tests under Node.*$'

    # The page as it was before the move: the $html here-string in SRRVRR.ps1 at the last commit before #47
    # (#46, the 'No sensor' change, which v0.6.0 doesn't have). A fixed commit, so the test still works after the merge.
    function Get-OldPage {
        $source = (& git -C $Root show '0b5a25ba68be9db8dc27548af0d3a5d97d2a5735:SRRVRR.ps1') -join "`n"
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $assign = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$html' }, $true)
        $assign.Right.Expression.Value -replace "`r`n", "`n"
    }
    # The new files put back together: the CSS and script inlined, and each /img/ URL turned back into its data URI.
    function Get-NewPage {
        $read = { param($name) [IO.File]::ReadAllText((Join-Path $Web $name)) -replace "`r`n", "`n" }
        $css = [regex]::Replace((& $read 'style.css'), 'url\(/img/([a-z0-9-]+)\.(svg|png)\)', {
            param($m)
            $type = if ($m.Groups[2].Value -eq 'svg') { 'image/svg+xml' } else { 'image/png' }
            $bytes = [IO.File]::ReadAllBytes((Join-Path $Web "img\$($m.Groups[1].Value).$($m.Groups[2].Value)"))
            "url(data:$type;base64,$([Convert]::ToBase64String($bytes)))"
        })
        $js = (& $read 'app.js') -replace $ExportBlock, "`n"
        $html = & $read 'index.html'
        $html = $html.Replace('<link rel="stylesheet" href="/style.css">' + "`n", "<style>`n$css</style>`n")
        $html.Replace('<script src="/app.js"></script>' + "`n", "<script>`n$js</script>`n").TrimEnd("`n")
    }
}

Describe 'T47-19 the page is unchanged by the move' {
    It 'T47-19 index.html, style.css, app.js and the images put back together equal the old page exactly' {
        $old = Get-OldPage
        $new = Get-NewPage
        $old.Length | Should -BeGreaterThan 10000
        if ($new -ne $old) {
            $i = 0; while ($i -lt [Math]::Min($old.Length, $new.Length) -and $old[$i] -eq $new[$i]) { $i++ }
            $at = [Math]::Max(0, $i - 40)
            "first difference at character ${i}: old '$($old.Substring($at, [Math]::Min(80, $old.Length - $at)))' new '$($new.Substring($at, [Math]::Min(80, $new.Length - $at)))'" | Should -BeNullOrEmpty
        }
    }
    It 'T47-19 SRRVRR.ps1 no longer holds the page, and the page declares UTF-8' {
        [IO.File]::ReadAllText((Join-Path $Root 'SRRVRR.ps1')) | Should -Not -Match '\$html\s*='
        [IO.File]::ReadAllText((Join-Path $Web 'index.html')) | Should -Match '<meta charset="utf-8">'
    }
    It 'T47-19 every image the CSS names exists and has an allowed name' {
        $css = [IO.File]::ReadAllText((Join-Path $Web 'style.css'))
        $names = @([regex]::Matches($css, 'url\(/img/([^)]+)\)') | ForEach-Object { $_.Groups[1].Value })
        $names.Count | Should -BeGreaterThan 0
        foreach ($n in $names) {
            $n | Should -Match '^[a-z0-9-]+\.(svg|png)$'
            Test-Path (Join-Path $Web "img\$n") | Should -BeTrue -Because $n
        }
        $css | Should -Not -Match 'url\(data:'
    }
}
