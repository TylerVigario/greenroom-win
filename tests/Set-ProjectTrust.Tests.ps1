# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Trust seeding writes ~/.claude.json, which belongs to Claude Code rather than to
  greenroom. Getting it wrong does not degrade greenroom -- it breaks the other
  application, so these tests are about not damaging somebody else's file.

  The empty-projects case is a regression. Inserting after the `{` of `"projects": {}`
  produced a trailing comma, and the guard did not catch it because ConvertFrom-Json
  ACCEPTS trailing commas while Node -- the parser that actually reads the file --
  rejects them. The result would have been a valid-looking write that Claude Code could
  not open.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) "greenroom-trust-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null

    # Node's strictness is the bar, so assert against a parser that shares it -- and one
    # that EXISTS on the running edition. System.Text.Json is .NET Core only; on Windows
    # PowerShell 5.1 its absence would fail these tests for the wrong reason, so 5.1 uses
    # JavaScriptSerializer, which rejects trailing commas just as strictly. (ConvertFrom-Json
    # is not usable either way -- it ACCEPTS the trailing comma Node rejects.)
    function BeStrictlyValidJson {
        param([string]$Text)
        try {
            if ($PSVersionTable.PSEdition -eq 'Desktop') {
                Add-Type -AssemblyName System.Web.Extensions
                $null = (New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($Text)
            }
            else {
                [System.Text.Json.JsonDocument]::Parse($Text).Dispose()
            }
            return $true
        }
        catch { return $false }
    }

    function Seed {
        param([string]$Existing, [string]$Directory = 'C:\probe-wd')
        $home2 = Join-Path $script:Sandbox ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $home2 -Force | Out-Null
        Set-Content (Join-Path $home2 '.claude.json') -Value $Existing -NoNewline
        $backup = Join-Path $home2 'backup'
        InModuleScope Greenroom -Parameters @{ h = $home2; d = $Directory; b = $backup } {
            param($h, $d, $b)
            $env:USERPROFILE = $h
            Set-ProjectTrust -Directory $d -BackupDir $b | Out-Null
        }
        Get-Content (Join-Path $home2 '.claude.json') -Raw
    }

    function Survived {
        param([string]$Existing, [string]$Directory = 'C:\probe-wd')
        $home2 = Join-Path $script:Sandbox ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $home2 -Force | Out-Null
        Set-Content (Join-Path $home2 '.claude.json') -Value $Existing -NoNewline
        InModuleScope Greenroom -Parameters @{ h = $home2; d = $Directory } {
            param($h, $d)
            $env:USERPROFILE = $h
            Test-TrustSurvived -Directory $d 3>$null   # 3>$null: swallow the parse Warning, assert the return
        }
    }
}

