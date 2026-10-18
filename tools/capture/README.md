# tools/capture

The UI comparison pipeline of PLAN.md §5.4 and the in-app flows of §5.5. One scenario drives the original
Electron app and the native app into the same state, and the two captures are compared.

```
tools/capture/run.sh [--tier wp|checkpoint|wave|final] [--acceptance] [--selftest]
                     [--refresh-original <scenario...>] [scenario...]
```

- No scenario named: every scenario tagged with the tier, from `scenarios/` and `scenarios/acceptance/`.
  `--acceptance` runs only the acceptance flows. A named scenario is `name`, `acceptance/name` or a path.
- `--tier wp` (the default) and `checkpoint` only report differences; `wave` and `final` also exit 1 on a geometry miss
  (an element off, missing on either side, or an unmet expectation). Exit 3 is a pipeline failure: a side
  that didn't finish, a missing capture, a step the original couldn't do, or an expectation the original
  didn't meet.
- `--refresh-original <scenario...>` captures the original app again for those scenarios (and runs them);
  see "The two sides".
- `--selftest` checks the comparison itself: a native capture and an Electron capture are each compared
  with themselves (no difference allowed), and `report.ts selftest` runs a hand-made pair of geometry
  dumps through `compare` (one element 3 pt off, one missing on each side, one unmet expectation), which
  must be reported as exactly that.

## Tiers: when each runs

