# Troubleshooting

Every failure in this architecture is invisible by construction — the window is hidden, so
nothing surfaces on screen. That is what makes a symptom table worth having: the symptom is
usually the only thing you get.

---

## Did it actually work?

Do not trust a green line from the installer for anything it cannot observe.

1. **No window should have appeared.** Only you can confirm this.
2. `Show-GreenroomSession <instance>` → the session appears.
3. **`/rc active` in the footer.** If absent, `/login` inside the session.
4. `Hide-GreenroomSession <instance>` → it disappears; `Get-GreenroomInstance` still shows it.
5. **Cold reboot.** The only test that proves the logon trigger fires and that the delay is
   long enough for whatever the session depends on. Nothing substitutes for it. After
   logging back in, wait ~90 s and check `watchdog.log`.

---

## Symptoms

| Symptom | Cause / fix |
|---|---|
| Session starts then dies, repeatedly, silently | Almost always a CLI without `--remote-control`. Check `claude --help` |
| Session never starts | `watchdog.log` — usually the `claude.exe` path or a missing login |
| A terminal flashes at logon | Something launched the session directly instead of via the `.vbs` |
| TUI renders as boxes | Launched under conhost. Check `wt` in `config.json` |
| Trust dialog on first start | The seed was dropped by another Claude process. Installer re-seeds; if it reports RE-SEED FAILED, close other sessions and re-run |
| `/rc active` missing | Not logged in, or logged in with a `setup-token` |
| `cannot resolve the window` | The instance has no usable window record — most often a session started before the record existed. `Restart-GreenroomSession <instance>` creates one |
| Wrong `claude.exe` picked | Pass `-ClaudeExe` |
| An elevated instance shows as `Opaque` with no name | The blind spot belongs to your shell, not the session — `Win32_Process.CommandLine` reads NULL across integrity levels. Re-run `Get-GreenroomInstance` elevated |
| An upgrade "worked" but nothing changed | The task records the **versioned** asset path, so a restart re-runs the old version. `Update-GreenroomInstance` — see [Upgrading the module](provisioning.md#upgrading-the-module) |
| `git push` fails with error 1312 right after a cold boot | An elevated instance has no Credential Manager set until the boot's first UAC elevation. [gotchas.md §6](gotchas.md) has the mechanism and the two git-specific routes around it |
| `Import-Module Greenroom` → "no valid module file was found" in 5.1 | 5.1 searches `Documents\WindowsPowerShell\Modules`, and the module is only on the pwsh 7 path. Install it to the 5.1 path too, or manage from `pwsh` |
| `Exception calling "ShouldContinue"` on a first gallery install in 5.1 | Windows PowerShell ships no NuGet provider and the bootstrap prompt cannot prompt. `Install-PackageProvider NuGet -Force -Scope CurrentUser`, once per host |

---

## Logs

```
%USERPROFILE%\.claude\greenroom\<instance>\watchdog.log    supervisor
%USERPROFILE%\.claude\greenroom\<instance>\launch.log      per-session launch
```

Both are **local time**, while most other output is UTC. That has cost a wrong conclusion
before now: two launcher entries looked like an unexplained restart until the timestamps
were reconciled against boot time and turned out to straddle a reboot.

`LastTaskResult 0` on the scheduled task does **not** mean it worked. It means the
supervisor exited cleanly — and the crash-loop that preceded it also exited 0. Read
`watchdog.log`.

---

## Restarting by hand

```powershell
Restart-GreenroomSession <instance>
```

That is the supported route, and it stops the watchdog first — which matters, because
stopping the session alone lets the watchdog immediately restart it and a subsequent task
start becomes a no-op against a session that never went away.

If you are driving the task directly instead:

```powershell
Stop-ScheduledTask  -TaskName greenroom-<instance>
Start-ScheduledTask -TaskName greenroom-<instance>
```

`Stop-ScheduledTask` is close to a no-op here: the task runs `wscript.exe`, which spawns
the watchdog detached and returns, so the task sits at `Ready` with nothing left to stop.
A plain `Start-ScheduledTask` therefore **adds** a second supervisor. A named mutex stops
the duplicate from doing damage, but the tidy route is `Restart-GreenroomSession`.

---

## Upgrading the Claude Code CLI

A running session holds `claude.exe` open, so upgrading the CLI underneath it fails:

```
remove: Access is denied.: "…\WinGet\Packages\Anthropic.ClaudeCode_…\claude.exe"
Installer failed with exit code: 0x8a150003
```

On a WinGet install there is only **one** file to lock. `~\AppData\Local\Microsoft\WinGet\Links\claude.exe`
is a symlink into the package directory, and every session — greenroom's and any you
started yourself — runs through it. Hiding a window does not release the handle, and
restarting only re-takes it.

Take the instances down, upgrade, bring them back:

```powershell
$running = (Get-GreenroomInstance).Instance
$running | Stop-GreenroomSession
winget upgrade --id Anthropic.ClaudeCode
$running | Start-GreenroomSession
```

**Capture the names first.** `Get-GreenroomInstance` lists *running* sessions, so once
they are stopped it returns nothing. The 0.4.0 version of this procedure piped a fresh
`Get-GreenroomInstance` into the restart, which therefore brought nothing back. Capturing
also restores exactly what was running, and not an instance that was down on purpose.
`Start-GreenroomSession *` is the blunter alternative: every registered instance that is
not running.

**Stopping the instances is not always enough.** An interactive Claude Code session holds
the same binary, including the one you may be running these commands inside. MEASURED:
with every greenroom instance stopped, the package file was still locked, and the only
remaining holder was an interactive session started by hand. Exit those too, and run the
upgrade from a plain terminal.

Claude **Desktop** can stay open. Its `Claude.exe` processes are the Electron app under
`Program Files\WindowsApps`, a different binary that does not touch this file — which is
also why matching by process name is the wrong instrument here.

---

## Never `Stop-Process -Name claude`

A host with Claude Desktop installed has several distinct `claude.exe` binaries; matching
by name kills all of them, including the session you are working in. Filter by path, or by
the instance token:

```powershell
Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
    Where-Object CommandLine -match '--remote-control <instance>'
```
