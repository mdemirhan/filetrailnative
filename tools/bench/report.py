#!/usr/bin/env python3
"""Collects the raw output of tools/bench/run.sh into build/bench/latest.json and compares it with
tools/bench/budgets.json and baseline.json. Args: quick report_only update_baseline (each 0 or 1)."""

import glob
import json
import os
import re
import statistics
import sys

quick, report_only, update_baseline = (a == "1" for a in sys.argv[1:4])
raw, root = "build/bench/raw", "tools/bench"


def bench_lines(path):
    try:
        text = open(path).read()
    except OSError:
        return []
    return [json.loads(line[6:]) for line in text.splitlines() if line.startswith("BENCH ")]


metrics = {}
launches = [
    r["launch_ms"]
    for f in sorted(glob.glob(f"{raw}/launch-*.txt"))
    for r in bench_lines(f)
    if "launch_ms" in r
]
if launches:
    metrics["launch_ms"] = statistics.median(launches)

backs = []
for f in sorted(glob.glob(f"{raw}/open-*.txt")):
    for r in bench_lines(f):
        for name, v in r.get("folders", {}).items():
            n = name.split("-")[1]
            metrics[f"open_{n}_ms"] = v["open_ms"]
            metrics[f"stall_{n}_ms"] = v["stall_ms"]
            backs.append(v["back_ms"])
if backs:
    metrics["back_ms"] = statistics.median(backs)

# Listing (tools/bench/listing.sh, no app): DirectoryService read and sort of the 3,000 and 100,000 folders.
try:
    listing_text = open("build/bench/listing.json").read()
except OSError:
    listing_text = ""
for line in listing_text.splitlines():
    try:
        r = json.loads(line)
        if "metric" in r:
            metrics[r["metric"]] = r["medianMs"]
        else:
            metrics[f"list_{r['folder'].split('-')[1]}_ms"] = r["medianMs"]
    except (ValueError, KeyError, IndexError):
        pass

for r in bench_lines(f"{raw}/scroll.txt"):
    if "error" in r:
        print(f"scroll run failed: {r['error']}")
    if "frame_max_ms" in r:
        metrics["scroll_max_ms"] = r["frame_max_ms"]
        metrics["scroll_p99_ms"] = r["frame_p99_ms"]

try:
    m = re.search(r"Footprint: ([\d.]+) (\w+)", open(f"{raw}/footprint.txt").read())
    scale = {"B": 1 / 1048576, "KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)]
    metrics["idle_mb"] = float(m.group(1)) * scale
except (OSError, AttributeError, KeyError):
    pass
try:
    metrics["bundle_mb"] = int(open(f"{raw}/bundle-kb.txt").read()) / 1024
except (OSError, ValueError):
    pass
metrics = {k: round(v, 2) for k, v in metrics.items()}

budgets = json.load(open(f"{root}/budgets.json"))
try:
    baseline = json.load(open(f"{root}/baseline.json")).get("metrics", {})
except (OSError, ValueError):
    baseline = {}
floor = budgets.get("regression_floor", 1.0)
limit = budgets.get("regression_percent", 10) / 100

os.makedirs("build/bench", exist_ok=True)
with open("build/bench/latest.json", "w") as f:
    json.dump({"quick": quick, "metrics": metrics}, f, indent=2, sort_keys=True)

rows, failed = [], False
for key, spec in budgets["metrics"].items():
    value, budget, base = metrics.get(key), spec.get("budget"), baseline.get(key)
    if value is None:
        verdict = "skipped"
    elif budget is not None and value > budget:
        verdict = "OVER BUDGET"
    elif base is not None and value > base * (1 + limit) and value - base > floor:
        verdict = "REGRESSION"
    elif base is None:
        verdict = "ok (no baseline)"
    else:
        verdict = "ok"
    if verdict in ("OVER BUDGET", "REGRESSION"):
        failed = True
    show = lambda x: "-" if x is None else f"{x:g}"
    rows.append((f"{key} ({spec['unit']})", show(value), show(budget), show(base), verdict))

header = ("metric", "value", "budget", "baseline", "verdict")
widths = [max(len(r[i]) for r in rows + [header]) for i in range(5)]
for r in [header] + rows:
    print("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)))

missing = [k for k in ("launch_ms", "idle_mb", "bundle_mb", "scroll_max_ms") if k not in metrics]
if missing:
    print("no result for: " + ", ".join(missing) + " (see build/bench/raw)")
    failed = True

if update_baseline:
    merged = dict(baseline)
    merged.update(metrics)
    with open(f"{root}/baseline.json", "w") as f:
        json.dump(
            {"note": "Last accepted run; refresh with tools/bench/run.sh --update-baseline.", "metrics": merged},
            f,
            indent=2,
            sort_keys=True,
        )
        f.write("\n")
    print(f"baseline updated: {root}/baseline.json")
elif failed and not report_only:
    print("FAIL")
    sys.exit(1)