| Tier | Scenarios | When |
|---|---|---|
| `checkpoint` | 16 scenarios + 7 acceptance flows (below) | Every checkpoint (phase ends, before the user's hands-on checks), through `ui-check.js` |
| `wave` | the checkpoint set + 62 scenarios + 10 acceptance flows | Wave ends |
| `final` | the same set as `wave` | The final parity sweep |
| `wp` | the 16 checkpoint scenarios (no flows) | A work package's own run, if one is ever allowed |

A checkpoint scenario is tagged `wp`, `checkpoint`, `wave`, `final`; a checkpoint flow `checkpoint`, `wave`,
`final`; every other item `wave`, `final` only. With no scenario named, `--tier T` runs the scenarios and flows
tagged `T`; `--acceptance` runs every flow whatever its tier.

The checkpoint set (23), chosen by the 2026-10-18 test audit (`docs/port/test-audit/scenarios.md`):

- Scenarios: `50-toolbar-default-light`, `51-toolbar-default-dark`, `77-sidebar-deep-path`,
  `75-sidebar-integrated-compact-light`, `03-icons-components-light`, `49-theme-accent-selection`,
  `148-pathbar-inforow-dark`, `143-infopanel-file-light`, `156-toasts-three-stacked`, `55-sort-menu`,
  `59-customize-toolbar`, `39-about-light`, `41-help-getting-around`, `159-quick-look-space`,
  `16-go-to-folder-typed`, `19-settings-general`.
- Acceptance flows: `a01-search`, `a02-folder-tree`, `a03-visible-clipboard`, `a04-paste-never-destroys`,
  `a05-undo-redo`, `a13-views`, `a14-tabs-and-windows`.

The other 72 items (62 scenarios, 10 flows) are final-only. The audit dropped 28 near-duplicate scenarios; the
`features`/`behaviors` tags of each moved to the scenario that covers it. When a scenario for a new surface is
added, tag it `checkpoint` only if it is the single capture of that surface. A12 (Batch Rename) and a09
(shortcut recorder) move to `checkpoint` when P6-03 / P6-04 merge.

No scenario captures the copy/paste progress card: the original shows it only after an operation has run 500 ms
and while it still runs, and no driver step can slow or hold a copy.

## Scenarios

A scenario (`scenarios/*.json`, `scenarios/acceptance/*.json`) has:

- `name`, `description`, `root` (relative to the fixtures folder), `now` (the frozen clock, local ISO
  time), `steps`;
- `features` (the `F-` rows it proves), `tier` (any of `wp`, `checkpoint`, `wave`, `final`), and for acceptance flows
  `behaviors` (the `B-` rules of `docs/port/behaviors/` its steps check);
- `setup.emptyFolders` (folders to make, dated to the clock) and `setup.scratch: true` for a scenario that
  changes files: each side then runs on a fresh copy of `root` at `~/Library/Caches/filetrail-port/work/
  <name>/<root name>` (the same path on both sides; only one copy exists at a time). The copy is named to
  both apps in `FILETRAIL_SCENARIO_ROOT`. `fs` steps refuse to run without it.

Each step is an object with a `step` key:

| Step | Fields | What it does |
|---|---|---|
| `window` | `width`, `height` | Sets the window's content size. |
| `prefs` | `prefs` | Any key of the original's preferences (`preferences.json`), plus `density` (`comfortable`/`compact`) for the four compact switches. Before the first live step they are seeded into `app-state.json`; later, keys the whole app shares are sent as Settings sends them, `viewMode` goes through its command, and other window session keys are `partial`. On the Swift side each key has a handler in `AutomationPrefs` (work packages register theirs); a key without one is reported as unsupported by name, and the run goes on. |
| `open` | `path` | Opens a folder (relative to `root`). |
| `select` | `names` | Selects items of the list by name. |
| `key` | `key`, `modifiers` | A key press: DOM key names; modifiers `cmd`, `shift`, `option`, `ctrl`. Keys that only the native menu takes (⌘Z) go through `command` or `menu` instead. |
| `type` | `text` | Types into whatever has the keyboard. |
| `command` | `id` | The original's renderer command ids (`AutomationCommands.all`). |
| `click` | `element`, `index`/`text`, `button` (`left`/`right`), `count` (1–3), `modifiers`, `holdMs` | Clicks the element's center. Swift synthesizes `NSEvent`s through `NSApp` (no Accessibility permission). A right click resolves the native menu without showing it. |
| `pick` | `element`, `option` | Sets a pop-up (`<select>`, `NSPopUpButton`) to the item with that title. |
| `menu` | `path` | Chooses a menu bar item by titles (`["File", "New Folder"]`; a trailing `…` is optional). |
| `contextMenu` | `element`, `index`/`text`, `choose` | Opens the element's context menu and chooses an item (a list for a submenu). Without `choose` Swift reports `partial`: a native menu can't be drawn into the capture. |
| `drag` | `from`, `to`, `modifiers`, `toEdge` (`top`/`bottom`) | File items: the original starts a native drag session, so the driver plays it as `e2e/dragIn.spec.ts` plays a drag from another app; Swift calls the drop handlers through `AutomationDragSource`/`AutomationDropTarget` and says so in the report. HTML drags (favorites) send their drag events; other drags (toolbar items) are pointer drags. `to` may be in another window. |
| `expectSheet` | `name` | Waits up to 5 s for the named dialog, sheet, popover or field. |
| `sheetButton` | `label` | Clicks the enabled button with that title in the dialog in front (or the window). |
| `newWindow`, `newTab` | | Opens one; later steps act on it. |
| `selectTab` | `index` | Shows that tab. |
| `selectWindow` | `index` or `title` | Later steps act on that window: by title any window (Settings), by index the explorer windows in the order they opened. |
| `fs` | `op` (`create`, `write`, `rename`, `delete`, `chmod`, `lock`, `touch`), `path`, `contents`, `directory`, `append`, `to`, `mode` (octal), `locked` | Changes the scratch copy from outside the app (folder-watch flows). What it makes, writes or touches is dated to the clock. |
| `expect` | `element` (name or `{name, index, text}`), `text`, `visible`, `count` | A soft assertion, recorded under `check` in the report. The original must meet it (else exit 3); this app missing it is a difference (`expect: N unmet (swift)`). |
| `wait` | `ms` | |
| `snapshot` | `name` | A PNG at 2×. |
| `geometry` | `name`, `allViews` | Frames and text styles of the named elements (`allViews: true` on the Swift side dumps every view, for finding views to name). |

Elements are found as on screen: every match whose center is in the window, top to bottom then left to
right, narrowed by `text`, then `index`. A step's element scrolled out of its list is scrolled into view
first.

## Elements

Work packages that run side by side keep their names in `elements.d/<WP id>.json` (the same format); `run.sh`
merges them into `elements.json` (a name given twice is an error) and passes the merged file to both sides
(`build/capture/elements.json`), and the native automation merges them the same way when it finds
`elements.json` itself.

`elements.json` maps a logical name to the original's CSS selector (with the child holding the text, or
`textAttribute` for an icon button named by its `aria-label`) and the Swift `accessibilityIdentifier`
(text matched against the view's text, its text fields, or its accessibility label). `first` compares only
the top-left match, `text` also compares font size, weight and color, and `geometry: false` names an element
only for steps; it is not compared. Names for dialogs and menus follow `docs/port/inventory/ui.md` §3.

## The two sides

- **Swift**: the debug app's `--automation <scenario> --out <dir> --elements <file>` mode
  (`Sources/FTAppKit/Automation/`), with `FILETRAIL_NOW` set from the scenario.
- **Electron**: `electron/driver.ts`, run with Bun and the reference build's Playwright. The original is
  captured once per scenario and cached in `~/Library/Caches/filetrail-port/captures/<referenceCommit>/<hash>/`.
  The key is the scenario file, `preferences.json` and `CAPTURE_FORMAT_VERSION` in the driver (bump it only
  when what a capture writes changes; that recaptures every scenario once). It is not keyed on
  `elements.json`/`elements.d`: the driver records which element ids it looked for, and `report.ts` shows a
  name added later as `not captured (electron)` instead of comparing it. Run `--refresh-original <scenario...>`
  to capture the original again for the scenarios that need the new names. Failed runs (a failed step, an unmet
  expectation, a driver error) are cached too, with their exit status, so the original isn't launched again
  for a scenario that can't pass; fix the scenario or use `--refresh-original`. A run killed by the time limit,
  or one that wrote no report, isn't cached. `run.sh` ends with how many times it launched the original.

## Reports

- **Geometry** (`report.ts`): ±1 pt frames, exact font size, weight and color. An element one side has
  and the other doesn't is `missing (swift)` or `missing (electron)`, counted apart from `off`:
  `geometry: 2 off, 9 missing (swift) of 16 (max 3pt)`.
- **Pixels**: `tools/pixeldiff` (compiled into `build/pixeldiff/`), traffic lights and scrollers masked.
- **Output**: `out/<scenario>/{electron,swift,diff}` and `out/contact.html`, the side-by-side sheet with
  each scenario's features, unmet expectations and notes.

## Acceptance flows

`scenarios/acceptance/a01…a17` are the improvements A1–A17 of PLAN.md §3.4a, tagged `wave` and `final` (a01–a05, a13, a14 also `checkpoint`),
written from the rules in `docs/port/behaviors/` (listed under `behaviors`). They are complete on the
Electron side; the native app reports what it can't do yet. Parts that can't run here are named in each
flow's description (Replace's Trash and crash recovery, quit and relaunch, disk images, UI zoom).
