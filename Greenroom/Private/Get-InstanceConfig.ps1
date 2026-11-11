# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

# An instance's config.json, or $null when it has none.
#
# Readable at any integrity level, which is what makes it the trustworthy source for
# the elevated flag: process command lines read as NULL across integrity boundaries,
# this file does not.
function Get-InstanceConfig {
    param([Parameter(Mandatory)][string]$Name)

    $cfg = Join-Path (Get-GreenroomStateRoot) "$Name\config.json"
    if (-not (Test-Path $cfg)) { return $null }
    try { return Get-Content $cfg -Raw | ConvertFrom-Json }
    catch { return $null }
}

# Whether an instance is configured to run with a full admin token.
function Test-InstanceElevated {
    param([Parameter(Mandatory)][string]$Name)

    $c = Get-InstanceConfig -Name $Name
    # An absent key means an instance installed before -Elevated existed, which by
    # definition was not elevated.
    return [bool]($c -and $c.elevated)
}

<#
  Whether an instance's RUNNING session has a full admin token, preferring what it
  actually has over what was configured for it.

  The two disagree after an elevation change nothing has restarted into, and the
  configured value is the misleading one -- it describes the NEXT start. Reported as the
  measurement when the measurement is possible, and as the configuration when it is not,
  which is also the only answer available for an instance that is not running.
#>
function Resolve-InstanceElevated {
    param([Parameter(Mandatory)][string]$Name, [int]$ClaudePid)

    if ($ClaudePid) {
        $measured = Test-SessionElevated -ProcessId $ClaudePid
        if ($null -ne $measured) { return $measured }
    }
    return (Test-InstanceElevated -Name $Name)
}

# Whether THIS session is elevated. Determines what discovery can see, not what the
# instances are.
function Test-SelfElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Whether any instance on this host is configured elevated. Gates the guesswork about
# unreadable processes: without an elevated instance installed, an unreadable
# claude.exe is not evidence of greenroom at all.
function Test-AnyInstanceElevated {
    $root = Get-GreenroomStateRoot
    if (-not (Test-Path $root)) { return $false }
    foreach ($d in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
        if (Test-InstanceElevated -Name $d.Name) { return $true }
    }
    return $false
}
