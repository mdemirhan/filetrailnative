# Decisions

The owner's decisions about how File Trail behaves and how its code is kept, each with its reason. A change that goes against one of them needs the owner's yes first; [principles.md](principles.md) says how a decision is weighed, and when to ask about making an exception or relaxing one. Open issues are in [state/known-issues.md](state/known-issues.md), background work in [state/battery.md](state/battery.md).

The decisions are kept by area. An entry names another by its title in quotes, which may be in another of these files.

| File | What it holds |
|---|---|
| This file | The standing decisions, below: what the app is built on |
| [decisions/names-and-search.md](decisions/names-and-search.md) | How names are ordered and matched, search, the filters, the Go To, Move To and Extract To box |
| [decisions/views.md](decisions/views.md) | The List, Icons, Compact List and Previews views, their sizes, Quick Look, how items are named and drawn |
| [decisions/windows-and-panes.md](decisions/windows-and-panes.md) | Two panes, workspaces, tabs, the menus and their keys, Back and Forward, the sidebar, Settings |
| [decisions/file-operations.md](decisions/file-operations.md) | Copy, move and Replace, what protects files, folder sizes, Paste as File, Copy Contents, Convert Images |
| [decisions/archives.md](decisions/archives.md) | Compress, Extract and Extract To, and the plan to browse archives |
| [decisions/code.md](decisions/code.md) | How work lands, how it is tested and released |
| [decisions/left-out.md](decisions/left-out.md) | What is not done on purpose, and why |
| [decisions/must-stay.md](decisions/must-stay.md) | What looks removable and is not |

## The standing decisions

- **The minimum macOS is 26.** There are no fallbacks for macOS 14 or 15, and the Liquid Glass look is the only one built.
- **Matching the earlier app pixel for pixel is not a goal.** Prefer the system's controls, symbols and look. Code, tests and goldens that existed only to match the earlier app's stylesheet or layout are gone.
- **The system's look.** Tabs and toolbars use Liquid Glass. Commands use SF Symbols, Finder's where Finder has the command. Sheets, the Info panel and Settings use the system's checkboxes, pop-up buttons, switches, number fields and tables.
- **Font sizes and row heights are the app's own, not Finder's**: sidebar 14 pt, icon labels 13, list 14, path bar 12. From Finder the app takes the Favorites and Locations icons as system symbols, the Locations icon color, the unfocused selected fill and the toolbar's sizes. Favorites icons use the app's accent, not the system's, and the search field keeps its own 200 pt width rather than Finder's.
- **Dark mode uses Finder's colors.** The content's background is the system's content material, so it takes the desktop's tint as Finder's does. The path bar is 3.3% white lighter and the sidebar's gray selection is 13.5% white, both measured from Finder. Light mode is unchanged.
- **Glass goes on brief surfaces only.** Toasts, the progress card, plain alerts (a title, a message and buttons) and the filter pill are glass, and keep their edge and shadow so they read over a white pane. Go To and Move To, the paste review, the Rename sheet, the path bar's suggestion list, and alerts with a list or a field stay opaque. The system's own sheet is opaque and its alert is glass, and glass behind lists and fields lets colorful content smear behind the text.
- **The Info panel is a plain split item**, not the system's inspector item. The toolbar lays its material over plain items only; as an inspector the panel's own color showed through the toolbar in dark mode.
- **File Copy, Cut and Paste use the app's own clipboard**, the one the toolbar's clipboard button lists, not the system's. What this means for people is in known-issues.md. Copy Path puts text on the system's clipboard, and Copy Contents a file's image or text.
- **Batch rename keeps JavaScript regular-expression rules, for now.** `JSRegExp.swift` stays as it is. Moving to `NSRegularExpression` would remove about 530 lines, but it would change what `\d`, `\w`, `\s` and `\b` match (ASCII only today, Unicode in ICU), how `ß` and ligatures fold, which syntax is accepted, and the wording of pattern errors. `expandReplacement` (`$1`, `$&`, `$<name>`) stays either way. Revisit later.
- **The search-result highlight uses `NSRegularExpression` for Regex searches.** The rule above covers batch rename only, where the pattern decides what is renamed. The search itself is done by `fd` with Rust's regex, so JavaScript's rules were never what people got there. Plain Text is marked by the app's own matcher (see "Typing finds names by their letters in order").
- **VoiceOver is not a supported target.** Don't add accessibility work; the VoiceOver-only code is gone. Accessibility identifiers and `accessibilityPerformPress()` stay, as the tests press things through them.
- **There is no import or upgrade path from the earlier app.** The earliest release of this app is v0.8.0, and its bundle id is `com.filetrail.native`. Nothing reads files only the earlier app wrote.
- **A window holds at most 25 tabs.**
