# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Behaviour of Get-GreenroomInstance against faked discovery.

  Everything real here needs live sessions, WMI and windows, so the process layer is
  mocked with -ModuleName: that reaches functions private to the module, which is the
  reason to have a module boundary and still be able to test behind it.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Get-GreenroomInstance' {

    BeforeEach {
        # Two readable sessions and nothing opaque, unless a test says otherwise.
        Mock -ModuleName Greenroom Get-SessionProcess {
            @(
                [PSCustomObject]@{ Instance = 'laptop-admin'; Claude = 'fake'; Pid = 1001; Opaque = $false }
                [PSCustomObject]@{ Instance = 'render-admin'; Claude = 'fake'; Pid = 1002; Opaque = $false }
            )
        }
        Mock -ModuleName Greenroom Get-TerminalHost { [PSCustomObject]@{ ProcessId = 2001 } }
        Mock -ModuleName Greenroom Resolve-SessionWindow { [IntPtr]::new(4242) }
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
        # $null is "this shell cannot read that process's token", which is also what
        # keeps this hermetic: the real one would open pid 1001 on the host running the
        # tests, and the answer would depend on what happens to be running there.
        Mock -ModuleName Greenroom Test-SessionElevated { $null }
        Mock -ModuleName Greenroom Test-SelfElevated { $true }
        # Hermetic: without this the real Get-ScheduledTask runs, and on a host that has a
        # greenroom task by one of the names above the result would depend on the machine.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
    }

    It 'emits one object per session' {
        @(Get-GreenroomInstance).Count | Should -Be 2
    }

    It 'tags output with the Greenroom.Instance type so the format view applies' {
        (Get-GreenroomInstance)[0].PSObject.TypeNames[0] | Should -Be 'Greenroom.Instance'
    }

    # The task's RunLevel says what the NEXT start gets. Between an elevation change and
    # the restart that carries it, the two disagree, and the installer points operators
    # at this column -- so it has to be about the process they can see.
    It 'reports the token the session actually holds, not what was configured' {
        Mock -ModuleName Greenroom Test-SessionElevated { $true }
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
        (Get-GreenroomInstance)[0].Elevated | Should -BeTrue
    }

    It 'falls back to the configured value when the token cannot be read' {
        Mock -ModuleName Greenroom Test-SessionElevated { $null }
        Mock -ModuleName Greenroom Test-InstanceElevated { $true }
        (Get-GreenroomInstance)[0].Elevated | Should -BeTrue
    }

    It 'emits data, not formatted text' {
        # The bug this whole design replaces: `greenroom list` piped formatting records
        # into the next command instead of objects.
        foreach ($i in Get-GreenroomInstance) {
            $i.PSObject.TypeNames[0] | Should -Not -Match 'Microsoft\.PowerShell\.Commands\.Internal\.Format'
        }
    }

    It 'exposes the fields the format view binds to' {
        $i = (Get-GreenroomInstance)[0]
        foreach ($p in 'Instance', 'ClaudePid', 'TerminalPid', 'Window', 'Visible', 'Elevated', 'Opaque') {
            $i.PSObject.Properties.Name | Should -Contain $p
        }
    }

    It 'filters by exact name' {
        (Get-GreenroomInstance -Name 'laptop-admin').Instance | Should -Be 'laptop-admin'
    }

    It 'filters by wildcard' {
        @(Get-GreenroomInstance -Name '*-admin').Count | Should -Be 2
        @(Get-GreenroomInstance -Name 'render*').Instance | Should -Be 'render-admin'
    }

    It 'returns nothing rather than erroring when nothing matches' {
        # A Get- returning empty is not an error condition; the script it replaces
        # exited 1 here.
        { Get-GreenroomInstance -Name 'nope' -ErrorAction Stop } | Should -Not -Throw
        @(Get-GreenroomInstance -Name 'nope').Count | Should -Be 0
    }

    It 'returns nothing when no session is running' {
        Mock -ModuleName Greenroom Get-SessionProcess { @() }
        @(Get-GreenroomInstance).Count | Should -Be 0
    }

    Context 'when a window cannot be resolved' {

        BeforeEach { Mock -ModuleName Greenroom Resolve-SessionWindow { $null } }

        It 'reports Window as $null, not a string' {
            # 'unresolved' as a value makes the column uncomparable and unfilterable.
            $i = (Get-GreenroomInstance)[0]
            $i.Window | Should -BeNullOrEmpty
            $i.Window | Should -Not -BeOfType [string]
        }

        It 'still emits the instance rather than dropping it' {
            @(Get-GreenroomInstance).Count | Should -Be 2
        }

        It 'leaves Visible unset because it is unknowable' {
            (Get-GreenroomInstance)[0].Visible | Should -BeNullOrEmpty
        }
    }

    Context 'when a process is opaque' {

        BeforeEach {
            Mock -ModuleName Greenroom Get-SessionProcess {
                @([PSCustomObject]@{ Instance = '(unreadable)'; Claude = 'fake'; Pid = 1003; Opaque = $true })
            }
            Mock -ModuleName Greenroom Test-SelfElevated { $false }
        }

        It 'marks it opaque and does not guess its elevation' {
            $i = (Get-GreenroomInstance -WarningAction SilentlyContinue)[0]
            $i.Opaque   | Should -BeTrue
            $i.Elevated | Should -BeNullOrEmpty
        }

        It 'warns on the Warning stream, which a caller can suppress' {
            # Write-Host could not be suppressed, which is why it is not used.
            $warnings = @()
            Get-GreenroomInstance -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
            $warnings.Count | Should -BeGreaterThan 0
            $warnings[0].Message | Should -Match 'command line'
        }

        It 'does not warn when the shell is elevated, because nothing is opaque then' {
            Mock -ModuleName Greenroom Test-SelfElevated { $true }
            $warnings = @()
            Get-GreenroomInstance -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
            $warnings.Count | Should -Be 0
        }
    }
}
