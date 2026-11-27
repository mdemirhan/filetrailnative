# Speed in large folders

Under way: phase 1 is built; phases 2 and 3 are planned.
Investigated on 2026-11-27 at the owner's request: opening, scrolling and filtering folders of 1,000 to 10,000 files at the smallest sizes in a maximized window, as the owner's own views show them, with no stutter or freeze as far as can be.

## What was measured

An optimized build with `DEBUG` defined (as `tools/capture/README.md` says to time a scroll), with probes that write every turn of the main run loop of 8 ms or more, and milestones (a folder asked for, read, shown; its previews all in; each filter key), to a log.
The probes and the scripts are on the branch `claude/perf-investigation`, which is not to be landed: its commits are the probes and the prototypes measured.

- The owner's profile, copied: a maximized window (1651 × 1040), `1000-files` in the Icons view at 32 pt, `2500-files` in the List with five columns, `5000-files` in the Compact List at 160 pt columns, and `10000-files` in both the Icons view at 32 pt and the Compact List at 160 pt.
  The folders are in `~/z-test-tmp`, made of real files of every kind (`_kitchen-sink`); `10000-files` is clones of `5000-files` and their copies.
- Each case: launching into the folder; going in for the first time after launching into its parent; going out and in again; Back and Forward; scrolling 8,000 points down and back (the `scroll` step, 120 Hz); typing a filter, a key every 900 ms and five keys at once; a size change, a view switch, resizing.
- Previews with Quick Look's cache emptied (`qlmanage -r cache`), as a first visit is, and warm.
- Causes from Time Profiler (`xctrace`) and `sample`, and per-item counters.
- A Mac's numbers move by 10 to 20% from run to run: comparisons were made with both builds run in turn, three times where it mattered, and runs right after a build left out (macOS checks a new binary the first time it starts it: 380 ms before the app's code runs, against 10 ms after).

### Before

Main thread held, in ms; a frame at 120 Hz is 8.3 ms.

| Folder and view | Launch into it: items drawn / settled | First entry | Going back in, Forward | Scroll: median, frames late | A filter key |
|---|---|---|---|---|---|
| 1000, Icons 32 | 600 / 830 | 680–940, one block up to 840 | 360–400 | 6–8, 15–48% | 77–296 |
| 2500, List | 430 / 590 | 160 | 80–100 | 7, 16–26% | 90–137 |
| 5000, Compact 160 | 650 / 910 | 400–740, one block up to 530 | 250 | 13, 100% | 190–440 |
| 10000, Icons 32 | 550 / 770 | 280–370 | 365–407 | 8–11, 41–97% | 116–434 |
| 10000, Compact 160 | 590 / 860 | 310 | 235 | 13, 100% | 143–273 |

- All previews of `1000-files` in: 2.1 s after a launch with Quick Look's cache empty (1.1 s warm), 1.7 s after a first entry (1.0 s warm).
- A size change 107–155 ms, a view switch 173–261 ms, maximizing the window 105 ms, each one block.
- Going back into a folder after it was scrolled built about 600 items against 230 the first time: AppKit prepares a larger area after a scroll.

### Where the time goes

Reading a folder is not it: 10,000 files read in 40 to 66 ms, off the main thread.
Each item on screen costs the main thread 0.2 to 0.35 ms (made, configured, laid out, drawn), and at the smallest sizes a maximized window shows 250 to 600 of them; every one is made again on going in, Back, Forward, each filter key, a size change and a view switch.

1. **Items are heavy.** An Icons item has about 11 views, a Compact List item 7, laid out partly through Auto Layout.
  Its icon is drawn by the CPU from the system's icon of many sizes; its name is laid out with TextKit (two lines, shortened in the middle) and drawn by the CPU; several views are there only for automation.
  On first entry about 60% of the main thread is AppKit making and laying out these views.
2. **Names are drawn in strips.** A name scrolling in is drawn by AppKit a strip at a time, the part just come into sight: about five times in the Compact List, four in the Icons view, each laying the whole name out again.
3. **Every change rebuilds every item on screen**: a filter's own matching is 20 to 60 ms of a key's 100 to 250.
4. **Previews** load four at a time, 128 pixels for icons that need 64.
5. **At launch** a maximized window's folder was laid out at the normal size while hidden, then shown and zoomed, and laid out again.
6. **Scrolling a Compact List frame** (13 ms): Core Animation committing and drawing (names and icons by the CPU), the items coming in, AppKit updating the tracking areas of every view in the grid, items restyled as their tags arrive.
  The Compact List also gives up AppKit's own scrolling thread (`SidewaysScrollView` overrides the wheel), so a trackpad scroll waits on the main thread.

## Phase 1: built

On the branch `claude/perf-phase1`.

- **1. Previews: 12 at once, at the size shown** (built).
  The Icons view's store loads 12 at a time (the Previews view keeps 4 for its large pictures), asks 64 pixels for 32 pt icons, keeps 2,000 under 96 MB and lets them go when macOS says memory is short.
  Measured, first entry into `1000-files` with Quick Look's cache empty, median of three: all previews in **1.10 s instead of 1.70 s (−36%)**, the main thread unchanged.
- **2. Name layout remembered** (built).
  The lines a name wraps into and its width are kept as its shortened form was, and all three keep 60,000 names (4,000 emptied the cache in any larger folder).
  Measured: going back in and Forward **10–15% quicker**, a filter key 5–10%.
