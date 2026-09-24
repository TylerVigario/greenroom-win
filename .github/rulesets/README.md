# Rulesets

Two payloads, one per ruleset applied to this repository:

| File | Ruleset | Target |
|---|---|---|
| `main.json` | **`main-protection`** | branch — the default branch |
| `tag.json` | **`tag-protection`** | tag — `~ALL` |

They are committed because a ruleset is applied state that lives only on GitHub:
it vanishes silently on repository recreate, rename or fork, and nothing in a
clone reveals it is gone. `tag-protection` spent time enforced with no committed
payload — active on the server, invisible here, and impossible to verify from a
checkout, which is the same hole in the other direction.

**The file is the source of truth. Apply it; do not hand-configure.** `main.json`
spent several commits describing protection that had been set by hand and never
matched it, which is the failure these exist to prevent. For the same reason a
payload records what is *applied*, not what would be better: change the file and
apply it, in that order, or the two disagree again.

```bash
# create
gh api repos/<org>/<repo>/rulesets --method POST --input .github/rulesets/main.json

# update an existing one
gh api repos/<org>/<repo>/rulesets/<id> --method PUT --input .github/rulesets/main.json

# list what is applied, to check either file against reality
gh api repos/<org>/<repo>/rulesets --jq '.[] | .id, .name, .target'
```

Read back what is enforced from the **rules** endpoint. The legacy
branch-protection API reports `enforcement_level: off` even where a ruleset is
demonstrably active, which is a good way to conclude protection is missing when it
is not:

```bash
gh api repos/<org>/<repo>/rules/branches/main
```

## Things that will catch you

**A required context is a job name, and renaming a job is a protection change.**
Rename one without updating this file and the ruleset waits forever on a context
nothing will ever report — indistinguishable from one merely pending, so the
branch wedges with no visible cause. The `json` check asserts every context here
resolves to a job in a workflow, so a typo fails the pull request that introduced
it rather than the branch afterwards.

**A job that cannot report on a pull request must never be required.** `history`
in `commit-convention.yml` runs only on pushes, which is why it is deliberately
absent from the payload.

**Apply only after every context has reported at least once.** A context that has
never run cannot be distinguished from one that is pending.

**`pull_request` requires zero approving reviews, deliberately.** GitHub does not
allow approving your own pull request, so any non-zero count deadlocks a
single-owner repository outright. Do not "fix" this.

**`bypass_actors` holds one entry: the release App, by its APP ID** — the number,
not the `Iv23li...` Client ID that goes in the workflow's secret. **Install the App
on the repository before applying**, or the whole `PUT` fails with a 422:
*"Invalid bypass actor"*. GitHub will not accept an actor it cannot resolve, which
is also why the `actor_id: 0` placeholder this file once carried made the payload
un-appliable rather than merely inert.

**`bypass_mode: always` bypasses every rule in the ruleset, not just the
pull-request one** — so the App could in principle force-push or delete `main`, not
merely skip review. Scoping that down means splitting this into two rulesets, one
carrying the PR and status-check rules with the bypass and one carrying the
integrity rules without. Considered and declined for a single-owner repository;
revisit if more actors ever hold a bypass.

The exemption belongs to the **actor**, not to `release.yml`: anything that can
mint the App's token can push to `main` unreviewed. That is why
`RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY` live on the `release`
environment — required reviewer, limited to `main` — rather than repository-wide.

To push by hand instead, set `enforcement` to `disabled` first — a deliberate,
visible act rather than a standing exemption.

## `tag.json`

`deletion` + `non_fast_forward` on every tag, with **no bypass actors** — the
release App is exempt from `main-protection` only. It does not need an exemption
here, because neither rule blocks *creating* a tag, which is all a release does.

**This is not quite immutability, and the gap is a convention rather than a rule.**
Those two rules stop an *annotated* tag being re-pointed, because the new tag
object is not a descendant of the old one. A *lightweight* tag moved to a
descendant commit is a fast-forward, and is allowed. Immutability therefore rests
on always creating annotated tags, which `cog bump --annotated` does — see the
`post_bump_hooks` in `cog.toml`.

Adding the `update` rule would remove that dependency on tag type. It is not here
because it is not applied; adding it means changing this file **and** applying it,
not one or the other.

One version number naming two different sets of bits is the failure this prevents,
and it matters most where something downstream builds from a tag — here, the
PowerShell Gallery publish, which is one-way: a published version can be unlisted
but never deleted.
