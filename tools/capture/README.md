# tools/capture

What the debug app's `--automation` mode (`Sources/FTAppKit/Automation/`) needs:

- `elements.json`: logical element names mapped to accessibility identifiers (`swift`), and whether an element's text is its
  accessibility label (`labelled`). Tests read them too.
- `readme/`: the scenes behind the README's screenshots, taken by `scripts/readme-screenshots.sh`.

A scenario is a JSON file with `name`, `root` and `steps`; `Sources/FTAppKit/Automation/Scenario.swift` lists every step.
The script freezes the clock with `FILETRAIL_NOW`.

## Timing a scroll, once

The `scroll` step (`{"step": "scroll", "distance": 4000, "ms": 1500}`) moves the folder's view a step each frame at
120 Hz and reports, in `report.json`, how long the main thread took per frame. A frame has about 8.3 ms. It moves the
clip view itself, so it times the main thread's part even where a trackpad would scroll on AppKit's own thread. Nothing
runs it by default: it's for checking a change by hand. A release measures with the same code, in `FrameTimeGUITests`
(see `scripts/release.sh`), in the debug build the tests run in. Automation is in debug builds only, so for numbers close to a
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
