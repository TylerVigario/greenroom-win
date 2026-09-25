# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Work out the settings an install should actually use, by merging what was passed
  with what the previous install of this instance recorded.

  THIS IS THE MOST DANGEROUS FUNCTION IN THE MODULE, and every rule in it is a bug
  that happened. Installing is documented as idempotent and safe to re-run, so a bare
  re-run that quietly changed something the operator never mentioned is a betrayal of
  that promise -- and each of these did exactly that:

    -WorkingDirectory   omitted, it fell back to ~/<instance>, RELOCATING the
                        instance: new directory created, trust seeded for it, session
                        restarted there, abandoning the real working directory along
                        with its project store, memory and transcripts. Reproduced on
                        two instances at once.
    -TriggerDelay       omitted, it reset a deliberately staggered PT3M to PT1M,
                        un-staggering a multi-instance host.
    -AdditionalDirectories omitted, it rebuilt the grant list as empty and wrote that
                        through to config.json, the project settings and the launch
                        line, silently revoking access.
    -ClaudeExe          a deliberate choice reverted to auto-detection.
    -Elevated           dropped, leaving an instance that still looks installed and
                        fails later with Access Denied inside a hidden window.

  Passing a parameter is always authoritative. Omitting it inherits. Clearing is
  explicit: -AdditionalDirectories @() and -ClaudeExe ''.

  Returns a settings object; writes nothing.
