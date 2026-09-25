# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Move registered instances onto the module version loaded in this session.

.DESCRIPTION
  Installing a new module version does not move an instance to it, and this is the command
  that does. The scheduled task records the VERSIONED asset path -- Register-GreenroomTask
  builds it from the module root -- and module versions install side by side, so
  Import-Module resolves the newest while the task keeps launching the old one.
  Restart-GreenroomSession does not help: it re-runs the task, and the task is what still
  names the old path. Nothing errors, which is what makes it worth a command.

  So an upgrade is two steps, and only the first is anybody else's job:

      Update-PSResource Greenroom     # however the module got here
      Update-GreenroomInstance

  Each instance is re-registered with Install-GreenroomInstance -NoStart, which rewrites
  the task and config.json TOGETHER -- they must move as one, or a new watchdog reads an
  old config -- and which inherits every parameter it is not given, so the original
  arguments are not needed here. Then it is restarted, because until it is, the running
  supervisor is still the old one.

  Only instances whose assets differ from this module are touched. An instance whose task
  path carries no version is left alone: that is a module installed somewhere unversioned,
  where new files land in place and there is nothing to move.

.PARAMETER Name
  Only update instances with this name. Wildcards supported. Default: every registered
  instance on the host.

.PARAMETER Force
  Re-register even when the version already matches. Also the way to repair a task
  pointing at a version that has since been deleted from disk.

.PARAMETER NoRestart
  Re-register without restarting. The new assets take effect at the next start; until
  then the running session keeps the old ones, so the drift warning stays accurate.

.OUTPUTS
  Greenroom.Instance for each restarted instance. Nothing under -NoRestart.

.EXAMPLE
  Update-GreenroomInstance

.EXAMPLE
  Update-GreenroomInstance -WhatIf
  Which instances are behind, and what they would move from and to, without touching them.

.EXAMPLE
  Update-GreenroomInstance -Name render-* -NoRestart
#>
function Update-GreenroomInstance {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Greenroom.Instance')]
    param(
        # Pipeline-bound like the other state-changing commands, with the Instance alias,
        # so `Get-GreenroomInstance | Where-Object AssetVersion | Update-GreenroomInstance`
        # binds. Module.Tests asserts this across the whole public surface.
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [SupportsWildcards()]
        [string]$Name,

        [switch]$Force,
        [switch]$NoRestart
    )

    process {

    # Registration IS the scheduled task, so that is what is enumerated -- a state
    # directory without a task is a half-uninstalled remnant, not something to restart.
    # Shared with the session commands; Update keeps its own no-name rule (every instance).
    $names = @(Get-RegisteredInstanceName)
    if ($Name) { $names = @($names | Where-Object { $_ -like $Name }) }

    if ($names.Count -eq 0) {
        if ($Name) { Write-Warning "no registered instance matches '$Name'" }
        else       { Write-Warning 'no greenroom instances are registered on this host' }
        return
    }

    $targets = @()
    foreach ($n in ($names | Sort-Object)) {
        $asset = Get-InstanceAssetVersion -Name $n

        if ($Force) {
            $targets += [PSCustomObject]@{ Instance = $n; From = $asset }
        }
        elseif (-not $asset) {
            Write-Verbose "$n runs assets from a path carrying no version -- nothing to move (-Force re-registers anyway)"
        }
        elseif ($asset -ne $script:GreenroomModuleVersion) {
            $targets += [PSCustomObject]@{ Instance = $n; From = $asset }
        }
        else {
            Write-Verbose "$n already runs $asset"
        }
    }

    if ($targets.Count -eq 0) {
        Write-Verbose "every matching instance already runs $script:GreenroomModuleVersion"
        return
    }

    foreach ($t in $targets) {
        $from = if ($t.From) { $t.From } else { 'an unversioned path' }

        # ONE ShouldProcess for the whole per-instance update, for the same reason
        # Restart-GreenroomSession gates its three kills with one: re-registering and
        # restarting are a single decision, and prompting twice for it is noise. The inner
        # calls are told not to ask again.
        if (-not $PSCmdlet.ShouldProcess($t.Instance, "re-register $from -> $script:GreenroomModuleVersion$(if ($NoRestart) { '' } else { ' and restart' })")) {
            continue
        }

        try { Install-GreenroomInstance -Name $t.Instance -NoStart -Confirm:$false | Out-Null }
        catch {
            # -ErrorAction Continue ON THE Write-Error ITSELF, and it is load-bearing. The
            # module sets $ErrorActionPreference = 'Stop', which functions here inherit, so
            # a bare Write-Error is TERMINATING and would abort the loop at the first
            # failure -- stranding every later instance on the old version, which is the
            # opposite of the intent. Measured: without this, a throw on the first instance
            # stopped the second from being re-registered at all.
            Write-Error -ErrorAction Continue -Message (
                "re-registering '$($t.Instance)' failed, it stays on $from -- $($_.Exception.Message)")
            continue
        }

        if ($NoRestart) {
            Write-Verbose "$($t.Instance) re-registered; the new assets start with the next session"
            continue
        }

        Restart-GreenroomSession -Name $t.Instance -Confirm:$false
    }

    }
}
