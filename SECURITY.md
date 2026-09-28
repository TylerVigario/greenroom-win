# Security policy

## Reporting a vulnerability

Report it privately, through GitHub's private vulnerability reporting:
**[Report a vulnerability](https://github.com/TylerVigario/greenroom-win/security/advisories/new)**
(the **Security** tab of this repository). Please do not open a public issue, discussion
or pull request for it.

A report that can be acted on says:

- the greenroom version — `Get-Module Greenroom -ListAvailable`
- the Windows build, and the PowerShell edition the module ran under (5.1 or 7)
- whether the instance is elevated — `Get-GreenroomInstance`
- what an attacker needs to start with, and what they end up with
- the steps that reproduce it

## Supported versions

**The latest release only.** greenroom is in initial development (`0.x`): a fix ships as
a new version, and earlier versions are not patched.

A fix always arrives under a new version number. A published version is never replaced:
release tags on this repository cannot be moved or deleted, and the PowerShell Gallery
does not accept a version twice.

## Scope

greenroom sets up things with standing on the host, so a flaw in any of these is a
security issue rather than an ordinary bug:

- **The logon task.** Every instance is a scheduled task. `-Elevated` registers it with
  `RunLevel Highest`, so that session holds a full admin token with no UAC prompt.
- **Elevation on demand.** `Show-`, `Hide-`, `Stop-` and `Restart-GreenroomSession`
  re-launch themselves through UAC to act on an elevated instance.
- **Trust.** Installing seeds Claude Code's trust entry for the instance's working
  directory in `~/.claude.json`, so Remote Control connects without the dialog.
- **What the task runs and reads.** The watchdog is run from the installed module's own
  directory, and per-instance state is read from `~\.claude\greenroom\<instance>` —
  including by an elevated task.
- **The release pipeline.** Anything that would let a published version differ from the
  commit it was released from.

Out of scope: vulnerabilities in Claude Code itself, which belong with Anthropic, and what
a session does with access you granted it.
