---
name: bot-labeller
description: Assess whether a GitHub pull request was machine-authored and whether the account behaves like a drive-by automation bot. Runs a deterministic scorer over branch names, PR title and body keywords, commit trailers, timing forensics and account activity, then routes only genuinely ambiguous cases to an AI reading pass. Use when the user asks whether a PR or contributor is a bot, AI, agent or automated; asks to evaluate, triage, label or vet an incoming contribution; wonders if a PR was "written by AI"; or wants to audit unsolicited pull requests on a repository.
---

# bot-labeller

Two questions get conflated when people ask "is this a bot?", and answering them
separately is the whole point of this skill:

| Axis | Question | What a high score means |
|:--|:--|:--|
| **AUTHORSHIP** | Was this diff machine-produced? | Nothing on its own. Plenty of good PRs are written with Claude Code, Copilot or Cursor. |
| **DRIVE-BY** | Does this account fork-and-PR unrelated projects at a cadence no person sustains? | This is the axis that predicts unsolicited, low-effort volume. |

`high AUTHORSHIP + low DRIVE-BY` is a maintainer using an agent. That is normal.
`high + high` is a drive-by bot. Never collapse the two into one number.

## Run the scorer first

```bash
./scripts/bot-score.sh 187                                  # PR in the current repo
./scripts/bot-score.sh https://github.com/owner/repo/pull/12
./scripts/bot-score.sh @some-user                           # account only
./scripts/bot-score.sh --json 187                           # machine-readable
./scripts/bot-score.sh --label 187                           # apply GitHub labels
```

Requires `gh` (authenticated) and `jq`. It reads GitHub over REST only, so it keeps
working during the GraphQL outages that break `gh pr view --json`.

## Hard vs soft signals decide what happens next

A **hard** signal is self-declaring — a registered GitHub App, an agent
`Co-Authored-By` trailer, a generation notice, an `agent/` branch namespace, a
`[bot]` title tag. It settles authorship by itself.

A **soft** signal is circumstantial — fork-to-PR latency, issue-to-PR latency,
prose shape, sandbox self-reports, account statistics. A tall pile of soft signals
is suggestive and still not conclusive.

So the triage does **not** key off the total:

| Triage | Condition | Exit | Action |
|:--|:--|:--|:--|
| `CONFIRMED` | any hard signal | 20 | Report it. **No AI pass** — the evidence already speaks. |
| `REVIEW` | no hard signal **and** authorship ≥ 25 | 10 | **Run the AI reading pass below.** |
| `REVIEW` | no hard signal **and** drive-by ≥ 45 | 10 | **Run the AI reading pass below.** |
| `CLEAR` | everything else | 0 | Report it. No AI pass. |

The `REVIEW` band exists because that is the only place a model adds information.
Below it there is nothing to answer; above it the PR has already told on itself, and
spending a reading pass would just re-derive a fact you already have.

`./scripts/self-test.sh` pins this matrix offline.

## The AI reading pass — only for `REVIEW`

Read the diff and the prose, and judge the things a regex cannot. Report a verdict
with confidence, and cite specifics.

**In the prose**
- Does the body explain *why*, or only restate *what* the diff does? Agents narrate
  changes; authors justify them.
- Is there any trace of the mess of real work — a rejected approach, a caveat, an
  unresolved question, a "not sure this is right"? Its complete absence in a
  non-trivial change is a signal.
- Does the register match the repo's other PRs by that author, and the project's
  own conventions?
- Does it claim validation it could not have run? Cross-check against whether CI
  actually executed. Fork PRs from first-time contributors need workflow approval,
  so a claimed green suite is often unverified.

**In the diff**
- Does it solve the problem stated, or the problem's *description*? Agents
  frequently satisfy the literal issue text while missing the intent.
- Is it internally consistent, or does it half-apply its own convention — two
  helpers converted and two left alone, one call site updated of three?
- Are there unmentioned semantic changes riding along (hoisting, evaluation order,
  error paths) that the body does not acknowledge?
- Does it touch anything it had no reason to touch? Reformatted lines, reordered
  imports, version bumps.

**Weigh it honestly.** A small, correct, well-explained change from a new account is
just a contribution. Fork-to-PR speed scales with how small the fix is: a stray `&&`
in `package.json` genuinely is a three-minute job. Do not let a single soft signal
carry a verdict, and say plainly when the reading pass is inconclusive.

## Reporting

Lead with the two scores and the triage verdict, then the evidence lines that
actually drove it — not the whole dump. State the axis distinction explicitly when
authorship is high and drive-by is low, so nobody reads "AI-assisted" as an
accusation.

If the outcome is a policy question (whether the project accepts unsolicited
agent-authored PRs at all), name it as a policy question and leave the call to the
maintainer. That belongs in `CONTRIBUTING.md`, not in a score.

## Labelling

`--label` applies `ai-authored` on `CONFIRMED`, `needs-ai-review` on `REVIEW`, and
adds `drive-by` when that axis is ≥ 70. Labels are created on demand. It writes to
the repository, so only pass it when the user has asked for labels.
