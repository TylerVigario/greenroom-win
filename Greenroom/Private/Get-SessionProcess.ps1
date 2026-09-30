# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

# Which claude.exe are greenroom's own. Lives in Assets/ because the watchdog needs the same
# answer and cannot reach Private/; the module does not load Assets/ on its own.
. (Join-Path $script:GreenroomModuleRoot 'Assets\Get-GreenroomSessionName.ps1')

<#
  Every running greenroom session on this host, as process records -- greenroom's OWN.

  A claude.exe is one only if greenroom started it: see Get-GreenroomSessionName. Any
  claude.exe can carry "--remote-control <name>", so the name alone listed sessions greenroom
  never started -- a Remote Control session run by hand, as though it were an instance, and
  one run with the unrelated --remote-control-session-name-prefix flag as "(unnamed)".

  Anchors on claude.exe itself rather than on a launcher. Two earlier approaches
  failed: matching pwsh by command line also matched shells that merely MENTIONED
  "--remote-control" (diagnostics included), and searching a launcher's descendants
  missed the window entirely, because Windows Terminal is parented to the
  console-handoff broker rather than to us.

  Renamed from Get-AllSessions: PSUseSingularNouns is a real rule for a module's
  functions, and it was one of the exclusions the script shape needed.
#>
function Get-SessionProcess {
    [CmdletBinding()]
    param()

    # Excluding the current process matters: a shell running greenroom has
    # "--remote-control" in its own command line.
    $all = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue -Verbose:$false |
             Where-Object { $_.ProcessId -ne $PID })

    foreach ($p in ($all | Where-Object { $_.CommandLine })) {
        $name = Get-GreenroomSessionName -ClaudeProc $p
        if ($name) {
            [PSCustomObject]@{ Instance = $name; Claude = $p; Pid = $p.ProcessId; Opaque = $false }
        }
        elseif ($p.CommandLine -match '--remote-control') {
            Write-Verbose "claude.exe pid $($p.ProcessId) uses Remote Control but greenroom did not start it -- not listed"
        }
    }

    # MEASURED on the reference host: Win32_Process.CommandLine comes back NULL for any
    # process this shell lacks query rights on -- confirmed against ctfmon.exe,
    # TabTip.exe and Bitwarden.exe, all of which enumerate but expose no command line.
    # A higher-integrity claude.exe falls in exactly that class, so an elevated session
    # is VISIBLE as a process but UNIDENTIFIABLE, and the filter above drops it
    # silently, reporting "nothing running" for something that is.
    #
    # This is a property of WHERE THIS CODE IS RUNNING, not of the session. From an
    # elevated shell nothing is opaque and every instance resolves by name.
    #
    # Gated on an elevated instance actually being configured, because a host with
    # Claude Desktop runs a dozen unrelated claude.exe (13 on the reference host), and
    # calling one of those a probable greenroom session would be the confident wrong
    # answer this branch exists to avoid.
    if (Test-AnyInstanceElevated) {
        foreach ($p in ($all | Where-Object { -not $_.CommandLine })) {
            [PSCustomObject]@{ Instance = '(unreadable)'; Claude = $p; Pid = $p.ProcessId; Opaque = $true }
        }
    }
}

# The WindowsTerminal.exe hosting a session, by walking up from claude.exe.
# Chain: WindowsTerminal.exe -> OpenConsole.exe -> pwsh.exe -> claude.exe
function Get-TerminalHost {
    param([Parameter(Mandatory)]$ClaudeProc)

    $cur = $ClaudeProc
    for ($i = 0; $i -lt 6 -and $cur; $i++) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($cur.ParentProcessId)" -ErrorAction SilentlyContinue -Verbose:$false
        if (-not $parent) { return $null }
        if ($parent.Name -eq 'WindowsTerminal.exe') { return $parent }
        $cur = $parent
    }
    return $null
}
