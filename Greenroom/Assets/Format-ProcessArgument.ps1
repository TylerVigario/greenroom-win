# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  One argument, quoted so a Windows program reads it back as exactly one argument.

.DESCRIPTION
  Start-Process -ArgumentList joins an array with spaces and quotes NOTHING, on both
  editions. Measured: a launcher at a path with a space, passed that way through
  Windows Terminal, never ran; quoted, it did. So every argument that could hold a space
  -- the shell's path, the launcher's path under the module directory, which lives under
  Documents and so under a profile name or a OneDrive folder -- goes through this.

  The rules are the ones the C runtime and CommandLineToArgvW read back: an argument with
  no whitespace or quote is left as it is; otherwise it is wrapped in quotes, a quote
  inside it is escaped as \", and backslashes are doubled only where they come before a
  quote -- including the closing one, so "C:\dir\" does not swallow its own terminator.
#>
function Format-ProcessArgument {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Argument)
    process {
        if ($Argument -and $Argument -notmatch '[\s"]') { return $Argument }
        $sb = [System.Text.StringBuilder]::new('"')
        $slashes = 0
        foreach ($c in $Argument.ToCharArray()) {
            if ($c -eq [char]92) { $slashes++; continue }
            if ($c -eq '"') { [void]$sb.Append([char]92, 2 * $slashes + 1).Append('"') }
            else { [void]$sb.Append([char]92, $slashes).Append($c) }
            $slashes = 0
        }
        [void]$sb.Append([char]92, 2 * $slashes).Append('"')
        $sb.ToString()
    }
}
