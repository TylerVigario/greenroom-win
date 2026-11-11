# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Every CASCADIA_HOSTING window owned by one WindowsTerminal.exe process.
#>
function Get-CascadiaWindow {
    # The `$l` below is the lParam of the Win32 EnumWindowsProc signature,
    # BOOL CALLBACK(HWND, LPARAM). The delegate requires both parameters, we pass
    # IntPtr.Zero, and the callback correctly ignores it -- but it cannot be dropped
    # without the scriptblock ceasing to match the delegate. Suppressed here rather
    # than excluded repo-wide so a genuinely unused parameter elsewhere still fails.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$HostPid)

    # The delegate executes in its own scope -- it can see neither this function's
    # locals nor its parameters. Both the input and the accumulator have to live in a
    # scope the callback can reach, which inside a module is the module scope.
    $script:grHits = @()
    $script:grPid  = $HostPid
    $cb = [Greenroom.Win1+EnumWindowsProc] {
        param($h, $l)
        $wpid = 0
        [Greenroom.Win1]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
        if ([int]$wpid -eq $script:grPid) {
            $sb = New-Object System.Text.StringBuilder 256
            [Greenroom.Win1]::GetClassName($h, $sb, 256) | Out-Null
            if ($sb.ToString() -match 'CASCADIA_HOSTING') {
                $tb = New-Object System.Text.StringBuilder 512
                [Greenroom.Win1]::GetWindowText($h, $tb, 512) | Out-Null
                $script:grHits += [PSCustomObject]@{ Handle = $h; Title = $tb.ToString() }
            }
        }
        return $true
    }
    [Greenroom.Win1]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    $script:grHits
}

<#
  Resolve an instance's window from the handle the watchdog recorded when it created
  that window. That record is the ONLY source; there is deliberately no fallback.

  Windows Terminal hosts every window in one process and exposes no supported way to
  map a hosted process to its window (microsoft/terminal#5694, Won't Fix), so anything
  other than the record is inference from the window title -- and the title belongs to
  Claude Code, not to greenroom. A session sitting at a trust prompt or a /login screen
  has not applied --name yet and has no matching title at all, which is exactly when
  the operator needs to attach.

  A title fallback would paper over that, and would also hide the failure that matters:
  capture silently not working looks healthy right up until the day it resolves someone
  else's window.

  The record is validated, never trusted. Windows reuses handles after a window closes,
  so a stale record can name a live window belonging to something else.

  Returns the handle, or $null with the reason on the Verbose stream. It does not
  write to the host: a resolver that prints is unusable from Get-GreenroomInstance,
  which needs to report "unresolved" for one instance without spraying advice about it.
#>
function Resolve-SessionWindow {
    [CmdletBinding()]
    [OutputType([IntPtr])]
    param(
        [Parameter(Mandatory)][int]$HostPid,
        [Parameter(Mandatory)][int]$ClaudePid,
        [Parameter(Mandatory)][string]$Name
    )

    $sf = Join-Path (Get-GreenroomStateRoot) "$Name\session.json"

    if (-not (Test-Path $sf)) {
        Write-Verbose "no window record for '$Name' -- restart the instance to create one"
        return $null
    }

    try {
        $rec = Get-Content $sf -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        # An empty file parses to $null rather than throwing, which would otherwise
        # fall through and report a mismatch against blank pids.
        if ($null -eq $rec) { throw 'file is empty' }
    }
    catch {
        Write-Verbose "window record for '$Name' is unreadable or malformed: $($_.Exception.Message)"
        return $null
    }

    # One invariant: this record was written for the session being acted on. Both pids
    # come from the live session the caller already resolved, so a record from any
    # earlier session fails here regardless of what it says.
    if ([int]$rec.claudePid -ne $ClaudePid -or [int]$rec.terminalPid -ne $HostPid) {
        Write-Verbose "record for '$Name' is for claude pid $($rec.claudePid) under terminal $($rec.terminalPid); this session is $ClaudePid under $HostPid"
        return $null
    }

    # Enumerate rather than trust the number: Windows reuses handles after a window
    # closes, so the record must still name a live CASCADIA window under this host.
    $match = @(Get-CascadiaWindow -HostPid $HostPid |
               Where-Object { [int64]$_.Handle -eq [int64]$rec.handle })
    if ($match.Count -ne 1) {
        Write-Verbose "recorded handle $($rec.handle) for '$Name' is not a live console window under pid $HostPid"
        return $null
    }

    return $match[0].Handle
}
