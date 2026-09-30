# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Install is the most dangerous command here, and almost all of that danger lives in
  Resolve-InstallParameter: installing is documented as idempotent, so a bare re-run
  that quietly changes something the operator never mentioned is a betrayal of that
  promise. Every rule below is a bug that actually happened on the reference host.

  These are pinned against a real config.json in a temp state root, because "does a
  bare re-run inherit what the last one wrote" is a question about a file.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    $script:StateRoot = Join-Path ([IO.Path]::GetTempPath()) "greenroom-install-$([guid]::NewGuid())"
    $script:WorkDir   = Join-Path $script:StateRoot 'work'
    New-Item -ItemType Directory -Path (Join-Path $script:StateRoot 'probe') -Force | Out-Null
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    function WritePrevConfig {
        param([hashtable]$Config)
        $Config | ConvertTo-Json | Set-Content (Join-Path $script:StateRoot 'probe\config.json')
    }

    # EVERYTHING INSTALL ACTS WITH, as a tripwire. These tests call the real
    # Install-GreenroomInstance and expect it to stop early -- at parameter validation, at
    # a refusal. If it ever does not, it must fail here, not go on to act on the machine
    # running the tests. MEASURED: with the name validation weakened, one of these tests
    # once ran a real install -- a scheduled task, a crash-looping watchdog and trust
    # entries in the real ~/.claude.json -- because nothing in it was mocked. A test that
    # needs a step to succeed mocks that step itself, which overrides the tripwire.
    function InstallTripwires {
        Mock -ModuleName Greenroom Get-GreenroomStateRoot { $script:StateRoot }
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        foreach ($c in 'Resolve-GreenroomPrerequisite', 'Assert-ClaudeModel', 'Set-ProjectTrust', 'Set-ProjectGrant',
                       'Test-TrustSurvived', 'Register-GreenroomTask', 'Start-ScheduledTask', 'Stop-ScheduledTask',
                       'Restart-GreenroomSession', 'Wait-GreenroomSession') {
            Mock -ModuleName Greenroom $c ([scriptblock]::Create("throw 'tripwire: $c must not be reached'"))
        }
    }

    # Resolve-InstallParameter is private; -Bound is what a caller's $PSBoundParameters
    # would hold, which is how "was it passed or omitted" is decided.
    function Resolve {
        param([hashtable]$Bound = @{}, [hashtable]$Extra = @{})
        InModuleScope Greenroom -Parameters @{ b = $Bound; a = $Extra } {
            param($b, $a)
            Resolve-InstallParameter -Name 'probe' -Bound $b @a
        }
    }
}

