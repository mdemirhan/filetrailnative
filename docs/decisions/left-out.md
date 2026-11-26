# Decisions: left out on purpose

What the app doesn't do, on purpose, kept so the reasons are not lost and the findings not rediscovered.
Part of the owner's decisions: [the index](../decisions.md) lists the other parts.
A feature left out "for now" sits with the area it belongs to;
engineering work left for later is in [state/tech-debt.md](../state/tech-debt.md).

- **The sidebar doesn't filter as the file list does, and its type-to-select has no "contains" fallback.**
  The sidebar keeps prefix type-to-select with its reset timer and shows nothing of what was typed, as Finder's does.
  The tree knows only expanded rows, and a tree filter would have to keep parent folders and could hide the current location.
- **There is no update mechanism.**
  People are not told of new versions.
  Kept on 2026-11-21.
