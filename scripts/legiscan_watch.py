#!/usr/bin/env python3
"""
Pulls skill-game and sweepstakes-gaming legislation from the LegiScan API and
records what changed since the previous run.

Data source: LegiScan API by LegiScan LLC, licensed under CC BY 4.0.

Outputs (all under data/):
  latest.json   every bill currently matching the keyword set
  changes.json  only what is new or changed since the last run
  state.json    bill_id -> change_hash, used to detect changes next run

Query spend: one getSearchRaw call per keyword per page. With the default
keyword set this is roughly 15 to 30 queries per run, well inside the
30,000 per month public tier.
"""

import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.legiscan.com/"
DATA = Path(__file__).resolve().parent.parent / "data"

# Full-text search terms. Quoted phrases are matched as phrases by LegiScan.
KEYWORDS = [
    '"skill game"',
    '"skill games"',
    '"games of skill"',
    '"amusement device"',
    '"amusement machine"',
    '"gray machine"',
    '"sweepstakes"',
    '"dual currency"',
    '"sweepstakes casino"',
    '"video gaming terminal"',
    '"electronic gaming device"',
]

# LegiScan relevance score, 0-100. Lower catches more and adds noise.
MIN_RELEVANCE = int(os.environ.get("MIN_RELEVANCE", "40"))

# year=2 restricts to the current legislative session.
YEAR = os.environ.get("LEGISCAN_YEAR", "2")

MAX_PAGES = 10


def api_call(params):
    """One LegiScan API call. Returns the parsed payload or raises."""
    params = dict(params)
    params["key"] = os.environ["LEGISCAN_API_KEY"]
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "skill-games-watch/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    # The crash course is explicit: always check status.
    if payload.get("status") != "OK":
        raise RuntimeError(f"LegiScan returned {payload.get('status')}: {payload.get('alert')}")
    return payload


def search(keyword):
    """getSearchRaw across all states, paginated. Returns {bill_id: record}."""
    found = {}
    page = 1
    while page <= MAX_PAGES:
        payload = api_call(
            {"op": "getSearchRaw", "state": "ALL", "query": keyword, "year": YEAR, "page": page}
        )
        result = payload.get("searchresult", {})
        summary = result.get("summary", {})
        for item in result.get("results", []):
            if int(item.get("relevance", 0)) < MIN_RELEVANCE:
                continue
            bill_id = str(item["bill_id"])
            record = {
                "bill_id": bill_id,
                "change_hash": item.get("change_hash", ""),
                "state": item.get("state", ""),
                "bill_number": item.get("bill_number", ""),
                "last_action": item.get("last_action", ""),
                "last_action_date": item.get("last_action_date", ""),
                "title": item.get("title", ""),
                "url": item.get("url", ""),
                "relevance": item.get("relevance", 0),
                "matched": [keyword],
            }
            if bill_id in found:
                found[bill_id]["matched"].append(keyword)
            else:
                found[bill_id] = record
        page_total = int(summary.get("page_total", 1) or 1)
        if page >= page_total:
            break
        page += 1
        time.sleep(1)
    return found


def main():
    if not os.environ.get("LEGISCAN_API_KEY"):
        sys.exit("LEGISCAN_API_KEY is not set")

    DATA.mkdir(parents=True, exist_ok=True)
    state_path = DATA / "state.json"
    previous = {}
    if state_path.exists():
        previous = json.loads(state_path.read_text())

    current = {}
    errors = []
    for keyword in KEYWORDS:
        try:
            for bill_id, record in search(keyword).items():
                if bill_id in current:
                    current[bill_id]["matched"] = sorted(
                        set(current[bill_id]["matched"]) | set(record["matched"])
                    )
                else:
                    current[bill_id] = record
        except Exception as exc:  # keep going; a failed keyword is reported, not fatal
            errors.append({"keyword": keyword, "error": str(exc)})
        time.sleep(1)

    for record in current.values():
        record["matched"] = sorted(set(record["matched"]))

    new_bills, changed_bills = [], []
    for bill_id, record in current.items():
        if bill_id not in previous:
            new_bills.append(record)
        elif previous[bill_id] != record["change_hash"]:
            changed_bills.append(record)

    disappeared = sorted(set(previous) - set(current))
    run_time = datetime.now(timezone.utc).isoformat(timespec="seconds")

    changes = {
        "generated_utc": run_time,
        "first_run": not state_path.exists(),
        "keywords": KEYWORDS,
        "min_relevance": MIN_RELEVANCE,
        "totals": {
            "matching": len(current),
            "new": len(new_bills),
            "changed": len(changed_bills),
            "no_longer_matching": len(disappeared),
        },
        "new": sorted(new_bills, key=lambda r: (r["state"], r["bill_number"])),
        "changed": sorted(changed_bills, key=lambda r: (r["state"], r["bill_number"])),
        "no_longer_matching": disappeared,
        "errors": errors,
        "attribution": "LegiScan API by LegiScan LLC, licensed under CC BY 4.0",
    }

    (DATA / "changes.json").write_text(json.dumps(changes, indent=2))
    (DATA / "latest.json").write_text(
        json.dumps(
            {
                "generated_utc": run_time,
                "count": len(current),
                "bills": sorted(current.values(), key=lambda r: (r["state"], r["bill_number"])),
                "attribution": "LegiScan API by LegiScan LLC, licensed under CC BY 4.0",
            },
            indent=2,
        )
    )
    state_path.write_text(
        json.dumps({bid: rec["change_hash"] for bid, rec in current.items()}, indent=2, sort_keys=True)
    )

    print(
        f"{run_time} matching={len(current)} new={len(new_bills)} "
        f"changed={len(changed_bills)} gone={len(disappeared)} errors={len(errors)}"
    )
    for err in errors:
        print(f"  keyword failed: {err['keyword']}: {err['error']}", file=sys.stderr)


if __name__ == "__main__":
    main()
