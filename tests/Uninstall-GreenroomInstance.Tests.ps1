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
        @{ Name = '..' }, @{ Name = '.' }, @{ Name = '*' }, @{ Name = 'pro*' }, @{ Name = '..\outer' }
    ) {
        { Uninstall-GreenroomInstance -Name $Name -Confirm:$false } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
        Test-Path (Join-Path $script:Outer 'sentinel.txt') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'probe')  | Should -BeTrue
        Test-Path (Join-Path $script:Root 'second') | Should -BeTrue
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0 -Exactly
    }

    It 'refuses a trailing dot, which Windows resolves to another instance' {
        # 'probe.' passes the pattern; Windows drops the dot, so its path IS probe's directory.
        Uninstall-GreenroomInstance -Name 'probe.' -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null
        $err.Count | Should -Be 1
        "$($err[0])" | Should -Match 'does not name its own directory'
        Test-Path (Join-Path $script:Root 'probe') | Should -BeTrue
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0 -Exactly
    }

    It 'still removes a real instance, and only it' {
        Uninstall-GreenroomInstance -Name probe -Confirm:$false | Out-Null
        Test-Path (Join-Path $script:Root 'probe')  | Should -BeFalse
        Test-Path (Join-Path $script:Root 'second') | Should -BeTrue
        Test-Path (Join-Path $script:Outer 'sentinel.txt') | Should -BeTrue
    }
}
