# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Re-run a command elevated, in a new process, and return its exit code and what it said.

  An unelevated shell cannot show, hide or foreground a window owned by an elevated
  process. MEASURED rather than taken from documentation: ShowWindow(SW_HIDE) against
  an elevated window returned false with GetLastWin32Error 5 (ERROR_ACCESS_DENIED) and
  the window did not move. No exception, no prompt. Acting anyway prints success and
  does nothing.

  Refusing would be safe but useless -- the operator still wants the window. So
  re-launch elevated and let the elevated copy do the work. A UAC prompt is acceptable
  here because this is an interactive command someone just typed. That is the opposite
  of the logon path, where a UAC dialog behind a hidden window would be an invisible
  hang, which is why the session takes its token from the task trigger instead.

  The module is imported BY PATH, not by name. Resolving by name would depend on
  PSModulePath being identical in the elevated context, and an explicit path removes
  that dependency entirely.

  Takes SEVERAL names, so one prompt covers every elevated instance a command matched.
  They are piped to the command rather than passed as -Name, which takes one name: piped,
  they reach one invocation, so Stop-GreenroomSession over there still settles once.

  The elevated window closes as it exits, so everything it prints is gone with it. What
  the command returned, warned and failed with is therefore written to a CLIXML file and
  read back here -- see Write-ForwardedRecord for how it is replayed. Without that, an
  operator acting on an elevated instance from an ordinary shell saw nothing at all:
  no StopResult, no instance row, no error text, only whether the exit code was zero.
