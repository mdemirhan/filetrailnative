# tools/parity

The reference app's own TypeScript (in the clone `tools/reference/setup.sh` builds) records expected answers as goldens in `Tests/Golden/<suite>.json`; Swift tests check the port against them without Bun.

- `gen.sh [suite...]` regenerates goldens; `gen.sh --check` fails with a short diff if any would change (run it after re-pinning the reference).
- `lib/reference.ts` imports reference modules by path (`importReference("packages/contracts/src/paths.ts")`), so their own imports resolve in the clone; `lib/prng.ts` is the seeded PRNG.
- Golden format: `{ suite, referenceCommit, seed, generator, cases: [{ name, input, output }] }`.

## Adding a suite

1. Write `golden/<suite>.ts` exporting `seed` (a number) and `generate(rng)`, returning `[{ name, input, output }]` with unique names: hand-picked edge cases first, then random ones from `rng`, each `output` computed by the reference function.
2. Run `tools/parity/gen.sh <suite>` and commit `Tests/Golden/<suite>.json`.
3. In a test: `let cases: [GoldenCase<In, Out>] = try Golden.load(suite: "<suite>")`, then `Golden.expectMatches(cases) { port($0) }`. It reports the first 10 mismatches, one line each, comparing outputs as JSON (NFC and NFD differ).

## Execution scenarios

`exec/run.ts <scenario.json>` builds a fresh tree in a temp folder, pastes through the reference engine (`packages/core`, with the native addon), and prints the tree before and after (`exec/snapshot.ts`), the result (paths as `$ROOT/...`, timestamps and undo log left out), the runtime questions and the status sequence. A scenario:

```json
{ "name": "copy one file into an empty folder",
  "tree": [{ "path": "source/a.txt", "kind": "file", "content": "hi\n", "mode": "0644", "flags": ["uchg"] },
           { "path": "destination", "kind": "dir" }, { "path": "link", "kind": "symlink", "target": "a.txt" }],
  "paste": { "mode": "copy", "sources": ["source/a.txt"], "destination": "destination" },
  "policy": { "file": "skip", "directory": "skip", "mismatch": "skip" },
  "answers": ["overwrite", "keep_both"],
  "stopAt": null }
```

`answers` reply to runtime questions in order ("skip" when they run out). `stopAt: { "afterEvent": n }` (stop the paste after its n-th event) is not supported yet. `FTTestSupport.ExecScenario` decodes the same JSON and builds the tree in Swift; `TreeSnapshot` writes the snapshot JSON byte for byte as `snapshot.ts` does, which `exec/selftest.sh` checks on a tree with every kind of item.
