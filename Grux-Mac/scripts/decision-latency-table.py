#!/usr/bin/env python3
"""Per-gate decision latency and cost, from the local decision ledger.

Prints a markdown table for two windows, BEFORE and AFTER a cut-over time, so
the before and after columns are measured the same way from the same file.
Used for Phase R's P-R-10 table and the 3.0 release notes.

    scripts/decision-latency-table.py --before-end 2026-09-21T14:33:00Z \
        --after-start 2026-09-21T14:41:00Z [--ledger PATH]

The ledger is ~/Library/Application Support/Grux/decisions.jsonl, one JSON
line per decision (surface, provider, latencyMs, inputTokens, costUSD, at).
It never leaves the machine; this script only reads it.
"""
import argparse, json, os, statistics
from collections import defaultdict
from datetime import datetime

def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))

def pct(xs, p):
    xs = sorted(xs)
    if not xs: return None
    k = max(0, min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1)))))
    return xs[k]

def table(rows, title):
    groups = defaultdict(list)
    for r in rows:
        groups[(r["surface"], r["provider"])].append(r)
    out = [f"**{title}**", "",
           "| gate | provider | calls | p50 | p90 | input tokens (median) | cost per call |",
           "|---|---|---|---|---|---|---|"]
    for (surface, provider), rs in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        lat = [r["latencyMs"] for r in rs]
        tok = [r["inputTokens"] for r in rs]
        cost = statistics.mean(r.get("costUSD", 0) for r in rs)
        per = "nothing" if cost == 0 else ("under $0.0001" if cost < 0.0001 else f"${cost:.4f}")
        out.append(f"| {surface} | {'on device' if provider == 'local' else 'Jev'} | {len(rs)} | "
                   f"{pct(lat, 50)} ms | {pct(lat, 90)} ms | {int(statistics.median(tok)):,} | {per} |")
    return "\n".join(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ledger", default=os.path.expanduser("~/Library/Application Support/Grux/decisions.jsonl"))
    ap.add_argument("--before-end", required=True)
    ap.add_argument("--after-start", required=True)
    a = ap.parse_args()
    rows = [json.loads(l) for l in open(a.ledger) if l.strip()]
    be, ast = parse(a.before_end), parse(a.after_start)
    before = [r for r in rows if parse(r["at"]) < be]
    after = [r for r in rows if parse(r["at"]) >= ast]
    print(table(before, f"Before (every decision before {a.before_end})"))
    print()
    print(table(after, f"After (every decision since {a.after_start})"))

if __name__ == "__main__":
    main()
