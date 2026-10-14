# tools/parity-matrix

Parity status that moves by script (PLAN.md §5.2). Files: `docs/port/parity/tests.tsv` (every case of the
original) and `features.md` (every feature row).

- `extract.ts` rebuilds the case list from the original at the pinned commit (keeps status, test and note).
- `sync.ts` reads citations and results and updates both files.
- `report.ts` prints compact counts by class, area and feature status (`state.py status-md` embeds it).

## Citing

In `Tests/**/*.swift`, a comment on the line before a `@Test`, or inside its body:

```swift
// T-1a2b3c4d T-5e6f7a8b      cases of the original this test ports
// F-123                      a UI-row test can cite features
// B-NAV-014                  a test or scenario can cite a behavior rule of docs/port/behaviors/*.md
// covered-by-feature F-123   the T ids cited by this test are proven by the feature instead
// N/A T-1a2b3c4d <reason>    not ported, with the reason (a row, no test needed)
```

An id that doesn't exist in `tests.tsv` / `features.md` is an error, reported as `file:line`.

## Running

```
bun tools/parity-matrix/sync.ts            # runs `swift test --parallel --xunit-output build/logs/parity-xunit.xml`, then updates
bun tools/parity-matrix/sync.ts --no-run   # uses the last result in build/logs/
bun tools/parity-matrix/sync.ts --no-write # validates citations, prints what would change; no test run
bun tools/parity-matrix/sync.ts --check    # gate: no writes, no test run; fails on invalid citations or stale files
```

`tests.tsv`: `swiftTest` gets `Target/function` of the citing tests; status is `ported` when cited and
`passing` when every citing test passed (without results, an existing `passing` is kept). `N/A` and
`covered-by-feature` rows keep their status and note. Idempotent.

`features.md`: columns `ID | Feature or behavior | Spec | Planned WP | Tests | Scenario | Behaviors | Status`. Tests comes
from F citations, Scenario from the top-level `"features": ["F-..."]` key of `tools/capture/scenarios/*.json`.
Status is `done` when every test and scenario of the row passes (a scenario passes when
`tools/capture/out/<name>/diff/summary.json` shows no geometry miss), `partial` when it has some evidence
but not all passing, `todo` otherwise. Statuses other than these three are left as written.

`behaviors.tsv`: one row per `B-` rule of `docs/port/behaviors/*.md`, columns `id | area | improvement | tests | scenarios | status`.
Tests come from `B-` citations in Swift tests, scenarios from the top-level `"behaviors": ["B-..."]` key of the scenario JSON. Status is
`todo`, `partial` or `done` by the same rules as features; `N/A` for a rule cited as `// N/A B-... reason`. An unknown `B-` id is an error.
The `Behaviors` column of `features.md` is generated: an F row lists up to 8 rules that share identifiers (camelCase names, file names) with it;
it stays empty where no match is clear. `report.ts` prints a behaviors summary per area.

Scenarios close e2e rows: the top-level `"tests": ["T-..."]` key of a scenario JSON lists the `tests.tsv` cases it proves
(unknown ids are errors). Such a row gets `swiftTest` `scenario/<name>` and is `passing` when every listed scenario passes
(`ported` otherwise). A Swift citation, N/A or covered-by-feature on the same row wins.
