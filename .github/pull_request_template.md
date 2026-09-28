<!--
The title becomes the commit on main: merges are squashes with an empty body, so write
the title as a conventional commit -- `fix(session): what changed` -- and keep it true
if the branch changes. `pr-title` checks it. See CONTRIBUTING.md.
-->

## What and why

## How it was tested

- [ ] `just check` passes locally (manifest, parse, json, analyze, test)
- [ ] Module code changed: CI runs the tests on both editions (`test-core`, `test-desktop`); a local run proves only the one you ran
