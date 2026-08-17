<div align="center">
  <img src="assets/logo.svg" alt="bot-labeller — a label tag with a robot face" width="150">

# bot-labeller

**Know which pull requests were machine-written — before you spend human time on them.**

A GitHub Action that scores every incoming PR for machine authorship and
drive-by automation, applies an honest label, and posts a single evidence
report. Deterministic, dependency-free, and it never runs the contributor's code.

[![ci](https://github.com/neolitec/bot-labeller/actions/workflows/ci.yml/badge.svg)](https://github.com/neolitec/bot-labeller/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/neolitec/bot-labeller?logo=github&color=1f6feb)](https://github.com/neolitec/bot-labeller/releases)
[![marketplace](https://img.shields.io/badge/marketplace-bot--labeller-1f6feb?logo=github)](https://github.com/marketplace/actions/bot-labeller)
[![license: MIT](https://img.shields.io/badge/license-MIT-1f6feb)](LICENSE)

[Quick start](#quick-start) ·
[How it works](#two-scores-not-one) ·
[Labels](#the-labels) ·
[Action reference](#action-reference) ·
[Claude skill](#the-claude-code-skill) ·
[Security](#the-security-model)

</div>

---

Every public repository now receives pull requests written by machines. Some come
from your own contributors using Claude Code, Copilot or Cursor — welcome, and
increasingly the norm. Others come from accounts that forked your repo **23 seconds**
before opening a PR, landed it four minutes after the issue was filed, and will
never answer a review comment.

The failure mode is not missing them. It is treating both the same.

## Two scores, not one

"Is this a bot?" is two questions wearing one coat, and bot-labeller refuses to
collapse them:

| Axis | Question | What a high score means |
|:--|:--|:--|
| **AUTHORSHIP** | Was this diff machine-produced? | Nothing on its own — plenty of good PRs are agent-written. |
| **DRIVE-BY** | Does this account fork-and-PR unrelated projects at a cadence no person sustains? | This is the axis that predicts unsolicited, low-effort volume. |

```
high AUTHORSHIP + low DRIVE-BY   → a maintainer used an agent. Normal.
high AUTHORSHIP + high DRIVE-BY  → a drive-by bot.
low  AUTHORSHIP + high DRIVE-BY  → worth a look; the diff is not the only evidence.
```

A high authorship score is not an accusation — it is a fact worth having on the
record, in a deliberately neutral colour.

## What you get

- 🔍 **Evidence, not vibes** — every point printed carries the literal text that
  earned it. Read the evidence, not the number.
- 🏷️ **Three labels, write-once** — automation gets exactly one say; from then on
  a human owns the verdict, and only a human removes a label.
- 🔒 **Never runs contributed code** — no checkout, no install, no build. Metadata
  in, one label and one comment out.
- 💬 **One sticky comment** — edited in place on later pushes, never stacked.
- 🧮 **Deterministic first, AI second** — hard signals settle it for free; only
  genuinely ambiguous PRs are flagged for a model's reading pass.
- 🪶 **Zero infrastructure** — a composite action in pure bash over `gh` and `jq`.
  No Docker image to pull, no Node runtime, nothing to build.

Here is the scorer looking at a real drive-by:

```
  pollychen-lab  —  neolitec/kevlar-tabs#187

  AUTHORSHIP  [####################]  100/100   very likely machine-authored
  DRIVE-BY    [####################]  100/100   very likely an automation account

  TRIAGE      CONFIRMED machine authorship is self-declared — no reading pass needed

  AUTHORSHIP signals
    [hard] +25  branch sits in an agent namespace — matched "agent/"
           +15  body reports its own sandbox limits — matched "browser binaries"
           +20  fork to PR in 23s — no human reads a codebase that fast
           +18  PR landed 4m 39s after issue #186 was filed
```

## Quick start

Drop this in `.github/workflows/bot-labeller.yml`:

```yaml
name: bot-labeller

on:
  pull_request_target:
    types: [opened, reopened, synchronize]

permissions:
  contents: read
  pull-requests: write

jobs:
  score:
    runs-on: ubuntu-latest
    steps:
      - uses: neolitec/bot-labeller@v1
```

That is the whole setup. From the next PR onward, the action scores it, applies
the right label, and posts **one** comment that it edits on later pushes rather
than stacking a new report each time. Comments and labels are always written in
English, regardless of the repository's language.

A commented copy of this workflow, including the optional knobs, lives in
[`examples/bot-labeller.yml`](examples/bot-labeller.yml).

## The labels

Every label shares the `bot:` prefix, so the family sorts together in the sidebar
and the whole set is one search away — `label:bot:authored`, or just scan for
`bot:` on the PR list.

| Label | Meaning |
|:--|:--|
| ![bot:authored](assets/labels/bot-authored.svg) | Machine authorship is self-declared. A **neutral fact** — informational blue, deliberately not a warning colour. |
| ![bot:unclear](assets/labels/bot-unclear.svg) | Circumstantial signals only; a reading pass is owed. |
| ![bot:drive-by](assets/labels/bot-drive-by.svg) | The only label that asserts a problem. |

The colours carry the argument, in hues every GitHub user already knows: blue for
a fact (like `documentation`), yellow for attention, red for the one case that is
actually a complaint (like `bug`). Labels are created on demand — nothing to set
up in the repository first — and if your repo already has them, your colours are
left alone.

Self-declared bots (GitHub Apps, `[bot]` accounts — dependabot, renovate) are
**exempt**: no label, no comment. They already told you what they are.

### Labels are write-once

**If the PR already carries a `bot:` label, the run stops immediately** — no
re-score, no relabel, and never a removal. The verdict exits `30`
(`ALREADY_LABELLED`) and the comment step is skipped.

This is deliberate. A label is a checkpoint that a human owns from the moment it
lands. Re-scoring on every push would let a later commit flip it: a rebase that
renames the `agent/` branch, or a body edit that strips the giveaway, would
silently withdraw a verdict a maintainer is already acting on. Automation gets
exactly one say; after that it is a person's call, and **only a person removes a
label**.

While no `bot:` label is present, every run is free to evaluate and apply one.

## The security model

The case this check exists for is incoming PRs from forks — and on a
`pull_request` event from a fork, `GITHUB_TOKEN` is **read-only**. The label and
the comment both fail. `pull_request_target` runs in the base repository's
context, where the token can write.

That trigger is genuinely dangerous when misused, because it hands a write token
to a workflow running against a PR the author controls. It is safe here for one
specific reason: **this action never checks out or executes the PR's code.** There
is no `actions/checkout`, no install, no build. It reads PR metadata over the API
and writes a label and a comment. Nothing the contributor wrote is ever run.

If you add a checkout or build step to that workflow file, the guarantee is gone.
Keep those in a separate `pull_request` workflow.

The action holds a write token, so pinning `@v1.2.0` — or a commit SHA — instead
of the mobile `@v1` is a legitimate choice if you would rather review each change
before it runs against your pull requests. See [SECURITY.md](SECURITY.md) for the
full threat model and how to report a vulnerability.

## Action reference

### Inputs

| Input | Default | Notes |
|:--|:--|:--|
| `pr-number` | the triggering PR | Set it to run against an arbitrary PR. |
| `repository` | current repo | `owner/name`. |
| `github-token` | `github.token` | Needs `pull-requests: write`. |
| `comment` | `true` | Post/update the sticky comment. |
| `label` | `true` | Apply labels. **Write-once** — an existing `bot:` label stops the run untouched. |
| `fail-on` | *(empty)* | `CONFIRMED`, `REVIEW`, or both comma-separated. Empty never fails — blocking a PR on a heuristic is rarely what you want. |

### Outputs

`authorship`, `driveby`, `triage`, `ai-review-needed`, `hard-signals` — so a later
step can gate on the result:

```yaml
      - uses: neolitec/bot-labeller@v1
        id: bl
      - if: steps.bl.outputs.ai-review-needed == 'true'
        run: echo "send this one to a reading pass"
```

## How the triage decides

A **hard** signal is self-declaring: a registered GitHub App, an agent
`Co-Authored-By` trailer, a generation notice, an `agent/` branch namespace, a
`[bot]` title tag. It settles authorship alone.

A **soft** signal is circumstantial: fork-to-PR latency, issue-to-PR latency,
prose shape, sandbox self-reports, account statistics. Any pile of these stays
suggestive.

Triage therefore keys off signal *quality*, not the total:

| Triage | Condition | Exit code | Meaning |
|:--|:--|:--|:--|
| `ALREADY_LABELLED` | a `bot:` label is present | `30` | Stop. A human owns this verdict. |
| `DECLARED_BOT` | author is a GitHub App or type `Bot` | `0` | Exempt. No label, no comment. |
| `CONFIRMED` | any hard signal | `20` | Settled. No AI pass needed. |
| `REVIEW` | no hard signal, authorship ≥ 25 | `10` | Ambiguous. Send to an AI reading pass. |
| `REVIEW` | no hard signal, drive-by ≥ 45 | `10` | Account looks like a pipeline. |
| `CLEAR` | everything else | `0` | Nothing to answer. |

The label check runs **first**, before any scoring, so a labelled PR costs one
API call instead of a full evaluation.

80 points of pure circumstance still earns a reading pass; one hard signal at 25
does not. That asymmetry is deliberate — it is what keeps the expensive step rare
and the cheap step honest.

<details>
<summary><strong>What it looks at</strong></summary>

**Authorship** — agent branch namespaces (`agent/`, `claude/`, `codex/`, `cursor/`,
`devin/`, `sweep/`, …); agent tool names anywhere in the branch; self-declared title
tags; agent `Co-Authored-By` trailers; explicit generation notices; harness
self-reports about sandbox limits (*"browser binaries are not installed in this
environment"*); the canonical `## Summary` / `## Test plan` scaffold; first-person
session narration; asserted validation runs; fork→PR latency; commit-authored-vs-fork
latency; issue→PR latency; multi-commit burst spans.

**Drive-by** — repo creation rate per month; distinct repos in recent public events;
PR events as a share of all activity; one-shot repos (a single PR, no follow-up);
same-minute fork+PR pairs.

</details>

## Standalone CLI

The scorer at the action's core runs perfectly well on its own — all it needs is
[`gh`](https://cli.github.com) (authenticated) and `jq`:

```bash
./scripts/bot-score.sh 187                                  # PR in the current repo
./scripts/bot-score.sh https://github.com/owner/repo/pull/12
./scripts/bot-score.sh @some-user                           # account only
./scripts/bot-score.sh --json 187                           # machine-readable
./scripts/bot-score.sh --label 187                          # apply labels (write-once)
./scripts/bot-score.sh --recheck 187                        # re-score a labelled PR, read-only
./scripts/bot-score.sh --help
```

Exit codes mirror the triage verdicts, so it drops straight into any CI:

```yaml
- run: ./scripts/bot-score.sh --label "$PR" || [ $? -eq 10 ] || [ $? -eq 20 ]
```

## The Claude Code skill

The action stops, on purpose, where determinism stops: a `REVIEW` verdict means
"a regex cannot answer this — a reader could." This repo doubles as a
[Claude Code](https://claude.com/claude-code) skill that supplies that reader.

It runs the same scorer first, then — only in the `REVIEW` band — reads the diff
and the prose the way a maintainer would: does the body explain *why* or only
restate *what*; does the change solve the problem or the problem's description;
does it claim validation it could not have run. Hard-confirmed and clear PRs
never spend a model call.

Install it by cloning into your skills directory:

```bash
git clone https://github.com/neolitec/bot-labeller ~/.claude/skills/bot-labeller
```

Then ask Claude things like:

> *"Is PR 187 written by a bot?"*
> *"Triage the incoming PRs on this repo."*
> *"Audit @some-user — do they drive-by?"*

The skill reports both scores with the evidence lines that drove them, states the
axis distinction explicitly so "AI-assisted" is never read as an accusation, and
only touches labels when asked. See [SKILL.md](SKILL.md) for the full playbook.

## Testing

```bash
./scripts/self-test.sh
```

Asserts the triage band matrix offline, including the corners no real PR happens
to cover. CI runs the same script on every pull request, and the release
pipeline runs it again before anything ships.

## Versioning and releases

Two kinds of tag, on purpose:

| Tag | Moves? | For |
|:--|:--|:--|
| `v1.2.0` | never | pinning to an exact, auditable commit |
| `v1` | yes, to the newest `v1.x` | getting fixes without editing your workflow |

`uses: neolitec/bot-labeller@v1` is the convenient default. Pin `@v1.2.0`, or a
commit SHA, if you would rather review each change before it runs against your
pull requests — the action holds a write token, so that is a legitimate choice.

### Cutting a release

Pushing an immutable `vX.Y.Z` tag is the whole interface. Everything else is
automated by `.github/workflows/release.yml`:

```bash
git switch main && git pull
git tag -a v1.2.0 -m 'v1.2.0'
git push origin v1.2.0
```

The workflow then runs the self-test, cuts the GitHub Release with generated
notes, and re-points `v1` at the new commit — in that order, so a failing test
leaves consumers on the last good release rather than on a half-finished one.

Do **not** move `v1` by hand. Consumers are pointed at it, so it changes their
behaviour silently and with no release notes to explain what changed.

Which number to bump, given the action's surface is its inputs, outputs and
labels:

- **patch** — a scoring fix that does not change the taxonomy
- **minor** — a new input, output or triage verdict
- **major** — a renamed or removed input, or a change to what the labels mean;
  publish it as `v2` and leave `v1` where it is

## Honest limits

These are heuristics, not proof. A determined human trips several of them; an
agent instructed to blend in trips none. The tool is built to narrow attention,
and it deliberately reports evidence rather than a verdict.

It also cannot see private activity, and GitHub's public events feed only reaches
back 90 days or 300 events.

Whether your project accepts unsolicited agent-authored PRs at all is a policy
question — it belongs in your `CONTRIBUTING.md`, not in a score.

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Agent-assisted
PRs are fine here, for obvious reasons; just disclose them. This repo runs its
own action on itself, so an undisclosed one will label itself.

## License

[MIT](LICENSE) © Kevin Manson
