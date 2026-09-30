# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  What Stop-VerifiedProcess reports as stopped. Its count feeds the StopResult and
  UninstallResult objects, whose contract is "what was actually stopped, as data" -- so a
  kill that was refused must not be counted.

  A refused kill is mocked: producing one for real means aiming at a protected process.
  The ordinary path is run for real, against a throwaway child process with a unique
  marker in its command line.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force
}
AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Stop-VerifiedProcess' {

    Context 'a kill that is refused' {
        BeforeEach {
            $script:Proc = [PSCustomObject]@{ ProcessId = 424242; CommandLine = 'pwsh -File greenroom-watchdog.ps1 -Instance probe' }
            Mock -ModuleName Greenroom Get-CimInstance { $script:Proc }
            # Non-terminating, as a real refusal is -- which is what SilentlyContinue swallowed.
            # Explicitly: a mock does not see the caller's -ErrorAction, so under a runner with
            # ErrorActionPreference Stop (ci/check.ps1) its error would otherwise terminate.
            Mock -ModuleName Greenroom Stop-Process { Write-Error 'Access is denied' -ErrorAction Continue }
        }

        It 'does not count it, and says so' {
            $n = InModuleScope Greenroom { Stop-VerifiedProcess -ProcessName 'pwsh.exe' -Pattern 'greenroom-watchdog.*probe' -Label 'watchdog' 3>&1 }
            $warn = @($n | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            @($n | Where-Object { $_ -is [int] }) | Should -Be @(0)
            $warn.Count | Should -Be 1
            "$($warn[0])" | Should -Match 'could not stop watchdog \(pid 424242\): Access is denied'
        }

        It 'counts it when the kill failed only because the process had already gone' {
            # It exited on its own between the identity check and the kill: Stop-Process
            # throws, but nothing is left running, which is what the count is about.
            $script:Lookups = 0
            Mock -ModuleName Greenroom Get-CimInstance { $script:Proc } -ParameterFilter { $Filter -like 'Name=*' }
            Mock -ModuleName Greenroom Get-CimInstance {
                $script:Lookups++
                if ($script:Lookups -eq 1) { $script:Proc }      # the identity check before the kill
            } -ParameterFilter { $Filter -eq 'ProcessId=424242' }
            $n = InModuleScope Greenroom { Stop-VerifiedProcess -ProcessName 'pwsh.exe' -Pattern 'greenroom-watchdog.*probe' -Label 'watchdog' 3>&1 }
            @($n | Where-Object { $_ -is [int] }) | Should -Be @(1)
            @($n | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
            $script:Lookups | Should -Be 2
        }
    }

    Context 'an instance''s session' {
        # Only the session greenroom's launcher started for the instance -- never one started
        # by hand under the same name. Processes are faked and no kill is real.
        BeforeAll {
            $script:Launcher = 'C:\Users\x\Documents\PowerShell\Modules\Greenroom\0.7.0\Assets\greenroom-launch.ps1'
            function Proc([int]$Id, [int]$Parent, [string]$Name, [string]$Cmd) {
                [PSCustomObject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CommandLine = $Cmd }
            }
        }
        BeforeEach {
            $script:Table = @(
                (Proc 50 1 'pwsh.exe' "pwsh.exe -NoLogo -File $script:Launcher -Instance render-"),
                (Proc 100 50 'claude.exe' 'claude.exe --remote-control render- --name render-'),
                (Proc 60 1 'pwsh.exe' 'pwsh.exe'),
                (Proc 101 60 'claude.exe' 'claude.exe --remote-control render-'),
                (Proc 70 1 'pwsh.exe' "pwsh.exe -NoLogo -File $script:Launcher -Instance render-two"),
                (Proc 102 70 'claude.exe' 'claude.exe --remote-control render-two')
            )
            Mock -ModuleName Greenroom Get-CimInstance {
                if ($Filter -eq "Name='claude.exe'") { return @($script:Table | Where-Object Name -eq 'claude.exe') }
                if ($Filter -match '^ProcessId=(\d+)$') { return @($script:Table | Where-Object ProcessId -eq ([int]$Matches[1])) }
            }
            Mock -ModuleName Greenroom Stop-Process { }
        }

        It 'stops the session greenroom started for it, and nothing else' {
            $n = InModuleScope Greenroom { Stop-VerifiedProcess -ProcessName 'claude.exe' -SessionOf 'render-' -Label 'session' }
            $n | Should -Be 1
            Should -Invoke -ModuleName Greenroom Stop-Process -Times 1 -Exactly
            Should -Invoke -ModuleName Greenroom Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 100 }
        }

        It 'stops nothing when the only session under the name was started by hand' {
            $script:Table = @($script:Table | Where-Object { $_.ProcessId -notin 50, 100 })
            $n = InModuleScope Greenroom { Stop-VerifiedProcess -ProcessName 'claude.exe' -SessionOf 'render-' -Label 'session' }
            $n | Should -Be 0
            Should -Invoke -ModuleName Greenroom Stop-Process -Times 0
        }

        It 'does not stop a pid that stopped being the session before the kill' {
            # Enumerated as greenroom's session; by the re-check the pid is a hand-started one.
            $script:Checks = 0
            Mock -ModuleName Greenroom Get-CimInstance {
                $script:Checks++
                if ($script:Checks -eq 1) { return (Proc 50 1 'pwsh.exe' "pwsh.exe -File $script:Launcher -Instance render-") }
                return (Proc 100 60 'claude.exe' 'claude.exe --remote-control render-')
            } -ParameterFilter { $Filter -eq 'ProcessId=100' -or $Filter -eq 'ProcessId=50' }
            $n = InModuleScope Greenroom { Stop-VerifiedProcess -ProcessName 'claude.exe' -SessionOf 'render-' -Label 'session' }
            $n | Should -Be 0
            Should -Invoke -ModuleName Greenroom Stop-Process -Times 0
        }
    }

    Context 'the pattern for a greenroom script' {
        # Only a shell running the script for the instance, in the one shape greenroom
        # starts it -- never one whose command line merely mentions both.
        It 'matches <Why>' -ForEach @(
            @{ Why = 'the watchdog as its .vbs starts it'; Script = 'greenroom-watchdog.ps1'; Name = 'laptop-admin'
               Cmd = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\Users\x\Documents\PowerShell\Modules\Greenroom\0.7.0\Assets\greenroom-watchdog.ps1" -Instance "laptop-admin"' }
            @{ Why = 'the launcher as the watchdog starts it'; Script = 'greenroom-launch.ps1'; Name = 'laptop-admin'
               Cmd = 'pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\Users\x\Documents\PowerShell\Modules\Greenroom\0.7.0\Assets\greenroom-launch.ps1 -Instance laptop-admin' }
            @{ Why = 'a launcher path quoted for its space'; Script = 'greenroom-launch.ps1'; Name = 'laptop-admin'
               Cmd = 'pwsh.exe -NoLogo -File "C:\Users\Jane Doe\Documents\PowerShell\Modules\Greenroom\0.7.0\Assets\greenroom-launch.ps1" -Instance laptop-admin' }
            @{ Why = 'a name ending in a dash'; Script = 'greenroom-watchdog.ps1'; Name = 'render-'
               Cmd = 'pwsh.exe -File C:\m\Assets\greenroom-watchdog.ps1 -Instance "render-"' }
            @{ Why = 'a name ending in a dot'; Script = 'greenroom-launch.ps1'; Name = 'v1.'
               Cmd = 'powershell.exe -File C:\m\Assets\greenroom-launch.ps1 -Instance v1.' }
        ) {
            $p = InModuleScope Greenroom -Parameters @{ s = $Script; n = $Name } { param($s, $n) Get-InstanceScriptPattern -Script $s -Name $n }
            $Cmd | Should -Match $p
        }

        It 'does not match <Why>' -ForEach @(
            @{ Why = 'a shell that only mentions the script and the instance'; Script = 'greenroom-watchdog.ps1'; Name = 'laptop-admin'
               Cmd = 'pwsh.exe -Command "Get-Content C:\m\Assets\greenroom-watchdog.ps1 | Select-String Instance; Get-GreenroomInstance -Instance laptop-admin"' }
            @{ Why = 'a shell reading the launcher before naming the instance'; Script = 'greenroom-launch.ps1'; Name = 'laptop-admin'
               Cmd = 'pwsh.exe -Command "code C:\m\Assets\greenroom-launch.ps1; Restart-GreenroomSession -Instance laptop-admin"' }
            @{ Why = 'another instance sharing the prefix'; Script = 'greenroom-watchdog.ps1'; Name = 'render-'
               Cmd = 'pwsh.exe -File C:\m\Assets\greenroom-watchdog.ps1 -Instance "render-two"' }
            @{ Why = 'another script whose name ends the same'; Script = 'greenroom-watchdog.ps1'; Name = 'laptop-admin'
               Cmd = 'pwsh.exe -File C:\m\my-greenroom-watchdog.ps1 -Instance laptop-admin' }
            @{ Why = 'the other greenroom script'; Script = 'greenroom-launch.ps1'; Name = 'laptop-admin'
               Cmd = 'pwsh.exe -File C:\m\Assets\greenroom-watchdog.ps1 -Instance laptop-admin' }
        ) {
            $p = InModuleScope Greenroom -Parameters @{ s = $Script; n = $Name } { param($s, $n) Get-InstanceScriptPattern -Script $s -Name $n }
            $Cmd | Should -Not -Match $p
        }
    }

    It 'stops and counts a real process' {
        $marker = 'gr-stop-probe-' + [guid]::NewGuid().ToString('N')
        $shell = (Get-Process -Id $PID).Path
        $child = Start-Process $shell -ArgumentList '-NoProfile', '-Command', "Start-Sleep 60 # $marker" -PassThru -WindowStyle Hidden
        try {
            for ($i = 0; $i -lt 40; $i++) {
                if (Get-CimInstance Win32_Process -Filter "ProcessId=$($child.Id)" | Where-Object CommandLine -match $marker) { break }
                Start-Sleep -Milliseconds 100
            }
            $n = InModuleScope Greenroom -Parameters @{ n = (Split-Path $shell -Leaf); m = $marker } {
                param($n, $m) Stop-VerifiedProcess -ProcessName $n -Pattern $m -Label 'probe'
            }
            $n | Should -Be 1
            $child.WaitForExit(5000) | Should -BeTrue
        }
        finally { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } }
    }
}
