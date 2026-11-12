# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  One instance's error does not end a command -- unless the caller asked it to.

  The module sets $ErrorActionPreference = 'Stop', and every function in it inherits that.
  So an error a command means only to REPORT is terminating unless it goes through
  Write-CommandError, and a command looping over instances stops at the first one it cannot
  act on. These pin both halves: it carries on by default, and it stops when told to.

  NO -ErrorAction ON THE CALLS THAT TEST THE DEFAULT. Passing -ErrorAction SilentlyContinue
  sets the command's own preference, which on its own makes a bare Write-Error
  non-terminating -- so a test written that way passes against exactly the code it exists to
  catch. The caller's preference is set to Continue inside each test instead, which is an
  interactive shell's default, so nothing depends on what the runner happens to use.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    # Write-CommandError on its own, inside a module set up as Greenroom.psm1 sets itself
    # up -- Stop at module scope -- so its semantics are tested without any greenroom
    # command in the way.
    $helper  = Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Private\Write-CommandError.ps1'
    $missing = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    New-Module -Name GreenroomErrorProbe -ArgumentList $helper, $missing -ScriptBlock {
        param($helper, $missing)
        $ErrorActionPreference = 'Stop'
        $script:Missing = $missing
        . $helper

        function Invoke-Loop {
            [CmdletBinding()] param()
            foreach ($i in 1, 2) {
                Write-CommandError -Cmdlet $PSCmdlet -ErrorId 'Probe' -Category ObjectNotFound -TargetObject $i -Message "e$i"
                "item$i"
            }
            # The module's own code, after an error has been written, must still be on Stop.
            try { Get-Item -LiteralPath $script:Missing | Out-Null; 'module-code-carried-on' } catch { 'module-code-still-stops' }
        }

        function Invoke-Record {
            [CmdletBinding()] param()
            Write-CommandError -Cmdlet $PSCmdlet -ErrorRecord ([System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('prepared'), 'Prepared', 'InvalidArgument', 'x'))
            'after'
        }

        function Invoke-FromInside {
            [CmdletBinding()] param()
            try { Invoke-Loop } catch { "caught: $($_.Exception.Message)" }
        }

        Export-ModuleMember -Function Invoke-Loop, Invoke-Record, Invoke-FromInside
    } | Import-Module -Force
}

AfterAll {
    Remove-Module GreenroomErrorProbe -Force -ErrorAction SilentlyContinue
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
}

Describe 'Write-CommandError' {

    It 'carries on by default, and reports every error' {
        $ErrorActionPreference = 'Continue'
        $out = @(Invoke-Loop -ErrorVariable e 2>$null)
        $out | Should -Be @('item1', 'item2', 'module-code-still-stops')
        @($e | Where-Object FullyQualifiedErrorId -like 'Probe,*').Count | Should -Be 2
    }

    It 'stops at the first error when the caller passes -ErrorAction Stop' {
        { Invoke-Loop -ErrorAction Stop } | Should -Throw 'e1'
    }

    It 'stops at the first error when the CALLER''s preference is Stop' {
        # What `Write-Error -ErrorAction Continue` got wrong: it carried on regardless.
        { $ErrorActionPreference = 'Stop'; Invoke-Loop } | Should -Throw 'e1'
    }

    It 'throws to a caller inside the module, whose preference is Stop' {
        # Which is what lets Update-GreenroomInstance catch a failed restart.
        Invoke-FromInside | Should -Be 'caught: e1'
    }

    It 'leaves the module''s own code on Stop after writing one' {
        $ErrorActionPreference = 'Continue'
        @(Invoke-Loop 2>$null)[-1] | Should -Be 'module-code-still-stops'
    }

    It 'names the command that was typed, with the id, category, exception and target given' {
        $ErrorActionPreference = 'Continue'
        $null = Invoke-Loop -ErrorVariable e 2>$null
        $first = @($e | Where-Object FullyQualifiedErrorId -like 'Probe,*')[0]
        $first.FullyQualifiedErrorId          | Should -Be 'Probe,Invoke-Loop'
        $first.InvocationInfo.MyCommand.Name  | Should -Be 'Invoke-Loop'
        $first.CategoryInfo.Category          | Should -Be 'ObjectNotFound'
        $first.Exception                      | Should -BeOfType ([System.Management.Automation.ItemNotFoundException])
        $first.TargetObject                   | Should -Be 1
    }

    It 'honours -ErrorAction SilentlyContinue, and -ErrorVariable still records' {
        $out = @(Invoke-Loop -ErrorAction SilentlyContinue -ErrorVariable e)
        $out[0..1] | Should -Be @('item1', 'item2')
        @($e | Where-Object FullyQualifiedErrorId -like 'Probe,*').Count | Should -Be 2
    }

    It 'passes a prepared record through with its own id and exception' {
        $ErrorActionPreference = 'Continue'
        $out = Invoke-Record -ErrorVariable e 2>$null
        $out | Should -Be 'after'
        $e[0].FullyQualifiedErrorId | Should -Be 'Prepared,Invoke-Record'
        $e[0].Exception | Should -BeOfType ([System.ArgumentException])
    }
}

