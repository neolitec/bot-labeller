# Security policy

## Supported versions

The latest `v1.x` release, which is what the mobile `v1` tag points at. Older
pinned tags stay available but only the newest release receives fixes.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting — **Security → Report a
vulnerability** on this repository — rather than a public issue. You should get
a response within a few days. Reports of anything in the threat model below are
very much in scope, even partial ones.

## Threat model

This action is designed to run on `pull_request_target`, which means it holds a
**write-capable token while evaluating content an attacker controls** (the PR
title, body, branch name, commit messages, and account metadata). The entire
safety argument rests on one invariant:

> **The action never checks out or executes the PR's code.**
> It reads metadata over the GitHub API and writes a label and a comment.

Given that, the interesting vulnerability classes are:

- **Injection through PR-controlled text.** Branch names, titles, bodies and
  commit trailers flow into `bash` and `jq`. Anything that lets that text
  influence execution — command injection, `jq` filter injection, output that
  forges `$GITHUB_OUTPUT` entries or workflow commands — is a critical finding.
- **Escalation of the token.** Any path by which the PR author can make the
  action do more than apply a `bot:` label and post one comment.
- **Verdict forgery.** A crafted PR that flips someone *else's* verdict — for
  example, abusing the sticky-comment marker to overwrite or impersonate the
  report on another PR.

Out of scope: evasion. The README is explicit that an agent instructed to blend
in trips no signals — the tool narrows attention, it does not promise detection.
Evasion reports are welcome as *signal ideas* (see CONTRIBUTING.md), not as
vulnerabilities.

## Hardening guidance for consumers

- Never add `actions/checkout`, an install, or a build step to the workflow
  that runs this action on `pull_request_target`. That breaks the invariant
  above. Keep build/test in a separate `pull_request` workflow.
- Grant only `contents: read` and `pull-requests: write`.
- If you prefer to review each change before it runs with a write token, pin
  `@vX.Y.Z` or a commit SHA instead of the mobile `@v1`.
