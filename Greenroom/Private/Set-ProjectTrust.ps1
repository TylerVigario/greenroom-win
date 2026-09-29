# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

# The two JSON stacks meet here, and nowhere else in the module. They are mutually
# exclusive across editions: JavaScriptSerializer is absent from .NET Core (pwsh 7), and
# -AsHashtable / System.Text.Json are absent from .NET Framework (Windows PowerShell 5.1).
# ~/.claude.json can carry keys differing only in drive-letter case, so the plain object
# parser (ConvertFrom-Json without -AsHashtable) is unusable on both. Every edition
# divergence in the module lives in these two helpers.

<#
  Is $Raw well-formed JSON, judged as strictly as the parser that actually reads the file?
  Both editions reject a trailing comma, which Node -- and so Claude Code -- reject.
#>
function Test-ClaudeJsonValid {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)
    try {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Add-Type -AssemblyName System.Web.Extensions
            $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $js.MaxJsonLength = [int]::MaxValue
            $null = $js.DeserializeObject($Raw)
        }
        else {
            [System.Text.Json.JsonDocument]::Parse($Raw).Dispose()
        }
        $true
    }
    catch { $false }
}

<#
  Parse ~/.claude.json's "projects" object into an indexable map, or $null if absent.
  Case-sensitive, and the two slash forms read as distinct keys -- verified on both
  editions. Throws on malformed JSON, which the caller must not confuse with "trust absent".
#>
function Read-ClaudeProjectMap {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -AssemblyName System.Web.Extensions
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $js.MaxJsonLength = [int]::MaxValue
        $root = $js.DeserializeObject($Raw)
    }
    else {
        $root = $Raw | ConvertFrom-Json -AsHashtable
    }
    # Both parsers return an IDictionary for a JSON object (Dictionary on 5.1, Hashtable on
    # 7). Anything else -- an array, a null, a bare value -- carries no projects map, so
    # return $null rather than let a .ContainsKey() on a non-dictionary throw.
    if ($root -is [System.Collections.IDictionary] -and $root.ContainsKey('projects')) {
        $projects = $root['projects']
        if ($projects -is [System.Collections.IDictionary]) { return $projects }
    }
    return $null
}

<#
  Whether a parsed projects map trusts a directory in BOTH path forms: a key equal to
  each form, case and all, holding an object whose hasTrustDialogAccepted is true. The one
  definition of "trusted" -- the seed and the post-launch check both use it, so they
  cannot disagree about what the seed has to achieve.
