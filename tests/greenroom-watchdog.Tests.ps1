# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  What the watchdog treats as its own: which claude.exe it adopts as its instance's
  session, and which window it closes as that session's corpse. Only greenroom's -- a
  session greenroom's launcher started for this instance, and the window greenroom
  recorded for it. By name or title alone it adopted, and closed the window of, a Remote
  Control session started by hand.

  The watchdog is a script with a supervision loop, not a module function, so the tests
  lift its functions out of the script's syntax tree and run that exact code against a
  faked process table and faked windows. Nothing is started, stopped or closed: the
  Win32 type the watchdog calls is never loaded here, so an unmocked call throws rather
  than reaching a real window.
#>

BeforeAll {
    $assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Assets'
    . (Join-Path $assets 'Get-GreenroomSessionName.ps1')

    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $assets 'greenroom-watchdog.ps1'), [ref]$null, [ref]$null)
    foreach ($name in 'Get-RcClaudePid', 'Close-StaleWindows', 'Get-WindowInfo', 'Send-WindowClose') {
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
            }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }

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

Describe 'the watchdog closes only the window greenroom recorded' {

    BeforeAll {
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Assets\Test-SessionTitle.ps1')
        # Instance name deliberately not this host's: nothing here reaches a real window,
        # but a slip would then still name nothing.
        $script:Title = ([string][char]0x25D0) + ' render-'
        function Log($m) { $script:Logged += @($m) }
        function UseRecord($Record) {
            $f = Join-Path $script:stateDir 'session.json'
            if ($null -eq $Record) { Remove-Item $f -ErrorAction SilentlyContinue }
            elseif ($Record -is [string]) { Set-Content -Path $f -Value $Record }
            else { $Record | ConvertTo-Json | Set-Content -Path $f }
        }
        function UseWindows([hashtable]$Windows) {
            $script:Windows = $Windows
            Mock Get-WindowInfo {
                $w = $script:Windows[[int][int64]$Handle]
                if ($w) { return $w }
                [PSCustomObject]@{ OwnerPid = 0; Class = ''; Title = '' }
            }
        }
        function Win([int]$Owner, [string]$Title, [string]$Class = 'CASCADIA_HOSTING_WINDOW_CLASS') {
            [PSCustomObject]@{ OwnerPid = $Owner; Class = $Class; Title = $Title }
        }
    }

    BeforeEach {
        $script:Instance = 'render-'
        $script:stateDir = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid()))).FullName
        $script:Logged = @()
        Mock Send-WindowClose { }
        Mock Start-Sleep { }
        UseRecord @{ handle = 1001; claudePid = 100; terminalPid = 777; capturedUtc = '2026-09-30T00:00:00Z' }
    }

    It 'closes the recorded window while it is still this instance''s session window' {
        UseWindows @{ 1001 = (Win 777 $script:Title) }
        Close-StaleWindows
        Should -Invoke Send-WindowClose -Times 1 -Exactly -ParameterFilter { [int64]$Handle -eq 1001 }
    }

    It 'leaves a window titled as the instance''s session that greenroom did not record' {
        # The window of a Remote Control session started by hand under the same name.
        UseWindows @{ 2002 = (Win 777 $script:Title) }
        Close-StaleWindows
        Should -Invoke Send-WindowClose -Times 0
    }

    It 'leaves the recorded window when <Why>' -ForEach @(
        @{ Why = 'its handle now belongs to another process'; Owner = 888; Title = ([string][char]0x25D0) + ' render-'; Class = 'CASCADIA_HOSTING_WINDOW_CLASS' }
        @{ Why = 'it is no longer titled as this instance''s session'; Owner = 777; Title = 'C:\Users\x\render-'; Class = 'CASCADIA_HOSTING_WINDOW_CLASS' }
        @{ Why = 'it is titled as another instance''s session'; Owner = 777; Title = ([string][char]0x25D0) + ' render-two'; Class = 'CASCADIA_HOSTING_WINDOW_CLASS' }
        @{ Why = 'it is not a terminal window'; Owner = 777; Title = ([string][char]0x25D0) + ' render-'; Class = 'Notepad' }
    ) {
        UseWindows @{ 1001 = (Win $Owner $Title $Class) }
        Close-StaleWindows
        Should -Invoke Send-WindowClose -Times 0
        $script:Logged | Should -Match 'left open'
    }

    It 'closes nothing when <Why>' -ForEach @(
        @{ Why = 'there is no record'; Record = $null }
        @{ Why = 'the record is malformed'; Record = '{ not json' }
        @{ Why = 'the record is empty'; Record = '' }
    ) {
        UseRecord $Record
        UseWindows @{ 1001 = (Win 777 $script:Title) }
        Close-StaleWindows
        Should -Invoke Send-WindowClose -Times 0
    }

    It 'closes nothing when the recorded window is already gone' {
        UseWindows @{}
        Close-StaleWindows
        Should -Invoke Send-WindowClose -Times 0
        $script:Logged | Should -BeNullOrEmpty
    }
}
