# skill-games-watch

Tracks state skill-game and sweepstakes legislation. A GitHub Actions cron job (`scripts/legiscan_watch.py`, weekdays 09:30 UTC, needs the `LEGISCAN_API_KEY` secret) diffs LegiScan bills by change_hash and commits `data/changes.json`, `latest.json` and `state.json` to main. The bot owns `data/`; do not hand-edit those files. No tests. See `README.md`.

The bot also pushes to main. The checkpoint hook runs `git pull --rebase --autostash` before pushing; on a conflict it aborts, leaves commits local, and `.claude/.last_checkpoint_sync_problem` says so (shown at session start). Resolve with `git pull --rebase` by hand.

## Working rules

- Before building anything, write success criteria and the tests that prove them.
- Record each non-trivial design decision in `docs/decisions.md`.
- After finishing a feature, create `docs/explainer-<feature>.html`: a one-page, plain-language visual of what was built and why, for a non-programmer.
- Before pushing a finished feature or milestone, run a review subagent that has not seen this conversation; it reads the diff and the success criteria and reports problems. Fix them before pushing. Checkpoint pushes are backups and need no review.
- If context gets compacted, tell me to run /clear so the next session starts from `resume-note.md`.

## Hooks

- `PreCompact`: forces a checkpoint (commit, update `resume-note.md`, `git pull --rebase`, push). Files over 50 MB are never committed, and a checkpoint that would add over 200 MB commits nothing. Any failure (rebase conflict, other pull failure, rejected push, repo mid-rebase) leaves the commits local, forces nothing, and is written to `.claude/.last_checkpoint_sync_problem`; `SessionStart` shows that note, then injects `resume-note.md`.
- `Stop` (`stop.sh`, the only Stop hook): runs the project's test command first, then the token checkpoint. Failing tests block stopping (once; guarded by `stop_hook_active`; tests are capped at 240s and a timeout counts as a failure) and skip the checkpoint. Define it by adding a line starting with `Test command:` followed by the command. No such line means tests are skipped and only the checkpoint runs.