#>
function Resolve-InstallParameter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Bound,
        [string]$WorkingDirectory,
        [string]$ClaudeExe,
        [string]$TriggerDelay,
        [string[]]$AdditionalDirectories,
        [bool]$Elevated,
        [string]$Model
    )

    $stateDir = Join-Path (Get-GreenroomStateRoot) $Name
    $cfgPath  = Join-Path $stateDir 'config.json'
    $task     = "greenroom-$Name"

    $prev = $null
    $prevUnreadable = $false
    if (Test-Path $cfgPath) {
        try { $prev = Get-Content $cfgPath -Raw | ConvertFrom-Json }
        catch { $prevUnreadable = $true }
    }

    # A config that EXISTS but will not parse is not the same as no config, and
    # swallowing the difference reopens the relocation bug through another door: with
    # nothing to inherit, every omitted parameter falls back to its default.
    if ($prevUnreadable) {
        # -Elevated belongs in this list even though its consequence is different. The
        # others fall back to a default that relocates or un-configures the instance;
        # this one falls back to NOT ELEVATED, silently demoting a session that was
        # deliberately given a full admin token. Elevation announces itself on every
        # ordinary re-run precisely because it is security-relevant, so dropping it
        # without a word on the one path where nothing can be inherited is the worst
        # place to be quiet.
        $omitted = @('WorkingDirectory', 'TriggerDelay', 'AdditionalDirectories', 'Elevated') |
                   Where-Object { -not $Bound.ContainsKey($_) } | ForEach-Object { "-$_" }
        if ($omitted.Count -gt 0) {
            throw ("'$cfgPath' exists but cannot be parsed, so this instance's remembered settings are " +
                   "unreadable. Refusing to continue: $($omitted -join ', ') were omitted, and with nothing " +
                   'to inherit they would fall back to defaults -- relocating the instance to ' +
                   "'$(Join-Path $env:USERPROFILE $Name)' and abandoning its project store, memory and " +
                   'transcripts, and dropping elevation from any instance that had it. Repair or delete ' +
                   'that file, or pass every value explicitly.')
        }
    }

    if (-not $Bound.ContainsKey('WorkingDirectory') -and $prev -and $prev.workingDirectory) {
        $WorkingDirectory = $prev.workingDirectory
        Write-Verbose "keeping working directory from the previous install: $WorkingDirectory"
    }
    if (-not $WorkingDirectory) { $WorkingDirectory = Join-Path $env:USERPROFILE $Name }

    # Elevation inherits like the rest, but ANNOUNCES itself every time rather than
    # only under -Verbose, because it is security-relevant.
    if (-not $Bound.ContainsKey('Elevated') -and $prev -and $prev.elevated) {
        $Elevated = $true
        Write-Warning "keeping ELEVATED from the previous install of '$Name'. Pass -Elevated:`$false to drop it."
    }

    if (-not $Bound.ContainsKey('TriggerDelay')) {
        if ($prev -and $prev.triggerDelay) {
            $TriggerDelay = $prev.triggerDelay
            Write-Verbose "keeping trigger delay from the previous install ($TriggerDelay)"
        }
        else {
            # config.json only started recording triggerDelay later, so an instance
            # installed before that has nothing to inherit. The registered task is the
            # authoritative record of the delay actually in force.
            $existing = Get-ScheduledTask -TaskPath '\' -TaskName $task -ErrorAction Ignore
            $fromTask = if ($existing -and $existing.Triggers) { $existing.Triggers[0].Delay } else { $null }
            if ($fromTask) {
                $TriggerDelay = $fromTask
                Write-Verbose "keeping trigger delay from the registered task ($TriggerDelay)"
            }
        }
    }
    if (-not $TriggerDelay) { $TriggerDelay = 'PT1M' }

    # -ClaudeExe persists a FLAG ABOUT the value, not just the value, because
    # config.json records the RESOLVED path. Inheriting unconditionally would pin
    # whatever auto-detection picked and defeat the WinGet Links shim, which is
    # package-ID-keyed and survives upgrades.
    #
    # The flag has to carry forward too. Deriving it from the bound parameters at
    # write time recorded 'false' on the very run that had just inherited, so the
    # choice survived exactly one bare re-run.
    $claudeExplicit  = ($Bound.ContainsKey('ClaudeExe') -and [bool]$ClaudeExe)
    $claudeInherited = $false
    if (-not $Bound.ContainsKey('ClaudeExe') -and $prev -and $prev.claudeExeExplicit -and $prev.claudeExe) {
        $ClaudeExe       = $prev.claudeExe
        $claudeExplicit  = $true
        $claudeInherited = $true
    }

    # An explicit choice that does not exist must not be silently discarded. The
    # candidate list filters on Test-Path, so a missing path dropped out and
    # auto-detection took over -- while claudeExeExplicit then pinned the
    # AUTO-DETECTED path as though it were the choice.
    if ($claudeExplicit -and -not (Test-Path -LiteralPath $ClaudeExe)) {
        $origin = if ($Bound.ContainsKey('ClaudeExe')) { 'was passed on this run' }
                  else { "was inherited from the previous install of '$Name'" }
        throw ("-ClaudeExe '$ClaudeExe' does not exist. It $origin. Refusing to continue: auto-detection " +
               'would silently take over and be recorded as though it were the deliberate choice. Point it ' +
               "at a binary that exists, or pass -ClaudeExe '' to return to auto-detection.")
    }
    if ($claudeInherited) { Write-Verbose "keeping explicitly chosen claude.exe: $ClaudeExe" }

    # Inherits like the rest. Clearing is explicit -- -Model '' returns the instance to
    # whatever the CLI would choose on its own.
    if (-not $Bound.ContainsKey('Model') -and $prev -and $prev.model) {
        $Model = $prev.model
        Write-Verbose "keeping model from the previous install: $Model"
    }

    if (-not $Bound.ContainsKey('AdditionalDirectories') -and $prev) {
        $prevGrants = @($prev.additionalDirectories) | Where-Object { $_ }
        if ($prevGrants.Count -gt 0) {
            $AdditionalDirectories = $prevGrants
            Write-Verbose "inheriting $($prevGrants.Count) grant(s); pass -AdditionalDirectories @() to clear"
        }
    }

    $grants = @()
    foreach ($d in $AdditionalDirectories) {
        if (-not (Test-Path $d)) {
            throw "-AdditionalDirectories: '$d' does not exist. Refusing to grant a path that isn't there."
        }
        $grants += (Resolve-Path $d).Path
    }

    [PSCustomObject]@{
        Instance              = $Name
        StateDir              = $stateDir
        TaskName              = $task
        WorkingDirectory      = $WorkingDirectory
        ClaudeExe             = $ClaudeExe
        ClaudeExeExplicit     = $claudeExplicit
        TriggerDelay          = $TriggerDelay
        AdditionalDirectories = $grants
        Elevated              = $Elevated
        Model                 = $Model
    }
}
