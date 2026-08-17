# bot-labeller

A Claude Code skill that assesses whether a GitHub pull request was machine-authored
— and, separately, whether the account behaves like a drive-by automation bot.

It scores deterministically first and only escalates to a model when a model would
actually add information.

## Why two scores

"Is this a bot?" is two questions wearing one coat:

- **AUTHORSHIP** — was this diff machine-produced?
- **DRIVE-BY** — does this account fork-and-PR unrelated projects at a cadence no
  person sustains, with no prior involvement?

A high authorship score is not an accusation. Maintainers use Claude Code, Copilot
and Cursor, and disclosing it is healthy. The combination is what matters:

```
high AUTHORSHIP + low DRIVE-BY   → a maintainer used an agent. Normal.
high AUTHORSHIP + high DRIVE-BY  → a drive-by bot.
low  AUTHORSHIP + high DRIVE-BY  → worth a look; the diff is not the only evidence.
```

## Install

Clone into your Claude Code skills directory:

```bash
git clone https://github.com/neolitec/bot-labeller ~/.claude/skills/bot-labeller
```

Then ask Claude things like *"is PR 187 written by a bot?"* or *"triage the incoming
PRs on this repo"*.

Requires [`gh`](https://cli.github.com) (authenticated) and `jq`.

## GitHub Action

```yaml
# .github/workflows/bot-labeller.yml
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

It scores the PR, applies the right label, and posts **one** comment that it edits
on later pushes rather than stacking a new report each time. The comment is always
written in English, regardless of the repository's language.

Once a `bot:` label is on the PR, later runs stop immediately and change nothing —
see [write-once](#labels-are-write-once).

### Why `pull_request_target`, and why that is safe here

The case this check exists for is incoming PRs from forks — and on a `pull_request`
event from a fork, `GITHUB_TOKEN` is **read-only**. The label and the comment both
fail. `pull_request_target` runs in the base repository's context, where the token
can write.

That trigger is genuinely dangerous when misused, because it hands a write token to
a workflow running against a PR the author controls. It is safe here for one
specific reason: **this action never checks out or executes the PR's code.** There is
no `actions/checkout`, no install, no build. It reads PR metadata over the API and
writes a label and a comment. Nothing the contributor wrote is ever run.

If you add a checkout or build step to that workflow file, the guarantee is gone.
Keep those in a separate `pull_request` workflow.

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

## Labels

Every label shares the `bot:` prefix, so the family sorts together in the sidebar and
the whole set is one search away — `label:bot:authored`, or just scan for `bot:` on
the PR list.

| Label | Colour | Meaning |
|:--|:--|:--|
| `bot:authored` | `#57606a` slate | Machine authorship is self-declared. A **neutral fact** — deliberately not a warning colour. |
| `bot:unclear` | `#bf8700` gold | Circumstantial signals only; a reading pass is owed. |
| `bot:drive-by` | `#7d1128` crimson | The only label that asserts a problem. |

The colours carry the argument: grey for a fact, gold for attention, crimson for the
one case that is actually a complaint.

### Labels are write-once

**If the PR already carries a `bot:` label, the run stops immediately** — no
re-score, no relabel, and never a removal. The verdict exits `30`
(`ALREADY_LABELLED`) and the comment step is skipped.

This is deliberate. A label is a checkpoint that a human owns from the moment it
lands. Re-scoring on every push would let a later commit flip it: a rebase that
renames the `agent/` branch, or a body edit that strips the giveaway, would silently
withdraw a verdict a maintainer is already acting on. Automation gets exactly one
say; after that it is a person's call, and **only a person removes a label**.

While no `bot:` label is present, every run is free to evaluate and apply one.

To score a labelled PR anyway, `--recheck` reports without touching the label:

```bash
./scripts/bot-score.sh --recheck 187
```

## Standalone use

The scorer runs perfectly well on its own:

```bash
./scripts/bot-score.sh 187                                  # PR in the current repo
./scripts/bot-score.sh https://github.com/owner/repo/pull/12
./scripts/bot-score.sh @some-user                           # account only
./scripts/bot-score.sh --json 187                           # machine-readable
./scripts/bot-score.sh --label 187                          # apply labels (write-once)
./scripts/bot-score.sh --recheck 187                        # re-score a labelled PR, read-only
./scripts/bot-score.sh --help
```

Example:

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

Every point printed carries the evidence that earned it, including the literal text
that matched. Read the evidence, not the number.

## Hard vs soft, and the review band

A **hard** signal is self-declaring: a registered GitHub App, an agent
`Co-Authored-By` trailer, a generation notice, an `agent/` branch namespace, a
`[bot]` title tag. It settles authorship alone.

A **soft** signal is circumstantial: fork-to-PR latency, issue-to-PR latency, prose
shape, sandbox self-reports, account statistics. Any pile of these stays suggestive.

Triage therefore keys off signal *quality*, not the total:

| Triage | Condition | Exit code | Meaning |
|:--|:--|:--|:--|
| `ALREADY_LABELLED` | a `bot:` label is present | `30` | Stop. A human owns this verdict. |
| `DECLARED_BOT` | author is a GitHub App or type `Bot` | `0` | Exempt. No label, no comment. |
| `CONFIRMED` | any hard signal | `20` | Settled. No AI pass needed. |
| `REVIEW` | no hard signal, authorship ≥ 25 | `10` | Ambiguous. Send to an AI reading pass. |
| `REVIEW` | no hard signal, drive-by ≥ 45 | `10` | Account looks like a pipeline. |
| `CLEAR` | everything else | `0` | Nothing to answer. |

The label check runs **first**, before any scoring, so a labelled PR costs one API
call instead of a full evaluation.

80 points of pure circumstance still earns a reading pass; one hard signal at 25 does
not. That asymmetry is deliberate — it is what keeps the expensive step rare and the
cheap step honest.

Exit codes make it usable from CI:

```yaml
- run: ./scripts/bot-score.sh --label "$PR" || [ $? -eq 10 ] || [ $? -eq 20 ]
```

## What it looks at

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

## Testing

```bash
./scripts/self-test.sh
```

Asserts the triage band matrix offline, including the corners no real PR happens to
cover.

## Limits

These are heuristics, not proof. A determined human trips several of them; an agent
instructed to blend in trips none. The tool is built to narrow attention, and it
deliberately reports evidence rather than a verdict.

It also cannot see private activity, and GitHub's public events feed only reaches
back 90 days or 300 events.

## License

MIT
