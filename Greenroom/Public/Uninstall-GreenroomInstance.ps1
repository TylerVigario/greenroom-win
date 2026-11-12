# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Remove one greenroom instance: its task, its running session and its state.

.DESCRIPTION

  NEVER touches the working directory -- it holds your work. The two trust entries
  install seeded in ~/.claude.json are left alone too, and that is a DECISION rather
  than a gap: Claude Code removes them itself, and they are its data, not greenroom's.

      $r = Uninstall-GreenroomInstance -Name modtest
      claude purge --dry-run $r.WorkingDirectory     # then again without --dry-run

  MEASURED against 2.1.322: `claude purge <dir>` finds and removes BOTH slash forms in
  one pass -- the part that makes them tedious to clear by hand -- and --dry-run prints
  the plan first. WorkingDirectory is on the result so that argument is to hand.

  READ THAT PLAN, because it deletes more than the trust entries. On a directory a
  session has actually worked in it also removes the project's transcripts and memory/,
  its file-edit history, and its prompts from history.jsonl. That makes it right for a
  throwaway instance and wrong for a directory whose conversation you want to keep. In
  that second case leave the entry alone: it trusts a DIRECTORY, not an instance, and
  nothing starts there any more.

  A third of the script this replaces is simply gone. -InstallDir and -RemoveScripts
  existed to delete copied scripts and a generated cmd shim out of a bin directory,
  along with the marker-matching that stopped it deleting somebody else's file of the
  same name. A module has none of that: the code lives in the module, and removing the
  code is Uninstall-PSResource. Removing an INSTANCE and removing the SOFTWARE are
  different operations, and conflating them is what made that flag necessary.

  Order matters. The task is unregistered first, so its trigger cannot start a
  replacement watchdog while the rest of this runs. And before that, a task this shell
  cannot remove -- one owned by Administrators, from an unelevated shell -- is refused
  with nothing touched, because the unregister would fail without stopping anything.

  Kills are identity-re-verified immediately before each one, which the script did not
  do: it enumerated, then killed. A pid recorded moments earlier can already belong to
  something else.

.PARAMETER Name
  The instance to remove.

.PARAMETER KeepState
  Leave the state directory (config, window record, logs) in place.

.PARAMETER NoElevate
  Refuse rather than re-launch elevated when the instance runs elevated and this shell
  does not. Without it, every elevated instance named is removed by ONE elevated run at
  the end, under one UAC prompt, and -KeepState goes with it.

.OUTPUTS
  Greenroom.UninstallResult -- what was actually removed, as data rather than prose.

.EXAMPLE
  Uninstall-GreenroomInstance -Name modtest

.EXAMPLE
  Uninstall-GreenroomInstance -Name modtest -WhatIf

.EXAMPLE
  Uninstall-GreenroomInstance -Name modtest -KeepState
  Keeps the logs, which is what you want when removing an instance to diagnose it.
