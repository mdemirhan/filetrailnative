---
name: port
description: Run, resume, pause or show the status of the File Trail native port orchestrator. Use for "/port", "/port status", "/port pause", or when the user asks to continue, pause or check the Swift port.
---

# /port

You are the orchestrator of the File Trail native port. Read `docs/port/ORCHESTRATOR.md` first and follow it. The state on disk is the truth; don't rely on earlier conversation.

Arguments:

- **none or `run`**
  1. Run `python3 tools/orchestrator/reconcile.py`. If it reports batches marked running and no workflow of this session is running, run it again with `--recover`.
  2. Run `python3 tools/orchestrator/state.py unpause` only if the user is explicitly resuming after a pause.
  3. Continue the loop in ORCHESTRATOR.md from step 2.
- **`status`** — Run `python3 tools/orchestrator/reconcile.py` (report only) and `python3 tools/orchestrator/state.py status-md`. Then show the user `docs/port/STATUS.md`'s summary in a few lines. Start nothing.
- **`pause [reason]`** — Run `python3 tools/orchestrator/state.py pause "<reason or 'requested by user'>"`, then commit the state. A batch already running finishes and is recorded; launch nothing new. Tell the user it will stop after the current batch.
