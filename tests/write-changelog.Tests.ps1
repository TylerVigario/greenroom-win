# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  ci/write-changelog.ps1 joins a full `cog changelog` between CHANGELOG.md's hand-kept preamble
  and its hand-written first release. cog's output is passed in as text (-Generated), shaped
  like cog 7.0.0's remote template, so nothing here runs cog or needs a repository.
#>

BeforeAll {
    $script:Writer = Join-Path (Split-Path $PSScriptRoot -Parent) 'ci\write-changelog.ps1'
    $script:Url = 'https://github.com/o/r'

    function Section([string]$Tag, [string]$From, [string[]]$Body) {
        (@("## [$Tag]($script:Url/compare/$From..$Tag) - 2026-10-01") + $Body) -join "`n"
    }
    function Version([string]$Tag) { "- (**version**) $Tag - ([abc1234]($script:Url/commit/abc1234)) - bot[bot]" }
    function Cog([string[]]$Sections) { ($Sections -join "`n`n- - -`n`n") + "`n`n" }

    $script:Current = @(
        '# Changelog', '', 'Preamble kept by hand.', '', '- - -',
        '## [v0.2.0](old link) - 2026-01-01', '#### Features', '- stale entry', '',
        '- - -', '', '', '## 0.1.0', '', 'Initial release.', ''
    ) -join "`n"
    $script:Generated = Cog @(
        (Section 'v0.3.0' 'v0.2.0' @('#### Features', '- (**x**) new thing (#9)', '#### Miscellaneous Chores', (Version 'v0.3.0'))),
        (Section 'v0.2.0' 'v0.1.0' @('#### Bug Fixes', '- (**y**) a fix (#5)', '#### Miscellaneous Chores', '- tidy (#4)', (Version 'v0.2.0'))),
        (Section 'v0.1.0' 'f00ba44' @('#### Features', '- every commit since the beginning'))
    )

    function Invoke-Writer([string]$Current = $script:Current, [string]$Generated = $script:Generated) {
        $p = Join-Path $TestDrive "CHANGELOG-$([guid]::NewGuid().ToString('N')).md"
        [IO.File]::WriteAllText($p, $Current)
        & $script:Writer -Path $p -Generated $Generated | Out-Null
        $p
    }
}

Describe 'write-changelog' {

    It 'keeps the preamble and the hand-written first release, and puts cog''s releases between them' {
        $text = [IO.File]::ReadAllText((Invoke-Writer))
        $text | Should -Match '(?s)^# Changelog\n\nPreamble kept by hand\.\n\n- - -\n## \[v0\.3\.0\]'
        $text | Should -Match '(?s)- tidy \(#4\)\n\n- - -\n\n\n## 0\.1\.0\n\nInitial release\.\n$'
        $text | Should -Not -Match 'stale entry'
    }

    It 'links each release from the previous tag, as cog changelog renders it' {
        $text = [IO.File]::ReadAllText((Invoke-Writer))
        $text | Should -Match ([regex]::Escape("compare/v0.2.0..v0.3.0"))
        $text | Should -Match ([regex]::Escape("compare/v0.1.0..v0.2.0"))
    }

    It 'drops cog''s own section for the hand-written release' {
        [IO.File]::ReadAllText((Invoke-Writer)) | Should -Not -Match 'every commit since the beginning|## \[v0\.1\.0\]'
    }

    It 'drops version commits, and a heading they leave empty, but keeps a heading with other entries' {
        $text = [IO.File]::ReadAllText((Invoke-Writer))
        $text | Should -Not -Match '\(\*\*version\*\*\)'
        ([regex]::Matches($text, '#### Miscellaneous Chores')).Count | Should -Be 1
        $text | Should -Match '#### Miscellaneous Chores\n- tidy \(#4\)'
    }

    It 'writes UTF-8 without a BOM, with LF line endings, keeping non-ASCII text' {
        $gen = $script:Generated -replace 'new thing', ('new ' + [char]0x2014 + ' thing') -replace "`n", "`r`n"
        $bytes = [IO.File]::ReadAllBytes((Invoke-Writer -Generated $gen))
        $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $text | Should -Not -Match "`r"
        $text | Should -Match ('new ' + [char]0x2014 + ' thing')
    }

    It 'refuses a changelog without <Why>' -ForEach @(
        @{ Why = 'two separators'; Current = "# Changelog`n`n- - -`n## 0.1.0`n" }
        @{ Why = 'a hand-written release below the last separator'; Current = "# Changelog`n- - -`nx`n- - -`nnothing here`n" }
    ) {
        $p = Join-Path $TestDrive 'bad.md'
        [IO.File]::WriteAllText($p, $Current)
        { & $script:Writer -Path $p -Generated $script:Generated } | Should -Throw
        [IO.File]::ReadAllText($p) | Should -Be $Current
    }

    It 'refuses cog output without a section for the hand-written release' {
        $p = Join-Path $TestDrive 'short.md'
        [IO.File]::WriteAllText($p, $script:Current)
        $partial = Cog @((Section 'v0.3.0' 'v0.2.0' @('#### Features', '- x (#9)')))
        { & $script:Writer -Path $p -Generated $partial } | Should -Throw
        [IO.File]::ReadAllText($p) | Should -Be $script:Current
    }
}
