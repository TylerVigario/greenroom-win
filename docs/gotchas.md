# Gotchas

Things that do not behave the way they obviously should, and residue that never got
cleanly resolved and can still bite you. Not a rationale archive — why a piece is built
the way it is lives in the commits, with receipts.

If you are porting this concept to another platform, this file is the part worth
reading. The scripts are disposable; these are not.

---

## 1. Windows 11 hands consoles off to Windows Terminal

Windows Terminal is a separate process parented to the console-handoff broker
(svchost), not to your launcher. Hiding your own pseudo-console does nothing —
Windows Terminal owns the visible window.

Worse, `PseudoConsoleWindow` reports `IsWindowVisible = true` at 0×0, so a naive
visibility check returns a **false pass**. Any real check must enumerate all
top-level windows and exclude zero-area ones.

## 2. Do not use conhost to dodge #1

conhost does no font fallback, and no console-registerable font — Consolas, Lucida
Console, Cascadia — contains the glyphs the Claude Code TUI draws: ✳ U+2733,
⏵ U+23F5, ⏺ U+23FA, ✦ U+2726. Verified by glyph-map inspection. Under conhost the
interface renders as boxes.

Windows Terminal honours `SW_HIDE` **and** does fallback, which is why it satisfies
both constraints at once and is a hard requirement rather than a preference.

## 3. Remote Control will not run from a home directory

The startup trust dialog never persists trust for a home directory, so Remote
Control never connects and the trust prompt repeats forever. Always use a project
subdirectory.

Trust is keyed on the **literal cwd string**, so `C:\x` and `C:/x` are separate
entries with independent trust values. Seeding one and starting with the other
re-prompts. Both forms must be seeded.

That literal-string keying is worth remembering beyond trust: anything else Claude
Code keys on a working directory keys on the exact string, so the same class of
mismatch — slash direction, drive-letter casing — reappears wherever a path is used
as an identifier.

**The concrete consequence: relocating an instance orphans its memory.** Claude
Code stores per-project state under `~/.claude/projects/<slug>/`, where the slug is
the literal working-directory string with every non-alphanumeric character replaced
by a dash. Change the working directory and the slug changes with it, so the
instance starts against an empty store — no memory, and nothing for `-c` to
continue.

```
~/desktop-admin       ->  C--Users-tyler-desktop-admin
~/src/desktop-admin   ->  C--Users-tyler-src-desktop-admin
```

**Carrying that state is the operator's job, not greenroom's.** Relocating takes a
deliberate `-WorkingDirectory` on an already-installed instance; it cannot happen by
accident. Provision it the same way you would any other move:

```powershell
Copy-Item -Path (Join-Path $old '*') -Destination $new -Recurse -Force
```

greenroom deliberately does not do this. `~/.claude/projects/` is Claude Code's data
model, not greenroom's — the contents change between versions, a target slug may
already hold state, and there is no obviously correct merge policy. greenroom writes
only what a session needs in order to start at all (trust, its own state) and warns
about everything else; see the marketplace check, which prints exactly what to remove
from `settings.json` rather than editing it. An instance with an empty memory store
starts fine. It is degraded, not broken, which puts it below that bar.

## 4. Windows Terminal hosts multiple windows in ONE process

On a host running two instances, both sessions walk up to the *same*
`WindowsTerminal.exe` PID, and that PID owns two `CASCADIA_HOSTING` windows.
Taking the first one is a coin flip on every attach and detach — this is the normal
two-instance case, not an edge case.