#>
function Uninstall-GreenroomInstance {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Greenroom.UninstallResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        # The same rule Install- enforces. The name becomes a path that is deleted
        # recursively, so anything install could never have created is refused here:
        # `..` would name ~/.claude itself, and `*` every instance's state at once.
        [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,30}[A-Za-z0-9_-])?$')]
        [string]$Name,

        [switch]$KeepState,

        [switch]$NoElevate
    )

    begin {
        $deferred = [System.Collections.Generic.List[string]]::new()
    }

    process {
        $task     = "greenroom-$Name"
        $root     = Get-GreenroomStateRoot
        $stateDir = Join-Path $root $Name

        # The pattern refuses the one quirk known to matter -- Windows drops a trailing dot,
        # so `probe.` would resolve to probe's directory -- but this deletes recursively, so
        # the resolved path is checked as well: exactly <state root>\<Name>, or nothing.
        $full = [IO.Path]::GetFullPath($stateDir)
        if ((Split-Path $full -Parent) -ne [IO.Path]::GetFullPath($root).TrimEnd('\') -or
            (Split-Path $full -Leaf) -ne $Name) {
            Write-CommandError -Cmdlet $PSCmdlet -ErrorId 'StatePathOutsideRoot' -Category InvalidArgument -TargetObject $Name -Message ("'$Name' does not name its own directory under " +
                "$root -- it resolves to $full. Nothing was removed.")
            return
        }

        # Read the config BEFORE anything is removed. config.json lives inside the state
        # directory, so reading it afterwards always returns $null.
        $cfg = Get-InstanceConfig -Name $Name

        $taskExists = [bool](Get-ScheduledTask -TaskPath '\' -TaskName $task -ErrorAction Ignore)
        if (-not $taskExists -and -not (Test-Path -LiteralPath $stateDir)) {
            Write-CommandError -Cmdlet $PSCmdlet -ErrorId 'InstanceNotInstalled' -Category ObjectNotFound -TargetObject $Name `
                -Message "'$Name' is not installed: no task '$task' and no state directory."
            return
        }

        if (-not $PSCmdlet.ShouldProcess($Name, 'Uninstall-GreenroomInstance')) { return }

        # The guards Stop- and Restart- have. Uninstalling the session this shell runs inside
        # kills its own ancestor part-way through, after the task is gone, leaving the state
        # half-removed.
        if (Test-SelfIsInstance -Name $Name) {
            Write-CommandError -Cmdlet $PSCmdlet -ErrorId 'SessionIsSelf' -Category InvalidOperation -TargetObject $Name -Message (
                "'$Name' is the session this shell is running inside. Uninstalling it from here would kill " +
                'this process part-way through and leave it half-removed. Run it from a shell outside the session.')
            return
        }
        # An elevated instance's processes cannot be seen or stopped from an unelevated shell,
        # and its task cannot be unregistered -- the state would go while the watchdog lived on
        # and crash-looped for want of its config. It is removed by one elevated run instead.
        if (-not (Assert-CanActOnInstance -Name $Name -Command 'Uninstall-GreenroomInstance' -NoElevate:$NoElevate -Defer $deferred -Cmdlet $PSCmdlet)) {
            return
        }

        # Refused BEFORE anything is stopped. Unregister-ScheduledTask reports Access is
        # denied as a NON-TERMINATING error -- measured 2026-11-12 from a medium-integrity
        # process against a task an elevated shell had created -- so against a task this
        # shell cannot remove, carrying on would kill the session and delete its state while
        # the task survived, to start a watchdog with no config at the next logon.
        if ($taskExists) {
            $blocked = Get-TaskRewriteBlocker -Name $Name
            if ($blocked) {
                Write-CommandError -Cmdlet $PSCmdlet -ErrorId 'TaskRemovalRefused' -Category PermissionDenied -TargetObject $Name -Message (
                    "refusing to uninstall '$Name' -- $blocked Nothing has been changed.")
                return
            }
        }

        # The task first. Its trigger would otherwise be free to start a replacement
        # watchdog while the kills below are still running.
        #
        # -ErrorAction Stop is load-bearing, as the backstop for any cause the check above
        # cannot predict: without it a refused unregister carries on into the kills. With it,
        # reaching the result means the task really went, so TaskRemoved is a fact.
        if ($taskExists) {
            Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop
            Write-Verbose "task removed: $task"
        }
        else {
            Write-Verbose "no scheduled task named $task"
        }

        $shells   = 'pwsh.exe', 'powershell.exe'
        $watchdog = Stop-VerifiedProcess -ProcessName $shells      -Pattern (Get-InstanceScriptPattern -Script 'greenroom-watchdog.ps1' -Name $Name) -Label 'watchdog'
        $session  = Stop-VerifiedProcess -ProcessName 'claude.exe' -SessionOf $Name                                                                  -Label 'session'
        $launcher = Stop-VerifiedProcess -ProcessName $shells      -Pattern (Get-InstanceScriptPattern -Script 'greenroom-launch.ps1' -Name $Name)   -Label 'launcher'

        $stateRemoved = $false
        if ($KeepState) {
            Write-Verbose "state kept: $stateDir"
        }
        elseif (Test-Path -LiteralPath $stateDir) {
            Remove-Item -LiteralPath $stateDir -Recurse -Force
            $stateRemoved = $true
            Write-Verbose "state removed: $stateDir"
        }

        # The trust entries outlive the instance deliberately -- see the description for
        # why, and for what `claude purge` takes with them.
        if ($cfg -and $cfg.workingDirectory) {
            Write-Verbose ("trust entries for $($cfg.workingDirectory) left in place -- " +
                           'claude purge removes them, and that project''s transcripts with them')
        }

        # Returned rather than printed. The facts about what survived are the ones an
        # operator needs, and as data they can be asserted on instead of read.
        [PSCustomObject]@{
            PSTypeName       = 'Greenroom.UninstallResult'
            Instance         = $Name
            TaskRemoved      = $taskExists
            WatchdogStopped  = $watchdog
            SessionStopped   = $session
            LauncherStopped  = $launcher
            StateRemoved     = $stateRemoved
            WorkingDirectory = if ($cfg) { $cfg.workingDirectory } else { $null }
        }
    }

    end {
        if ($deferred.Count) {
            $carry = if ($KeepState) { @('KeepState') } else { @() }
            Invoke-DeferredElevation -Command 'Uninstall-GreenroomInstance' -Name $deferred -Cmdlet $PSCmdlet -Forward $carry
        }
    }
}
