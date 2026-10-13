# tools/capture

The UI comparison pipeline of PLAN.md §5.4 and the in-app flows of §5.5. One scenario drives the original
Electron app and the native app into the same state, and the two captures are compared.

```
tools/capture/run.sh [--tier wp|wave|final] [--acceptance] [--selftest] [scenario...]
```

- No scenario named: every scenario tagged with the tier, from `scenarios/` and `scenarios/acceptance/`.
  `--acceptance` runs only the acceptance flows. A named scenario is `name`, `acceptance/name` or a path.
- `--tier wp` (the default) only reports differences; `wave` and `final` also exit 1 on a geometry miss
  (an element off, missing on either side, or an unmet expectation). Exit 3 is a pipeline failure: a side
  that didn't finish, a missing capture, a step the original couldn't do, or an expectation the original
  didn't meet.
- `--selftest` checks the comparison itself: a native capture and an Electron capture are each compared
  with themselves (no difference allowed), and `report.ts selftest` runs a hand-made pair of geometry
  dumps through `compare` (one element 3 pt off, one missing on each side, one unmet expectation), which
  must be reported as exactly that.

## Scenarios

A scenario (`scenarios/*.json`, `scenarios/acceptance/*.json`) has:

- `name`, `description`, `root` (relative to the fixtures folder), `now` (the frozen clock, local ISO
  time), `steps`;
- `features` (the `F-` rows it proves), `tier` (any of `wp`, `wave`, `final`), and for acceptance flows
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

`elements.json` maps a logical name to the original's CSS selector (with the child holding the text, or
`textAttribute` for an icon button named by its `aria-label`) and the Swift `accessibilityIdentifier`
(text matched against the view's text, its text fields, or its accessibility label). `first` compares only
the top-left match, `text` also compares font size, weight and color, and `geometry: false` names an element
only for steps; it is not compared. Names for dialogs and menus follow `docs/port/inventory/ui.md` §3.

## The two sides

- **Swift**: the debug app's `--automation <scenario> --out <dir> --elements <file>` mode
  (`Sources/FTAppKit/Automation/`), with `FILETRAIL_NOW` set from the scenario.
- **Electron**: `electron/driver.ts`, run with Bun and the reference build's Playwright. Its captures are
  cached in `~/Library/Caches/filetrail-port/captures/<referenceCommit>/<hash>/` and rerun only when the
  scenario, `elements.json`, `preferences.json` or the driver changes, and only a run where every step
  worked and every expectation held is cached.

## Reports

- **Geometry** (`report.ts`): ±1 pt frames, exact font size, weight and color. An element one side has
  and the other doesn't is `missing (swift)` or `missing (electron)`, counted apart from `off`:
  `geometry: 2 off, 9 missing (swift) of 16 (max 3pt)`.
- **Pixels**: `tools/pixeldiff` (compiled into `build/pixeldiff/`), traffic lights and scrollers masked.
- **Output**: `out/<scenario>/{electron,swift,diff}` and `out/contact.html`, the side-by-side sheet with
  each scenario's features, unmet expectations and notes.

## Acceptance flows

`scenarios/acceptance/a01…a17` are the improvements A1–A17 of PLAN.md §3.4a, tagged `wave` and `final`,
written from the rules in `docs/port/behaviors/` (listed under `behaviors`). They are complete on the
Electron side; the native app reports what it can't do yet. Parts that can't run here are named in each
flow's description (Replace's Trash and crash recovery, quit and relaunch, disk images, UI zoom).
