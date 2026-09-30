# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  The greenroom instance a claude.exe is the session of, or $null if greenroom did not start it.

.DESCRIPTION
  Greenroom starts every session the same way: its launcher, greenroom-launch.ps1, runs
  `claude --remote-control <instance> ...` and waits on it, so the launcher is the session's
  PARENT for as long as the session runs. MEASURED on the reference host: the live session's
  claude.exe is a direct child of the pwsh running greenroom-launch.ps1 -Instance <instance>.
  So a session is greenroom's only when:

    - its own command line carries --remote-control <name> -- the flag exactly, not the
      unrelated --remote-control-session-name-prefix;
    - its parent's command line runs greenroom-launch.ps1 with -Instance <name>;
    - and the two names are the same.

  A claude.exe started any other way -- a Remote Control session run by hand under the same
  name included -- is not greenroom's, and nothing in greenroom acts on it.

  Shared: the module dot-sources this for session discovery, and the watchdog for
  adoption, so both answer the question the same way.
#>
function Get-GreenroomSessionName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$ClaudeProc)

    if ([string]$ClaudeProc.CommandLine -notmatch '--remote-control\s+"?([^"\s-][^"\s]*)') { return $null }
    $name = $Matches[1]
    if (-not $ClaudeProc.ParentProcessId) { return $null }
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($ClaudeProc.ParentProcessId)" -ErrorAction SilentlyContinue -Verbose:$false
    $cmd = [string]$parent.CommandLine
    if ($cmd -notmatch 'greenroom-launch\.ps1"?(\s|$)') { return $null }
    if ($cmd -notmatch ('-Instance\s+"?' + [regex]::Escape($name) + '("|\s|$)')) { return $null }
    $name
}
