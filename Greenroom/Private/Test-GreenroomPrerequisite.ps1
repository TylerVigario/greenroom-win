# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

# Where Claude Code is. Lives in Assets/ because the launcher needs the same answer and cannot
# reach Private/; the module does not load Assets/ on its own.
. (Join-Path $script:GreenroomModuleRoot 'Assets\Find-ClaudeCode.ps1')

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

    $shell = Resolve-GreenroomShell

    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path $wscript)) { throw "wscript.exe not found at $wscript" }

    # AN EXPLICIT -ClaudeExe IS THAT PATH OR NOTHING. As one candidate among the others, a
    # choice the filters below reject -- Claude Desktop's bundled claude.exe -- simply
    # dropped out, auto-detection supplied another, and install then recorded THAT path as
    # the explicit choice, pinning it on every later re-run. So it is checked alone, and
    # refused with the reason.
    # Auto-detection lives in Assets\Find-ClaudeCode.ps1, where the launcher can reach it too.
    if ($ClaudeExe) {
        if (Test-ClaudeDesktopPath $ClaudeExe) {
            throw ("-ClaudeExe '$ClaudeExe' is Claude Desktop's bundled claude.exe, not a Claude Code CLI " +
                   'greenroom can run. Pass the CLI''s path, or omit -ClaudeExe to find it automatically.')
        }
        if (-not (Test-Path -LiteralPath $ClaudeExe)) { throw "-ClaudeExe '$ClaudeExe' does not exist." }
        $claude = [System.IO.Path]::GetFullPath($ClaudeExe)
    }
    else {
        $claude = Find-ClaudeCode
    }
    if (-not $claude) { throw 'Claude Code CLI (claude.exe) not found. Pass -ClaudeExe, or install Claude Code first.' }

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
  Where Claude Code will find Git Bash, or $null -- its documented lookup, in its order
  (https://code.claude.com/docs/en/troubleshoot-install):

    1. CLAUDE_CODE_GIT_BASH_PATH, when it names an existing file called bash.exe, sh.exe, bash
       or sh. Any other value is ignored, as Claude Code ignores it.
    2. The default install locations, C:\Program Files\Git and C:\Program Files (x86)\Git.
    3. The git on PATH, using the bin\bash.exe of that Git installation.

  Not found, Claude Code does not fail: its Bash tool falls back to the PowerShell tool.

  The inputs are parameters so the lookup can be tested without the host's own Git.
  -Variable takes the variable's values in precedence order; -PathDir the PATH folders.
#>
function Find-GitBash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string[]]$Variable = @(),
        [string[]]$InstallRoot = @(
            $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git' }),
            $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Git' })
        ),
        [string[]]$PathDir = @()
    )

    foreach ($v in $Variable) {
        if ($v -and (Split-Path $v -Leaf) -in 'bash.exe', 'sh.exe', 'bash', 'sh' -and (Test-Path -LiteralPath $v -PathType Leaf)) {
            return $v
        }
    }
    foreach ($root in $InstallRoot | Where-Object { $_ }) {
        $bash = Join-Path $root 'bin\bash.exe'
        if (Test-Path -LiteralPath $bash -PathType Leaf) { return $bash }
    }
    # git.exe sits in Git\cmd, Git\bin or Git\mingw64\bin: the installation is the nearest
    # folder above it that has bin\bash.exe.
    foreach ($dir in $PathDir | Where-Object { $_ }) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'git.exe') -PathType Leaf)) { continue }
        $up = $dir
        for ($i = 0; $i -lt 3 -and $up; $i++) {
            $bash = Join-Path $up 'bin\bash.exe'
            if (Test-Path -LiteralPath $bash -PathType Leaf) { return $bash }
            $up = Split-Path $up -Parent
        }
    }
    $null
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

    # Claude Code's Bash tool runs Git Bash. A check that only asked whether bash.exe is on PATH
    # warned on hosts where it plainly works -- Git for Windows puts Git\cmd on PATH, not
    # Git\bin, and Claude Code does not need either -- and told the operator to edit PATH. So
    # this asks Claude Code's own question (Find-GitBash), with what a task-launched session
    # will see: settings.json's env, the environment from the registry and this process, and
    # PATH from both.
    if ($s.defaultShell -eq 'bash') {
        $machineEnv = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        $var = 'CLAUDE_CODE_GIT_BASH_PATH'
        $variable = @(
            $(if ($s.env) { $s.env.$var }),
            [Environment]::GetEnvironmentVariable($var),
            (Get-ItemProperty 'HKCU:\Environment' -Name $var -ErrorAction SilentlyContinue).$var,
            (Get-ItemProperty $machineEnv -Name $var -ErrorAction SilentlyContinue).$var
        ) | Where-Object { $_ }
        $machinePath = (Get-ItemProperty $machineEnv -Name Path -ErrorAction SilentlyContinue).Path
        $userPath    = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
        $pathDirs = @(([Environment]::ExpandEnvironmentVariables("$machinePath;$userPath") + ";$env:Path") -split ';' |
                      Where-Object { $_ })

        $bash = Find-GitBash -Variable $variable -PathDir $pathDirs
        if ($bash) {
            Write-Verbose "shell: bash -> $bash"
        }
        else {
            Write-Warning ('defaultShell is "bash", but Claude Code will find no Git Bash, so its Bash tool falls back to ' +
                           'PowerShell: CLAUDE_CODE_GIT_BASH_PATH names no bash.exe that exists, Git for Windows is not ' +
                           'under Program Files, and no git on PATH has a bin\bash.exe beside it. Install Git for Windows, ' +
                           'or set CLAUDE_CODE_GIT_BASH_PATH in the env block of ~\.claude\settings.json.')
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

<#
  The shell greenroom runs in: the watchdog, the session, and the elevated relaunch.
  pwsh 7 is PREFERRED -- WinGet's version-independent alias first, then the real install
  path, then anything on PATH. Windows PowerShell 5.1 ships in-box on every Windows host
  and is the last resort, so a machine with no pwsh 7 still works. greenroom's code runs
  on both editions, and this is the same ladder the watchdog .vbs walks at logon.
#>
function Resolve-GreenroomShell {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $shell = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Get-Command pwsh.exe -ErrorAction SilentlyContinue | ForEach-Object Source),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $shell) { throw 'no PowerShell found: neither pwsh.exe nor Windows PowerShell 5.1 (powershell.exe).' }
    $shell
}
