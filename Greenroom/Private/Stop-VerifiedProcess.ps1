# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Stop processes matching a command-line pattern, re-verifying identity immediately
  before each kill.

  Or, with -SessionOf, stop an instance's session: a claude.exe greenroom's launcher
  started for that instance -- see Get-GreenroomSessionName. Not by pattern: the session's
  --remote-control name is on any Remote Control session, greenroom's or not, and a
  pattern on it stopped a session started by hand under the same name.

  A pid recorded moments ago can already belong to something else. On 2026-07-29 a
  launcher exited between enumeration and termination and only this re-check prevented
  killing whatever had inherited its pid.

  Returns the number stopped.
#>
function Stop-VerifiedProcess {
    # No ShouldProcess here, for the same reason as Set-WindowVisible: the public
    # Restart-GreenroomSession gates the whole restart with one ShouldProcess call, so
    # gating each of the three kills separately would ask three times for one decision.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding(DefaultParameterSetName = 'Pattern')]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string[]]$ProcessName,
        [Parameter(Mandatory, ParameterSetName = 'Pattern')][string]$Pattern,
        [Parameter(Mandatory, ParameterSetName = 'Session')][string]$SessionOf,
        [Parameter(Mandatory)][string]$Label
    )

    $stopped = 0
    # ProcessName may name more than one binary. An instance's watchdog and launcher run
    # under whatever shell was resolved -- pwsh.exe where pwsh 7 is present, powershell.exe
    # on stock Windows -- so both have to be matched. The identity test is the real
    # discriminator; the name is only a cheap pre-filter.
    $filter = ($ProcessName | ForEach-Object { "Name='$_'" }) -join ' OR '
    $candidates = @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue -Verbose:$false |
                    Where-Object { $_.ProcessId -ne $PID -and (Test-StopTarget -Proc $_ -Pattern $Pattern -SessionOf $SessionOf) })

    foreach ($p in $candidates) {
        $live = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ProcessId)" -ErrorAction SilentlyContinue -Verbose:$false
        if (-not $live) { continue }
        if (-not (Test-StopTarget -Proc $live -Pattern $Pattern -SessionOf $SessionOf)) {
            Write-Verbose "skipped pid $($p.ProcessId) -- no longer matches $Label"
            continue
        }
        # Counted only if it is gone. SilentlyContinue with an unconditional count reported a
        # refused kill -- access denied, a process at a higher integrity level -- as a stop,
        # so the "what was actually stopped" results said so of something still running.
        # One that exits on its own while this runs is gone all the same, and counts.
        # -ErrorVariable rather than try/catch: it collects the error whether the cmdlet
        # raised it as terminating or not.
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue -ErrorVariable failed
        if ($failed) {
            $still = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ProcessId)" -ErrorAction SilentlyContinue -Verbose:$false
            if ($still -and (Test-StopTarget -Proc $still -Pattern $Pattern -SessionOf $SessionOf)) {
                Write-Warning "could not stop $Label (pid $($p.ProcessId)): $($failed[0])"
                continue
            }
        }
        Write-Verbose "stopped $Label (pid $($p.ProcessId))"
        $stopped++
    }

    return $stopped
}

# Whether a process record is the one Stop-VerifiedProcess was asked to stop. Asked of the
# enumerated record and again of the live one right before the kill.
function Test-StopTarget {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Proc, [string]$Pattern, [string]$SessionOf)

    if ($SessionOf) { return (Get-GreenroomSessionName -ClaudeProc $Proc) -eq $SessionOf }
    [string]$Proc.CommandLine -match $Pattern
}

<#
  Whether this process is running INSIDE the named instance's session.

  Walks up the ancestry looking for the claude.exe that owns this shell. Restarting an
  instance from inside itself kills an ancestor of the current process partway through,
  so the restart never reaches Start-ScheduledTask and the instance is left DOWN rather
  than restarted -- and running it from inside the session is the most natural way to
  invoke it, which is exactly what makes the trap worth a guard.

  Only greenroom's own session counts -- see Get-GreenroomSessionName. Stop, Restart and
  Uninstall kill only that one, so running them from inside a Remote Control session started
  by hand under the same name kills no ancestor, and refusing there refused for nothing.
#>
function Test-SelfIsInstance {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    $ancestor = $PID
    for ($hop = 0; $hop -lt 8 -and $ancestor; $hop++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ancestor" -ErrorAction SilentlyContinue -Verbose:$false
        if (-not $p) { return $false }
        if ($p.Name -eq 'claude.exe' -and (Get-GreenroomSessionName -ClaudeProc $p) -eq $Name) { return $true }
        $ancestor = $p.ParentProcessId
    }
    return $false
}
