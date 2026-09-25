# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Turn a -Name argument into the registered instance names a session command acts on.

  One resolver for Start-, Stop- and Restart-GreenroomSession, which had drifted into
  three: two fell back to state directories when no name was given and looked the exact
  task up by name, the third enumerated tasks. Registration IS the scheduled task -- it is
  what every one of these commands starts, stops or re-runs, and a state directory with no
  task is a half-uninstalled remnant none of them can act on -- so tasks are the source.

    no name     exactly one registered instance, or an error listing them
    wildcards   every registered instance that matches, sorted; a warning if none do
    otherwise   that instance, if its task exists

  Instance names cannot contain wildcard characters -- ValidatePattern allows only letters,
  digits, dot, dash and underscore -- so a pattern can never be mistaken for a name.

  Errors are written, not thrown, so a caller's -ErrorAction decides.
#>
function Resolve-InstanceName {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Name)

    if ($Name -and -not [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Name)) {
        if (Get-ScheduledTask -TaskName "greenroom-$Name" -ErrorAction SilentlyContinue) { return $Name }
        Write-Error -Category ObjectNotFound -Message "no scheduled task 'greenroom-$Name' -- is '$Name' installed?"
        return
    }

    $registered = @(Get-ScheduledTask -TaskName 'greenroom-*' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.TaskName -replace '^greenroom-', '' } | Sort-Object)

    if (-not $Name) {
        if ($registered.Count -eq 1) { return $registered[0] }
        Write-Error -Category InvalidArgument -Message (
            "an instance name is required. Registered: $(if ($registered) { $registered -join ', ' } else { 'none' })")
        return
    }

    $matched = @($registered | Where-Object { $_ -like $Name })
    if ($matched.Count -eq 0) { Write-Warning "no registered instance matches '$Name'" }
    $matched
}
