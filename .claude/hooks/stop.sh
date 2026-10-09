#!/usr/bin/env bash
# Stop: run the test command named in CLAUDE.md ("Test command: ..." at line start),
# then the token checkpoint. Sequential on purpose: hooks on one event run in parallel,
# so this is the only Stop hook. Failing tests -> exit 2 (blocks stopping, stderr goes to
# Claude) and NO checkpoint. No command -> skip tests, checkpoint anyway.
# Tests are capped at 240s (timeout -> exit 2, no checkpoint); the hook's own 360s limit leaves room for the checkpoint.
INPUT=$(cat)
# Already continuing because of this hook: never block twice (infinite-loop guard).
printf '%s' "$INPUT" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && exit 0
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || exit 0
CMD=$(tr -d '\r' < CLAUDE.md 2>/dev/null | grep -m1 '^Test command:' | sed -e 's/^Test command:[[:space:]]*//' -e 's/^`//' -e 's/`[[:space:]]*$//' -e 's/[[:space:]]*$//')
if [ -n "$CMD" ]; then
  # Pure-bash timeout (macOS has no `timeout`). The watchdog polls once a second so it
  # never outlives the tests or holds the hook's stdio open. STOP_TEST_TIMEOUT is for testing.
  LIMIT="${STOP_TEST_TIMEOUT:-240}"
  case "$LIMIT" in ''|*[!0-9]*) LIMIT=240 ;; esac
  LOG=$(mktemp) || exit 0
  trap 'rm -f "$LOG" "$LOG.timeout"' EXIT
  set -m   # own process group, so a timeout can kill the whole test tree
  bash -c "$CMD" >"$LOG" 2>&1 &
  TPID=$!
  set +m
  ( for _ in $(seq "$LIMIT"); do sleep 1; kill -0 "$TPID" 2>/dev/null || exit 0; done
    : >"$LOG.timeout"; kill -- "-$TPID" 2>/dev/null || kill "$TPID" 2>/dev/null ) >/dev/null 2>&1 &
  { wait "$TPID"; } 2>/dev/null; RC=$?
  if [ -e "$LOG.timeout" ]; then
    { echo "Tests timed out after ${LIMIT}s (\`$CMD\`). Make them faster or fix the hang before stopping."; tail -n 60 "$LOG"; } >&2
    exit 2
  elif [ "$RC" -ne 0 ]; then
    { echo "Tests failed (\`$CMD\`). Fix these before stopping:"; tail -n 60 "$LOG"; } >&2
    exit 2
  fi
fi
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/handoff-check.sh"
exit 0