AfterAll {
    if (Test-Path $script:Sandbox) { Remove-Item $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ProjectTrust' {

    BeforeEach { $script:RealProfile = $env:USERPROFILE }
    AfterEach  { $env:USERPROFILE = $script:RealProfile }

    It 'produces strictly valid JSON when projects is EMPTY' {
        # The regression. A trailing comma here is invisible to ConvertFrom-Json and
        # fatal to Node.
        $out = Seed -Existing '{ "projects": {} }'
        BeStrictlyValidJson $out | Should -BeTrue -Because 'Node rejects trailing commas'
        $out | Should -Not -Match ',\s*\}'
    }

    It 'produces strictly valid JSON when projects already has entries' {
        $out = Seed -Existing '{ "projects": { "C:\\other": { "hasTrustDialogAccepted": true } } }'
        BeStrictlyValidJson $out | Should -BeTrue
    }

    It 'seeds BOTH path forms, because trust is keyed on the literal string' {
        # 'C:\x' and 'C:/x' are separate entries with independent trust; seeding one and
        # starting with the other re-prompts forever.
        $out = Seed -Existing '{ "projects": {} }'
        $out | Should -Match 'C:\\\\probe-wd'
        $out | Should -Match 'C:/probe-wd'
    }

    It 'marks trust accepted' {
        $out = Seed -Existing '{ "projects": {} }'
        ($out | ConvertFrom-Json).projects.'C:\probe-wd'.hasTrustDialogAccepted | Should -BeTrue
    }

    It 'preserves keys it did not put there' {
        $out = Seed -Existing '{ "numStartups": 42, "projects": {} }'
        ($out | ConvertFrom-Json).numStartups | Should -Be 42
    }

    It 'is idempotent -- seeding twice does not duplicate or corrupt' {
        $first  = Seed -Existing '{ "projects": {} }'
        # Feeding the result back in is what a re-run does.
        $second = Seed -Existing $first
        BeStrictlyValidJson $second | Should -BeTrue
        ([regex]::Matches($second, 'hasTrustDialogAccepted')).Count | Should -Be 2
    }

    It 'refuses rather than writing when there is no projects block' {
        $out = Seed -Existing '{ "somethingElse": 1 }'
        $out | Should -Be '{ "somethingElse": 1 }'
    }

    Context 'what counts as already trusted' {
        <#
          The seed must leave the file in the state the post-launch check requires: a
          "projects" key equal to each path form, case and all, with hasTrustDialogAccepted
          true. Anything short of that and the hidden session stops at the trust dialog.
          So each case seeds, then asks Test-TrustSurvived -- the check install runs after
          launch -- about the result.
        #>

        It 'seeds a path that appears in the file only as a value elsewhere' {
            $out = Seed -Existing '{ "githubRepoPaths": { "me/repo": ["C:\\probe-wd"] }, "projects": {} }'
            BeStrictlyValidJson $out | Should -BeTrue
            Survived -Existing $out | Should -BeTrue
            ($out | ConvertFrom-Json).githubRepoPaths.'me/repo' | Should -Be 'C:\probe-wd'
        }

        It 'accepts trust on an entry that exists with the dialog NOT accepted, keeping its other fields' {
            $existing = '{ "projects": { ' +
                '"C:\\probe-wd": { "allowedTools": ["Bash(ls:*)"], "hasTrustDialogAccepted": false, "lastCost": 1.5 }, ' +
                '"C:/probe-wd": { "hasTrustDialogAccepted": false } } }'
            $out = Seed -Existing $existing
            BeStrictlyValidJson $out | Should -BeTrue
            Survived -Existing $out | Should -BeTrue
            $e = ($out | ConvertFrom-Json).projects.'C:\probe-wd'
            $e.allowedTools | Should -Be 'Bash(ls:*)'
            $e.lastCost | Should -Be 1.5
        }

        It 'adds the flag to an entry that exists without it' {
            $out = Seed -Existing '{ "projects": { "C:\\probe-wd": { "allowedTools": [] }, "C:/probe-wd": {} } }'
            BeStrictlyValidJson $out | Should -BeTrue
            Survived -Existing $out | Should -BeTrue
        }

        It 'seeds the exact case when only a different case is present' {
            # Claude Code keys the literal cwd string; "c:\probe-wd" is not "C:\probe-wd".
            $out = Seed -Existing '{ "projects": { "c:\\probe-wd": { "hasTrustDialogAccepted": true }, "c:/probe-wd": { "hasTrustDialogAccepted": true } } }'
            BeStrictlyValidJson $out | Should -BeTrue
            Survived -Existing $out | Should -BeTrue
            $out | Should -Match '"c:\\\\probe-wd"'        # the other entry is left alone
        }

        It 'is not fooled by braces and quotes inside strings, or a "projects" key nested elsewhere' {
            # The text is walked by token, so structure inside a string is not structure, and
            # only the TOP-LEVEL "projects" is the projects map.
            $existing = '{ "cache": { "projects": { "C:\\probe-wd": { "hasTrustDialogAccepted": false } } }, ' +
                '"note": "a } brace, a \" quote and \"C:\\\\probe-wd\": { in a string", ' +
                '"projects": { "C:\\probe-wd": { "hasTrustDialogAccepted": false, "x": "}{" } } }'
            $out = Seed -Existing $existing
            BeStrictlyValidJson $out | Should -BeTrue
            Survived -Existing $out | Should -BeTrue
            $o = $out | ConvertFrom-Json
            $o.cache.projects.'C:\probe-wd'.hasTrustDialogAccepted | Should -BeFalse   # the decoy is untouched
            $o.note | Should -Be 'a } brace, a " quote and "C:\\probe-wd": { in a string'
            $o.projects.'C:\probe-wd'.x | Should -Be '}{'
        }

        It 'changes nothing when both forms are already trusted' {
            $existing = '{ "projects": { "C:\\probe-wd": { "hasTrustDialogAccepted": true }, "C:/probe-wd": { "hasTrustDialogAccepted": true } } }'
            Seed -Existing $existing | Should -Be $existing
        }
    }
}

Describe 'Test-TrustSurvived' {

    BeforeEach { $script:RealProfile = $env:USERPROFILE }
    AfterEach  { $env:USERPROFILE = $script:RealProfile }

    It 'is true when both path forms are trusted' {
        Survived -Existing '{ "projects": { "C:\\probe-wd": { "hasTrustDialogAccepted": true }, "C:/probe-wd": { "hasTrustDialogAccepted": true } } }' |
            Should -BeTrue
    }

    It 'is false when the directory is absent' {
        Survived -Existing '{ "projects": { "C:\\other": { "hasTrustDialogAccepted": true } } }' | Should -BeFalse
    }

    It 'never throws -- returns false on malformed JSON' {
        # A boolean predicate that Install calls without a catch: throwing would abort the
        # install rather than let it re-seed.
        Survived -Existing '{ "projects": { oops' | Should -BeFalse
    }

    It 'returns false on a non-object project entry rather than throwing' {
        Survived -Existing '{ "projects": { "C:\\probe-wd": "nope", "C:/probe-wd": "nope" } }' | Should -BeFalse
    }
}

Describe 'Claude Code files keep their encoding' {
    <#
      Claude Code writes its JSON as UTF-8 without a BOM. Windows PowerShell 5.1 reads such
      a file as ANSI and writes UTF-8 WITH a BOM, so on 5.1 any non-ASCII text came back as
      mojibake, a BOM was put in front of the file, and a trust key under a non-ASCII path
      never matched. These bite on 5.1 -- CI's test-desktop leg.

      Non-ASCII is built from code points, and fixtures are written as explicit bytes: this
      file is ASCII, and a 5.1 Set-Content would itself write ANSI.
    #>
    BeforeAll {
        $script:Utf8 = [Text.UTF8Encoding]::new($false)
        $script:Text = 'caf' + [char]0xE9 + ' ' + [char]0x65E5 + [char]0x672C + ' ' + [char]::ConvertFromUtf32(0x1F680)
        $script:Dir  = 'C:\Users\Jos' + [char]0xE9 + '\work'
        function NewHome([string]$Json) {
            $h = Join-Path $script:Sandbox ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $h -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $h '.claude.json'), $Json, $script:Utf8)
            $h
        }
        function HasBom([string]$Path) {
            $b = [IO.File]::ReadAllBytes($Path)
            $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
        }
    }
    BeforeEach { $script:RealProfile = $env:USERPROFILE }
    AfterEach  { $env:USERPROFILE = $script:RealProfile }

    It 'seeding keeps non-ASCII text exactly, and writes no BOM' {
        $h = NewHome ('{ "userName": "' + $script:Text + '", "projects": {} }')
        InModuleScope Greenroom -Parameters @{ h = $h } { param($h); $env:USERPROFILE = $h; Set-ProjectTrust -Directory 'C:\probe-wd' -BackupDir (Join-Path $h 'b') | Out-Null }
        $file = Join-Path $h '.claude.json'
        HasBom $file | Should -BeFalse
        $after = [IO.File]::ReadAllText($file, $script:Utf8)
        [regex]::Match($after, '"userName": "([^"]*)"').Groups[1].Value | Should -BeExactly $script:Text
    }

    It 'trusts a working directory with a non-ASCII name under the key Claude Code will read' {
        # Self-consistency is not enough: a seed and a check that mis-decode the same way agree
        # with each other. What matters is the key as Claude Code reads the file -- UTF-8.
        $h = NewHome '{ "projects": {} }'
        $ok = InModuleScope Greenroom -Parameters @{ h = $h; d = $script:Dir } {
            param($h, $d); $env:USERPROFILE = $h
            Set-ProjectTrust -Directory $d -BackupDir (Join-Path $h 'b') | Out-Null
            Test-TrustSurvived -Directory $d
        }
        $ok | Should -BeTrue
        $asRead = [IO.File]::ReadAllText((Join-Path $h '.claude.json'), $script:Utf8) | ConvertFrom-Json
        $asRead.projects.($script:Dir).hasTrustDialogAccepted | Should -BeTrue
    }

    It 'recognises trust under a non-ASCII path in the file as Claude Code writes it, and adds nothing' {
        # Claude Code rewrites ~/.claude.json constantly, BOM-less. Read as ANSI, the key no
        # longer matched: the check said "not trusted" forever and the seed added a second,
        # mojibake entry.
        $k1 = $script:Dir.Replace('\', '\\'); $k2 = $script:Dir.Replace('\', '/')
        $json = '{ "projects": { "' + $k1 + '": { "hasTrustDialogAccepted": true }, "' + $k2 + '": { "hasTrustDialogAccepted": true } } }'
        $h = NewHome $json
        $r = InModuleScope Greenroom -Parameters @{ h = $h; d = $script:Dir } {
            param($h, $d); $env:USERPROFILE = $h
            [PSCustomObject]@{
                Survived = Test-TrustSurvived -Directory $d
                Seeded   = Set-ProjectTrust -Directory $d -BackupDir (Join-Path $h 'b')
            }
        }
        $r.Survived | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $h '.claude.json'), $script:Utf8) | Should -BeExactly $json
    }

    It 'writes the project settings without a BOM, keeping a non-ASCII grant' {
        $wd = Join-Path $script:Sandbox ([guid]::NewGuid())
        $grant = 'D:\' + $script:Text
        InModuleScope Greenroom -Parameters @{ w = $wd; g = $grant } { param($w, $g); Set-ProjectGrant -Directory $w -Grants @($g) }
        $file = Join-Path $wd '.claude\settings.json'
        HasBom $file | Should -BeFalse
        ([IO.File]::ReadAllText($file, $script:Utf8) | ConvertFrom-Json).permissions.additionalDirectories | Should -BeExactly $grant
    }
}
