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