- **4. A filter's list drawn once for the keys typed ahead** (built).
  From 500 items, a key typed while more keys already wait still narrows the list, orders it and selects at once, but leaves the drawing to the last key waiting; a key that isn't the filter's, a click, a context menu or a selection made from outside draws it first, any other full redraw (another folder, a view switch, a sort) takes its place, and a timer draws it within 150 ms if nothing else does.
  Nothing waits when the app keeps up: a pause of 60 ms tried first merged nothing, as keys came 100 ms apart, and did 15% more work.
  The queue is looked at in a run-loop mode of the app's own: looked at in the default mode, the run loop ran the work waiting there (a block, a timer) in the middle of a key, which a full test run showed by hanging in another test's waiting block.
  Measured, five keys typed faster than the app draws: **−54%** in `10000-files` (645 → 295 ms), **−59%** in `5000-files` (415 → 170), **−70%** in `1000-files` (208 → 63).
  Measured with the five keys put in the app's own queue at once, the way keys typed while the app is busy wait there; keys sent through the window server need the Accessibility permission the tests don't have, so real typing is to be tried by hand. AppKit takes the keys waiting from the window server in a batch as it takes one, so a key typed while the app is two or more keys behind is seen, and the first of a burst draws.
  A menu command (⌘I, ⌘⌫, ⌘F) draws a waiting list and tells its selection before it acts.
- **6. A window opened maximized is zoomed before its folder is laid out** (built): brought back at launch, opened with none open when the last one closed maximized, or a window view set to Maximized. It is zoomed through AppKit while still hidden, so the green button and Un-maximize go back to the normal frame.
  Found while checking it, and older than it, and fixed: in a window brought back maximized with several tabs, Un-maximize from a tab other than the one in front went to AppKit's default size, not the normal one; the window's delegate now sends it to the normal frame (checked in the app with three tabs).
  Measured, launching into the folder, median of the runs after the first: items drawn **12–19% sooner** (10000 Icons 545 → 480 ms, 1000 Icons 620 → 500, 5000 Compact 620 → 500), the biggest block **16–24% shorter**, settled 5–10% sooner.

Left out of phase 1, after measuring:

- **3. The Compact List laid out again as tags arrive**: planned as the cause of names drawn several times over, it wasn't; with it gone the frames were the same.
  The cause is the strips (above).
  A name drawn once into a picture and copied for each strip was pixel for pixel the same but slower (24 ms a frame against 13.5): the picture's copy happens in Core Animation's commit, on the CPU.
  The picture as the label's layer contents was quicker (12.0 ms) but the text field drew its own text under it, so names showed twice.
  Doing it properly needs the name to be a view of its own drawing, not a text field: phase 2, item 7.
- **5. The sidebar off the first frame**: measured, it already comes after it.
  It is a block of its own of about 60 ms right after (the tree laying out its rows), which phase 2 can look at.

## Phase 2: planned

- **7. Lighter items** (the most work, medium risk), in three steps each measured and landed alone:
  - 7a: icons drawn once at their size and given to the layer as a picture, redrawn when the screen's scale, the appearance or the accent (folder icons are drawn in it) change, or the icon is replaced by a custom one or a preview;
  - 7b: the views there for automation replaced by accessibility identifiers on the views that stay, the same in debug and release builds;
  - 7c: about 5 views an item, frames set by hand, and names as views that draw themselves (or a picture as their layer's contents), so a name is drawn once whatever the strips.
  Expected: 35–50% less an item; first entries from about 500 to about 250 ms, a rebuild from about 220 to about 120, Icons scrolling from about 10.5 to 6–7 ms a frame.
  What reads the views (drag images, Quick Look's zoom, the rename field, spring-loading, the selection, cut and hidden items, tags, drops) is moved and checked.
- **8. Names fitted ahead**, off the main thread, right after a folder is read, with the same TextKit engine, font and width as on screen (another engine could wrap differently): about 60 ms less on first entry per 600 items.
  Allowed by the decision "What the folder on screen needs is read for it, ahead of the scroll".
- **9. What AppKit prepares**: after a navigation or a reload, only what's on screen and a row or two, then the rest a slice at a time in the moments the main thread is idle, stopping while scrolling or when the window is hidden.
  The folder shows after about 230 items instead of 600 (going back in from about 220 to about 140 ms), the same total work spread over the frames after.
  To check in a spike: that `NSCollectionView` keeps the limit after a reload, and that a fling straight after going in shows no blank.
- **10. The Compact List on AppKit's scrolling thread** (set aside by the owner, 2026-11-27).
  Turning the wheel sideways by overriding it gives up that thread; keeping both probably means a trackpad's vertical swipe no longer moves it sideways, which is the owner's to decide.
- **11. Changes to the folder applied in place** (`docs/state/tech-debt.md`, "Items added or removed shown in place"): about 200 ms a change in packed views of 10,000 to about 10–30 ms.
  A batch update whose counts don't match the data throws: a strict check falls back to a full reload for anything unusual (groups, a sort, a rename under way).
- **12. Details, tags and previews read ahead** for the folder on screen, at low priority and stopped when it's left: rows coming on screen no longer wait for them.

## Phase 3: measuring, planned

- `scripts/frame-times.sh` at the smallest sizes too, in a window as large as the screen.
- An on-demand script that runs the open, go back in, Back, Forward and filter scenario with the probe above and lists the main thread's blocks over 8 ms, against a run made just before.
  Both are in "Speed is measured on demand, in the worst cases" (`docs/decisions/code.md`).

## Decisions changed for this

- "Nothing is read before it is needed" became "What the folder on screen needs is read for it, ahead of the scroll; nothing is read for what isn't shown" (`docs/decisions.md`).
- "The frame times of scrolling are measured on demand" became "Speed is measured on demand, in the worst cases" (`docs/decisions/code.md`).
