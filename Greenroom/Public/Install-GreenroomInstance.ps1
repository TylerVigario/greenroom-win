# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Provision a greenroom instance: config, trust, scheduled task, and start it.

.DESCRIPTION

  It provisions an INSTANCE. It does not install the software -- that already happened,
  or you could not be calling this. The script it replaces did both: it copied its own
  scripts into a bin directory and generated a cmd shim, which is what a package
  manager is for. That is roughly 130 lines that no longer exist, along with
  -InstallDir and the PATH warning that went with them.

  Idempotent, and that is load-bearing rather than a nicety: omitting a parameter
  INHERITS what the previous install recorded rather than falling back to a default.
  Every one of those rules is a bug that happened -- see Resolve-InstallParameter.
  Passing a parameter is authoritative; clearing is explicit
  (-AdditionalDirectories @(), -ClaudeExe '').

  Order is deliberate. Everything that can refuse does so BEFORE anything is written:
  the name is validated, elevation is checked against the current token, prerequisites
  are resolved and the CLI is proved to support --remote-control. Failing at
  Register-ScheduledTask instead would leave an instance half-built.

.PARAMETER Name
  1-32 characters, letters/digits/dot/dash/underscore, starting alphanumeric and not
  ending in a dot. No spaces: it goes on a command line, is matched back out of one, and
  becomes part of a scheduled-task name. No trailing dot: Windows drops it from a path,
  so 'probe.' would read and write probe's state.

.PARAMETER WorkingDirectory
  Where the session runs. Omitted, it inherits from the previous install; on a first
  install it defaults to ~/<name>. Never a home directory -- Remote Control will not
  connect from one.

.PARAMETER AdditionalDirectories
  Directory grants for THIS instance, passed as --add-dir. Default none: an instance
  boots with its working directory and nothing else.

.PARAMETER Elevated
  Run the session with a full admin token (task RunLevel Highest). Off by default
  because it CHANGES HOW THE INSTANCE IS OPERATED: an elevated session cannot be shown
  or hidden from an unelevated shell, since UIPI blocks the window calls silently.
  Requires an elevated caller. -Elevated:$false revokes.

.PARAMETER Model
  The model this instance launches with, passed to the CLI as --model. An alias such as
  `opus` tracks the newest of that family; a pinned id does not. Omitted, it inherits;
  -Model '' returns the instance to whatever the CLI would choose on its own.

  Passed on the LAUNCH LINE because an instance resumes its conversation, and a resumed
  session keeps the model it was saved with -- so an always-on instance otherwise stays
  on whatever it last ran, indefinitely, and a settings-file default will not move it.

  Validated by running the CLI when passed explicitly, because a bad value exits 1 inside
  a hidden window and crash-loops the instance. That probe is a real request, and it runs
  under -WhatIf too -- deliberately, so -WhatIf cannot report an install that would then
  fail. It writes nothing: it runs from a throwaway directory that is removed with the
  transcript it produces.

.PARAMETER TriggerDelay
  ISO-8601 logon delay, default PT1M. Stagger it across instances on one host.

.PARAMETER NoTrustSeed
  Skip seeding Claude Code's trust. Expect a modal dialog in a hidden window.

.PARAMETER NoStart
  Register everything but do not start the session.

.OUTPUTS
  Greenroom.Instance for the started session, or Greenroom.InstallResult with -NoStart.

.EXAMPLE
  Install-GreenroomInstance -Name desktop-admin

.EXAMPLE
  Install-GreenroomInstance -Name render-admin -WorkingDirectory D:\render-admin -TriggerDelay PT2M

.EXAMPLE
  Install-GreenroomInstance -Name desktop-admin -Elevated:$false
  Revokes elevation. Takes effect when the instance next restarts.

.EXAMPLE
  Install-GreenroomInstance -Name laptop-admin -Model opus
  Restart-GreenroomSession laptop-admin
  Sets the model and makes it take effect. Everything else about the instance is inherited.
