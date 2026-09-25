# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Start an instance that is stopped. Leave one that is running alone.

.DESCRIPTION
  The counterpart to Stop-GreenroomSession, and the gap it left. Until this existed the
  only way to bring a stopped instance back was Restart-GreenroomSession, which is the
  wrong verb and the wrong behaviour: against an instance that turns out to be RUNNING it
  kills the watchdog, the session and the launcher first. Start never kills anything. An
  instance that is already up is returned as it is.

  It also takes the instance NAME, resolved against registered scheduled tasks, rather
  than a running session -- because the thing being started has no running session.
  Get-GreenroomInstance lists only running sessions, so after a stop it returns nothing,
  and piping it anywhere does nothing. MEASURED: the upgrade procedure documented in 0.4.0,
  `Get-GreenroomInstance | Restart-GreenroomSession` after stopping everything, brought
  nothing back up. Capture the names while they are running instead -- see the example.

  NO ELEVATION IS NEEDED TO START, even for an elevated instance, and this deliberately
  does not escalate. The task launches at its own run level; starting it is not acting on
  the elevated process. Measured: an unelevated shell started an elevated instance through
  its task. What an unelevated shell cannot do is CONFIRM it -- an elevated session's
  command line is unreadable from a lower integrity level -- so it says so, rather than
  reporting a check that never ran.

  A running instance that is unreadable from this shell looks stopped, so the task is
  started anyway. That is harmless: the second watchdog finds the instance's named mutex
  already held and exits at once.

.PARAMETER Name
  The instance to start. Wildcards match every registered instance, so
  `Start-GreenroomSession *` starts all of them that are down. If omitted and exactly
  one instance is registered, that one is used. Accepts pipeline input, including names
  captured from Get-GreenroomInstance while the instances were running.

.PARAMETER TimeoutSeconds
  How long to wait for each session to appear. Default 45.

.OUTPUTS
  Greenroom.Instance for each instance that is up afterwards -- started, or already
  running. Nothing for one that could not be confirmed.

.EXAMPLE
  Start-GreenroomSession laptop-admin

.EXAMPLE
  Start-GreenroomSession *
  Start every registered instance that is not running.

.EXAMPLE
  $running = (Get-GreenroomInstance).Instance
  $running | Stop-GreenroomSession
  winget upgrade --id Anthropic.ClaudeCode
  $running | Start-GreenroomSession
  Upgrading the CLI every session holds open. The names are captured FIRST: after the
  stop Get-GreenroomInstance lists nothing, and this also brings back exactly what was
  running rather than an instance that was deliberately down.
#>
function Start-GreenroomSession {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Greenroom.Instance')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [SupportsWildcards()]
        [string]$Name,

        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 45
    )

    process {
        $names = @(Resolve-InstanceName -Name $Name -Cmdlet $PSCmdlet)

        foreach ($n in $names) {
            $now = @(Get-GreenroomInstance -Name $n -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
            if ($now.Count -gt 0 -and -not $now[0].Opaque) {
                Write-Verbose "'$n' is already running (claude pid $($now[0].ClaudePid)) -- nothing to start"
                $now[0]
                continue
            }

            if (-not $PSCmdlet.ShouldProcess($n, 'Start-GreenroomSession')) { continue }

            # Same warning Restart gives, for the same reason: the task names a VERSIONED
            # asset path, so starting it brings the instance up on whatever version it was
            # registered with, not the module that is loaded.
            $asset = Get-InstanceAssetVersion -Name $n
            if ($asset -and $asset -ne $script:GreenroomModuleVersion) {
                Write-Warning ("'$n' runs $asset assets while module $script:GreenroomModuleVersion is loaded. " +
                               "Starting runs the task, so it will come up on $asset. To move it: " +
                               "Update-GreenroomInstance -Name $n")
            }

            Start-ScheduledTask -TaskName "greenroom-$n"

            # Confirm by observation: the task succeeding only means the watchdog was
            # launched, not that a session came up behind it. Counted polls rather than a
            # wall-clock deadline, so a sleep that does not sleep cannot become a busy-wait.
            $up = $null
            for ($i = 0; $i -lt $TimeoutSeconds * 2; $i++) {
                Start-Sleep -Milliseconds 500
                $got = @(Get-GreenroomInstance -Name $n -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
                if ($got.Count -gt 0 -and -not $got[0].Opaque) { $up = $got[0]; break }
            }
            if ($up) { $up; continue }

            if ((Test-InstanceElevated -Name $n) -and -not (Test-SelfElevated)) {
                Write-Warning ("started '$n', but cannot confirm it from an unelevated shell: an elevated " +
                               'session is unreadable here. Re-check with Get-GreenroomInstance from an elevated shell.')
                continue
            }

            Write-Error -Category OperationTimeout -Message (
                "'$n' did not come up within $TimeoutSeconds s. If its watchdog is still alive -- in crash-loop " +
                "backoff, say -- the new one exits on the instance's mutex and nothing starts until the backoff " +
                "ends; Restart-GreenroomSession $n stops it first. Check: Get-Content " +
                "`"$(Join-Path (Get-GreenroomStateRoot) "$n\watchdog.log")`" -Tail 20")
        }
    }
}
