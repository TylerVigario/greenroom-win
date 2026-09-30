# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Supervisor for one greenroom instance.

  Requirement: the session is not allowed to be down. If the Windows Terminal
  window is closed accidentally instead of detached, the session must come back
  within a second or two, without any window ever appearing.

  Design:
    - This watchdog is itself launched hidden by greenroom-watchdog.vbs (wscript
      is GUI-subsystem, and Run(cmd,0,False) passes SW_HIDE at process creation).
    - It launches the session as a Windows Terminal window that is ALSO born
      hidden, via Start-Process -WindowStyle Hidden. WT honours it, and the
      hidden window can still be revealed later by greenroom.ps1.
    - It watches the claude.exe PID directly. Get-Process -Id is cheap enough to
      poll once a second; the expensive CIM query only runs on a restart.

  Windows Terminal is required rather than conhost: conhost does no font
  fallback, and no console-registerable font contains the glyphs the TUI draws.

  OWNERSHIP: the watchdog adopts only its own instance's session -- one greenroom's
  launcher started for this instance. See Get-GreenroomSessionName.ps1 next door.
  Several instances can then be supervised on one host without stealing each other's
  sessions, and a Remote Control session started by hand under the same name is left
  alone: matching on the name alone adopted it, stopped starting the real session, and
  handed the instance to a process greenroom does not control.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Instance)

$ErrorActionPreference = 'Continue'

$stateDir = Join-Path $env:USERPROFILE ".claude\greenroom\$Instance"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$log = Join-Path $stateDir 'watchdog.log'

# Bounded, like the launcher's -- see Write-InstanceLog.ps1 next door.
. (Join-Path $PSScriptRoot 'Write-InstanceLog.ps1')
function Log($m) { Write-InstanceLog -Path $log -Message $m }

# SINGLE-INSTANCE GUARD.
#
# Exactly one watchdog may supervise an instance. Two is not merely redundant:
# when the session dies they both see it inside the same 1s poll and both call
# Start-RcSession, producing two Windows Terminal windows carrying the SAME
# --name. Resolution then finds two matches, refuses, and attach breaks
# permanently with nothing on screen to explain it.
#
# This is easy to reach by accident. Stop-ScheduledTask is a no-op against this
# architecture -- the task runs wscript.exe, which spawns the watchdog detached
# and returns, so the task sits at Ready with nothing left to stop. A plain
# Start-ScheduledTask therefore ADDS a supervisor. Measured on the reference
# host: 1 watchdog, Stop-ScheduledTask, still 1, Start-ScheduledTask, 2.
#
# A named mutex rather than a process scan, deliberately. Scanning races: two
# watchdogs starting together can both look, both see nothing, and both proceed.
# The mutex is a kernel object, so the check and the claim are one atomic step.
# It is also self-cleaning -- if the holder is killed, its handle closes and the
# claim is released, so a crashed watchdog never locks the instance out.
#
# Local\ not Global\: instances run in the interactive user's session, and
# Global\ would let one user's watchdog block another's on a shared machine.
$mutexName = "Local\greenroom-watchdog-$Instance"
$script:mutex = New-Object System.Threading.Mutex($false, $mutexName)
$acquired = $false
try {
    $acquired = $script:mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # The previous holder died without releasing. That means we DID acquire it,
    # and the instance is genuinely unsupervised right now.
    $acquired = $true
    Log 'previous watchdog terminated without releasing its claim -- taking over'
}
if (-not $acquired) {
    Log "another watchdog already supervises '$Instance' -- this one (pid $PID) is exiting"
    exit 0
}

$cfgPath = Join-Path $stateDir 'config.json'
if (-not (Test-Path $cfgPath)) {
    Log "FATAL: no config at $cfgPath -- run Install-GreenroomInstance -Name $Instance"
    exit 1
}
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

$wt      = $cfg.wt
$shell   = $cfg.shell
$inner   = Join-Path $PSScriptRoot 'greenroom-launch.ps1'
$POLL_MS = 1000

Log "=== watchdog start, pid $PID, instance '$Instance' ==="
Log "     cwd=$($cfg.workingDirectory)  claude=$($cfg.claudeExe)"

# Whether a claude.exe is greenroom's session, and of which instance -- see
# Get-GreenroomSessionName.ps1 next door. The module asks the same question the same way.
. (Join-Path $PSScriptRoot 'Get-GreenroomSessionName.ps1')

function Get-RcClaudePid {
    $p = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
         Where-Object { $_.ProcessId -ne $PID -and (Get-GreenroomSessionName -ClaudeProc $_) -eq $Instance } |
         Select-Object -First 1
    if ($p) { $p.ProcessId } else { $null }
}