#>
function Install-GreenroomInstance {
    [CmdletBinding(SupportsShouldProcess)]
    # Both, because -NoStart returns a different shape: there is no session to describe,
    # so it reports what was provisioned instead. Declaring only one misleads anything
    # reading OutputType metadata, including Get-Command -Syntax and editor tooling.
    [OutputType('Greenroom.Instance', 'Greenroom.InstallResult')]
    param(
        # ValueFromPipeline as well as ByPropertyName, so a bare name works and not only
        # a Greenroom.Instance. Piping into an install is safe precisely because a bare
        # re-run inherits: `Get-GreenroomInstance | Install-GreenroomInstance` re-registers
        # every instance without changing any of their settings.
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,30}[A-Za-z0-9_-])?$')]
        [string]$Name,

        [string]$WorkingDirectory,
        [string]$ClaudeExe,
        [string]$Model,
        [string]$TriggerDelay,
        [string[]]$AdditionalDirectories,
        [switch]$Elevated,
        [switch]$NoTrustSeed,
        [switch]$NoStart,

        [ValidateRange(10, 300)]
        [int]$TimeoutSeconds = 60
    )

    process {
        # Resolved from what the previous install recorded, before anything is touched.
        $s = Resolve-InstallParameter -Name $Name -Bound $PSBoundParameters `
                 -WorkingDirectory $WorkingDirectory -ClaudeExe $ClaudeExe `
                 -TriggerDelay $TriggerDelay -AdditionalDirectories $AdditionalDirectories `
                 -Elevated $Elevated.IsPresent -Model $Model

        # MEASURED: registering RunLevel Highest from a non-elevated shell fails with
        # 'Access is denied'. Checked here rather than at registration, which is the last
        # step -- failing there leaves files written, trust seeded and no task to run any
        # of it.
        if ($s.Elevated -and -not (Test-SelfElevated)) {
            throw ("-Elevated requires an elevated caller. Registering a scheduled task with RunLevel " +
                   'Highest fails with Access Denied otherwise, verified on the reference host. ' +
                   'Nothing has been changed.')
        }

        $pre = Resolve-GreenroomPrerequisite -ClaudeExe $s.ClaudeExe
        Test-GreenroomHostSetting

        # Only for a model passed on THIS run. The probe costs an API call, and a value
        # that is merely inherited was already proved when it was set -- re-proving it on
        # every bare re-run would tax the idempotence the rest of this command depends on.
        # Before ShouldProcess and before anything is written, like every other refusal.
        if ($PSBoundParameters.ContainsKey('Model') -and $Model) {
            Assert-ClaudeModel -ClaudeExe $pre.ClaudeExe -Model $Model
        }

        if (-not $PSCmdlet.ShouldProcess($Name, 'Install-GreenroomInstance')) { return }

        foreach ($d in @($s.StateDir, $s.WorkingDirectory)) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }

        [PSCustomObject]@{
            instance              = $s.Instance
            claudeExe             = $pre.ClaudeExe
            # True when chosen on this run OR inherited from a previous choice. It
            # records a flag ABOUT the value, so it has to be carried forward too.
            claudeExeExplicit     = $s.ClaudeExeExplicit
            workingDirectory      = $s.WorkingDirectory
            triggerDelay          = $s.TriggerDelay
            additionalDirectories = $s.AdditionalDirectories
            # Read to decide whether this shell can act on the window AT ALL, so it is
            # recorded rather than re-derived from the task: it has to be known BEFORE
            # something tries and silently fails.
            elevated              = $s.Elevated
            # Empty means "whatever the CLI picks". Recorded either way so the launcher
            # never has to distinguish absent from cleared.
            model                 = $s.Model
            wt                    = $pre.WindowsTerminal
            # The shell the session runs under: pwsh 7 when present, else Windows PowerShell 5.1.
            shell                 = $pre.Shell
            installedUtc          = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -Path (Join-Path $s.StateDir 'config.json') -Encoding UTF8

        Set-ProjectGrant -Directory $s.WorkingDirectory -Grants $s.AdditionalDirectories

        if ($NoTrustSeed) { Write-Warning 'trust seed skipped -- expect a modal dialog inside the hidden window' }
        else { Set-ProjectTrust -Directory $s.WorkingDirectory -BackupDir $s.StateDir | Out-Null }

        Register-GreenroomTask -Name $s.Instance -WorkingDirectory $s.WorkingDirectory `
            -TriggerDelay $s.TriggerDelay -WScriptPath $pre.WScript -Elevated $s.Elevated

        # The one announcement of elevation, made whether it was asked for or kept from the
        # previous install -- see Resolve-InstallParameter.
        if ($s.Elevated) {
            $kept = if ($s.ElevatedKept) { ' (kept from its previous install)' } else { '' }
            Write-Warning ("'$($s.Instance)' runs ELEVATED$kept. Showing and hiding it now need an elevated shell too: " +
                           'UIPI blocks the window calls from a lower integrity level. Nothing on screen marks ' +
                           "the session as elevated -- Get-GreenroomInstance is how you tell. Revoke with " +
                           "Install-GreenroomInstance -Name $($s.Instance) -Elevated:`$false")
        }

        if ($NoStart) {
            return [PSCustomObject]@{
                PSTypeName       = 'Greenroom.InstallResult'
                Instance         = $s.Instance
                WorkingDirectory = $s.WorkingDirectory
                TaskName         = $s.TaskName
                Elevated         = $s.Elevated
                Started          = $false
            }
        }

        Start-ScheduledTask -TaskName $s.TaskName
        $up = Wait-GreenroomSession -Name $s.Instance -TimeoutSeconds $TimeoutSeconds

        # Verify the seed SURVIVED rather than assuming it did. Any other claude.exe on
        # the host can rewrite ~/.claude.json between the seed and the launch, and the
        # consequence is a modal dialog in a window nobody can see.
        if (-not $NoTrustSeed -and -not (Test-TrustSurvived -Directory $s.WorkingDirectory)) {
            Write-Warning 'trust seed did NOT survive -- something rewrote ~/.claude.json. Re-seeding.'
            Set-ProjectTrust -Directory $s.WorkingDirectory -BackupDir $s.StateDir | Out-Null

            if (Test-TrustSurvived -Directory $s.WorkingDirectory) {
                Write-Warning 'trust re-seeded; restarting the session so it picks the seed up.'
                # Trust is read at startup, so a session already sitting on the dialog
                # will not pick up the re-seed. Restart-GreenroomSession stops the
                # supervisor BY PROCESS first, which is the only thing that works here --
                # Stop-ScheduledTask is a no-op against this architecture.
                $up = Restart-GreenroomSession -Name $s.Instance -TimeoutSeconds $TimeoutSeconds
            }
            else {
                Write-Warning ('RE-SEED FAILED. Expect a modal trust dialog inside the hidden window: show ' +
                               'the session and accept it by hand, or close other claude.exe and install again.')
            }
        }

        if (-not $up) {
            Write-Error -Category OperationTimeout -Message (
                "'$($s.Instance)' did not come up within $TimeoutSeconds s. Check: Get-Content " +
                "`"$(Join-Path $s.StateDir 'watchdog.log')`" -Tail 20")
            return
        }

        return $up
    }
}

