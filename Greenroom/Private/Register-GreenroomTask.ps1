# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Register (or replace) the logon task that supervises an instance.

  The task runs wscript.exe against the .vbs shipped in this module's Assets folder.
  wscript is a GUI-subsystem binary, so Run(cmd, 0, False) passes SW_HIDE in
  STARTUPINFO at PROCESS CREATION -- the whole reason it is there. Hiding a console
  from inside the process is too late: the OS creates the window visible and pwsh needs
  ~370 ms to boot before any of our code runs, measured as a 367 ms flash at logon.

  The .vbs resolves the watchdog next to itself, and the watchdog resolves the launcher
  next to itself, so all three relocate together and the module can live anywhere.

  Interactive logon is REQUIRED: the session hosts a real Windows Terminal window to
  attach to, and it is also what puts the user's module path in scope for the watchdog.
#>
function Register-GreenroomTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$TriggerDelay,
        [Parameter(Mandatory)][string]$WScriptPath,
        [bool]$Elevated
    )

    $task = "greenroom-$Name"
    $vbs  = Join-Path $script:GreenroomModuleRoot 'Assets\greenroom-watchdog.vbs'
    if (-not (Test-Path $vbs)) { throw "module is incomplete: no watchdog entry point at $vbs" }

    $action = New-ScheduledTaskAction -Execute $WScriptPath `
                  -Argument ('"{0}" "{1}"' -f $vbs, $Name) -WorkingDirectory $env:USERPROFILE

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    # The delay lets credential managers, VPN and sync clients come up first; the
    # session needs network and, with an SSH agent, an unlocked vault.
    $trigger.Delay = $TriggerDelay

    # Highest runs with the user's full admin token and, because the trigger is a task
    # rather than an interactive launch, produces NO UAC prompt -- the only reason a
    # session that starts hidden at logon can be elevated at all. A UAC dialog behind a
    # hidden window is an invisible hang, the exact failure class this project avoids.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                     -LogonType Interactive -RunLevel $(if ($Elevated) { 'Highest' } else { 'Limited' })

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -DontStopOnIdleEnd -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero)   # 0 = no limit; the default kills it after 3 days
    $settings.Hidden = $false

    $desc = "Always-on greenroom session '$Name' in $WorkingDirectory. Started hidden at logon; reveal with Show-GreenroomSession."
    if ($Elevated) { $desc += ' RUNS ELEVATED.' }

    if (Get-ScheduledTask -TaskPath '\' -TaskName $task -ErrorAction Ignore) {
        Write-Verbose "replacing pre-existing task '$task'"
    }

    # -Force replaces in ONE step. Unregistering first and then registering is the same
    # thing only when registration succeeds: if it is refused, the pre-emptive
    # unregister has already destroyed a working task and the instance stops starting
    # at logon.
    #
    # -ErrorAction Stop is load-bearing. Register-ScheduledTask reports `Access is
    # denied` as a NON-TERMINATING error, so without it execution simply carries on, the
    # caller's try/catch never fires, and the caller reports a success for a task it did
    # not change. Measured 2026-11-11: three instances printed `Updated 0.7.2 -> 0.7.3`
    # while their tasks were still on 0.7.2.
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $desc -Force `
        -ErrorAction Stop | Out-Null

    # Verify rather than trust the absence of an error. -ErrorAction Stop covers the
    # failures that raise one; this covers any that do not, and costs a single query.
    # The assets path is the thing that matters -- an upgrade that leaves the task
    # naming the old version is the exact failure this function exists to prevent.
    $registered = Get-ScheduledTask -TaskPath '\' -TaskName $task -ErrorAction Ignore
    if (-not $registered) {
        throw "task '$task' does not exist after registration reported no error"
    }
    $arguments = [string]$registered.Actions[0].Arguments
    if (-not $arguments.Contains($vbs)) {
        # Not the Access-denied case: -ErrorAction Stop has already raised that one. So this
        # names no cause it cannot see, and says where to look instead.
        throw ("task '$task' still names different assets after a registration that reported " +
               "no error: expected '$vbs', found '$arguments'. Read it back with " +
               "Get-ScheduledTask -TaskName $task to see what it holds.")
    }

    Write-Verbose "task registered: $task (delay $TriggerDelay, RunLevel $(if ($Elevated) { 'Highest' } else { 'Limited' }))"
}
