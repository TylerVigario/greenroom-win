# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  The instance logs -- watchdog.log and launch.log -- run unattended for months and must
  stay bounded. launch.log was not: it grew without limit, fastest in a crash loop.

  Hermetic: the helper is dot-sourced exactly as the two scripts dot-source it, and writes
  only under $TestDrive.
#>

BeforeAll {
    $script:Assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Assets'
    . (Join-Path $script:Assets 'Write-InstanceLog.ps1')
}

Describe 'Write-InstanceLog' {

    It 'appends one timestamped line' {
        $log = Join-Path $TestDrive 'a.log'
        Write-InstanceLog -Path $log -Message 'hello'
        $lines = @(Get-Content $log)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}  hello$'
    }

    It 'keeps the newest lines once the log passes its cap' {
        $log = Join-Path $TestDrive 'b.log'
        Set-Content $log -Value (1..300 | ForEach-Object { "old line $_ " + ('x' * 40) })
        Write-InstanceLog -Path $log -Message 'newest' -MaxBytes 4KB -KeepLines 20
        $lines = @(Get-Content $log)
        $lines.Count | Should -Be 20
        $lines[-1] | Should -Match '  newest$'
        $lines[0] | Should -Match '^old line 282 '
    }

    It 'leaves a log under its cap alone' {
        $log = Join-Path $TestDrive 'c.log'
        Set-Content $log -Value (1..10 | ForEach-Object { "line $_" })
        Write-InstanceLog -Path $log -Message 'eleventh' -MaxBytes 4KB -KeepLines 5
        @(Get-Content $log).Count | Should -Be 11
    }

    It 'defaults to the cap the watchdog always had: 512 KB, then the last 500 lines' {
        $log = Join-Path $TestDrive 'd.log'
        Set-Content $log -Value (1..6000 | ForEach-Object { "line $_ " + ('y' * 90) })   # ~600 KB
        Write-InstanceLog -Path $log -Message 'last'
        @(Get-Content $log).Count | Should -Be 500
    }

    It '<Script> logs through it' -ForEach @(
        @{ Script = 'greenroom-watchdog.ps1' }, @{ Script = 'greenroom-launch.ps1' }
    ) {
        # Both scripts' Log goes through the one bounded writer; the launcher's once did not.
        $text = Get-Content (Join-Path $script:Assets $Script) -Raw
        $text | Should -Match "\. \(Join-Path \`$PSScriptRoot 'Write-InstanceLog\.ps1'\)"
        $text | Should -Match 'function Log\(\$m\) \{ Write-InstanceLog -Path \$log -Message \$m \}'
    }
}
