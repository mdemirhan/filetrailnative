# tools/capture

The UI comparison pipeline of PLAN.md §5.4. One scenario drives the original Electron app and the native
app into the same state, and the two captures are compared.

```
tools/capture/run.sh [--tier wp|wave|final] [--selftest] [scenario...]
```

- **Scenarios** (`scenarios/*.json`): `name`, `description`, `root` (relative to the fixtures folder),
  `now` (the frozen clock, local ISO time), optional `setup.emptyFolders`, and `steps`. Each step is an
  object with a `step` key: `window {width, height}`, `prefs {prefs}`, `open {path}`, `select {names}`,
  `key {key, modifiers}` (DOM key names; `cmd`, `shift`, `option`, `ctrl`), `type {text}`,
  `command {id}` (the original's renderer command ids), `wait {ms}`, `snapshot {name}`,
  `geometry {name}` (`allViews: true` on the Swift side dumps every view, for finding views to name).
- **Element names** (`elements.json`): logical name → the original's CSS selector (and the child holding
  the text) and the Swift `accessibilityIdentifier`.
- **Swift side**: the debug app's `--automation <scenario> --out <dir>` mode
  (`Sources/FTAppKit/Automation/`), with `FILETRAIL_NOW` set from the scenario.
- **Electron side**: `electron/driver.ts`, run with Bun and the reference build's Playwright. Its
  captures are cached in `~/Library/Caches/filetrail-port/captures/<referenceCommit>/<hash>/` and
  rerun only when the scenario, `elements.json` or the driver changes.
- **Diffs**: geometry (±1 pt frames, exact font size, weight and color) in `report.ts`; pixels with
  `tools/pixeldiff` (compiled into `build/pixeldiff/`), traffic lights and scrollers masked.
- **Output**: `out/<scenario>/{electron,swift,diff}` and `out/contact.html`, the side-by-side sheet.

`--tier wp` only reports differences; `wave` and `final` also exit 1 on a geometry miss. Exit 3 is a
pipeline failure (a side that didn't finish, a missing capture, a step the original couldn't do).
`--selftest` compares a native capture with itself, which must show no difference.
