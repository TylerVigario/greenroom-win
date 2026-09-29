# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Reveal a hidden greenroom session's window.

.DESCRIPTION
  Replaces `greenroom attach`. Show- and Hide- are approved verbs and they are also
  literally what happens: the window exists the whole time and this calls ShowWindow
  on it, so you get the LIVE session with its full scrollback rather than a resumed
  copy. "Attach" was always a euphemism for a visibility toggle.

  The change is confirmed by observation. ShowWindow returns the window's PREVIOUS
  visibility rather than success, so it reports false on every successful attach; the
  only trustworthy signal is IsWindowVisible changing.

  When the target instance runs elevated and this shell does not, the command
  re-launches itself elevated, because UIPI blocks the window call from a lower
  integrity level and would otherwise report success while doing nothing. Use
  -NoElevate to get a refusal instead of a UAC prompt.

.PARAMETER Name
  The instance to reveal. Accepts pipeline input, including Greenroom.Instance objects
  from Get-GreenroomInstance.

.PARAMETER NoElevate
  Do not escalate when the instance runs elevated. Fails instead, for scripted callers
  that must not block on a prompt.

.EXAMPLE
  Show-GreenroomSession laptop-admin

.EXAMPLE
  Get-GreenroomInstance | Where-Object { -not $_.Visible } | Show-GreenroomSession
  Reveal every hidden session. This is the shape the old `list` could not feed,
  because it emitted formatted text rather than objects.

.EXAMPLE
  Show-GreenroomSession laptop-admin -WhatIf
#>
function Show-GreenroomSession {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [string]$Name,

        [switch]$NoElevate
    )

    process {
        # Resolve first: validation must precede ShouldProcess, or -WhatIf would report
        # that it would show a window for an instance that is not even running.
        # Elevation first: an elevated session cannot be found from an unelevated shell.
        if (Invoke-ElevationFirst -Name $Name -Command 'Show-GreenroomSession' -NoElevate:$NoElevate -Cmdlet $PSCmdlet) { return }
        $target = Resolve-GreenroomTarget -Name $Name -RequireWindow
        if (-not $target) { return }

        # ASK BEFORE ESCALATING. Escalation runs this command again in a NEW process,
        # which starts with its own $WhatIfPreference and $ConfirmPreference -- so
        # anything decided only over there is decided against defaults, not against what
        # the operator asked for. Gating here means -WhatIf never escalates at all, and
        # -Confirm prompts once, in the shell the operator typed in rather than in an
        # elevated window they may never look at.
        if (-not $PSCmdlet.ShouldProcess($target.Instance, 'Show-GreenroomSession')) { return }

        if (-not (Assert-CanActOnInstance -Name $target.Instance -Command 'Show-GreenroomSession' -NoElevate:$NoElevate)) {
            return
        }

        # Success is SILENT: the operator watches a window appear, which beats a line of
        # text, and a pipeline of ten should not print ten confirmations. -Verbose has it.
        if (Set-WindowVisible -Handle $target.Window -Show $true) {
            Write-Verbose "shown '$($target.Instance)' (claude pid $($target.ClaudePid), window $($target.Window))"
            return
        }

        Write-Error -Category InvalidResult -Message (Get-WindowFailureReason -Name $target.Instance)
    }
}
