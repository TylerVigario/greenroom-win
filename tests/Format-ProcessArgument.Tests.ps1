# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  How the watchdog quotes the arguments it hands Windows Terminal. Start-Process quotes
  nothing, and a launcher path with a space in it then never ran.

  The property that matters is the round trip: whatever this produces, a Windows program
  must read back as exactly the argument that went in. So each case is checked against a
  real child process, not against an expected string.
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Assets\Format-ProcessArgument.ps1')

    # What a real Windows program receives: a child pwsh prints each argv element on a line.
    function RoundTrip([string[]]$Arguments) {
        $echo = Join-Path $TestDrive 'echo-args.ps1'
        Set-Content -LiteralPath $echo -Value '$args | ForEach-Object { "[$_]" }'
        $line = (@('-NoLogo', '-NoProfile', '-File', $echo) + @($Arguments | Format-ProcessArgument)) -join ' '
        $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path, $line)
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        @($out -split "`r?`n" | Where-Object { $_ })
    }
}

Describe 'Format-ProcessArgument' {

    It 'leaves an argument with nothing to protect exactly as it is: <A>' -ForEach @(
        @{ A = '-NoProfile' }, @{ A = 'C:\Users\x\Modules\greenroom-launch.ps1' }, @{ A = 'laptop-admin' }
    ) {
        Format-ProcessArgument $A | Should -BeExactly $A
    }

    It 'round-trips <Why>' -ForEach @(
        @{ Why = 'a path with a space';           A = 'C:\Users\Jane Doe\Documents\PowerShell\Modules\Greenroom\0.7.0\Assets\greenroom-launch.ps1' }
        @{ Why = 'a OneDrive folder';             A = 'C:\Users\x\OneDrive - Contoso\Documents\a.ps1' }
        @{ Why = 'a trailing backslash';          A = 'C:\Program Files\dir\' }
        @{ Why = 'backslashes before a quote';    A = 'a\\"b c' }
        @{ Why = 'an embedded quote';             A = 'say "hi" there' }
        @{ Why = 'a tab';                         A = "a`tb" }
    ) {
        RoundTrip @($A) | Should -Be @("[$A]")
    }

    It 'keeps separate arguments separate' {
        RoundTrip @('C:\a b\x.ps1', '-Instance', 'probe') | Should -Be @('[C:\a b\x.ps1]', '[-Instance]', '[probe]')
    }
}
