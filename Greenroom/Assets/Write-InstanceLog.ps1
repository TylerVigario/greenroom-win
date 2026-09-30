# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Append one timestamped line to an instance log, and keep the log bounded.

.DESCRIPTION
  The watchdog and the launcher each keep a log in the instance's state directory, and
  both run unattended for months. Only the watchdog's was bounded; the launcher's grew
  without limit -- slowly in normal use (38 KB in two months on the reference host), fast
  in a crash loop, which writes an entry every restart. Both now share this rule: past
  -MaxBytes, the log keeps its last -KeepLines lines.
#>
function Write-InstanceLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [long]$MaxBytes = 512KB,
        [int]$KeepLines = 500
    )
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')  $Message" | Add-Content -Path $Path -Encoding UTF8
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt $MaxBytes) {
        $tail = Get-Content -LiteralPath $Path -Tail $KeepLines
        Set-Content -Path $Path -Value $tail -Encoding UTF8
    }
}
