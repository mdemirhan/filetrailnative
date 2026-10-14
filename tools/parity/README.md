# tools/parity

The reference app's own TypeScript (in the clone `tools/reference/setup.sh` builds) records expected answers as goldens in `Tests/Golden/<suite>.json`; Swift tests check the port against them without Bun.

- `gen.sh [suite...]` regenerates goldens; `gen.sh --check` fails with a short diff if any would change (run it after re-pinning the reference).
- `lib/reference.ts` imports reference modules by path (`importReference("packages/contracts/src/paths.ts")`), so their own imports resolve in the clone; `lib/prng.ts` is the seeded PRNG.
- Golden format: `{ suite, referenceCommit, seed, generator, cases: [{ name, input, output }] }`.

## Adding a suite

1. Write `golden/<suite>.ts` exporting `seed` (a number) and `generate(rng)`, returning `[{ name, input, output }]` with unique names: hand-picked edge cases first, then random ones from `rng`, each `output` computed by the reference function.
2. Run `tools/parity/gen.sh <suite>` and commit `Tests/Golden/<suite>.json`.
3. In a test: `let cases: [GoldenCase<In, Out>] = try Golden.load(suite: "<suite>")`, then `Golden.expectMatches(cases) { port($0) }`. It reports the first 10 mismatches, one line each, comparing outputs as JSON (NFC and NFD differ).

## The write-engine differential (PLAN.md §5.3)

`exec/` runs scenarios through the reference's own write engine and records everything that matters; `FTTestSupport.ExecHarness` runs the same scenarios through the Swift engine and compares.

| File | What it does |
|---|---|
| `exec/places.ts` | The scenario format, the work folder (`tree/` = `$ROOT`, `trash/` = `$TRASH`, `journal/replace-journal.json`), disk images, building the tree, snapshots |
| `exec/run.ts` | Runs an execution scenario: builds the tree, starts `engine.ts` in a child Bun process, recovers after a crash, records the outcome |
| `exec/engine.ts` | The child: the review and the paste through the app's `WriteService` (as `bootstrap.ts` makes it) with the native file system (`testNativePaste.ts`), the app's journal file (`writeJournal.ts`) and the app's Trash wrapper (`createTrashItem`) around a folder Trash; answers and stops as the window does; writes one JSON record per line as things happen |
| `exec/analysis.ts` | Runs an analysis scenario in-process: the report, the choices, the resolution |
| `exec/normalize.ts` | Normalization, mirrored by `FTTestSupport.ExecNormalize` |
| `exec/scenarios.ts` | Builders the `exec-*` and `analysis-*` suites use |
| `exec/selftest.sh` | Checks `snapshot.ts` against `TreeSnapshot`, and `normalize.ts` against `ExecNormalize` on raw outcomes of recorded cases |

Run one by hand: `bun tools/parity/exec/run.ts [--raw] <scenario.json>`, `bun tools/parity/exec/run.ts [--raw] --golden exec-crash 1`, or `bun tools/parity/exec/analysis.ts <scenario.json>`.

### Scenario

```json
{ "name": "a file appears where a file is pasted, answered overwrite",
  "tree": [{ "path": "source/a.txt", "kind": "file", "content": "hi\n", "mode": "0644", "flags": ["uchg"] },
           { "path": "destination", "kind": "dir" }, { "path": "link", "kind": "symlink", "target": "a.txt" }],
  "paste": { "mode": "copy", "sources": ["source/a.txt"], "destination": "destination" },
  "policy": { "file": "skip", "directory": "skip", "mismatch": "skip" },
  "overrides": [{ "nodeId": "item-1/b.txt", "action": "keep_both" }],
  "answers": ["overwrite"],
  "applyToRemaining": [true],
  "stopAt": { "afterEvent": 3 },
  "crashAt": { "journalWrite": 2 },
  "changes": [{ "ops": [{ "op": "write", "path": "destination/a.txt", "content": "x\n" }] },
              { "afterEvent": 2, "ops": [{ "op": "remove", "path": "source/b.txt" }] }],
  "trash": true,
  "volumes": { "destination": "fat32" },
  "volumesWithoutTrash": ["destination"] }
```