AfterAll {
    if (Test-Path $script:StateRoot) { Remove-Item $script:StateRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-InstallParameter' {

    BeforeEach {
        Mock -ModuleName Greenroom Get-GreenroomStateRoot { $script:StateRoot }
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        $cfg = Join-Path $script:StateRoot 'probe\config.json'
        if (Test-Path $cfg) { Remove-Item $cfg -Force }
    }

    Context 'a bare re-run inherits rather than resetting' {

        It 'keeps the working directory' {
            # THE WORST ONE. Falling back to ~/<instance> relocated the instance:
            # new directory, trust seeded for it, session restarted there, abandoning
            # the project store, memory and transcripts. Hit two instances at once.
            WritePrevConfig @{ workingDirectory = 'D:\real-work'; triggerDelay = 'PT3M' }
            (Resolve).WorkingDirectory | Should -Be 'D:\real-work'
        }

        It 'keeps the trigger delay' {
            # Resetting a deliberate PT3M to PT1M un-staggers a multi-instance host.
            WritePrevConfig @{ workingDirectory = 'D:\real-work'; triggerDelay = 'PT3M' }
            (Resolve).TriggerDelay | Should -Be 'PT3M'
        }

        It 'keeps directory grants' {
            # A bare re-run rebuilt the list empty and wrote that through to config, the
            # project settings AND the launch line, silently revoking access.
            WritePrevConfig @{ workingDirectory = $script:WorkDir; additionalDirectories = @($script:WorkDir) }
            (Resolve).AdditionalDirectories | Should -Be @($script:WorkDir)
        }

        It 'keeps elevation' {
            WritePrevConfig @{ workingDirectory = 'D:\real-work'; elevated = $true }
            (Resolve -Bound @{} ).Elevated | Should -BeTrue
        }

        It 'keeps an explicitly chosen claude.exe, and the fact that it was chosen' {
            # The flag has to carry forward too. Deriving it from bound parameters at
            # write time recorded false on the very run that inherited, so the choice
            # survived exactly one bare re-run.
            $exe = Join-Path $script:StateRoot 'fake-claude.exe'
            Set-Content $exe 'x'
            WritePrevConfig @{ workingDirectory = 'D:\w'; claudeExe = $exe; claudeExeExplicit = $true }
            $r = Resolve
            $r.ClaudeExe         | Should -Be $exe
            $r.ClaudeExeExplicit | Should -BeTrue
        }

        It 'does NOT pin an auto-detected claude.exe' {
            # config.json records the RESOLVED path. Inheriting it unconditionally would
            # freeze whatever auto-detection picked, so a re-run could never follow a
            # change in PATH -- which is what resolution is meant to track.
            WritePrevConfig @{ workingDirectory = 'D:\w'; claudeExe = 'C:\auto\claude.exe'; claudeExeExplicit = $false }
            $r = Resolve
            $r.ClaudeExe         | Should -BeNullOrEmpty
            $r.ClaudeExeExplicit | Should -BeFalse
        }
    }

    Context 'passing a parameter stays authoritative' {

        It 'a passed working directory overrides the remembered one' {
            WritePrevConfig @{ workingDirectory = 'D:\old' }
            (Resolve -Bound @{ WorkingDirectory = $true } -Extra @{ WorkingDirectory = 'D:\new' }).WorkingDirectory |
                Should -Be 'D:\new'
        }

        It 'an explicitly empty grant list clears grants' {
            # -AdditionalDirectories @() is how you actually revoke, as opposed to
            # omitting it, which inherits.
            WritePrevConfig @{ workingDirectory = 'D:\w'; additionalDirectories = @('C:\Windows') }
            $r = Resolve -Bound @{ AdditionalDirectories = $true } -Extra @{ AdditionalDirectories = @() }
            $r.AdditionalDirectories.Count | Should -Be 0
        }

        It 'defaults the working directory only on a first install' {
            (Resolve).WorkingDirectory | Should -Be (Join-Path $env:USERPROFILE 'probe')
        }
    }

    Context 'the working directory is stored as the launcher will land' {
        <#
          The launcher compares where it landed with the stored string and exits on any
          difference, and it always lands on a full Windows path. So anything else stored
          here crash-loops the hidden session on every start.
        #>

        It 'stores <Typed> as a full Windows path' -ForEach @(
            @{ Typed = 'C:/work/foo';  Want = 'C:\work\foo' }
            @{ Typed = 'C:/work/foo/'; Want = 'C:\work\foo' }
            @{ Typed = 'C:\work\foo\'; Want = 'C:\work\foo' }
            @{ Typed = 'D:/not-mounted/x'; Want = 'D:\not-mounted\x' }
        ) {
            (Resolve -Bound @{ WorkingDirectory = $true } -Extra @{ WorkingDirectory = $Typed }).WorkingDirectory |
                Should -Be $Want
        }

        It 'resolves ~ against the home directory' {
            (Resolve -Bound @{ WorkingDirectory = $true } -Extra @{ WorkingDirectory = '~/gr-probe' }).WorkingDirectory |
                Should -Be (Join-Path $env:USERPROFILE 'gr-probe')
        }

        It 'resolves a relative path against this shell, not the task folder' {
            Push-Location $script:WorkDir
            try {
                (Resolve -Bound @{ WorkingDirectory = $true } -Extra @{ WorkingDirectory = '.\sub' }).WorkingDirectory |
                    Should -Be (Join-Path $script:WorkDir 'sub')
            }
            finally { Pop-Location }
        }

        It 'leaves a working path exactly as it was, case and all' {
            # Claude Code files memory under the literal string; changing it orphans it.
            WritePrevConfig @{ workingDirectory = 'C:\Users\X\Desktop-Admin' }
            (Resolve).WorkingDirectory | Should -BeExactly 'C:\Users\X\Desktop-Admin'
        }

        It 'refuses the home directory, <Typed>' -ForEach @(
            @{ Typed = '~' }, @{ Typed = '~/' }, @{ Typed = 'HOME' }
        ) {
            $wd = if ($Typed -eq 'HOME') { $env:USERPROFILE } else { $Typed }
            { Resolve -Bound @{ WorkingDirectory = $true } -Extra @{ WorkingDirectory = $wd } } |
                Should -Throw '*is the home directory*'
        }
    }

    Context 'refusals' {

        It 'refuses when the previous config exists but will not parse and anything was omitted' {
            # Swallowing the difference between "no config" and "unreadable config"
            # reopens the relocation bug through another door.
            Set-Content (Join-Path $script:StateRoot 'probe\config.json') '{ not json'
            { Resolve } | Should -Throw '*cannot be parsed*'
        }

        It 'allows an unreadable config when every value is passed explicitly' {
            Set-Content (Join-Path $script:StateRoot 'probe\config.json') '{ not json'
            { Resolve -Bound @{ WorkingDirectory = $true; TriggerDelay = $true; AdditionalDirectories = $true; Elevated = $true } `
                      -Extra @{ WorkingDirectory = 'D:\w'; TriggerDelay = 'PT1M'; AdditionalDirectories = @(); Elevated = $true } } |
                Should -Not -Throw
        }

        It 'refuses an unreadable config when only -Elevated was omitted' {
            # The others fall back to a default that relocates the instance. This one
            # falls back to NOT ELEVATED, silently demoting a session that was
            # deliberately given a full admin token -- and elevation announces itself on
            # every ordinary re-run precisely because it is security-relevant.
            Set-Content (Join-Path $script:StateRoot 'probe\config.json') '{ not json'
            { Resolve -Bound @{ WorkingDirectory = $true; TriggerDelay = $true; AdditionalDirectories = $true } `
                      -Extra @{ WorkingDirectory = 'D:\w'; TriggerDelay = 'PT1M'; AdditionalDirectories = @() } } |
                Should -Throw '*-Elevated*'
        }

        It 'refuses a chosen claude.exe that does not exist' {
            # It used to drop out of the candidate list silently, and then the
            # AUTO-DETECTED path got recorded as though it were the deliberate choice.
            { Resolve -Bound @{ ClaudeExe = $true } -Extra @{ ClaudeExe = 'C:\nope\claude.exe' } } |
                Should -Throw '*does not exist*'
        }

        It 'refuses a grant on a path that is not there' {
            { Resolve -Bound @{ AdditionalDirectories = $true } -Extra @{ AdditionalDirectories = @('C:\nope-not-here') } } |
                Should -Throw '*does not exist*'
        }
    }
}

Describe 'Install-GreenroomInstance' {

    BeforeEach { InstallTripwires }

    It 'rejects an invalid instance name before doing anything: <Name>' -ForEach @(
        # The name goes on a command line, is matched back out of one, and becomes part
        # of a task name, so spaces and oddities are refused at the parameter. Windows
        # drops a trailing dot from a path, so 'probe.' would read and write probe's state.
        @{ Name = 'has space' }, @{ Name = '-startsdash' }, @{ Name = 'probe.' }
    ) {
        # The parameter's own error, specifically: a tripwire's throw would satisfy a bare
        # Should -Throw, and hide exactly the regression this is for.
        { Install-GreenroomInstance -Name $Name -ErrorAction Stop } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
        Should -Invoke -ModuleName Greenroom Resolve-GreenroomPrerequisite -Times 0
        Should -Invoke -ModuleName Greenroom Register-GreenroomTask -Times 0
    }

    It 'names instances by the same rule Uninstall- enforces' {
        # The name becomes a directory Uninstall- deletes recursively; a name one command
        # accepts and the other refuses is an instance that cannot be removed, or worse.
        $pattern = { param($cmd) ((Get-Command $cmd).Parameters['Name'].Attributes |
            Where-Object { $_ -is [ValidatePattern] }).RegexPattern }
        & $pattern Install-GreenroomInstance | Should -Be (& $pattern Uninstall-GreenroomInstance)
    }

    It 'accepts <Name>' -ForEach @(
        @{ Name = 'a' }, @{ Name = 'a.b' }, @{ Name = 'a-' }, @{ Name = 'a_' }, @{ Name = 'v1.2' },
        @{ Name = 'x' * 32 }
    ) {
        $rx = ((Get-Command Install-GreenroomInstance).Parameters['Name'].Attributes |
            Where-Object { $_ -is [ValidatePattern] }).RegexPattern
        $Name | Should -Match $rx
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'probe.' }, @{ Name = 'a..' }, @{ Name = '.a' }, @{ Name = '-a' }, @{ Name = 'x' * 33 },
        @{ Name = 'has space' }, @{ Name = '..' }, @{ Name = '*' }
    ) {
        $rx = ((Get-Command Install-GreenroomInstance).Parameters['Name'].Attributes |
            Where-Object { $_ -is [ValidatePattern] }).RegexPattern
        $Name | Should -Not -Match $rx
    }

    It 'supports ShouldProcess' {
        (Get-Command Install-GreenroomInstance).Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'has no InstallDir parameter' {
        # It provisions an INSTANCE. Installing the software is Install-PSResource.
        (Get-Command Install-GreenroomInstance).Parameters.Keys | Should -Not -Contain 'InstallDir'
    }

    It 'refuses -Elevated from a non-elevated caller, before writing anything' {
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        Mock -ModuleName Greenroom Resolve-GreenroomPrerequisite { throw 'must not get this far' }
        Mock -ModuleName Greenroom Register-GreenroomTask { throw 'must not get this far' }
        { Install-GreenroomInstance -Name probe -Elevated -ErrorAction Stop } | Should -Throw '*elevated caller*'
        Should -Invoke -ModuleName Greenroom Register-GreenroomTask -Times 0
    }
}

Describe 'Model' {

    BeforeEach {
        InstallTripwires
        Mock -ModuleName Greenroom Get-GreenroomStateRoot { $script:StateRoot }
        # Get-ScheduledTask too: a previous config without triggerDelay makes
        # Resolve-InstallParameter fall back to reading the registered task, so without
        # this the result depends on whether the host happens to have a greenroom-probe
        # task -- and it pays a real scheduled-task query per test.
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        Remove-Item (Join-Path $script:StateRoot 'probe\config.json') -ErrorAction SilentlyContinue
    }

    It 'inherits the model a previous install recorded' {
        WritePrevConfig @{ workingDirectory = $script:WorkDir; model = 'opus' }
        (Resolve).Model | Should -Be 'opus'
    }

    It 'takes an explicitly passed model over the recorded one' {
        WritePrevConfig @{ workingDirectory = $script:WorkDir; model = 'opus' }
        (Resolve -Bound @{ Model = 'sonnet' } -Extra @{ Model = 'sonnet' }).Model | Should -Be 'sonnet'
    }

    It "clears with -Model '', rather than treating empty as omitted" {
        # The -ClaudeExe '' precedent: clearing has to be sayable, or a deliberate choice
        # can be set but never unset.
        WritePrevConfig @{ workingDirectory = $script:WorkDir; model = 'opus' }
        (Resolve -Bound @{ Model = '' } -Extra @{ Model = '' }).Model | Should -BeNullOrEmpty
    }

    It 'is empty when no install ever set one' {
        WritePrevConfig @{ workingDirectory = $script:WorkDir }
        (Resolve).Model | Should -BeNullOrEmpty
    }

    Context 'validation' {

        It 'refuses a model the CLI rejects, before writing anything' {
            # A bad model exits 1 inside a hidden window and crash-loops the instance, so
            # it is caught the same way a CLI without --remote-control is: by running it.
            #
            # Resolve-GreenroomPrerequisite is mocked because it runs FIRST and throws
            # "claude.exe not found" on any host without the CLI -- which is every CI
            # runner. Without this the test passes only on a developer machine and fails
            # in CI for a reason that has nothing to do with what it is testing.
            Mock -ModuleName Greenroom Resolve-GreenroomPrerequisite {
                [PSCustomObject]@{
                    WindowsTerminal = 'C:\fake\wt.exe'
                    Shell           = 'C:\fake\pwsh.exe'
                    WScript         = 'C:\fake\wscript.exe'
                    ClaudeExe       = 'C:\fake\claude.exe'
                    ClaudeVersion   = '0.0.0 (Claude Code)'
                }
            }
            Mock -ModuleName Greenroom Assert-ClaudeModel { throw "-Model 'bogus' was rejected by the CLI" }
            Mock -ModuleName Greenroom Register-GreenroomTask { throw 'must not get this far' }
            { Install-GreenroomInstance -Name probe -Model bogus -ErrorAction Stop } | Should -Throw '*rejected by the CLI*'
            Should -Invoke -ModuleName Greenroom Register-GreenroomTask -Times 0
        }

        It 'does not re-probe a model that was merely inherited' {
            # The probe costs an API call. Paying it on every bare re-run would tax the
            # idempotence the rest of Install- depends on.
            WritePrevConfig @{ workingDirectory = $script:WorkDir; model = 'opus' }
            Mock -ModuleName Greenroom Assert-ClaudeModel { }
            Mock -ModuleName Greenroom Resolve-GreenroomPrerequisite { throw 'stop here' }
            { Install-GreenroomInstance -Name probe -ErrorAction Stop } | Should -Throw
            Should -Invoke -ModuleName Greenroom Assert-ClaudeModel -Times 0
        }
    }
}

Describe 'Resolve-GreenroomShell' {
    # The shell greenroom starts things in -- the watchdog, the session, the elevated
    # relaunch. pwsh 7 where there is one; Windows PowerShell 5.1, which every Windows host
    # has, where there is not.

    It 'prefers pwsh 7 when it is installed' {
        Mock -ModuleName Greenroom Test-Path { $true }
        InModuleScope Greenroom { Resolve-GreenroomShell } | Should -BeLike '*\pwsh.exe'
    }

    It 'falls back to Windows PowerShell 5.1 when there is no pwsh 7' {
        Mock -ModuleName Greenroom Test-Path { $Path -like '*\WindowsPowerShell\v1.0\powershell.exe' }
        Mock -ModuleName Greenroom Get-Command { $null } -ParameterFilter { $Name -eq 'pwsh.exe' }
        InModuleScope Greenroom { Resolve-GreenroomShell } | Should -Be (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
}

Describe 'Resolve-GreenroomPrerequisite with an explicit -ClaudeExe' {
    <#
      An explicit -ClaudeExe is that path or nothing. As one candidate among the others, a
      path the filters reject -- Claude Desktop's bundled claude.exe -- dropped out, the CLI
      on PATH was used instead, and install recorded THAT as the explicit choice.

      Hermetic: Test-Path and Get-Command are mocked, and every case must stop before any
      claude.exe is run.
    #>
    BeforeEach {
        Mock -ModuleName Greenroom Test-Path { $true }
        Mock -ModuleName Greenroom Get-Command { [PSCustomObject]@{ Source = "C:\Users\x\.local\bin\$Name" } }
    }

    It 'refuses Claude Desktop''s claude.exe rather than quietly using another: <Exe>' -ForEach @(
        @{ Exe = 'C:\Program Files\WindowsApps\Claude_1.0.0.0_x64__abc\app\claude.exe' }
        @{ Exe = 'C:\Users\x\AppData\Local\AnthropicClaude\app-1.0.0\claude.exe' }
        @{ Exe = 'C:\Users\x\AppData\Roaming\Claude\claude-code\2.1.0\claude.exe' }
    ) {
        { InModuleScope Greenroom -Parameters @{ e = $Exe } { param($e) Resolve-GreenroomPrerequisite -ClaudeExe $e } } |
            Should -Throw "*is Claude Desktop's bundled claude.exe*"
    }

    It 'refuses a missing explicit path rather than falling back' {
        Mock -ModuleName Greenroom Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'C:\nope\claude.exe' }
        { InModuleScope Greenroom { Resolve-GreenroomPrerequisite -ClaudeExe 'C:\nope\claude.exe' } } |
            Should -Throw "*-ClaudeExe 'C:\nope\claude.exe' does not exist*"
    }
}
