# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Write the version AND that version's release notes into the manifest, as a cog
  pre-bump hook.

  WHY THE NOTES LIVE IN THE MANIFEST. PrivateData.PSData.ReleaseNotes is what the
  PowerShell Gallery renders on a version's page, and it is the only thing a person
  browsing the gallery can read to decide whether to upgrade. A module that ships it empty
  -- or points at a changelog somewhere else -- is the package equivalent of an app store
  entry that says "bug fixes and improvements", and that is a failure of tooling rather
  than a fact about the release. Every version this repository publishes carries its own
  changes.

  A published version is PERMANENT: the gallery allows unlisting, not deleting. So the
  notes have to be right on the way out, not fixable afterwards.

  ORDER. cog runs pre-bump hooks BEFORE it writes the changelog, commits or tags, so the
  new tag does not exist yet and `git describe` still names the PREVIOUS release. That is
  exactly the range we want: previous tag..HEAD.

  Both values go in ONE Update-ModuleManifest call, which is PowerShell's own writer for
  the manifest -- nothing here hand-edits a psd1.

  Verified before adopting it: multi-line notes containing apostrophes, asterisks, parens
  and `#` round-trip through Update-ModuleManifest intact and leave the manifest valid.
  The only difference is line endings, which it normalises to CRLF.

  FAILS RATHER THAN SHIPPING EMPTY NOTES. A hook that throws aborts the bump before the
  commit and tag exist, which is the safe side of the point of no return.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$ManifestPath = './Greenroom/Greenroom.psd1'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command cog -ErrorAction SilentlyContinue)) {
    throw 'cog is not on PATH, so release notes cannot be generated. Refusing to bump.'
}

# No tag yet means a first release: take the whole history rather than an empty range.
$previous = git describe --tags --abbrev=0 2>$null
$range    = if ($LASTEXITCODE -eq 0 -and $previous) { "$previous..HEAD" } else { $null }

$raw = if ($range) { & cog changelog $range --template default } else { & cog changelog --template default }
if ($LASTEXITCODE -ne 0) { throw "cog changelog failed for range '$range'. Refusing to bump." }

# Drop cog's own heading -- it reads "## Unreleased (abc..def)", which is both wrong on a
# published version and redundant beside the version the gallery already shows.
#
# Then drop the version-bump commit. It is the release's own bookkeeping ("- (**version**)
# v0.2.0"), it is never what a reader wants to know, and dropping it is what makes the
# emptiness check below mean something.
# @() around every pipeline, and Select-Object -Skip rather than a range slice. Both are
# load-bearing in PowerShell and were verified rather than assumed:
#   - a pipeline yielding ONE item collapses to a [string], and indexing a string returns
#     CHARACTERS, which silently corrupts the heading pass below
#   - `1..($n-1)` with $n=1 expands to `1,0` -- DESCENDING -- so the slice keeps the very
#     line it was meant to drop
# Neither shows up on a normal release; both would land on an odd one, permanently.
$lines = @($raw -split "`r?`n")
if ($lines.Count -and $lines[0] -match '^##\s') { $lines = @($lines | Select-Object -Skip 1) }
$lines = @($lines | Where-Object { $_ -notmatch '^\-\s+\(\*\*version\*\*\)' })

# WRITTEN FOR THE PERSON READING THE GALLERY PAGE, not for someone with the repository
# open. Surveyed what comparable modules actually ship in this field: PSReadLine,
# PSScriptAnalyzer and ImportExcel ship it EMPTY; Pester and dbatools ship a bare link;
# Az.Accounts -- the best of them, and the most installed module there is -- ships plain
# readable bullets. None of the six carry commit hashes or author names.
#
# So drop both. The gallery renders this close to plain text, which makes a hash
# unclickable noise, and per-line attribution answers a question the reader is not asking:
# they want to know what changed, and the git detail is one click away in the full
# changelog linked at the end.
#
# Pull request numbers are KEPT, deliberately, as the one deviation. They cost four
# characters and, beside that link, are enough to find the discussion behind a change.
$lines = @($lines |
    ForEach-Object { $_ -replace ' - \([0-9a-f]{7,40}\) - .*$', '' } |
    ForEach-Object { $_ -replace '^(\-\s+)\(\*\*([^*]+)\*\*\)\s*', '$1$2: ' })

# MEASURED, and the reason this check is not a formality: for a degenerate range -- HEAD
# already at the previous tag -- cog does not emit nothing. It emits the PREVIOUS release's
# section, chore commit and all, so a naive "is it empty" test passes and the manifest ends
# up describing a release that already shipped. Require an actual entry instead.
$entries = @($lines | Where-Object { $_ -match '^\-\s+\S' })
if ($entries.Count -eq 0) {
    # Spelled out for BOTH cases. On a first release there is no previous tag, so naming
    # the range and the tag would interpolate to "for '' ... since ." -- unreadable at the
    # one moment it gets read, which is while diagnosing a bump that just refused.
    $scope = if ($previous) { "since $previous ('$range')" } else { 'in the entire history (no previous tag)' }
    throw ("no release notes could be generated $scope -- nothing there but bookkeeping. Refusing to " +
           'bump: a version published with empty or stale notes cannot be fixed afterwards, because ' +
           'the gallery allows unlisting but not deleting.')
}

# Drop any section heading left with no entries under it after that filtering.
#
# `Select-Object -Skip` again rather than `($i+1)..($n-1)`: when the heading is the LAST
# line that range is descending too, and would look backwards through the notes for the
# entry it is meant to be checking for ahead.
$kept = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^####\s') {
        $next = @($lines | Select-Object -Skip ($i + 1) | Where-Object { $_ -match '^\S' } | Select-Object -First 1)
        if ($next.Count -eq 0 -or $next[0] -notmatch '^\-\s') { continue }
    }
    $kept += $lines[$i]
}
$notes = ($kept -join "`n").Trim()

$notes = $notes + "`n`nFull changelog: https://github.com/TylerVigario/greenroom-win/releases/tag/v$Version"

Update-ModuleManifest -Path $ManifestPath -ModuleVersion $Version -ReleaseNotes $notes

# Write-Output rather than Write-Host: this is a hook run as `pwsh -File`, nothing consumes
# its pipeline, and the one Write-Host exemption in this repository is deliberately scoped
# to ci/check.ps1, which needs colour for a console reporter. This just needs a log line.
Write-Output "manifest: $Version, $((($notes -split "`n") | Measure-Object).Count) lines of release notes"
