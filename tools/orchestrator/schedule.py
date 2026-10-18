#!/usr/bin/env python3
"""Dependency scheduling and the bookkeeping around each workflow run, so the orchestrator does it in one command.

Each work package runs in its own workflow (batch id = "<wave>-<wp>"), started as soon as everything it
depends on has merged; it merges as soon as it is ready. Nothing waits on a slower neighbour.

    schedule.py ready                 work packages that can start now (respects the pause and the current wave)
    schedule.py start <wp>...         make and start one batch per work package, commit, print each batch's args
    schedule.py run-id <batch>=<id>…  record workflow run ids, commit
    schedule.py finish <output-file>  record a finished workflow: reports, stats, carry-overs, worktree and branch
                                      cleanup, STATUS.md, progress data; commit; print a summary and what is ready

Commits only when no integrator holds the merge lock and no merge is in progress in the checkout; otherwise it
waits (up to 10 minutes) for the lock to go.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import state as st  # pyright: ignore[reportImplicitRelativeImport]

ROOT = st.ROOT
LOCK = Path.home() / "Library/Caches/filetrail-port/integrate.lock"
BRIEFS = st.STATE_DIR / "wp"
WORKTREES = ROOT / ".claude/worktrees"
BUSY = {"implementing", "merged", "blocked", "ready", "reviewing", "fixing"}


def git(*args: str, check: bool = True) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=check, capture_output=True, text=True
    ).stdout.strip()


def wait_for_checkout() -> None:
    for _ in range(60):
        merging = (ROOT / ".git/MERGE_HEAD").exists()
        if not LOCK.exists() and not merging:
            return
        time.sleep(10)
    raise SystemExit(
        "an integrator still holds the merge lock (or a merge is in progress); try again later"
    )


def commit(message: str, paths: list[str]) -> None:
    wait_for_checkout()
    git("add", "--", *paths)
    if (
        subprocess.run(
            ["git", "diff", "--cached", "--quiet"], cwd=ROOT, check=False
        ).returncode
        == 0
    ):
        return
    git("commit", "-q", "-m", message)


def running_wps(state: dict[str, Any]) -> set[str]:
    return {
        w
        for b in state["batches"].values()
        if b["status"] == "running"
        for w in b["wps"]
    }


def ready(state: dict[str, Any]) -> tuple[list[str], str | None]:
    if state.get("pause", {}).get("requested"):
        return [], f"paused: {state['pause'].get('reason')}"
    wave = int(state.get("wave", 0))
    busy = running_wps(state)
    out = []
    for wp_id, wp in state["wps"].items():
        if wp["status"] != "todo" or wp_id in busy or int(wp.get("wave", 99)) > wave:
            continue
        if not all(
            state["wps"][d]["status"] == "merged" for d in wp.get("depends", [])
        ):
            continue
        out.append(wp_id)
    missing = [w for w in out if not (BRIEFS / f"{w}.md").exists()]
    note = f"no brief yet: {', '.join(missing)}" if missing else None
    return [w for w in out if w not in missing], note


def batch_id_for(state: dict[str, Any], wp_id: str) -> str:
    base = f"W{state.get('wave')}-{wp_id}"
    n, bid = 1, base
    while bid in state["batches"]:
        n += 1
        bid = f"{base}-{n}"
    return bid


def cmd_start(wp_ids: list[str]) -> None:
    state = st.load()
    out = []
    for wp_id in wp_ids:
        bid = batch_id_for(state, wp_id)
        state["batches"][bid] = {
            "wps": [wp_id],
            "status": "running",
            "runId": None,
            "startedAt": st.now(),
        }
        if state["wps"][wp_id]["status"] == "todo":
            state["wps"][wp_id]["status"] = "implementing"
        out.append(st.batch_args(state, bid))
    st.save(state, "start", batches=[a["batchId"] for a in out])
    st.STATUS_MD.write_text(st.status_md(state))
    commit(f"port: start {', '.join(a['batchId'] for a in out)}", ["docs/port"])
    for a in out:
        print(json.dumps(a, ensure_ascii=False))


def cmd_run_id(pairs: list[str]) -> None:
    state = st.load()
    for pair in pairs:
        bid, run = pair.split("=", 1)
        state["batches"][bid]["runId"] = run
    st.save(state, "run-id", runs=pairs)
    commit("port: run ids " + " ".join(pairs), ["docs/port/state"])


def workflow_result(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    raw = json.loads(path.read_text())
    result = raw.get("result")
    if isinstance(result, str):
        result = json.loads(result)
    return raw, result


def stats(raw: dict[str, Any]) -> dict[str, Any]:
    agents = (
        (raw.get("workflowProgress") or {}).get("agents")
        if isinstance(raw.get("workflowProgress"), dict)
        else None
    )
    agents = agents or [
        x
        for x in (raw.get("workflowProgress") or [])
        if isinstance(x, dict) and x.get("type") == "workflow_agent"
    ]
    starts = [a["startedAt"] for a in agents if a.get("startedAt")]
    ends = [
        a["startedAt"] + a.get("durationMs", 0) for a in agents if a.get("startedAt")
    ]
    minutes = round((max(ends) - min(starts)) / 60000, 1) if starts else None
    return {
        "agents": raw.get("agentCount") or len(agents),
        "subagentTokens": raw.get("totalTokens"),
        "durationMin": minutes,
    }


def cleanup(run_id: str | None, merged: list[str]) -> list[str]:
    done = []
    if run_id:
        for wt in sorted(WORKTREES.glob(f"{run_id}-*")):
            git("worktree", "unlock", str(wt), check=False)
            if subprocess.run(
                ["git", "worktree", "remove", "--force", str(wt)],
                cwd=ROOT,
                capture_output=True,
                check=False,
            ).returncode:
                shutil.rmtree(wt, ignore_errors=True)
            done.append(wt.name)
        git("worktree", "prune")
        # Worktree isolation also leaves a "worktree-<name>" base branch per agent; main already contains them.
        for name in git(
            "branch", "--list", f"worktree-{run_id}-*", "--format=%(refname:short)"
        ).split():
            if (
                subprocess.run(
                    ["git", "merge-base", "--is-ancestor", name, "main"],
                    cwd=ROOT,
                    check=False,
                ).returncode
                == 0
            ):
                git("branch", "-D", name, check=False)
                done.append(name)
    for wp_id in merged:
        if git("branch", "--list", f"port/{wp_id}"):
            git("branch", "-D", f"port/{wp_id}", check=False)
            done.append(f"port/{wp_id}")
    return done


def apply_carry_over(
    state: dict[str, Any], source: str, items: list[dict[str, str]]
) -> list[str]:
    applied = []
    for item in items:
        wp_id, text = item.get("wp", "").strip(), item.get("text", "").strip()
        if not text:
            continue
        line = f"From {source}: {text}"
        if wp_id in state["wps"]:
            wp = state["wps"][wp_id]
            if line in wp.setdefault("carryOver", []):
                continue
            wp["carryOver"].append(line)
            brief = BRIEFS / f"{wp_id}.md"
            if brief.exists():
                body = brief.read_text()
                if "## Carried over" not in body:
                    body = body.rstrip("\n") + "\n\n## Carried over\n\n"
                brief.write_text(body.rstrip("\n") + f"\n- {line}\n")
            applied.append(wp_id)
        else:
            state["openIssues"].append(
                {
                    "at": st.now()[:10],
                    "seenIn": source,
                    "issue": text,
                    "owner": wp_id or "unassigned",
                    "closed": False,
                }
            )
            applied.append(f"openIssue({wp_id or '?'})")
    return applied


def cmd_finish(path: Path) -> None:
    raw, result = workflow_result(path)
    state = st.load()
    bid = result["batchId"]
    batch = state["batches"][bid]
    _ = st.apply_report(state, result)
    batch.update({k: v for k, v in stats(raw).items() if v is not None})
    integration = result.get("integration") or {}
    merged = integration.get("merged", [])
    carried: list[str] = []
    for rep in result.get("reports", []):
        if rep:
            carried += apply_carry_over(state, rep["id"], rep.get("carryOver") or [])
    carried += apply_carry_over(
        state, f"{bid} integrator", integration.get("carryOver") or []
    )
    removed = cleanup(batch.get("runId"), merged)
    st.save(state, "finish", batch=bid, merged=merged, carried=carried)
    st.STATUS_MD.write_text(st.status_md(state))
    subprocess.run(
        [sys.executable, str(ROOT / "tools/orchestrator/progress_data.py")],
        cwd=ROOT,
        check=False,
        capture_output=True,
    )
    commit(f"port: checkpoint {bid}", ["docs/port"])

    print(
        f"batch {bid}: merged {merged or 'nothing'}; {batch.get('agents')} agents, {batch.get('durationMin')} min"
    )
    for rep in result.get("reports", []):
        if not rep:
            continue
        findings = rep.get("findings") or []
        fixes = rep.get("fixes") or []
        flaky = (rep.get("gate") or {}).get("flaky") or []
        print(
            f"  {rep['id']}: {rep.get('status')}; findings {len(findings)} "
            f"({', '.join(f.get('severity', '?') for f in findings) or '-'}); fixes {len(fixes)}; "
            f"reviewers checked {rep.get('reviewChecked')}"
            + (f"; flaky {flaky}" if flaky else "")
        )
        for b in rep.get("blockers") or []:
            print(f"    blocker: {b}")
        for d in rep.get("deviations") or []:
            print(f"    deviation: {d[:200]}")
    for n in integration.get("notMerged", []):
        print(f"  not merged: {n}")
    print(f"  carry-overs to: {sorted(set(carried)) or '-'}")
    print(f"  cleaned up: {len(removed)} worktrees/branches")
    nxt, note = ready(st.load())
    print(f"ready to start: {nxt or '-'}" + (f" ({note})" if note else ""))


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    command, rest = argv[0], argv[1:]
    if command == "ready":
        ids, note = ready(st.load())
        print(" ".join(ids) if ids else "-")
        if note:
            print(note, file=sys.stderr)
    elif command == "start":
        cmd_start(rest)
    elif command == "run-id":
        cmd_run_id(rest)
    elif command == "finish":
        cmd_finish(Path(rest[0]))
    else:
        print(f"unknown command {command}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
