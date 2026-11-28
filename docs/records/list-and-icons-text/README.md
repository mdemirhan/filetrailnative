# The List's rows and the Icons view's names: what was measured (2026-11-28)

After phase 2 (`docs/plans/performance.md`), the owner found scrolling `2500-files` in the List the choppiest. Recorded
with Instruments while they scrolled, the List's main thread was busy 600 to 850 ms of each second on the first pass and
the second alike: the cost was building and drawing each row as it came in, not reading anything. Six ideas were tried
behind switches in one build, against the state the owner had tried (`claude/perf-phase2-golden`), and the four that
won were built. This record keeps what each was, its code and its numbers, for a change that comes back to it. How the
Compact List's names came to be drawn the same way is in `docs/records/compact-list-names/`.

## Where a List scroll went

Four seconds of the owner's scroll in the List, main thread:

| | Share |
|---|---|
| The rows' text drawn by AppKit, a strip at a time as each row came in (`NSViewBackingLayer display`) | ~39% |
| Each row made and set up (`tableView(_:viewFor:row:)`, the cells) | ~19% |
| Tracking areas brought up to date for each new row's views (tooltips, cursors) | ~13% |
| The window's key view loop worked out again for each new row (`_setDefaultKeyViewLoop`) | ~8% |
| Layout | ~8% |

## The ideas, measured alone

Main-thread time over each frame, the median of three runs by turns, maximized, in the owner's packed folders
(`~/z-test-tmp`), from switches in one optimized build with `DEBUG` defined (`experiment-switches.diff`, which applies
to `claude/perf-phase2-golden`). A scroll is 8,000 points in 2 s; a flick 20,000 points in 0.5 s. With every switch
off the build measured as the golden one.

| Idea (switch) | View | Scroll | Flick | Kept |
|---|---|---|---|---|
| Text drawn whole (`FT_EXP_LIST_WHOLE`) | List | 7.2 → 4.3–4.5 ms, late 16% → 0% | 12.0 → 9.4–9.9 | yes |
| Row background as the layer's color and corners (`FT_EXP_LIST_BARLAYER`) | List | 7.2 → 6.5–6.6 | 12.0 → 10.6–11.5 | yes |
| No tooltips (`FT_EXP_LIST_NOTIPS`) | List | the same | the same | no |
| Markers and the clipboard glyph only while they show (`FT_EXP_LIST_FEWER`) | List | the same | the same | no |
| All four together | List | 7.2 → 3.0, late 0% | 12.0 → 7.8–8.0 | |
| Names drawn whole (`FT_EXP_ICONS_WHOLE`) | Icons | 9.1 → 4.1, late 74% → 40% | 26.7 → 22.3 (2500) | yes |
| Names fitted while idle (`FT_EXP_ICONS_WARM`) | Icons | the same | first flick through 10,000: 40.3 → 34.2 | yes |
| Both | Icons | 9.5 → 3.9 | first flick through 10,000: 40.3 → 29.2 | |

- Tooltips cost nothing measured here, but the measured scroll moves the view, not the pointer, and AppKit brings
  tracking areas up to date when the pointer is over the window: by hand they were 13% of the scroll. Pricing them
  needs a recording of a real scroll.
- The key view loop is AppKit's, worked out for each row added; fewer views per row didn't change the time.
- Fitting names while idle helps only a first pass: the Icons view keeps every name it fits (`IconLabelText`, up to
  60,000), so a second pass already found them. In `2500-files` the scroll before the flick passes over nearly the
  whole folder, so its flick shows nothing.
- Phase 2 had found the Icons view's names gained nothing from being drawn whole: that was measured with its first
  version, a text field that drew its own layer, to which AppKit adds a label of its own on screen that drew each name
  again (`docs/records/compact-list-names/`).

## What was built

- **The List's row background** is its layer's color and corners (`DetailsBarView.updateLayer`); the drop highlight
  is a view there only while a drag is over the row (`DropHighlightView`, shared with the Compact List).
- **The Icons view fits its names while idle** (`IconViewController.fitNamesAhead`): once a folder is drawn, 2 ms at
  most at a time, waiting while the folder scrolls; again for a new icon size, a new grid or items put in. It reads
  nothing, so it is within "nothing is read for what isn't shown".
- **The Icons view's names and the List's text** are views of their own that draw a picture of their text into their
  layer, as the Compact List's names do (`PictureLabel`, way 5 of `docs/records/compact-list-names/`): `IconNameLabel`,
  and in the List `RowTextLabel` with `NameLabel`, `FolderColumnLabel` and `TagsLabel`. Each is placed whole pixels
  high and wide, so its picture is its size exactly, and placed again when the window moves to a screen of another
  scale; the size is right-aligned from a right edge on a whole pixel, so the sizes of every row end in one line. The List's cell no longer hands the table a text field: automation
  reads a row's name from its name label (`ElementFinder.ownText`, `AutomationRunner`), the row's markers take any view
  as their source, and VoiceOver reads each as static text.

## The built version against golden

Three runs each by turns, plugged in, 2026-11-28:

| View, folder | First draw | Scroll | Flick down / back |
|---|---|---|---|
| List, 2500 | 92 → 71 ms | 7.4 → 2.8 ms, late 23% → 0% | 12.0 / 12.0 → 7.6 / 7.6, late 100% → 27% |
| List, 10000 | 123 → 107 | 7.4 → 2.8, late 24% → 0% | 12.9 / 12.3 → 8.0 / 8.0, late 100% → 41% |
| Icons, 2500 | 143 → 132 | 7.2 → 1.4 | 25.7 / 25.1 → 22.2 / 20.4 |
| Icons, 10000 | 162 → 154 | 7.5 → 1.3 | 40.8 / 29.5 → 29.7 / 22.5 |

In the Icons view the median frame is low but about 40% of a scroll's frames are still late: those that bring in a row
of items, which costs more than a frame.

## How it looks

Taken from inside each build, which drew its window's layers into a picture (`CALayer.render(in:)` through `lldb`), in
`1000-files`, and compared with golden: the Compact List is pixel for pixel the same. In the List and the Icons view
the text has the same ink (within 0.4%) and sharpness (within 0.4%) and the same horizontal place, and sits 0.6 px
lower, as the Compact List's names do against `main`; the row backgrounds are pixel for pixel the same.
`list-*-zoom.png` and `icons-*-zoom.png` show a name before and after, 4×, light and dark.

In the List and the Compact List each text's layer lands on whole pixels of the window (`OnScreenNamesGUITests`
checks it). In the Icons view it doesn't quite: AppKit places an item's view a hair off the whole points its layout
gives when the rows are spread by fractions of a point (a layout of 1942 shown at 1941.94), and doesn't move the
layer onto the pixel. A name there is a tenth of a pixel off the grid; measured in such a row, it is as sharp as the
text field it replaced (0.3% sharper). Rounding the items' frames in the layout didn't change where AppKit put them.

## The code

- `experiment-switches.diff`: every idea behind its switch, against `claude/perf-phase2-golden`, for measuring only.
- The built version is in the code itself; the commits that made it say which idea each is.
