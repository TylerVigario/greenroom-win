# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Regenerate CHANGELOG.md from the whole history, at each release. Runs after `cog bump`,
  with the new tag on HEAD, and before the version commit leaves the runner.

  WHY NOT THE SECTION `cog bump` WRITES. cog bump renders only the release it is cutting, and
  two things in that section come out wrong (cocogitto 7.0.0; cocogitto/cocogitto#579):

    - The compare link starts at the release's FIRST COMMIT, not the previous tag. GitHub's
      A..B leaves A out, so the linked comparison drops that commit: v0.7.0 linked
      70a7f3c..v0.7.0, without #58.
    - The date is the UTC date of the newest commit BEFORE the bump -- the last change merged,
      which can be days before the release. v0.7.0 read 2026-09-30, the day #91 merged; it was
      released 2026-10-01 (UTC), the date its tag, version commit, gallery entry and GitHub
      Release all carry.

  A full `cog changelog` renders every release with its predecessor in range: tag..tag links,
  each release dated by its own version commit, in UTC like every other record of it.

  KEPT BY HAND, verbatim: the preamble down to the FIRST separator, and everything from the
  LAST separator on -- the 0.1.0 section, which reads "Initial release." because cog's own
  0.1.0 would list every commit since the repository began. cog's section for that version
  is dropped.

  DROPPED: each version commit's own line, "- (**version**) vX.Y.Z - ...". They were never
  in this file, and the one for the release being cut would cite the runner's local bump
  commit, which never exists on GitHub: GitHub constructs the commit that is recorded. A
  heading left with no entries goes too.

  -Generated takes cog's output as text instead of running cog, so the joining can be
  tested without a repository.
#>
[CmdletBinding()]
param(
    [string]$Path = './CHANGELOG.md',
    [string]$Generated
)

$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('Generated')) {
    # cog writes UTF-8. PowerShell decodes a native command's output with the CONSOLE's
    # encoding, which on Windows is a legacy code page: an em dash in a commit subject came
    # back as three wrong characters. Said explicitly, so it holds wherever this runs.
    $was = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $Generated = (& cog changelog) -join "`n"
    }
    finally { [Console]::OutputEncoding = $was }
    if ($LASTEXITCODE -ne 0) { throw 'cog changelog failed. Refusing to write the changelog.' }
}

$current = @((Get-Content -LiteralPath $Path -Raw -Encoding utf8) -replace "`r`n", "`n" -split "`n")
$separators = @(for ($i = 0; $i -lt $current.Count; $i++) { if ($current[$i] -eq '- - -') { $i } })
if ($separators.Count -lt 2) {
    throw "$Path needs a '- - -' line under its preamble and one above the hand-written first release."
}
$preamble = $current[0..$separators[0]]
$tail = $current[$separators[-1]..($current.Count - 1)]

# The hand-written release below the last separator replaces cog's section for it.
$handVersion = ($tail | Where-Object { $_ -match '^## (\d+\.\d+\.\d+)\s*$' } | Select-Object -First 1) -replace '^## '
if (-not $handVersion) { throw "No '## X.Y.Z' heading below the last separator of $Path." }

$lines = @(($Generated -replace "`r`n", "`n") -split "`n")
$cut = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l.StartsWith("## [v$handVersion]") })
if ($cut -lt 0) { throw "cog changelog has no section for v$handVersion; is the history complete?" }
$lines = @($lines[0..($cut - 1)] | Where-Object { $_ -notmatch '^- \(\*\*version\*\*\) v\d+\.\d+\.\d+ - ' })

# Drop a heading with no entries under it, and the separator and blank lines cog leaves
# ahead of the section that was cut.
$kept = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $lines.Count; $i++) {
    $next = if ($i + 1 -lt $lines.Count) { $lines[$i + 1] } else { '' }
    if ($lines[$i] -match '^####\s' -and $next -notmatch '^- ') { continue }
    $kept.Add($lines[$i])
}
while ($kept.Count -and ($kept[$kept.Count - 1] -eq '' -or $kept[$kept.Count - 1] -eq '- - -')) {
    $kept.RemoveAt($kept.Count - 1)
}
if (-not $kept.Count) { throw 'cog changelog produced no releases. Refusing to write the changelog.' }

$text = (@($preamble) + $kept + '' + @($tail)) -join "`n"
if (-not $text.EndsWith("`n")) { $text += "`n" }
[IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $text, [Text.UTF8Encoding]::new($false))
Write-Output "wrote $Path"
