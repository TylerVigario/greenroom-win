# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Resolve and verify everything an instance needs before anything is registered.

  All of these fail SILENTLY inside a hidden window if they are wrong, which is why
  they are checked here rather than discovered later as "it just doesn't work".

  Returns the resolved paths; throws on anything fatal.
#>
function Resolve-GreenroomPrerequisite {
    [CmdletBinding()]
    param([string]$ClaudeExe)

    # Windows Terminal is a HARD requirement. conhost does no font fallback and no
    # console-registerable font carries the glyphs the TUI draws, so under conhost the
    # interface renders as boxes.
    $wt = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
        (Get-Command wt.exe -ErrorAction SilentlyContinue | ForEach-Object Source)
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $wt) { throw 'Windows Terminal (wt.exe) not found and is required. winget install Microsoft.WindowsTerminal' }

    # The shell that runs the watchdog and the session. pwsh 7 is PREFERRED -- WinGet's
    # version-independent alias first, then the real install path, then anything on PATH.
    # Windows PowerShell 5.1 ships in-box on every Windows host and is the last resort, so a
    # machine with no pwsh 7 still installs. greenroom's code runs on both editions, and this
    # is the same ladder the watchdog .vbs walks at logon.
    $shell = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Get-Command pwsh.exe -ErrorAction SilentlyContinue | ForEach-Object Source),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $shell) { throw 'no PowerShell found: neither pwsh.exe nor Windows PowerShell 5.1 (powershell.exe).' }

    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path $wscript)) { throw "wscript.exe not found at $wscript" }

    # Candidate ORDER matters, and PATH decides it. Whatever `claude` resolves to in the
    # operator's own shell is what the supervised session should run. greenroom does not
    # install Claude Code, so ranking the ways it can be installed is not its business --
    # and the list would have to be maintained against someone else's distribution matrix
    # forever: native, npm, WinGet, two Homebrew casks, apt, dnf, apk.
    #
    # A hard-coded WinGet Links entry came FIRST until this changed, justified by that path
    # being keyed on package ID rather than version, so it survives upgrades. That is true
    # and not distinctive: EVERY Windows install path for this CLI is version-stable. The
    # WinGet package directory carries no version segment either, the native launcher at
    # ~\.local\bin keeps its versions under ~\.local\share\claude\versions, and the npm shim
    # is fixed as well. So the preference bought nothing the alternatives lacked.
    #
    # What it DID do was outrank a newer install silently. A package-manager install caps
    # itself at whatever the manifest offers -- `claude doctor` says so outright,
    # "Auto-updates: Managed by package manager" -- so on a host carrying both, greenroom
    # chose the one that cannot update itself. MEASURED: WinGet at 2.1.268 preferred over a
    # native 2.1.282 that PATH already ranked first, with a green line and no warning.
    #
    # ~\.local\bin stays as a LAST resort, for a native install whose directory is not on
    # PATH. In the normal case PATH reaches it and this entry is never used.
    $candidates = @()
    if ($ClaudeExe) { $candidates += $ClaudeExe }
    $candidates += (Get-Command claude.exe -All -ErrorAction SilentlyContinue | ForEach-Object Source)
    $candidates += (Join-Path $env:USERPROFILE '.local\bin\claude.exe')

    # Claude DESKTOP ships its own claude.exe plus a private bundled CLI; neither is a
    # valid target, and its location depends on install method.
    $desktopPatterns = @(
        '*\Program Files\WindowsApps\*',
        '*\AnthropicClaude\*',
        '*\AppData\Roaming\Claude\claude-code\*'
    )

    $seen = @{}
    $claude = $candidates | Where-Object {
        if (-not $_) { return $false }
        if (-not (Test-Path $_)) { return $false }
        foreach ($pat in $desktopPatterns) { if ($_ -like $pat) { return $false } }
        $k = $_.ToLower()
        if ($seen.ContainsKey($k)) { return $false }
        $seen[$k] = $true
        return $true
    } | Select-Object -First 1

    if (-not $claude) { throw 'Claude Code CLI (claude.exe) not found. Pass -ClaudeExe, or install Claude Code first.' }

    # Deliberately NOT resolved through the symlink: the WinGet Links entry points at a
    # versioned target, and following it bakes a path that breaks on the next upgrade.
    $claude = [System.IO.Path]::GetFullPath($claude)

    $ver = (& $claude --version 2>&1 | Out-String).Trim()
    if ($ver -notmatch 'Claude Code') {
        throw "'$claude' does not look like the Claude Code CLI (--version said: $ver). Pass -ClaudeExe explicitly."
    }

    # THE WORST FAILURE GREENROOM HAS. Without --remote-control the session dies
    # instantly inside a hidden window, the watchdog restarts it, the crash-loop guard
    # trips, and nothing surfaces anywhere.
    #
    # The '[' anchor matters: older builds carry --remote-control-session-name-prefix
    # without the flag itself, and a bare substring match passes on those.
    $help = (& $claude --help 2>&1 | Out-String)
    if ($help -notmatch '--remote-control\s*\[') {
        throw ("'$claude' ($ver) does not support --remote-control. Verified absent in 2.1.92, present " +
               'from 2.1.218. Note --remote-control-session-name-prefix is a DIFFERENT flag that may be ' +
               'present without this one. Upgrade Claude Code, or pass -ClaudeExe at a build that has it.')
    }

    [PSCustomObject]@{
        WindowsTerminal = $wt
        Shell           = $shell
        WScript         = $wscript
        ClaudeExe       = $claude
        ClaudeVersion   = $ver
    }
}

