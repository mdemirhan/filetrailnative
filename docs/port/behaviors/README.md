# Behavior rules of the original, from its code

These rules are the specification for the UI and interaction work (PLAN.md §3.4a). They were extracted on 2026-10-13 from the original's source and its own tests at the pinned commit `e4d0872`. Each rule cites the file:line that decides it and the test ids (`docs/port/parity/tests.tsv`) that check it.

| File | Area | Rules |
|---|---|---|
| `nav.md` | Navigation, history, Back/Forward, Go menu, startup, folder memory | 226 |
| `sel.md` | Selection, keyboard, type-to-filter, inline rename, marquee, paging | 183 |
| `info.md` | Info panel, Info Row, path bar, status text, folder sizes, size bars | 201 |
| `srch.md` | Search sessions, options, scopes, results, refinement, background tabs | 196 |
| `tree.md` | Sidebar tree, tree root, Favorites, Locations, volumes, eject | 201 |
| `clip.md` | Cut/copy/paste, visible clipboard, review and conflicts, drag, write states, Undo questions | 199 |
| `view.md` | Views, columns, sorting, toolbar, tabs, window commands, folder watch UI, notifications, context menus | 239 |
| `dlg.md` | Go To / Move To, Batch Rename sheet, Settings, shortcut recorder, theme and accent, Help and About | 263 |

## How they are used

- A work package implements the rules of its area. Its Swift tests and scenarios cite the `B-` ids they prove (`// B-NAV-014`, or `behaviors: [...]` in a scenario). The parity sync counts them (P0-11).
- Rules about UI zoom are out of scope (DEVIATIONS D-005). Mark them `N/A D-005`.

## Open questions

Each file ends with "Open questions": places where the code and its comments or tests disagree, or where a path wasn't traced. The work package that implements the area settles each one by **running the reference app** in the capture harness, with a scenario that shows what actually happens. It then records the answer in the rule (or as a new rule) and cites the scenario. Copy the original's actual behavior unless it is clearly a bug; a bug goes to `docs/port/DEVIATIONS.md` as proposed.
