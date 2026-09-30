# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Uninstall is destructive, so the tests that matter are about what it must NOT touch
  and in what order it does the rest.

  Everything is mocked; nothing is unregistered or killed. The state directory is a
  real temp directory, because "does it actually delete the right folder" is the one
  part a mock cannot answer.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    $script:StateRoot = Join-Path ([IO.Path]::GetTempPath()) "greenroom-uninstall-$([guid]::NewGuid())"
}

AfterAll {
    if (Test-Path $script:StateRoot) { Remove-Item $script:StateRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
}

Describe 'Uninstall-GreenroomInstance' {

    BeforeEach {
        $script:InstanceDir = Join-Path $script:StateRoot 'probe'
        New-Item -ItemType Directory -Path $script:InstanceDir -Force | Out-Null
        Set-Content (Join-Path $script:InstanceDir 'config.json') '{ "workingDirectory": "C:\\probe-wd" }'
        Set-Content (Join-Path $script:InstanceDir 'watchdog.log') 'log line'

        Mock -ModuleName Greenroom Get-GreenroomStateRoot { $script:StateRoot }
        Mock -ModuleName Greenroom Get-ScheduledTask { [PSCustomObject]@{ TaskName = 'greenroom-probe' } }
        Mock -ModuleName Greenroom Stop-ScheduledTask { }
        Mock -ModuleName Greenroom Unregister-ScheduledTask { }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        # Pinned, so these do not depend on the host: whether this shell is elevated, runs
        # inside an instance, or has one of that name installed elevated.
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        Mock -ModuleName Greenroom Test-SelfElevated { $true }
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
    }

    AfterEach {
        if (Test-Path $script:StateRoot) {
            Get-ChildItem $script:StateRoot -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'unregisters the scheduled task' {
        Uninstall-GreenroomInstance -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Unregister-ScheduledTask -Times 1 -Exactly
    }

    It 'stops the watchdog, the session and the launcher' {
        Uninstall-GreenroomInstance -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 3 -Exactly
    }

    It 'removes the state directory' {
        Uninstall-GreenroomInstance -Name probe | Out-Null
        Test-Path $script:InstanceDir | Should -BeFalse
    }

    It 'keeps the state directory with -KeepState' {
        # What you want when removing an instance in order to read its logs.
        Uninstall-GreenroomInstance -Name probe -KeepState | Out-Null
        Test-Path $script:InstanceDir | Should -BeTrue
        Test-Path (Join-Path $script:InstanceDir 'watchdog.log') | Should -BeTrue
    }

    It 'reports the working directory it did NOT delete' {
        # Read from config.json BEFORE the state directory goes, or it is always null.
        (Uninstall-GreenroomInstance -Name probe).WorkingDirectory | Should -Be 'C:\probe-wd'
    }

    It 'returns a result object rather than printing prose' {
        $r = Uninstall-GreenroomInstance -Name probe
        $r.PSObject.TypeNames[0] | Should -Be 'Greenroom.UninstallResult'
        $r.Instance        | Should -Be 'probe'
        $r.TaskRemoved     | Should -BeTrue
        $r.StateRemoved    | Should -BeTrue
        $r.WatchdogStopped | Should -Be 1
    }

    It 'does nothing at all under -WhatIf' {
        Uninstall-GreenroomInstance -Name probe -WhatIf
        Should -Invoke -ModuleName Greenroom Unregister-ScheduledTask -Times 0
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Test-Path $script:InstanceDir | Should -BeTrue
    }

    It 'errors when the instance is not installed at all' {
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        { Uninstall-GreenroomInstance -Name ghost -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    It 'still cleans up when the task is already gone but state remains' {
        # Half-removed instances are real: a task can be unregistered by hand.
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        $r = Uninstall-GreenroomInstance -Name probe
        $r.TaskRemoved  | Should -BeFalse
        $r.StateRemoved | Should -BeTrue
    }

    It 'has no InstallDir or RemoveScripts parameter' {
        # Both existed only to delete copied scripts and a generated cmd shim out of a
        # bin directory. Removing the SOFTWARE is Uninstall-PSResource, and conflating
        # it with removing an INSTANCE is what made those flags necessary.
        $p = (Get-Command Uninstall-GreenroomInstance).Parameters.Keys
        $p | Should -Not -Contain 'InstallDir'
        $p | Should -Not -Contain 'RemoveScripts'
    }

    It 'accepts instances from the pipeline' {
        New-Item -ItemType Directory -Path (Join-Path $script:StateRoot 'second') -Force | Out-Null
        @('probe', 'second') | Uninstall-GreenroomInstance | Out-Null
        Should -Invoke -ModuleName Greenroom Unregister-ScheduledTask -Times 2 -Exactly
    }
}

Describe 'Uninstall-GreenroomInstance with a name that is not an instance' {
    <#
      The name becomes a path that is deleted recursively. These run against a state root
      nested one level inside the test's own temp directory, beside a sentinel file, so a
      traversal that got through would hit the sentinel -- never the real ~/.claude.
    #>

    BeforeEach {
        $script:Outer = Join-Path $script:StateRoot 'outer'
        $script:Root  = Join-Path $script:Outer 'greenroom'
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'probe') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'second') -Force | Out-Null
        Set-Content (Join-Path $script:Outer 'sentinel.txt') 'must survive'

        Mock -ModuleName Greenroom Get-GreenroomStateRoot { $script:Root }
        Mock -ModuleName Greenroom Get-ScheduledTask { }
        Mock -ModuleName Greenroom Stop-ScheduledTask { }
        Mock -ModuleName Greenroom Unregister-ScheduledTask { }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 0 }
    }

    AfterEach {
        if (Test-Path $script:Outer) { Remove-Item $script:Outer -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses <Name> before doing anything' -ForEach @(
        @{ Name = '..' }, @{ Name = '.' }, @{ Name = '*' }, @{ Name = 'pro*' }, @{ Name = '..\outer' },
        # A trailing dot is dropped by Windows, so 'probe.' would BE probe's directory.
        @{ Name = 'probe.' }
    ) {
        { Uninstall-GreenroomInstance -Name $Name -Confirm:$false } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
        Test-Path (Join-Path $script:Outer 'sentinel.txt') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'probe')  | Should -BeTrue
        Test-Path (Join-Path $script:Root 'second') | Should -BeTrue
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0 -Exactly
    }

    It 'still removes a real instance, and only it' {
        Uninstall-GreenroomInstance -Name probe -Confirm:$false | Out-Null
        Test-Path (Join-Path $script:Root 'probe')  | Should -BeFalse
        Test-Path (Join-Path $script:Root 'second') | Should -BeTrue
        Test-Path (Join-Path $script:Outer 'sentinel.txt') | Should -BeTrue
    }
}

Describe 'Uninstall-GreenroomInstance guards' {
    <#
      The guards Stop- and Restart- have. Without them, an elevated instance uninstalled
      from an unelevated shell lost its state while its task and processes -- invisible
      from here -- lived on; and the session this shell runs inside killed its own ancestor
      part-way through.
    #>
    BeforeEach {
        $script:Probe = Join-Path $script:StateRoot 'probe'
        New-Item -ItemType Directory -Path $script:Probe -Force | Out-Null
        Set-Content (Join-Path $script:Probe 'config.json') '{ "workingDirectory": "C:\\probe-wd", "elevated": true }'
        New-Item -ItemType Directory -Path (Join-Path $script:StateRoot 'second') -Force | Out-Null

        Mock -ModuleName Greenroom Get-GreenroomStateRoot { $script:StateRoot }
        Mock -ModuleName Greenroom Get-ScheduledTask { [PSCustomObject]@{ TaskName = 'greenroom-x' } }
        Mock -ModuleName Greenroom Stop-ScheduledTask { }
        Mock -ModuleName Greenroom Unregister-ScheduledTask { }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        Mock -ModuleName Greenroom Test-InstanceElevated { $true }
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { [PSCustomObject]@{ ExitCode = 0; Records = @() } }
    }

    AfterEach {
        Get-ChildItem $script:StateRoot -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'refuses the session this shell runs inside, and touches nothing' {
        Mock -ModuleName Greenroom Test-SelfIsInstance { $true }
        Uninstall-GreenroomInstance -Name probe -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null
        "$err" | Should -Match 'running inside'
        Should -Invoke -ModuleName Greenroom Unregister-ScheduledTask -Times 0
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Test-Path $script:Probe | Should -BeTrue
    }

    It 'hands an elevated instance to an elevated run, and changes nothing here' {
        Uninstall-GreenroomInstance -Name probe -Confirm:$false | Out-Null
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly `
            -ParameterFilter { $Command -eq 'Uninstall-GreenroomInstance' -and "$Name" -eq 'probe' -and -not $Forward }
        Should -Invoke -ModuleName Greenroom Unregister-ScheduledTask -Times 0
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Test-Path $script:Probe | Should -BeTrue
    }

    It 'carries -KeepState to the elevated run' {
        Uninstall-GreenroomInstance -Name probe -KeepState -Confirm:$false | Out-Null
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly -ParameterFilter { $Forward -contains 'KeepState' }
    }

    It 'removes several elevated instances in ONE elevated run' {
        'probe', 'second' | Uninstall-GreenroomInstance -Confirm:$false | Out-Null
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly -ParameterFilter { ($Name -join ',') -eq 'probe,second' }
    }

    It 'refuses under -NoElevate, and escalates nothing' {
        Uninstall-GreenroomInstance -Name probe -NoElevate -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null
        "$err" | Should -Match 'runs ELEVATED'
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
        Test-Path $script:Probe | Should -BeTrue
    }

    It 'returns what the elevated run removed, as an UninstallResult' {
        Mock -ModuleName Greenroom Invoke-ElevatedSelf {
            $r = [PSCustomObject]@{ Instance = 'probe'; TaskRemoved = $true; StateRemoved = $true }
            $r.PSObject.TypeNames.Insert(0, 'Deserialized.Greenroom.UninstallResult')
            [PSCustomObject]@{ ExitCode = 0; Records = @($r) }
        }
        $out = @(Uninstall-GreenroomInstance -Name probe -Confirm:$false)
        $out.Count | Should -Be 1
        $out[0].PSObject.TypeNames[0] | Should -Be 'Greenroom.UninstallResult'
        $out[0].StateRemoved | Should -BeTrue
    }

    It 'acts here, as before, from an elevated shell' {
        Mock -ModuleName Greenroom Test-SelfElevated { $true }
        Uninstall-GreenroomInstance -Name probe -Confirm:$false | Out-Null
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
        Should -Invoke -ModuleName Greenroom Unregister-ScheduledTask -Times 1 -Exactly
        Test-Path $script:Probe | Should -BeFalse
    }
}

Describe 'The elevated uninstall command, run for real' {
    # As for Stop-: the string Invoke-ElevatedSelf builds runs in a real child pwsh (without
    # RunAs) against a stand-in module, which records what it was called with.
    BeforeAll {
        $script:Stub = Join-Path $TestDrive 'Greenroom'
        New-Item -ItemType Directory -Force $script:Stub | Out-Null
        Set-Content -Path (Join-Path $script:Stub 'Greenroom.psm1') -Value @'
function Uninstall-GreenroomInstance {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(ValueFromPipeline)][string]$Name, [switch]$KeepState, [switch]$NoElevate)
    process {
        if (-not $NoElevate) { throw 'the elevated copy must not escalate again' }
        Add-Content -Path (Join-Path $PSScriptRoot 'acted.txt') -Value "$Name KeepState=$KeepState"
    }
}
'@
        New-ModuleManifest -Path (Join-Path $script:Stub 'Greenroom.psd1') -RootModule 'Greenroom.psm1' `
            -FunctionsToExport 'Uninstall-GreenroomInstance' -ModuleVersion '0.0.1'

        function Build([string[]]$Forward) {
            Mock -ModuleName Greenroom Start-Process { $script:Inner = $ArgumentList[-1]; [PSCustomObject]@{ ExitCode = 0 } }
            InModuleScope Greenroom -Parameters @{ Stub = $script:Stub; Sw = $Forward } {
                param($Stub, $Sw)
                $saved = $script:GreenroomModuleRoot
                $script:GreenroomModuleRoot = $Stub
                try { Invoke-ElevatedSelf -Command 'Uninstall-GreenroomInstance' -Name 'one', 'two' -Forward $Sw -WarningAction SilentlyContinue | Out-Null }
                finally { $script:GreenroomModuleRoot = $saved }
            }
            $script:Inner
        }
    }

    BeforeEach { Remove-Item (Join-Path $script:Stub 'acted.txt') -ErrorAction Ignore }

    It 'passes -KeepState through to every name' {
        pwsh -NoLogo -NoProfile -Command (Build -Forward 'KeepState') | Out-Null
        $LASTEXITCODE | Should -Be 0
        @(Get-Content (Join-Path $script:Stub 'acted.txt')) | Should -Be @('one KeepState=True', 'two KeepState=True')
    }

    It 'passes nothing extra without it' {
        pwsh -NoLogo -NoProfile -Command (Build -Forward @()) | Out-Null
        @(Get-Content (Join-Path $script:Stub 'acted.txt')) | Should -Be @('one KeepState=False', 'two KeepState=False')
    }

    It 'refuses a switch that is not a bare name' {
        { InModuleScope Greenroom { Invoke-ElevatedSelf -Command 'Uninstall-GreenroomInstance' -Name 'one' -Forward 'KeepState; Remove-Item x' } } |
            Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }
}
