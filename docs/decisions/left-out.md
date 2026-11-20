# Decisions: left out on purpose

Part of the owner's decisions: [the index](../decisions.md) lists the other parts.

Not done, and not to be done without a plan of its own. Kept so the reasons are not lost and the findings not rediscovered.

- **Space as Quick Look a second after the last key of a filter: to be looked at again.** Kept as it is for now (see "Space and the filter"). A key that means one thing or another by how long ago the last one was pressed is hard to foresee: "my", a pause, then Space opens Quick Look where a space was meant.
- **The file clipboard on the system pasteboard.** See the standing decisions in [the index](../decisions.md).
  - known-issues.md now says so for people.
- **Search inside archives.** The search field is dimmed inside an archive, and a search from a folder doesn't look into the archives in it (fd can't, and Finder doesn't). The filter still narrows the folder of an archive on screen.
- **Fuzzy search through fd.** See "Plain Text search finds what the filters find".
- **The sidebar filtering as the file list does, or a "contains" fallback to its type-to-select.** The sidebar keeps prefix type-to-select with its reset timer and shows nothing of what was typed, as Finder's does. The tree knows only expanded rows, and a tree filter has to keep parent folders and can hide the current location.
- **The sidebar as a real source-list outline** (about 1,000 lines). A redesign with every sidebar interaction test redone.
- **The in-window dialog framework replaced by `NSAlert` and sheets.** High risk; about 3,800 lines of tests drive it.
  - The cheap part is done: alerts and sheets share one base for their panel, footer, button row and Tab order, and use the system's checkboxes and pop-up buttons.
- **The clipboard popover as an `NSTableView`; the path bar as `NSPathControl`.** Worth doing once the system controls elsewhere show how they sit.
  - Sheets, the Info panel, Settings and the icons are now the system's; these two are still not specified.
- **Menu enablement by `validateMenuItem` instead of pushed state.**
  - The cheap part is done: the menu bar is updated in place, not rebuilt.
- **Drag tracking by AppKit's callbacks** (`draggingEnded`, the system's spring-loading) instead of timers. Needs hand tests of drags from other apps first.
- **One write slot instead of two kept in step by a polling loop, and the early-event buffers.** Sound today; the order of "operation ended" against "next write may start" is delicate.
  - When stalls were measured, the paste's `usleep(50)` loop at its end and the progress hop to the main queue (about 1 µs an event) were left with it.
- **The six in-memory file systems in the tests.** Moving them onto real temporary folders is about 1,900 lines of test changes, with medium confidence.
  - The file-system protocols' members are now all required, so every test double implements them all.
- **Flushing the journal's record of a folder moved to another disk.** The copies themselves are now written out before the originals go (see "A move to another disk is written out to that disk before the original is deleted"). Still not flushed: the record of a folder move to another disk, which a power cut could leave naming a folder that isn't the paste's.
  - A folder that replaces another by a move to another disk has a wider gap: after a power cut that loses the other disk's last writes, the folder at the destination can still be the one that was to be replaced, and recovery, finding a folder there and the original at its source, says the moved folder is in place. Telling the two apart needs the journal to say when the swap was made, which is a change to its format and to the order of a Replace's writes.
- **Partial files under 32 MB left behind by a crash.** Needs a measured cost of journaling smaller files.
- **File ids of 2^53 or more treated as unknown.** Needs a check on a FAT disk of which ids are really shared.
- **Date and number formats tied to the language, not the region; English words around localized dates.**
  - Names now sort in the user's language; dates and numbers are unchanged.
- **The default accent as the system's accent.**
- **An update mechanism.** There is none; people are not told of new versions.
- **The app log file.** Nothing in the app reads it; keep it if people are asked to send it.
- **The response cache's 3-second lifetime, the hand-written app-state writer, the visited-folders ranking constants, the path bar's 250 ms single-click delay, matching AppKit's private views by class name.**
  - The response cache never merged identical requests in flight: two listings of one folder asked at once both read it. Left as is.
- **Alerts are not clamped to the window's height.**
- **Small helpers that are similar but not identical** (parent path, leaf name, trimming with different whitespace sets, exact path equality, thousands grouping with different locales, key codes, "hold until released" test gates, the review-resolve-execute test harness, three seeded generators in tests). Take one only when a bug fix touches it.
  - The identical copies were merged. These differ and stay apart: the drag rules' volume root (it counts UTF-16 units), the disk-image name trim and the application path trim (different whitespace sets), the counts in Eject and the toolbar (they round above 2^53), the clipboard summary's plural (no grouping), the counts that follow the locale, and `Date.epochMilliseconds`, which rounds in FTFoundation and rounds down in FTFileSystem.
- **Test folder and suite names that no longer match their contents, and duplicate tests of the same behavior.**
- **About 30 "nothing happened after a fixed sleep" checks; the goldens that depend on the machine** (`kind-strings.json`, `folder-size-trees.json`, `search-sort.json`); **tests that depend on installed apps, the system appearance or the keyboard layout.** A larger piece of work with little payoff per test.
- **The size of the screenshots in `docs/screenshots`** (about 8 MB).
- **Settings' rows and cards on `NSGridView` and `NSStackView`.** Settled meanwhile: page layout, not a control, and a dozen layout tests pin exact frames.
- **Caching the write engine's looks at destinations.** Settled meanwhile, by measuring: dropping a look before a file's copy would save about 0.1% of a small file's time, and caching the review's path lookups about 5% of a review of 2,000 conflicts, at the cost of threading a cache through safety checks that must run twice.
- **Moving a restored window back on screen.** Settled meanwhile: AppKit already moves a window whose frame is off every screen onto the main screen when it is shown.
