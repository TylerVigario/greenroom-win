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

  Some tasks cannot be registered from an unelevated shell: an instance that runs
  elevated, because registering RunLevel Highest takes an elevated caller, and any task
  first created from an elevated shell, because Administrators then own it. Those are not
  attempted here. They are collected and updated together at the end by ONE elevated copy
  of this command, under one UAC prompt, as Restart-GreenroomSession does for elevated
  sessions. -NoElevate refuses them instead.

.PARAMETER Name
  Only update instances with this name. Wildcards supported. Default: every registered
  instance on the host.

.PARAMETER Force
  Re-register even when the version already matches. Also the way to repair a task
  pointing at a version that has since been deleted from disk.

.PARAMETER NoRestart
  Re-register without restarting. The new assets take effect at the next start; until
  then the running session keeps the old ones, so the drift warning stays accurate.

.PARAMETER NoElevate
  Refuse, rather than re-launch elevated, an instance whose task this shell cannot
  register. Each is reported Refused. Without it, all of them are updated by one elevated
  run at the end, under one UAC prompt, and -Force and -NoRestart go with it.

.OUTPUTS
  Greenroom.UpdateResult, one per matching instance -- including those left alone, so
  "nothing needed doing" is an answer rather than silence. Action is one of:

    Updated      re-registered on this version and restarted; ClaudePid is the new session
    Registered   re-registered, not restarted: under -NoRestart, when the instance is the
                 session this shell runs inside (a warning names the restart to run from
                 outside it), or when the restart failed (an error says why). The task
                 names the new assets; the session is not running them yet
    Current      already runs this version, untouched
    Unversioned  runs from a path carrying no version, untouched (-Force re-registers)
    ClaudeMissing  would be Current or Unversioned, but the claude.exe its config.json records
                 no longer exists, so it cannot start a session; untouched, and a warning
                 says how to fix it (-Force re-registers, which finds Claude Code again)
    Refused      not attempted under -NoElevate, because this shell cannot register the
                 task: the instance runs elevated, or its task is owned by Administrators.
                 Nothing is changed, and the error says what to run instead
    Failed       re-registration failed and the instance stays on From; the error says why

  From is the version the task ran before, To the version loaded here. An instance handed
  to the elevated copy gets its row from that copy, after the rows for the rest. Nothing is
  emitted for an instance a -WhatIf or -Confirm declined, or whose UAC prompt was declined;
  the error for a declined prompt names every instance it left unchanged.

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
        [switch]$NoRestart,
        [switch]$NoElevate
    )

    begin {
        # Instances whose task this shell cannot register, updated together in `end` by one
        # elevated copy so that one UAC prompt covers all of them. That copy re-registers and
        # restarts them one at a time, exactly as the loop below does.
        $deferred = [System.Collections.Generic.List[string]]::new()
    }

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

    # One result per matching instance, INCLUDING the ones left alone. With "already
    # current" on the verbose stream instead, a run that changed nothing and a run that
    # moved everything look the same at the prompt -- which is the question this command
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
            # Before calling an instance left alone fine: is the claude.exe it runs still there?
            # Reinstalling Claude Code another way removes it, and such an instance was reported
            # Current while it could not start a session. An instance that is behind is
            # re-registered below anyway, which looks Claude Code up again.
            if (-not $asset -or $asset -eq $to) {
                $gone = Get-MissingClaudeExe -Name $n
                if ($gone) {
                    Write-Warning $(if ($gone.Explicit) {
                        "'$n' cannot start a session: claude.exe '$($gone.Path)', chosen with -ClaudeExe, no longer exists. " +
                        "Re-run Install-GreenroomInstance -Name $n -ClaudeExe <path to claude.exe>, or -ClaudeExe '' to find it automatically."
                    } else {
                        "'$n': claude.exe '$($gone.Path)', found at install, no longer exists. " +
                        "Update-GreenroomInstance -Name $n -Force re-registers it, which finds Claude Code again."
                    })
                    & $result $n 'ClaudeMissing' $asset $null
                    continue
                }
            }
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

        # Never attempt what this shell cannot do: attempted anyway, the registration reported
        # a result the task did not reflect. Only certain causes get here -- anything
        # ambiguous falls through to the attempt, which fails loudly. -Elevated is the
        # configured value, which is what the re-registration below inherits.
        #
        # Install- makes the same check before it writes anything, so this is not the only
        # guard. It is here as well because only here can the instance be handed to an
        # elevated copy, or answered with a Refused row rather than a Failed one. Those say
        # different things on purpose: Refused means nothing was tried and the instance is
        # untouched; Failed means an attempt broke partway.
        $blocked = Get-TaskRewriteBlocker -Name $n -Elevated (Test-InstanceElevated -Name $n)
        if ($blocked -and $NoElevate) {
            # The row BEFORE the error, here and below: a caller who asked for Stop gets the
            # error as a throw, and the row emitted after it would never be.
            & $result $n 'Refused' $asset $null
            Write-CommandError -Cmdlet $PSCmdlet -ErrorId 'UpdateRefused' -Category PermissionDenied -TargetObject $n -Message (
                "refusing to update '$n', it stays on $from -- $blocked " +
                '-NoElevate was passed, so it is not being escalated. Nothing has been changed.')
            continue
        }

        # ONE ShouldProcess for the whole per-instance update, for the same reason
        # Restart-GreenroomSession gates its three kills with one: re-registering and
        # restarting are a single decision, and prompting twice for it is noise. The inner
        # calls are told not to ask again. A declined prompt emits no result -- -WhatIf
        # has already said what would happen, and a row claiming an Action would not be true.
        #
        # Asked BEFORE an instance is deferred, as Restart- does: the elevated copy is a new
        # process with its own preferences, so -WhatIf has to stop here, and -Confirm has to
        # ask in the shell the operator is typing in.
        $how = "re-register $from -> $to$(if ($NoRestart) { '' } else { ' and restart' })$(if ($blocked) { ', elevated' })"
        if (-not $PSCmdlet.ShouldProcess($n, $how)) { continue }

        # Handed on, not attempted. The elevated copy decides afresh -- Current, Updated,
        # Registered for the session a shell runs inside -- and its rows are replayed here.
        #
        # That includes the session this shell runs inside, which this shell does not filter
        # out: the elevated copy's own Test-SelfIsInstance finds it, because a process that
        # UAC elevates is parented to the process that asked. Measured 2026-11-12 on the
        # reference host: from a medium-integrity shell, Start-Process -Verb RunAs on an
        # auto-elevating Windows binary -- the same AppInfo route, without the prompt a
        # test cannot click -- gave a High-integrity process whose parent was that shell.
        if ($blocked) { $deferred.Add($n); continue }

        try { Install-GreenroomInstance -Name $n -NoStart -Confirm:$false | Out-Null }
        catch {
            # Write-CommandError, and it is load-bearing. The module sets
            # $ErrorActionPreference = 'Stop', which functions here inherit, so a bare
            # Write-Error is TERMINATING and would abort the loop at the first failure --
            # stranding every later instance on the old version. Measured: a throw on the
            # first instance stopped the second from being re-registered at all. Unlike
            # `Write-Error -ErrorAction Continue`, it still stops when the CALLER asks to.
            & $result $n 'Failed' $asset $null
            Write-CommandError -Cmdlet $PSCmdlet -ErrorId 'UpdateFailed' -Category InvalidOperation -TargetObject $n -Message (
                "re-registering '$n' failed, it stays on $from -- $($_.Exception.Message)")
            continue
        }

        if ($NoRestart) {
            # Registered, not Updated: the task now names the new assets, but the session
            # running right now is still the old code until it next starts.
            & $result $n 'Registered' $asset $null
            continue
        }

        # The session this shell runs inside cannot be restarted from here -- Restart-
        # refuses, because the kill would take this process with it before the task is
        # started again. For an admin lane updating the host it runs on, that is the
        # expected case rather than a failure, so it is said as the next step to take. The
        # task already names the new assets.
        if (Test-SelfIsInstance -Name $n) {
            Write-Warning ("'$n' is re-registered on $to but is still running $from, because it is " +
                           'the session this shell runs inside and cannot be restarted from here. ' +
                           "From a shell outside it: Restart-GreenroomSession $n")
            & $result $n 'Registered' $asset $null
            continue
        }

        # Caught rather than left to propagate. Called from in here, where the preference
        # is the module's Stop, Restart-'s errors are TERMINATING -- by design, so that this
        # loop sees them. Uncaught, one failed restart would end this loop: every later
        # instance left on the old version, and no row at all for this one, whose task HAS
        # moved. Registered is the true state: the task names the new assets, and whether a
        # session is running on them is what the error says.
        #
        # Restart's instance row is folded into this result rather than passed through:
        # two object types in one pipeline render as one table with the wrong columns.
        # Its warnings and errors still reach the operator on their own streams.
        try { $up = @(Restart-GreenroomSession -Name $n -Confirm:$false) }
        catch {
            & $result $n 'Registered' $asset $null
            Write-CommandError -Cmdlet $PSCmdlet -ErrorId 'RestartFailed' -Category InvalidOperation -TargetObject $n -Message (
                "'$n' is re-registered on $to, but restarting it failed -- $($_.Exception.Message)")
            continue
        }
        & $result $n 'Updated' $asset ($up | Select-Object -First 1 -ExpandProperty ClaudePid -ErrorAction Ignore)
    }

    }

    end {
        # -Force and -NoRestart go with them: dropped, the elevated copy would skip an instance
        # -Force asked for, or restart one -NoRestart said to leave running.
        if ($deferred.Count) {
            $carry = @()
            if ($Force)     { $carry += 'Force' }
            if ($NoRestart) { $carry += 'NoRestart' }
            Invoke-DeferredElevation -Command 'Update-GreenroomInstance' -Name $deferred -Cmdlet $PSCmdlet -Forward $carry
        }
    }
}
