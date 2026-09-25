# Host provisioning

What a host needs before an instance will run, and why each item is a requirement
rather than a preference.

`Install-GreenroomInstance` checks everything on this page and refuses or warns rather than
letting you build a setup that fails silently. Every failure in this architecture is
invisible, because the window is hidden, so a check that runs at install time is
worth far more than a note telling you to look.

`Greenroom/Assets/settings.template.json` carries the shape of a working
`%USERPROFILE%\.claude\settings.json`, with the reasoning for each key inline. Fill
in your own values — the template ships none.

---

## Prerequisites

| | |
|---|---|
| Windows | 10 or 11 |
| PowerShell | **5.1+** — in-box Windows PowerShell suffices; pwsh 7 preferred, see below |
| NuGet provider | **5.1 only, once per host** — `Install-PackageProvider NuGet -Force -Scope CurrentUser` |
| Windows Terminal | **required** — see [gotchas](gotchas.md#2-do-not-use-conhost-to-dodge-1) |
| Claude Code CLI | must support `--remote-control [name]` |
| claude.ai login | full `/login`, not `claude setup-token` |

### The NuGet provider, on 5.1 only

Measured on a stock host: **Windows PowerShell 5.1 ships PowerShellGet 1.0.0.1 but no
NuGet provider**, and PSGallery is registered `Untrusted`. So its first gallery install
tries to bootstrap the provider, which prompts — and in a non-interactive shell the prompt
has nothing to prompt, so it fails with `Exception calling "ShouldContinue"` rather than
anything that names the cause. Install the provider once and it never recurs:

```powershell
Install-PackageProvider NuGet -Force -Scope CurrentUser
```

pwsh 7 needs none of this: it ships `Microsoft.PowerShell.PSResourceGet` and reaches the
gallery unaided.

`Untrusted` is the shipped default for PSGallery on both editions, not something set on
your host, and it applies to **every** package from the gallery — the gallery takes no
submission and reviews nothing, which is exactly why publishing to it needs no approval.
Answer the prompt with `-TrustRepository` / `-Force` per install, or mark it trusted for
everything — the cmdlet differs by edition, because stock 5.1 has PowerShellGet and no
PSResourceGet:

```powershell
Set-PSResourceRepository -Name PSGallery -Trusted                # pwsh 7
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted     # 5.1
```

### PowerShell version

Greenroom runs on **Windows PowerShell 5.1 or PowerShell 7**. The manifest declares
`PowerShellVersion = '5.1'` and `CompatiblePSEditions = 'Core', 'Desktop'`, and the module
imports and passes its full test suite on both. 5.1 is the floor because it **ships in-box
on every Windows host** — nothing to install — and running on a stock machine is the whole
point of the project.

**pwsh 7 is preferred, not required.** The installer and the logon `.vbs` resolve a shell
the same way: pwsh 7 first — WinGet's version-independent alias, then the install path —
and Windows PowerShell 5.1 only when no pwsh 7 is found. On a host with pwsh 7 nothing
changes; on one without, the in-box shell carries the session.

Prefer pwsh 7 where you can. It is the actively developed edition; 5.1 is frozen and takes
security fixes but no features, and any pwsh 7 you do run should itself be a
[supported release](https://learn.microsoft.com/powershell/scripting/install/powershell-support-lifecycle).
Greenroom is written to run identically on both, and the one place the editions genuinely
diverge — parsing `~/.claude.json`, which can hold keys differing only in drive-letter
case — is isolated behind two helpers (`JavaScriptSerializer` on 5.1, `System.Text.Json`
and `-AsHashtable` on 7) that the tests exercise under each edition.

PowerShell 7 is **not part of Windows** and never arrives through Windows Update. Windows
ships Windows PowerShell 5.1, a separate product on the Windows lifecycle. `pwsh` is always
an explicit install, so "the host is fully updated" says nothing about whether it has
PowerShell 7 at all — which is exactly why the floor is the shell that is always present.

### CLI version

`--remote-control [name]` is absent in 2.1.92 and present from 2.1.218. Launching
without it kills the session instantly inside a hidden window; the watchdog restarts
it, the crash-loop guard trips, and nothing surfaces anywhere. This is the worst
failure mode in the design, so `Install-GreenroomInstance` asserts the flag before registering
anything.

Note `--remote-control-session-name-prefix` is a **different** flag that exists on
builds lacking the one you need. A bare substring check passes on those.

### Which `claude.exe`

A host with Claude Desktop installed has several. **PATH decides**: resolution is
`-ClaudeExe` → PATH order → `~\.local\bin`. Whatever `claude` runs in your own shell is
what the supervised session runs. Whichever path wins is deliberately not resolved through
its symlink, which would bake in a versioned target that breaks on the next update.

`~\.local\bin` is a last resort only, for a native install whose directory is not on PATH.

greenroom does not install Claude Code and does not rank the ways it can be installed.
That is why there is no source setting: the list would have to track someone else's
distribution matrix — native, npm, WinGet, two Homebrew casks, apt, dnf, apk — and PATH
already encodes your answer.

> Until 0.4.0 a hard-coded WinGet Links entry came first, on the grounds that its path is
> keyed on package ID rather than version and so survives upgrades. True, but every Windows
> install path for this CLI is version-stable, so it bought nothing — while silently
> outranking newer installs. A package-manager install caps itself at whatever the manifest
> offers, which `claude doctor` reports as `Auto-updates: Managed by package manager`, so a
> host with both ran the one that could not update itself.

Excluded as never-valid targets: `Program Files\WindowsApps` (Store Desktop),
`AnthropicClaude` (standalone Desktop), and `AppData\Roaming\Claude\claude-code`
(Desktop's private bundled CLI).

Override with `-ClaudeExe` if your layout is unusual — that is the escape hatch, and it is
the only thing that outranks PATH. Passing it records `claudeExeExplicit`, so re-runs keep
it; `-ClaudeExe ''` clears it and returns to PATH resolution.

### Login

Remote Control requires a full claude.ai login. `claude setup-token` credentials are
rejected, and the rejection is silent in a hidden window. Run `claude` once
interactively, `/login`, then confirm `/rc active` appears in the footer after the
supervised session starts.

---

## Upgrading the module

**Installing a new module version does not move a running instance to it.** An upgrade is
two steps, and only the first belongs to whatever delivered the module:

```powershell
Update-PSResource Greenroom     # pwsh 7   -- or however the module got here
Update-Module Greenroom         # 5.1      -- PowerShellGet, not PSResourceGet
Update-GreenroomInstance        # move the instances onto it
```

`Update-GreenroomInstance` re-registers every instance whose assets are behind and restarts
it. `-WhatIf` reports which are behind without touching them, `-Name` narrows it, and
`-NoRestart` re-registers without interrupting the running session — the new assets then
start with the next one.

It reports one row per instance, including the ones it left alone, so a run that changed
nothing is distinguishable from one that moved everything:

```
Instance             Action       From       To          ClaudePid
--------             ------       ----       --          ---------
laptop-admin         Updated      0.4.0      0.5.0           17096
render-a             Current      0.5.0      0.5.0
```

`Action` is `Updated`, `Registered` (re-registered under `-NoRestart`, still running the old
code), `Current`, `Unversioned` (a path carrying no version, left alone) or `Failed`.

By hand, per instance, it is:

```powershell
Install-GreenroomInstance -Name <name> -NoStart   # rewrites the task and config.json
Restart-GreenroomSession  <name>
```

`Install-` is idempotent and inherits every parameter it is not given, so this is safe to
re-run and does not need the original arguments. **The task and `config.json` must move
together** — that is why re-registering is the upgrade step rather than copying assets over
the old ones — and doing it in one call is what guarantees a new watchdog never reads an
old config.

The reason is that the scheduled task records the **versioned** asset path —
`…\Modules\Greenroom\<version>\Assets\greenroom-watchdog.vbs` — because that is where the
module registering it lives. Module versions install side by side, so after staging a new
one:

- `Import-Module` and `Get-Module` resolve the **newest** version and report it
- the task keeps launching the **old** version's watchdog and launcher
- **`Restart-GreenroomSession` does not help.** It re-runs the task, and the task is what
  still names the old path

Nothing errors, and every version readout agrees with the version you meant to be running.
This was found on a host where a restart appeared to complete an upgrade and did not.

`Get-GreenroomInstance` shows the version each task runs in its `AssetVersion` column, and
warns when it differs from the loaded module, so the condition is visible rather than silent:

```
WARNING: module 0.2.0 is loaded but laptop-admin runs 0.1.0. A version bump does not reach
an instance until it is re-registered, because the task names the versioned asset path...
```

`Restart-GreenroomSession` warns for the same reason **before** it stops anything, since a
restart at that point brings the old version straight back up.

`AssetVersion` is read from the **task**, so it confirms what the next start will run. To
confirm what is running *now* — after a restart that may not have completed — read the live
processes instead:

```powershell
(Get-ScheduledTask greenroom-<name>).Actions.Arguments
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
    Where-Object CommandLine -match 'greenroom-watchdog' | Select-Object -Expand CommandLine
```

Removing an old module version while an instance still points at it leaves the task naming
a file that does not exist: `wscript.exe` exits and no session starts. Re-register first,
then prune.

---

## If `defaultShell` is `bash`

This is the one host setting greenroom inspects, and only because getting it wrong
breaks the supervised session invisibly — not because greenroom has an opinion about
your configuration.

Git for Windows puts `<git-root>\cmd` and `<git-root>\mingw64\bin` on PATH.
**Neither contains `bash.exe`.** So a stock Git install satisfies `git` and fails
`bash`, and if `defaultShell` is `bash`, every Bash tool call then fails silently.

Add **`<git-root>\bin`** to your user PATH — it contains exactly three files:
`bash.exe`, `git.exe`, `sh.exe`.

Do **not** add `<git-root>\usr\bin`. It also contains bash, which makes it look
correct, but it is several hundred files that shadow Windows `echo`, `expand`,
`find`, `link`, `sort`, `tee`, and `timeout`.

### Verifying, and the false negative

A shell spawned from an existing process inherits a **stale environment block**, so
checking from the terminal you just made the change in — or from anything an agent
spawns — reports failure even when the registry is correct.

Verify from a terminal opened fresh from Explorer or the Start menu:

```powershell
Get-Command bash, sh, git | Select-Object Name, Source
```

`Install-GreenroomInstance` distinguishes the two cases: not-on-PATH-anywhere versus
on-PATH-in-the-registry-but-not-in-this-process. They need different responses, and
they are otherwise indistinguishable.

If a session is already running when you change PATH, restart its task — it still
holds the old block.

---

## Model

Each instance can pin the model it launches with:

```powershell
Install-GreenroomInstance -Name laptop-admin -Model opus
Restart-GreenroomSession  laptop-admin        # takes effect on the next start
```

Omitted, it inherits from the previous install like every other parameter; `-Model ''`
returns the instance to whatever the CLI would choose. It is validated when passed
explicitly, by running the CLI — a bad value exits 1 inside a hidden window and
crash-loops the instance, the same failure class as a CLI without `--remote-control`.

**Why this is a launch-line flag rather than a setting.** An instance resumes its
conversation with `-c`, and a resumed session keeps the model it was saved with — by
design, so one session's choice cannot move another's. For an always-on instance that
means the model becomes **sticky**: whatever it last ran is what it keeps, across
restarts and reboots, indefinitely. A `model` entry in `settings.json` will not dislodge
it. `--model` on the launch line does, and nothing else reachable from here does.

Prefer an **alias** to a pinned id. `opus` follows the newest of that family;
`claude-opus-5` stays on that version forever, which is the same trap in a different place.

This sets the model a session **starts** with, not a guarantee for its lifetime. A session
can be moved afterwards with `/model`, and the CLI can fall back to a different model on
its own when it flags a message — a long security-flavoured session may find itself on a
different model than it launched with. greenroom cannot read the live model, so it does
not report one; `config.json` records what was asked for, not what is running.

---

## Elevated instances

`-Elevated` registers the task with `RunLevel Highest`, so the session runs with a full
admin token and no UAC prompt. **Requires an elevated installer** — registering
`RunLevel Highest` is refused from a normal shell.

It is off by default because it changes how the instance is operated, not as a security
posture:

- **Show and Hide prompt for elevation.** UIPI stops a normal shell from showing or hiding
  an elevated window, and the calls fail by returning `false` rather than erroring — so the
  command re-launches itself through UAC and the elevated copy does the work. Pass
  `-NoElevate` to get a plain refusal instead. `Stop-` and `Restart-GreenroomSession`
  escalate the same way, but **once per command**: `Stop-GreenroomSession *` raises one
  prompt for every elevated instance it matched, after the others have been handled.
- **`Get-GreenroomInstance` has a blind spot unless it is run elevated too.**
  `Win32_Process.CommandLine` reads as NULL across integrity levels, and that is how
  instances are named — so from an ordinary shell an elevated session shows as `Opaque`
  with no name. Run it elevated and the blind spot is gone; it belongs to the shell, not
  the session.
- **Nothing on screen distinguishes an elevated session** — no prompt, no badge.
  `Get-GreenroomInstance` is how you tell.
- **Credential Manager is empty until the boot's first elevation.** The `Highest` task
  builds its token via a password-less S4U logon, so the elevated session has no Windows
  Credential Manager credential set until a genuine UAC elevation warms it — a
  credential-backed tool (git over HTTPS via GCM) fails right after a cold boot with error
  1312, then works once you have elevated anything. There is no general fix; you route the
  affected tool around it — for git, the DPAPI store
  (`git config --global credential.credentialStore dpapi`) or an SSH remote, neither of
  which cures the blindness itself. [gotchas.md §6](gotchas.md) has the mechanism and both.

Elevation is inherited on a bare re-run, like grants and the working directory, and says so
each time. Revoke it explicitly:

```powershell
Install-GreenroomInstance -Name desktop-admin -Elevated:$false
```

Background: [gotchas.md §5](gotchas.md).

---

## Several instances on one host

```powershell
Install-GreenroomInstance -Name desktop-admin -TriggerDelay PT1M
Install-GreenroomInstance -Name render-admin  -TriggerDelay PT2M -WorkingDirectory D:\render-admin
```

Stagger the delays so they do not race at logon. Each instance gets its own working
directory, its own grants, and its own name in the Remote Control UI.

---

## Directory access

Each instance launches with access to its working directory and nothing else.
Anything more is granted at install time and passed as `--add-dir` on the launch
line, so the grant is scoped to that instance and visible in the process list:

```powershell
Install-GreenroomInstance -Name desktop-admin -AdditionalDirectories "$env:USERPROFILE"

Install-GreenroomInstance -Name render-admin -WorkingDirectory D:\render-admin `
              -AdditionalDirectories D:\models
```

No `-AdditionalDirectories` means no extra access. The installer refuses to grant a
path that does not exist. Widening later is a re-run with the new grant, effective at
the next session restart.

This governs only what the supervisor launches. Anything granted host-wide in your
own Claude configuration applies to every session on the machine regardless, which is
outside greenroom's control and worth knowing when reasoning about an instance's real
reach.

---

## Trust

Remote Control will not connect from an untrusted directory, and the trust dialog is
modal — in a hidden window that means the session hangs with no visible reason.

`Install-GreenroomInstance` seeds `hasTrustDialogAccepted` for the working directory in
`~/.claude.json` before first launch, in **both** slash forms, then re-reads the file
after launch to confirm the seed survived. It does not assume: on any host with
Claude Desktop there are always other `claude.exe` processes, and any of them can
rewrite that file in between. If the seed is gone it re-seeds and restarts once, and
says so plainly if that fails.

It refuses to write `~/.claude.json` at all if the result would not parse as JSON.

**This is the only file outside greenroom's own directories that installing writes.**
`-NoTrustSeed` declines it entirely — run `claude` once in the working directory and
accept the dialog yourself, and greenroom then touches nothing but
`~\.local\bin\greenroom` and `~\.claude\greenroom\<instance>`.
