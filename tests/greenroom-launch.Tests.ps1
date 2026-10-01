# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  What the launcher does when the claude.exe install recorded is missing, or is not a program.

  The real launcher runs as a child process with USERPROFILE pointed at this test's drive and a
  PATH holding only a stand-in claude.exe -- a copy of where.exe, which exits at once on the
  launcher's arguments -- so nothing it finds can be Claude Code. Before each launch the same
  search is run under the child's environment, and the test refuses to start the child if it
  would reach anything outside this test's drive.
#>

BeforeAll {
    $script:Launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Assets\greenroom-launch.ps1'
    $script:Finder = Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Assets\Find-ClaudeCode.ps1'
    $script:Shell = (Get-Process -Id $PID).Path
    $script:Name = 'gr-launch-test'

    # A stand-in claude.exe, and a file named claude.exe that is not a program.
    $script:Bin = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'bin') -Force
    $script:Fake = Join-Path $script:Bin 'claude.exe'
    Copy-Item (Join-Path $env:SystemRoot 'System32\where.exe') $script:Fake
    $script:NotAProgram = Join-Path $TestDrive 'not-a-program\claude.exe'
    New-Item -ItemType Directory -Path (Split-Path $script:NotAProgram) -Force | Out-Null
    Set-Content -LiteralPath $script:NotAProgram -Value 'not a program'

    function Launch([hashtable]$Config, [string]$Path) {
        $home_ = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $state = New-Item -ItemType Directory -Path (Join-Path $home_ ".claude\greenroom\$script:Name") -Force
        $work = New-Item -ItemType Directory -Path (Join-Path $home_ 'work') -Force
        ($Config + @{ workingDirectory = $work.FullName }) | ConvertTo-Json | Set-Content (Join-Path $state 'config.json')

        $saved = $env:USERPROFILE, $env:Path
        try {
            $env:USERPROFILE = $home_
            $env:Path = $Path
            # The guard: whatever the launcher's search could find must be inside this test.
            $reach = & $script:Shell -NoProfile -NonInteractive -Command ". '$script:Finder'; Find-ClaudeCode"
            if ($reach -and -not "$reach".StartsWith($TestDrive, [StringComparison]::OrdinalIgnoreCase)) {
                throw "refusing to launch: the search reaches '$reach', outside this test"
            }
            $null = & $script:Shell -NoProfile -NonInteractive -File $script:Launcher -Instance $script:Name 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $env:USERPROFILE, $env:Path = $saved
        }
        [PSCustomObject]@{ Code = $code; Log = (Get-Content (Join-Path $state 'launch.log') -Raw) }
    }
    $script:OnlyFake = "$script:Bin;$env:SystemRoot\System32"
    $script:NoClaude = "$env:SystemRoot\System32"
    $script:Gone = Join-Path $TestDrive 'uninstalled\claude.exe'
}

Describe 'the launcher, when the recorded claude.exe is gone' {

    It 'finds Claude Code again when the path was detected, runs it, and says so' {
        $r = Launch @{ claudeExe = $script:Gone; claudeExeExplicit = $false } $script:OnlyFake
        $r.Log | Should -Match ([regex]::Escape("WARN: claude.exe '$script:Gone', found at install, no longer exists -- running '$script:Fake' instead."))
        $r.Log | Should -Match ([regex]::Escape("Re-run Install-GreenroomInstance -Name $script:Name"))
        $r.Log | Should -Match ([regex]::Escape("exec: $script:Fake --remote-control $script:Name"))
        $r.Log | Should -Match 'claude exited with 1'          # where.exe's own exit code: it ran
    }

    It 'stops with a FATAL, and runs nothing, when the path was chosen explicitly' {
        $r = Launch @{ claudeExe = $script:Gone; claudeExeExplicit = $true } $script:OnlyFake
        $r.Code | Should -Be 1
        $r.Log | Should -Match ([regex]::Escape("FATAL: claude.exe '$script:Gone', chosen with -ClaudeExe at install, does not exist."))
        $r.Log | Should -Match ([regex]::Escape("-ClaudeExe '' to find it automatically"))
        $r.Log | Should -Not -Match 'exec:'
    }

    It 'stops with a FATAL when Claude Code cannot be found anywhere' {
        $r = Launch @{ claudeExe = $script:Gone; claudeExeExplicit = $false } $script:NoClaude
        $r.Code | Should -Be 1
        $r.Log | Should -Match 'FATAL: .*no longer exists, and Claude Code is not on PATH or in ~\\\.local\\bin\.'
        $r.Log | Should -Not -Match 'exec:'
    }
}

Describe 'the launcher, running claude.exe' {

    It 'runs the recorded path when it is there, without a warning' {
        $r = Launch @{ claudeExe = $script:Fake; claudeExeExplicit = $false } $script:NoClaude
        $r.Log | Should -Not -Match 'WARN|FATAL'
        $r.Log | Should -Match ([regex]::Escape("exec: $script:Fake"))
        $r.Log | Should -Match 'claude exited with 1'
    }

    It 'logs a FATAL, not an exit code, when the path is not a program' {
        $r = Launch @{ claudeExe = $script:NotAProgram; claudeExeExplicit = $true } $script:NoClaude
        $r.Code | Should -Be 1
        $r.Log | Should -Match ([regex]::Escape("FATAL: could not run '$script:NotAProgram'"))
        $r.Log | Should -Not -Match 'claude exited with'
    }
}
