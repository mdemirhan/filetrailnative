# Orchestrator operating instructions

Any Claude Code session that loads this file runs the port. The plan is `docs/port/PLAN.md`; this file is how to carry it out. Never rely on conversation memory: the state files and git are the truth.

## Files

| File | Role |
|---|---|
| `docs/port/state/orchestrator.json` | Authoritative state. Read it first; write it after every change. |
| `docs/port/state/journal.jsonl` | Append-only log, one JSON object per line: `{"at", "event", ...}`. |
| `docs/port/state/wp/<id>.md` | The full brief of each work package, passed to its agents. |
| `docs/port/STATUS.md` | Human dashboard, rewritten from the state after each batch. |
| `docs/port/DEVIATIONS.md` | Intentional differences from the original, each marked proposed or approved. |
| `tools/orchestrator/reconcile.py` | Compares state with git, recovers leftover worktrees, and prints a summary. |
| `tools/orchestrator/state.py` | Small CLI to read and update the state and journal (use it instead of editing JSON by hand). |
| `tools/orchestrator/workflows/batch.js` | The workflow script that runs one batch of work packages. Run it by `scriptPath`. |

## The loop (`/port`)

1. **Reconcile.** Run `python3 tools/orchestrator/reconcile.py`. It must report `ok`, or say what it recovered. Read its summary instead of the raw state.
2. **Check the pause flag.** If `pause.requested` is set, report the status and stop.
3. **Read the meter.** Call `get_usage`. If the weekly all-models limit is at 90% or above, or the next batch's estimate would cross it, set the pause with the reason `weekly-limit` and the reset time, checkpoint, and stop.
4. **Pick the next batch.** Take WPs whose `depends` are all `merged` and whose status is not `merged` or `blocked`. Respect the current wave, and keep each batch to 10 agents or fewer (the session's workflow-size guideline). Count each WP as 2 agents for low risk, 5 for medium and 7 for high, plus 1 for the integrator (`state.py add-batch` prints the estimate).
5. **Checkpoint before launching.** Set the batch's `status: running` and record the meter reading in the state, then commit the state.
6. **Run the batch.** Launch `Workflow({scriptPath: "tools/orchestrator/workflows/batch.js", args})`. `args` comes from `python3 tools/orchestrator/state.py batch-args <batchId>`. Record the returned run id in the state right away.
7. **Record the results** when the workflow returns. Apply each WP report with `state.py apply-report`. Record the meter reading after the batch and the tokens per agent. Rewrite `STATUS.md` (`state.py status-md`). Commit everything as `port: checkpoint <batchId>`.
8. **At a phase end,** run the phase critic (inside the next batch, or as a one-agent workflow). Turn real gaps into new WPs.
9. **At a wave end,** run `tools/capture/run.sh --acceptance` (PLAN.md §3.4a). A Finder-improvement flow that passed before and fails now blocks the gate. Then stop and ask the user to approve the new `DEVIATIONS.md` entries and to do the human checkpoints of PLAN.md §8. (`main` already holds the work; nothing to merge.)
10. **Repeat** from step 2.

The orchestrator does not write feature code. It writes only state, briefs, status and the orchestrator tools.

## Pause and stop

- **Pause** (`/port pause` or the user saying so). Run `state.py pause "<reason>"`. A batch already running finishes and is recorded, and then the loop stops at step 2.
- **Stop.** The user may stop at any time. On the next `/port`, reconcile handles it: a batch left `running` without a result becomes `interrupted`. Its WPs keep whatever stages they committed. Re-running the batch skips finished stages, because every stage checks for its `Port-Stage` commit before working.
- **Same-session resume.** If the session that ran the batch is still open, relaunch with `resumeFromRunId` (the run id is in the state). Agents that already finished come back from cache.

## Branch and commit rules

- `main` is the integration branch, checked out in the main checkout (`/Users/tcmudemirhan/src/swiftproj/filetrail`), where the orchestrator runs. Don't edit files there while a batch runs.
- Each WP works on `port/<wp-id>`, made from `main` by its implementer.
- When an agent finishes, it detaches HEAD (`git checkout --detach`) so the branch is free for the next stage's agent.
- Stage commits end with a trailer line: `Port-Stage: implemented`, `Port-Stage: fixed-1`, `Port-Stage: fixed-2`.
- No `Co-Authored-By` trailers (global CLAUDE.md).
- Only the integrator merges into `main`, using `--no-ff`, one WP at a time, and runs the full CI after each merge.
