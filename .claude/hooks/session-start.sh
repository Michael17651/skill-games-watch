#!/usr/bin/env bash
# SessionStart: print resume-note.md (stdout becomes session context). No-op if absent.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
[ -f resume-note.md ] && head -c 4000 resume-note.md
exit 0