<#
  Prove a model value works before it can reach a launch line.

  An unusable --model is FATAL and silent: claude exits 1 at once, the launcher records it,
  the watchdog never sees a session come up, and the crash-loop guard eventually trips --
  all inside a hidden window. Same failure class as a CLI without --remote-control, so it
  is checked the same way, by running the thing.

  MEASURED on the reference host:
    claude --model definitely-not-a-real-model-xyz --print  -> exit 1, "There's an issue
                                                               with the selected model"
    claude --model opus --print                             -> exit 0
    claude --model <anything> --version                     -> exit 0 EITHER WAY

  That last line is why this costs an API call: --version short-circuits and validates
  nothing, so there is no free probe. The caller therefore runs this only when -Model was
  passed EXPLICITLY, never when it was inherited from the previous install.
#>
function Assert-ClaudeModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudeExe,
        [Parameter(Mandatory)][string]$Model
    )

    # PROBED FROM A THROWAWAY DIRECTORY, and that is not tidiness.
    #
    # --print writes a transcript into the project store of the CURRENT directory, and
    # Install- is most naturally run from the instance's own working directory -- the one
    # store greenroom must not litter, because greenroom-launch.ps1 resumes the NEWEST
    # transcript there. A probe stub landing in it could become the conversation the
    # instance comes back to at its next restart.
    #
    # Measured: probing from ~/src/greenroom-win left two 11 KB transcripts in that
    # project store whose only user message was "ok". Probing from a temp directory puts
    # them under that path's slug instead, which is then removed with it.
    $probeDir = Join-Path ([IO.Path]::GetTempPath()) "greenroom-model-probe-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    # Same slug rule the launcher uses: the literal path with every non-alphanumeric
    # character replaced by a dash.
    $store = Join-Path $env:USERPROFILE (".claude\projects\" + ($probeDir -replace '[^A-Za-z0-9]', '-'))

    Push-Location $probeDir
    try {
        $out  = (& $ClaudeExe --model $Model --print 'ok' 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
        Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $store    -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($code -eq 0) {
        Write-Verbose "model '$Model' accepted by $ClaudeExe"
        return
    }

    $first = @($out -split "`r?`n" | Where-Object { $_ }) | Select-Object -First 1
    throw ("-Model '$Model' was rejected by the CLI, so it is not written and nothing has been " +
           "changed. A bad model would exit 1 inside a hidden window and crash-loop the instance. " +
           "The CLI said: $first")
}

<#
  Warn about host settings that break a supervised session invisibly.

  Advisory only -- none of these are fatal, and none are greenroom's to fix. They go to
  the Warning stream so a caller can suppress or capture them.
#>
function Test-GreenroomHostSetting {
    [CmdletBinding()]
    param()

    $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path $settings)) { return }

    $s = $null
    try { $s = Get-Content $settings -Raw | ConvertFrom-Json }
    catch { Write-Warning "could not parse $settings"; return }

    # Git for Windows puts Git\cmd and Git\mingw64\bin on PATH but NOT Git\bin, which
    # is where bash.exe lives -- so a stock install satisfies `git` and fails `bash`,
    # and every Bash tool call then fails silently in a hidden window.
    if ($s.defaultShell -eq 'bash') {
        $inProc = Get-Command bash -ErrorAction SilentlyContinue

        # Build the PATH a NEW process would get, from the registry. This process may
        # hold a stale environment block, and that false negative is otherwise
        # indistinguishable from a real failure.
        $machine = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name Path).Path
        $user    = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
        $fresh   = [Environment]::ExpandEnvironmentVariables(($machine.TrimEnd(';') + ';' + $user))
        $freshHit = ($fresh -split ';') |
                    Where-Object { $_ -and (Test-Path (Join-Path $_ 'bash.exe')) } | Select-Object -First 1

        if ($inProc -and $freshHit) {
            Write-Verbose "shell: bash -> $($inProc.Source)"
        }
        elseif ($freshHit) {
            Write-Warning ("bash resolves in the registry PATH ($freshHit) but not in THIS process, which " +
                           'holds a stale environment block. A task-launched session will be fine.')
        }
        else {
            $msg = 'defaultShell is "bash" but bash.exe does not resolve on PATH. Every Bash tool call will fail silently in a hidden window.'
            $git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
            if ($git) {
                $gitBin = Join-Path (Split-Path (Split-Path $git)) 'bin'
                if (Test-Path (Join-Path $gitBin 'bash.exe')) {
                    $msg += " Add '$gitBin' to your USER PATH. Do NOT add Git\usr\bin -- it also has bash but shadows Windows echo/find/sort/tee and breaks scripts."
                }
            }
            Write-Warning $msg
        }
    }

    # A marketplace whose source directory is missing throws a plugin load error at
    # every session start -- invisible, same as everything else here.
    if ($s.extraKnownMarketplaces) {
        foreach ($p in $s.extraKnownMarketplaces.PSObject.Properties) {
            $path = $p.Value.source.path
            if ($p.Value.source.source -eq 'directory' -and $path -and -not (Test-Path $path)) {
                $m = "marketplace '$($p.Name)' points at a path that does not exist: $path. Remove extraKnownMarketplaces.$($p.Name) from $settings"
                if ($s.enabledPlugins) {
                    $refs = @($s.enabledPlugins.PSObject.Properties.Name | Where-Object { $_ -like "*@$($p.Name)" })
                    if ($refs) { $m += ", plus enabledPlugins: $($refs -join ', ')" }
                }
                Write-Warning $m
            }
        }
    }

    # A host-wide grant defeats per-instance scoping. Filter falsy entries: @($null)
    # has Count 1, so an absent key would otherwise report a grant of nothing.
    $hostWide = @($s.permissions.additionalDirectories | Where-Object { $_ })
    if ($hostWide.Count -gt 0) {
        Write-Warning ("$settings grants these to EVERY instance on this host: $($hostWide -join ', '). " +
                       'Move them into a per-instance -AdditionalDirectories grant instead.')
    }
}
