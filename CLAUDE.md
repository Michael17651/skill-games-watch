# skill-games-watch

Tracks state skill-game and sweepstakes legislation. A GitHub Actions cron job (`scripts/legiscan_watch.py`, weekdays 09:30 UTC, needs the `LEGISCAN_API_KEY` secret) diffs LegiScan bills by change_hash and commits `data/changes.json`, `latest.json` and `state.json` to main. The bot owns `data/`; do not hand-edit those files. No tests. See `README.md`.

Because the bot pushes to main, local checkpoint pushes can be rejected as non-fast-forward (the hook swallows that). Run `git pull --rebase` at session start and after any `Auto-handoff:` commit that did not push.

## Working rules

- Before building anything, write success criteria and the tests that prove them.
- Record each non-trivial design decision in `docs/decisions.md`.
- After finishing a feature, create `docs/explainer-<feature>.html`: a one-page, plain-language visual of what was built and why, for a non-programmer.
- Before pushing, run a review subagent that has not seen this conversation; it reads the diff and the success criteria and reports problems. Fix them before pushing.
- If context gets compacted, tell me to run /clear so the next session starts from `resume-note.md`.

## Hooks

- `PreCompact`: forces a checkpoint (commit, update `resume-note.md`, push). `SessionStart`: injects `resume-note.md`.
- `Stop` (`stop.sh`, the only Stop hook): runs the project's test command first, then the token checkpoint. Failing tests block stopping (once; guarded by `stop_hook_active`; tests are capped at 240s and a timeout counts as a failure) and skip the checkpoint. Define it by adding a line starting with `Test command:` followed by the command. No such line means tests are skipped and only the checkpoint runs.