#>
function Invoke-ElevatedSelf {
    [CmdletBinding()]
    [OutputType('Greenroom.ElevatedRun')]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Name
    )

    $list = ($Name | ForEach-Object { "'$_'" }) -join ', '
    Write-Warning "$list $(if ($Name.Count -eq 1) { 'runs' } else { 'run' }) elevated and this shell does not. Re-launching elevated..."

    # Single-quoted inside the -Command string so nothing is re-interpreted by the
    # elevated shell, with embedded quotes doubled -- which is how PowerShell escapes a
    # quote inside a single-quoted string.
    #
    # The instance name cannot contain one (ValidatePattern allows only letters, digits,
    # dot, dash and underscore) but THE MODULE PATH CAN: a home directory belonging to
    # someone called O'Brien is enough to break the command otherwise.
    $manifest  = (Join-Path $script:GreenroomModuleRoot 'Greenroom.psd1').Replace("'", "''")
    $safeNames = ($Name | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','

    # -Confirm:$false, deliberately. The caller has ALREADY passed its own ShouldProcess
    # gate before escalating, so the decision is made; a fresh process would otherwise
    # start with default preferences and either prompt a second time or, worse, not
    # prompt at all because -Confirm was never forwarded.
    #
    # ErrorActionPreference=Stop and an explicit exit, NOT $LASTEXITCODE. That variable
    # is only set by NATIVE commands, so a PowerShell function that fails with a
    # non-terminating Write-Error leaves it untouched -- and in a fresh process it is
    # $null, which exits 0. MEASURED: an inner command whose function wrote a
    # non-terminating error exited 0, so every recoverable failure over there was
    # reported here as success, and the caller then skipped acting locally on the
    # strength of work that never happened.
    #
    # The command itself runs with -ErrorAction Continue, overriding that Stop, because a
    # batch must carry on past one instance's failure exactly as the local loop does; its
    # errors are counted through -ErrorVariable instead. MEASURED in a child process: an
    # error from the second of three names still let the third run, and exited 1 -- as
    # did an error written by a helper the command called rather than by the command.
    #
    # The exit code still has to be right on its own: it is what signals failure when the
    # result file never gets written, because the child died before reaching that line.
    #
    # What the command said travels in a CLIXML file. The elements are PIPED to
    # Export-Clixml -- given as -InputObject, an array serializes as one opaque object and
    # comes back as a single unreadable blob. Warnings and errors are flattened into plain
    # objects first, because a WarningRecord's Message and an ErrorRecord's category both
    # come back EMPTY from deserialization. MEASURED on 5.1 and 7 alike. GreenroomStream
    # marks them; no result object the module emits carries that property.
    #
    # Two constraints on the text of this command. It contains no double quotes: it
    # reaches the child as an argument to Start-Process, and whether a double quote
    # survives that depends on the edition doing the launching. And the export is wrapped
    # separately from the command, so a file that fails to write costs the replay but not
    # the exit code -- the command's own success is what that reports.
    #
    # -NoClobber because the child is elevated and the path is in the user's temp: if
    # anything already sits at that name -- a planted link, say -- the write is refused
    # rather than followed.
    $out     = Join-Path ([IO.Path]::GetTempPath()) ('greenroom-elevated-' + [guid]::NewGuid().ToString('N') + '.clixml')
    $safeOut = $out.Replace("'", "''")

    $inner = (
        "`$ErrorActionPreference='Stop';",
        "try {",
        "  Import-Module '$manifest' -Force; `$ev = `$null;",
        "  `$r = @($safeNames | $Command -NoElevate -Confirm:`$false -ErrorAction Continue -ErrorVariable ev 3>&1 2>&1);",
        "  try {",
        "    `$r | ForEach-Object {",
        "      if (`$_ -is [System.Management.Automation.WarningRecord]) { [pscustomobject]@{ GreenroomStream = 'Warning'; Message = [string]`$_.Message } }",
        "      elseif (`$_ -is [System.Management.Automation.ErrorRecord]) { [pscustomobject]@{ GreenroomStream = 'Error'; Message = [string]`$_; ErrorId = [string]`$_.FullyQualifiedErrorId; Category = [string]`$_.CategoryInfo.Category } }",
        "      else { `$_ }",
        "    } | Export-Clixml -LiteralPath '$safeOut' -NoClobber -Depth 4",
        "  } catch { }",
        "  exit ([int](`$ev.Count -gt 0))",
        "} catch {",
        "  try { [pscustomobject]@{ GreenroomStream = 'Error'; Message = [string]`$_; ErrorId = 'ElevatedRunCrashed'; Category = 'NotSpecified' } | Export-Clixml -LiteralPath '$safeOut' -NoClobber } catch { }",
        "  exit 1",
        "}"
    ) -join ' '

    try {
        try {
            $p = Start-Process pwsh -Verb RunAs -PassThru -Wait -ErrorAction Stop `
                     -ArgumentList '-NoLogo', '-NoProfile', '-Command', $inner
        }
        catch {
            # The usual cause is the UAC prompt being dismissed, which is a decision rather
            # than a fault, so it is reported as one.
            throw "elevation declined or failed -- $list $(if ($Name.Count -eq 1) { 'was' } else { 'were' }) not changed. To do it by hand, from an elevated shell: $list | $Command"
        }

        # Absent is not an error in itself: a child that died before exporting leaves no
        # file, and its exit code already says so.
        $records = @()
        if (Test-Path -LiteralPath $out) { $records = @(Import-Clixml -LiteralPath $out) }

        [PSCustomObject]@{
            PSTypeName = 'Greenroom.ElevatedRun'
            ExitCode   = $p.ExitCode
            Records    = $records
        }
    }
    finally { Remove-Item -LiteralPath $out -Force -ErrorAction Ignore }
}

<#
  Replay what an elevated run said, into the stream each piece came from.

  With -Cmdlet, everything goes through the CALLER's cmdlet: objects reach its output even
  from inside a helper whose own output is being captured, and errors name the command
  that was typed and obey its -ErrorAction. Result objects get their type name back --
  deserialization prefixes it with Deserialized., which would lose them their table view.
  Only the module's own types are restored; anything else is left as it arrived.

  Without -Cmdlet, objects are DROPPED and errors are NOT written. That path serves
  Assert-CanActOnInstance, whose return value is a bool the caller tests in an if; an
  object emitted there would be read as part of that answer, and the commands that use it
  return nothing anyway. Its errors come back as text for Assert to fold into its one
  error: under the module's ErrorActionPreference of Stop, a Write-Error here would throw
  before this function returned, taking the rest of the replay with it.

  Returns the message of every error the run reported, written or not -- the caller needs
  to know whether a generic "it failed" still needs saying.
#>
function Write-ForwardedRecord {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][object[]]$Record = @(),
        [System.Management.Automation.PSCmdlet]$Cmdlet
    )

    $errors = @()
    foreach ($r in $Record) {
        if ($null -eq $r) { continue }
        $stream = if ($r.PSObject.Properties['GreenroomStream']) { $r.GreenroomStream }

        if ($stream -eq 'Warning') {
            if ($Cmdlet) { $Cmdlet.WriteWarning($r.Message) } else { Write-Warning $r.Message }
        }
        elseif ($stream -eq 'Error') {
            $errors += [string]$r.Message
            if ($Cmdlet) {
                # The id arrives qualified by the command that raised it over there
                # ("Boom,Stop-GreenroomSession"); WriteError qualifies it again, so strip it.
                $id  = ([string]$r.ErrorId -split ',')[0]
                if (-not $id) { $id = 'ElevatedRunError' }
                $cat = [System.Management.Automation.ErrorCategory]::NotSpecified
                [void][Enum]::TryParse([string]$r.Category, [ref]$cat)
                $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new([string]$r.Message), $id, $cat, $null))
            }
        }
        elseif ($Cmdlet) {
            $first = $r.PSObject.TypeNames[0]
            if ($first -like 'Deserialized.Greenroom.*') { $r.PSObject.TypeNames.Insert(0, $first.Substring(13)) }
            $Cmdlet.WriteObject($r)
        }
    }

    # Unrolled, so the caller's @() gets strings rather than a nested array.
    $errors
}

<#
  Escalate, once, every instance a command deferred with Assert-CanActOnInstance -Defer.

  Reports through the CALLER's $PSCmdlet, as Resolve-InstanceName does, so a declined
  prompt or a failed elevated run names the command that was typed and obeys its
  -ErrorAction. A declined prompt is caught rather than left to unwind: it is one failure
  to report, not a reason to skip what the caller still has to do after it.
#>
function Invoke-DeferredElevation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet
    )

    # A NEW record, not the caught one re-written: that would keep its origin, and name
    # Invoke-ElevatedSelf to the operator instead of the command they typed.
    try { $run = Invoke-ElevatedSelf -Command $Command -Name $Name }
    catch {
        $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [System.OperationCanceledException]::new($_.Exception.Message, $_.Exception),
            'ElevationDeclined', [System.Management.Automation.ErrorCategory]::PermissionDenied, $Name))
        return
    }

    $reported = @(Write-ForwardedRecord -Record $run.Records -Cmdlet $Cmdlet)

    # Only when the run failed WITHOUT saying why -- it died before writing its results.
    # If its own errors came back they are the explanation, and a generic line on top
    # would be one failure reported twice.
    if ($run.ExitCode -ne 0 -and $reported.Count -eq 0) {
        $list = ($Name | ForEach-Object { "'$_'" }) -join ', '
        $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new(
                "the elevated '$Command' for $list exited with code $($run.ExitCode) and reported " +
                "nothing back; run '$Command' from an elevated shell to see why."),
            'ElevatedRunFailed', [System.Management.Automation.ErrorCategory]::NotSpecified, $Name))
    }
}

<#
  Decide whether this shell may act on an instance's window, and escalate if not.

  Returns $true when the caller should proceed itself, $false when the work has
  already been done by an elevated copy.

  With -Defer, escalation is NOT done here: the name is added to that list, $false is
  returned, and the caller escalates the whole list once, with Invoke-DeferredElevation.
  That is for commands that act on several instances. Escalating each as it came up
  raised one UAC prompt PER ELEVATED INSTANCE, so `Stop-GreenroomSession *` on a host
  with three of them asked three times for one decision.
#>
function Assert-CanActOnInstance {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [switch]$NoElevate,
        [System.Collections.Generic.List[string]]$Defer
    )

    # config.json is readable at any integrity level, so its flag is trustworthy even
    # where the process command line is not.
    if (-not (Test-InstanceElevated -Name $Name)) { return $true }
    if (Test-SelfElevated) { return $true }

    # A BACKSTOP, not the primary guard. Every public command gates on ShouldProcess
    # BEFORE calling this, so under -WhatIf escalation is already unreachable. This
    # stays because the cost of the ordering silently regressing is a dry run that
    # raises a UAC prompt and then performs the real action in the other process --
    # which is exactly what happened before that ordering was fixed.
    #
    # $WhatIfPreference is inherited by called functions, verified rather than assumed.
    if ($WhatIfPreference) {
        Write-Verbose "'$Name' runs elevated; not escalating because -WhatIf changes nothing anyway"
        return $true
    }

    if ($NoElevate) {
        Write-Error -Category PermissionDenied -Message (
            "'$Name' runs ELEVATED and this shell does not. UIPI blocks ShowWindow and " +
            'SetForegroundWindow from a lower integrity level, so the operation would report ' +
            'success and do nothing at all. -NoElevate was passed, so this is not being ' +
            'escalated automatically.')
        return $false
    }

    # $null, not truthiness: the list is EMPTY the first time, and an empty list is falsy.
    if ($null -ne $Defer) { $Defer.Add($Name); return $false }

    $run = Invoke-ElevatedSelf -Command $Command -Name $Name

    # Warnings replay as they are. Errors come back as text and are folded into the one
    # error this has always written -- see Write-ForwardedRecord for why not one each.
    $reported = @(Write-ForwardedRecord -Record $run.Records)
    if ($run.ExitCode -ne 0 -or $reported.Count) {
        $why = if ($reported.Count) { $reported -join '; ' } else { "exited with code $($run.ExitCode) and reported nothing back" }
        Write-Error "the elevated '$Command' for '$Name' failed: $why"
    }
    return $false
}
