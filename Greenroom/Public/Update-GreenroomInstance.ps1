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
  Greenroom.UpdateResult, one per matching instance -- including those left alone, so
  "nothing needed doing" is an answer rather than silence. Action is one of:

    Updated      re-registered on this version and restarted; ClaudePid is the new session
    Registered   re-registered, not restarted (-NoRestart); the running session is still
                 the old code until it next starts
    Current      already runs this version, untouched
    Unversioned  runs from a path carrying no version, untouched (-Force re-registers)
    Failed       re-registration failed and the instance stays on From; the error says why

  From is the version the task ran before, To the version loaded here. Nothing is emitted
  for an instance a -WhatIf or -Confirm declined.

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
    [OutputType('Greenroom.UpdateResult')]
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

    # One result per matching instance, INCLUDING the ones left alone. "Already current"
    # used to be a verbose message, so a run that changed nothing and a run that moved
    # everything looked the same at the prompt -- which is the question this command
    # exists to answer.
    #
    # A scriptblock rather than a nested function: a New- verb without ShouldProcess is an
    # analyzer failure, and building a result object changes nothing.
    $to = $script:GreenroomModuleVersion
    $result = {
        param($Instance, $Action, $From, $ClaudePid)
        [PSCustomObject]@{
            PSTypeName = 'Greenroom.UpdateResult'
            Instance   = $Instance
            Action     = $Action
            From       = $From
            To         = $to
            ClaudePid  = $ClaudePid
        }
    }

    foreach ($n in ($names | Sort-Object)) {
        $asset = Get-InstanceAssetVersion -Name $n

        if (-not $Force) {
            if (-not $asset) {
                # Not an error and not behind: a module installed somewhere unversioned,
                # where new files land in place and there is nothing to move.
                Write-Verbose "$n runs assets from a path carrying no version -- nothing to move (-Force re-registers anyway)"
                & $result $n 'Unversioned' $null $null
                continue
            }
            if ($asset -eq $to) {
                & $result $n 'Current' $asset $null
                continue
            }
        }

        $from = if ($asset) { $asset } else { 'an unversioned path' }

        # ONE ShouldProcess for the whole per-instance update, for the same reason
        # Restart-GreenroomSession gates its three kills with one: re-registering and
        # restarting are a single decision, and prompting twice for it is noise. The inner
        # calls are told not to ask again. A declined prompt emits no result -- -WhatIf
        # has already said what would happen, and a row claiming an Action would not be true.
        if (-not $PSCmdlet.ShouldProcess($n, "re-register $from -> $to$(if ($NoRestart) { '' } else { ' and restart' })")) {
            continue
        }

        try { Install-GreenroomInstance -Name $n -NoStart -Confirm:$false | Out-Null }
        catch {
            # -ErrorAction Continue ON THE Write-Error ITSELF, and it is load-bearing. The
            # module sets $ErrorActionPreference = 'Stop', which functions here inherit, so
            # a bare Write-Error is TERMINATING and would abort the loop at the first
            # failure -- stranding every later instance on the old version, which is the
            # opposite of the intent. Measured: without this, a throw on the first instance
            # stopped the second from being re-registered at all.
            Write-Error -ErrorAction Continue -Message (
                "re-registering '$n' failed, it stays on $from -- $($_.Exception.Message)")
            & $result $n 'Failed' $asset $null
            continue
        }

        if ($NoRestart) {
            # Registered, not Updated: the task now names the new assets, but the session
            # running right now is still the old code until it next starts.
            & $result $n 'Registered' $asset $null
            continue
        }

        # Restart's instance row is folded into this result rather than passed through:
        # two object types in one pipeline render as one table with the wrong columns.
        # Its warnings and errors still reach the operator on their own streams.
        $up = @(Restart-GreenroomSession -Name $n -Confirm:$false)
        & $result $n 'Updated' $asset ($up | Select-Object -First 1 -ExpandProperty ClaudePid -ErrorAction Ignore)
    }

    }
}
