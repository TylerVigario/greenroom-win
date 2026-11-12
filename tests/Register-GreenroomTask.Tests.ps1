# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Register-GreenroomTask must not let a registration that did nothing pass as one that
  worked. That is the whole of what these test.

  THE MOCK HAS TO FAIL THE WAY THE REAL CMDLET DOES, or these prove nothing.
  Register-ScheduledTask lives in another module, so Greenroom's ErrorActionPreference of
  Stop never reaches it: `Access is denied` is NON-TERMINATING unless the call itself says
  -ErrorAction Stop. Measured 2026-11-11 on the reference host, where that let three
  instances report an upgrade their tasks never received. So the stand-in writes a
  non-terminating error unless it was handed -ErrorAction -- which is what makes the first
  test fail if the -ErrorAction Stop in the source is ever removed.

  Nothing is registered: Register-ScheduledTask and Get-ScheduledTask are both mocked. The
  New-ScheduledTask* builders run for real, and they only construct objects.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    # The path the function will expect to find in the task, computed the way it does.
    $script:Vbs = InModuleScope Greenroom { Join-Path $script:GreenroomModuleRoot 'Assets\greenroom-watchdog.vbs' }

    function TaskNaming([string]$Arguments) {
        $script:TaskArgs = $Arguments
        Mock -ModuleName Greenroom Get-ScheduledTask {
            [PSCustomObject]@{ TaskName = 'greenroom-probe'; Actions = @([PSCustomObject]@{ Arguments = $script:TaskArgs }) }
        }
    }

    function Register {
        InModuleScope Greenroom {
            Register-GreenroomTask -Name 'probe' -WorkingDirectory 'C:\probe-wd' -TriggerDelay 'PT1M' `
                -WScriptPath 'C:\Windows\System32\wscript.exe' -Elevated $false
        }
    }
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Register-GreenroomTask' {

    BeforeEach {
        Mock -ModuleName Greenroom Register-ScheduledTask { }
        TaskNaming ('"{0}" "probe"' -f $script:Vbs)
    }

    It 'stops on Access is denied, which Register-ScheduledTask does not raise by itself' {
        Mock -ModuleName Greenroom Register-ScheduledTask {
            $ea = if ($PesterBoundParameters.ContainsKey('ErrorAction')) { $PesterBoundParameters['ErrorAction'] } else { 'Continue' }
            Write-Error -Message 'Access is denied.' -ErrorAction $ea
        }
        # The task still names the OLD assets, as it did on the reference host. Were the
        # error to slip past, the read-back would throw instead -- with a different message,
        # which is how this tells the two apart.
        TaskNaming '"C:\Modules\Greenroom\0.0.1\Assets\greenroom-watchdog.vbs" "probe"'
        { Register } | Should -Throw '*Access is denied*'
    }

    It 'passes -ErrorAction Stop to Register-ScheduledTask' {
        Register
        Should -Invoke -ModuleName Greenroom Register-ScheduledTask -Times 1 -Exactly `
            -ParameterFilter { $PesterBoundParameters['ErrorAction'] -eq 'Stop' }
    }

    It 'throws when the task still names other assets after a registration that raised nothing' {
        TaskNaming '"C:\Modules\Greenroom\0.0.1\Assets\greenroom-watchdog.vbs" "probe"'
        { Register } | Should -Throw '*still names different assets*'
    }

    It 'does not blame ownership for that -- -ErrorAction Stop has already handled it' {
        TaskNaming '"C:\Modules\Greenroom\0.0.1\Assets\greenroom-watchdog.vbs" "probe"'
        { Register } | Should -Throw '*Get-ScheduledTask -TaskName greenroom-probe*'
    }

    It 'throws when the task does not exist after registration' {
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        { Register } | Should -Throw '*does not exist after registration*'
    }

    It 'returns quietly when the task names this module''s assets' {
        { Register } | Should -Not -Throw
        Should -Invoke -ModuleName Greenroom Register-ScheduledTask -Times 1 -Exactly
    }
}
