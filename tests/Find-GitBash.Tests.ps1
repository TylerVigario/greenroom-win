# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Where Claude Code will find Git Bash -- its documented lookup -- and the host-setting warning
  built on it, which used to fire whenever bash.exe was not on PATH, including on hosts where
  Claude Code's Bash tool plainly works.

  Every input is given explicitly and lives on this test's drive; the host's own Git is never
  consulted.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    function NewFile([string]$Path) {
        New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
        Set-Content -LiteralPath $Path -Value 'x'
        $Path
    }
    # A Git for Windows layout: cmd\git.exe, mingw64\bin\git.exe, bin\bash.exe.
    function NewGit([string]$Root) {
        NewFile (Join-Path $Root 'cmd\git.exe') | Out-Null
        NewFile (Join-Path $Root 'mingw64\bin\git.exe') | Out-Null
        NewFile (Join-Path $Root 'bin\bash.exe')
    }
    function Find([hashtable]$With) {
        $a = @{ Variable = @(); InstallRoot = @(); PathDir = @() }
        foreach ($k in $With.Keys) { $a[$k] = $With[$k] }
        InModuleScope Greenroom -Parameters @{ a = $a } { param($a) Find-GitBash @a }
    }
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Find-GitBash' {

    BeforeEach { $script:T = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName }

    It 'takes CLAUDE_CODE_GIT_BASH_PATH first, when it names a bash.exe that exists' {
        $mine = NewFile (Join-Path $T 'mine\bash.exe')
        $default = NewGit (Join-Path $T 'PF\Git')
        Find @{ Variable = @($mine); InstallRoot = @((Split-Path (Split-Path $default))) } | Should -Be $mine
    }

    It 'ignores the variable when it names <Why>, as Claude Code does' -ForEach @(
        @{ Why = 'a file of another name'; Leaf = 'git-bash.exe'; Create = $true }
        @{ Why = 'a file that does not exist'; Leaf = 'bash.exe'; Create = $false }
    ) {
        $v = Join-Path $T "v\$Leaf"
        if ($Create) { NewFile $v | Out-Null }
        $default = NewGit (Join-Path $T 'PF\Git')
        Find @{ Variable = @($v); InstallRoot = @((Split-Path (Split-Path $default))) } | Should -Be $default
    }

    It 'finds the default install location' {
        $default = NewGit (Join-Path $T 'PF\Git')
        Find @{ InstallRoot = @((Join-Path $T 'nothing-here\Git'), (Split-Path (Split-Path $default))) } | Should -Be $default
    }

    It 'finds the installation of the git on PATH, from <Dir>' -ForEach @(@{ Dir = 'cmd' }, @{ Dir = 'mingw64\bin' }) {
        $bash = NewGit (Join-Path $T 'D\tools\Git')
        Find @{ PathDir = @((Join-Path $T 'elsewhere'), (Join-Path $T "D\tools\Git\$Dir")) } | Should -Be $bash
    }

    It 'finds nothing when there is no Git Bash anywhere it looks' {
        NewFile (Join-Path $T 'bin\bash.exe') | Out-Null          # a bash with no git beside it on PATH
        Find @{ Variable = @((Join-Path $T 'nope\bash.exe')); InstallRoot = @((Join-Path $T 'PF\Git'))
                PathDir = @((Join-Path $T 'bin')) } | Should -BeNullOrEmpty
    }
}

Describe 'the host-setting warning for a bash defaultShell' {

    BeforeEach {
        $script:Home_ = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
        New-Item -ItemType Directory -Path (Join-Path $Home_ '.claude') | Out-Null
        @{ defaultShell = 'bash' } | ConvertTo-Json | Set-Content (Join-Path $Home_ '.claude\settings.json')
        $script:Saved = $env:USERPROFILE
        $env:USERPROFILE = $Home_
    }
    AfterEach { $env:USERPROFILE = $script:Saved }

    It 'says nothing when Claude Code will find Git Bash' {
        Mock -ModuleName Greenroom Find-GitBash { 'C:\Program Files\Git\bin\bash.exe' }
        InModuleScope Greenroom { Test-GreenroomHostSetting -WarningVariable w -WarningAction SilentlyContinue; $w } |
            Should -BeNullOrEmpty
    }

    It 'warns, and says the Bash tool falls back to PowerShell, when it will not' {
        Mock -ModuleName Greenroom Find-GitBash { $null }
        $w = InModuleScope Greenroom { Test-GreenroomHostSetting -WarningVariable w -WarningAction SilentlyContinue; $w }
        "$w" | Should -Match 'Claude Code will find no Git Bash, so its Bash tool falls back to PowerShell'
        "$w" | Should -Not -Match 'USER PATH'
    }

    It 'passes the settings file''s CLAUDE_CODE_GIT_BASH_PATH to the lookup first' {
        @{ defaultShell = 'bash'; env = @{ CLAUDE_CODE_GIT_BASH_PATH = 'D:\portable\bin\bash.exe' } } |
            ConvertTo-Json | Set-Content (Join-Path $Home_ '.claude\settings.json')
        Mock -ModuleName Greenroom Find-GitBash { 'x' }
        InModuleScope Greenroom { Test-GreenroomHostSetting -WarningAction SilentlyContinue }
        Should -Invoke -ModuleName Greenroom Find-GitBash -Times 1 -Exactly -ParameterFilter { $Variable[0] -eq 'D:\portable\bin\bash.exe' }
    }
}
