# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Why this shell cannot register or remove an instance's task, or $null when nothing is
  known to stop it.

  A BLOCKER, not a test: the answer is truthy when the caller must NOT go ahead. It is a
  sentence rather than a bool so the caller can say what is wrong and what to do about it.

  It exists because the failure it predicts is quiet. `Register-ScheduledTask` and
  `Unregister-ScheduledTask` both report `Access is denied` as a NON-TERMINATING error, so
  an attempt carries straight on past it. Measured on the reference host: on 2026-11-11
  three instances printed `Updated 0.7.2 -> 0.7.3` while their tasks still named 0.7.2,
  and on 2026-11-12 an unregister from a medium-integrity process, against a task an
  elevated shell had created, carried on with the task still there.

  Only causes that are CERTAIN are reported. A false refusal blocks work that would have
  succeeded, which is worse than the loud failure an attempt now produces, so anything
  unreadable or ambiguous returns $null and lets the attempt decide.
#>
function Get-TaskRewriteBlocker {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,

        # Whether the task the caller is about to register runs RunLevel Highest. Uninstall
        # registers nothing and leaves it off.
        [bool]$Elevated
    )

    # An elevated caller can do all of it, so there is nothing to refuse.
    if (Test-SelfElevated) { return $null }

    # Certain: RunLevel Highest cannot be registered without an elevated caller, whoever
    # owns the task.
    if ($Elevated) {
        return ("'$Name' runs elevated, and registering a task with RunLevel Highest requires " +
                'an elevated caller. Run this from an elevated shell.')
    }

    # Certain enough: a task owned by an administrative principal cannot be rewritten or
    # removed by an unelevated caller, whatever its own RunLevel.
    #
    # The owner is set when the task is CREATED, and a -Force replace keeps it. Measured
    # 2026-11-12 on the reference host: a task created from an elevated shell came out owned
    # by Administrators and stayed that way through a replace, while an instance re-registered
    # from an elevated shell -- RunLevel Highest, which nothing else can register -- kept the
    # user owner it was created with. So this reads the task as it is, rather than reasoning
    # from who last touched it.
    #
    # Compared by SID, never by name: Owner is a localized account name, and
    # 'VORDEFINIERT\Administratoren' is the same group as 'BUILTIN\Administrators'.
    # Restricted to these three on purpose -- "the owner is not me" is NOT the same question
    # as "I cannot change this", and refusing on it would block legitimate work in setups
    # this has never seen.
    $file = Join-Path $env:SystemRoot "System32\Tasks\greenroom-$Name"
    try {
        $acl = Get-Acl -LiteralPath $file -ErrorAction Stop
        $sid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    }
    catch { return $null }   # unreadable from here: do not predict, let the attempt decide
    if (-not $sid) { return $null }

    $administrative = @(
        'S-1-5-32-544'   # BUILTIN\Administrators -- what a task created from an elevated shell gets
        'S-1-5-18'       # NT AUTHORITY\SYSTEM
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'   # NT SERVICE\TrustedInstaller
    )
    if ($administrative -contains $sid) {
        $who = if ($acl.Owner) { $acl.Owner } else { $sid }
        return ("the scheduled task for '$Name' is owned by $who, which an unelevated caller " +
                'cannot change. A task takes its owner when it is created, and one created from ' +
                'an elevated shell belongs to Administrators. Run this from an elevated shell.')
    }

    return $null
}
