# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Version drift between the module loaded in this session and the assets an instance's
  task actually runs.

  This exists because the drift is otherwise invisible and reads as a successful upgrade:
  the task hard-codes the VERSIONED asset path, so staging a new module and restarting
  brings the old supervisor back up while Get-Module reports the new version. Measured on
  two hosts before it was noticed at all.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    function FakeTask {
        param([string]$Arguments)
        [PSCustomObject]@{ Actions = @([PSCustomObject]@{ Arguments = $Arguments }) }
    }
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Get-InstanceAssetVersion' {

    It 'reads the version out of the task action' {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            FakeTask '"C:\Users\x\Documents\PowerShell\Modules\Greenroom\0.1.0\Assets\greenroom-watchdog.vbs" "probe"'
        }
        InModuleScope Greenroom { Get-InstanceAssetVersion -Name probe } | Should -Be ([version]'0.1.0')
    }

    It 'reads a forward-slash path too' {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            FakeTask '"C:/Users/x/Documents/PowerShell/Modules/Greenroom/1.2.3/Assets/greenroom-watchdog.vbs" "probe"'
        }
        InModuleScope Greenroom { Get-InstanceAssetVersion -Name probe } | Should -Be ([version]'1.2.3')
    }

    It 'is null when there is no task' {
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        InModuleScope Greenroom { Get-InstanceAssetVersion -Name probe } | Should -BeNullOrEmpty
    }

    It 'is null when the path carries no version, rather than guessing' {
        # A module copied onto the module path by hand need not sit in a versioned
        # directory. Unknown must not be reported as drift -- a false alarm here would
        # train the operator to ignore the real one.
        Mock -ModuleName Greenroom Get-ScheduledTask {
            FakeTask '"C:\Users\x\Documents\PowerShell\Modules\Greenroom\Assets\greenroom-watchdog.vbs" "probe"'
        }
        InModuleScope Greenroom { Get-InstanceAssetVersion -Name probe } | Should -BeNullOrEmpty
    }
}

Describe 'drift reporting' {

    BeforeEach {
        Mock -ModuleName Greenroom Get-SessionProcess {
            @([PSCustomObject]@{ Instance = 'probe'; Claude = 'fake'; Pid = 1001; Opaque = $false })
        }
        Mock -ModuleName Greenroom Get-TerminalHost { [PSCustomObject]@{ ProcessId = 2001 } }
        Mock -ModuleName Greenroom Resolve-SessionWindow { [IntPtr]::new(4242) }
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
        Mock -ModuleName Greenroom Test-SelfElevated { $true }
    }

    It 'warns when the task runs a different version than the loaded module' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Get-GreenroomInstance -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        "$w" | Should -Match 'Install-GreenroomInstance'
    }

    It 'says nothing when the versions agree' {
        $v = InModuleScope Greenroom { $script:GreenroomModuleVersion }
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $v }.GetNewClosure()
        Get-GreenroomInstance -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        "$w" | Should -BeNullOrEmpty
    }

    It 'says nothing when the version is unknown' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
        Get-GreenroomInstance -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        "$w" | Should -BeNullOrEmpty
    }

    It 'carries the running version on the object' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        (Get-GreenroomInstance -WarningAction SilentlyContinue).AssetVersion | Should -Be ([version]'0.0.1')
    }

    It 'shows AssetVersion in the default table, not only on the object' {
        # Computed and left off the table, it was the answer to "did the update take" that
        # nobody saw without Format-List.
        $view = Get-FormatData -TypeName 'Greenroom.Instance'
        $view.FormatViewDefinition[0].Control.Headers.Label | Should -Contain 'AssetVersion'
    }
}
