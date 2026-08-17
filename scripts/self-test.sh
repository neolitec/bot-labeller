#!/usr/bin/env bash
#
# self-test.sh — assert the triage band matrix. Runs offline: the bands are what
# decide whether a PR costs an AI reading pass, so they are worth pinning down
# independently of whichever PRs happen to exist to test against.
#
#   ./scripts/self-test.sh

set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0

check() { # authorship driveby hard  expected_verdict expected_exit  why
  local a="$1" d="$2" h="$3" want="$4" want_exit="$5" why="$6" got got_exit
  got="$(./scripts/bot-score.sh --triage-only "$a" "$d" "$h" --json 2>/dev/null | jq -r .triage.verdict)"

  got_exit="$(./scripts/bot-score.sh --triage-only "$a" "$d" "$h" >/dev/null 2>&1; echo $?)"
  if [ "$got" = "$want" ] && [ "$got_exit" = "$want_exit" ]; then
    printf '  ok    a=%-3s d=%-3s hard=%s -> %-9s %s\n' "$a" "$d" "$h" "$got" "$why"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  a=%-3s d=%-3s hard=%s -> %s/%s, wanted %s/%s  %s\n' \
      "$a" "$d" "$h" "$got" "$got_exit" "$want" "$want_exit" "$why"
    FAIL=$((FAIL + 1))
  fi
}

printf '\nTriage bands\n\n'

# A hard signal settles it, at any score, on either axis.
check 100 100 6 CONFIRMED 20 "self-declared bot, drive-by account"
check  92   0 2 CONFIRMED 20 "maintainer disclosing agent use"
check  25   0 1 CONFIRMED 20 "one hard signal is enough on its own"

# No hard signal: circumstance alone must route to a reading pass, never to a
# verdict. This is the band the tool exists to identify.
check  80   0 0 REVIEW    10 "high but purely circumstantial"
check  45  20 0 REVIEW    10 "mid circumstantial"
check  25   0 0 REVIEW    10 "lower edge of the review band"
check  24   0 0 CLEAR      0 "just below the edge"

# A human-reading PR from an account that behaves like a pipeline still deserves
# a look — the diff is not the only thing being judged.
check   0  45 0 REVIEW    10 "clean PR, pipeline-shaped account"
check   0  44 0 CLEAR      0 "clean PR, unremarkable account"
check  12  25 0 CLEAR      0 "the human control case (#163)"

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
