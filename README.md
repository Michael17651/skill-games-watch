# skill-games-watch

Tracks state legislation on skill-based amusement machines and sweepstakes gaming.

A GitHub Actions workflow queries the LegiScan API on a weekday schedule, compares
each bill's `change_hash` against the previous run, and commits the results to
`data/`. Claude scheduled tasks read `data/changes.json` and combine it with
attorney general opinions, enforcement actions, regulator guidance and tribal
compact activity, which no bill API covers, into a rolling report.

## Files

- `scripts/legiscan_watch.py` pulls and diffs the data
- `.github/workflows/legiscan-watch.yml` runs it at 09:30 UTC, Monday to Friday
- `data/changes.json` what is new or changed since the previous run
- `data/latest.json` every bill currently matching the keyword set
- `data/state.json` bill_id to change_hash, used for change detection

## Setup

1. Add a repository secret named `LEGISCAN_API_KEY` under Settings, Secrets and
   variables, Actions.
2. Run the workflow once by hand from the Actions tab to seed `data/state.json`.
   The first run reports everything as new, which is expected.

## Tuning

`MIN_RELEVANCE` defaults to 40. Raise it to cut noise, lower it to catch more.
Keyword list lives at the top of `scripts/legiscan_watch.py`.

## Notes

Scraping the legiscan.com website is prohibited and will get the key suspended.
Only `api.legiscan.com` is called here. Only one public API key per account is
permitted.

## Attribution

LegiScan API by LegiScan LLC, licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
