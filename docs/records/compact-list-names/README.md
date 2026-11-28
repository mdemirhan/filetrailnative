# The Compact List's names: how they are drawn (2026-11-28)

Phase 2 of the performance plan (`docs/plans/performance.md`, item 7c) drew the Compact List's names once, whole, instead
of a strip at a time as they scrolled in. Six ways were built and measured to do it; the owner chose way 5. This record
keeps what each way was, its code, its numbers and how it looked, for a change that comes back to it.

## Why names were slow

AppKit draws a layer-backed view coming into sight in a scroll a strip at a time, the part just come into view, and a
text field lays its whole name out again for each strip: about five times a name in the Compact List. Counted with
breakpoints during the same flick through `5000-files` (Compact List, 160 pt), names drawn for each item made: 1.9 as
`main` draws them, 1.0 drawn whole.

## The ways

| | Way | Scroll, a frame | Flick, a frame | Look against `main` |
|---|---|---|---|---|
| 1 | As `main`: a text field AppKit draws | 11.0–12.3 ms | 33–35 ms | — |
| 2 | Text field with a plain `CALayer` of its own (`makeBackingLayer`) | 1.3–1.9 ms | 23–25 ms | same ink and sharpness, 0.58 px lower |
| 3 | View of its own, drawn by `draw(_:)`, AppKit's layer | 11.0–11.8 ms | 32–33 ms | pixel for pixel the same |
| 4 | View of its own, a picture in `updateLayer()`, font smoothing off | 1.3–1.9 ms | 24 ms | visibly thinner |
| 5 | **Kept.** As 4, smoothing as AppKit draws | 1.3–1.8 ms | 23–25 ms | same as way 2 (6 pixels of 7.2 million differ) |
| 6 | Text field whose prepared area is all of it (`preparedContentRect`) | 11.9 ms | 34 ms | pixel for pixel the same |

Main-thread time over each frame, the median of three runs, in the Compact List at 160 pt, maximized, in the owner's
`5000-files` and `10000-files` (`~/z-test-tmp`), on battery. A scroll is 8,000 points in 2 s; a flick 20,000 points in
0.5 s, about 40 a frame, as fast as a trackpad's flick is at its start. Ways 2 and 5 were measured as full builds;
3, 4 and 6 as prototypes, which draw the same way.

The gain comes only from a layer that keeps the whole drawn name. Ways 3 and 6, where AppKit keeps the layer, are as
slow as `main`: AppKit draws its own layers in strips, and a prepared area doesn't change it.

## What was learned

- **A text field that draws its own layer** (`wantsUpdateLayer`) is given a private subview by AppKit on screen,
  `NSTextFieldSimpleLabel`, which draws the text itself. The first 7c did that, and every name showed twice, cut short
  two ways (`first-7c-doubled-names.diff`). AppKit adds it only in a window on screen, so a windowless test can't see it;
  `OnScreenNamesGUITests`, which a release runs, can.
- **A layer a view makes itself** (way 2) gets no screen scale: AppKit gives it only to the layers it makes. Without
  setting it, names were drawn at 1× on a Retina screen and looked soft. It isn't snapped to whole pixels either, as
  AppKit's are.
- **Font smoothing:** AppKit draws text into its layers with smoothing on. A picture drawn with it off (way 4, and the
  first 7c) is thinner than every other text in the window.
- **The remaining 0.58 px:** ways 2 and 5 put each line 0.29 pt lower than AppKit does (measured as the centre of the
  ink: 153.611 against 153.029 px in a sample name; the ink itself 244,027 against 244,028, the sharpness within 0.4%).
  Not explained: rounding the baseline to a pixel (up, down or nearest), AppKit's 16-bit pixel format, and the name's
  frame on whole pixels each left it as it was or moved it too far. It doesn't show at 1:1. Drawing the picture with
  AppKit's own `cacheDisplay(in:to:)` leaves a view that draws its own layer nearly empty.
