#!/usr/bin/env python3
"""
Pulls skill-game and sweepstakes-gaming legislation from the LegiScan API and
records what changed since the previous run.

Data source: LegiScan API by LegiScan LLC, licensed under CC BY 4.0.

Query pattern, per LegiScan's documented work loop:
  getSearchRaw  cheap. Returns bill_id, change_hash and relevance only.
                Used to find matches and detect changes.
  getBill       spent only on bills that are new or whose change_hash moved.
                Supplies state, bill number, title, status, links and history.
Descriptive detail for unchanged bills is reused from data/details.json rather
than re-fetched, so steady-state query spend is a few dozen calls per run.

Outputs (all under data/):
  latest.json   every bill currently matching, with descriptive detail
  changes.json  only what is new or changed since the last run
  state.json    bill_id -> change_hash, used to detect changes next run
  details.json  bill_id -> cached descriptive detail
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

# Safety valve on getBill spend in a single run.
DETAIL_CAP = int(os.environ.get("DETAIL_CAP", "500"))

MAX_PAGES = 10
SEARCH_DELAY = 1.0
BILL_DELAY = 0.4


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
    """getSearchRaw across all states, paginated. Returns {bill_id: stub}."""
    found = {}
    page = 1
    while page <= MAX_PAGES:
        payload = api_call(
            {"op": "getSearchRaw", "state": "ALL", "query": keyword, "year": YEAR, "page": page}
        )
        result = payload.get("searchresult", {})
        summary = result.get("summary", {})
        for item in result.get("results", []):
            relevance = int(item.get("relevance", 0) or 0)
            if relevance < MIN_RELEVANCE:
                continue
            bill_id = str(item["bill_id"])
            if bill_id in found:
                found[bill_id]["matched"].append(keyword)
                found[bill_id]["relevance"] = max(found[bill_id]["relevance"], relevance)
            else:
                found[bill_id] = {
                    "bill_id": bill_id,
                    "change_hash": item.get("change_hash", ""),
                    "relevance": relevance,
                    "matched": [keyword],
                }
        page_total = int(summary.get("page_total", 1) or 1)
        if page >= page_total:
            break
        page += 1
        time.sleep(SEARCH_DELAY)
    return found


def fetch_detail(bill_id):
    """getBill for one bill. Returns the descriptive fields we report on."""
    bill = api_call({"op": "getBill", "id": bill_id}).get("bill", {})
    history = bill.get("history") or []
    last = history[-1] if history else {}
    session = bill.get("session") or {}
    return {
        "state": bill.get("state", ""),
        "bill_number": bill.get("bill_number", ""),
        "title": bill.get("title", ""),
        "description": bill.get("description", ""),
        "status": bill.get("status", ""),
        "status_date": bill.get("status_date", ""),
        "last_action": last.get("action", ""),
        "last_action_date": last.get("date", ""),
        "url": bill.get("url", ""),
        "state_link": bill.get("state_link", ""),
        "session": session.get("session_name", ""),
    }


def merge(stub, detail):
    record = dict(detail)
    record.update(
        {
            "bill_id": stub["bill_id"],
            "change_hash": stub["change_hash"],
            "relevance": stub["relevance"],
            "matched": sorted(set(stub["matched"])),
        }
    )
    return record


def sort_key(record):
    return (record.get("state", ""), record.get("bill_number", ""), record.get("bill_id", ""))


def main():
    if not os.environ.get("LEGISCAN_API_KEY"):
        sys.exit("LEGISCAN_API_KEY is not set")

    DATA.mkdir(parents=True, exist_ok=True)
    state_path = DATA / "state.json"
    details_path = DATA / "details.json"

    previous = json.loads(state_path.read_text()) if state_path.exists() else {}
    details = json.loads(details_path.read_text()) if details_path.exists() else {}

    current, errors = {}, []
    for keyword in KEYWORDS:
        try:
            for bill_id, stub in search(keyword).items():
                if bill_id in current:
                    current[bill_id]["matched"].extend(stub["matched"])
                    current[bill_id]["relevance"] = max(
                        current[bill_id]["relevance"], stub["relevance"]
                    )
                else:
                    current[bill_id] = stub
        except Exception as exc:  # a failed keyword is reported, not fatal
            errors.append({"stage": "search", "keyword": keyword, "error": str(exc)})
        time.sleep(SEARCH_DELAY)

    # Decide which bills need a getBill query.
    new_ids, changed_ids = [], []
    for bill_id, stub in current.items():
        if bill_id not in previous:
            new_ids.append(bill_id)
        elif previous[bill_id] != stub["change_hash"]:
            changed_ids.append(bill_id)

    # A bill with no cached detail needs one even if its hash did not move,
    # which is how a run recovers from an earlier failed lookup.
    missing_ids = [b for b in current if b not in details and b not in new_ids and b not in changed_ids]

    to_fetch = new_ids + changed_ids + missing_ids
    capped = len(to_fetch) > DETAIL_CAP
    for bill_id in to_fetch[:DETAIL_CAP]:
        try:
            details[bill_id] = fetch_detail(bill_id)
        except Exception as exc:
            errors.append({"stage": "getBill", "bill_id": bill_id, "error": str(exc)})
        time.sleep(BILL_DELAY)

    blank = {
        "state": "", "bill_number": "", "title": "", "description": "", "status": "",
        "status_date": "", "last_action": "", "last_action_date": "", "url": "",
        "state_link": "", "session": "",
    }
    records = {bid: merge(stub, details.get(bid, blank)) for bid, stub in current.items()}

    disappeared = sorted(set(previous) - set(current))
    for bill_id in disappeared:
        details.pop(bill_id, None)

    run_time = datetime.now(timezone.utc).isoformat(timespec="seconds")
    changes = {
        "generated_utc": run_time,
        "first_run": not state_path.exists(),
        "keywords": KEYWORDS,
        "min_relevance": MIN_RELEVANCE,
        "detail_cap_hit": capped,
        "totals": {
            "matching": len(records),
            "new": len(new_ids),
            "changed": len(changed_ids),
            "no_longer_matching": len(disappeared),
        },
        "new": sorted((records[b] for b in new_ids), key=sort_key),
        "changed": sorted((records[b] for b in changed_ids), key=sort_key),
        "no_longer_matching": disappeared,
        "errors": errors,
        "attribution": "LegiScan API by LegiScan LLC, licensed under CC BY 4.0",
    }

    (DATA / "changes.json").write_text(json.dumps(changes, indent=2))
    (DATA / "latest.json").write_text(
        json.dumps(
            {
                "generated_utc": run_time,
                "count": len(records),
                "bills": sorted(records.values(), key=sort_key),
                "attribution": "LegiScan API by LegiScan LLC, licensed under CC BY 4.0",
            },
            indent=2,
        )
    )
    state_path.write_text(
        json.dumps({b: s["change_hash"] for b, s in current.items()}, indent=2, sort_keys=True)
    )
    details_path.write_text(json.dumps(details, indent=2, sort_keys=True))

    print(
        f"{run_time} matching={len(records)} new={len(new_ids)} changed={len(changed_ids)} "
        f"gone={len(disappeared)} detail_calls={min(len(to_fetch), DETAIL_CAP)} "
        f"capped={capped} errors={len(errors)}"
    )
    for err in errors:
        print(f"  {err}", file=sys.stderr)


if __name__ == "__main__":
    main()
