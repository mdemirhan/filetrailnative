# tools/capture

What the debug app's `--automation` mode (`Sources/FTAppKit/Automation/`) needs:

- `elements.json`: logical element names mapped to accessibility identifiers (`swift`), and whether an element's text is its
  accessibility label (`labelled`). Tests read them too.
- `readme/`: the scenes behind the README's screenshots, taken by `scripts/readme-screenshots.sh`.

A scenario is a JSON file with `name`, `root` and `steps`; `Sources/FTAppKit/Automation/Scenario.swift` lists every step.
The script freezes the clock with `FILETRAIL_NOW`.

## Checking a change by hand

A change that needs trying in the app (how it behaves, looks or feels) is tried by whoever made it, in a debug build driven
by a scratch scenario:

- `scripts/build-app.sh debug --out build/check-app` (a release build takes over a minute and is for `scripts/release.sh`
  and `scripts/ci.sh --full`). Quit a running copy first.
- Write a throwaway scenario on a scratch folder and run the app's binary with `--automation <scenario> --out <folder>
  --elements tools/capture/elements.json --user-data-dir <folder>`, with `CFFIXED_USER_HOME` set to a scratch home, as
  `scripts/readme-screenshots.sh` does. `report.json` in the out folder says how each step went.
- `menu` steps fail when a title is missing or dimmed, so they check titles; `choose` picks a pop-up button's item by its
  title (`{"step": "choose", "element": "tab view view", "item": "Viewer"}`), as its menu would, and fails on a
  dimmed pop-up; `key` steps with modifiers go through the menu
  bar's keys; `snapshot` and `windowShot` give pictures to look at. System Events has no accessibility permission here:
  don't ask for it.
- No before and after pictures for the owner, and no waiting for a look to be approved: look, say in the report what was
  checked and anything that seems off, and commit.
- While trying, build and run; the full `scripts/ci.sh` is for once the behavior is right, before committing.

## Timing the main thread

`scripts/stalls.sh` launches into large folders, goes in, back in, Back, Forward and filters them, and lists the main
thread's blocks against a run made before (its header says how). Its runs set `FILETRAIL_STALLS_LOG`, which makes the
app write each block of 8 ms or more and a few moments (a step begun, a list drawn whole, the previews all in) to that
file, and leave the front to whatever app has it. Two steps are for it: `{"step": "maximize"}` zooms the window as the
green button does, and `{"step": "type", "text": "image", "queued": true}` puts the keys at the end of the app's queue at
once, as keys typed faster than the app draws wait there.

## Timing a scroll, once

The `scroll` step (`{"step": "scroll", "distance": 4000, "ms": 1500}`) moves the folder's view a step each frame at
120 Hz and reports, in `report.json`, how long the main thread took per frame, stopping at the end of the folder. A
frame has about 8.3 ms. It moves the clip view itself, so it times the main thread's part even where a trackpad would
scroll on AppKit's own thread. Nothing runs it by default: it's for checking a change by hand. `scripts/frame-times.sh`
measures with the same code, in `FrameTimeGUITests`, in the debug build the tests run in. Automation is in debug builds only, so for numbers close to a
release build, build optimized with `DEBUG` defined, into a folder of its own:

```bash
swift build -c release -Xswiftc -DDEBUG --scratch-path build/timing --product FileTrail
```

Then put that binary in a debug app (`scripts/build-app.sh debug --out build/timing-app`, copy
`build/timing/release/FileTrail` over `Contents/MacOS/FileTrail`, `codesign --force --sign - "build/timing-app/File Trail.app"`)
and run a scenario that opens a large folder, waits for its previews and scrolls:

```bash
"build/timing-app/File Trail.app/Contents/MacOS/FileTrail" --automation scroll.json --out build/timing-out --user-data-dir build/timing-data
```
