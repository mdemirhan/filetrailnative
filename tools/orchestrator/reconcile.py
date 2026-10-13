#!/usr/bin/env python3
"""Brings the orchestrator state in line with git before the loop continues.

Run at the start of every /port. By default it only reports. With --recover (use it
only when no workflow of this session is running) it also:
  - marks batches still "running" as "interrupted";
  - commits uncommitted work left in a work package's worktree as "wip(<wp>): recovered",
    then removes that worktree (never discards changes).

Prints a JSON summary; "ok" is false when something needs the orchestrator's attention.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import state as st  # pyright: ignore[reportImplicitRelativeImport]

ROOT = st.ROOT
STAGE_TO_STATUS = {
    "implemented": "implemented",
    "fixed-1": "fixing",
    "fixed-2": "fixing",
}


def git(*args: str, cwd: Path = ROOT, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, check=False
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def port_branches() -> dict[str, str]:
    out = git(
        "for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads/port/"
    )
    branches = {}
    for line in out.splitlines():
        name, sha = line.split()
        if name != "port/integration":
            branches[name.removeprefix("port/")] = sha
    return branches


def last_stage(wp_id: str) -> str | None:
    out = git(
        "log",
        f"port/{wp_id}",
        "--not",
        "port/integration",
        "--format=%(trailers:key=Port-Stage,valueonly,separator=%x2C)",
        check=False,
    )
    for line in out.splitlines():
        if line.strip():
            return line.strip().split(",")[0].strip()
    return None


def worktrees() -> list[dict[str, str]]:
    out = git("worktree", "list", "--porcelain")
    trees, current = [], {}
    for line in out.splitlines() + [""]:
        if not line:
            if current:
                trees.append(current)
            current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value
    return trees


def owner_of(tree: dict[str, str], branches: dict[str, str]) -> str | None:
    """The work package a worktree belongs to: its port/ branch, or a detached HEAD on one
    (built on its tip, or at an earlier commit of it)."""
    branch = tree.get("branch", "").removeprefix("refs/heads/")
    if branch.startswith("port/") and branch != "port/integration":
        return branch.removeprefix("port/")
    head = tree.get("HEAD")
    if "detached" not in tree or not head:
        return None

    def is_ancestor(a: str, b: str) -> bool:
        return (
            subprocess.run(
                ["git", "merge-base", "--is-ancestor", a, b], cwd=ROOT, check=False
            ).returncode
            == 0
        )

    integration = git("rev-parse", "port/integration")
    for wp_id, sha in branches.items():
        if is_ancestor(sha, head) or (
            is_ancestor(head, sha) and not is_ancestor(head, integration)
        ):
            return wp_id
    # Already merged: a detached worktree whose commit is in port/integration holds nothing new.
    if is_ancestor(head, integration) and "/.claude/worktrees/wf_" in tree.get(
        "worktree", ""
    ):
        return "merged"
    return None


def main(argv: list[str]) -> int:
    recover = "--recover" in argv
    state = st.load()
    summary: dict[str, Any] = {
        "ok": True,
        "notes": [],
        "recovered": [],
        "interrupted": [],
    }
    branches = port_branches()

    for batch_id, batch in state["batches"].items():
        if batch["status"] == "running":
            if recover:
                batch["status"] = "interrupted"
                summary["interrupted"].append(batch_id)
            else:
                summary["notes"].append(
                    f"batch {batch_id} is marked running; if no workflow is running, rerun with --recover"
                )
                summary["ok"] = False

    for wp_id, wp in state["wps"].items():
        if wp_id not in branches or wp["status"] in ("merged", "ready", "blocked"):
            continue
        stage = last_stage(wp_id)
        wp["headSha"] = branches[wp_id]
        if (
            stage
            and STAGE_TO_STATUS.get(stage)
            and wp["status"] in ("todo", "implementing")
        ):
            wp["status"] = STAGE_TO_STATUS[stage]
            summary["notes"].append(
                f"{wp_id}: git shows stage {stage}; status set to {wp['status']}"
            )

    here = str(ROOT)
    for tree in worktrees():
        path = tree.get("worktree", "")
        if path == here:
            continue
        wp_id = owner_of(tree, branches)
        if not wp_id:
            continue
        dirty = git("status", "--porcelain", cwd=Path(path), check=False)
        if not recover:
            summary["notes"].append(
                f"worktree {path} ({wp_id}){' has uncommitted changes' if dirty else ''}"
            )
            continue
        if dirty and wp_id == "merged":
            summary["notes"].append(
                f"worktree {path} is on merged work but has uncommitted changes; left alone"
            )
            summary["ok"] = False
            continue
        if dirty:
            git("add", "-A", cwd=Path(path))
            git("commit", "-q", "-m", f"wip({wp_id}): recovered", cwd=Path(path))
            if "detached" in tree:
                git(
                    "branch", "-f", f"port/{wp_id}", "HEAD", cwd=Path(path), check=False
                )
        git("worktree", "remove", "--force", path, check=False)
        summary["recovered"].append(
            {"wp": wp_id, "path": path, "hadChanges": bool(dirty)}
        )

    reference = Path(state["referenceCache"]).expanduser() / "electron"
    if (reference / ".git").exists():
        pinned = git("rev-parse", "--short", "HEAD", cwd=reference, check=False)
        if not state["referenceCommit"].startswith(pinned) and not pinned.startswith(
            state["referenceCommit"]
        ):
            summary["notes"].append(
                f"reference build is at {pinned}, pinned commit is {state['referenceCommit']}"
            )
            summary["ok"] = False
    else:
        summary["notes"].append("reference build not set up yet")

    if recover or summary["notes"]:
        st.save(
            state,
            "reconcile",
            recover=recover,
            notes=summary["notes"],
            recovered=summary["recovered"],
        )

    counts: dict[str, int] = {}
    for wp in state["wps"].values():
        counts[wp["status"]] = counts.get(wp["status"], 0) + 1
    summary.update(
        wave=state["wave"],
        phase=state["phase"],
        pause=state["pause"],
        nextAction=state.get("nextAction"),
        wpCounts=counts,
        lastMeter=state["meter"][-1] if state["meter"] else None,
    )
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
