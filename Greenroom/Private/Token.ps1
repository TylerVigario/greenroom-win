# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Whether a RUNNING process actually holds a full admin token.

  CONFIGURED elevation and RUNNING elevation are different facts, and the gap between
  them is silent. Re-registering a task as RunLevel Limited does not touch the session
  already running under the old one: it keeps the token it started with until something
  restarts it. MEASURED on the reference host -- after
  `Install-GreenroomInstance -Elevated:$false` the task read Limited, the session was
  the same pid, and its token was still S-1-16-12288.

  A separate P/Invoke type from Win32.ps1, for the reason that file records: Add-Type
  cannot redefine a live type, so a long-lived shell that imported an older Greenroom
  binds to the stale definition and fails on any member added since. A new concern gets
  a new type rather than a new member on an old one.
#>
if (-not ('Greenroom.Tok1' -as [type])) {
    Add-Type -Namespace Greenroom -Name Tok1 -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr proc, uint access, out IntPtr token);
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, int len, out int need);
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr str);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
[DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr h);
'@
}

$script:TOKEN_QUERY         = 0x0008
$script:TokenIntegrityLevel = 25      # TOKEN_INFORMATION_CLASS ordinal

<#
  The integrity-level SID of a running process -- 'S-1-16-12288' and the rest -- or
  $null when it cannot be read.

  $NULL IS A REAL ANSWER, NOT A FAILURE. A lower-integrity caller cannot open the token
  of a higher-integrity process at all: the same blindness that makes
  Win32_Process.CommandLine read NULL across levels. Callers must read it as "unknown"
  and fall back to what was configured. Reading it as "not elevated" would be the
  confident wrong answer this whole file exists to stop.
#>
function Get-ProcessIntegritySid {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$ProcessId)

    $token = [IntPtr]::Zero
    $buf = [IntPtr]::Zero
    try {
        $h = (Get-Process -Id $ProcessId -ErrorAction Stop).Handle
        if (-not [Greenroom.Tok1]::OpenProcessToken($h, $script:TOKEN_QUERY, [ref]$token)) { return $null }

        # Two calls, and the FIRST IS EXPECTED TO FAIL: it asks how large the
        # TOKEN_MANDATORY_LABEL is, reporting insufficient-buffer. Its return value is
        # deliberately discarded; $need is the answer.
        $need = 0
        [void][Greenroom.Tok1]::GetTokenInformation($token, $script:TokenIntegrityLevel, [IntPtr]::Zero, 0, [ref]$need)
        if ($need -le 0) { return $null }

        $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal($need)
        if (-not [Greenroom.Tok1]::GetTokenInformation($token, $script:TokenIntegrityLevel, $buf, $need, [ref]$need)) { return $null }

        # TOKEN_MANDATORY_LABEL is a SID_AND_ATTRIBUTES, whose first field is a POINTER
        # to the SID rather than the SID itself. Reading the struct as the SID yields
        # mojibake that looks like a plausible string, which is how this goes wrong
        # quietly rather than loudly.
        $sidPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($buf)
        $strPtr = [IntPtr]::Zero
        if (-not [Greenroom.Tok1]::ConvertSidToStringSidW($sidPtr, [ref]$strPtr)) { return $null }
        try { return [Runtime.InteropServices.Marshal]::PtrToStringUni($strPtr) }
        finally { [void][Greenroom.Tok1]::LocalFree($strPtr) }
    }
    catch { return $null }
    finally {
        if ($buf -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
        if ($token -ne [IntPtr]::Zero) { [void][Greenroom.Tok1]::CloseHandle($token) }
    }
}

<#
  Whether a running session actually has a full admin token: $true, $false, or $null
  when this caller cannot see. High and System count; anything below does not.
#>
function Test-SessionElevated {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)

    $sid = Get-ProcessIntegritySid -ProcessId $ProcessId
    if (-not $sid) { return $null }
    return ($sid -in 'S-1-16-12288', 'S-1-16-16384')
}
