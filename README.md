# greenroom-win

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

> **Status: in development.** Every `0.x` release is initial development in the
> sense semver means it — anything may change, and the surface is not stable — so
> a command that exists today may not exist, or may not behave the same way, in
> the next minor.
>
> That is enforced rather than promised: while the major is zero a breaking change
> bumps the minor, so reaching `1.0.0` cannot happen by accident. It takes someone
> deciding the surface is worth keeping.
>
> `1.0.0` will mean the surface has stopped moving, not that the feature list is
> finished — a condition to be met rather than a date to arrive at.

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

**Before a real install, read [docs/provisioning.md](docs/provisioning.md).** Two
prerequisites fail *silently* if unmet — a CLI without `--remote-control`, and
`defaultShell: "bash"` on a host where `bash` does not resolve. The installer checks
both, but knowing why matters when something is off.

Then confirm it for yourself — a green line from the installer does not prove the
things it cannot observe: [docs/troubleshooting.md](docs/troubleshooting.md#did-it-actually-work).

---

## Scope

Everything needed to stand an instance up lives here, and the installer does as much
of it as it can without being asked twice.

**One thing is deliberately not here: memory.** What an instance should *know* is
personal and specific to whoever runs it — it does not belong in a repository that
anyone can clone, and it is conveyed separately.

Everything else — settings shape, host prerequisites, branch protection payload — is
in the tree.

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

The name can be omitted **when exactly one instance is installed** — for the visibility
commands, `Restart-`, `Start-` and `Stop-`. `Start-`, `Stop-` and `Restart-` also take wildcards, matched against registered instances:
`Stop-GreenroomSession *`, `Restart-GreenroomSession render-*`. The other two differ, deliberately: `Update-GreenroomInstance`
with no name updates **every** instance whose assets are behind, and `Uninstall-` always
requires `-Name`, because removing the wrong instance is not a mistake worth making
convenient.

`Show-` and `Hide-` are approved verbs and they are also literally what happens: the
window exists the whole time and these call `ShowWindow` on it. "Attach" was always a
euphemism for a visibility toggle.

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

`Stop-` is the one that had no answer before: `Hide-` only moves the window and the
process keeps its handles, `Restart-` brings it straight back, and `Uninstall-` removes
the instance. It stops the watchdog, the session and the launcher, then watches for a few
seconds to confirm nothing put the session back — a supervisor that was missed would
otherwise leave three successful-looking kill counts and a running session. The scheduled
task is stopped but **not disabled**, so the instance returns at the next logon, or when
you run `Start-GreenroomSession`. `Start-` is the only one of these that never kills
anything: an instance that is already running is returned as it is.

The case it exists for is upgrading the Claude Code CLI, which every session holds open —
see [Troubleshooting](docs/troubleshooting.md#upgrading-the-claude-code-cli).

Every state-changing command supports `-WhatIf` and `-Confirm`. `-Verbose` explains
what a command decided and why, including the specific reason a window could not be
resolved.

Uninstalling never touches the working directory, and leaves trust entries in
`~/.claude.json` in place. `-KeepState` also keeps `~/.claude/greenroom/<instance>`.

No PATH entry, no shim, no profile change: the module resolves by name once it is on
the module path.

---

## Instance options

| Parameter | |
|---|---|
| `-Name` | required; 1–32 chars, letters/digits/`.`/`-`/`_`, **no spaces** |
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
working directory used to relocate the instance and abandon its project store.
Clearing is explicit — `-AdditionalDirectories @()`, `-ClaudeExe ''`.

---

## How it works

```
Task Scheduler  (at logon, +delay, Interactive, no elevation)
  └── wscript.exe greenroom-watchdog.vbs <instance>        ← born hidden, SW_HIDE
        └── <shell> greenroom-watchdog.ps1 -Instance <name> ← supervisor, 1s poll
              └── wt.exe -w new  (hidden)
                    └── <shell> greenroom-launch.ps1 -Instance <name>
                          └── claude.exe --remote-control <name> [--add-dir ...]
```

`<shell>` is pwsh 7 where it is installed, otherwise the in-box Windows PowerShell 5.1
(`powershell.exe`) — resolved per host, pwsh preferred.

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
more than 5 restarts in 5 minutes triggers a 2-minute backoff. Measured recovery
after a kill on the reference host was ~1.4 s.

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
