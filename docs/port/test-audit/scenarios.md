# Capture scenario audit: checkpoint, final, drop

Read-only audit of `tools/capture/scenarios/*.json` (106 scenarios) and `tools/capture/scenarios/acceptance/*.json`
(17 flows), 2026-10-18. Nothing was run. Sources: the scenario files, `tools/capture/README.md`, PLAN.md §3.4a and
§5.4-5.5, `docs/port/inventory/ui.md`, the WP briefs' scenario ranges (`docs/port/state/wp/*.md`) and
`docs/port/STATUS.md`.

Decisions:

- **checkpoint**: runs at every checkpoint (phase ends, before the user's hands-on checks), and at wave ends and in the final sweep.
- **final**: kept; runs only at wave ends and in the final parity sweep (tiers `wave`, `final`).
- **drop**: a near-duplicate. The scenario named in "covered by" captures the same state. Its `features`/`behaviors` tags
  have to move there first, because `tools/parity-matrix/sync.ts` counts scenario tags.

## 1. Summary

| | checkpoint | final | drop | total |
|---|---|---|---|---|
| Scenarios | 16 | 62 | 28 | 106 |
| Acceptance flows | 7 | 10 | 0 | 17 |
| **Total** | **23** | **72** | **28** | **123** |

Once the drops are made, the final sweep runs 78 scenarios and 17 flows (95). A checkpoint runs 23.

### Checkpoint set and the surface each covers

| # | Scenario | Surface | Built yet? |
|---|---|---|---|
| 1 | `50-toolbar-default-light` | Window chrome (grid, traffic-light inset), default toolbar, List view light, path bar (collapsed) with status text, sidebar in the separate layout as it opens | yes (P5-01/03/06) |
| 2 | `51-toolbar-default-dark` | The same window in the dark theme: List dark, chrome and toolbar dark | yes |
| 3 | `77-sidebar-deep-path` | Sidebar, separate layout: tree rooted above the folder, every folder on the way expanded, the selected row | yes (P5-02) |
| 4 | `75-sidebar-integrated-compact-light` | Sidebar, integrated layout (Favorites inside the tree), and **Compact density** for the sidebar and the List | yes |
| 5 | `03-icons-components-light` | Icons view | no: P5-04 (misses are expected until it merges) |
| 6 | `49-theme-accent-selection` | Accent colour, selection in the focused and unfocused pane, Light/Dark/Auto (5 snapshots) | yes (P4-03) |
| 7 | `148-pathbar-inforow-dark` | Path bar and status bar: the Info Row for one file, dark | yes (P5-06) |
| 8 | `143-infopanel-file-light` | Info panel (hero, Open in, Information, Quick Actions), its resizer and column | yes (P5-06) |
| 9 | `156-toasts-three-stacked` | Context menu (Copy Path chosen three times through a file's menu) and toasts, stacked | yes (P5-09) |
| 10 | `55-sort-menu` | Toolbar pop-up menu (Sort), item ticked after choosing | yes (P5-01) |
| 11 | `59-customize-toolbar` | Customize Toolbar mode: scrim, handles, panel | yes (P5-01) |
| 12 | `39-about-light` | About window | yes (P4-03) |
| 13 | `41-help-getting-around` | Help window (topic list, first topic) | yes (P4-03) |
| 14 | `159-quick-look-space` | Quick Look on Space, opened and closed | yes (P5-09) |
| 15 | `16-go-to-folder-typed` | Go To panel with completions (dialog) | no: P6-01 |
| 16 | `19-settings-general` | Settings window, General tab (dialog) | no: P6-04 |
| A | `a01-search` | A1 search: field, scope, results, background tab | no: P5-07 |
| B | `a02-folder-tree` | A2 tree: keyboard expand, Use as Tree Root, hide/show, Go Home | yes (P5-02) |
| C | `a03-visible-clipboard` | A3: cut marks and count, clipboard popover, paste in another window | no: P5-08 |
| D | `a04-paste-never-destroys` | A4: review sheet, For-all choices, single-conflict alert (the paste dialogs) | no: P3-05, P6-02 |
| E | `a05-undo-redo` | A5: inline rename, move, Trash, Undo/Redo | no: P3-06/07 |
| F | `a13-views` | A13: the three views, List optional columns, Compact List, Quick Look | partly (P5-04 pending) |
| G | `a14-tabs-and-windows` | A14: tab strip, per-tab view, Move Tab to New Window, Merge All Windows | yes (P4-02) |

**Why these seven acceptance flows.** A3, A4 and A5 are about data safety: cutting, pasting onto conflicts and undoing
must not lose files. A1 and A2 are what people use File Trail for most. A13 and A14 are the view and window state
every other surface sits in. Each of them also captures a surface that no checkpoint scenario captures: the search
UI, the clipboard popover, the review sheet and alert, the inline rename field, Compact List and the tab strip.
That is why `14`, `15`, `17`, `18` and `10` can stay out of the checkpoint set. The other ten flows are final:

- a06 Go To: `16` captures the panel.
- a07 type-to-filter: P5-05 isn't merged.
- a08 path bar and history: `148` captures the path bar. It is also today's slowest flow on the Swift side (29 s).
- a09 Settings Shortcuts: `19` captures the Settings window.
- a10: `59` captures the Customize Toolbar mode.
- a11: the size bars are also captured by `89`.
- a12 batch rename: P6-03 isn't merged.
- a15: `49` captures the theme and accent.
- a16: `77` and `143` cover its surfaces.
- a17: folder watching is behaviour, already proven windowless.

**Promote when built.** a12 (Batch Rename sheet) and a09 (shortcut recorder) are the only captures of those two
dialogs. Move each to checkpoint when P6-03 or P6-04 merges, and drop `19` then if a09 joins.

**Coverage gaps (no scenario exists):**

- Progress UI (P5-09 progress, P6-02 copy progress). Nothing captures a progress window or row. Add one with P6-02.
- Batch Rename sheet outside a12.
- Search options menu outside a01.
- Compact List outside a13.

## 2. Every scenario

| File | Decision | Reason | Covered by |
|---|---|---|---|
| `01-list-components-light` | drop | Same root, clock, prefs, window and steps as 50, byte for byte; the capture is identical | `50` |
| `02-list-components-dark` | drop | Same as 51, byte for byte | `51` |
| `03-icons-components-light` | checkpoint | The only Icons view capture | |
| `04-list-sorted-size` | drop | Same folder (photos), sort (size, descending) and window as 89; 89 adds two selected rows | `89` |
| `05-list-sorted-date` | drop | Date Modified sort indicator and newest-first order; 94 reaches the same sort by a header click | `94` |
| `06-list-selection-4` | drop | The same four files selected in the same folder as 140, which also shows the Info Row | `140` |
| `07-list-root` | final | Lighthouse root: a folders-first list of mixed kinds, not shown elsewhere | |
| `08-list-empty-folder` | final | The empty-folder state | |
| `09-back-after-navigating` | final | Back restores the folder and selection (F-590, F-833); a behaviour check | |
| `10-search-typed` | final | Search field with text typed; a01 covers search at checkpoints | |
| `11-context-menu-file` | final | One Copy Path toast with a selected row; 156 runs the same menu three times at checkpoints | |
| `12-rename-f2` | final | Inline rename field and its result; a05 renames with F2 at checkpoints | |
| `13-new-folder` | final | New Folder with its name editing (P3-06) | |
| `14-cut-items-marks` | drop | a03's first snapshot is the same four files cut in the same folder, with marks and the count | `a03` |
| `15-clipboard-popover` | final | The popover for copied items ("2 items copied"); a03 shows the cut variant | |
| `16-go-to-folder-typed` | checkpoint | Go To panel with completions (pending P6-01) | |
| `17-review-sheet-conflict` | final | Review sheet for two conflicts; a04 opens the same sheet at checkpoints | |
| `18-second-tab` | final | Tab strip with two tabs; a14 shows the same strip at checkpoints | |
| `19-settings-general` | checkpoint | Settings window, General tab (pending P6-04) | |
| `20-outside-file-created` | drop | a17 creates a file from outside in the same folder and expects it listed | `a17` |
| `21-menubar-file-trail-light` | drop | Same menu path (File Trail › Settings…) as 19, but captures only the explorer behind Settings | `19` |
| `22-menubar-file-light` | final | File › New Tab through the real menu | |
| `23-menubar-edit-light` | final | Edit › Select All through the real menu | |
| `24-menubar-view-light` | final | View › as Icons through the real menu (the native menu and its checkmark aren't captured) | |
| `25-menubar-go-light` | final | Go › Enclosing Folder through the real menu | |
| `26-menubar-window-light` | final | Window › Show Previous Tab through the real menu | |
| `27-menubar-help-light` | drop | Captures the explorer window, not Help; the shortcuts page itself is captured by 45 | `45` |
| `28-menubar-file-trail-dark` | drop | Dark twin of 21: a menu action doesn't depend on the theme, and 51 captures the dark explorer | `19` + `51` |
| `29-menubar-file-dark` | drop | Dark twin of 22 | `22` + `51` |
| `30-menubar-edit-dark` | drop | Dark twin of 23 | `23` + `51` |
| `31-menubar-view-dark` | drop | Dark twin of 24 | `24` + `51` |
| `32-menubar-go-dark` | drop | Dark twin of 25 | `25` + `51` |
| `33-menubar-window-dark` | drop | Dark twin of 26 | `26` + `51` |
| `34-menubar-help-dark` | drop | Dark twin of 27 | `45` + `51` |
| `35-new-window` | final | ⌘N: a second window on the same folder, cascaded | |
| `36-open-in-new-window` | final | Open in New Window on a selected folder | |
| `37-move-tab-and-merge` | drop | a14 moves a tab to its own window and merges all windows back, with snapshots (move B-VIEW-178/179 to it) | `a14` |
| `38-paste-in-another-window` | final | Copy (not cut) across windows; a port of an original e2e flow | |
| `39-about-light` | checkpoint | About window | |
| `40-about-dark` | final | About window, dark: the only dark capture of it | |
| `41-help-getting-around` | checkpoint | Help window | |
| `42-help-files` | drop | Same Help window and layout as 41, another topic's text | `41` |
| `43-help-searching` | drop | Same as 42 | `41` |
| `44-help-views` | drop | Same as 42 | `41` |
| `45-help-shortcuts` | final | The keycaps: the one topic that renders differently | |
| `46-help-search` | final | Help search with results | |
| `47-help-search-empty` | final | Help search with no match: the empty message | |
| `48-acknowledgements` | final | Acknowledgements window with an entry expanded | |
| `49-theme-accent-selection` | checkpoint | Accent, active and inactive selection, Light/Dark/Auto | |
| `50-toolbar-default-light` | checkpoint | Window chrome, toolbar, List light, path bar, status text | |
| `51-toolbar-default-dark` | checkpoint | The same, dark | |
| `52-tree-hidden` | final | Toolbar reaching the corner (76 pt for the traffic lights) with the tree hidden | |
| `53-info-panel-open` | drop | Panel open with nothing selected in the same folder as 145; same resizer, column and toolbar (move B-INFO-183/185) | `145` |
| `54-narrow-overflow` | final | Narrow window: the » overflow menu | |
| `55-sort-menu` | checkpoint | Toolbar pop-up menu with a ticked item | |
| `56-view-options-menu` | final | The same toolbar menu as 55 with other items; turns on the Info Row | |
| `57-theme-menu` | final | The same toolbar menu as 55; switches to Dark | |
| `58-history-hold` | drop | a08 holds Back for the history list and right-clicks Forward the same way (move B-NAV-026 to a08) | `a08` |
| `59-customize-toolbar` | checkpoint | Customize Toolbar mode | |
| `60-customize-toolbar-dark` | final | Customize Toolbar, dark: the only dark capture of it | |
| `70-sidebar-separate-comfortable-light` | final | Base sidebar: separate, comfortable, light, tree rooted at the folder | |
| `71-sidebar-separate-comfortable-dark` | final | Separate layout, dark | |
| `72-sidebar-separate-compact-light` | final | Separate layout, compact | |
| `73-sidebar-integrated-comfortable-light` | final | Integrated layout, comfortable | |
| `74-sidebar-integrated-comfortable-dark` | final | Integrated layout, dark | |
| `75-sidebar-integrated-compact-light` | checkpoint | Integrated layout and Compact density | |
| `76-sidebar-integrated-compact-dark` | drop | Compact × dark adds nothing: the compact metrics are 75's, the dark integrated colours 74's | `75` + `74` |
| `77-sidebar-deep-path` | checkpoint | Separate layout with the tree expanded four levels deep and the last folder selected | |
| `78-sidebar-click-selection` | final | A click on a tree row selects it and opens its folder | |
| `79-sidebar-separate-compact-dark` | drop | Same reasoning as 76 | `72` + `71` |
| `80-sidebar-sections-closed` | final | Collapsed section headers | |
| `81-sidebar-jump-to` | final | The Jump to pill | |
| `82-sidebar-keyboard-expand` | final | Right then Down in the tree; a02 covers Right only | |
| `83-sidebar-volume-eject` | final | Same steps as 70, but needs a mounted disk image for the Eject button; already final-only and run by name | |
| `85-list-compact` | drop | 72 is the same window state (separate, compact, light, components) plus the tree rooted at the folder | `72` |
| `86-list-optional-columns` | drop | a13's first snapshot uses the same `detailColumns` (Created, Permissions) in the same folder | `a13` |
| `87-list-narrow-pane` | final | Least window width: Name gives way, columns drop | |
| `88-list-fitted-column` | final | Double-click on a column separator fits the column | |
| `89-list-size-bars-selected` | final | Size bars with selected rows | |
| `93-list-inactive-selection` | final | Grey selection in a window that isn't in front (49 covers an unfocused pane, not an inactive window) | |
| `94-list-sort-header-click` | final | A header click sorts the list | |
| `135-pathbar-collapsed-light` | drop | Same steps, prefs and window as 50 (a 100 ms longer wait); the path bar collapses there the same way (move B-INFO-092/093/102/105 to 50) | `50` |
| `136-pathbar-expanded-light` | final | … expands the path into a horizontal scroll | |
| `137-pathbar-editor-suggestions-light` | final | Path editor with suggestions opening upward | |
| `138-pathbar-folder-menu-light` | drop | a08's `folder-menu` snapshot: the same separator menu, opening upward, with the path's folder ticked | `a08` |
| `139-inforow-one-item-light` | final | Info Row for one file, light (148 is its dark twin at checkpoints) | |
| `140-inforow-several-light` | final | Info Row for several items: count and summed size | |
| `141-inforow-folder-light` | final | Info Row for the folder on screen, with Calculate size | |
| `142-inforow-folder-size-light` | final | Info Row with a calculated folder size | |
| `143-infopanel-file-light` | checkpoint | Info panel for a file | |
| `144-infopanel-folder-size-light` | final | Info panel with a calculated folder size | |
| `145-infopanel-folder-light` | final | Info panel for the folder on screen, with Calculate | |
| `146-infopanel-several-light` | final | Info panel for several items | |
| `147-infopanel-file-dark` | final | Info panel, dark: the only dark capture of it | |
| `148-pathbar-inforow-dark` | checkpoint | Path bar and Info Row, dark | |
| `149-infopanel-open-with-menu-light` | final | The Info panel's Open With menu (a16 opens Open With from a context menu) | |
| `150-menu-content-show-info` | final | Show Info from a file's context menu | |
| `151-menu-folder-open-in-new-tab` | final | Open in New Tab from a folder's context menu | |
| `152-menu-background-copy-path` | final | The background context menu (F-814) | |
| `153-menu-background-sort-by-submenu` | final | A context submenu | |
| `154-menu-tree-use-as-root` | final | Use as Tree Root from the tree's context menu (a02 uses ⇧⌘R) | |
| `155-menu-favorite-use-as-root` | final | Use as Tree Root from a favorite's context menu | |
| `156-toasts-three-stacked` | checkpoint | Context menu and stacked toasts | |
| `157-toasts-off` | final | No toast when notifications are off | |
| `158-toast-tab-limit` | final | 101st-tab notice; slow (108 steps), already wave/final only | |
| `159-quick-look-space` | checkpoint | Quick Look | |

### Acceptance flows

| File | Decision | Reason |
|---|---|---|
| `a01-search` | checkpoint | A1, the main reason to use the app; the only full capture of the search UI |
| `a02-folder-tree` | checkpoint | A2, the tree flow; passes on the Swift side today |
| `a03-visible-clipboard` | checkpoint | A3, data safety; the clipboard popover and cross-window paste |
| `a04-paste-never-destroys` | checkpoint | A4, data safety; the review sheet and alert |
| `a05-undo-redo` | checkpoint | A5, data safety; inline rename, Trash, Undo/Redo |
| `a06-go-to` | final | `16` captures the Go To panel at checkpoints |
| `a07-type-to-filter` | final | P5-05 isn't merged; the filter is mostly behaviour, proven windowless |
| `a08-path-bar-history` | final | `148` captures the path bar; covers the dropped 58 and 138; slowest flow today (29 s Swift) |
| `a09-shortcuts` | final | Promote when P6-04 merges (the only shortcut recorder capture) |
| `a10-customize-toolbar` | final | `59` captures the mode at checkpoints |
| `a11-folder-sizes` | final | Size bars also captured by `89` |
| `a12-batch-rename` | final | Promote when P6-03 merges (the only Batch Rename sheet capture) |
| `a13-views` | checkpoint | A13, the three views and Compact List; covers the dropped 86 |
| `a14-tabs-and-windows` | checkpoint | A14, the tab strip and window management; covers the dropped 37 |
| `a15-make-it-yours` | final | `49` captures the theme and accent at checkpoints |
| `a16-favorites` | final | Sidebar and Open With surfaces covered by `77` and `143` |
| `a17-outside-changes` | final | Folder watching, drag, hidden files; covers the dropped 20 |

No flow is dropped: each one is a different improvement, A1-A17.

## 3. Near-duplicate families

**Sidebar, 70-83.** Seven scenarios (70-76, 79) differ only in the layout (separate or integrated), the density
(comfortable or compact) and the theme (light or dark), all with the same steps. At checkpoints, **77** stands for the
separate layout: it shows more than 70 (expanded branches and a selected row four levels down). **75** stands for the
integrated layout and also carries Compact density. The final sweep keeps the four comfortable combinations
(70, 71, 73, 74) and one compact capture per layout (72, 75). The two compact-dark captures (76, 79) are dropped:
the compact metrics and the dark colours are each already captured separately. PLAN §5.4 also says Compact density is
checked by token unit tests, not screenshots. 78 and 80-82 are interactions (click, collapsed headers, Jump to,
keyboard) and are final. 83 has the same steps as 70, but its Eject button needs a mounted disk image; it stays
final-only.

**List, 01-09 and 85-94.** The base List state (app/src/components, light, 1200×760) is captured four times:

- 01 and 50 are identical, byte for byte.
- 135 is the same with a 100 ms longer wait.
- 85 is it in Compact, which 72 also captures.

**50** stays at checkpoints for List light, **51** for List dark (02 is the same as 51), and **03** for Icons view. The
dropped ones duplicate a kept capture with a trivial difference:

- 04 is 89 without the selection.
- 05 shows the same date sort as 94.
- 06 has the same selection as 140.
- 86 has the same columns as a13.

07 (root), 08 (empty), 09 (Back), 87 (narrow), 88 (fitted column), 89 (bars), 93 (inactive window) and 94 (header
sort) each show a different state. They are final.

**Menu bar, 21-34.** These choose a menu item through the real menu bar. The native menu itself is never captured: each
scenario captures the explorer window after the command. The dark twins (28-34) repeat a theme-independent action
over a window 51 already captures in dark. 21 duplicates 19's menu path, and 27 captures the explorer window, not the
Help page it opens (45 captures that page). 22-26 stay final as the only end-to-end menu dispatch checks. None runs at
checkpoints: menu wiring is covered by P4-01's windowless menu tests.

**Help, 41-47.** 42-44 are the Help window on another topic, with only the body text different from 41. 41 stays at
checkpoints. 45 (keycaps), 46 (search) and 47 (no match) render differently and stay final.

**Toolbar, 50-60.** 50 and 51 are the smoke captures. 55, 56 and 57 are the same toolbar pop-up menu with different
items; 55 stays at checkpoints. 58 repeats a08's Back-hold and Forward-right-click and is dropped. 53 is 145's panel
state and is dropped. 59 (Customize Toolbar) stays at checkpoints, and its dark twin 60 is final.

**Path bar, Info Row and Info panel, 135-149.** Light/dark pairs:

- 139 and 148: Info Row.
- 143 and 147: Info panel.

**148** (the path bar and the Info Row together, dark) and **143** (the panel, light) stay at checkpoints. The Info
Row and panel scenarios for several items and for folders (140-142, 144-146) are different content states and are
final. 135 is 50 and 138 is a08's folder menu, so both are dropped.

**Context menus and toasts, 11 and 150-158.** A right click resolves the native menu without drawing it, so these
scenarios compare what the chosen item does. **156** (three Copy Path toasts) stays at checkpoints because it covers
the context menu, the toast and the stacking together. 11 is the one-toast version and is final. 150-155 are each a
different menu (file, folder, background, tree, favorite) and are final.

**Windows and clipboard, 14-18 and 35-38.** 14 and 37 are captured inside a03 and a14, so they are dropped. 15, 17
and 18 are close to a03, a04 and a14 but capture a different state (copied rather than cut, a two-file conflict, a
tab on the same folder), so they stay final.

## 4. Run time

**What was measured.** The only timings on disk are from the acceptance run of 14 Oct:

- `tools/capture/out/a*/{swift,electron}/report.json`, which has per-step milliseconds;
- `build/logs/acceptance-w1.txt`.

`out/` holds only the latest run, so the 106 scenarios have no `report.json` there. In that run:

- The 17 flows took about 3 min 48 s from the first to the last diff summary (about 19:26:18 to 19:30:06).
- Swift's steps added up to 209 s, and Electron was replayed from its cache: `capture-electron.log` is empty, and
  both sides' reports were written in the same second.
- Each flow cost about 1.2 s beyond its Swift steps (launch, compare, pixel diff).
- On the Swift side a step took about 135 ms plus its declared wait. An `expectSheet` for a surface that isn't built
  yet waits out its 5 s timeout (the average was 5.2 s).
- Electron took about 190 ms per step.

**How the scenarios were estimated.**

- Swift side: steps × 135 ms + declared waits + 1.2 s per scenario. The upper end of each range adds 5 s per
  `expectSheet`, for a surface that isn't built yet.
- Electron, when not cached: steps × 190 ms + waits + about 3 s to launch. The 3 s launch is an assumption, not a
  measurement.
- Acceptance flows: their measured times.
- None of this includes the app build or the vision review.

| Set | Runs | Swift side | Electron, uncached |
|---|---|---|---|
| Today's checkpoint (`ui-check.js` default: `--tier wp` and `--acceptance`) | 104 + 17 = 121 | ~9-12 min | ~13 min |
| Everything (`--tier final`) | 106 + 17 = 123 | ~9.5-12 min | ~13 min |
| **Proposed checkpoint** | 16 + 7 = 23 | **~2.5-3 min** | ~3 min |
| Final sweep after the drops | 78 + 17 = 95 | ~8-10 min | ~11 min |

Electron runs again only when a scenario, `elements.json`, `preferences.json` or the driver changes. At a usual
checkpoint, the run time is therefore the Swift side: about 150-185 s instead of 545-695 s, roughly a quarter of today's.

## 5. To apply (not done here)

1. **Pass the checkpoint list to `ui-check.js`.** Its `scenarios` argument defaults to `--tier wp`, which is 104 of
   the 106 scenarios. `run.sh` only knows the tiers `wp`, `wave` and `final`. So either pass the 16 scenario names and
   the 7 flow names, or add a `checkpoint` tier to `run.sh` and to those files.
2. **Move the tags before deleting anything.** Before deleting a dropped file, move its `features` and `behaviors` to
   the scenario that covers it, so that `sync.ts` keeps counting them. The ones that matter:
   - 37's B-VIEW-178/179 → a14
   - 53's B-INFO-183/185 → 145
   - 58's B-NAV-026 → a08
   - 135's B-INFO-092/093/102/105 and F-744 → 50
   - 76/79's B-TREE rows: already on 75/72
   - the F- rows of 01, 02, 04-06, 85 and 86 → their covering scenarios
3. **Approval.** As the pending userRequest says, the user approves this list before any file is deleted.