- **Why way 5 over way 2** (the owner, 2026-11-28, on which is simpler, more maintainable, less fragile, more future
  proof): way 2 is less code but rests on how a text field behaves inside, which AppKit keeps to itself and changed
  under us once; way 5 uses only what AppKit documents for this (`wantsUpdateLayer`, `updateLayer()`,
  `layer.contents`), and AppKit gives its layer the scale and whole pixels. Way 5 isn't a text field, so automation
  reads its text (`ElementFinder.ownText`), the markers over its item take any view as their source, and VoiceOver reads
  it as static text; with those in, it measured the same as way 2.

## Way 5 against `main`, everything measured

All of phase 2 with way 5, against `main` with the same measuring code: `scripts/stalls.sh`, the owner's packed folders,
maximized, each view at its smallest size, the median of three runs, 2026-11-28, the screen unlocked, on battery.
Main thread held, in ms, `main` → way 5:

| Folder and view | Launch: drawn | First entry: drawn | Going back in: busy | Forward: busy | Filter key: busy | Scroll: frame | Flick down / back: frame |
|---|---|---|---|---|---|---|---|
| 1000, Icons 32 | 483 → 398 | 195 → 137 | 305 → 107 | 281 → 106 | 191 → 94 | 8.1 → 7.3 | 25.1 / 31.0 → 18.4 / 23.8 |
| 2500, List | 336 → 335 | 94 → 92 | 108 → 94 | 108 → 103 | 117 → 107 | 7.4 → 7.3 | 13.2 / 13.4 → 11.9 / 11.8 |
| 5000, Compact 160 | 462 → 375 | 187 → 111 | 330 → 134 | 319 → 134 | 386 → 230 | 10.8 → 1.3 | 40.2 / 42.9 → 24.0 / 23.4 |
| 10000, Icons 32 | 450 → 420 | 191 → 161 | 251 → 84 | 267 → 82 | 220 → 151 | 7.8 → 7.3 | 46.7 / 36.1 → 37.9 / 27.5 |
| 10000, Compact 160 | 458 → 395 | 199 → 134 | 337 → 126 | 325 → 129 | 309 → 197 | 11.1 → 1.3 | 42.5 / 44.9 → 25.0 / 24.4 |

Back is within the runs' spread everywhere (−24% to +4% busy). In `10000-files`' Compact List the parent is drawn 13 ms
later (36 → 49), its busy time the same (52 → 54; the runs 46, 59 and 52 against 54, 61 and 54): profiled, way 5 does
less on the main thread there than `main` (navigation 23–25 samples of a millisecond against 29–30), and draws the
names' pictures in the same pass, before the moment a list counts as drawn. Way 2's runs gave the same numbers within
2%, apart from that Back (64 ms busy).

## The code

Each diff is against the code as it is with way 5 (`Sources/FTAppKit/Content/PictureLabel.swift` and its users), and
applies with `git apply` unless it says otherwise.

- `way-2-text-field-plain-layer.diff`: way 2, whole (the label a `ListLabel` with a plain layer given the screen's
  scale, the markers and automation as they were).
- `prototype-view-draw.diff`: way 3, a view of its own drawn by `draw(_:)`.
- `prototype-prepared.diff`: way 6, a text field whose prepared area is all of it.
- `first-7c-doubled-names.diff`: the first 7c, a text field that drew its own layer: the doubled names. Against the
  commit before 7c ("Item markers and clipboard marks are in an item only while they show"), not today's code.
- Way 4 is way 5 with `context.setShouldSmoothFonts(false)` in `picture(scale:)`.

## The pictures

`names-light-zoom.png`, `names-dark-zoom.png` (8×) and `names-light-1x.png`, `names-dark-1x.png` (1:1, Retina pixels):
the same names of `1000-files`, as `main`, way 2, way 5 and way 4 draw them. They were taken from inside each build,
which drew its window's layers into a picture (`CALayer.render(in:)` run through `lldb`), not from the screen: the
Screen Recording permission isn't the agent's to give. Pixels were compared by a small tool counting those that differ
by more than 8 of 255.

## How it was measured

- Frames: a scratch scenario per way (`tools/capture/README.md`, "Timing a scroll, once") in an optimized build with
  `DEBUG` defined, the ways by turns, three runs each.
- Everything else: `scripts/stalls.sh`, which now flicks as well, against `main` with the same measuring code.
- Draws: breakpoints that continue by themselves on the name's `draw(_:)` and the item's `configure`, during the same
  flick.
