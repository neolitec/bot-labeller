#!/usr/bin/env bash
#
# bot-score.sh — score a GitHub pull request on two independent axes, then decide
# whether the case is settled by evidence or needs a human/AI reading pass.
#
#   ./scripts/bot-score.sh 187
#   ./scripts/bot-score.sh https://github.com/owner/repo/pull/12
#   ./scripts/bot-score.sh @some-user            # account-only scoring
#   ./scripts/bot-score.sh --json 187            # machine-readable
#   ./scripts/bot-score.sh --label 187           # apply GitHub labels
#
# TWO AXES, because they answer different questions and must not be averaged:
#
#   AUTHORSHIP — was this diff machine-produced? A high score is NOT a verdict on
#                the contribution. Many good PRs are written with Claude Code,
#                Copilot or Cursor, and saying so is healthy, not suspect.
#   DRIVE-BY   — does the account fork-and-PR unrelated projects at a cadence no
#                person sustains, with no prior involvement? This is the axis that
#                actually predicts unsolicited, low-effort volume.
#
# HARD vs SOFT signals decide the triage. A hard signal is self-declaring: a
# registered App, an agent `Co-Authored-By` trailer, a generation notice, an
# `agent/` branch namespace. Those settle the question on their own. Soft signals
# are circumstantial — timing, prose shape, account statistics — and a pile of
# them is suggestive, never conclusive. So the recommendation is not a function of
# the total alone: 80 points of pure circumstance still warrants a reading pass,
# while one hard signal at 40 does not.
#
# Exit codes, for CI use:
#   0  no reading pass needed        20  machine authorship confirmed (hard signal)
#   10 reading pass recommended      1   usage or API error
#
# Heuristics, not proof. A determined human can trip any of these, and an agent
# told to hide will trip none. Read the evidence lines, not the number.

set -euo pipefail

# Resolve the current repo from the git remote first: `gh repo view --json` is
# GraphQL-only, so it goes dark during a GraphQL outage and the bare-number form
# loses its repo context. Parsing the remote works offline and covers SSH, HTTPS,
# scp-style and .git-suffixed URLs alike; gh stays as the fallback.
repo_from_remote() {
  local url
  url="$(git remote get-url upstream 2>/dev/null || git remote get-url origin 2>/dev/null)" || return 1
  printf '%s' "$url" \
    | sed -E 's#^git@[^:]+:#/#; s#^ssh://[^/]+/#/#; s#^https?://[^/]+/#/#; s#\.git$##' \
    | sed -E 's#^/##' \
    | grep -E '^[^/]+/[^/]+$' || return 1
}

REPO="$(repo_from_remote 2>/dev/null || gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
JSON_OUT=0
DO_LABEL=0
TARGET=""

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

TRIAGE_ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    # Evaluate the triage bands for given scores without touching the network.
    # Exists so the band matrix is testable: real PRs rarely cover every corner.
    #   bot-score.sh --triage-only <authorship> <driveby> <hardSignals>
    --triage-only) TRIAGE_ONLY=1; AUTHOR_SCORE="${2:?}"; DRIVEBY_SCORE="${3:?}"; HARD_HITS="${4:?}"; shift 4 ;;
    --repo)  REPO="${2:-}"; shift 2 ;;
    --json)  JSON_OUT=1; shift ;;
    --label) DO_LABEL=1; shift ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) TARGET="$1"; shift ;;
  esac
done

if [ -n "$TRIAGE_ONLY" ]; then
  LOGIN="(triage-only)"; PR_NUMBER=""; SKIP_ACCOUNT=1; EV_COUNT=0
else
  [ -n "$TARGET" ] || die "give a PR number, PR URL, or @username (see --help)"
  command -v gh >/dev/null || die "gh CLI not found"
  command -v jq >/dev/null || die "jq not found"
fi

# ---------------------------------------------------------------- date helpers

to_epoch() { # ISO8601 -> unix seconds, GNU and BSD date
  if date -u -d "$1" +%s 2>/dev/null; then return 0; fi
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s
}

