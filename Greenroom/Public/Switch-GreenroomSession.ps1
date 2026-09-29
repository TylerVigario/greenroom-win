# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Reveal a hidden greenroom session, or hide a revealed one.

.DESCRIPTION
  Replaces `greenroom toggle`. Show it if it is hidden, hide it if it is showing.

  Switch- is the approved verb whose documented meaning is alternation, which is the
  honest mapping even though "toggle" reads more obviously. There is no approved
  Toggle- verb.

  This exists rather than leaving the caller to branch because the point of a toggle is
  not caring what state the window is in: press it to bring the session up, press it
  again to put it away. It is the one thing that would be strictly worse as a
  conditional, and the natural thing to bind to a hotkey:

      $i = Get-GreenroomInstance laptop-admin
      if ($i.Visible) { Hide-GreenroomSession laptop-admin } else { Show-GreenroomSession laptop-admin }

  VISIBILITY IS READ AT THE POINT OF DECISION, not up front. The script this replaces
  read IsWindowVisible once near the top and acted on that value later, so anything
  that changed the window in between -- the operator clicking it, another shell, the
  session exiting a modal -- made toggle do the exact opposite of what was wanted. The
  read here is the last thing before the switch is chosen.

.PARAMETER Name
  The instance to switch. Accepts pipeline input, including Greenroom.Instance objects.

.PARAMETER NoElevate
  Do not escalate when the instance runs elevated. Fails instead.

.EXAMPLE
  Switch-GreenroomSession laptop-admin

.EXAMPLE
  Switch-GreenroomSession laptop-admin -WhatIf
  Reports which direction it would go, without moving the window.

.EXAMPLE
  Get-GreenroomInstance | Switch-GreenroomSession
  Inverts every session's visibility.
#>
function Switch-GreenroomSession {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [string]$Name,

        [switch]$NoElevate
    )

    process {
        # Resolve, escalate, gate, act -- the same order as Show- and Hide-, for the
        # reasons documented on Show-GreenroomSession.
        # Elevation first: an elevated session cannot be found from an unelevated shell.
        if (Invoke-ElevationFirst -Name $Name -Command 'Switch-GreenroomSession' -NoElevate:$NoElevate -Cmdlet $PSCmdlet) { return }
        $target = Resolve-GreenroomTarget -Name $Name -RequireWindow
        if (-not $target) { return }

        # Deliberately NOT $target.Visible, which was read during discovery and may
        # already be stale. This is the last read before the direction is chosen.
        $show = -not (Test-WindowVisible -Handle $target.Window)
        $verb = if ($show) { 'show' } else { 'hide' }

        # The direction goes in the ShouldProcess description so -WhatIf reports which
        # way it would go, rather than an unhelpful "would switch".
        #
        # Gated before escalation: a new elevated process starts with its own
        # $WhatIfPreference and $ConfirmPreference, so anything decided only over there
        # is decided against defaults rather than against what the operator asked for.
        if (-not $PSCmdlet.ShouldProcess($target.Instance, "Switch-GreenroomSession (would $verb)")) { return }

        if (-not (Assert-CanActOnInstance -Name $target.Instance -Command 'Switch-GreenroomSession' -NoElevate:$NoElevate)) {
            return
        }

        if (Set-WindowVisible -Handle $target.Window -Show $show) {
            Write-Verbose "switched '$($target.Instance)' to $verb (claude pid $($target.ClaudePid), window $($target.Window))"
            return
        }

        Write-Error -Category InvalidResult -Message (Get-WindowFailureReason -Name $target.Instance)
    }
}
