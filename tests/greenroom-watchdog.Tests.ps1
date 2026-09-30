# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Which claude.exe the watchdog adopts as its instance's session. Only its own: one whose
  parent is greenroom's launcher for this instance. Adopting by name alone took over a
  Remote Control session started by hand, and the real session was then never started.

  The watchdog is a script with a supervision loop, not a module function, so the test
  lifts Get-RcClaudePid out of the script's syntax tree and runs that exact code against
  a faked process table. Nothing is started or stopped.
#>

BeforeAll {
    $assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Assets'
    . (Join-Path $assets 'Get-GreenroomSessionName.ps1')

    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $assets 'greenroom-watchdog.ps1'), [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RcClaudePid'
        }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))

    $script:Launcher = 'C:\Users\x\Documents\PowerShell\Modules\Greenroom\0.7.0\Assets\greenroom-launch.ps1'
    function Proc([int]$Id, [int]$Parent, [string]$Name, [string]$Cmd) {
        [PSCustomObject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CommandLine = $Cmd }
    }
    function UseProcesses([object[]]$Table) {
        $script:Table = $Table
        Mock Get-CimInstance {
            if ($Filter -eq "Name='claude.exe'") { return @($script:Table | Where-Object Name -eq 'claude.exe') }
            if ($Filter -match '^ProcessId=(\d+)$') { return @($script:Table | Where-Object ProcessId -eq ([int]$Matches[1])) }
        }
    }
}

Describe 'the watchdog adopts only its own instance''s session' {

    # Get-RcClaudePid reads the watchdog's -Instance parameter; here it is this.
    BeforeEach { $script:Instance = 'laptop-admin' }

    It 'adopts the session greenroom''s launcher started for this instance' {
        UseProcesses @(
            (Proc 50 1 'pwsh.exe' "pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:Launcher -Instance laptop-admin"),
            (Proc 100 50 'claude.exe' 'claude.exe --remote-control laptop-admin --name laptop-admin -c')
        )
        Get-RcClaudePid | Should -Be 100
    }

    It 'does not adopt <Why>' -ForEach @(
        @{ Why = 'a Remote Control session run by hand under the same name'
           Table = @( @{ Id = 60; Parent = 1; Name = 'pwsh.exe'; Cmd = 'pwsh.exe' },
                      @{ Id = 101; Parent = 60; Name = 'claude.exe'; Cmd = 'claude.exe --remote-control laptop-admin' } ) }
        @{ Why = 'another instance''s session'
           Table = @( @{ Id = 50; Parent = 1; Name = 'pwsh.exe'; Cmd = "pwsh.exe -File C:\m\Assets\greenroom-launch.ps1 -Instance laptop-admin-2" },
                      @{ Id = 102; Parent = 50; Name = 'claude.exe'; Cmd = 'claude.exe --remote-control laptop-admin-2' } ) }
        @{ Why = 'a session whose launcher was started for another instance'
           Table = @( @{ Id = 50; Parent = 1; Name = 'pwsh.exe'; Cmd = 'pwsh.exe -File C:\m\Assets\greenroom-launch.ps1 -Instance other' },
                      @{ Id = 103; Parent = 50; Name = 'claude.exe'; Cmd = 'claude.exe --remote-control laptop-admin' } ) }
        @{ Why = 'a session whose parent has already exited'
           Table = @( @{ Id = 104; Parent = 999; Name = 'claude.exe'; Cmd = 'claude.exe --remote-control laptop-admin' } ) }
    ) {
        UseProcesses @($Table | ForEach-Object { Proc $_.Id $_.Parent $_.Name $_.Cmd })
        Get-RcClaudePid | Should -BeNullOrEmpty
    }

    It 'adopts its own session, not a hand-started one listed before it under the same name' {
        UseProcesses @(
            (Proc 60 1 'pwsh.exe' 'pwsh.exe'),
            (Proc 101 60 'claude.exe' 'claude.exe --remote-control laptop-admin'),
            (Proc 50 1 'pwsh.exe' "pwsh.exe -File $script:Launcher -Instance laptop-admin"),
            (Proc 100 50 'claude.exe' 'claude.exe --remote-control laptop-admin')
        )
        Get-RcClaudePid | Should -Be 100
    }
}
