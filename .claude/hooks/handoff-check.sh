#!/usr/bin/env bash
# Fires on PreToolUse (every tool call) and on Stop. Reads live token usage
# for the current ccusage 5h billing block and checkpoints (commit + write
# resume-note.md + commit + push) once both of these hold since the last
# checkpoint:
#   1. billable tokens (totalTokens minus cache-read tokens) have crossed a
#      new CHECKPOINT_INCREMENT-token step, and
#   2. at least MIN_INTERVAL_SECONDS have elapsed.
#
# Cache reads are excluded from the metric because they re-count the whole
# context on every turn, so totalTokens alone climbs by millions per turn and
# any sane token threshold fires constantly. The time floor is a second,
# independent guard: it holds even if ccusage's field names change again and
# the cache-read subtraction silently falls back to raw totalTokens.
#
# This is non-blocking by design: it never stops the session or exits
# non-zero for the session's sake. It just leaves a trail of safe restore
# points so a resume-note.md is never more than one increment (and at least
# MIN_INTERVAL_SECONDS) stale.
set -uo pipefail
# Desktop-app hooks can run with a minimal PATH. Add the usual Homebrew,
# npm-global and Windows-safe locations so node and ccusage resolve. Missing
# directories are harmless.
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME:-}/.npm-global/bin:$PATH"
cd "$CLAUDE_PROJECT_DIR" || exit 0

STATE_FILE=".claude/.last_checkpoint_tokens"
TIME_FILE=".claude/.last_checkpoint_time"
CHECKPOINT_INCREMENT=100000
MIN_INTERVAL_SECONDS=900

checkpoint() {  # $1 = commit label, $2 = why it fired
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "Auto-handoff: $1" -q || true
  fi

  {
    echo "# Resume Notes"
    echo
    echo "Auto-generated $(date -u +"%Y-%m-%dT%H:%M:%SZ") — $2"
    echo
    echo "## Last commit"
    git log -1 --pretty=format:"%H %s (%ci)" 2>/dev/null
    echo
    echo
    echo "## Working tree status at checkpoint"
    git status --short 2>/dev/null
    echo
    echo "## Next steps"
    echo "- This is a routine checkpoint, not a stop — the session continues normally."
    echo "- If a session does end unexpectedly, resume by starting a new Claude Code session in this repo and reading this file."
  } > resume-note.md

  git add resume-note.md
  git commit -m "Add resume notes for checkpoint" -q || true
  git push -u origin HEAD 2>/dev/null || true
}

# Prints billable tokens for the active block, or nothing if unavailable.
fetch_tokens() {
  # Look for ccusage on PATH first. If it's not there (hooks don't always inherit
  # the shell PATH), try the known install locations: Homebrew on macOS, the
  # custom npm prefix on macOS, then the Windows npm prefix.
  CCUSAGE_BIN="ccusage"
  if ! command -v "$CCUSAGE_BIN" >/dev/null 2>&1; then
    for CANDIDATE in /opt/homebrew/bin/ccusage "${HOME:-}/.npm-global/bin/ccusage" /c/home/mkpc/.npm-global/ccusage; do
      if [ -x "$CANDIDATE" ]; then
        CCUSAGE_BIN="$CANDIDATE"
        break
      fi
    done
  fi
  [ -x "$CCUSAGE_BIN" ] || command -v "$CCUSAGE_BIN" >/dev/null 2>&1 || return 0

  USAGE_JSON=$("$CCUSAGE_BIN" blocks --active --json 2>/dev/null) || return 0
  [ -z "$USAGE_JSON" ] && return 0

  # Billable tokens = totalTokens minus cache-read tokens, since cache reads
  # re-count the whole context every turn. Field naming varies across ccusage
  # versions, so check cacheReadInputTokens, then cacheReadTokens, then
  # cacheRead. If none of them are present, fall back to totalTokens unchanged
  # (the time floor below still protects against over-firing).
  printf '%s' "$USAGE_JSON" | node -e '
  let d = "";
  process.stdin.on("data", c => d += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(d);
      const b = (j.blocks || []).find(x => x.isActive);
      if (!b) { console.log(""); return; }
      const total = Number.isFinite(b.totalTokens) ? b.totalTokens : NaN;
      const tc = b.tokenCounts || {};
      let cacheRead;
      if (Number.isFinite(tc.cacheReadInputTokens)) cacheRead = tc.cacheReadInputTokens;
      else if (Number.isFinite(tc.cacheReadTokens)) cacheRead = tc.cacheReadTokens;
      else if (Number.isFinite(tc.cacheRead)) cacheRead = tc.cacheRead;
      const billable = (Number.isFinite(total) && Number.isFinite(cacheRead)) ? total - cacheRead : total;
      console.log(Number.isFinite(billable) ? billable : "");
    } catch (e) {
      console.log("");
    }
  });
  ' 2>/dev/null
}

# --force (PreCompact hook): checkpoint now, skip the thresholds, but record the
# baseline like a normal checkpoint so the next tool call doesn't re-fire.
if [ "${1:-}" = "--force" ]; then
  checkpoint "pre-compact checkpoint" "PreCompact hook fired, so context is about to be compacted."
  date +%s > "$TIME_FILE"
  # Fetch tokens only after the checkpoint so a slow ccusage can't eat the hook timeout.
  CURRENT_TOKENS=$(fetch_tokens)
  case "$CURRENT_TOKENS" in
    ''|*[!0-9]*) ;;
    *) echo "$CURRENT_TOKENS" > "$STATE_FILE" ;;
  esac
  exit 0
fi

CURRENT_TOKENS=$(fetch_tokens)

# No active block (between sessions) or ccusage/node hiccup — skip quietly.
case "$CURRENT_TOKENS" in
  ''|*[!0-9]*) exit 0 ;;
esac

LAST=0
[ -f "$STATE_FILE" ] && LAST=$(cat "$STATE_FILE")
case "$LAST" in
  ''|*[!0-9]*) LAST=0 ;;
esac

# The active block rolled over to a new 5h window since the last check —
# its token total reset lower than our last checkpoint. Re-baseline instead
# of computing a bogus negative/huge diff.
if [ "$CURRENT_TOKENS" -lt "$LAST" ]; then
  LAST=0
fi

DIFF=$((CURRENT_TOKENS - LAST))
[ "$DIFF" -lt "$CHECKPOINT_INCREMENT" ] && exit 0

# Time floor: a missing or unparseable last-checkpoint time means "allow".
NOW=$(date +%s)
LAST_TIME=0
[ -f "$TIME_FILE" ] && LAST_TIME=$(cat "$TIME_FILE")
case "$LAST_TIME" in
  ''|*[!0-9]*) LAST_TIME=0 ;;
esac

if [ "$LAST_TIME" -gt 0 ]; then
  ELAPSED=$((NOW - LAST_TIME))
  [ "$ELAPSED" -lt "$MIN_INTERVAL_SECONDS" ] && exit 0
fi

checkpoint "checkpoint at ~${CURRENT_TOKENS} billable tokens in current session block" "checkpoint triggered by ccusage billable token usage (~${CURRENT_TOKENS} billable tokens, i.e. totalTokens minus cache reads, in the current 5h session block, a new ${CHECKPOINT_INCREMENT}-token increment since the last checkpoint, at least ${MIN_INTERVAL_SECONDS}s since the previous one)."
echo "$CURRENT_TOKENS" > "$STATE_FILE"
echo "$NOW" > "$TIME_FILE"

exit 0
