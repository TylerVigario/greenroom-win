# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Remove one greenroom instance: its task, its running session and its state.

.DESCRIPTION

  NEVER touches the working directory -- it holds your work. Trust entries in
  ~/.claude.json are also left alone, which is a known gap rather than a decision:
  install seeds two per instance and nothing removes them.

  A third of the script this replaces is simply gone. -InstallDir and -RemoveScripts
  existed to delete copied scripts and a generated cmd shim out of a bin directory,
  along with the marker-matching that stopped it deleting somebody else's file of the
  same name. A module has none of that: the code lives in the module, and removing the
  code is Uninstall-PSResource. Removing an INSTANCE and removing the SOFTWARE are
  different operations, and conflating them is what made that flag necessary.

  Order matters. The task is unregistered first, so its trigger cannot start a
  replacement watchdog while the rest of this runs.

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
        $esc      = [regex]::Escape($Name)

        # The pattern refuses the one quirk known to matter -- Windows drops a trailing dot,
        # so `probe.` would resolve to probe's directory -- but this deletes recursively, so
        # the resolved path is checked as well: exactly <state root>\<Name>, or nothing.
        $full = [IO.Path]::GetFullPath($stateDir)
        if ((Split-Path $full -Parent) -ne [IO.Path]::GetFullPath($root).TrimEnd('\') -or
            (Split-Path $full -Leaf) -ne $Name) {
            Write-Error -Category InvalidArgument -Message ("'$Name' does not name its own directory under " +
                "$root -- it resolves to $full. Nothing was removed.")
            return
        }

        # Read the config BEFORE anything is removed. config.json lives inside the state
        # directory, so reading it afterwards always returns $null.
        $cfg = Get-InstanceConfig -Name $Name

        $taskExists = [bool](Get-ScheduledTask -TaskPath '\' -TaskName $task -ErrorAction Ignore)
        if (-not $taskExists -and -not (Test-Path -LiteralPath $stateDir)) {
            Write-Error -Category ObjectNotFound -Message "'$Name' is not installed: no task '$task' and no state directory."
            return
        }

        if (-not $PSCmdlet.ShouldProcess($Name, 'Uninstall-GreenroomInstance')) { return }

        # The guards Stop- and Restart- have. Uninstalling the session this shell runs inside
        # kills its own ancestor part-way through, after the task is gone, leaving the state
        # half-removed.
        if (Test-SelfIsInstance -Name $Name) {
            Write-Error -Category InvalidOperation -Message (
                "'$Name' is the session this shell is running inside. Uninstalling it from here would kill " +
                'this process part-way through and leave it half-removed. Run it from a shell outside the session.')
            return
        }
        # An elevated instance's processes cannot be seen or stopped from an unelevated shell,
        # and its task cannot be unregistered -- the state would go while the watchdog lived on
        # and crash-looped for want of its config. It is removed by one elevated run instead.
        if (-not (Assert-CanActOnInstance -Name $Name -Command 'Uninstall-GreenroomInstance' -NoElevate:$NoElevate -Defer $deferred)) {
            return
        }

        # The task first. Its trigger would otherwise be free to start a replacement
        # watchdog while the kills below are still running.
        if ($taskExists) {
            Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $task -Confirm:$false
            Write-Verbose "task removed: $task"
        }
        else {
            Write-Verbose "no scheduled task named $task"
        }

        $shells   = 'pwsh.exe', 'powershell.exe'
        $watchdog = Stop-VerifiedProcess -ProcessName $shells      -Pattern ('greenroom-watchdog.*-Instance\s+"?' + $esc + '("|\s|$)') -Label 'watchdog'
        $session  = Stop-VerifiedProcess -ProcessName 'claude.exe' -Pattern ('--remote-control\s+"?' + $esc + '("|\s|$)')                 -Label 'session'
        $launcher = Stop-VerifiedProcess -ProcessName $shells      -Pattern ('greenroom-launch.*-Instance\s+"?' + $esc + '("|\s|$)')   -Label 'launcher'

        $stateRemoved = $false
        if ($KeepState) {
            Write-Verbose "state kept: $stateDir"
        }
        elseif (Test-Path -LiteralPath $stateDir) {
            Remove-Item -LiteralPath $stateDir -Recurse -Force
            $stateRemoved = $true
            Write-Verbose "state removed: $stateDir"
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
