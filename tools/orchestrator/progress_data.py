#!/usr/bin/env python3
"""Writes the progress page's data files to build/progress/ from the orchestrator state and the parity matrix.

Run after every checkpoint; the orchestrator uploads the files to the progress dashboard.
Effort weights are PLAN.md §10's agent runs per work package (low 1.5, medium 3.5, high 5); the P7 loop has no
work packages yet, so its effort is PLAN.md's estimate of its agent runs.
"""

from __future__ import annotations

import csv
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
STATE = ROOT / "docs/port/state/orchestrator.json"
TESTS = ROOT / "docs/port/parity/tests.tsv"
FEATURES = ROOT / "docs/port/parity/features.md"
OUT = ROOT / "build/progress"

EFFORT = {"low": 1.5, "medium": 3.5, "high": 5.0}
P7_EFFORT = 32.0  # PLAN.md §10: about 25-40 agent runs

PHASES: list[tuple[str, str, str, str]] = [
    ("P0", "Foundations and harness", "Test, comparison, capture and benchmark tools; package layout", "Low: tooling"),
    ("P1", "Pure logic", "Names, Keep Both, formatting, preferences, shortcuts, batch-rename planning", "Low: pure functions, checked against the original's outputs"),
    ("P2", "File system services", "Listing, watching, folder sizes, volumes, icons, search, Open With, Trash, app state", "Medium: system APIs, real disks"),
    ("P3", "Write engine", "Copy, move, replace, trash, delete, rename, undo, crash recovery", "High: safety-critical; a strict chain of 8"),
    ("P4", "App shell", "Menus, native windows and tabs, theme, About, Help", "Medium"),
    ("P5", "Explorer UI", "Layout, toolbar, sidebar, List/Icons views, selection, search, drag and drop", "Medium: must match the original to the point"),
    ("P6", "Dialogs and Settings", "Go To, paste conflict dialogs, Batch Rename sheet, Settings", "Medium, one high-risk"),
    ("P7", "Parity loop", "Full sweeps; every gap found becomes a fix, until nothing new turns up", "Open-ended"),
    ("P8", "Release", "Signing, notarization, DMG, bundle id cutover", "Low; needs your signing certificate"),
]


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def write(name: str, rows: Any) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1))


def main() -> None:
    state = json.loads(STATE.read_text())
    wps: dict[str, dict[str, Any]] = state["wps"]
    batches: dict[str, dict[str, Any]] = state["batches"]
    batch_of = {wp: bid for bid, b in batches.items() for wp in b["wps"]}

    phase_rows = []
    for code, name, what, complexity in PHASES:
        members = [w for k, w in wps.items() if k.startswith(code)]
        total = sum(EFFORT[w["risk"]] for w in members) if members else (P7_EFFORT if code == "P7" else 0.0)
        done = sum(EFFORT[w["risk"]] for w in members if w["status"] == "merged")
        running = sum(1 for w in members if w["status"] in ("implementing", "ready"))
        merged = sum(1 for w in members if w["status"] == "merged")
        status = "done" if members and merged == len(members) else "running" if running else "started" if merged else "not started"
        phase_rows.append(
            {
                "phase": code,
                "name": name,
                "what": what,
                "complexity": complexity,
                "wps_total": len(members),
                "wps_merged": merged,
                "effort_total": total,
                "effort_done": done,
                "status": status,
            }
        )
    write("phases", phase_rows)

    wp_rows = [
        {
            "id": k,
            "title": w["title"],
            "phase": k[:2],
            "wave": w.get("wave"),
            "risk": w["risk"],
            "model": w.get("model", ""),
            "status": w["status"],
            "batch": batch_of.get(k, ""),
        }
        for k, w in wps.items()
    ]
    write("work_packages", wp_rows)

    batch_rows = []
    for bid, b in batches.items():
        tokens = b.get("subagentTokens")
        batch_rows.append(
            {
                "batch": bid,
                "wps": ", ".join(b["wps"]),
                "status": b["status"],
                "agents": b.get("agents") or b.get("estimatedAgents"),
                "tokens_m": round(tokens / 1e6, 2) if tokens else None,
                "minutes": b.get("durationMin"),
                "started": b.get("startedAt"),
                "ended": b.get("endedAt"),
            }
        )
    write("batches", batch_rows)

    tests = Counter(r["status"] for r in csv.DictReader(TESTS.open(), delimiter="\t"))
    features = Counter(re.findall(r"^\|[^|\n]*\|.*\| (todo|done|partial|passing|n/a|N/A) \|", FEATURES.read_text(), re.M))
    parity = [{"matrix": "Original's tests", "status": s, "count": n} for s, n in sorted(tests.items())]
    parity += [{"matrix": "Original's features", "status": s, "count": n} for s, n in sorted(features.items())]
    write("parity", parity)

    write(
        "usage",
        [{"at": m["at"], "weekly_pct": m["weeklyPct"], "five_hour_pct": m["fiveHourPct"], "note": m.get("note", "")} for m in state["meter"]],
    )

    effort_total = sum(r["effort_total"] for r in phase_rows)
    effort_done = sum(r["effort_done"] for r in phase_rows)
    tests_done = tests.get("passing", 0) + tests.get("ported", 0) + tests.get("N/A", 0)
    feat_total = sum(features.values())
    running = [bid for bid, b in batches.items() if b["status"] == "running"]
    write(
        "summary",
        [
            {
                "effort_done_pct": round(effort_done / effort_total, 4),
                "wps_merged": sum(1 for w in wps.values() if w["status"] == "merged"),
                "wps_total": len(wps),
                "tests_done_pct": round(tests_done / sum(tests.values()), 4),
                "features_done_pct": round(features.get("done", 0) / feat_total, 4) if feat_total else 0,
                "agent_tokens_m": round(sum(b.get("subagentTokens") or 0 for b in batches.values()) / 1e6, 1),
                "weekly_pct": state["meter"][-1]["weeklyPct"] if state["meter"] else None,
                "wave": state["wave"],
                "running": ", ".join(f"{bid} ({', '.join(batches[bid]['wps'])})" for bid in running) or "nothing",
                "next_action": state.get("nextAction", ""),
                "paused": bool(state["pause"]["requested"]),
                "updated_at": now(),
            }
        ],
    )
    print(f"wrote {OUT.relative_to(ROOT)}: effort {effort_done:g}/{effort_total:g}, running {running}")


if __name__ == "__main__":
    main()