- **tree**: made in order; then modes and flags, deepest first (equally deep: last first), so a read-only or locked folder is filled before it is closed.
- **overrides**: per-item review choices, by analysis node id.
- **answers**: replies to runtime questions in order (`resolveRuntimeConflict`, given as the question's event goes out); `skip` once they run out. Each must be one the engine allows, as the write service would refuse it (the generator fails otherwise).
- **applyToRemaining**: by position, which answers are given "for the rest of this operation". The write service then answers later conflicts of the same kind itself, without a question, when the answer suits them (`autoResolve`); others are asked.
- **stopAt**: right after the n-th progress event (the first is `queued`), `cancelOperation`, as the Stop button does; a question still open is dropped unanswered.
- **crashAt**: the child kills itself with `SIGKILL` right after its n-th journal write (each `add`, and each `remove` of an entry it holds, rewrites the file). `run.ts` then runs the app's startup recovery (`openWriteJournal`, `recoverWrites` with `answerWithinMs: 3000`, as `bootstrap.ts` does) on the same folders.
- **changes**: made on disk after the review, before Paste (no `afterEvent`), or right after the n-th progress event, before the engine goes on. Ops: `write`, `mkdir`, `remove`, `chmod` (`mode`, octal).
- **trash**: `false` gives the engine no Trash at all, so a Replace asks before deleting for good. Otherwise the Trash is the app's `createTrashItem` (which tells a locked item, and a disk that may have no Trash, from other failures) around a stand-in for the Trash like `testNativePaste.ts`'s: items are moved into their disk's Trash folder as `<n>-<name>`.
- **volumesWithoutTrash**: folders of `volumes` whose disk has no Trash: the stand-in fails there with `ENOTSUP`, as the Trash does on such a disk, so `createTrashItem` says it may have none and a Replace asks (`trash_unavailable`) before deleting for good.
- **volumes**: top-level folders made on a copy-on-write clone of a blank disk image (`apfs`, `apfs-cs`, `hfs`, `fat32`, `exfat`, from `tools/fixtures/disk-images.sh`), attached once per process with `hdiutil` and detached at exit. Their tree and Trash map to `$ROOT` and `$TRASH` too.

### Execution outcome

`{ before, after, trash, events, result, undoLog, journal, recovery }`:

- `before`, `after`, `trash`: tree snapshots (`snapshot.ts`), all disks merged. Items the owner can't read are opened for the snapshot and keep their own mode in it.
- `events`, in order, each with a `kind`:
  - `event`: a progress event, without its `result`, as the write service sends them: `queued` first, then the engine's, and the service's own `failed` (with a result for every item) or `cancelled` when the paste throws;
  - `answer`: `{ conflictId, allowed, answer, applyToRemaining }`, after the question's `awaiting_resolution` event (and any change due then). A conflict a standing answer covers has neither;
  - `journal`: `{ write, entries }`, the journal file after each write;
  - `change`, `stop`, `crash` (`{ afterJournalWrite }`), `issues` (the review refused the paste), `error` (the review itself failed).
- `result`: the final result without `undoLog`, or null; `undoLog` beside it.
- `journal`: the file when the engine finished or died (`[]` if never written).
- `recovery`, after a crash: `{ notices, finished, log: [{ level, message, details }], after, trash, journal }`.

### Analysis outcome

`{ before, report, allConflictsChoices, choices, resolved }`:

- `report`: `buildCopyPasteAnalysisReport` with the write service's thresholds (100 items, 1 GiB).
- `allConflictsChoices`: the "For all conflicts" buttons offered.
- `choices`: for each conflict node, by id, the choices offered and what each button makes of it (`effectiveChoice`, with the scenario's overrides).
- `resolved`: `resolveAnalysisWithPolicy` with the scenario's policy and overrides, as `{ id, action, destinationPath, children }` (or `{ error }`); null when the report has issues.

### Normalization (`normalize.ts`, `ExecNormalize`)

One walk, arrays in order and object keys sorted by UTF-16 code unit, so ordinals number the same on both sides:

- `startedAt` and `finishedAt` are dropped; a number under `mtimeMs` becomes `"set"`.
- `dev` and `ino` numbers become `dev-<n>` and `ino-<n>`, numbered by first appearance; a 16-hex-digit `id` (a journal id) becomes `journal-<n>`.
- A `conflictId`'s trailing question counter becomes `-q<n>`. `analysisId` and `operationId` become `analysis` and `operation`.
- In every string, each place is replaced by its token wherever it occurs (`$ROOT`, `$TRASH`, `$JOURNAL`; longest first, also under its `/var` spelling), then a hidden staging name's 8 random hex digits become `~<n>`.
- Snapshots (`before`, `after`, `trash`, and the same under `recovery`) are sorted by path again.

Normalizing twice changes nothing, so a recording replayed compares equal.

### Suites

| Suite | Cases |
|---|---|
| `exec-copy` | Plain copies, merge, Keep Both, Replace (file, folder, package, link), Skip, type mismatches, locks, no Trash, a blocked Replace, an unreadable folder, other disks, other disks without a Trash, a paste that fails as a whole |
| `exec-cut` | Same-disk renames, per-file moves into a merged folder, Replace, Skip, a locked file, a move into its own folder, moves to and from other disks |
| `exec-runtime` | Changes after the review or mid-paste, each allowed answer, answers for the rest of the operation (reused, asked again, another kind) |
| `exec-volumes` | Copy, Add Missing merge, Keep Both, Skip, a same-disk move, and moves onto and off each disk image: apfs, apfs-cs, hfs, fat32, exfat |
| `exec-stop` | Stops at chosen events: while queued, as it starts, inside a folder copy, between items, while building a replacement, during a move, with a question open |
| `exec-crash` | A crash after each journal write of a folder Replace (copy, and same-disk move), a file Replace, a folder copied whole, and a folder moved to another disk; then recovery |
| `analysis-cases` | Hand-picked: file-operations.md §2 and §7 A–C |
| `analysis-random` | 90 seeded random trees (seed 20261013) |
| `analysis-volumes` | Each disk image as source or destination; case sensitivity, AppleDouble, FAT's empty files |

### Swift side (`FTTestSupport`)

- `ExecScenario`: the scenario; `build(in:)` makes the tree as `places.ts` does, `applyChanges(afterEvent:in:)` makes its changes.
- `ExecPlaces.make(for:)`: the same folders and disk images (`ExecDiskImages`); `snapshotTree()`, `snapshotTrash()`, `readJournal()`, `trashFor(_:)`, `hasTrash(_:)`, `tokens`.
- `ExecEngine`: `run(scenario, answers:, stopAt:, crashAt:, in: places) async throws -> ExecOutcome`, which the Swift write engine implements; `ExecAnalysisEngine` for the analysis.
- `ExecHarness`: `cases(suite:)`, `check(_:with:)`, `checkAnalysis(_:with:)`, `mismatchReport(suite:engine:)` (builds the tree in fresh folders, runs the engine, normalizes, compares) and `builtTreeDifferences(_:)`.
- `ExecDiff.differences(expected:actual:)`: the first differences, one line each (`events[3].completedItemCount: expected 2, got 3`). Strings compare scalar for scalar.
- `SwiftExecEngine` (`FTOperationsTests/Exec`) runs `exec-copy`, `exec-cut`, `exec-runtime` and `exec-volumes`. `ReferenceReplayEngine` returns the recordings themselves; it only proves the decode path (decoding, normalizing and comparing, and building every scenario's tree and checking it against the recorded `before`) and stands in for `exec-stop` and `exec-crash`.
