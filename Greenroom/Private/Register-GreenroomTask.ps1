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
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $desc -Force | Out-Null

    Write-Verbose "task registered: $task (delay $TriggerDelay, RunLevel $(if ($Elevated) { 'Highest' } else { 'Limited' }))"
}
