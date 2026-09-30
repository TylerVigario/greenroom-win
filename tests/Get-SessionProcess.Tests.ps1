# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Which claude.exe greenroom treats as its sessions. Only the ones it started: a claude.exe
  whose parent is greenroom's launcher for the same instance. The name alone listed Remote
  Control sessions greenroom never started.

  Processes are faked: Get-CimInstance returns a table, looked up by name or by pid.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    $script:Launcher = 'C:\Users\x\Documents\PowerShell\Modules\Greenroom\0.7.0\Assets\greenroom-launch.ps1'
    function Proc([int]$Id, [int]$Parent, [string]$Name, [string]$Cmd) {
        [PSCustomObject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CommandLine = $Cmd }
    }
    function UseProcesses([object[]]$Table) {
        $script:Table = $Table
        Mock -ModuleName Greenroom Test-AnyInstanceElevated { $false }
        Mock -ModuleName Greenroom Get-CimInstance {
            if ($Filter -eq "Name='claude.exe'") { return @($script:Table | Where-Object Name -eq 'claude.exe') }
            if ($Filter -match '^ProcessId=(\d+)$') { return @($script:Table | Where-Object ProcessId -eq ([int]$Matches[1])) }
        }
    }
    function Listed { @(InModuleScope Greenroom { Get-SessionProcess }) }
}

Describe 'Get-SessionProcess lists only the sessions greenroom started' {

    It 'lists a session whose parent is greenroom''s launcher for it' {
        UseProcesses @(
            (Proc 50 1 'pwsh.exe' "pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:Launcher -Instance laptop-admin"),
            (Proc 100 50 'claude.exe' 'C:\Users\x\.local\bin\claude.exe --remote-control laptop-admin --name laptop-admin -c')
        )
        $l = @(Listed)
        $l.Count | Should -Be 1
        $l[0].Instance | Should -Be 'laptop-admin'
        $l[0].Pid | Should -Be 100
    }

    It 'lists it when the launcher path is quoted because it has a space' {
        UseProcesses @(
            (Proc 50 1 'pwsh.exe' 'pwsh.exe -NoLogo -File "C:\Users\Jane Doe\Documents\PowerShell\Modules\Greenroom\0.7.0\Assets\greenroom-launch.ps1" -Instance laptop-admin'),
            (Proc 100 50 'claude.exe' 'claude.exe --remote-control laptop-admin --name laptop-admin')
        )
        (Listed).Instance | Should -Be 'laptop-admin'
    }

    It 'does not list <Why>' -ForEach @(
        @{ Why = 'a Remote Control session run by hand under the same name'
           Table = @( @{ Id = 60; Parent = 1; Name = 'pwsh.exe'; Cmd = 'pwsh.exe' },
                      @{ Id = 101; Parent = 60; Name = 'claude.exe'; Cmd = 'claude.exe --remote-control laptop-admin' } ) }
        @{ Why = 'a process using the unrelated --remote-control-session-name-prefix flag'
           Table = @( @{ Id = 60; Parent = 1; Name = 'pwsh.exe'; Cmd = 'pwsh.exe' },
                      @{ Id = 102; Parent = 60; Name = 'claude.exe'; Cmd = 'claude.exe --remote-control-session-name-prefix laptop' } ) }
        @{ Why = 'a session whose name differs from the one its launcher was started for'
           Table = @( @{ Id = 50; Parent = 1; Name = 'pwsh.exe'; Cmd = 'pwsh.exe -File C:\m\Assets\greenroom-launch.ps1 -Instance alpha' },
                      @{ Id = 103; Parent = 50; Name = 'claude.exe'; Cmd = 'claude.exe --remote-control beta' } ) }
        @{ Why = 'a session whose parent has already exited'
           Table = @( @{ Id = 104; Parent = 999; Name = 'claude.exe'; Cmd = 'claude.exe --remote-control laptop-admin' } ) }
        @{ Why = 'Claude Desktop, which uses no Remote Control flag at all'
           Table = @( @{ Id = 105; Parent = 1; Name = 'claude.exe'; Cmd = 'C:\Program Files\WindowsApps\Claude\app\claude.exe --type=renderer' } ) }
    ) {
        UseProcesses @($Table | ForEach-Object { Proc $_.Id $_.Parent $_.Name $_.Cmd })
        Listed | Should -BeNullOrEmpty
    }

    It 'lists greenroom''s session and nothing else when both run under one name' {
        UseProcesses @(
            (Proc 50 1 'pwsh.exe' "pwsh.exe -File $script:Launcher -Instance laptop-admin"),
            (Proc 100 50 'claude.exe' 'claude.exe --remote-control laptop-admin'),
            (Proc 60 1 'pwsh.exe' 'pwsh.exe'),
            (Proc 101 60 'claude.exe' 'claude.exe --remote-control laptop-admin')
        )
        $l = @(Listed)
        $l.Count | Should -Be 1
        $l[0].Pid | Should -Be 100
    }
}
