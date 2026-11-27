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
        # The one deliberate change since: #48 UAT shows a missing temperature in gray, not amber.
        ($assign.Right.Expression.Value -replace "`r`n", "`n").Replace(": error ? ' warn' : none ? ' none' : '');", ": error || none ? ' none' : '');")
    }
    # The moved files put back together: the CSS and script inlined, and each /img/ URL turned back into its data URI.
    function Get-NewPage {
        # The text files as of the #48 merge (5961666), the last page before #49 changed it on purpose; images as they are.
        $read = { param($name) ((& git -C $Root show "5961666:web/$name") -join "`n") + "`n" }
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

Describe 'T50-51 banners come from server events' {
    It 'T50-51 app.js has no page-side comparison of activity left' {
        $js = [IO.File]::ReadAllText((Join-Path $Web 'app.js'))
        foreach ($name in 'lastValheim', 'plexKeys', 'watchValheim', 'watchPlex') {
            $js | Should -Not -Match $name -Because "$name compared one /stats reading with the next"
        }
        $js | Should -Match 'function bannerFor\('
    }
}

Describe 'T63-07 one time formatter' {
    It 'T63-07 app.js has no en-GB, no h23, and one Intl.DateTimeFormat call site (in fmtTime)' {
        $js = [IO.File]::ReadAllText((Join-Path $Web 'app.js'))
        $js | Should -Not -Match 'en-GB'
        $js | Should -Not -Match 'h23'
        ([regex]::Matches($js, [regex]::Escape('Intl.DateTimeFormat('))).Count | Should -Be 1
        $start = $js.IndexOf('function fmtTime(')
        $start | Should -BeGreaterThan -1
        $js.IndexOf('Intl.DateTimeFormat(') | Should -BeGreaterThan $start
        $js.IndexOf('Intl.DateTimeFormat(') | Should -BeLessThan ($start + 600)
    }
}

#region 90 Roles and the host name (#90)
Describe 'T90-13 the page''s markup for the roles' {
    BeforeAll {
        $script:Html = [IO.File]::ReadAllText((Join-Path $Web 'index.html'))
        # The opening tag of the element with this id (empty when there is none).
        function Get-OpenTag([string]$Id) { [regex]::Match($Html, '<(\w+)\b[^>]*\bid="' + [regex]::Escape($Id) + '"[^>]*>').Value }
        # The cards in <main>, in page order: each from its <section to the next (sections don't nest here).
        $main = [regex]::Match($Html, '(?s)<main>(.*)</main>').Groups[1].Value
        $script:Cards = @([regex]::Split($main, '(?=<section\b)') | Where-Object { $_ -match '^<section\b' })
        # The position of the card holding this id, or -1.
        function Get-CardIndex([string]$Id) {
            for ($i = 0; $i -lt $Cards.Count; $i++) { if ($Cards[$i] -match ('\bid="' + [regex]::Escape($Id) + '"')) { return $i } }
            -1
        }
    }
    It 'T90-13 the header is h1#host with the text SRRVRR, and the tab title is SRRVRR' {
        $Html | Should -Match '<h1\b[^>]*\bid="host"[^>]*>SRRVRR</h1>'
        $Html | Should -Match '<title>SRRVRR</title>'
    }
    It 'T90-13 <id> is a <tag> and hidden' -ForEach @(
        @{ id = 'vramCard'; tag = 'section'; class = 'card' }
        @{ id = 'aiCard'; tag = 'section'; class = 'card wide' }
        @{ id = 'topCard'; tag = 'section'; class = 'card wide' }
        @{ id = 'gpuBadge'; tag = 'span'; class = $null }
        @{ id = 'memD'; tag = 'div'; class = 'sub' }
    ) {
        $open = Get-OpenTag $id
        $open | Should -Not -BeNullOrEmpty -Because "index.html has an element with id $id"
        $open | Should -Match "^<$tag\b"
        $open | Should -Match '\shidden(?=[\s/>=])' -Because "$id starts hidden"
        if ($class) { $open | Should -Match ('\bclass="' + [regex]::Escape($class) + '"') }
    }
    It 'T90-13 vramCard is the tile between the GPU and Network tiles' {
        $gpu = Get-CardIndex 'gpuV'; $vram = Get-CardIndex 'vramCard'; $net = Get-CardIndex 'netV'
        $gpu | Should -BeGreaterThan -1
        $vram | Should -Be ($gpu + 1) -Because 'the Video memory tile comes right after the GPU tile'
        $net | Should -Be ($vram + 1) -Because 'the Network tile comes right after the Video memory tile'
    }
    It 'T90-13 aiCard, then topCard, come after the Network tile and before procCard' {
        $net = Get-CardIndex 'netV'; $ai = Get-CardIndex 'aiCard'; $top = Get-CardIndex 'topCard'; $proc = Get-CardIndex 'procCard'
        $net | Should -BeGreaterThan -1
        $ai | Should -Be ($net + 1) -Because 'the AI server card comes right after the Network tile'
        $top | Should -Be ($ai + 1) -Because 'the Top programs card comes right after the AI server card'
        $proc | Should -Be ($top + 1) -Because 'the Processes card comes right after the Top programs card'
    }
    It 'T90-13 gpuBadge is in the GPU tile''s top row, memD under memS, and vramCard holds vramV, vramBadge, vramS and the canvas vramC' {
        $gpuCard = $Cards[(Get-CardIndex 'gpuV')]
        $gpuCard.IndexOf('id="gpuBadge"') | Should -BeGreaterThan $gpuCard.IndexOf('class="top"') -Because 'gpuBadge is in the GPU tile'
        $gpuCard.IndexOf('id="gpuBadge"') | Should -BeLessThan $gpuCard.IndexOf('id="gpuS"') -Because 'gpuBadge is in the top row, above the sub line'
        $memCard = $Cards[(Get-CardIndex 'memV')]
        $memCard.IndexOf('id="memD"') | Should -BeGreaterThan $memCard.IndexOf('id="memS"') -Because 'memD is in the Memory tile, under memS'
        $memCard.IndexOf('id="memD"') | Should -BeLessThan $memCard.IndexOf('id="memC"') -Because 'memD is above the graph'
        Get-CardIndex 'vramCard' | Should -BeGreaterThan -1 -Because 'index.html has the Video memory tile'
        $vramCard = $Cards[(Get-CardIndex 'vramCard')]
        foreach ($id in 'vramV', 'vramBadge', 'vramS') { $vramCard | Should -Match ('\bid="' + $id + '"') -Because "the Video memory tile holds $id" }
        $vramCard | Should -Match '<canvas\b[^>]*\bid="vramC"' -Because 'the Video memory tile has its graph'
    }
}
#endregion 90