human_delta() {
  local s="$1"
  if   [ "$s" -lt 60 ];    then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ];  then printf '%dm %ds' $((s / 60)) $((s % 60))
  elif [ "$s" -lt 86400 ]; then printf '%dh %dm' $((s / 3600)) $(((s % 3600) / 60))
  else printf '%dd' $((s / 86400)); fi
}

# ------------------------------------------------------------- score machinery

# Defaults only: --triage-only seeds these from the command line, so do not clobber.
AUTHOR_SCORE="${AUTHOR_SCORE:-0}"
DRIVEBY_SCORE="${DRIVEBY_SCORE:-0}"
HARD_HITS="${HARD_HITS:-0}"
EVIDENCE=""   # "axis|hardness|weight|text" per line

add() { # axis weight text  [soft]
  local axis="$1" weight="$2" text="$3"
  case "$axis" in
    authorship) AUTHOR_SCORE=$((AUTHOR_SCORE + weight)) ;;
    driveby)    DRIVEBY_SCORE=$((DRIVEBY_SCORE + weight)) ;;
  esac
  EVIDENCE="${EVIDENCE}${axis}|soft|${weight}|${text}"$'\n'
}

addh() { # axis weight text  [hard / self-declaring]
  local axis="$1" weight="$2" text="$3"
  case "$axis" in
    authorship) AUTHOR_SCORE=$((AUTHOR_SCORE + weight)) ;;
    driveby)    DRIVEBY_SCORE=$((DRIVEBY_SCORE + weight)) ;;
  esac
  HARD_HITS=$((HARD_HITS + 1))
  EVIDENCE="${EVIDENCE}${axis}|hard|${weight}|${text}"$'\n'
}

note() { EVIDENCE="${EVIDENCE}context|info|0|${1}"$'\n'; }

# kw / kwh — scan a corpus for one category pattern and report the matched text.
# One category is one alternation pattern, so a category can score at most once
# no matter how many of its phrasings appear.
kw()  { local c="$1" ax="$2" w="$3" pat="$4" desc="$5" hit
        hit="$(printf '%s' "$c" | grep -oiE "$pat" | head -1 || true)"
        [ -n "$hit" ] && add  "$ax" "$w" "$desc — matched \"$(printf '%s' "$hit" | cut -c1-60)\"" || true; }
kwh() { local c="$1" ax="$2" w="$3" pat="$4" desc="$5" hit
        hit="$(printf '%s' "$c" | grep -oiE "$pat" | head -1 || true)"
        [ -n "$hit" ] && addh "$ax" "$w" "$desc — matched \"$(printf '%s' "$hit" | cut -c1-60)\"" || true; }

# ----------------------------------------------------------- keyword catalogue

# Agent tool names, used in several corpora below.
AGENTS='claude|codex|copilot|cursor|devin|sweep|jules|aider|cline|roo ?code|windsurf|openhands|swe-?agent|autogpt|goose|opencode|amp|factory|bolt\.new|lovable|v0\.dev|gemini-?cli|qwen-?coder'

# Branch namespaces that agents and harnesses reserve for themselves.
BRANCH_NS="^(agent|agents|ai|bot|auto|llm|${AGENTS})[-/_]"

# A harness describing its own sandbox. The single most reliable prose tell:
# humans do not narrate their toolchain's absence in a PR body.
SANDBOX='(not|n.t) (installed|available|present) in (this|the) (environment|sandbox|container)|in (this|the) (environment|sandbox)[,.]? (so|because|as|therefore)|(could|can|did) ?n.t (be )?(run|execute|verif(y|ied)|install)[^.]{0,40}(local|here|environment|sandbox)|no network access|network (is )?(disabled|unavailable|restricted)|(browser|playwright|chromium) binar(y|ies)|sandbox(ed)? environment|unable to (run|verify|execute)[^.]{0,30}(here|locally|in this)'

