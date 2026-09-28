# greenroom-win task runner.
#
# `just check` is the whole gate. CI runs the same phases out of this file, one per job,
# so a red X names the failure -- which is what keeps a green local run and a green pull
# request meaning the same thing. Anything CI enforced that was not reachable from here
# would make the pull request the only place a failure can be found.
#
# Recipes run under pwsh on every platform so there is one dialect rather than two, and
# the gate's logic lives in ci/check.ps1 -- just's shebang recipes require cygpath on
# Windows, which is this repository's whole audience.
#
# The gate needs NOTHING but pwsh. That is deliberate: it has to stay runnable on a host
# with no network and no extra tooling, which is the situation you are in precisely when
# something is already broken.

set shell := ["pwsh", "-NoLogo", "-NoProfile", "-Command"]

# Recipe parameters reach recipes as environment variables. `verify` relies on it: a
# subject passed through shell quoting breaks on an apostrophe, because just quotes for
# POSIX (`'\''`) while pwsh escapes by doubling instead.
set export := true

# Show the recipes.
default:
    @just --list --unsorted

# Everything CI enforces: manifest, parse, json, static analysis, tests.
check:
    @pwsh -NoProfile -File ./ci/check.ps1

# Validate the module manifest.
manifest:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase manifest

# Parse every .ps1, .psd1 and .ps1xml.
parse:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase parse

# Validate every JSON file, including the branch-protection payload.
json:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase json

# PSScriptAnalyzer, default rules, no settings file.
analyze:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase analyze

# Pester.
test:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase test

# The three below need cocogitto on PATH. `just check` deliberately does not -- the gate
# stays runnable with nothing but pwsh, and commit tooling is not something you should have
# to install to find out whether the tree is sound.
#
# INSTALL THE VERSION CI PINS, not the newest. COG_VERSION in commit-convention.yml and
# release.yml is what every reported result was produced by; a local cog of a different
# version can disagree with the gate about the same history. On Windows:
#
#   $v = '7.0.0'   # must equal COG_VERSION in .github/workflows/
#   curl.exe -fsSL "https://github.com/cocogitto/cocogitto/releases/download/$v/cocogitto-$v-x86_64-pc-windows-msvc.tar.gz" -o cog.tar.gz
#   tar -xzf cog.tar.gz --strip-components=1 -C "$HOME\.local\bin" x86_64-pc-windows-msvc/cog.exe
#
# `curl.exe`, not `curl`: Windows PowerShell 5.1 aliases curl to Invoke-WebRequest, which
# takes none of those flags, so the bare name fails there and works in pwsh 7 -- the worst
# split for a line someone pastes. `tar` needs no such care; it is a real binary in both.
#
# NOT ON WINGET -- no package exists, and the `cog` search is all false positives, so that
# is a dead end rather than something to keep looking for. The archive is the project's own
# release artifact. `cargo install cocogitto` is equally official if a Rust toolchain is
# already present (winget has one, `Rustlang.Rustup`), but it builds from source and pulls
# in MSVC build tools for a single binary.

# Lint a subject the way CI lints a pull request title: `just verify "feat: add a thing"`.
verify subject:
    @cog verify $env:subject

# Lint the whole history, as the post-merge check does.
lint:
    @cog check

# What the next release would be, and what would be in it. Writes nothing, pushes nothing.
next:
    @cog bump --auto --dry-run
    @cog changelog
