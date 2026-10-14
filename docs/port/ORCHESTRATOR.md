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
| `tools/orchestrator/workflows/batch.js` | The workflow script that runs one batch (normally one work package). Run it by `scriptPath`. |
| `tools/orchestrator/schedule.py` | Dependency scheduling and the bookkeeping around each run: `ready`, `start`, `run-id`, `finish`. |

## The loop (`/port`)

1. **Reconcile.** Run `python3 tools/orchestrator/reconcile.py`. It must report `ok`, or say what it recovered. Read its summary instead of the raw state.
2. **Check the pause flag.** If `pause.requested` is set, report the status and stop.
3. **Read the meter.** Call `get_usage`. If the weekly all-models limit is at 90% or above, or the next batch's estimate would cross it, set the pause with the reason `weekly-limit` and the reset time, checkpoint, and stop.
4. **Start what is ready.** `python3 tools/orchestrator/schedule.py ready` lists the work packages whose dependencies have all merged (current wave, brief written, not paused). Start them all at once: `schedule.py start <wp>…` makes one batch per work package (id `W<wave>-<wp>`), marks it running, commits, and prints each batch's args. Launch one `Workflow({scriptPath: "tools/orchestrator/workflows/batch.js", args})` per line, all in one message, then record the run ids with `schedule.py run-id <batch>=<runId>…`. There are no multi-package batches and no barriers: each package merges as soon as it is ready, and its dependents start as soon as its finish is recorded. When `ready` reports packages with no brief yet, write those briefs right away (one agent per brief, all in parallel, then a review of each) so they can start.
5. **What a run does** (batch.js): build; the windowless gate and the reviewers side by side (Opus for high-risk parity; every reviewer returns the checklist it went through); at most 2 fix rounds; then the window check, once: GUI tests, the changed scenarios plus the smoke set, the acceptance flows (the bench runs only at wave ends), followed by the visual review of its captures; window failures and visual findings go to the fixer (at most 2 rounds); then the integrator merges under the merge lock. A test that fails once and passes alone is reported as flaky, not as a failure.
6. **Never message a running workflow agent** (it forks a second copy in the same worktree), and never commit in this checkout while `~/Library/Caches/filetrail-port/integrate.lock` exists or a merge is in progress; schedule.py waits for both.
7. **When a workflow returns,** run `python3 tools/orchestrator/schedule.py finish <its output file>`. It applies the report, records agents, tokens and minutes, appends every carry-over the agents returned to the named package's brief (or opens an issue when the package doesn't exist), removes the run's worktrees and the merged branches, rewrites STATUS.md and the progress data, commits `port: checkpoint <batch>`, and prints a summary and what is now ready. Read the summary (blockers, deviations, flaky tests), act on anything that needs judgment, record the meter reading (`state.py meter`), then go to step 4.
   Refresh the progress page (`docs/port/state/progress-page.json` has its url): upload each file in `build/progress/` (summary, phases, work_packages, batches, parity, usage) with the Artifact tool (`asset: true`, one JSON file per call, all in one message), then in one `ArtifactData` batch `update` each `datasets/<id>` with the new `source.url` and `updated: {at, by: "Port orchestrator"}`, pinned to the versions the last update returned.
8. **At a phase end,** run the phase critic (inside the next batch, or as a one-agent workflow). Turn real gaps into new WPs.
9. **At a wave end,** run the scripts-only parity sweep first (PLAN.md §6.5 step 1: tests, differential, every scenario light and dark at Comfortable and Compact (`tools/capture/run.sh --tier wave`, the full set), e2e, bench) and turn its failures into WPs; give every scenario a vision review, not only those over the pixel threshold. Then run `tools/capture/run.sh --acceptance` (PLAN.md §3.4a). A Finder-improvement flow that passed before and fails now blocks the gate. Then stop and ask the user to approve the new `DEVIATIONS.md` entries and to do the human checkpoints of PLAN.md §8. (`main` already holds the work; nothing to merge.)
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