# The canonical agent PR-body scaffold.
TEMPLATE='^#{1,3} (summary|test plan|validation|changes|what changed|notes|verification)'

# Self-declaration in the title.
TITLE_TAG="\\[(ai|bot|agent|automated|${AGENTS})\\]|^(ai|bot|agent)[:/]"

# First-person narration of a work session.
FIRSTPERSON="i (ran|verified|checked|confirmed|updated|added|removed|did ?n.t|have not|couldn.t|was unable)|i.ve (added|updated|removed|verified|run)|let me know if"

# Claimed validation, usually a command list.
VALIDATED='all (tests|checks) (pass|passed)|tests pass (locally|cleanly)|(pnpm|npm|yarn|bun) (run )?(test|lint|build)( |$)'

# ------------------------------------------------------------------ PR context

PR_NUMBER=""
LOGIN=""

case "$TARGET" in
  @*)    LOGIN="${TARGET#@}" ;;
  http*) PR_NUMBER="${TARGET##*/}"
         REPO="$(printf '%s' "$TARGET" | sed -E 's#https?://[^/]+/([^/]+/[^/]+)/pull/.*#\1#')" ;;
  *)     PR_NUMBER="$TARGET" ;;
esac

[ -n "$REPO" ] || [ -n "$TRIAGE_ONLY" ] || die "no repo context; pass --repo owner/name"

