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
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { [PSCustomObject]@{ ExitCode = 0; Records = @() } }
    }

    It 'escalates for a real run against an elevated instance' {
        $r = InModuleScope Greenroom { Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' }
        $r | Should -BeFalse -Because 'the elevated copy did the work, so the caller must not also act'
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly
    }

    It 'returns only its bool, even when the elevated run sent objects back' {
        # The caller tests this in an if. An object replayed here would be read as part of
        # that answer, so objects are dropped on this path -- the commands that use it
        # return nothing anyway -- while the warning still reaches the operator.
        Mock -ModuleName Greenroom Invoke-ElevatedSelf {
            [PSCustomObject]@{ ExitCode = 0; Records = @(
                [PSCustomObject]@{ Instance = 'probe' }
                [PSCustomObject]@{ GreenroomStream = 'Warning'; Message = 'said over there' }
            ) }
        }
        $r = @(InModuleScope Greenroom {
            Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' -WarningVariable w -WarningAction SilentlyContinue
            $script:W = $w
        })
        $r.Count | Should -Be 1
        $r[0]    | Should -BeFalse
        InModuleScope Greenroom { "$script:W" } | Should -Match 'said over there'
    }

    It 'reports the error text the elevated run sent back, not just its exit code' {
        Mock -ModuleName Greenroom Invoke-ElevatedSelf {
            [PSCustomObject]@{ ExitCode = 1; Records = @(
                [PSCustomObject]@{ GreenroomStream = 'Error'; Message = 'window is gone'; ErrorId = 'Gone,Show-GreenroomSession'; Category = 'ObjectNotFound' }
            ) }
        }
        $e = $null
        InModuleScope Greenroom {
            Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' -ErrorAction SilentlyContinue -ErrorVariable ev | Out-Null
            $script:E = $ev
        }
        $e = InModuleScope Greenroom { $script:E }
        @($e).Count | Should -Be 1
        "$($e[0])"  | Should -Match 'window is gone'
    }

    It 'says the run reported nothing when it failed without a word' {
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { [PSCustomObject]@{ ExitCode = 1; Records = @() } }
        InModuleScope Greenroom {
            Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' -ErrorAction SilentlyContinue -ErrorVariable ev | Out-Null
            $script:E = $ev
        }
        "$(InModuleScope Greenroom { $script:E })" | Should -Match 'reported nothing back'
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

    It 'with -Defer, queues the name instead of escalating -- even into an EMPTY list' {
        # An empty list is falsy, so a truthiness check would escalate the first name
        # immediately and defer only the ones after it.
        $r = InModuleScope Greenroom {
            $q = [System.Collections.Generic.List[string]]::new()
            [PSCustomObject]@{
                Result = Assert-CanActOnInstance -Name probe -Command 'Stop-GreenroomSession' -Defer $q
                Queued = @($q)
            }
        }
        $r.Result | Should -BeFalse -Because 'the caller must not act on it locally'
        $r.Queued | Should -Be @('probe')
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

Describe 'Fan-out and name resolution' {

    # Regressions for a review of the wildcard work in #54, which fanned a pattern out into
    # one nested invocation per instance. Each case here was confirmed against that version
    # before it was fixed.

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            $hit = @('greenroom-a', 'greenroom-b', 'greenroom-c' | Where-Object { $_ -like $TaskName })
            # Like the real cmdlet: an EXACT name that matches nothing raises an error. A
            # mock that stayed silent is how a stray error record went unnoticed.
            if (-not $hit -and -not [WildcardPattern]::ContainsWildcardCharacters($TaskName)) {
                # The mock body runs in the TEST's scope, so -ErrorAction passed by the code
                # does not reach a bare Write-Error here. Hand it on explicitly, or the mock
                # records errors the real cmdlet would not. MEASURED on the real cmdlet:
                # SilentlyContinue leaves one record, Ignore leaves none.
                $ea = if ($PesterBoundParameters.ContainsKey('ErrorAction')) { $PesterBoundParameters['ErrorAction'] } else { 'Continue' }
                Write-Error -Message "No MSFT_ScheduledTask objects found with property 'TaskName' equal to '$TaskName'." -ErrorAction $ea
            }
            $hit | ForEach-Object { [PSCustomObject]@{ TaskName = $_ } }
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

    It 'Stop settles ONCE across every instance, not once per instance' {
        # One pass of SettleSeconds * 2 polls. Per-instance settling slept 3x as long here.
        Stop-GreenroomSession -Name '*' -SettleSeconds 1 | Out-Null
        Should -Invoke -ModuleName Greenroom Start-Sleep -Times 2 -Exactly
    }

    It 'resolves a pattern with one task lookup, not one per instance' {
        Stop-GreenroomSession -Name '*' -SettleSeconds 0 | Out-Null
        Should -Invoke -ModuleName Greenroom Get-ScheduledTask -Times 1 -Exactly
    }

    It 'reports an unknown name as the command that was typed, and ONLY that' {
        # The lookup's own "not found" must leave no record ahead of it: SilentlyContinue
        # hid that error from the console but still put it first in -ErrorVariable.
        Stop-GreenroomSession -Name 'nope' -ErrorAction SilentlyContinue -ErrorVariable e
        $e.Count                    | Should -Be 1
        $e[0].FullyQualifiedErrorId | Should -Be 'InstanceNotRegistered,Stop-GreenroomSession'
    }

    It 'reports a missing name as the command that was typed' {
        Restart-GreenroomSession -ErrorAction SilentlyContinue -ErrorVariable e
        $e[0].FullyQualifiedErrorId | Should -Be 'InstanceNameRequired,Restart-GreenroomSession'
    }

    It 'with ONE registered instance and no name, resolves the whole name, not its first letter' {
        # A one-element array returned from a function unrolls to a bare string, and
        # indexing a string returns a character: this once started 'greenroom-p'.
        Mock -ModuleName Greenroom Get-ScheduledTask {
            if ('greenroom-probe' -like $TaskName) { [PSCustomObject]@{ TaskName = 'greenroom-probe' } }
        }
        Stop-GreenroomSession -SettleSeconds 0 | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-ScheduledTask -Times 1 -Exactly `
            -ParameterFilter { $TaskName -eq 'greenroom-probe' }
    }

    It 'lists each registered instance once, even if a same-named task sits in another folder' {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            [PSCustomObject]@{ TaskName = 'greenroom-a' }; [PSCustomObject]@{ TaskName = 'greenroom-a' }
        }
        @(InModuleScope Greenroom { Get-RegisteredInstanceName }) | Should -Be @('a')
    }

    It 'reads only the root task folder, where Register-GreenroomTask puts them' {
        InModuleScope Greenroom { Get-RegisteredInstanceName } | Out-Null
        Should -Invoke -ModuleName Greenroom Get-ScheduledTask -Times 1 -Exactly `
            -ParameterFilter { $TaskPath -eq '\' }
    }
}

Describe 'One UAC prompt for many elevated instances' {

    # Escalation used to happen per instance, as each came up in the loop, so a pattern
    # matching three elevated instances asked three times for one decision. Now they are
    # deferred and escalated together in `end`. Assert-CanActOnInstance is deliberately
    # NOT mocked here: the deferral lives in it, and mocking it is how this went untested.

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            'greenroom-a', 'greenroom-b', 'greenroom-c' | Where-Object { $_ -like $TaskName } |
                ForEach-Object { [PSCustomObject]@{ TaskName = $_ } }
        }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        Mock -ModuleName Greenroom Test-InstanceElevated { $Name -in 'a', 'c' }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { [PSCustomObject]@{ ExitCode = 0; Records = @() } }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        Mock -ModuleName Greenroom Stop-ScheduledTask { }
        Mock -ModuleName Greenroom Start-ScheduledTask { }
        Mock -ModuleName Greenroom Start-Sleep { }
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
        Mock -ModuleName Greenroom Get-GreenroomInstance {
            [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = $Name; ClaudePid = 1; Opaque = $false }
        }
    }

    It 'Stop: one escalation carries every elevated match, and the rest are stopped here' {
        Mock -ModuleName Greenroom Get-GreenroomInstance { }
        $r = @(Stop-GreenroomSession -Name '*' -SettleSeconds 0 -WarningAction SilentlyContinue)
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly -ParameterFilter {
            ($Name -join ',') -eq 'a,c' -and $Command -eq 'Stop-GreenroomSession'
        }
        $r.Instance | Should -Be @('b')
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 3 -Exactly
    }

    It 'Restart: one escalation carries every elevated match, and the rest are restarted here' {
        $r = @(Restart-GreenroomSession -Name '*' -WarningAction SilentlyContinue)
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly -ParameterFilter {
            ($Name -join ',') -eq 'a,c' -and $Command -eq 'Restart-GreenroomSession'
        }
        $r.Instance | Should -Be @('b')
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 1 -Exactly
    }

    It 'names piped in one at a time still share one prompt' {
        # Each piped name is its own `process` call, so deferring within the loop alone
        # would still have prompted once per name. The list lives across calls, in `begin`.
        Mock -ModuleName Greenroom Get-GreenroomInstance { }
        'a', 'b', 'c' | Stop-GreenroomSession -SettleSeconds 0 -WarningAction SilentlyContinue | Out-Null
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly -ParameterFilter {
            ($Name -join ',') -eq 'a,c'
        }
    }

    It 'a single elevated instance escalates on its own, as before' {
        Mock -ModuleName Greenroom Get-GreenroomInstance { }
        Stop-GreenroomSession -Name 'a' -SettleSeconds 0 | Out-Null
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly -ParameterFilter {
            ($Name -join ',') -eq 'a'
        }
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    # Declines are counted on the ERROR STREAM, not with -ErrorVariable. MEASURED: a throw
    # that is caught still lands in the caller's -ErrorVariable and in $Error, so the
    # variable also holds what Invoke-ElevatedSelf threw and Start-Process raised inside it
    # -- none of which the operator sees. The stream is what reaches the console.
    It 'a declined prompt is one error, and does not undo or skip the instances done here (Stop)' {
        # Invoke-ElevatedSelf THROWS when the prompt is dismissed.
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { throw "elevation declined or failed -- 'a', 'c' were not changed" }
        Mock -ModuleName Greenroom Get-GreenroomInstance { }
        $out = @(Stop-GreenroomSession -Name '*' -SettleSeconds 0 -WarningAction SilentlyContinue -ErrorAction Continue 2>&1)
        $err = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }).Instance | Should -Be @('b')
        $err.Count                    | Should -Be 1
        $err[0].FullyQualifiedErrorId | Should -Be 'ElevationDeclined,Stop-GreenroomSession'
        "$($err[0])"                  | Should -Match 'declined'
    }

    It 'a declined prompt is one error, and does not undo or skip the instances done here (Restart)' {
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { throw 'declined' }
        $out = @(Restart-GreenroomSession -Name '*' -WarningAction SilentlyContinue -ErrorAction Continue 2>&1)
        $err = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }).Instance | Should -Be @('b')
        $err.Count                    | Should -Be 1
        $err[0].FullyQualifiedErrorId | Should -Be 'ElevationDeclined,Restart-GreenroomSession'
    }

    It 'a failed elevated run is reported as the command, naming every instance it carried' {
        # A run that dies before writing its results reports nothing back, so which one
        # failed cannot be known here.
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { [PSCustomObject]@{ ExitCode = 1; Records = @() } }
        Mock -ModuleName Greenroom Get-GreenroomInstance { }
        Stop-GreenroomSession -Name '*' -SettleSeconds 0 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -ErrorVariable e | Out-Null
        $e.Count                    | Should -Be 1
        $e[0].FullyQualifiedErrorId | Should -Be 'ElevatedRunFailed,Stop-GreenroomSession'
        "$($e[0])"                  | Should -Match "'a', 'c'"
    }

    It 'replays what the elevated run said: its results typed, its warnings, its errors' {
        # Results arrive deserialized, typed Deserialized.Greenroom.StopResult -- which no
        # view matches, so they would print as a bare list. The type name is restored.
        Mock -ModuleName Greenroom Get-GreenroomInstance { }
        Mock -ModuleName Greenroom Invoke-ElevatedSelf {
            $stopped = [PSCustomObject]@{ Instance = 'a'; StayedDown = $true }
            $stopped.PSObject.TypeNames.Insert(0, 'Deserialized.Greenroom.StopResult')
            [PSCustomObject]@{ ExitCode = 1; Records = @(
                $stopped
                [PSCustomObject]@{ GreenroomStream = 'Warning'; Message = 'settled late' }
                [PSCustomObject]@{ GreenroomStream = 'Error'; Message = 'c would not stop'; ErrorId = 'Stuck,Stop-GreenroomSession'; Category = 'OperationStopped' }
            ) }
        }
        $out = @(Stop-GreenroomSession -Name '*' -SettleSeconds 0 -WarningVariable w -WarningAction SilentlyContinue -ErrorAction Continue 2>&1)
        $err = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $obj = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

        ($obj.Instance | Sort-Object) | Should -Be @('a', 'b')
        ($obj | Where-Object Instance -eq 'a').PSObject.TypeNames[0] | Should -Be 'Greenroom.StopResult'
        "$w" | Should -Match 'settled late'

        # One error: the run's own. It explains the non-zero exit, so the generic
        # "exited with code 1" must not be stacked on top of it.
        $err.Count                    | Should -Be 1
        "$($err[0])"                  | Should -Match 'c would not stop'
        $err[0].FullyQualifiedErrorId | Should -Be 'Stuck,Stop-GreenroomSession'
        $err[0].CategoryInfo.Category | Should -Be 'OperationStopped'
    }

    It 'restores only the module''s own types' {
        $r = InModuleScope Greenroom {
            $foreign = [PSCustomObject]@{ X = 1 }
            $foreign.PSObject.TypeNames.Insert(0, 'Deserialized.Some.Other.Type')
            & {
                [CmdletBinding()] param()
                Write-ForwardedRecord -Record @($foreign) -Cmdlet $PSCmdlet | Out-Null
            }
        }
        $r.PSObject.TypeNames[0] | Should -Be 'Deserialized.Some.Other.Type'
    }

    It '-NoElevate refuses each elevated instance and escalates nothing' {
        Mock -ModuleName Greenroom Get-GreenroomInstance { }
        $r = @(Stop-GreenroomSession -Name '*' -NoElevate -SettleSeconds 0 -ErrorAction SilentlyContinue -ErrorVariable e)
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
        $r.Instance | Should -Be @('b')
        $e.Count    | Should -Be 2
    }

    It '-ErrorAction Stop still ends the run at the first refusal' {
        { Stop-GreenroomSession -Name '*' -NoElevate -SettleSeconds 0 -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
    }

    It '-WhatIf escalates nothing' {
        Stop-GreenroomSession -Name '*' -WhatIf
        Restart-GreenroomSession -Name '*' -WhatIf
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }
}

