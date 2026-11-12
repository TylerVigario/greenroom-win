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
        # Mocked rather than left to run for real, or the whole suite would depend on
        # whether the shell running it happens to be elevated, and on what it runs inside.
        Mock -ModuleName Greenroom Get-TaskRewriteBlocker { $null }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        # Never the real one: that is a UAC prompt, or on an elevated host a real elevated
        # run of the command against whatever is installed there.
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { [PSCustomObject]@{ ExitCode = 0; Records = @() } }
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
        #
        # The CALLER's preference is set, not assumed: the command honours it, and the gate
        # runs Pester from a script whose preference is Stop -- under which stopping at the
        # first failure is the right answer. Continue is an interactive shell's default.
        $ErrorActionPreference = 'Continue'
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

    It 'does not ATTEMPT an instance it cannot register' {
        # The failure this prevents: Register-ScheduledTask reports Access is denied as a
        # NON-terminating error, so the attempt carried on and the instance was reported
        # Updated while its task still named the old version.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Get-TaskRewriteBlocker {
            if ($Name -eq 'alpha') { 'owned by BUILTIN\Administrators.' }
        }
        # Both ways: handed to an elevated copy by default, refused under -NoElevate.
        Update-GreenroomInstance -ErrorAction SilentlyContinue
        Update-GreenroomInstance -NoElevate -ErrorAction SilentlyContinue
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0 `
            -ParameterFilter { $Name -eq 'alpha' }
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 0 `
            -ParameterFilter { $Name -eq 'alpha' }
    }

    It 'carries on to the next instance after refusing one under -NoElevate' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Get-TaskRewriteBlocker {
            if ($Name -eq 'alpha') { 'owned by BUILTIN\Administrators.' }
        }
        Update-GreenroomInstance -NoElevate -ErrorAction SilentlyContinue -ErrorVariable e
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'beta' }
        "$e" | Should -Match 'alpha'
    }

    It 'reports a refusal under -NoElevate as Refused, and escalates nothing' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Get-TaskRewriteBlocker {
            if ($Name -eq 'alpha') { 'requires an elevated caller.' }
        }
        $rows = Update-GreenroomInstance -NoElevate -ErrorAction SilentlyContinue -ErrorVariable e
        ($rows | Where-Object Instance -eq 'alpha').Action | Should -Be 'Refused'
        ($rows | Where-Object Instance -eq 'beta').Action  | Should -Be 'Updated'
        $e[0].FullyQualifiedErrorId | Should -Be 'UpdateRefused,Update-GreenroomInstance'
        "$($e[0])" | Should -Match '-NoElevate was passed'
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
    }

    It 'stops at the first refusal when the caller passes -ErrorAction Stop, row first' {
        # `Write-Error -ErrorAction Continue` carried on whatever the caller asked. And the
        # row has to go out before the error, or a throw leaves this instance with none.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Get-TaskRewriteBlocker {
            if ($Name -eq 'alpha') { 'owned by BUILTIN\Administrators.' }
        }
        $script:rows = [System.Collections.Generic.List[object]]::new()
        { Update-GreenroomInstance -NoElevate -ErrorAction Stop | ForEach-Object { $script:rows.Add($_) } } |
            Should -Throw '*refusing to update*'
        $script:rows.Action | Should -Be @('Refused')
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0
    }

    Context 'an instance this shell cannot register, without -NoElevate' {

        BeforeEach {
            Mock -ModuleName Greenroom Get-TaskRewriteBlocker {
                if ($Name -eq 'alpha') { 'owned by BUILTIN\Administrators.' }
            }
        }

        It 'hands every one of them to ONE elevated run, and attempts none here' {
            # One UAC prompt for the whole command, as Restart- and Stop- do: escalating each
            # as it came up would ask once per instance for one decision.
            Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
            Mock -ModuleName Greenroom Get-TaskRewriteBlocker { 'owned by BUILTIN\Administrators.' }
            $rows = @(Update-GreenroomInstance)
            Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly -ParameterFilter {
                $Command -eq 'Update-GreenroomInstance' -and ($Name -join ',') -eq 'alpha,beta'
            }
            Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0
            Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 0
            # Its rows are the elevated copy's to give, and this one returned none.
            $rows.Count | Should -Be 0
        }

        It 'still does the rest itself' {
            Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
            $rows = @(Update-GreenroomInstance)
            Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
                -ParameterFilter { $Name -eq 'beta' }
            Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly `
                -ParameterFilter { ($Name -join ',') -eq 'alpha' }
            $rows.Instance | Should -Be @('beta')
        }

        It 'carries -Force and -NoRestart to the elevated copy' {
            # Dropped, the copy would skip what -Force asked for, or restart what -NoRestart
            # said to leave running.
            Update-GreenroomInstance -Force -NoRestart
            Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly -ParameterFilter {
                $Forward -contains 'Force' -and $Forward -contains 'NoRestart' -and $Forward.Count -eq 2
            }
        }

        It 'carries nothing it was not given' {
            Update-GreenroomInstance
            Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly -ParameterFilter { -not $Forward }
        }

        It 'replays the elevated copy''s rows as update rows, after the rest' {
            Mock -ModuleName Greenroom Invoke-ElevatedSelf {
                $row = [PSCustomObject]@{ Instance = 'alpha'; Action = 'Updated'; From = '0.0.1'; To = '9.9.9'; ClaudePid = 4242 }
                $row.PSObject.TypeNames.Insert(0, 'Deserialized.Greenroom.UpdateResult')
                [PSCustomObject]@{ ExitCode = 0; Records = @($row) }
            }
            $rows = @(Update-GreenroomInstance)
            $rows.Instance                  | Should -Be @('beta', 'alpha')
            $rows[1].Action                 | Should -Be 'Updated'
            $rows[1].PSObject.TypeNames[0]  | Should -Be 'Greenroom.UpdateResult'
        }

        It 'escalates nothing under -WhatIf' {
            Update-GreenroomInstance -WhatIf
            Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
            Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0
        }

        It 'reports a declined prompt as one error naming the instance, and the rest still report' {
            # The caller's preference, set here for the reason CONTRIBUTING.md gives: the gate
            # runs Pester under Stop, and this is a test of the default. Counted on the error
            # STREAM, as the Stop- and Restart- tests do: a caught throw also lands in
            # -ErrorVariable, which the operator never sees.
            $ErrorActionPreference = 'Continue'
            Mock -ModuleName Greenroom Invoke-ElevatedSelf {
                throw "elevation declined or failed -- 'alpha' was not changed."
            }
            $out  = @(Update-GreenroomInstance 2>&1)
            $err  = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            $rows = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
            $rows.Instance                 | Should -Be @('beta')
            $err.Count                     | Should -Be 1
            $err[0].FullyQualifiedErrorId  | Should -Be 'ElevationDeclined,Update-GreenroomInstance'
            "$($err[0])"                   | Should -Match "'alpha' was not changed"
        }
    }

    It 'asks the blocker about the elevation the re-registration will inherit' {
        # The configured value: Install- inherits it, so it is what will be registered.
        Mock -ModuleName Greenroom Test-InstanceElevated { $Name -eq 'alpha' }
        Update-GreenroomInstance
        Should -Invoke -ModuleName Greenroom Get-TaskRewriteBlocker -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'alpha' -and $Elevated }
    }

    It 'carries on to the next instance when a RESTART fails, with no -ErrorAction supplied' {
        # Restart-'s Write-Error is terminating under the module's ErrorActionPreference, so
        # uncaught it ended the loop after the first instance's task had already moved.
        # The caller's preference is set for the reason given in the test above.
        $ErrorActionPreference = 'Continue'
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Restart-GreenroomSession {
            # -ErrorAction Stop, because a mock body runs in this file's scope and not the
            # module's: the real Restart-'s Write-Error is terminating, measured, and a plain
            # one here would not be -- letting the test pass with the fix taken out.
            if ($Name -eq 'alpha') { Write-Error "'alpha' did not come up within 45 s." -ErrorAction Stop }
        }
        $rows = @(Update-GreenroomInstance 2>$null)
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'beta' }
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'beta' }
        $rows.Count | Should -Be 2
    }

    It 'reports a failed restart as Registered, and says so' {
        # The task names the new assets; the session is what did not follow.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Restart-GreenroomSession {
            # -ErrorAction Stop, because a mock body runs in this file's scope and not the
            # module's: the real Restart-'s Write-Error is terminating, measured, and a plain
            # one here would not be -- letting the test pass with the fix taken out.
            if ($Name -eq 'alpha') { Write-Error "'alpha' did not come up within 45 s." -ErrorAction Stop }
        }
        $rows = @(Update-GreenroomInstance -ErrorAction SilentlyContinue -ErrorVariable e)
        ($rows | Where-Object Instance -eq 'alpha').Action | Should -Be 'Registered'
        ($rows | Where-Object Instance -eq 'beta').Action  | Should -Be 'Updated'
        "$e" | Should -Match ([regex]::Escape("'alpha' is re-registered on $script:Loaded, but restarting it failed"))
        "$e" | Should -Match 'did not come up'
    }

    It 'does not restart the session this shell runs inside, and names the command that will' {
        # Restart- refuses that one, so asking it would only produce an error for the case an
        # admin lane updating its own host always hits.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $Name -eq 'alpha' }
        $rows = @(Update-GreenroomInstance -WarningVariable w -WarningAction SilentlyContinue)
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'alpha' }
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 0 `
            -ParameterFilter { $Name -eq 'alpha' }
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'beta' }
        ($rows | Where-Object Instance -eq 'alpha').Action | Should -Be 'Registered'
        "$w" | Should -Match ([regex]::Escape('Restart-GreenroomSession alpha'))
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
        # Pinned in every block, not just the first: left real, these read the host --
        # whether the shell is elevated, what it runs inside, who owns a task by that name.
        Mock -ModuleName Greenroom Get-TaskRewriteBlocker { $null }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
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
        Mock -ModuleName Greenroom Get-TaskRewriteBlocker { $null }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
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

Describe 'The elevated Update command, run for real' {

    # What the elevated copy runs is a command line built as a string, so a switch it does
    # not bind fails only when someone clicks through UAC. This runs that exact string in a
    # real child pwsh -- without RunAs, the one part a test cannot click -- against THIS
    # module, for a name no host has registered, so it changes nothing anywhere.

    BeforeAll {
        Mock -ModuleName Greenroom Start-Process { $script:Inner = $ArgumentList[-1]; [PSCustomObject]@{ ExitCode = 0 } }
        InModuleScope Greenroom {
            Invoke-ElevatedSelf -Command 'Update-GreenroomInstance' -Name 'gr-no-such-instance' `
                -Forward 'Force', 'NoRestart' -WarningAction SilentlyContinue | Out-Null
        }
        $script:Out = [regex]::Match($script:Inner, "LiteralPath '([^']+\.clixml)'").Groups[1].Value
    }

    AfterAll { if ($script:Out) { Remove-Item -LiteralPath $script:Out -Force -ErrorAction Ignore } }

    It 'binds every forwarded switch, exits 0, and carries the run''s warning back' {
        $ErrorActionPreference = 'Continue'
        $script:Inner | Should -Match ' -Force -NoRestart '
        pwsh -NoLogo -NoProfile -Command $script:Inner 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        $rec = @(Import-Clixml -LiteralPath $script:Out)
        $rec.Count              | Should -Be 1
        $rec[0].GreenroomStream | Should -Be 'Warning'
        $rec[0].Message         | Should -Match "no registered instance matches 'gr-no-such-instance'"
    }
}
