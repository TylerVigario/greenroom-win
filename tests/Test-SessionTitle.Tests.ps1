# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Which windows the watchdog treats as a dead session's and closes.

  The watchdog posts WM_CLOSE to every Windows Terminal window this matches, so the cases
  that matter most are the ones it must NOT match: another instance whose name ends in
  this one's, and ordinary shell tabs whose title ends in the instance name.

  Hermetic: the helper is dot-sourced exactly the way greenroom-watchdog.ps1 dot-sources
  it. Glyphs are built from code points, because Windows PowerShell 5.1 reads a BOM-less
  test file as ANSI.
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Assets\Test-SessionTitle.ps1')
    $script:G  = [string][char]0x25D0        # measured on the reference host
    $script:G2 = [string][char]0x2733        # another spinner glyph
    $script:Wide = [char]::ConvertFromUtf32(0x1F7E0)   # outside the BMP: two UTF-16 units
}

Describe 'Test-SessionTitle' {

    It 'matches the session title <Title>' -ForEach @(
        @{ Title = 'G laptop-admin'; Instance = 'laptop-admin' }
        @{ Title = 'G2 admin';       Instance = 'admin' }
        @{ Title = 'Wide admin';     Instance = 'admin' }
        @{ Title = 'G v1.2';         Instance = 'v1.2' }
    ) {
        $t = $Title -replace '^Wide', $script:Wide -replace '^G2', $script:G2 -replace '^G', $script:G
        Test-SessionTitle -Title $t -Instance $Instance | Should -BeTrue
    }

    It 'does not match <Why>' -ForEach @(
        @{ Why = 'another instance ending in this name'; Title = 'G laptop-admin'; Instance = 'admin' }
        @{ Why = 'a Git Bash tab in ~\<name>';           Title = 'MINGW64:/c/Users/x/admin'; Instance = 'admin' }
        @{ Why = 'a prompt titled with the cwd leaf';    Title = 'admin'; Instance = 'admin' }
        @{ Why = 'a tab titled with a path';             Title = 'C:\Users\x\admin'; Instance = 'admin' }
        @{ Why = 'an ASCII first character';             Title = '* admin'; Instance = 'admin' }
        @{ Why = 'text after the name';                  Title = 'G admin (2)'; Instance = 'admin' }
        @{ Why = 'a longer glyph run';                   Title = 'GGG admin'; Instance = 'admin' }
        @{ Why = 'a dot in the name used as a wildcard'; Title = 'G v1x2'; Instance = 'v1.2' }
        @{ Why = 'an empty title';                       Title = ''; Instance = 'admin' }
    ) {
        $t = $Title -replace '^GGG', ($script:G * 3) -replace '^G', $script:G
        Test-SessionTitle -Title $t -Instance $Instance | Should -BeFalse
    }
}
