# greenroom-win

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/Greenroom?label=PowerShell%20Gallery)](https://www.powershellgallery.com/packages/Greenroom)
[![CI](https://github.com/TylerVigario/greenroom-win/actions/workflows/ci.yml/badge.svg)](https://github.com/TylerVigario/greenroom-win/actions/workflows/ci.yml)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

Always-on **Claude Code Remote Control** sessions on Windows. Each instance starts
hidden at logon, stays supervised, and is revealed on demand with its full live
scrollback — not a resumed copy.

![Show-GreenroomSession revealing a hidden session, then hiding it again](assets/greenroom-demo.gif)

*Running since logon, never on screen. One command reveals it, another puts it away — it
keeps running either way.*

A green room is where the performer waits: always there, out of sight, called on
stage the moment you want them.

Several instances run side by side on one host, each with its own working
directory, its own directory grants, and its own name in the Remote Control UI.

> **Status: in development.** `0.x` is initial development in the sense semver
> means it: a command that exists today may not exist, or may not behave the same
> way, in the next minor. While the major is zero a breaking change bumps the
> minor, so `1.0.0` cannot arrive by accident — it will mean the surface has
> stopped moving, not that the feature list is finished.

---

## Quick start

```powershell
Install-PSResource Greenroom -TrustRepository        # pwsh 7
Install-GreenroomInstance -Name desktop-admin
Get-GreenroomInstance
```

That is the whole procedure. `Install-GreenroomInstance` resolves the right
`claude.exe`, asserts the flag it depends on, checks the host settings that fail
silently, seeds trust, registers the logon task, starts the session and verifies what
it can observe. `Import-Module` is not needed — the commands auto-load.

On **Windows PowerShell 5.1** the module install is two lines instead of one, because
Windows ships no NuGet provider:

```powershell
Install-PackageProvider NuGet -Force -Scope CurrentUser   # once per host
Install-Module Greenroom -Scope CurrentUser -Force
```

**Before a real install, read [docs/provisioning.md](docs/provisioning.md).** Three
prerequisites fail *silently* if unmet — a CLI without `--remote-control`,
`defaultShell: "bash"` on a host where `bash` does not resolve, and credentials that
are not a full `claude.ai` login: Remote Control rejects `claude setup-token` and says
nothing about it. **The installer checks the first two and cannot check the third** —
run `claude` once in the working directory, `/login`, and confirm `/rc active` appears
in the footer.

Then confirm it for yourself — a green line from the installer does not prove the
things it cannot observe: [docs/troubleshooting.md](docs/troubleshooting.md#did-it-actually-work).

### Verifying where it came from

Each release's package is attested: a signed record, in a public transparency log, of the
workflow, commit and run that built it. The gallery serves the package exactly as it was
published, so the file you install can be checked against that record:

```powershell
Save-PSResource Greenroom -Version <version> -AsNupkg -Path . -TrustRepository
gh attestation verify .\Greenroom.<version>.nupkg --repo TylerVigario/greenroom-win
```

The same file is attached to the version's [GitHub Release](https://github.com/TylerVigario/greenroom-win/releases),
so comparing hashes works without `gh` as well. Releases before attestation was added carry
no attestation.

---

## Use

```powershell
Get-GreenroomInstance                             # what is running
Show-GreenroomSession    desktop-admin            # reveal it
Hide-GreenroomSession    desktop-admin            # put it away, session keeps running
Switch-GreenroomSession  desktop-admin            # whichever it is not
Restart-GreenroomSession desktop-admin
Start-GreenroomSession   desktop-admin            # bring a stopped one back; a running one is left alone
Stop-GreenroomSession    desktop-admin            # down until you start it, or the next logon
Update-GreenroomInstance                          # after a module upgrade
Uninstall-GreenroomInstance -Name desktop-admin
```

The name can be omitted when there is exactly one candidate, and what counts as a
candidate follows what the command acts on:

- **`Show-`, `Hide-`, `Switch-`** — exactly one **running** instance, since they act on its
  window.
- **`Start-`, `Stop-`, `Restart-`** — exactly one **registered** instance (one scheduled
  task), since a stopped instance has no window to find. These three also take wildcards,
  matched against registered instances: `Stop-GreenroomSession *`,
  `Restart-GreenroomSession render-*`.

The other two differ, deliberately: `Update-GreenroomInstance` with no name updates
**every** instance whose assets are behind, and `Uninstall-` always requires `-Name`,
because removing the wrong instance is not a mistake worth making convenient.

**`Get-GreenroomInstance` emits objects**, so the listing feeds the actions:

```powershell
Get-GreenroomInstance | Where-Object { -not $_.Visible } | Show-GreenroomSession
Get-GreenroomInstance | Where-Object Elevated
Get-GreenroomInstance | Where-Object { $null -eq $_.Window } | Restart-GreenroomSession
```

`Show-`, `Hide-` and `Switch-` return **nothing** — they are `System.Void`, so a pipeline
ends at them. `Restart-` and `Start-` return the instance they brought up, and so does `Install-`
— except under `-NoStart`, where there is no session to hand back and it returns an
install result instead. `Uninstall-` and `Stop-` return result objects. When you want
state after a visibility change, ask for it: `Show-GreenroomSession x; Get-GreenroomInstance x`.

`Stop-` takes the watchdog, the session and the launcher down together, then watches
for a few seconds to confirm nothing put the session back — a supervisor that was
missed would otherwise leave three successful-looking kill counts and a running
session. The task is stopped but **not disabled**, so the instance returns at the next
logon or on `Start-GreenroomSession`. The case it exists for is upgrading the Claude
Code CLI, which every session holds open — see
[Troubleshooting](docs/troubleshooting.md#upgrading-the-claude-code-cli).

Every state-changing command supports `-WhatIf` and `-Confirm`. `-Verbose` explains
what a command decided and why, including the specific reason a window could not be
resolved.

Uninstalling never touches the working directory, and leaves trust entries in
`~/.claude.json` in place — `claude purge <dir>` is what removes those, both slash
forms in one pass, and `--dry-run` prints the plan first. Read that plan: on a
directory a session has worked in it also takes the transcripts and `memory/`.
`-KeepState` also keeps `~/.claude/greenroom/<instance>`.

No PATH entry, no shim, no profile change: the module resolves by name once it is on
the module path.

---

## Instance options

| Parameter | |
|---|---|
| `-Name` | required; 1–32 chars, letters/digits/`.`/`-`/`_`, not ending in `.`, **no spaces** |
| `-WorkingDirectory` | inherited on a re-run; `%USERPROFILE%\<name>` on a first install |
| `-AdditionalDirectories` | per-instance grants, **default none** |
| `-TriggerDelay` | logon delay, default `PT1M` |
| `-ClaudeExe` | override CLI detection |
| `-Model` | model this instance launches with, e.g. `opus`; inherited on a re-run, `''` clears |
| `-Elevated` | run the session as admin, **default off** — see [provisioning](docs/provisioning.md#elevated-instances) |
| `-NoTrustSeed`, `-NoStart` | skip those steps |
| `-WhatIf`, `-Confirm` | as with every state-changing command here |

Idempotent — re-run any time. It will not kill a running session; new config applies
at the next restart.

**Omitting a parameter INHERITS it** from the previous install rather than falling
back to a default. That is load-bearing, not a nicety: a bare re-run that reset the
working directory to a default would relocate the instance and abandon its project
store. Clearing is explicit — `-AdditionalDirectories @()`, `-ClaudeExe ''`.

---

## How it works

```
Task Scheduler  (at logon, +delay, Interactive, non-elevated by default)
  └── wscript.exe greenroom-watchdog.vbs <instance>        ← born hidden, SW_HIDE
        └── <shell> greenroom-watchdog.ps1 -Instance <name> ← supervisor, 1s poll
              └── wt.exe -w new --title <token>  (hidden)   ← names the new window
                    └── <shell> greenroom-launch.ps1 -Instance <name>
                          └── claude.exe --remote-control <name> --name <name>
                                         [--add-dir ...] --resume <id>
```

`<shell>` is pwsh 7 where it is installed, otherwise the in-box Windows PowerShell 5.1
(`powershell.exe`) — resolved per host, pwsh preferred.

**`--resume <id>` is what makes these *always-on* rather than *restarted*.** The
launcher pins one conversation id and resumes that exact id on every launch after the
first, so a crashed session or a rebooted host comes back to the same conversation
instead of a fresh one. Reaching for the newest conversation instead would quietly
adopt one somebody started by hand in the same directory.

**`--title <token>` is how the watchdog knows which window it just made.** Windows
Terminal hosts every window in one process and exposes no mapping back to the process
inside, so two instances starting in the same second are otherwise indistinguishable
— [gotchas.md §4](docs/gotchas.md).

| Path | |
|---|---|
| `<module path>\Greenroom\` | the module — the commands you type |
| `<module path>\Greenroom\Assets\` | watchdog, launcher, vbs entry point — task-invoked, never by you |
| `%USERPROFILE%\.claude\greenroom\<instance>\config.json` | resolved paths and grants |
| `%USERPROFILE%\.claude\greenroom\<instance>\session.json` | the recorded window handle |
| `%USERPROFILE%\.claude\greenroom\<instance>\watchdog.log` | supervisor log |
| `%USERPROFILE%\.claude\greenroom\<instance>\launch.log` | per-session launch log |

The `.vbs` finds the watchdog next to itself and the watchdog finds the launcher next
to itself, so the whole chain relocates with the module and the registered task points
into wherever it was installed.

The watchdog polls once a second and restarts a dead session. Crash-loop guard:
more than 5 restarts in 5 minutes triggers a 2-minute backoff. Measured on the
reference host, three kills: recovery to a new session in 1.1 s, 1.2 s and 1.8 s.

**`claude --bg` does not replace any of this.** The CLI grew background sessions of
its own, so the question is fair, and the answer is measured against 2.1.322: there
is one daemon per user and it holds one integrity level, so on a host mixing elevated
and unelevated instances the elevated one either stops the others from starting or is
silently de-elevated, depending only on which started first. Nothing starts the daemon
at logon either. [Issue #103](https://github.com/TylerVigario/greenroom-win/issues/103)
has both directions.

---

## Documentation

| Document | What is in it |
|---|---|
| [docs/provisioning.md](docs/provisioning.md) | what a host needs and why each item is a requirement — plus elevated instances, multiple instances, and upgrading |
| [docs/gotchas.md](docs/gotchas.md) | **the part worth reading** — what does not behave the way it obviously should, and what never got cleanly resolved |
| [docs/troubleshooting.md](docs/troubleshooting.md) | symptoms, logs, and how to confirm an install actually worked |
| [CONTRIBUTING.md](CONTRIBUTING.md) | working from source, the gate, repository layout, releases |

If you are porting the concept elsewhere, start with the gotchas; the scripts are
disposable, that reasoning is not.

---

## License

**GNU Affero General Public License v3.0 or later** — see [LICENSE](LICENSE).

Copyright © 2026 Tyler Vigario.

Use it, modify it, break it, run it in production, charge for installing and
supporting it. What you may not do is take it closed. Modifications you distribute
come back under the same terms, so the next person who wants to tinker with it can.

That is the whole intent: earning a living with this is fine, enclosing it is not.

Third-party marks are the property of their owners. This project is not affiliated
with or endorsed by Anthropic.
