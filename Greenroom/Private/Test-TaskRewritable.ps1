# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Why this shell could not re-register an instance's task, or $null when it can.

  Returned as a sentence rather than a bool so the caller can say what is wrong. The
  point is to REFUSE before attempting: `Register-ScheduledTask` reports `Access is
  denied` as a NON-TERMINATING error, so an attempt that fails this way carries on and
  the caller reports a success for a task it did not change. Measured 2026-11-11 on the
  reference host, where three instances printed `Updated 0.7.2 -> 0.7.3` while their
  tasks were still on 0.7.2 afterwards.

  Only causes that are CERTAIN are reported here. A false refusal blocks an update that
  would have worked, which is worse than the loud failure the attempt now produces, so
  anything unreadable or ambiguous returns $null and lets the attempt decide.
#>
function Test-TaskRewritable {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # An elevated caller can rewrite any of these, so there is nothing to refuse.
    if (Test-SelfElevated) { return $null }

    # Certain: RunLevel Highest cannot be registered without an elevated caller at all,
    # whoever owns the task.
    if (Test-InstanceElevated -Name $Name) {
        return ("'$Name' is configured to run elevated, and registering a task with " +
                'RunLevel Highest requires an elevated caller.')
    }

    # Certain enough: a task registered from an elevated shell is owned by
    # BUILTIN\Administrators, and an unelevated caller cannot rewrite it whatever the
    # task's own RunLevel. This is a property of WHO REGISTERED IT, not of the instance.
    # On the reference host three of four unelevated instances were in that state, each
    # matching a time an elevated session had re-registered it, and the one never touched
    # from an elevated shell updated from a normal prompt without complaint.
    #
    # Restricted to the well-known administrative principals on purpose. "Owner is not
    # me" is NOT the same question as "I cannot write this", and refusing on it would
    # block legitimate updates in setups this has never seen.
    $file = Join-Path $env:SystemRoot "System32\Tasks\greenroom-$Name"
    try { $owner = (Get-Acl -LiteralPath $file -ErrorAction Stop).Owner }
    catch { return $null }   # unreadable from here: do not predict, let the attempt decide
    if (-not $owner) { return $null }

    $elevatedOwners = @(
        'BUILTIN\Administrators'
        'NT AUTHORITY\SYSTEM'
        'NT SERVICE\TrustedInstaller'
    )
    if ($elevatedOwners -contains $owner) {
        return ("the scheduled task for '$Name' is owned by $owner, which an unelevated " +
                'caller cannot rewrite. It is owned that way because it was registered ' +
                'from an elevated shell.')
    }

    return $null
}
