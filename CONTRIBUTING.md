# Contributing

Thanks for looking at this. The project is small on purpose — a scorer, a
composite action around it, and a Claude Code skill — so most contributions are
one of three shapes.

## What makes a good contribution

- **A new signal.** Bring evidence: a real PR (or a redacted transcript of one)
  where the signal fired and a human would have agreed. Say whether it is
  **hard** (self-declaring, settles authorship alone) or **soft**
  (circumstantial, only ever suggestive) — that distinction drives the whole
  triage, so it is the first question a review will ask.
- **A false-positive fix.** Same standard in reverse: show the PR that was
  scored unfairly and which line of evidence was wrong.
- **Docs and workflow ergonomics.** The README and `examples/` are part of the
  product surface.

Things that will get pushback: collapsing the two axes into one score, making
labels removable by automation, adding a checkout or execution step to the
action (see [SECURITY.md](SECURITY.md)), or adding a runtime dependency beyond
`bash`, `gh` and `jq`.

## Before you open a PR

```bash
./scripts/self-test.sh
```

This pins the triage band matrix offline — no token, no network. CI runs exactly
this on your PR. If you change scoring or banding, extend the self-test to cover
the new corner; a band change without a test is the one thing that ships silent
behaviour to every consumer on `@v1`.

Shell style: `bash`, `set -uo pipefail`, no GNU-only flags that break on macOS.
Comments explain *why*, not *what*.

## Disclose agent assistance

Agent-assisted PRs are welcome here — it would be a strange rule for this repo
to have. Just say so in the PR body. This repository runs its own action on
itself, so an undisclosed one will, fittingly, label itself.

## Releases

Maintainers only — the process is documented in the README under
[Cutting a release](README.md#cutting-a-release). The short version: push an
annotated `vX.Y.Z` tag and the release workflow does the rest. Never move `v1`
by hand.
