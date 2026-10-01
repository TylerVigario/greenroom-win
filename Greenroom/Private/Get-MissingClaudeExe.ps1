# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  The claude.exe an instance's config.json records, when it no longer exists: Path, and
  Explicit (chosen with -ClaudeExe rather than found). $null when it exists, or when there is
  no readable config to say -- that is someone else's error to report.

  Reinstalling Claude Code another way removes the recorded path, and an instance on the
  current module version was reported Current while it could not start a session.
#>
function Get-MissingClaudeExe {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)][string]$Name)

    $cfgPath = Join-Path (Get-GreenroomStateRoot) "$Name\config.json"
    try { $cfg = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
    if (-not $cfg -or -not $cfg.claudeExe) { return $null }
    if (Test-Path -LiteralPath $cfg.claudeExe) { return $null }
    [PSCustomObject]@{ Path = [string]$cfg.claudeExe; Explicit = [bool]$cfg.claudeExeExplicit }
}
