# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Stop an instance's session, supervisor and launcher, and leave them stopped.

.DESCRIPTION
  The gap this fills: every existing way to get a session to stop also brings it back.
  Restart-GreenroomSession stops it and starts the task again. Hide-GreenroomSession
  only moves the window -- the process keeps running and keeps its handles. Uninstall
  stops it by removing the instance, which is a different operation entirely. So the
  documented answer to "take this one down for a minute" was to stop the watchdog by
  hand and remember not to start anything, which is the procedure the module exists to
  replace.

  The case this was WRITTEN for is an upgrade of the Claude Code CLI, and it depends on
  how the CLI was installed. Both halves below are measured; the WinGet one still
  applies, and this paragraph used to generalise it to every install.

  MEASURED, on a probe process holding its own image, which is the Windows rule the rest
  of this follows from:

    overwrite in place / open for write / truncate   FAIL, "being used by another process"
    delete                                          FAIL, "Access to the path ... is denied"
    RENAME                                          SUCCEEDS
    create a new file at the freed path              SUCCEEDS
    delete the renamed original, still running       FAIL -- succeeds once it exits

  So a running executable cannot be overwritten or deleted, but it CAN be renamed out of
  the way. One rule, and two installers that pick different sides of it.

  WinGet REMOVES. Every session runs through one WinGet\Links\claude.exe symlink into a
  single package file, and MEASURED: with a session running,
  `winget upgrade --id Anthropic.ClaudeCode` fails with 0x8a150003 and
  `remove: Access is denied` against that package file -- the delete row above. Hiding
  the window does not release the handle and restarting only re-takes it, so on a WinGet
  install this command is the workaround, exactly as originally written. The package is
  still published: `winget show --id Anthropic.ClaudeCode` resolves.

  The NATIVE updater RENAMES, so it needs no downtime at all. MEASURED 2026-11-09 with
  five sessions up: ~\.local\bin\claude.exe was renamed to
  claude.exe.old.1794251994594.15092 at 11:19:54 -- an epoch-ms stamp and the pid of a
  session holding it -- and the new 346,487,456-byte build was written at the freed path,
  with .last-update-result.json recording {"outcome":"success","path":"native"}. Sessions
  that started before the rename keep executing the renamed bytes; the orphan is
  329 MB and CANNOT be deleted while any of them maps it.

  Two things follow that are easy to get backwards. `claude --version` starts a NEW
  process from the path, so it reports what is on DISK, not what a running session is
  executing. And on a native install, reaching for this command to make an upgrade safe
  buys nothing.

  What the command is still for, on every install: the gap in the first paragraph --
  taking an instance down deliberately and having it STAY down. Nothing else does that.

  Order matters, and it is the same order Restart uses for the same reason. The watchdog
  goes first: it polls once a second and restarts a dead session, so killing the session
  first means racing a supervisor that is specifically designed to undo you.

  The task is stopped before any of it, so its trigger cannot start a replacement
  watchdog part-way through. That does NOT disable the task -- a stopped instance comes
  back at the next logon, or when Start-GreenroomSession is run, which is the intended
  behaviour for a supervised thing.
  Uninstall-GreenroomInstance is how you make it stay away.

  Everything is driven from the instance NAME, its scheduled task and config.json,
  never from session discovery. Discovery reads CommandLine, which is NULL across
  integrity levels, so a discovery-driven stop would be unusable from an unelevated
  shell against an elevated instance.

  REFUSES to stop the instance the calling shell is running inside. Killing an ancestor
  of this process mid-run means the settle check never executes, so the command cannot
  report the one thing it promises -- that the instance stayed down. Reaching for it
  from inside the session is the natural mistake, which is what makes the guard worth
  having.

.PARAMETER Name
  The instance to stop. Wildcards match every registered instance, so
  `Stop-GreenroomSession *` acts on all of them. If omitted and exactly one instance is
  registered, that one is used. Accepts pipeline input, including Greenroom.Instance objects.

