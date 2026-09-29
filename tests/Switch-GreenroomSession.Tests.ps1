# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Switch-GreenroomSession decides a direction and then acts, so the tests that matter
  are about WHICH direction and WHEN the decision is made.

  The stale-read case is the reason Test-WindowVisible exists as a private wrapper at
  all: Pester cannot mock a static .NET method, so with the P/Invoke called inline
  there would be no way to prove the read happens at the point of decision rather than
  during discovery.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Switch-GreenroomSession' {

    BeforeEach {
        # .Visible is deliberately set to a value that DISAGREES with what
        # Test-WindowVisible reports, so any test that passes by reading the cached
        # property instead of taking a fresh read will fail.
        Mock -ModuleName Greenroom Resolve-GreenroomTarget {
            [PSCustomObject]@{
                PSTypeName = 'Greenroom.Instance'
                Instance   = 'probe'; ClaudePid = 1001; TerminalPid = 2001
                Window     = [IntPtr]::new(4242)
                Visible    = $true          # stale on purpose
                Elevated   = $false; Opaque = $false
            }
        }
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $true }
        Mock -ModuleName Greenroom Set-WindowVisible { $true }
        Mock -ModuleName Greenroom Get-WindowFailureReason { 'mocked failure reason' }
        Mock -ModuleName Greenroom Test-WindowVisible { $false }   # actually hidden

        # Pinned, so these tests do not depend on whether the host shell is elevated or has
        # an instance of that name installed.
        Mock -ModuleName Greenroom Test-SelfElevated { $true }
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
    }

    It 'shows a hidden window' {
        Switch-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly `
            -ParameterFilter { $Show -eq $true }
    }

    It 'hides a visible window' {
        Mock -ModuleName Greenroom Test-WindowVisible { $true }
        Switch-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly `
            -ParameterFilter { $Show -eq $false }
    }

    It 'reads visibility fresh rather than trusting the resolved object' {
        # The mocked target says Visible = $true while the window is actually hidden.
        # Acting on the cached value would hide an already-hidden window, which is the
        # bug the script it replaces could hit: it read IsWindowVisible once near the
        # top and acted on that value later.
        Switch-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Test-WindowVisible -Times 1 -Exactly
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly `
            -ParameterFilter { $Show -eq $true }
    }

    It 'decides a direction locally but acts on nothing when escalation handled it' {
        # The ordering changed deliberately: ShouldProcess now gates BEFORE escalation,
        # so -WhatIf never escalates and -Confirm prompts in the shell the operator typed
        # in rather than in an elevated window they may never look at. A consequence is
        # that visibility is read before the escalation check rather than after.
        #
        # That is NOT a staleness regression. When escalation happens the elevated copy
        # re-runs the whole command and takes its own fresh read, so this value is
        # discarded rather than acted on -- which is what the second assertion pins.
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $false }
        Switch-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Test-WindowVisible -Times 1 -Exactly
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 0
    }

    It 'performs nothing under -WhatIf' {
        Switch-GreenroomSession -Name probe -WhatIf
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 0
    }

    It 'still decides a direction under -WhatIf so the message can name it' {
        Switch-GreenroomSession -Name probe -WhatIf
        Should -Invoke -ModuleName Greenroom Test-WindowVisible -Times 1 -Exactly
    }

    It 'is silent on success' {
        Switch-GreenroomSession -Name probe | Should -BeNullOrEmpty
    }

    It 'requires a resolved window' {
        Switch-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Resolve-GreenroomTarget -Times 1 -Exactly `
            -ParameterFilter { $RequireWindow -eq $true }
    }

    It 'does nothing when the target cannot be resolved' {
        Mock -ModuleName Greenroom Resolve-GreenroomTarget { $null }
        Switch-GreenroomSession -Name nope
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 0
        Should -Invoke -ModuleName Greenroom Test-WindowVisible -Times 0
    }

    It 'errors when the window did not change state' {
        Mock -ModuleName Greenroom Set-WindowVisible { $false }
        { Switch-GreenroomSession -Name probe -ErrorAction Stop } | Should -Throw
    }

    It 'accepts a Greenroom.Instance from the pipeline' {
        [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe' } | Switch-GreenroomSession
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly
    }

    It 'switches each item piped in' {
        'a', 'b', 'c' | Switch-GreenroomSession
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 3 -Exactly
    }
}
