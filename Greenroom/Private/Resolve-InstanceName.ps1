# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Registered instance names, and the resolution of a -Name argument against them.

  Registration IS the scheduled task: it is what Start-, Stop-, Restart- and
  Update-GreenroomInstance start, stop, re-run or re-register, and a state directory with no
  task is a remnant none of them can act on. So tasks are the source, read in ONE place --
  these commands had drifted into separate copies of the same enumeration.

  ROOT FOLDER ONLY. Register-GreenroomTask registers without -TaskPath, which is the root,
  and Get-ScheduledTask without -TaskPath searches EVERY folder: a same-named task elsewhere
  -- left behind by a manual import, say -- would otherwise list the instance twice, which
  both breaks the "exactly one" rule and acts on it twice under a wildcard.

  -ErrorAction IGNORE, not SilentlyContinue, on every lookup. On a real host a lookup that
  finds nothing raises a CIM "not found" error, and SilentlyContinue only hides it: the
  record still lands in $Error and in the caller's -ErrorVariable, AHEAD of the error the
  command actually reports. MEASURED: `Stop-GreenroomSession nope -ErrorVariable e` gave
  $e[0] from Get-ScheduledTask ('CmdletizationQuery_NotFound'). For a probe, not found is
  the answer, not a failure, so it should leave nothing behind.
#>
function Get-RegisteredInstanceName {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @(Get-ScheduledTask -TaskPath '\' -TaskName 'greenroom-*' -ErrorAction Ignore |
      ForEach-Object { $_.TaskName -replace '^greenroom-', '' } | Sort-Object -Unique)
}

<#
  Turn a -Name argument into the instance names a session command acts on.

    no name     exactly one registered instance, or an error listing them
    wildcards   every registered instance that matches, sorted; a warning if none do
    otherwise   that instance, if its task exists

  Instance names cannot contain wildcard characters -- ValidatePattern allows only letters,
  digits, dot, dash and underscore -- so a pattern can never be mistaken for a name.

  ERRORS AND WARNINGS ARE WRITTEN THROUGH THE CALLER'S $PSCmdlet. Written from here, they
  were attributed to this private function: `Stop-GreenroomSession nope` reported
  "Resolve-InstanceName : no scheduled task", with an error id naming a function the operator
  cannot see or call. Through the caller they name the command that was typed, and the
  caller's -ErrorAction and -WarningAction decide what happens to them.
#>
function Resolve-InstanceName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Name,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet
    )

    if ($Name -and -not [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Name)) {
        if (Get-ScheduledTask -TaskPath '\' -TaskName "greenroom-$Name" -ErrorAction Ignore) { return $Name }
        $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [System.Management.Automation.ItemNotFoundException]::new(
                "no scheduled task 'greenroom-$Name' -- is '$Name' installed?"),
            'InstanceNotRegistered', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Name))
        return
    }

    # @() IS LOAD-BEARING. A function returning a one-element array has it unrolled to a
    # bare string on the way out, and indexing a string returns a CHARACTER: with a single
    # instance named 'probe', $registered[0] was 'p', and the command went on to start a
    # task called 'greenroom-p'. Caught by the no-name test, not by reading it.
    $registered = @(Get-RegisteredInstanceName)

    if (-not $Name) {
        if ($registered.Count -eq 1) { return $registered[0] }
        $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [System.ArgumentException]::new(
                "an instance name is required. Registered: $(if ($registered) { $registered -join ', ' } else { 'none' })"),
            'InstanceNameRequired', [System.Management.Automation.ErrorCategory]::InvalidArgument, $null))
        return
    }

    $matched = @($registered | Where-Object { $_ -like $Name })
    if ($matched.Count -eq 0) { $Cmdlet.WriteWarning("no registered instance matches '$Name'") }
    $matched
}