There is no supported way to ask Windows Terminal which window hosts a given
process. That was requested as [microsoft/terminal#5694][t5694] and closed
**Won't Fix**, so this is a permanent property of WT, not a version bug.

[t5694]: https://github.com/microsoft/terminal/issues/5694

**Fix — record the handle at creation.** The watchdog is the only component that
knows which window is which, because it is the one that made it:
it snapshots every `CASCADIA_HOSTING` handle immediately before launching
`wt.exe`, then takes the handle that is both *new since that snapshot* and
*owned by the `WindowsTerminal.exe` in the session's own ancestry*, so a window
opened by an unrelated `wt` at the same moment fails one of them. The survivor is
written to `~/.claude/greenroom/<instance>/session.json`; anything ambiguous
records nothing and says so in the log rather than guessing.

**Those two filters are not enough when two instances start in the same second.**
Both windows are new, and both belong to the same `WindowsTerminal.exe`, so
neither filter separates them and capture fails for *both* instances — they run
perfectly and neither can ever be revealed. So `wt` is launched with
`--title <unique token>` and the watchdog polls for the window carrying it, which
decides the question outright instead of narrowing it.

**The token is readable for only a moment, and that is deliberate.**
`--suppressApplicationTitle` is **not** passed, so the session takes the title
back: the window ends up reading `✳ <instance>`, which is what a human wants in
the taskbar and what `Test-SessionTitle` matches when a corpse has to be closed.
MEASURED on Windows 11 26200 with Claude Code 2.1.322, polling every 50 ms:

| ~t | Window title |
|---|---|
| 0.03 s | `Windows Terminal` |
| 0.12 s | `Terminal` |
| 0.32 s | `greenroom-<instance>-<8 hex>` — the token |
| 0.67 s | `claude` |
| 0.99 s | `✳ <instance>` |

A third of a second. That is why the search runs from the launch rather than from
the moment the session's pid appears, which is a second or more later.

**This is not the title matching rejected below.** The token is read once, inside
the first second, to choose between handles that have *just appeared* — a string
greenroom itself put there, not one Claude Code owns. Resolution never consults a
title: it uses the recorded handle, validated on every use, with no fallback. A
Windows Terminal that ignored `--title` would simply leave the two original
filters in place, and a genuinely ambiguous start still records nothing.

That record is the **only** source. There is deliberately no fallback.

The obvious alternative is to match on the window title, since the session is
launched with `--name <instance>` and Claude Code renders the title as
`<glyph> <name>`. Don't. The title belongs to Claude Code, not to greenroom, and
a session sitting at a trust prompt or a `/login` screen has not applied `--name`
yet — so it has no matching title at all, which is exactly when the operator needs
to attach. Nor is there anything directory-shaped to fall back to: without `--name`
the title is `Claude Code` until the conversation acquires an auto-generated title,
and then it is *that*, which changes as the conversation does and is never tied to
the working directory. A title fallback also hides the failure that actually
matters: capture silently not working looks perfectly healthy right up until the
day it resolves someone else's window. One source makes a capture failure loud on
the first attach, and `Restart-GreenroomSession <instance>` fixes it in one step.

The stored handle is **validated on every use, never trusted**, against a single
invariant: the record must have been written for the session being acted on. Both
PIDs in the record are checked against the live session the caller already
resolved, so a record left by any earlier session fails regardless of what it
contains. The handle is then re-enumerated rather than used directly, because
Windows reuses handles after a window closes and a stale number can name a live
window belonging to something else. Any mismatch refuses and names the reason —
acting on the wrong window hides or reveals the wrong session, which is worse
than doing nothing.

`--name` is still passed, because a window titled `✳ laptop-admin` is easier to
read than `Claude Code`. Nothing depends on it.

**Test window resolution on a host running two instances.** A single-instance host
cannot tell a working scheme from a broken one: the host process owns exactly one
window, so anything at all short-circuits to the right answer and is right by luck.

## 5. An elevated session cannot be attached from an unelevated shell

Elevation is opt-in per instance (`Install-GreenroomInstance -Elevated`), and it is off by
default — but the reason is operational, not a security posture. **Elevation breaks
attach and detach**, in the silent way, and that is a behaviour change the operator
has to know about rather than inherit.

Registering the task at all requires an elevated installer: `RunLevel Highest`
returns `Access is denied` from a normal shell. Measured, not assumed. The
installer therefore checks up front rather than at `Register-ScheduledTask`, which
is the last step — failing there would leave the instance half-built, with files
copied and trust seeded but nothing registered to run it.

User Interface Privilege Isolation stops a lower-integrity process from driving a
higher-integrity window. **Measured on the reference host 2026-07-29**, not taken
from documentation — an unelevated shell calling `ShowWindow(SW_HIDE)` on a window
owned by an elevated process:

```
ShowWindow returned : False
GetLastWin32Error   : 5      (ERROR_ACCESS_DENIED)
window visible      : True before, True after -- nothing moved
```

No exception, no prompt, no warning.

### `ShowWindow`'s return value does not mean what it looks like

Measuring the *other* direction in the same run produced the correction that
matters. An **elevated** shell calling `SW_RESTORE` on a normal greenroom window:

```
ShowWindow returned : False
GetLastWin32Error   : 1461
window visible      : False before, True after -- it WORKED
```

**Both directions returned `false`.** One was refused, one succeeded. The return
value is not a success flag at all — it is documented as the window's *previous
visibility*, so it is `false` for any window that was hidden, which is every single
`attach`. `GetLastError` is no better: it carries a real `ERROR_ACCESS_DENIED` on
the refused call and stale garbage on the successful one.

So there is **no way to detect this failure from the call itself.** The only
trustworthy signal is comparing `IsWindowVisible` before and after.

That makes both defences necessary rather than belt-and-braces:

- `Assert-CanActOnInstance` checks `config.json` *before* acting, so an unelevated shell
  escalates rather than walking into a refusal it cannot detect;
- and every show/hide **verifies by observation afterwards** and reports failure
  loudly. Piping `ShowWindow` to `Out-Null` and reporting success unconditionally
  makes any no-op, from any cause, read as success — and not only this one: a
  stale window would be misreported just as happily.

The same probe confirmed the reads that still work, which is what keeps `list`
useful from an ordinary shell:

| From an unelevated shell, against an elevated process | Result |
|---|---|
| process enumerates in `Win32_Process` | yes |
| `Win32_Process.CommandLine` | **NULL** |
| `GetWindowText` / `EnumWindows` on its window | **works** |
| `ShowWindow` on its window | **false, error 5** |

And the asymmetry in the other direction: from an elevated shell, `ctfmon.exe`,
`TabTip.exe` and `Bitwarden.exe` — all opaque to a normal shell — read back their
command lines normally, and `Register-ScheduledTask -RunLevel Highest` succeeds
where it returns `Access is denied` unelevated.

That is the worst possible shape for this project. Everything here is already
invisible because the window is hidden; a call that reports success while doing
nothing removes the last signal there was.

**Fix:** `Install-GreenroomInstance` records `elevated` in `config.json`, and the module
checks it *before* touching a window. When the instance is elevated and the shell
is not, it **re-launches itself through UAC** and lets the elevated copy do the
work, so `attach` still attaches.

A UAC prompt is fine here precisely because this is an interactive command someone
just typed. That is the mirror image of the logon path, where a UAC dialog behind a
hidden window would be an invisible hang — which is why the session takes its token
from the task trigger instead of prompting. Same mechanism, opposite conclusion,
decided by whether a human is already looking at the screen. `-NoElevate` restores
the plain refusal for scripted callers that must not block.

Window *enumeration* is unaffected: `EnumWindows`, `GetClassName` and
`GetWindowText` work across integrity levels. Only acting is blocked.

### Process discovery is affected, and it depends on where you run from

**`Win32_Process.CommandLine` is NULL for any process the querying shell lacks
query rights on.** Measured on the reference host against `ctfmon.exe`,
`TabTip.exe` and `Bitwarden.exe` — all three enumerate normally and all three
expose no command line to an ordinary shell.

An elevated `claude.exe` lands in exactly that class, which breaks the identifying
assumption everything here rests on: sessions are found by matching
`--remote-control <instance>` on the command line. With no command line there is no
token to match, so an elevated session is **visible as a process but
unidentifiable**, and a naive filter drops it — reporting "no session running" for
one that is running.

**This is a property of the shell, not of the session.** Run `Get-GreenroomInstance` from
an elevated prompt and there is nothing unreadable: every instance resolves by name
exactly as usual. The blind spot belongs to the observer, and the fix for it is to
change vantage point, not configuration. The output says so rather than describing
the sessions as though they were permanently unknowable.

Unreadable processes are therefore reported as `(unreadable)` rather than
discarded — but **only when an elevated instance is actually configured**. An
unreadable `claude.exe` is not evidence of greenroom by itself: a host with Claude
Desktop installed runs a dozen unrelated ones (13 on the reference host), and
labelling one of those a probable greenroom session would be precisely the
confident wrong answer this branch exists to avoid.

The watchdog is unaffected — `RunLevel Highest` covers the whole `wscript` →
watchdog → `wt` → `claude` chain, so an elevated instance's supervisor is itself
elevated and always sees its own session.

Nothing on screen distinguishes an elevated session from a normal one — the token
comes from the task trigger, so there is no prompt and no badge. `Get-GreenroomInstance`
grew an `Elevated` column to make it legible.

---

## 6. An elevated instance starts blind to Credential Manager

An elevated instance cannot read or write Windows Credential Manager until something in
that session triggers a genuine UAC elevation. This is not a delay that clears on its own:
with nothing ever elevated it never clears — you can wait hours. A tool that depends on the
store — git over HTTPS through Git Credential Manager is the usual one — fails after a cold
boot with

```
fatal: Unable to persist credentials with the 'wincredman' credential store.
```

(Win32 error 1312, "a specified logon session does not exist"), and works the instant you
elevate *anything* in that session — Run-as-admin a shell, accept one UAC prompt. It is the
elevation that fixes it, not elapsed time: nothing greenroom did changed between the
failure and the success.

**The credential set a session can read is tied to how its logon was established.** A
logon made *with a password* — your real Hello/interactive sign-in — gets a Windows
Credential Manager credential set; a password-less one does not. `RunLevel Highest` builds
its elevated token through an S4U (Service-for-User) logon, which is password-less by
construction, so the elevated session has no credential set at all. `CredWrite` returning
1312 is not a permission error; there is simply no store to write to. The *non-elevated*
interactive session — your real sign-in — carries the set the entire time, which is why
the same credentials are visible there throughout.

The warming is the boot's first genuine **UAC elevation**: consenting to a real
medium→high elevation establishes credential material for the elevated logon session, and
every elevated process that boot shares one such session, so they all light up at once.
Measured: cold at +40 s, still cold at +3 min with nothing elevated, warm within seconds of
the first `Run-as-admin`. The instance's own token cannot trigger it — it is *already*
elevated, so it has nothing to consent to.

There is no clean *general* fix — nothing makes the elevated session credential-bearing
while it stays interactive:

- A **password-backed task** (registered with a stored password → Batch logon) is
  credential-bearing, but a Batch logon is non-interactive: no desktop, so no Remote
  Control window. It also writes the account password into Credential Manager where any
  admin can extract it. Credential-bearing and interactive-at-logon are mutually exclusive
  here.
- **Disabling UAC** (`EnableLUA=0`) removes the split token and the problem with it, but
  it is a genuine security downgrade and breaks Store/UWP apps. Not something to require of
  every host.

So you do not fix the session — you route the specific tool that needs credentials *around*
Credential Manager. The blindness itself stays; you just stop depending on the store the
elevated session cannot reach. For git there are two such routes, and they fix **git**, not
the blindness:

- **DPAPI store, for git over HTTPS.** `git config --global credential.credentialStore dpapi`
  makes Git Credential Manager encrypt the token to a file (`%USERPROFILE%\.gcm\dpapi_store`)
  with your DPAPI key instead of into Credential Manager. DPAPI works in the elevated session
  even when wincredman does not, because its key comes from the user profile the S4U token
  still carries. Measured: with wincredman empty at +109 s after a cold boot, an
  authenticated `git push` from the elevated instance succeeds. Populate it once with
  `git-credential-manager github login`; it survives reboots, since DPAPI uses your
  persistent master key.
- **An SSH remote.** Use `git@github.com:…` instead of `https://…`; git over SSH
  authenticates with a key and never touches Credential Manager. The catch is that the key
  must be reachable from the elevated session — a file-based key under `~/.ssh` is, but an
  agent-backed one (Bitwarden, Pageant) works only if that agent answers the elevated
  session, which is not a given.

Neither touches the underlying blindness. Anything else that reads Windows Credential
Manager is still blind in that session until its first elevation. That is narrow in practice
— git is the common case, and the rest of the store is personal application tokens the
instance has no reason to read — but the remedy is per-tool, not a cure for the session.

---

## Two smaller ones

**Identify sessions by the instance name on the command line.** The name passed to
`--remote-control` does double duty: it labels the session in the Remote Control UI
*and* puts a unique token in the process command line. A supervisor matching bare
`--remote-control` adopts whichever session it sees first and then fights the other
supervisor over it. Anchor the match so `admin` cannot match `admin-2`.

**Never match `claude.exe` by process name.** A machine with Claude Desktop
installed has several distinct `claude.exe` binaries in unrelated locations.
`Stop-Process -Name claude` takes out all of them, including the session you are
working in. Filter by path or by the instance token.

---

## The general lesson

Every failure in this architecture is silent, because the window is hidden. A
misconfiguration that would be obvious in a visible terminal — a missing flag, a
modal dialog, a plugin load error — presents as "it just doesn't work" with no
output anywhere.

So the installer verifies rather than warns wherever it can, and refuses to
register anything until the prerequisites that fail silently are confirmed
present. Any port of this concept should hold the same line.