.PARAMETER NoElevate
  Do not escalate when the instance runs elevated. Fails instead. Without it, an elevated
  instance is handed to an elevated copy through UAC -- ONE prompt for every elevated
  instance a pattern or pipeline matched, raised after the others have been stopped.

.PARAMETER SettleSeconds
  How long to watch for the session coming back before reporting. Default 5. A
  surviving watchdog restarts a session within about a second, so this is long enough
  to catch one; 0 skips the check.

.OUTPUTS
  Greenroom.StopResult -- what was actually stopped, as data rather than prose.

.EXAMPLE
  Stop-GreenroomSession laptop-admin

.EXAMPLE
  Stop-GreenroomSession laptop-admin -WhatIf
  Shows what would be stopped without touching anything.

.EXAMPLE
  $running = (Get-GreenroomInstance).Instance
  $running | Stop-GreenroomSession
  # ...whatever actually needs every session down...
  $running | Start-GreenroomSession
  Taking every instance down and bringing back exactly what was up. Capture the names
  FIRST: Get-GreenroomInstance lists running sessions only, so once they are stopped it
  returns nothing, and capturing is also what avoids starting an instance that was down
  on purpose. Note that a Claude Code session you are typing in holds the same binary,
  so this frees it only if the shell running these commands is not itself inside one.

  The middle line is a placeholder because the right command depends on the install.
  `winget upgrade --id Anthropic.ClaudeCode` belongs there on a WinGet install, where
  the package file is locked by every running session. On a native install nothing
  belongs there, because the updater renames rather than removes and needs no downtime.
  See the DESCRIPTION. Either way the capture-first lesson is the point of the example,
  not the command in the middle.
