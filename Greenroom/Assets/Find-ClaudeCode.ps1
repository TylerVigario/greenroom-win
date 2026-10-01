# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Where the Claude Code CLI is: the first claude.exe on PATH, else ~\.local\bin\claude.exe --
  never Claude Desktop's bundled copy. $null when there is none.

.DESCRIPTION
  Shared. Install-GreenroomInstance resolves the path with this when -ClaudeExe is not given, then
  proves it is the CLI and has --remote-control. The launcher uses it to find Claude Code again
  when the path install recorded has gone -- Claude Code reinstalled another way -- and was not
  chosen explicitly.

  Candidate ORDER matters, and PATH decides it. Whatever `claude` resolves to in the
  operator's own shell is what the supervised session should run. greenroom does not
  install Claude Code, so ranking the ways it can be installed is not its business --
  and the list would have to be maintained against someone else's distribution matrix
  forever: native, npm, WinGet, two Homebrew casks, apt, dnf, apk.

  A hard-coded WinGet Links entry came FIRST until this changed, justified by that path
  being keyed on package ID rather than version, so it survives upgrades. That is true
  and not distinctive: EVERY Windows install path for this CLI is version-stable. The
  WinGet package directory carries no version segment either, the native launcher at
  ~\.local\bin keeps its versions under ~\.local\share\claude\versions, and the npm shim
  is fixed as well. So the preference bought nothing the alternatives lacked.

  What it DID do was outrank a newer install silently. A package-manager install caps
  itself at whatever the manifest offers -- `claude doctor` says so outright,
  "Auto-updates: Managed by package manager" -- so on a host carrying both, greenroom
  chose the one that cannot update itself. MEASURED: WinGet at 2.1.268 preferred over a
  native 2.1.282 that PATH already ranked first, with a green line and no warning.

  ~\.local\bin stays as a LAST resort, for a native install whose directory is not on
  PATH. In the normal case PATH reaches it and this entry is never used.

  Claude DESKTOP ships its own claude.exe plus a private bundled CLI; neither is a
  valid target, and its location depends on install method.

  Deliberately NOT resolved through the symlink: the WinGet Links entry points at a
  versioned target, and following it bakes a path that breaks on the next upgrade.
#>
function Test-ClaudeDesktopPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    foreach ($pattern in '*\Program Files\WindowsApps\*', '*\AnthropicClaude\*', '*\AppData\Roaming\Claude\claude-code\*') {
        if ($Path -like $pattern) { return $true }
    }
    $false
}

function Find-ClaudeCode {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $candidates = @(Get-Command claude.exe -All -ErrorAction SilentlyContinue | ForEach-Object Source)
    $candidates += Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    $found = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) -and -not (Test-ClaudeDesktopPath $_) } |
             Select-Object -First 1
    if ($found) { [System.IO.Path]::GetFullPath($found) } else { $null }
}
