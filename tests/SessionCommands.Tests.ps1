# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Show-, Hide- and Restart-GreenroomSession: the decision logic, with every effect
  mocked. No windows move and no processes are killed.

  The properties worth pinning down are the ones that were bugs in the script this
  replaces: that -WhatIf really performs nothing, that an unresolvable window refuses
  instead of acting, and that restarting the session you are running inside is refused
  rather than bricking the instance.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Show-GreenroomSession / Hide-GreenroomSession' {

    BeforeEach {
        Mock -ModuleName Greenroom Resolve-GreenroomTarget {
            [PSCustomObject]@{
                PSTypeName = 'Greenroom.Instance'
                Instance   = 'probe'; ClaudePid = 1001; TerminalPid = 2001
                Window     = [IntPtr]::new(4242); Visible = $false
                Elevated   = $false; Opaque = $false
            }
        }
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $true }
        Mock -ModuleName Greenroom Set-WindowVisible { $true }
        Mock -ModuleName Greenroom Get-WindowFailureReason { 'mocked failure reason' }
    }

    It 'shows the window with Show = true' {
        Show-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly `
            -ParameterFilter { $Show -eq $true }
    }

    It 'hides the window with Show = false' {
        Hide-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly `
            -ParameterFilter { $Show -eq $false }
    }

    It 'is silent on success' {
        # An operator watches the window appear; a pipeline of ten should not print ten
        # confirmations.
        Show-GreenroomSession -Name probe | Should -BeNullOrEmpty
    }

    It 'performs nothing under -WhatIf' {
        Show-GreenroomSession -Name probe -WhatIf
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 0
    }

    It 'validates before -WhatIf, so it cannot claim it would act on a dead instance' {
        Mock -ModuleName Greenroom Resolve-GreenroomTarget { $null }
        Show-GreenroomSession -Name nope -WhatIf
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 0
        Should -Invoke -ModuleName Greenroom Assert-CanActOnInstance -Times 0
    }

    It 'requires a resolved window' {
        Show-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Resolve-GreenroomTarget -Times 1 -Exactly `
            -ParameterFilter { $RequireWindow -eq $true }
    }

    It 'does not act when escalation says the work was handled elsewhere' {
        # Assert-CanActOnInstance returning false means an elevated copy already did it,
        # or the caller was refused. Either way this process must not also act.
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $false }
        Show-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 0
    }

    It 'errors when the window did not change state' {
        # ShowWindow cannot report failure; only observation can. A silent no-op is the
        # failure mode this check exists for.
        Mock -ModuleName Greenroom Set-WindowVisible { $false }
        { Show-GreenroomSession -Name probe -ErrorAction Stop } | Should -Throw
    }

    It 'accepts a Greenroom.Instance from the pipeline via the Instance alias' {
        [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe' } | Show-GreenroomSession
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly
    }

    It 'processes every item piped in' {
        'a', 'b', 'c' | Show-GreenroomSession
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 3 -Exactly
    }
}

Describe 'Assert-CanActOnInstance' {

    BeforeEach {
        Mock -ModuleName Greenroom Test-InstanceElevated { $true }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { 0 }
    }

    It 'escalates for a real run against an elevated instance' {
        $r = InModuleScope Greenroom { Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' }
        $r | Should -BeFalse -Because 'the elevated copy did the work, so the caller must not also act'
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly
    }

    It 'does NOT escalate under -WhatIf' {
        # Escalation runs the command again in a NEW process, and -WhatIf is not
        # forwarded to it -- so a dry run would raise a UAC prompt and then PERFORM THE
        # REAL ACTION over there. A -WhatIf that acts is worse than no -WhatIf at all.
        # Setting $WhatIfPreference is exactly what PowerShell does for -WhatIf.
        $r = InModuleScope Greenroom {
            $WhatIfPreference = $true
            Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession'
        }
        $r | Should -BeTrue -Because 'the caller proceeds locally, where its own ShouldProcess reports and changes nothing'
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
    }

    It 'refuses instead of escalating under -NoElevate' {
        $r = InModuleScope Greenroom {
            Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' -NoElevate -ErrorAction SilentlyContinue
        }
        $r | Should -BeFalse
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
    }

    It 'does not escalate at all when the instance is not elevated' {
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
        $r = InModuleScope Greenroom { Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' }
        $r | Should -BeTrue
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
    }
}

Describe 'Invoke-ElevatedSelf' {

    # Deliberately its OWN Describe with no Invoke-ElevatedSelf mock -- mocking the
    # function under test is how the first version of this passed while proving nothing.

    It 'escalates with -Confirm:$false so the decision is not retaken on defaults' {
        # The caller has already passed its own ShouldProcess gate by the time this runs.
        # A fresh elevated process starts with default preferences, so without this it
        # would either prompt a second time or -- because -Confirm is never forwarded --
        # not prompt at all.
        Mock -ModuleName Greenroom Start-Process { [PSCustomObject]@{ ExitCode = 0 } }
        InModuleScope Greenroom { Invoke-ElevatedSelf -Command 'Show-GreenroomSession' -Name 'probe' } | Out-Null
        Should -Invoke -ModuleName Greenroom Start-Process -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -match '-Confirm:\$false'
        }
    }

    It 'signals failure by exit code rather than trusting $LASTEXITCODE' {
        # $LASTEXITCODE is set by NATIVE commands only. A PowerShell function failing
        # with a non-terminating Write-Error leaves it untouched, and in a fresh process
        # it is $null -- which exits 0. Measured: an inner command whose function wrote a
        # non-terminating error exited 0, so every recoverable failure over there came
        # back as success and the caller skipped acting on work that never happened.
        Mock -ModuleName Greenroom Start-Process { [PSCustomObject]@{ ExitCode = 0 } }
        InModuleScope Greenroom { Invoke-ElevatedSelf -Command 'Show-GreenroomSession' -Name 'probe' } | Out-Null
        Should -Invoke -ModuleName Greenroom Start-Process -Times 1 -Exactly -ParameterFilter {
            $cmd = $ArgumentList -join ' '
            $cmd -match "ErrorActionPreference='Stop'" -and
            $cmd -match 'exit 1' -and
            $cmd -notmatch 'LASTEXITCODE'
        }
    }

    It 'doubles embedded quotes so a path containing one cannot break the command' {
        # The instance name cannot contain a quote, but the MODULE PATH can: a home
        # directory belonging to someone called O'Brien is enough.
        Mock -ModuleName Greenroom Start-Process { [PSCustomObject]@{ ExitCode = 0 } }
        InModuleScope Greenroom {
            $script:GreenroomModuleRoot = "C:\Users\O'Brien\Modules\Greenroom"
            Invoke-ElevatedSelf -Command 'Show-GreenroomSession' -Name 'probe'
        } | Out-Null
        Should -Invoke -ModuleName Greenroom Start-Process -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -match "O''Brien"
        }
    }
}

Describe 'The self-restart guard' {

    # Also its own Describe: the suite elsewhere mocks Test-SelfIsInstance to $false so
    # the destructive path can be exercised, and that mock would shadow the thing being
    # tested here.

    It 'fires for an instance name ending in a dash' {
        # The dangerous case. A guard that misses lets you restart the instance your own
        # shell runs inside, which leaves it DOWN rather than restarted.
        Mock -ModuleName Greenroom Get-CimInstance {
            [PSCustomObject]@{
                ProcessId = 4242; Name = 'claude.exe'
                CommandLine = 'claude.exe --remote-control render-'
                ParentProcessId = 0
            }
        }
        InModuleScope Greenroom { Test-SelfIsInstance -Name 'render-' } | Should -BeTrue
    }

    It 'fires for an instance name ending in a dot' {
        Mock -ModuleName Greenroom Get-CimInstance {
            [PSCustomObject]@{
                ProcessId = 4242; Name = 'claude.exe'
                CommandLine = 'claude.exe --remote-control v1.'
                ParentProcessId = 0
            }
        }
        InModuleScope Greenroom { Test-SelfIsInstance -Name 'v1.' } | Should -BeTrue
    }

    It 'does not fire for a different instance sharing a prefix' {
        Mock -ModuleName Greenroom Get-CimInstance {
            [PSCustomObject]@{
                ProcessId = 4242; Name = 'claude.exe'
                CommandLine = 'claude.exe --remote-control render-two'
                ParentProcessId = 0
            }
        }
        InModuleScope Greenroom { Test-SelfIsInstance -Name 'render-' } | Should -BeFalse
    }
}

Describe 'Instance names ending in a dot or dash' {

    # ValidatePattern allows them -- 'render-' and 'v1.' are legal instance names -- and a
    # `\b` word boundary does NOT match after a non-word character. Patterns anchored with
    # `\b` therefore matched nothing for those names, which meant the watchdog and session
    # were never stopped, and worse, the self-restart guard never fired.
    #
    # These assert the pattern the code actually passes matches a real command line,
    # rather than asserting the pattern's text, so a future rewrite that is still correct
    # keeps passing.

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask { [PSCustomObject]@{ TaskName = 'greenroom-x' } }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $true }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        Mock -ModuleName Greenroom Start-ScheduledTask { }
        Mock -ModuleName Greenroom Start-Sleep { }
        Mock -ModuleName Greenroom Get-GreenroomInstance {
            [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'render-'; ClaudePid = 1; Opaque = $false }
        }
    }

    It 'Restart matches a session whose name ends in a dash' {
        Restart-GreenroomSession -Name 'render-' | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'session' -and
            ('claude.exe --remote-control render- --add-dir C:\x' -match $Pattern)
        }
    }

    It 'Restart matches a watchdog whose name ends in a dot' {
        Restart-GreenroomSession -Name 'v1.' | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'watchdog' -and
            ('pwsh.exe -File greenroom-watchdog.ps1 -Instance "v1."' -match $Pattern)
        }
    }

    It 'Uninstall matches a session whose name ends in a dash' {
        Mock -ModuleName Greenroom Get-GreenroomStateRoot { [IO.Path]::GetTempPath() }
        Mock -ModuleName Greenroom Unregister-ScheduledTask { }
        Mock -ModuleName Greenroom Stop-ScheduledTask { }
        Uninstall-GreenroomInstance -Name 'render-' | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'session' -and
            ('claude.exe --remote-control render-' -match $Pattern)
        }
    }

}

Describe 'Restart-GreenroomSession' {

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            # Honours -TaskName, so an exact lookup for an unregistered name finds nothing.
            if ('greenroom-probe' -like $TaskName) { [PSCustomObject]@{ TaskName = 'greenroom-probe' } }
        }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $true }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        Mock -ModuleName Greenroom Start-ScheduledTask { }
        Mock -ModuleName Greenroom Start-Sleep { }
        Mock -ModuleName Greenroom Get-GreenroomInstance {
            [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe'; ClaudePid = 1234; Opaque = $false }
        }
    }

    It 'stops the watchdog, the session and the launcher' {
        Restart-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 3 -Exactly
    }

    It 'stops the watchdog FIRST, or it resurrects the session before the task runs' {
        Restart-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 1 -Exactly `
            -ParameterFilter { $Label -eq 'watchdog' }
    }

    It 'starts the task again' {
        Restart-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 1 -Exactly
    }

    It 'returns the restarted instance' {
        (Restart-GreenroomSession -Name probe).Instance | Should -Be 'probe'
    }

    It 'REFUSES to restart the session the shell is running inside' {
        # Killing an ancestor mid-run leaves the instance DOWN rather than restarted,
        # and calling it from inside the session is the most natural way to reach for it.
        Mock -ModuleName Greenroom Test-SelfIsInstance { $true }
        { Restart-GreenroomSession -Name probe -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
    }

    It 'refuses when the instance has no scheduled task' {
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        { Restart-GreenroomSession -Name nope -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    It 'kills nothing under -WhatIf' {
        Restart-GreenroomSession -Name probe -WhatIf
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
    }

    It 'checks the self-restart guard before doing anything destructive' {
        Restart-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Test-SelfIsInstance -Times 1 -Exactly
    }
}

Describe 'Stop-GreenroomSession' {

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            # Honours -TaskName, so an exact lookup for an unregistered name finds nothing.
            if ('greenroom-probe' -like $TaskName) { [PSCustomObject]@{ TaskName = 'greenroom-probe' } }
        }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $true }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        Mock -ModuleName Greenroom Stop-ScheduledTask { }
        Mock -ModuleName Greenroom Start-ScheduledTask { }
        Mock -ModuleName Greenroom Start-Sleep { }
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        # Absent means stopped. The settle loop asks repeatedly, so this is the
        # "it stayed down" case.
        Mock -ModuleName Greenroom Get-GreenroomInstance { @() }
    }

    It 'stops the watchdog, the session and the launcher' {
        Stop-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 3 -Exactly
    }

    It 'stops the watchdog FIRST, or it resurrects the session mid-run' {
        Stop-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 1 -Exactly `
            -ParameterFilter { $Label -eq 'watchdog' }
    }

    It 'does NOT start the task again -- that is the whole difference from Restart' {
        Stop-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
    }

    It 'stops the task so its trigger cannot start a replacement watchdog mid-run' {
        Stop-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-ScheduledTask -Times 1 -Exactly
    }

    It 'reports what it stopped as data' {
        $r = Stop-GreenroomSession -Name probe
        $r.Instance        | Should -Be 'probe'
        $r.WatchdogStopped | Should -Be 1
        $r.SessionStopped  | Should -Be 1
        $r.LauncherStopped | Should -Be 1
        $r.StayedDown      | Should -BeTrue
    }

    It 'reports StayedDown false when something puts the session back' {
        # The failure this check exists for: a watchdog whose command line did not match
        # the pattern -- one from a different asset version, say -- survives, restarts the
        # session, and the three kill counts still look like success.
        Mock -ModuleName Greenroom Get-GreenroomInstance {
            [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe'; ClaudePid = 99; Opaque = $false }
        }
        $r = Stop-GreenroomSession -Name probe -WarningAction SilentlyContinue
        $r.StayedDown | Should -BeFalse
    }

    It 'skips the settle check with -SettleSeconds 0' {
        Mock -ModuleName Greenroom Get-GreenroomInstance {
            [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe'; Opaque = $false }
        }
        $r = Stop-GreenroomSession -Name probe -SettleSeconds 0
        $r.StayedDown | Should -BeTrue -Because 'nothing was observed, so nothing contradicts it'
        Should -Invoke -ModuleName Greenroom Get-GreenroomInstance -Times 0
    }

    It 'cannot confirm an elevated instance from an unelevated shell' {
        # Absence is not evidence when the command line is unreadable across integrity
        # levels. Reporting Confirmed here would be reporting a check that never ran.
        Mock -ModuleName Greenroom Test-InstanceElevated { $true }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        $r = Stop-GreenroomSession -Name probe -WarningAction SilentlyContinue
        $r.Confirmed | Should -BeFalse
    }

    It 'REFUSES to stop the session the shell is running inside' {
        Mock -ModuleName Greenroom Test-SelfIsInstance { $true }
        { Stop-GreenroomSession -Name probe -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    It 'refuses when the instance has no scheduled task' {
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        { Stop-GreenroomSession -Name nope -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    It 'kills nothing under -WhatIf' {
        Stop-GreenroomSession -Name probe -WhatIf
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Should -Invoke -ModuleName Greenroom Stop-ScheduledTask -Times 0
    }

    It 'matches a session whose name ends in a dash' {
        # ValidatePattern allows 'render-', and a \b word boundary does not match after a
        # non-word character -- the bug that made the kill patterns match nothing.
        Mock -ModuleName Greenroom Get-ScheduledTask {
            if ('greenroom-render-' -like $TaskName) { [PSCustomObject]@{ TaskName = 'greenroom-render-' } }
        }
        Stop-GreenroomSession -Name 'render-' | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'session' -and
            ('claude.exe --remote-control render- --add-dir C:\x' -match $Pattern)
        }
    }

    It 'accepts a Greenroom.Instance from the pipeline via the Instance alias' {
        [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe' } | Stop-GreenroomSession | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 3 -Exactly
    }
}

Describe 'Start-GreenroomSession' {

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            # Honours -TaskName, so an exact lookup for an unregistered name finds nothing.
            if ('greenroom-probe' -like $TaskName) { [PSCustomObject]@{ TaskName = 'greenroom-probe' } }
        }
        Mock -ModuleName Greenroom Start-ScheduledTask { }
        Mock -ModuleName Greenroom Start-Sleep { }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        # Stopped by default: nothing running, and nothing ever comes up.
        Mock -ModuleName Greenroom Get-GreenroomInstance { }
    }

    AfterEach { Remove-Variable -Name GrStartCalls -Scope Script -ErrorAction SilentlyContinue }

    It 'starts the task for a stopped instance' {
        Start-GreenroomSession -Name probe -TimeoutSeconds 5 -ErrorAction SilentlyContinue
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 1 -Exactly `
            -ParameterFilter { $TaskName -eq 'greenroom-probe' }
    }

    It 'returns the instance once its session appears' {
        # Stopped at the check, up by the first poll.
        $script:GrStartCalls = 0
        Mock -ModuleName Greenroom Get-GreenroomInstance {
            $script:GrStartCalls++
            if ($script:GrStartCalls -gt 1) {
                [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe'; ClaudePid = 77; Opaque = $false }
            }
        }
        (Start-GreenroomSession -Name probe).ClaudePid | Should -Be 77
    }

    It 'LEAVES A RUNNING INSTANCE ALONE -- the difference from Restart' {
        # Restart kills the watchdog, the session and the launcher before starting. Reached
        # for as "make sure it is up", that restarts something that was fine.
        Mock -ModuleName Greenroom Get-GreenroomInstance {
            [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe'; ClaudePid = 42; Opaque = $false }
        }
        (Start-GreenroomSession -Name probe).ClaudePid | Should -Be 42
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    It 'never kills anything, even when it does start' {
        Start-GreenroomSession -Name probe -TimeoutSeconds 5 -ErrorAction SilentlyContinue
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    It 'refuses when the instance has no scheduled task' {
        { Start-GreenroomSession -Name nope -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
    }

    It 'starts nothing under -WhatIf' {
        Start-GreenroomSession -Name probe -WhatIf
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
    }

    It 'errors when the session never appears' {
        { Start-GreenroomSession -Name probe -TimeoutSeconds 5 -ErrorAction Stop } | Should -Throw
    }

    It 'warns rather than errors when an elevated instance cannot be confirmed' {
        # Starting needs no elevation; confirming does. Failing here would report a check
        # that could not run as a start that did not happen.
        Mock -ModuleName Greenroom Test-InstanceElevated { $true }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        { Start-GreenroomSession -Name probe -TimeoutSeconds 5 -ErrorAction Stop -WarningAction SilentlyContinue } |
            Should -Not -Throw
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 1 -Exactly
    }

    It 'warns when the instance would come up on older assets' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { '0.0.1' }
        Start-GreenroomSession -Name probe -TimeoutSeconds 5 -ErrorAction SilentlyContinue `
            -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ' ') | Should -Match '0\.0\.1'
    }

    It 'with no name, uses the only registered instance' {
        Start-GreenroomSession -TimeoutSeconds 5 -ErrorAction SilentlyContinue
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 1 -Exactly `
            -ParameterFilter { $TaskName -eq 'greenroom-probe' }
    }

    It 'with no name and several registered, refuses to guess' {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            'greenroom-a', 'greenroom-b' | Where-Object { $_ -like $TaskName } |
                ForEach-Object { [PSCustomObject]@{ TaskName = $_ } }
        }
        { Start-GreenroomSession -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
    }

    It 'starts every registered instance a wildcard matches' {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            'greenroom-a', 'greenroom-b' | Where-Object { $_ -like $TaskName } |
                ForEach-Object { [PSCustomObject]@{ TaskName = $_ } }
        }
        Start-GreenroomSession -Name '*' -TimeoutSeconds 5 -ErrorAction SilentlyContinue
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 2 -Exactly
    }

    It 'takes names captured before a stop, from the pipeline' {
        # The upgrade procedure: capture while running, stop, upgrade, pipe the names back.
        Mock -ModuleName Greenroom Get-ScheduledTask {
            'greenroom-a', 'greenroom-b' | Where-Object { $_ -like $TaskName } |
                ForEach-Object { [PSCustomObject]@{ TaskName = $_ } }
        }
        'a', 'b' | Start-GreenroomSession -TimeoutSeconds 5 -ErrorAction SilentlyContinue
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 2 -Exactly
    }
}

Describe 'Wildcards on Stop- and Restart-GreenroomSession' {

    # A pattern fans out into one call per resolved instance, so each gets the full
    # single-instance path. The properties worth pinning: every match is acted on, -WhatIf
    # survives the fan-out, and a refusal for one instance does not abandon the rest.

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            'greenroom-a', 'greenroom-b' | Where-Object { $_ -like $TaskName } |
                ForEach-Object { [PSCustomObject]@{ TaskName = $_ } }
        }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $true }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        Mock -ModuleName Greenroom Stop-ScheduledTask { }
        Mock -ModuleName Greenroom Start-ScheduledTask { }
        Mock -ModuleName Greenroom Start-Sleep { }
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
        Mock -ModuleName Greenroom Get-GreenroomInstance { }
    }

    It 'Stop acts on every registered instance a wildcard matches' {
        $r = @(Stop-GreenroomSession -Name '*' -SettleSeconds 0)
        $r.Instance | Should -Be @('a', 'b')
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 6 -Exactly
    }

    It 'Restart acts on every registered instance a wildcard matches' {
        Restart-GreenroomSession -Name '*' -TimeoutSeconds 5 -ErrorAction SilentlyContinue
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 2 -Exactly
    }

    It 'a pattern only matches what it says' {
        $r = @(Stop-GreenroomSession -Name 'b*' -SettleSeconds 0)
        $r.Instance | Should -Be @('b')
    }

    It 'warns and does nothing when a pattern matches no instance' {
        Stop-GreenroomSession -Name 'zzz*' -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ' ') | Should -Match 'zzz'
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    It '-WhatIf survives the fan-out' {
        Stop-GreenroomSession -Name '*' -WhatIf
        Restart-GreenroomSession -Name '*' -WhatIf
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
    }

    It 'refusing the instance the shell is inside does NOT abandon the others' {
        # The reason this fans out rather than looping inside one call: the single-instance
        # body refuses by returning early, and in a loop that return would silently skip
        # every instance after the refused one.
        Mock -ModuleName Greenroom Test-SelfIsInstance { $Name -eq 'a' }
        $r = @(Stop-GreenroomSession -Name '*' -SettleSeconds 0 -ErrorAction SilentlyContinue -ErrorVariable e)
        $r.Instance | Should -Be @('b')
        $e.Count    | Should -BeGreaterThan 0
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 3 -Exactly
    }

    It 'with no name and several registered, Stop refuses to guess' {
        { Stop-GreenroomSession -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    It 'with no name and several registered, Restart refuses to guess' {
        { Restart-GreenroomSession -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }
}