#>
function Stop-GreenroomSession {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Greenroom.StopResult')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [SupportsWildcards()]
        [string]$Name,

        [switch]$NoElevate,

        [ValidateRange(0, 60)]
        [int]$SettleSeconds = 5
    )

    begin {
        # Stopped instances are collected and settled together in `end`, once. Settling
        # inside the loop slept a full SettleSeconds after EACH instance, so `Stop *` over
        # six instances blocked for thirty seconds of pure sleep to learn what one pass
        # learns in five.
        $stopped = [System.Collections.Generic.List[object]]::new()

        # Elevated instances this shell cannot act on, escalated together in `end` so that
        # one UAC prompt covers all of them -- whether they came from one pattern or were
        # piped in one at a time.
        $deferred = [System.Collections.Generic.List[string]]::new()
    }

    process {
        # ONE INVOCATION, looping, as Start-GreenroomSession does. This replaced a fan-out
        # that re-invoked the command once per matched instance, and that was wrong in
        # three ways: -Confirm's "Yes to All" and "No to All" reset for every nested call,
        # since each had its own ShouldProcess state; a THROW in one nested call -- a
        # declined UAC prompt -- unwound through the loop and abandoned every instance after
        # it; and each nested call resolved its name all over again.
        foreach ($n in @(Resolve-InstanceName -Name $Name -Cmdlet $PSCmdlet)) {
            if (Test-SelfIsInstance -Name $n) {
                Write-Error -Category InvalidOperation -Message (
                    "'$n' is the session this shell is running inside. Stopping it from here would kill " +
                    'this process part-way through, so the settle check would never run and this could not ' +
                    'report whether it stayed down. Run it from a shell outside the session.')
                continue
            }

            # Gated before escalation, for the same reason Restart-GreenroomSession gates
            # there: a new elevated process starts with its own $WhatIfPreference and
            # $ConfirmPreference, so -WhatIf must stop here rather than be re-decided against
            # defaults over there, and -Confirm must prompt in the shell the operator typed in.
            if (-not $PSCmdlet.ShouldProcess($n, 'Stop-GreenroomSession')) { continue }

            if (-not (Assert-CanActOnInstance -Name $n -Command 'Stop-GreenroomSession' -NoElevate:$NoElevate -Defer $deferred)) {
                continue
            }

            # Before the kills, so the trigger cannot launch a replacement watchdog while
            # they run. This only ends a task currently executing; it does not disable it.
            Stop-ScheduledTask -TaskName "greenroom-$n" -ErrorAction SilentlyContinue

            $shells = 'pwsh.exe', 'powershell.exe'

            $watchdog = Stop-VerifiedProcess -ProcessName $shells      -Pattern (Get-InstanceScriptPattern -Script 'greenroom-watchdog.ps1' -Name $n) -Label 'watchdog'
            $session  = Stop-VerifiedProcess -ProcessName 'claude.exe' -SessionOf $n                                                                  -Label 'session'
            $launcher = Stop-VerifiedProcess -ProcessName $shells      -Pattern (Get-InstanceScriptPattern -Script 'greenroom-launch.ps1' -Name $n)   -Label 'launcher'

            if (($watchdog + $session + $launcher) -eq 0) { Write-Verbose "nothing was running for '$n'" }

            $stopped.Add([PSCustomObject]@{ Instance = $n; Watchdog = $watchdog; Session = $session; Launcher = $launcher })
        }
    }

    end {
        # The elevated copy stops and settles its own instances, and its results do not
        # cross back -- only whether it succeeded does -- so they are reported here as an
        # error or not at all, as they were when each was escalated on its own.
        if ($deferred.Count) { Invoke-DeferredElevation -Command 'Stop-GreenroomSession' -Name $deferred -Cmdlet $PSCmdlet }

        # Confirm by observation, not by the kills returning. "Stopped" is only meaningful
        # if it is still stopped a moment later: a watchdog that was missed -- one belonging
        # to a stale asset version, say, whose command line does not match the pattern --
        # puts the session straight back, and the counts would still look like success.
        #
        # Counted iterations rather than a wall-clock deadline. A deadline loop with the
        # sleep inside it degenerates into a busy-wait the moment the sleep does not
        # actually sleep -- which is exactly what happens under test.
        $cameBack = @{}
        if ($SettleSeconds -gt 0 -and $stopped.Count -gt 0) {
            for ($i = 0; $i -lt $SettleSeconds * 2; $i++) {
                Start-Sleep -Milliseconds 500
                foreach ($s in $stopped) {
                    if ($cameBack.ContainsKey($s.Instance)) { continue }
                    $back = @(Get-GreenroomInstance -Name $s.Instance -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
                    if ($back.Count -gt 0 -and -not $back[0].Opaque) {
                        $cameBack[$s.Instance] = $true
                        Write-Warning ("'$($s.Instance)' came back up while settling -- something is still supervising it. " +
                                       "Check for a watchdog from a different module version: Get-CimInstance Win32_Process " +
                                       "-Filter `"Name='pwsh.exe'`" | Where-Object CommandLine -match 'greenroom-watchdog'")
                    }
                }
                if ($cameBack.Count -eq $stopped.Count) { break }
            }
        }

        foreach ($s in $stopped) {
            $stayedDown = -not $cameBack.ContainsKey($s.Instance)

            # An unelevated shell cannot read an elevated session's command line, so absence
            # is not evidence here. Saying so beats reporting a confirmation never made.
            $confirmed = $stayedDown
            if ((Test-InstanceElevated -Name $s.Instance) -and -not (Test-SelfElevated)) {
                $confirmed = $false
                Write-Warning ("cannot confirm '$($s.Instance)' stopped from an unelevated shell: an elevated " +
                               'session is unreadable here. Re-check with Get-GreenroomInstance from an elevated shell.')
            }

            # Returned rather than printed, matching Uninstall-GreenroomInstance: the facts
            # about what stopped are the ones an operator needs, and as data they can be
            # asserted on instead of read.
            [PSCustomObject]@{
                PSTypeName      = 'Greenroom.StopResult'
                Instance        = $s.Instance
                WatchdogStopped = $s.Watchdog
                SessionStopped  = $s.Session
                LauncherStopped = $s.Launcher
                StayedDown      = $stayedDown
                Confirmed       = $confirmed
            }
        }
    }
}