#>
function Test-ProjectMapTrusted {
    param([System.Collections.IDictionary]$Projects, [Parameter(Mandatory)][string]$Directory)
    if (-not $Projects) { return $false }
    foreach ($f in (@($Directory.Replace('/', '\'), $Directory.Replace('\', '/')) | Select-Object -Unique)) {
        if (-not (Test-ProjectEntryTrusted $Projects $f)) { return $false }
    }
    return $true
}

function Test-ProjectEntryTrusted {
    param([System.Collections.IDictionary]$Projects, [Parameter(Mandatory)][string]$Key)
    # Guard the entry as well: a hand-edited project value that is not an object, or is
    # missing the flag, is "not trusted" rather than a reason to throw indexing into it.
    if (-not $Projects.ContainsKey($Key)) { return $false }
    $entry = $Projects[$Key]
    if ($entry -isnot [System.Collections.IDictionary] -or -not $entry.ContainsKey('hasTrustDialogAccepted')) { return $false }
    return [bool]$entry['hasTrustDialogAccepted']
}

<#
  JSON TEXT, WALKED BY TOKEN. The seed edits ~/.claude.json as text (see Set-ProjectTrust),
  so it needs to find things in that text exactly: a direct member of one object, never the
  same characters somewhere else in the file. A regex steps from string to bracket, so the
  loop runs per token rather than per character, and a brace inside a string is never
  mistaken for structure.
#>
$script:JsonToken = [regex]'"(?:[^"\\]|\\.)*"|[{}\[\]]'

# Index of the bracket closing the object or array that opens at $Open.
function Find-JsonClose {
    param([string]$Text, [int]$Open)
    $depth = 0
    for ($m = $script:JsonToken.Match($Text, $Open); $m.Success; $m = $m.NextMatch()) {
        $c = $m.Value[0]
        if ($c -eq '{' -or $c -eq '[') { $depth++ }
        elseif ($c -eq '}' -or $c -eq ']') { $depth--; if ($depth -eq 0) { return $m.Index } }
    }
    return -1
}

# The value of the DIRECT member $RawKey (its text between the quotes, escapes and case as
# written) of the object opening at $Open: @{ Start; End } with End exclusive, or $null.
function Find-JsonMember {
    param([string]$Text, [int]$Open, [string]$RawKey)
    $depth = 0
    for ($m = $script:JsonToken.Match($Text, $Open); $m.Success; $m = $m.NextMatch()) {
        $c = $m.Value[0]
        if ($c -eq '{' -or $c -eq '[') { $depth++; continue }
        if ($c -eq '}' -or $c -eq ']') { $depth--; if ($depth -eq 0) { return $null }; continue }
        if ($depth -ne 1) { continue }
        $colon = ([regex]'\G\s*:\s*').Match($Text, $m.Index + $m.Length)
        if (-not $colon.Success -or $m.Value.Substring(1, $m.Value.Length - 2) -cne $RawKey) { continue }
        $start = $colon.Index + $colon.Length
        if ($Text[$start] -eq '{' -or $Text[$start] -eq '[') {
            return @{ Start = $start; End = (Find-JsonClose $Text $start) + 1 }
        }
        $scalar = ([regex]'\G(?:"(?:[^"\\]|\\.)*"|[^,}\]\s]+)').Match($Text, $start)
        return @{ Start = $start; End = $start + $scalar.Length }
    }
    return $null
}

<#
  Seed Claude Code's trust for a working directory, so the session does not stop at a
  modal trust dialog inside a window nobody can see.

  Claude Code keys project state on the LITERAL cwd string, so 'C:\x' and 'C:/x' are
  separate entries with independent trust. Both forms are seeded; that mismatch is what
  made an earlier setup re-prompt on every start.

  TEXT SURGERY, NOT ROUND-TRIPPING, and deliberately. ~/.claude.json belongs to another
  application: it can contain keys differing only in drive-letter case, which the object
  parser rejects outright, and re-serialising it would reorder and reshape a file
  greenroom does not own. The insert is validated as JSON before anything is written,
  and the original is backed up first.

  This is the only file outside greenroom's own directories that installing writes.
#>
function Set-ProjectTrust {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BackupDir
    )

    $file = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $file)) {
        Write-Warning 'no ~/.claude.json yet -- run `claude` once, then install again'
        return $false
    }

    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $backup = Join-Path $BackupDir ('claude.json.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item $file $backup -Force

    $raw = Get-Content $file -Raw
    # WHAT IS TRUSTED IS DECIDED FROM THE PARSED FILE, the way Claude Code reads it: a
    # "projects" key equal to the path form, case and all, with the flag true. Searching
    # the text for the quoted path was not that. It found the path as a value elsewhere
    # (githubRepoPaths), found an entry whose dialog was never accepted, and found another
    # case of the same path -- and skipped the seed each time, leaving a hidden session at
    # the trust dialog.
    try { $projects = Read-ClaudeProjectMap $raw }
    catch {
        Write-Warning "~/.claude.json does not parse ($($_.Exception.Message)) -- leaving it untouched"
        return $false
    }
    $root = $raw.IndexOf('{')
    $span = if ($root -ge 0) { Find-JsonMember $raw $root 'projects' }
    if (-not $projects -or -not $span -or $raw[$span.Start] -ne '{') {
        Write-Warning 'no "projects" block in ~/.claude.json -- skipping trust seed'
        return $false
    }

    $targets = @($Directory.Replace('/', '\'), $Directory.Replace('\', '/')) | Select-Object -Unique
    $seeded = $false
    foreach ($t in $targets) {
        if (Test-ProjectEntryTrusted $projects $t) { continue }
        $jsonKey = $t.Replace('\', '\\')
        # Offsets move with every edit, so the projects object is found afresh each pass.
        $open  = (Find-JsonMember $raw $root 'projects').Start
        $entry = Find-JsonMember $raw $open $jsonKey

        if ($entry -and $raw[$entry.Start] -eq '{') {
            # The entry exists -- `claude` was run here once and the dialog never accepted.
            # Accept it in place and leave everything else in the entry alone.
            $flag = Find-JsonMember $raw $entry.Start 'hasTrustDialogAccepted'
            if ($flag) {
                $raw = $raw.Substring(0, $flag.Start) + 'true' + $raw.Substring($flag.End)
            }
            else {
                $emptyEntry = $raw.Substring($entry.Start + 1) -match '^\s*\}'
                $raw = $raw.Substring(0, $entry.Start + 1) + ' "hasTrustDialogAccepted": true' +
                       $(if ($emptyEntry) { ' ' } else { ',' }) + $raw.Substring($entry.Start + 1)
            }
        }
        elseif ($entry) {
            Write-Warning "~/.claude.json holds a project entry for '$t' that is not an object -- leaving it untouched"
            return $false
        }
        else {
            $insertAt = $open + 1

            # An EMPTY projects object takes no trailing comma. Inserting one after the `{`
            # of `"projects": {}` produces `{ "x": {...},}`, which Node -- the parser that
            # actually reads this file -- rejects outright, taking Claude Code with it.
            #
            # Recomputed each pass, because after the first entry the object is no longer
            # empty and the second one does need its comma.
            $isEmpty = $raw.Substring($insertAt) -match '^\s*\}'
            $comma = if ($isEmpty) { '' } else { ',' }

            $newEntry = @"

    "$jsonKey": {
      "allowedTools": [],
      "mcpContextUris": [],
      "mcpServers": {},
      "enabledMcpjsonServers": [],
      "disabledMcpjsonServers": [],
      "hasTrustDialogAccepted": true,
      "projectOnboardingSeenCount": 0,
      "hasClaudeMdExternalIncludesApproved": false,
      "hasClaudeMdExternalIncludesWarningShown": false,
      "exampleFiles": []
    }$comma
"@
            $raw = $raw.Substring(0, $insertAt) + $newEntry + $raw.Substring($insertAt)
        }
        $seeded = $true
    }

    if (-not $seeded) {
        Write-Verbose 'trust already present for both path forms'
        return $true
    }

    # VALIDATE WITH THE SAME STRICTNESS AS THE PARSER THAT READS THIS FILE. Node -- and so
    # Claude Code -- reject a trailing comma, which a bad insert could produce; Test-ClaudeJsonValid
    # rejects it too, on both editions. (Plain ConvertFrom-Json is not a safe guard: on pwsh 7
    # it ACCEPTS the trailing comma Node rejects, and on 5.1 it dies on the drive-letter-case
    # keys this file can carry. The edition-aware helper is strict and case-tolerant on both.)
    if (-not (Test-ClaudeJsonValid $raw)) {
        Write-Warning 'refusing to write ~/.claude.json -- the seeded result was not valid JSON'
        return $false
    }
    # And it must be what the post-launch check will ask for. Written only if it is.
    if (-not (Test-ProjectMapTrusted (Read-ClaudeProjectMap $raw) $Directory)) {
        Write-Warning 'refusing to write ~/.claude.json -- the seeded result would still not trust the directory'
        return $false
    }

    Set-Content -Path $file -Value $raw -Encoding UTF8 -NoNewline
    Write-Verbose "trust seeded (backup at $backup)"
    return $true
}

<#
  Whether trust for a directory is present RIGHT NOW, in both path forms.

  Worth re-checking after launch rather than assuming: on any host with Claude Desktop
  there are always other claude.exe processes, and any of them can rewrite
  ~/.claude.json between the seed and the launch. The consequence is a modal dialog in
  a window nobody can see, which reads as "it hangs for no reason".
#>
function Test-TrustSurvived {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Directory)

    $file = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $file)) { return $false }

    # This is a boolean predicate and must never throw: Install-GreenroomInstance calls it
    # without a try/catch, so an exception here would ABORT the install instead of letting
    # it re-seed. A READ failure is environmental -- quiet $false, the caller re-seeds. A
    # PARSE failure is a real anomaly, so it is surfaced (Write-Warning, not silently
    # swallowed the way the old blanket catch was) and still reported as not-survived. The
    # 5.1 -AsHashtable bind error that old catch used to hide is gone now that Read-ClaudeProjectMap
    # is edition-aware.
    $raw = try { Get-Content $file -Raw -ErrorAction Stop } catch { return $false }
    $projects = try { Read-ClaudeProjectMap $raw }
                catch { Write-Warning "~/.claude.json did not parse while verifying trust for '$Directory': $($_.Exception.Message)"; return $false }
    return (Test-ProjectMapTrusted $projects $Directory)
}

<#
  Mirror an instance's directory grants into its PROJECT settings, so a session started
  by hand in that directory gets the same scope as the supervised one.

  Merged, never clobbered: the file may hold settings that are nothing to do with us.
#>
function Set-ProjectGrant {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string[]]$Grants = @()
    )

    $dir  = Join-Path $Directory '.claude'
    $file = Join-Path $dir 'settings.json'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $obj = $null
    if (Test-Path $file) {
        try { $obj = Get-Content $file -Raw | ConvertFrom-Json }
        catch { Write-Warning "$file exists but is not valid JSON -- leaving it untouched"; return }
    }
    if (-not $obj) { $obj = [PSCustomObject]@{} }

    if (-not $obj.PSObject.Properties['permissions']) {
        $obj | Add-Member -NotePropertyName permissions -NotePropertyValue ([PSCustomObject]@{})
    }
    if ($obj.permissions.PSObject.Properties['additionalDirectories']) {
        $obj.permissions.additionalDirectories = @($Grants)
    }
    else {
        $obj.permissions | Add-Member -NotePropertyName additionalDirectories -NotePropertyValue @($Grants)
    }

    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
    Write-Verbose "project settings: $file"
}