if [ -n "$PR_NUMBER" ]; then
  # Deliberately REST, not `gh pr view --json`: the latter is GraphQL-only, and a
  # GraphQL outage then surfaces as "cannot read PR" — indistinguishable from a PR
  # that does not exist. Errors are reported verbatim rather than swallowed.
  if ! PR_RAW="$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1)"; then
    die "cannot read PR #$PR_NUMBER in $REPO — $(printf '%s' "$PR_RAW" | head -1)"
  fi
  COMMITS_RAW="$(gh api "repos/$REPO/pulls/$PR_NUMBER/commits" --paginate 2>/dev/null || echo '[]')"

  PR_JSON="$(jq -n --argjson p "$PR_RAW" --argjson c "$COMMITS_RAW" '{
    number: $p.number, title: $p.title,
    author: { login: $p.user.login },
    createdAt: $p.created_at, body: ($p.body // ""),
    headRefName: $p.head.ref,
    isCrossRepository: (($p.head.repo.full_name // "") != ($p.base.repo.full_name // "")),
    headRepositoryOwner: { login: ($p.head.repo.owner.login // "") },
    additions: $p.additions, deletions: $p.deletions, changedFiles: $p.changed_files,
    commits: [ $c[] | {
      oid: .sha, authoredDate: .commit.author.date,
      messageHeadline: (.commit.message | split("\n")[0]),
      messageBody: (.commit.message | split("\n")[1:] | join("\n")) } ]
  }')"

  LOGIN="$(jq -r '.author.login' <<<"$PR_JSON")"
  TITLE="$(jq -r '.title' <<<"$PR_JSON")"
  BRANCH="$(jq -r '.headRefName' <<<"$PR_JSON")"
  PR_CREATED="$(jq -r '.createdAt' <<<"$PR_JSON")"
  PR_BODY="$(jq -r '.body // ""' <<<"$PR_JSON")"
  IS_FORK="$(jq -r '.isCrossRepository' <<<"$PR_JSON")"
  FORK_OWNER="$(jq -r '.headRepositoryOwner.login // ""' <<<"$PR_JSON")"
  N_COMMITS="$(jq -r '.commits | length' <<<"$PR_JSON")"
  FIRST_COMMIT_AT="$(jq -r '[.commits[].authoredDate] | sort | first // ""' <<<"$PR_JSON")"
  COMMIT_MSGS="$(jq -r '[.commits[] | .messageHeadline + "\n" + (.messageBody // "")] | join("\n")' <<<"$PR_JSON")"

  note "PR #$(jq -r .number <<<"$PR_JSON") in $REPO by $LOGIN"
  note "\"$TITLE\""
  note "branch \`$BRANCH\`"
  note "$(jq -r '"+\(.additions)/-\(.deletions) across \(.changedFiles) file(s), \(.commits|length) commit(s)"' <<<"$PR_JSON")"

  # -- branch name ----------------------------------------------------------
  kwh "$BRANCH" authorship 25 "$BRANCH_NS"  "branch sits in an agent namespace"
  if ! printf '%s' "$BRANCH" | grep -qiE "$BRANCH_NS"; then
    kw "$BRANCH" authorship 12 "$AGENTS" "branch name contains an agent tool name"
  fi

  # -- title ----------------------------------------------------------------
  kwh "$TITLE" authorship 25 "$TITLE_TAG" "title carries a self-declared automation tag"

  # -- explicit disclosure in commits or body -------------------------------
  kwh "$COMMIT_MSGS$PR_BODY" authorship 40 \
      "co-authored-by:[^\\n]*($AGENTS|bot@|noreply\\.github)" "agent \`Co-Authored-By\` trailer"
  kwh "$COMMIT_MSGS$PR_BODY" authorship 40 \
      "generated (with|by)|🤖|written by ($AGENTS)|created (with|by) ($AGENTS)|assisted by ($AGENTS)" \
      "explicit generation notice"

  # -- prose shape ----------------------------------------------------------
  kw "$PR_BODY" authorship 15 "$SANDBOX"      "body reports its own sandbox limits — a harness describing itself"
  kw "$PR_BODY" authorship 10 "$FIRSTPERSON"  "body narrates a work session in the first person"
  kw "$PR_BODY" authorship  8 "$VALIDATED"    "body asserts a validation run"
  if [ "$(printf '%s' "$PR_BODY" | grep -ciE "$TEMPLATE" || true)" -ge 2 ]; then
    add authorship 12 "body uses the canonical agent section scaffold (2+ of Summary / Test plan / Validation / Changes)"
  fi

  # -- timing forensics: the strongest signal available without prose --------
  PR_EPOCH="$(to_epoch "$PR_CREATED")"

  if [ "$IS_FORK" = "true" ] && [ -n "$FORK_OWNER" ]; then
    FORK_CREATED="$(gh api "repos/$FORK_OWNER/${REPO##*/}" -q .created_at 2>/dev/null || true)"
    if [ -n "$FORK_CREATED" ]; then
      FORK_EPOCH="$(to_epoch "$FORK_CREATED")"
      D=$((PR_EPOCH - FORK_EPOCH))
      if [ "$D" -ge 0 ]; then
        note "fork -> PR: $(human_delta "$D")"
        if   [ "$D" -lt 120 ]; then add authorship 20 "fork to PR in $(human_delta "$D") — no human reads a codebase that fast"
        elif [ "$D" -lt 900 ]; then add authorship 12 "fork to PR in $(human_delta "$D")"
        fi
      fi
      if [ -n "$FIRST_COMMIT_AT" ]; then
        C=$((FORK_EPOCH - $(to_epoch "$FIRST_COMMIT_AT"))); C=${C#-}
        [ "$C" -lt 60 ] && add authorship 15 "first commit authored ${C}s from the fork — work predates or is instant" || true
      fi
    fi
  fi

  # -- issue -> PR latency --------------------------------------------------
  ISSUE_NUM="$(printf '%s' "$PR_BODY" \
    | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
    | grep -oE '[0-9]+' | sort -n | head -1 || true)"
  if [ -n "$ISSUE_NUM" ]; then
    ISSUE_AT="$(gh api "repos/$REPO/issues/$ISSUE_NUM" -q .created_at 2>/dev/null || true)"
    if [ -n "$ISSUE_AT" ]; then
      D=$((PR_EPOCH - $(to_epoch "$ISSUE_AT")))
      if [ "$D" -ge 0 ]; then
        note "issue #$ISSUE_NUM -> PR: $(human_delta "$D")"
        if   [ "$D" -lt 600 ];  then add authorship 18 "PR landed $(human_delta "$D") after issue #$ISSUE_NUM was filed"
        elif [ "$D" -lt 3600 ]; then add authorship 8  "PR landed $(human_delta "$D") after issue #$ISSUE_NUM was filed"
        fi
      fi
    fi
  fi

  # -- burst commits --------------------------------------------------------
  if [ "$N_COMMITS" -gt 1 ]; then
    SPAN="$(jq -r '[.commits[].authoredDate] | sort | (last, first)' <<<"$PR_JSON" | {
      read -r a; read -r b; echo $(( $(to_epoch "$a") - $(to_epoch "$b") )); })"
    [ "$SPAN" -lt 60 ] && add authorship 10 "all $N_COMMITS commits authored within ${SPAN}s" || true
  fi
fi

# -------------------------------------------------------------- account shape

# A GitHub App author has no user record: gh reports `app/dependabot`, and
# users/app%2Fdependabot 404s. Short-circuit — a declared App needs no scoring.
if printf '%s' "$LOGIN" | grep -qE '^app/|\[bot\]$'; then
  addh authorship 100 "author is a declared GitHub App (\`$LOGIN\`) — machine by definition"
  note "declared App: volume is the point of a bot, so DRIVE-BY is not scored"
  AUTHOR_SCORE=100; DRIVEBY_SCORE=0; EV_COUNT=0; SKIP_ACCOUNT=1
fi

if [ "${SKIP_ACCOUNT:-0}" != "1" ]; then
USER_JSON="$(gh api "users/$LOGIN" 2>/dev/null)" || die "cannot read user $LOGIN"

U_TYPE="$(jq -r '.type' <<<"$USER_JSON")"
U_CREATED="$(jq -r '.created_at' <<<"$USER_JSON")"
U_REPOS="$(jq -r '.public_repos' <<<"$USER_JSON")"
U_FOLLOWERS="$(jq -r '.followers' <<<"$USER_JSON")"
U_BIO="$(jq -r '.bio // ""' <<<"$USER_JSON")"

[ "$U_TYPE" = "Bot" ] && addh authorship 100 "account type is Bot" || true

AGE_DAYS=$(( ( $(date -u +%s) - $(to_epoch "$U_CREATED") ) / 86400 ))
AGE_MONTHS=$(( AGE_DAYS / 30 )); [ "$AGE_MONTHS" -gt 0 ] || AGE_MONTHS=1
REPOS_PER_MONTH=$(( U_REPOS / AGE_MONTHS ))

note "account: created ${U_CREATED%%T*} (${AGE_DAYS}d), ${U_REPOS} repos, ${U_FOLLOWERS} followers"
note "repo creation rate: ~${REPOS_PER_MONTH}/month"

if   [ "$REPOS_PER_MONTH" -ge 15 ]; then add driveby 20 "~${REPOS_PER_MONTH} repos created per month — consistent with automated forking"
elif [ "$REPOS_PER_MONTH" -ge 8 ];  then add driveby 10 "~${REPOS_PER_MONTH} repos created per month"
fi

if [ "$U_FOLLOWERS" -lt 15 ] && [ -z "$U_BIO" ]; then
  add driveby 10 "no bio and ${U_FOLLOWERS} followers — no social footprint"
fi

# ------------------------------------------------------- public event patterns

EV="$(gh api "users/$LOGIN/events/public" --paginate 2>/dev/null || echo '[]')"
EV_COUNT="$(jq 'length' <<<"$EV")"

if [ "$EV_COUNT" -gt 0 ]; then
  DISTINCT_REPOS="$(jq -r '[.[].repo.name] | unique | length' <<<"$EV")"
  PR_EVENTS="$(jq -r '[.[] | select(.type=="PullRequestEvent")] | length' <<<"$EV")"
  FORK_EVENTS="$(jq -r '[.[] | select(.type=="ForkEvent")] | length' <<<"$EV")"
  ONE_SHOT="$(jq -r '
    [.[] | select(.type=="PullRequestEvent") | .repo.name]
    | group_by(.) | map(select(length == 1)) | length' <<<"$EV" 2>/dev/null || echo 0)"

  note "recent public events: $EV_COUNT across $DISTINCT_REPOS repos ($PR_EVENTS PRs, $FORK_EVENTS forks)"

  if   [ "$DISTINCT_REPOS" -ge 10 ]; then add driveby 25 "$DISTINCT_REPOS distinct repos in recent activity — scattershot targeting"
  elif [ "$DISTINCT_REPOS" -ge 6 ];  then add driveby 15 "$DISTINCT_REPOS distinct repos in recent activity"
  fi

  if [ "$PR_EVENTS" -gt 0 ] && [ "$FORK_EVENTS" -gt 0 ]; then
    RATIO=$(( PR_EVENTS * 100 / EV_COUNT ))
    [ "$RATIO" -ge 30 ] && add driveby 15 "${RATIO}% of all public activity is opening PRs — no issues, reviews or discussion" || true
  fi

  [ "$ONE_SHOT" -ge 4 ] && add driveby 20 "$ONE_SHOT repos received exactly one PR and no follow-up — opens and leaves" || true

  # Same-minute fork+PR pairs. Both event types must appear in a group: two PR
  # events on one repo in one minute (open then close, or a synchronize) are
  # ordinary and must not count.
  PAIRS="$(jq -r '
    [.[] | select(.type=="ForkEvent" or .type=="PullRequestEvent")
         | {t: .created_at[0:16], r: .repo.name, k: .type}]
    | group_by(.r + .t) | map(select(([.[].k] | unique | length) == 2)) | length' <<<"$EV" 2>/dev/null || echo 0)"
  [ "$PAIRS" -ge 2 ] && add driveby 15 "$PAIRS repos forked and PR'd inside the same minute — a repeated pipeline" || true
else
  note "no public events available (private activity, or beyond the 90-day window)"
fi
fi  # SKIP_ACCOUNT

# --------------------------------------------------------------------- triage

clamp() { [ "$1" -gt 100 ] && echo 100 || echo "$1"; }
AUTHOR_SCORE="$(clamp "$AUTHOR_SCORE")"
DRIVEBY_SCORE="$(clamp "$DRIVEBY_SCORE")"

band() {
  if   [ "$1" -ge 70 ]; then echo "very likely"
  elif [ "$1" -ge 45 ]; then echo "likely"
  elif [ "$1" -ge 25 ]; then echo "possible"
  else echo "little evidence"; fi
}

# The recommendation turns on signal QUALITY, not just the total. One hard signal
# settles authorship; a pile of soft ones does not, however tall.
if [ "$HARD_HITS" -gt 0 ]; then
  TRIAGE="CONFIRMED"
  TRIAGE_LINE="machine authorship is self-declared — no reading pass needed"
  EXIT_CODE=20
elif [ "$AUTHOR_SCORE" -ge 25 ]; then
  TRIAGE="REVIEW"
  TRIAGE_LINE="circumstantial only ($AUTHOR_SCORE pts, no hard signal) — send to an AI reading pass"
  EXIT_CODE=10
elif [ "$DRIVEBY_SCORE" -ge 45 ]; then
  TRIAGE="REVIEW"
  TRIAGE_LINE="the PR reads human but the account looks like a pipeline — send to an AI reading pass"
  EXIT_CODE=10
else
  TRIAGE="CLEAR"
  TRIAGE_LINE="nothing to answer — no reading pass needed"
  EXIT_CODE=0
fi

# ---------------------------------------------------------------------- output

if [ "$JSON_OUT" = "1" ]; then
  jq -n --arg login "$LOGIN" --arg repo "$REPO" --arg pr "${PR_NUMBER:-}" \
        --argjson a "$AUTHOR_SCORE" --argjson d "$DRIVEBY_SCORE" --argjson hard "$HARD_HITS" \
        --arg ab "$(band "$AUTHOR_SCORE")" --arg db "$(band "$DRIVEBY_SCORE")" \
        --arg tr "$TRIAGE" --arg trl "$TRIAGE_LINE" --arg ev "$EVIDENCE" '
    { login: $login, repo: $repo, pr: $pr,
      authorship: { score: $a, verdict: $ab },
      driveby:    { score: $d, verdict: $db },
      hardSignals: $hard,
      triage: { verdict: $tr, rationale: $trl, aiReviewNeeded: ($tr == "REVIEW") },
      evidence: ($ev | rtrimstr("\n") | split("\n") | map(select(length > 0) | split("|")
                | { axis: .[0], hardness: .[1], weight: (.[2] | tonumber), text: .[3] })) }'
  exit "$EXIT_CODE"
fi

bar() { local n=$(( $1 / 5 )) i; printf '['
        for i in $(seq 1 20); do [ "$i" -le "$n" ] && printf '#' || printf '.'; done; printf ']'; }

printf '\n  %s' "$LOGIN"; [ -n "${PR_NUMBER:-}" ] && printf '  —  %s#%s' "$REPO" "$PR_NUMBER"
printf '\n\n'
printf '  AUTHORSHIP  %s  %3d/100   %s machine-authored\n' "$(bar "$AUTHOR_SCORE")" "$AUTHOR_SCORE" "$(band "$AUTHOR_SCORE")"
printf '  DRIVE-BY    %s  %3d/100   %s an automation account\n' "$(bar "$DRIVEBY_SCORE")" "$DRIVEBY_SCORE" "$(band "$DRIVEBY_SCORE")"
printf '\n  TRIAGE      %-8s %s\n' "$TRIAGE" "$TRIAGE_LINE"

printf '\n  Context\n'
printf '%s' "$EVIDENCE" | awk -F'|' '$1=="context" {printf "    · %s\n", $4}'
for axis in authorship driveby; do
  if printf '%s' "$EVIDENCE" | awk -F'|' -v a="$axis" '$1==a' | grep -q .; then
    printf '\n  %s signals\n' "$(printf '%s' "$axis" | tr '[:lower:]' '[:upper:]')"
    printf '%s' "$EVIDENCE" | awk -F'|' -v a="$axis" \
      '$1==a {printf "    %s +%-3d %s\n", ($2=="hard" ? "[hard]" : "      "), $3, $4}'
  fi
done
printf '\n  Heuristics, not proof. AI assistance is not misconduct — high AUTHORSHIP\n'
printf '  with low DRIVE-BY usually just means a maintainer used an agent.\n\n'

# ----------------------------------------------------------------- labelling

if [ "$DO_LABEL" = "1" ] && [ -n "${PR_NUMBER:-}" ]; then
  LABELS=""
  [ "$TRIAGE" = "CONFIRMED" ] && LABELS="ai-authored"
  [ "$TRIAGE" = "REVIEW" ]    && LABELS="needs-ai-review"
  [ "$DRIVEBY_SCORE" -ge 70 ] && LABELS="${LABELS:+$LABELS,}drive-by"
  if [ -n "$LABELS" ]; then
    IFS=','; for l in $LABELS; do
      gh label create "$l" --repo "$REPO" --color ededed --description "applied by bot-labeller" 2>/dev/null || true
    done; unset IFS
    gh api -X POST "repos/$REPO/issues/$PR_NUMBER/labels" -f "labels[]=${LABELS//,/&labels[]=}" >/dev/null 2>&1 \
      || gh pr edit "$PR_NUMBER" --repo "$REPO" $(printf -- '--add-label %s ' ${LABELS//,/ }) >/dev/null 2>&1 \
      || printf '  warning: could not apply labels (%s)\n\n' "$LABELS" >&2
    printf '  labels applied: %s\n\n' "$LABELS"
  else
    printf '  no label warranted\n\n'
  fi
fi

exit "$EXIT_CODE"
