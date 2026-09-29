# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Hide a greenroom session's window, leaving the session running.

.DESCRIPTION
  Replaces `greenroom detach`. The session is NOT stopped -- only its window is
  hidden, which is the whole point of the architecture: the session stays up and
  supervised, and its window is revealed again on demand with its scrollback intact.

  As with Show-GreenroomSession, the change is confirmed by observing IsWindowVisible
  rather than trusting ShowWindow's return value, and an elevated instance targeted
  from an unelevated shell re-launches elevated rather than silently doing nothing.

.PARAMETER Name
  The instance to hide. Accepts pipeline input, including Greenroom.Instance objects.

.PARAMETER NoElevate
  Do not escalate when the instance runs elevated. Fails instead.

.EXAMPLE
  Hide-GreenroomSession laptop-admin

.EXAMPLE
  Get-GreenroomInstance | Where-Object Visible | Hide-GreenroomSession
  Hide everything currently on screen.

.EXAMPLE
  Hide-GreenroomSession laptop-admin -WhatIf
#>
function Hide-GreenroomSession {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [string]$Name,

        [switch]$NoElevate
    )

    process {
        # Same order as Show-GreenroomSession, and for the same reasons: resolve, then
        # escalate, then gate, then act. See that function for why each step sits here.
        # Elevation first: an elevated session cannot be found from an unelevated shell.
        if (Invoke-ElevationFirst -Name $Name -Command 'Hide-GreenroomSession' -NoElevate:$NoElevate -Cmdlet $PSCmdlet) { return }
        $target = Resolve-GreenroomTarget -Name $Name -RequireWindow
        if (-not $target) { return }

        if (-not $PSCmdlet.ShouldProcess($target.Instance, 'Hide-GreenroomSession')) { return }

        if (-not (Assert-CanActOnInstance -Name $target.Instance -Command 'Hide-GreenroomSession' -NoElevate:$NoElevate)) {
            return
        }

        if (Set-WindowVisible -Handle $target.Window -Show $false) {
            Write-Verbose "hidden '$($target.Instance)' -- session still running (claude pid $($target.ClaudePid))"
            return
        }

        Write-Error -Category InvalidResult -Message (Get-WindowFailureReason -Name $target.Instance)
    }
}
