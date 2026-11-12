# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Get-TaskRewriteBlocker decides whether Update-, Install- and Uninstall- refuse an
  instance before touching it, so these exercise its own logic rather than mocking it.

  Get-Acl is mocked with an owner SID and, separately, an owner NAME. The two are kept apart
  on purpose: the name is localized, and the refusal has to follow the SID.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    function Ask([bool]$Elevated) {
        InModuleScope Greenroom -Parameters @{ e = $Elevated } {
            param($e)
            Get-TaskRewriteBlocker -Name 'probe' -Elevated $e
        }
    }

    # A stand-in for what Get-Acl returns: the localized Owner string, and GetOwner(SID).
    function OwnedBy([string]$Sid, [string]$Display) {
        $script:OwnerSid  = $Sid
        $script:OwnerName = $Display
        Mock -ModuleName Greenroom Get-Acl {
            $o = [PSCustomObject]@{ Owner = $script:OwnerName }
            # The real GetOwner takes the identity type; a script method needs no param
            # block to accept it.
            $o | Add-Member -MemberType ScriptMethod -Name GetOwner -Value {
                [Security.Principal.SecurityIdentifier]::new($script:OwnerSid)
            } -PassThru
        }
    }
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Get-TaskRewriteBlocker' {

    BeforeEach {
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        OwnedBy 'S-1-5-21-1-2-3-1001' 'HOST\someone'
    }

    It 'refuses nothing from an elevated shell, and reads nothing to decide that' {
        Mock -ModuleName Greenroom Test-SelfElevated { $true }
        OwnedBy 'S-1-5-32-544' 'BUILTIN\Administrators'
        Ask -Elevated $true | Should -BeNullOrEmpty
        Should -Invoke -ModuleName Greenroom Get-Acl -Times 0
    }

    It 'refuses an elevated registration from an unelevated shell, and names the fix' {
        $why = Ask -Elevated $true
        $why | Should -Match 'requires an elevated caller'
        $why | Should -Match 'Run this from an elevated shell'
    }

    It 'refuses a task owned by <Who>, whatever the name is spelled as' -ForEach @(
        @{ Who = 'Administrators';                Sid = 'S-1-5-32-544'; Display = 'BUILTIN\Administrators' }
        # German Windows. Matching the name instead of the SID refused nothing here.
        @{ Who = 'Administrators, localized';     Sid = 'S-1-5-32-544'; Display = 'VORDEFINIERT\Administratoren' }
        @{ Who = 'SYSTEM';                        Sid = 'S-1-5-18';     Display = 'NT AUTHORITY\SYSTEM' }
        @{ Who = 'TrustedInstaller';              Sid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; Display = 'NT SERVICE\TrustedInstaller' }
    ) {
        OwnedBy $Sid $Display
        $why = Ask -Elevated $false
        $why | Should -Match ([regex]::Escape("owned by $Display"))
        $why | Should -Match 'Run this from an elevated shell'
    }

    It 'says the owner comes from creation, not from who last registered it' {
        OwnedBy 'S-1-5-32-544' 'BUILTIN\Administrators'
        Ask -Elevated $false | Should -Match 'takes its owner when it is created'
    }

    It 'refuses nothing for a task the user owns' {
        Ask -Elevated $false | Should -BeNullOrEmpty
    }

    It 'refuses nothing when the task cannot be read -- the attempt decides' {
        # Includes a first install, where there is no task file at all.
        Mock -ModuleName Greenroom Get-Acl { throw 'Cannot find path' }
        Ask -Elevated $false | Should -BeNullOrEmpty
    }
}
