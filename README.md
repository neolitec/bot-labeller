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

## Standalone use

The scorer runs perfectly well on its own:

```bash
./scripts/bot-score.sh 187                                  # PR in the current repo
./scripts/bot-score.sh https://github.com/owner/repo/pull/12
./scripts/bot-score.sh @some-user                           # account only
./scripts/bot-score.sh --json 187                           # machine-readable
./scripts/bot-score.sh --label 187                          # apply GitHub labels
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
| `CONFIRMED` | any hard signal | `20` | Settled. No AI pass needed. |
| `REVIEW` | no hard signal, authorship ≥ 25 | `10` | Ambiguous. Send to an AI reading pass. |
| `REVIEW` | no hard signal, drive-by ≥ 45 | `10` | Account looks like a pipeline. |
| `CLEAR` | everything else | `0` | Nothing to answer. |

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