# Windows Terminal keeps a window alive when the process hosting its tab dies
# abruptly rather than exiting. The window stays enumerable, frozen at whatever
# title it had at death. Killing claude.exe does NOT do this -- the launcher then
# exits normally and the window closes with it -- but killing the launcher shell
# does, and so does any abnormal termination of it.
#
# Left alone, every abnormal death leaks one such window -- hidden, unless it had
# been shown -- so the watchdog closes it before starting the replacement.
#
# Only the window greenroom created for this instance is ever closed: the handle
# Save-SessionWindow recorded in session.json. Closing by title closed any window
# carrying "<glyph> <instance>", and that is not only greenroom's. A Remote Control
# session started by hand under the instance's name is not the watchdog's own, so it
# does not count as a live session here -- and its window, if titled the same, was
# closed as a corpse, taking a session greenroom never started with it.
#
# The record is validated, never trusted, because Windows reuses handles: the handle
# must still be a CASCADIA_HOSTING window of the recorded WindowsTerminal process, and
# still carry exactly this instance's session title. With no usable record nothing is
# known to be greenroom's, and nothing is closed. Attach resolves only from the record
# too (Resolve-SessionWindow), so a corpse left behind costs a window, not attach.
if (-not ('GreenroomWd.Win1' -as [type])) {
    Add-Type -Namespace GreenroomWd -Name Win1 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
'@
}

# Every CASCADIA_HOSTING window currently on the desktop, as a set of handle values.
function Get-CascadiaHandleSet {
    # $l is the lParam of Win32's EnumWindowsProc, BOOL CALLBACK(HWND, LPARAM). The
    # delegate requires it, we pass IntPtr.Zero, and dropping it stops the scriptblock
    # matching the delegate.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param()

    $script:capHits = @()
    $cb = [GreenroomWd.Win1+EnumWindowsProc] {
        param($h, $l)
        $sb = New-Object System.Text.StringBuilder 256
        [GreenroomWd.Win1]::GetClassName($h, $sb, 256) | Out-Null
        if ($sb.ToString() -match 'CASCADIA_HOSTING') { $script:capHits += [int64]$h }
        return $true
    }
    [GreenroomWd.Win1]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return , @($script:capHits)
}

# Record which window belongs to this session, so attach never has to guess.
#
# Windows Terminal hosts every window in ONE process, and Microsoft declined to
# expose any mapping from a hosted process to its window (microsoft/terminal#5694,
# closed Won't-Fix). GetWindowThreadProcessId therefore returns the same pid for
# every window WT owns, and the only thing that differs between them is the title
# -- which the hosted application owns and rewrites. A session sitting at a trust
# dialog or a login prompt never applies --name at all, so title matching fails
# exactly when attaching matters most.
#
# The handle is knowable at creation instead. Two independent filters are applied
# so a concurrent start cannot be misattributed:
#   1. the handle must be NEW since immediately before wt.exe was launched
#   2. it must belong to the WindowsTerminal process in this session's ancestry
# Exactly one handle satisfying both is recorded; anything else records nothing and
# leaves the title fallback in place rather than storing a guess.
function Save-SessionWindow {
    param([int]$ClaudePid, [int64[]]$Before)

    $wtPid = $null
    $cur = Get-CimInstance Win32_Process -Filter "ProcessId=$ClaudePid" -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 6 -and $cur; $i++) {
        $par = Get-CimInstance Win32_Process -Filter "ProcessId=$($cur.ParentProcessId)" -ErrorAction SilentlyContinue
        if (-not $par) { break }
        if ($par.Name -eq 'WindowsTerminal.exe') { $wtPid = [int]$par.ProcessId; break }
        $cur = $par
    }
    if (-not $wtPid) { Log 'window capture: no WindowsTerminal in ancestry -- leaving title fallback'; return }

    $now = Get-CascadiaHandleSet
    $new = @($now | Where-Object { $Before -notcontains $_ })

    $owned = @($new | Where-Object {
        $wp = 0
        [GreenroomWd.Win1]::GetWindowThreadProcessId([IntPtr]$_, [ref]$wp) | Out-Null
        [int]$wp -eq $wtPid
    })

    if ($owned.Count -ne 1) {
        Log "window capture: $($owned.Count) candidate windows (new=$($new.Count), wt pid $wtPid) -- leaving title fallback"
        return
    }

    $state = @{
        handle       = $owned[0]
        claudePid    = $ClaudePid
        terminalPid  = $wtPid
        capturedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
    $path = Join-Path $stateDir 'session.json'
    $state | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
    Log "window capture: handle $($owned[0]) on WindowsTerminal pid $wtPid"
}

. (Join-Path $PSScriptRoot 'Format-ProcessArgument.ps1')

# Exactly "<glyph> <instance>" -- see Test-SessionTitle.ps1 next door. Anything looser
# closes windows that are not this instance's: "admin" once matched "<glyph> laptop-admin".
. (Join-Path $PSScriptRoot 'Test-SessionTitle.ps1')

# Owner pid, class and title of one window. OwnerPid is 0 when the handle names no window.
function Get-WindowInfo {
    param([IntPtr]$Handle)
    $wp = 0
    [GreenroomWd.Win1]::GetWindowThreadProcessId($Handle, [ref]$wp) | Out-Null
    $cls = New-Object System.Text.StringBuilder 256
    [GreenroomWd.Win1]::GetClassName($Handle, $cls, 256) | Out-Null
    $tb = New-Object System.Text.StringBuilder 512
    [GreenroomWd.Win1]::GetWindowText($Handle, $tb, 512) | Out-Null
    [PSCustomObject]@{ OwnerPid = [int]$wp; Class = $cls.ToString(); Title = $tb.ToString() }
}

