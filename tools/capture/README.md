# tools/capture

What the debug app's `--automation` mode (`Sources/FTAppKit/Automation/`) needs:

- `elements.json`: logical element names mapped to accessibility identifiers (`swift`), and whether an element's text is its
  accessibility label (`labelled`). Tests read them too.
- `readme/`: the scenes behind the README's screenshots, taken by `scripts/readme-screenshots.sh`.

A scenario is a JSON file with `name`, `root` and `steps`; `Sources/FTAppKit/Automation/Scenario.swift` lists every step.
The script freezes the clock with `FILETRAIL_NOW`.