Describe 'One instance''s error does not end the command' {

    BeforeEach {
        # Two registered instances, a and b, so "did it reach b" is the question.
        Mock -ModuleName Greenroom Get-ScheduledTask {
            'greenroom-a', 'greenroom-b' | Where-Object { $_ -like $TaskName } |
                ForEach-Object { [PSCustomObject]@{ TaskName = $_ } }
        }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        # Left REAL: Assert-CanActOnInstance returns $true at once for an unelevated instance.
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        Mock -ModuleName Greenroom Stop-ScheduledTask { }
        Mock -ModuleName Greenroom Start-ScheduledTask { }
        Mock -ModuleName Greenroom Start-Sleep { }
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
        Mock -ModuleName Greenroom Get-GreenroomInstance {
            [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = $Name; ClaudePid = 4242; Opaque = $false; Window = [IntPtr]7 }
        }
    }

    Context 'Restart-GreenroomSession' {

        It 'restarts b after refusing a, the session this shell runs inside' {
            $ErrorActionPreference = 'Continue'
            Mock -ModuleName Greenroom Test-SelfIsInstance { $Name -eq 'a' }
            $null = Restart-GreenroomSession -Name '*' -ErrorVariable e 2>$null
            Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'greenroom-b' }
            $e[0].FullyQualifiedErrorId | Should -Be 'SessionIsSelf,Restart-GreenroomSession'
        }

        It 'stops at a when the caller passes -ErrorAction Stop' {
            Mock -ModuleName Greenroom Test-SelfIsInstance { $Name -eq 'a' }
            { Restart-GreenroomSession -Name '*' -ErrorAction Stop } | Should -Throw '*running inside*'
            Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
        }

        It 'stops at a when the caller''s preference is Stop' {
            Mock -ModuleName Greenroom Test-SelfIsInstance { $Name -eq 'a' }
            { $ErrorActionPreference = 'Stop'; Restart-GreenroomSession -Name '*' } | Should -Throw '*running inside*'
            Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
        }

        It 'restarts b after a''s session fails to come up' {
            $ErrorActionPreference = 'Continue'
            Mock -ModuleName Greenroom Get-GreenroomInstance {
                if ($Name -eq 'b') { [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'b'; ClaudePid = 4242; Opaque = $false } }
            }
            $r = @(Restart-GreenroomSession -Name '*' -TimeoutSeconds 5 -ErrorVariable e 2>$null)
            $r.Instance | Should -Be @('b')
            $e[0].FullyQualifiedErrorId | Should -Be 'SessionDidNotStart,Restart-GreenroomSession'
        }

        It 'restarts b after refusing to escalate for a, under -NoElevate' {
            # Through the REAL Assert-CanActOnInstance, whose refusal returns $false -- a
            # return that, written with Write-Error, never ran.
            $ErrorActionPreference = 'Continue'
            Mock -ModuleName Greenroom Test-InstanceElevated { $Name -eq 'a' }
            $null = Restart-GreenroomSession -Name '*' -NoElevate -ErrorVariable e 2>$null
            Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'greenroom-b' }
            $e[0].FullyQualifiedErrorId | Should -Be 'ElevationRefused,Restart-GreenroomSession'
        }

        It 'restarts b after a name in the pipeline that is not registered' {
            $ErrorActionPreference = 'Continue'
            $null = 'nope', 'b' | Restart-GreenroomSession -ErrorVariable e 2>$null
            Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'greenroom-b' }
            $e[0].FullyQualifiedErrorId | Should -Be 'InstanceNotRegistered,Restart-GreenroomSession'
        }
    }

    Context 'Stop-GreenroomSession' {

        It 'stops b after refusing a, the session this shell runs inside' {
            $ErrorActionPreference = 'Continue'
            Mock -ModuleName Greenroom Test-SelfIsInstance { $Name -eq 'a' }
            Mock -ModuleName Greenroom Get-GreenroomInstance { }
            $r = @(Stop-GreenroomSession -Name '*' -SettleSeconds 0 -ErrorVariable e 2>$null)
            $r.Instance | Should -Be @('b')
            $e[0].FullyQualifiedErrorId | Should -Be 'SessionIsSelf,Stop-GreenroomSession'
        }
    }

    Context 'Start-GreenroomSession' {

        It 'reaches b after a''s session fails to come up' {
            $ErrorActionPreference = 'Continue'
            Mock -ModuleName Greenroom Get-GreenroomInstance {
                if ($Name -eq 'b') { [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'b'; ClaudePid = 4242; Opaque = $false } }
            }
            $r = @('a', 'b' | Start-GreenroomSession -TimeoutSeconds 5 -ErrorVariable e 2>$null)
            $r.Instance | Should -Be @('b')
            $e[0].FullyQualifiedErrorId | Should -Be 'SessionDidNotStart,Start-GreenroomSession'
        }
    }

    Context 'Show-GreenroomSession' {

        It 'shows b after a name in the pipeline that is not running' {
            $ErrorActionPreference = 'Continue'
            Mock -ModuleName Greenroom Invoke-ElevationFirst { $false }
            Mock -ModuleName Greenroom Set-WindowVisible { $true }
            Mock -ModuleName Greenroom Get-GreenroomInstance {
                if ($Name -eq 'b') { [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'b'; ClaudePid = 4242; Opaque = $false; Window = [IntPtr]7 } }
            }
            'a', 'b' | Show-GreenroomSession -ErrorVariable e 2>$null
            Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly
            $e[0].FullyQualifiedErrorId | Should -Be 'SessionNotRunning,Show-GreenroomSession'
        }
    }
}
