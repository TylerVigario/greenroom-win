# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Whether a window title is exactly the title of an instance's session.

.DESCRIPTION
  Claude Code titles a session's window "<glyph> <name>": one spinner glyph, a space, and
  the --name the launcher passes, which is the instance name. Measured on the reference
  host: "<U+25D0> laptop-admin". The glyph changes as the session works; the shape does not.

  The watchdog CLOSES every window this matches, so it matches the whole title and nothing
  less. An instance named "admin" must not match "<glyph> laptop-admin", and an ordinary
  shell tab -- titled with a path or a command, which may well end in the instance name
  because the default working directory is ~\<name> -- must not match at all.

  The glyph is one or two UTF-16 units outside ASCII (a symbol outside the Basic
  Multilingual Plane takes two). Written with escapes only: Windows PowerShell 5.1 reads a
  BOM-less file as ANSI, so a literal glyph here would not survive.
#>
function Test-SessionTitle {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][string]$Instance
    )
    $Title -match ('^[^\x00-\x7F]{1,2} ' + [regex]::Escape($Instance) + '$')
}