Describe 'The batched elevated command, run for real' {

    # The string Invoke-ElevatedSelf builds is executed in a real child pwsh -- without
    # RunAs, the one part a test cannot click through -- against a stand-in module at the
    # path it imports from. Asserting on the string's TEXT would pass a command that does
    # not parse, or one that stops at the first failing name.

    BeforeAll {
        $script:Stub = Join-Path $TestDrive 'Greenroom'
        New-Item -ItemType Directory -Force $script:Stub | Out-Null
        Set-Content -Path (Join-Path $script:Stub 'Greenroom.psm1') -Value @'
function Stop-GreenroomSession {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(ValueFromPipeline)][string]$Name, [switch]$NoElevate)
    process {
        if (-not $NoElevate) { throw 'the elevated copy must not escalate again' }
        if ($Name -eq 'bad') { Write-Error "failed for $Name"; return }
        Add-Content -Path (Join-Path $PSScriptRoot 'acted.txt') -Value $Name
    }
}
'@
        New-ModuleManifest -Path (Join-Path $script:Stub 'Greenroom.psd1') -RootModule 'Greenroom.psm1' `
            -FunctionsToExport 'Stop-GreenroomSession' -ModuleVersion '0.0.1'

        # Build the command with the stub as the module root, then put the real root back.
        # The mock body runs in this file's scope, so $script: here is this file's.
        Mock -ModuleName Greenroom Start-Process { $script:Inner = $ArgumentList[-1]; [PSCustomObject]@{ ExitCode = 0 } }
        InModuleScope Greenroom -Parameters @{ Stub = $script:Stub } {
            param($Stub)
            $saved = $script:GreenroomModuleRoot
            $script:GreenroomModuleRoot = $Stub
            try {
                Invoke-ElevatedSelf -Command 'Stop-GreenroomSession' -Name 'one', 'bad', 'two' -WarningAction SilentlyContinue | Out-Null
            }
            finally { $script:GreenroomModuleRoot = $saved }
        }
    }

    It 'built a command to run' { $script:Inner | Should -Match 'Stop-GreenroomSession' }

    BeforeEach { Remove-Item (Join-Path $script:Stub 'acted.txt') -ErrorAction Ignore }

    It 'acts on every name in one process, past a failing one, and exits 1' {
        # The child writes the failing name's error to stderr, on purpose. Under Windows
        # PowerShell 5.1 a native command's stderr becomes an ERROR RECORD even when
        # redirected to $null, and ci/check.ps1 runs with ErrorActionPreference Stop, so
        # that expected line ended the test. MEASURED: CI's 5.1 leg failed here; pwsh 7 did not.
        $ErrorActionPreference = 'Continue'
        pwsh -NoLogo -NoProfile -Command $script:Inner 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
        @(Get-Content (Join-Path $script:Stub 'acted.txt')) | Should -Be @('one', 'two')
    }

    It 'exits 0 when every name succeeds' {
        pwsh -NoLogo -NoProfile -Command $script:Inner.Replace("'bad',", '') | Out-Null
        $LASTEXITCODE | Should -Be 0
        @(Get-Content (Join-Path $script:Stub 'acted.txt')) | Should -Be @('one', 'two')
    }
}

Describe 'What the elevated run said, round-tripped for real' {

    # The command Invoke-ElevatedSelf builds, run in a real child pwsh -- the Start-Process
    # mock executes it rather than recording it -- so the CLIXML file is really written by
    # one process and read by another. A test that handed Records in directly would pass a
    # command whose text did not parse, or a file that could not be read back.

    BeforeAll {
        $script:Stub = Join-Path $TestDrive 'Greenroom'
        New-Item -ItemType Directory -Force $script:Stub | Out-Null
        Set-Content -Path (Join-Path $script:Stub 'Greenroom.psm1') -Value @'
function Stop-GreenroomSession {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(ValueFromPipeline)][string]$Name, [switch]$NoElevate)
    process {
        if ($Name -eq 'bad') { Write-Error -Message "failed for $Name" -Category ObjectNotFound; return }
        Write-Warning "warned for $Name"
        [PSCustomObject]@{ PSTypeName = 'Greenroom.StopResult'; Instance = $Name; AssetVersion = [version]'9.8.7' }
    }
}
'@
        New-ModuleManifest -Path (Join-Path $script:Stub 'Greenroom.psd1') -RootModule 'Greenroom.psm1' `
            -FunctionsToExport 'Stop-GreenroomSession' -ModuleVersion '0.0.1'

        function Invoke-RealRun([string]$Root, [string[]]$Names) {
            Mock -ModuleName Greenroom Start-Process {
                $script:RunInner = $ArgumentList[-1]
                # Continue for the child's run: under 5.1 a native command's stderr becomes
                # an error record even when redirected, and the gate runs with Stop.
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { pwsh -NoLogo -NoProfile -Command $ArgumentList[-1] 2>$null | Out-Null; $code = $LASTEXITCODE }
                finally { $ErrorActionPreference = $prev }
                [PSCustomObject]@{ ExitCode = $code }
            }
            InModuleScope Greenroom -Parameters @{ Root = $Root; Names = $Names } {
                param($Root, $Names)
                $saved = $script:GreenroomModuleRoot
                $script:GreenroomModuleRoot = $Root
                try { Invoke-ElevatedSelf -Command 'Stop-GreenroomSession' -Name $Names -WarningAction SilentlyContinue }
                finally { $script:GreenroomModuleRoot = $saved }
            }
        }
    }

    It 'brings back every result, warning and error, in order, and exits 1 for the failure' {
        $run = Invoke-RealRun $script:Stub 'one', 'bad', 'two'
        $run.ExitCode | Should -Be 1

        $results = @($run.Records | Where-Object { -not $_.PSObject.Properties['GreenroomStream'] })
        $results.Instance                 | Should -Be @('one', 'two')
        $results[0].PSObject.TypeNames[0] | Should -Be 'Deserialized.Greenroom.StopResult'
        $results[0].AssetVersion          | Should -Be ([version]'9.8.7')

        # Flattened in the child: a deserialized WarningRecord's Message and an
        # ErrorRecord's category both come back empty, measured on 5.1 and 7.
        @($run.Records | Where-Object GreenroomStream -eq 'Warning').Message | Should -Be @('warned for one', 'warned for two')
        $err = @($run.Records | Where-Object GreenroomStream -eq 'Error')
        $err.Count       | Should -Be 1
        $err[0].Message  | Should -Be 'failed for bad'
        $err[0].Category | Should -Be 'ObjectNotFound'
    }

    It 'leaves nothing behind in temp' {
        Invoke-RealRun $script:Stub 'one' | Out-Null
        $script:RunInner -match 'greenroom-elevated-[0-9a-f]{32}\.clixml' | Should -BeTrue
        Join-Path ([IO.Path]::GetTempPath()) $Matches[0] | Should -Not -Exist
    }

    It 'brings back the reason when the child fails before running the command at all' {
        # A module path that does not import: the child never reaches the command, but
        # its catch still records why, rather than leaving only "exited with code 1".
        $run = Invoke-RealRun (Join-Path $TestDrive 'nowhere') 'one'
        $run.ExitCode | Should -Be 1
        $err = @($run.Records | Where-Object GreenroomStream -eq 'Error')
        $err.Count      | Should -Be 1
        $err[0].ErrorId | Should -Be 'ElevatedRunCrashed'
        $err[0].Message | Should -Not -BeNullOrEmpty
    }
}