# WM_CLOSE. PostMessage, not SendMessage: PostMessage returns immediately, so an
# unresponsive window cannot block the supervisor. Closing is best-effort by design.
function Send-WindowClose {
    param([IntPtr]$Handle)
    [GreenroomWd.Win1]::PostMessage($Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
}

function Close-StaleWindows {
    [CmdletBinding()]
    param()

    $sf = Join-Path $stateDir 'session.json'
    if (-not (Test-Path $sf)) { return }
    try {
        $rec = Get-Content $sf -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { Log "window record unreadable, no stale window closed: $($_.Exception.Message)"; return }
    if ($null -eq $rec -or -not $rec.handle) { return }

    $w = Get-WindowInfo -Handle ([IntPtr][int64]$rec.handle)
    # Gone: the usual case. A session that exits normally takes its window with it.
    if ($w.OwnerPid -eq 0) { return }
    if ($w.OwnerPid -ne [int]$rec.terminalPid -or $w.Class -notmatch 'CASCADIA_HOSTING' -or
        -not (Test-SessionTitle -Title $w.Title -Instance $Instance)) {
        Log "recorded window $($rec.handle) is no longer this instance's session window -- left open"
        return
    }
    Send-WindowClose -Handle ([IntPtr][int64]$rec.handle)
    Log "closed stale window $($rec.handle) '$($w.Title)' -- its host died without releasing it"
    Start-Sleep -Milliseconds 500
}

function Start-RcSession {
    # No ShouldProcess: this is the watchdog's internal launch step, private to a script
    # that runs unattended from a scheduled task. There is no interactive caller for
    # -WhatIf or -Confirm to serve.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param()

    Close-StaleWindows
    # Snapshot the desktop's console windows immediately before launching, so the
    # one this call creates can be identified by difference rather than by title.
    # Deliberately taken AFTER Close-StaleWindows, or a corpse still being torn
    # down could appear as "new" in the comparison.
    $script:windowsBefore = Get-CascadiaHandleSet
    # -w new forces its own window instead of a tab in an existing terminal.
    # Quoted, because Start-Process quotes nothing: a shell or launcher path with a space
    # in it -- a profile name, a OneDrive Documents folder -- otherwise arrives in pieces
    # and the session never starts. See Format-ProcessArgument.ps1 next door.
    $args_ = @('-w', 'new', $shell, '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', $inner, '-Instance', $Instance) | Format-ProcessArgument
    Start-Process -FilePath $wt -ArgumentList $args_ -WindowStyle Hidden
    Log 'launched WT session (hidden)'
}

$sessionPid   = $null
$restarts     = @()   # timestamps, for backoff
$backoffUntil = [datetime]::MinValue

while ($true) {
    try {
        $alive = $false
        if ($sessionPid) {
            $alive = [bool](Get-Process -Id $sessionPid -ErrorAction SilentlyContinue)
        }

        if (-not $alive) {
            # confirm via command line before declaring it dead -- it may have been
            # restarted by something else, or our recorded pid may be stale.
            $found = Get-RcClaudePid
            if ($found) {
                if ($found -ne $sessionPid) { Log "adopted existing session, claude pid $found" }
                $sessionPid = $found
            }
            elseif ((Get-Date) -lt $backoffUntil) {
                # in backoff, do nothing this tick
            }
            else {
                if ($sessionPid) { Log "session pid $sessionPid is gone -- restarting" }
                else { Log 'no session running -- starting' }

                Start-RcSession

                # wait for it to come up and record the new pid
                $deadline = (Get-Date).AddSeconds(45)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 500
                    $found = Get-RcClaudePid
                    if ($found) {
                        $sessionPid = $found; Log "session up, claude pid $found"
                        # Capture now, while it is unambiguous which window was
                        # just created. Best-effort: a failure here costs the
                        # deterministic path, not the session.
                        try { Save-SessionWindow -ClaudePid $found -Before $script:windowsBefore }
                        catch { Log "window capture failed: $_" }
                        break
                    }
                }
                if (-not $found) { Log 'session did NOT come up within 45s'; $sessionPid = $null }

                # crash-loop guard: >5 restarts in 5 minutes -> back off 2 minutes
                $now = Get-Date
                $restarts = @($restarts | Where-Object { $_ -gt $now.AddMinutes(-5) })
                $restarts += $now
                if ($restarts.Count -gt 5) {
                    $backoffUntil = $now.AddMinutes(2)
                    Log "crash loop detected ($($restarts.Count) restarts in 5 min) -- backing off until $backoffUntil"
                    $restarts = @()
                }
            }
        }
    } catch {
        Log "watchdog error: $_"
    }

    Start-Sleep -Milliseconds $POLL_MS
}
