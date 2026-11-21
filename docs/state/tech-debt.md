# Engineering work left for later

Changes to how the app is built that were weighed and left, each with why, so the findings are not made again. None changes what people see. Not to be done without a plan of its own; what may simply be taken up when a fix touches it says so. Open faults are in [known-issues.md](known-issues.md).

## AppKit in place of the app's own

- **The sidebar as a real source-list outline** (about 1,000 lines): a redesign with every sidebar interaction test redone.
- **The in-window dialog framework replaced by `NSAlert` and sheets.** High risk; about 3,800 lines of tests drive it. The cheap part is done: alerts and sheets share one base for their panel, footer, button row and Tab order, and use the system's checkboxes and pop-up buttons.
- **The clipboard popover as an `NSTableView`; the path bar as `NSPathControl`.** Worth doing once the system controls elsewhere show how they sit; not specified yet.
- **Menu enablement by `validateMenuItem` instead of pushed state.** The cheap part is done: the menu bar is updated in place, not rebuilt.
- **Drag tracking by AppKit's callbacks** (`draggingEnded`, the system's spring-loading) instead of timers. Needs hand tests of drags from other apps first.

## The write engine

- **One write slot instead of two kept in step by a polling loop, and the early-event buffers.** Sound today; the order of "operation ended" against "next write may start" is delicate. When stalls were measured, the paste's `usleep(50)` loop at its end and the progress hop to the main queue (about 1 µs an event) were left with it.
- **File ids of 2^53 or more treated as unknown.** Needs a check on a FAT disk of which ids are really shared.

## Small things left as they are

- **The response cache's 3-second lifetime, the hand-written app-state writer, the visited-folders ranking constants, the path bar's 250 ms single-click delay, matching AppKit's private views by class name.** The response cache never merged identical requests in flight: two listings of one folder asked at once both read it.
- **The app log file.** Nothing in the app reads it; keep it if people are asked to send it.
- **Small helpers that are similar but not identical** (parent path, leaf name, trimming with different whitespace sets, exact path equality, key codes, "hold until released" test gates, the review-resolve-execute test harness, three seeded generators in tests). Take one only when a bug fix touches it. The identical copies were merged; these differ and stay apart: the drag rules' volume root (it counts UTF-16 units), the disk-image name trim and the application path trim (different whitespace sets), and `Date.epochMilliseconds`, which rounds in FTFoundation and rounds down in FTFileSystem.

## Tests

- **The six in-memory file systems in the tests.** Moving them onto real temporary folders is about 1,900 lines of test changes, with medium confidence. The file-system protocols' members are all required, so every test double implements them all.
- **Test folder and suite names that no longer match their contents, and duplicate tests of the same behavior.**
- **About 30 "nothing happened after a fixed sleep" checks; the goldens that depend on the machine** (`kind-strings.json`, `folder-size-trees.json`, `search-sort.json`); **tests that depend on installed apps, the system appearance or the keyboard layout.** A larger piece of work with little payoff per test.
- **The size of the screenshots in `docs/screenshots`** (about 8 MB).
