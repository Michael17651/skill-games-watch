#!/usr/bin/env bash
# Fires on PreToolUse (every tool call) and on Stop. Reads live token usage
# for the current ccusage 5h billing block and checkpoints (commit + write
# resume-note.md + commit + pull --rebase + push) once both of these hold since the last
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

PROBLEM_FILE=".claude/.last_checkpoint_sync_problem"   # gitignored; session-start.sh shows it
MAX_FILE_BYTES="${CHECKPOINT_MAX_FILE_BYTES:-52428800}"    # 50 MB: bigger single files are never committed
MAX_TOTAL_BYTES="${CHECKPOINT_MAX_TOTAL_BYTES:-209715200}" # 200 MB: if one checkpoint would add more than this, commit nothing
PROBLEMS=""
add_problem() { PROBLEMS="${PROBLEMS}- $1"$'\n'; }

# Looks at what a blanket `git add -A` would sweep in (untracked, modified or already staged files).
#  - A single file over MAX_FILE_BYTES is left out (and unstaged if it was staged), stays on disk, and is reported.
#  - If the files that remain add up to more than MAX_TOTAL_BYTES (many mid-size files, like the
#    ~1.2 GB of PDFs that once got committed), SKIP_COMMIT=1: the working tree is not committed at all.
# Fills BIG_EXCLUDES with pathspecs for `git add`. Symlinks count as a few bytes, as git stores them.
find_big_files() {
  BIG_EXCLUDES=(); SKIP_COMMIT=0
  local p sz total=0 staged
  while IFS= read -r -d '' p; do
    [ -L "$p" ] && continue
    [ -f "$p" ] || continue
    sz=$(wc -c < "$p" 2>/dev/null | tr -d ' ')
    case "$sz" in ''|*[!0-9]*) continue ;; esac
    if [ "$sz" -gt "$MAX_FILE_BYTES" ]; then
      BIG_EXCLUDES+=(":(exclude,literal)$p")
      git reset -q -- ":(literal)$p" 2>/dev/null   # in case it was already staged
      add_problem "not committed, over $((MAX_FILE_BYTES / 1048576)) MB: $p ($((sz / 1048576)) MB). Move it out of the repo, or add it to .gitignore."
    else
      total=$((total + sz))
    fi
  done < <({ git ls-files -z --others --exclude-standard; git ls-files -z -m; git diff --cached --name-only -z --diff-filter=AMR; } 2>/dev/null | sort -zu)
  if [ "$total" -gt "$MAX_TOTAL_BYTES" ]; then
    SKIP_COMMIT=1
    add_problem "nothing was committed: the pending changes add up to $((total / 1048576)) MB, over the $((MAX_TOTAL_BYTES / 1048576)) MB checkpoint limit. Look at git status; add generated or copied folders to .gitignore, commit by hand, or raise CHECKPOINT_MAX_TOTAL_BYTES."
  fi
}

checkpoint() {  # $1 = commit label, $2 = why it fired
  PROBLEMS=""
  find_big_files
  if [ "$SKIP_COMMIT" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
    if [ ${#BIG_EXCLUDES[@]} -gt 0 ]; then git add -A -- . "${BIG_EXCLUDES[@]}"; else git add -A; fi
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
  git commit -m "Add resume notes for checkpoint" -q -- resume-note.md || true   # only the note, even if something else is staged
  sync_and_push
  if [ -n "$PROBLEMS" ]; then
    { printf 'Checkpoint problems (%s). Commits already made stay local; nothing was forced.\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; printf '%s' "$PROBLEMS"; } > "$PROBLEM_FILE"
  else
    rm -f "$PROBLEM_FILE"
  fi
}

# Rebase onto the upstream first, so a bot or another machine pushing doesn't make the push fail.
# Every failure (conflict, any other pull failure, a rejected push, a repo left mid-rebase) is
# recorded with add_problem, the checkpoint commits stay local, and nothing is ever forced.
sync_and_push() {
  export GIT_TERMINAL_PROMPT=0
  local gd out
  gd=$(git rev-parse --git-dir 2>/dev/null) || return 0
  # Someone is mid-rebase/merge by hand: leave the repo alone.
  if [ -e "$gd/rebase-merge" ] || [ -e "$gd/rebase-apply" ] || [ -e "$gd/MERGE_HEAD" ]; then
    add_problem "the repo is in the middle of a rebase or merge, so the checkpoint was not pulled or pushed. Finish or abort it, then push."
    return 0
  fi
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    if ! out=$(git pull --rebase --autostash -q 2>&1); then
      if [ -e "$gd/rebase-merge" ] || [ -e "$gd/rebase-apply" ]; then
        git rebase --abort >/dev/null 2>&1
        add_problem "git pull --rebase hit a conflict and was aborted; checkpoint commits are not pushed. Run git pull --rebase yourself, resolve it, then push."
      else
        add_problem "git pull --rebase failed ($(printf '%s\n' "$out" | grep -v '^hint:' | tail -n 1)); checkpoint commits are not pushed. Offline? If it mentions the stash, check git stash list."
      fi
      return 0
    fi
  fi
  if ! out=$(git push -u origin HEAD 2>&1); then
    out=$(printf '%s\n' "$out" | grep -v '^hint:' | tail -n 1)
    add_problem "git push failed (${out}); checkpoint commits are local only."
  fi
  return 0
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
