#!/usr/bin/env bash
#
# render-comment.sh — turn bot-score.sh --json output into a PR comment.
#
#   ./scripts/bot-score.sh --json 187 | ./scripts/render-comment.sh
#
# The first line is an HTML marker the workflow greps for, so repeated runs edit
# one comment instead of stacking a new one on every push.

set -euo pipefail
command -v jq >/dev/null || { echo "error: jq not found" >&2; exit 1; }

J="$(cat)"
[ -n "$J" ] || { echo "error: no JSON on stdin" >&2; exit 1; }

A="$(jq -r '.authorship.score' <<<"$J")"
D="$(jq -r '.driveby.score' <<<"$J")"
TR="$(jq -r '.triage.verdict' <<<"$J")"
RAT="$(jq -r '.triage.rationale' <<<"$J")"
HARD="$(jq -r '.hardSignals' <<<"$J")"

meter() { # score -> 20-cell block meter
  local n=$(( $1 / 5 )) i out=""
  for i in $(seq 1 20); do
    if [ "$i" -le "$n" ]; then out="${out}█"; else out="${out}░"; fi
  done
  printf '%s' "$out"
}

case "$TR" in
  CONFIRMED) HEAD="Machine authorship confirmed"; ICON="🤖" ;;
  REVIEW)    HEAD="Authorship unclear — reading pass recommended"; ICON="🔍" ;;
  *)         HEAD="No signals of concern"; ICON="✅" ;;
esac

printf '<!-- bot-labeller -->\n'
printf '### %s %s\n\n' "$ICON" "$HEAD"
printf '| Axis | Score | Reading |\n|:--|:--|:--|\n'
printf '| **Authorship** — was this diff machine-produced? | `%s` %d/100 | %s |\n' \
  "$(meter "$A")" "$A" "$(jq -r '.authorship.verdict' <<<"$J")"
printf '| **Drive-by** — does the account behave like a pipeline? | `%s` %d/100 | %s |\n\n' \
  "$(meter "$D")" "$D" "$(jq -r '.driveby.verdict' <<<"$J")"
printf '**Triage: `%s`** — %s\n\n' "$TR" "$RAT"

# Hard signals first: they are what settles the question.
if [ "$HARD" -gt 0 ]; then
  printf '**Self-declaring signals**\n\n'
  jq -r '.evidence[] | select(.hardness == "hard") | "- **+\(.weight)** \(.text)"' <<<"$J"
  printf '\n'
fi

printf '<details><summary>All signals and context</summary>\n\n'
for axis in authorship driveby; do
  if [ "$(jq -r --arg a "$axis" '[.evidence[] | select(.axis == $a)] | length' <<<"$J")" -gt 0 ]; then
    printf '**%s**\n\n' "$(printf '%s' "$axis" | tr '[:lower:]' '[:upper:]')"
    jq -r --arg a "$axis" '.evidence[] | select(.axis == $a)
      | "- \(if .hardness == "hard" then "**[hard]** " else "" end)+\(.weight) — \(.text)"' <<<"$J"
    printf '\n'
  fi
done
printf '**Context**\n\n'
jq -r '.evidence[] | select(.axis == "context") | "- \(.text)"' <<<"$J"
printf '\n</details>\n\n'

if [ "$TR" = "REVIEW" ]; then
  printf '> No self-declaring signal fired, so this rests on circumstance alone.\n'
  printf '> A human or AI reading pass over the diff and the prose is worth the time here.\n\n'
elif [ "$TR" = "CONFIRMED" ] && [ "$D" -lt 45 ]; then
  printf '> High authorship with a low drive-by score is the ordinary shape of a\n'
  printf '> maintainer using an agent. This is a disclosure, not a finding.\n\n'
fi

printf '<sub>Heuristics, not proof — read the evidence, not the number. '
printf 'Posted by [bot-labeller](https://github.com/neolitec/bot-labeller).</sub>\n'
