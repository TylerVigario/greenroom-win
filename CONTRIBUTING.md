# Contributing

## The rules that are enforced

**`main` rejects direct pushes for everyone, including admins.** Branch, commit, push,
open a pull request.

The **pull request title becomes the commit message on `main`**, because merges are
squashes — so write the title as a conventional commit. The body is a free-form record
and is never linted.

Both are checked by CI rather than trusted: `pr-title` lints the title exactly as
`cog verify` would, and the branch cannot merge until every required check reports.

## Working from source

For working *on* greenroom rather than using it — a local folder as a repository, no
gallery and no network. These are PSResourceGet cmdlets, so run them **under pwsh 7**;
stock Windows PowerShell 5.1 has PowerShellGet only and does not have them.

```powershell
git clone https://github.com/TylerVigario/greenroom-win
cd greenroom-win
Get-ChildItem -Recurse | Unblock-File   # if it arrived as an archive
Register-PSResourceRepository -Name greenroom-local -Uri (Resolve-Path .) -Trusted
Publish-PSResource -Path .\Greenroom -Repository greenroom-local
Install-PSResource -Name Greenroom -Repository greenroom-local -Scope CurrentUser
```

Or copy it onto the module path, which is all the above amounts to and works on either
edition — drop the line you do not need:

```powershell
$v = (Import-PowerShellDataFile .\Greenroom\Greenroom.psd1).ModuleVersion
Copy-Item .\Greenroom "$HOME\Documents\PowerShell\Modules\Greenroom\$v" -Recurse          # pwsh 7
Copy-Item .\Greenroom "$HOME\Documents\WindowsPowerShell\Modules\Greenroom\$v" -Recurse   # 5.1
```

Installing a new version does not move a running instance onto it — see
[Upgrading the module](docs/provisioning.md#upgrading-the-module), which applies to a
source install exactly as it does to a gallery one.

## The gate

```powershell
just check          # everything CI enforces: manifest, parse, json, analyze, test
just test           # one phase
pwsh ./ci/check.ps1 # the same thing without just
```

CI runs the same phases out of the same file, one job each, so a green local run and a
green pull request mean the same thing. **The gate needs nothing but pwsh** — deliberately,
because it has to stay runnable on a host with no network and no extra tooling, which is
the situation you are in precisely when something is already broken.

Tests run on **both editions** in CI: `test-core` under pwsh 7 and `test-desktop` under
Windows PowerShell 5.1. A local run only proves the edition you ran it on.

Two things a local green does not prove, and both have bitten this repository:

- **Host dependencies.** A test that reaches a real `claude.exe`, a registered scheduled
  task, or an installed module path passes on a development machine and fails on a bare
  runner. Mock at the boundary the code actually calls.
- **The other edition.** `System.Text.Json` and `-AsHashtable` do not exist on 5.1;
  `JavaScriptSerializer` does not exist on 7.

```powershell
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path ./Greenroom -Recurse -Severity Error,Warning
```

The analyzer runs with **no settings file and no exclusions**. Where a rule genuinely does
not apply — the `lParam` that Win32's `EnumWindowsProc` delegate requires and the callback
ignores — it is suppressed at that function with the reason, so a real finding elsewhere
still fails.

## Repository layout

```
Greenroom/
  Greenroom.psd1                manifest — ModuleVersion is the only version slot
  Greenroom.psm1                loads Private then Public, exports only Public
  Greenroom.format.ps1xml       the table view for Greenroom.Instance
  Public/                       one file per exported command
  Private/                      helpers, unreachable from outside the module
  Assets/                       watchdog, launcher, vbs entry point, settings template
assets/                         package icon (repository only, not shipped in the module)
ci/check.ps1                    the gate
ci/set-manifest-version.ps1     release hook: version + that version's release notes
tests/                          Pester
docs/                           provisioning, gotchas, troubleshooting
.github/rulesets/main.json      branch protection payload, applied from the tree
CHANGELOG.md
```

`Public/` versus `Private/` is the API boundary: `Get-Command -Module Greenroom` shows
exactly the supported surface and nothing else.

The changelog records what a release contains. Iterations live in `git log` and the pull
request record — the repository is the diff.

## Releases

Releases are automated and run from `main` only. `cog bump` writes the version and that
version's release notes into the manifest, commits, tags, pushes both refs atomically,
publishes the GitHub Release, and publishes the module to the PowerShell Gallery.

Do not tag by hand. See the header of
[`.github/workflows/release.yml`](.github/workflows/release.yml) for the setup it depends
on and why each piece is there.
