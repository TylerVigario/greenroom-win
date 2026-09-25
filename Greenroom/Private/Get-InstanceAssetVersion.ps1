# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Which module version's assets an instance's task actually runs.

  Register-GreenroomTask builds the action from $GreenroomModuleRoot, which is the
  VERSIONED module directory, so the task names the assets of the version that registered
  it and keeps naming them forever. Module versions install side by side, and that is the
  whole problem:

    - Import-Module resolves the NEWEST version, so Get-Module reports the new one
    - the task keeps executing ...\Greenroom\<old>\Assets\greenroom-watchdog.vbs
    - Restart-GreenroomSession does NOT change it -- it re-runs the task, and the task
      re-runs the old path

  So staging a new module and restarting leaves the supervisor on the old code while every
  version readout says otherwise. Nothing errors. Measured on the reference host: with
  0.2.0 staged, the task and all live watchdog and launcher command lines still named
  0.1.0\Assets. Only Install-GreenroomInstance rewrites the task, which is why it is
  mandatory on a version bump rather than merely idempotent.

  Returns $null when the version cannot be determined -- an absent task, or a module
  installed somewhere that carries no version in its path. Unknown is NOT reported as
  drift: a false alarm here would train the operator to ignore the real one.
#>
function Get-InstanceAssetVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param([Parameter(Mandatory)][string]$Name)

    $task = Get-ScheduledTask -TaskPath '\' -TaskName "greenroom-$Name" -ErrorAction Ignore
    if (-not $task) { return $null }

    foreach ($action in @($task.Actions)) {
        # Both slash forms, because the path is only ever read back, never built here.
        if ($action.Arguments -match 'Greenroom[\\/](\d+\.\d+(?:\.\d+){0,2})[\\/]Assets') {
            return [version]$Matches[1]
        }
    }
    return $null
}
