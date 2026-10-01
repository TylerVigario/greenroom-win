# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Update-GreenroomInstance moves instances onto the loaded module version.

  Everything it does is delegated -- Install- rewrites the task and config, Restart- brings
  the session back -- so what is worth testing is the DECIDING: which instances it picks,
  which it leaves alone, and that it never acts under -WhatIf.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force
    $script:Loaded = InModuleScope Greenroom { $script:GreenroomModuleVersion }
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Update-GreenroomInstance' {

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            @(
                [PSCustomObject]@{ TaskName = 'greenroom-alpha' }
                [PSCustomObject]@{ TaskName = 'greenroom-beta' }
            )
        }
        Mock -ModuleName Greenroom Install-GreenroomInstance { }
        Mock -ModuleName Greenroom Get-MissingClaudeExe { $null }
        Mock -ModuleName Greenroom Restart-GreenroomSession { }
        # alpha is behind, beta is current. $script:Loaded, not $script:GreenroomModuleVersion:
        # a mock body runs in THIS file's scope, where the module's variable is $null -- which
        # made beta read as Unversioned, and the test passed for the wrong reason.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion {
            if ($Name -eq 'alpha') { [version]'0.0.1' } else { $script:Loaded }
        }
    }

    It 'updates only the instance that is behind' {
        Update-GreenroomInstance
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'alpha' }
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0 `
            -ParameterFilter { $Name -eq 'beta' }
    }

    It 're-registers without starting, then restarts' {
        # -NoStart matters: Install- would otherwise launch a session that Restart- then
        # kills, and the launch is the expensive half.
        Update-GreenroomInstance
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $NoStart }
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'alpha' }
    }

    It 'touches nothing under -WhatIf' {
        Update-GreenroomInstance -WhatIf
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 0
    }

    It 're-registers everything under -Force' {
        Update-GreenroomInstance -Force
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 2 -Exactly
    }

    It 'honours -Name' {
        Update-GreenroomInstance -Name 'bet*' -Force
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'beta' }
    }

    It 'does not restart under -NoRestart' {
        Update-GreenroomInstance -NoRestart
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 0
    }

    It 'leaves an unversioned path alone -- there is nothing to move' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
        Update-GreenroomInstance
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0
    }

    It 'warns rather than silently doing nothing when no instance matches' {
        Update-GreenroomInstance -Name 'nope' -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'no registered instance matches'
    }

    It 'warns when the host has no instances at all' {
        Mock -ModuleName Greenroom Get-ScheduledTask { @() }
        Update-GreenroomInstance -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'no greenroom instances'
    }

    It 'carries on to the next instance when one fails to re-register' {
        # A declined elevation on one instance must not strand the rest of the host.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Install-GreenroomInstance {
            if ($Name -eq 'alpha') { throw 'elevation declined' }
        }
        Update-GreenroomInstance -ErrorAction SilentlyContinue -ErrorVariable e
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'beta' }
        "$e" | Should -Match 'alpha'
    }

    It 'carries on with NO -ErrorAction supplied, which is the real default' {
        # The test above passes -ErrorAction SilentlyContinue, and that alone made it pass:
        # the module sets $ErrorActionPreference = 'Stop', so a bare Write-Error is
        # TERMINATING and aborted the loop at the first failure. Every later instance was
        # left on the old version. This is the case that caught it.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Install-GreenroomInstance {
            if ($Name -eq 'alpha') { throw 'elevation declined' }
        }
        Update-GreenroomInstance 2>$null
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'beta' }
    }

    It 'does not restart an instance whose re-registration failed' {
        Mock -ModuleName Greenroom Install-GreenroomInstance { throw 'nope' }
        Update-GreenroomInstance -ErrorAction SilentlyContinue
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 0
    }
}

Describe 'Update-GreenroomInstance results' {

    # One row per matching instance, including those left alone. "Already current" used to
    # be verbose-only, so a run that changed nothing and a run that moved everything looked
    # the same at the prompt -- and whether it moved them is the whole question.

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            @(
                [PSCustomObject]@{ TaskName = 'greenroom-alpha' }
                [PSCustomObject]@{ TaskName = 'greenroom-beta' }
            )
        }
        Mock -ModuleName Greenroom Install-GreenroomInstance { }
        Mock -ModuleName Greenroom Get-MissingClaudeExe { $null }
        Mock -ModuleName Greenroom Restart-GreenroomSession {
            [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = $Name; ClaudePid = 4242 }
        }
        Mock -ModuleName Greenroom Get-InstanceAssetVersion {
            if ($Name -eq 'alpha') { [version]'0.0.1' } else { $script:Loaded }
        }
    }

    It 'reports the moved instance as Updated, and the current one as Current' {
        $r = @(Update-GreenroomInstance)
        $r.Count | Should -Be 2
        $r | ForEach-Object { $_.PSObject.TypeNames[0] | Should -Be 'Greenroom.UpdateResult' }

        $a = $r | Where-Object Instance -eq 'alpha'
        $a.Action    | Should -Be 'Updated'
        $a.From      | Should -Be ([version]'0.0.1')
        $a.To        | Should -Be $script:Loaded
        $a.ClaudePid | Should -Be 4242

        $b = $r | Where-Object Instance -eq 'beta'
        $b.Action | Should -Be 'Current'
        $b.From   | Should -Be $script:Loaded
    }

    It 'passes no instance rows through -- the restart is folded into the result' {
        # Two object types in one pipeline render as one table with the wrong columns.
        $r = @(Update-GreenroomInstance)
        @($r | Where-Object { $_.PSObject.TypeNames[0] -eq 'Greenroom.Instance' }).Count | Should -Be 0
    }

    It 'reports Registered, not Updated, under -NoRestart' {
        # The task names the new assets, but the session running now is still the old code.
        (@(Update-GreenroomInstance -NoRestart) | Where-Object Instance -eq 'alpha').Action | Should -Be 'Registered'
    }

    It 'reports Unversioned for a path carrying no version' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
        @(Update-GreenroomInstance).Action | Should -Be @('Unversioned', 'Unversioned')
    }

    It 'reports Failed alongside the error, and still reports the rest' {
        Mock -ModuleName Greenroom Install-GreenroomInstance { if ($Name -eq 'alpha') { throw 'nope' } }
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        $r = @(Update-GreenroomInstance -ErrorAction SilentlyContinue -ErrorVariable e)
        ($r | Where-Object Instance -eq 'alpha').Action | Should -Be 'Failed'
        ($r | Where-Object Instance -eq 'beta').Action  | Should -Be 'Updated'
        "$e" | Should -Match 'alpha'
    }

    It 'emits nothing for an instance -WhatIf declined' {
        # -WhatIf has already said what would happen; a row claiming an Action would be false.
        @(Update-GreenroomInstance -WhatIf | Where-Object Instance -eq 'alpha').Count | Should -Be 0
    }

    It 'has a table view with Action in it' {
        # Five properties would otherwise render as a list.
        $view = Get-FormatData -TypeName 'Greenroom.UpdateResult'
        $view | Should -Not -BeNullOrEmpty
        $view.FormatViewDefinition[0].Control.Headers.Label | Should -Contain 'Action'
    }
}

Describe 'Update-GreenroomInstance, when the recorded claude.exe is gone' {

    # Reinstalling Claude Code another way removes the path config.json records. An instance on
    # the current version was reported Current while it could not start a session.

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            @([PSCustomObject]@{ TaskName = 'greenroom-alpha' }, [PSCustomObject]@{ TaskName = 'greenroom-beta' })
        }
        Mock -ModuleName Greenroom Install-GreenroomInstance { }
        Mock -ModuleName Greenroom Restart-GreenroomSession { }
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $script:Loaded }
        Mock -ModuleName Greenroom Get-MissingClaudeExe {
            if ($Name -eq 'beta') { [PSCustomObject]@{ Path = 'C:\gone\claude.exe'; Explicit = $false } }
        }
    }

    It 'reports ClaudeMissing, not Current, and says how to fix it' {
        $r = @(Update-GreenroomInstance -WarningVariable w -WarningAction SilentlyContinue)
        ($r | Where-Object Instance -eq 'alpha').Action | Should -Be 'Current'
        ($r | Where-Object Instance -eq 'beta').Action  | Should -Be 'ClaudeMissing'
        "$w" | Should -Match ([regex]::Escape("'beta': claude.exe 'C:\gone\claude.exe', found at install, no longer exists"))
        "$w" | Should -Match ([regex]::Escape('Update-GreenroomInstance -Name beta -Force'))
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0
    }

    It 'points an explicitly chosen path at -ClaudeExe' {
        Mock -ModuleName Greenroom Get-MissingClaudeExe {
            if ($Name -eq 'beta') { [PSCustomObject]@{ Path = 'C:\gone\claude.exe'; Explicit = $true } }
        }
        $null = Update-GreenroomInstance -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match ([regex]::Escape("'beta' cannot start a session"))
        "$w" | Should -Match ([regex]::Escape("-ClaudeExe '' to find it automatically"))
    }

    It 'reports ClaudeMissing for an unversioned instance too' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
        (@(Update-GreenroomInstance -WarningAction SilentlyContinue) | Where-Object Instance -eq 'beta').Action |
            Should -Be 'ClaudeMissing'
    }

    It 'still re-registers an instance that is behind -- that looks Claude Code up again' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        $r = @(Update-GreenroomInstance -WarningAction SilentlyContinue)
        ($r | Where-Object Instance -eq 'beta').Action | Should -Be 'Updated'
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly -ParameterFilter { $Name -eq 'beta' }
    }

    It 're-registers it under -Force, which is the fix the warning names' {
        $null = Update-GreenroomInstance -Name beta -Force
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly -ParameterFilter { $Name -eq 'beta' }
    }
}

Describe 'Get-MissingClaudeExe' {

    BeforeEach {
        $script:Root = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
        Mock -ModuleName Greenroom Get-GreenroomStateRoot { $script:Root }
        $script:Present = Join-Path $script:Root 'claude.exe'
        Set-Content -LiteralPath $script:Present -Value 'x'
        function Config($Value) {
            $d = New-Item -ItemType Directory -Path (Join-Path $script:Root 'probe') -Force
            if ($Value -is [string]) { Set-Content (Join-Path $d 'config.json') $Value }
            else { $Value | ConvertTo-Json | Set-Content (Join-Path $d 'config.json') }
        }
        function Ask { InModuleScope Greenroom { Get-MissingClaudeExe -Name probe } }
    }

    It 'returns the path, and whether it was chosen, when it no longer exists' {
        Config @{ claudeExe = (Join-Path $script:Root 'gone\claude.exe'); claudeExeExplicit = $true }
        $r = Ask
        $r.Path | Should -Be (Join-Path $script:Root 'gone\claude.exe')
        $r.Explicit | Should -BeTrue
    }

    It 'returns nothing when <Why>' -ForEach @(
        @{ Why = 'the path exists'; Kind = 'present' }
        @{ Why = 'there is no config'; Kind = 'none' }
        @{ Why = 'the config is unreadable'; Kind = 'broken' }
        @{ Why = 'the config records no claude.exe'; Kind = 'empty' }
    ) {
        switch ($Kind) {
            'present' { Config @{ claudeExe = $script:Present; claudeExeExplicit = $false } }
            'broken'  { Config '{ not json' }
            'empty'   { Config @{ workingDirectory = 'D:\w' } }
        }
        Ask | Should -BeNullOrEmpty
    }
}
