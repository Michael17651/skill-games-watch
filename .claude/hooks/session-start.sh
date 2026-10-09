#!/usr/bin/env bash
# SessionStart: print the checkpoint sync problem (if any) and resume-note.md (stdout becomes session context).
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
# A checkpoint that could not sync (rebase conflict) leaves a note; show it before the resume note.
[ -f .claude/.last_checkpoint_sync_problem ] && { echo "## Checkpoint sync problem"; cat .claude/.last_checkpoint_sync_problem; echo; }
[ -f resume-note.md ] && head -c 4000 resume-note.md
exit 0
