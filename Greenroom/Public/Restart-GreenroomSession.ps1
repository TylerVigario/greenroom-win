# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Restart an instance's session, supervisor and launcher.

.DESCRIPTION
  This exists because the procedure it replaces did not restart anything. The advice
  was to stop the watchdog by process and then run Start-ScheduledTask -- but stopping
  the watchdog leaves the session running, and the new watchdog then ADOPTS it. The
  result is the old session with a new supervisor, which is precisely not a restart.
  Measured on the reference host: an instance reinstalled with -Elevated kept running
  at Medium integrity through exactly that sequence.

  Order matters. The watchdog goes first, because killing the session first makes the
  watchdog immediately restart it, and the subsequent task start is then a no-op
  against a session that never went away.

  Everything is driven from the instance NAME, its scheduled task and config.json,
  never from session discovery. Discovery reads CommandLine, which is NULL across
  integrity levels, so a discovery-driven restart would be unusable from an unelevated
  shell against an elevated instance.

  REFUSES to restart the instance the calling shell is running inside. That would kill
  an ancestor of this process before the task is started again, leaving the instance
  down rather than restarted -- and calling it from inside the session is the most
  natural way to reach for it.

.PARAMETER Name
  The instance to restart. Wildcards match every registered instance, so
  `Restart-GreenroomSession *` acts on all of them. If omitted and exactly one instance is
  registered, that one is used. Accepts pipeline input, including Greenroom.Instance objects.

.PARAMETER NoElevate
  Do not escalate when the instance runs elevated. Fails instead.

.PARAMETER TimeoutSeconds
  How long to wait for the replacement session to appear. Default 45.

.OUTPUTS
  Greenroom.Instance for the restarted session, or nothing if it could not be confirmed.

.EXAMPLE
  Restart-GreenroomSession laptop-admin

.EXAMPLE
  Restart-GreenroomSession laptop-admin -WhatIf
  Shows what would be stopped without touching anything.

.EXAMPLE
  Get-GreenroomInstance | Where-Object { $null -eq $_.Window } | Restart-GreenroomSession
  Restart every instance whose window cannot be resolved, which is how an instance
  gets a window record if it started before records existed.
#>
function Restart-GreenroomSession {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Greenroom.Instance')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [SupportsWildcards()]
        [string]$Name,

        [switch]$NoElevate,

        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 45
    )

    process {
        # ONE INVOCATION, looping, as Start-GreenroomSession does -- see the note in
        # Stop-GreenroomSession for what the per-instance fan-out it replaced got wrong.
        #
        # Deliberately SEQUENTIAL: each instance is confirmed up before the next is touched.
        # Instances are staggered at logon so they do not race each other starting, and
        # restarting them all at once would bring that race straight back.
        foreach ($n in @(Resolve-InstanceName -Name $Name -Cmdlet $PSCmdlet)) {
            if (Test-SelfIsInstance -Name $n) {
                Write-Error -Category InvalidOperation -Message (
                    "'$n' is the session this shell is running inside. Restarting it from here would kill " +
                    'this process partway through, before the task is started again, leaving the instance down ' +
                    "rather than restarted. Run it from a shell outside the session.")
                continue
            }

            # Gated before escalation: a new elevated process starts with its own
            # $WhatIfPreference and $ConfirmPreference, so -WhatIf must stop here rather than
            # be re-decided against defaults over there, and -Confirm must prompt in the
            # shell the operator typed in.
            if (-not $PSCmdlet.ShouldProcess($n, 'Restart-GreenroomSession')) { continue }

            # A declined UAC prompt THROWS; caught so it cannot abandon the instances after
            # this one, and reported through this command so -ErrorAction still decides.
            try { $proceed = Assert-CanActOnInstance -Name $n -Command 'Restart-GreenroomSession' -NoElevate:$NoElevate }
            catch { $PSCmdlet.WriteError($_); continue }
            if (-not $proceed) { continue }

            # Said BEFORE anything is stopped, while it is still actionable. A restart re-runs
            # the task and the task names the VERSIONED asset path, so with a new module merely
            # staged this brings the old version straight back up -- silently, and looking
            # exactly like a successful upgrade. Measured on a host that did precisely that.
            $asset = Get-InstanceAssetVersion -Name $n
            if ($asset -and $asset -ne $script:GreenroomModuleVersion) {
                Write-Warning ("'$n' runs $asset assets while module $script:GreenroomModuleVersion is loaded. " +
                               "Restarting re-runs the task, so it will come back up on $asset. To move it: " +
                               "Update-GreenroomInstance -Name $n")
            }

            $esc    = [regex]::Escape($n)
            $shells = 'pwsh.exe', 'powershell.exe'
            $killed =
                (Stop-VerifiedProcess -ProcessName $shells      -Pattern ('greenroom-watchdog.*-Instance\s+"?' + $esc + '("|\s|$)') -Label 'watchdog') +
                (Stop-VerifiedProcess -ProcessName 'claude.exe' -Pattern ('--remote-control\s+"?' + $esc + '("|\s|$)')                 -Label 'session')  +
                (Stop-VerifiedProcess -ProcessName $shells      -Pattern ('greenroom-launch.*-Instance\s+"?' + $esc + '("|\s|$)')   -Label 'launcher')

            if ($killed -eq 0) { Write-Verbose "nothing was running for '$n'" }

            Start-Sleep -Seconds 2
            Start-ScheduledTask -TaskName "greenroom-$n"

            # Confirm by observation: the task returning success only means the watchdog was
            # launched, not that a session came up behind it. Counted polls, not a wall-clock
            # deadline -- under test a mocked sleep turned the deadline loop into a busy-wait
            # that spun for the full timeout.
            $up = $null
            for ($i = 0; $i -lt [int][math]::Ceiling($TimeoutSeconds / 0.75); $i++) {
                Start-Sleep -Milliseconds 750
                $got = @(Get-GreenroomInstance -Name $n -WarningAction SilentlyContinue)
                if ($got.Count -eq 1 -and -not $got[0].Opaque) { $up = $got[0]; break }
            }
            if ($up) { $up; continue }

            # An unelevated shell cannot read an elevated session's command line, so absence
            # here is not evidence of failure. Saying so beats reporting a false one.
            if ((Test-InstanceElevated -Name $n) -and -not (Test-SelfElevated)) {
                Write-Warning ("cannot confirm '$n' from an unelevated shell: an elevated session is " +
                               'unreadable here. Re-check with Get-GreenroomInstance from an elevated shell.')
                continue
            }

            Write-Error -Category OperationTimeout -Message (
                "'$n' did not come up within $TimeoutSeconds s. Check: Get-Content " +
                "`"$(Join-Path (Get-GreenroomStateRoot) "$n\watchdog.log")`" -Tail 20")
        }
    }
}
