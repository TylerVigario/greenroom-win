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
        [string]$Name,

        [switch]$KeepState
    )

    process {
        $task     = "greenroom-$Name"
        $stateDir = Join-Path (Get-GreenroomStateRoot) $Name
        $esc      = [regex]::Escape($Name)

        # Read the config BEFORE anything is removed. config.json lives inside the state
        # directory, so reading it afterwards always returns $null.
        $cfg = Get-InstanceConfig -Name $Name

        $taskExists = [bool](Get-ScheduledTask -TaskPath '\' -TaskName $task -ErrorAction Ignore)
        if (-not $taskExists -and -not (Test-Path $stateDir)) {
            Write-Error -Category ObjectNotFound -Message "'$Name' is not installed: no task '$task' and no state directory."
            return
        }

        if (-not $PSCmdlet.ShouldProcess($Name, 'Uninstall-GreenroomInstance')) { return }

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
        elseif (Test-Path $stateDir) {
            Remove-Item $stateDir -Recurse -Force
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
}
