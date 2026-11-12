# Decisions

The owner's decisions about how File Trail behaves and how its code is kept, each with its reason. A change that goes against one of them needs the owner's yes first. Open issues are in [known-issues.md](known-issues.md), background work in [battery.md](battery.md).

## Decisions

- **The minimum macOS is 26.** There are no fallbacks for macOS 14 or 15, and the Liquid Glass look is the only one built.
- **Matching the earlier app pixel for pixel is not a goal.** Prefer the system's controls, symbols and look. Code, tests and goldens that existed only to match the earlier app's stylesheet or layout are gone.
- **The system's look.** Tabs and toolbars use Liquid Glass. Commands use SF Symbols, Finder's where Finder has the command. Sheets, the Info panel and Settings use the system's checkboxes, pop-up buttons, switches, number fields and tables.
- **Font sizes and row heights are the app's own, not Finder's**: sidebar 14 pt, icon labels 13, list 14, path bar 12. From Finder the app takes the Favorites and Locations icons as system symbols, the Locations icon color, the unfocused selected fill and the toolbar's sizes. Favorites icons use the app's accent, not the system's, and the search field keeps its own 200 pt width rather than Finder's.
- **Dark mode uses Finder's colors.** The content's background is the system's content material, so it takes the desktop's tint as Finder's does. The path bar is 3.3% white lighter and the sidebar's gray selection is 13.5% white, both measured from Finder. Light mode is unchanged.
- **Glass goes on brief surfaces only.** Toasts, the progress card and plain alerts (a title, a message and buttons) are glass, and keep their edge and shadow so they read over a white pane. Go To and Move To, the paste review, the Rename sheet, the path bar's suggestion list, and alerts with a list or a field stay opaque. The system's own sheet is opaque and its alert is glass, and glass behind lists and fields lets colorful content smear behind the text.
- **The Info panel is a plain split item**, not the system's inspector item. The toolbar lays its material over plain items only; as an inspector the panel's own color showed through the toolbar in dark mode.
- **File Copy, Cut and Paste use the app's own clipboard**, the one the toolbar's clipboard button lists, not the system's. What this means for people is in known-issues.md. Copy Path puts text on the system's clipboard.
- **Batch rename keeps JavaScript regular-expression rules, for now.** `JSRegExp.swift` stays as it is. Moving to `NSRegularExpression` would remove about 530 lines, but it would change what `\d`, `\w`, `\s` and `\b` match (ASCII only today, Unicode in ICU), how `ß` and ligatures fold, which syntax is accepted, and the wording of pattern errors. `expandReplacement` (`$1`, `$&`, `$<name>`) stays either way. Revisit later.
- **The search-result highlight uses `NSRegularExpression`.** The rule above covers batch rename only, where the pattern decides what is renamed. The search itself is done by `fd` with Rust's regex, so JavaScript's rules were never what people got there.
- **VoiceOver is not a supported target.** Don't add accessibility work; the VoiceOver-only code is gone. Accessibility identifiers and `accessibilityPerformPress()` stay, as the tests press things through them.
- **There is no import or upgrade path from the earlier app.** The earliest release of this app is v0.8.0, and its bundle id is `com.filetrail.native`. Nothing reads files only the earlier app wrote.
- **A window holds at most 25 tabs.**

## Answers

### How the app behaves

- **Names sort one way everywhere, in the user's language, with numbers in order.** One order (ICU's collator for the user's locale, numeric, ignoring case and accents) serves the folder listing, the tree, path suggestions, search results, Open With and volumes, so `file2` comes before `file10` in search results as in a folder, and a Swedish or Turkish user gets their alphabet's order, as in Finder. For an English user only search results changed. Kind labels and extensions compare as words, digit by digit. The locale is read once at launch. Without the system's collator, names compare as text through Foundation; no table of our own is kept for that case, as it would happen only if macOS dropped `libicucore` for everyone at once.
- **The startup disk is shown by its real name**, as other disks already were, so a renamed startup disk is no longer called "Macintosh HD". The name is read at launch and on every rename, off the main thread, and open windows follow; the Go menu's item follows it too. Help and the startup disk's row in Settings' Shortcuts keep "Macintosh HD": they name a command, as Go ▸ Home does, and the Shortcuts label also feeds Help's golden.
- **Listings and naming use one list of 37 package extensions.** `.rtfd`, `.xcworkspace`, `.photoslibrary`, `.pkg`, `.sparsebundle`, `.key` and the rest show as one item, not a folder, and carry the system's kind ("Keynote Presentation"). Before, listings knew 10 and called the others folders.
- **Accented letters match however a name is stored.** The list filter, the search results' filter, the sidebar's type-to-select and Go To fold both sides (lowercase, composed) before comparing, so "é" typed finds "Café" whether the disk keeps it composed or decomposed. Plain "e" doesn't find "é". A stored name is never changed, and Go To's marks fall on the name as stored. Everywhere else paths compare byte for byte (see "Must stay").
- **List view's columns keep the widths they were given.** A pane narrower than the columns (a narrow window, the Info panel open) scrolls sideways; no column shrinks or hides to fit, and Name is never squeezed. A column dragged past the pane's edge scrolls the list so its divider stays in view. Widths change only when someone drags, steps or double-clicks a divider, so what is set is what shows.
- **The Icons view's icon size and the Compact List's column width are set with one slider in the status bar**, and with View ▸ Make Bigger, Make Smaller and Default Size (⌘+, ⌘- and ⌘0, changeable in Settings; ⌘= is ⌘+'s other key, as most keyboards type + with Shift): icons from 32 to 128 pt in steps of 8, columns from 160 to 600 pt, the commands going to the next whole 40, each kept for each density in every window. The List has none. The items are named for the view ("Make Icons Bigger", "Make Columns Wider") and are dimmed in the List and at the ends of the range. While the slider moves, or after one of the commands, the size shows in points in place of the status text, and fades once it stops. Dragging the gaps between columns was tried and dropped: nothing on screen shows the gaps can be dragged. Icons larger than 64 pt ask Quick Look for 256-pixel previews instead of 128.
- **A click on a sidebar row opens its folder at once.** Nothing waits to see whether a second click follows; the second click of a double-click only opens or closes the folder's branch in the tree. With single-click expand on, the first click already does both, and the second does nothing more. A click on a path bar segment still waits 250 ms, as a double-click there edits the path.
- **File ▸ Remove from Favorites is offered for a Trash favorite**, as the context menu is.
- **A full disk ends a paste.** The first "no space" error stops the run, the rest is "Not started", and a partly copied folder is not put in place. There is no free-space check before a paste starts, for now: that is a feature of its own.
- **A file moved to another disk goes even if the disk refused an extended attribute.** A refused attribute is skipped on purpose (most files carry `com.apple.provenance`, and FAT and exFAT refuse many); only a resource fork that can't be written fails the copy.
- **The journal entry that guards a moved item's only copy is flushed to disk.** Other journal entries aren't, for speed; this one is written once per Replace.
- **A folder moved to another disk keeps its journal entry until the originals are gone.** After a crash in between, recovery says what was left of the original and where.
- **Progress counts are taken back when a Replace is undone or asked again**, so the count done never passes the total.
- **A conflict question takes one answer.** If the answer can't be sent, the question stays, its buttons disabled, and Escape still dismisses it.
- **A Replace row in the paste review says what goes to the Trash**, as its footer does, not "Deletes".
- **A tab dropped into a window that already has 25 goes back out** into a window of its own, with the tab-limit notice. The session save still cuts at 25, as the limit doesn't hold everywhere: a folder opened with the app at launch is added as a tab to a restored window even when it has 25, and that stays as it is.
- **Back doesn't follow a folder renamed since it was visited, and Quick Look does nothing of its own when the window's folder changes.** Neither was wanted, and the unwired code for them went.
- **`constructor` and `__proto__` are unknown modifier names** in a shortcut, like any other unknown name.
- **With hidden files shown, Quick Look's button and the hidden-files button both show an eye.** Kept as is.
- **Settings keeps its own row and card layout.** Its controls are the system's, but the page layout is not a control, and a dozen layout tests pin its frames, so `SettingsMetrics` keeps its layout constants.
- **Back and Forward when a read fails or is overtaken: left open.** Back and Forward move the history's index before the folder is read, and nothing puts it back. Back to a slow folder and then opening another drops the folder you came from; Back to a deleted folder leaves the old folder on screen with the index moved. Restoring the index when a navigation is overtaken breaks two quick Backs (they go to B and then A on [A, B, C], and a restore would put the index back on C). A fix that holds: remember the index of the folder on screen while a move is ahead of it; restore it when a push, a replace or a read in place starts, and when the current navigation fails with the old folder on screen; do nothing when it is overtaken, and leave the index as moved when another Back, Forward or jump starts.

### How the code is kept

- **Work lands on `main` by fast-forward or rebase**, never by a merge commit, and there are no pull requests. A commit message is one plain sentence saying what is now true of the app, with no `Co-Authored-By` trailer.
- **`scripts/release.sh` runs the tests that drive real windows.** A release is run at the keyboard, and these are the only tests of real windows.
- **`scripts/ci.sh --affected` compares with the previous commit, not with `main`:** the last commit's files, uncommitted changes and new files. On a long branch every module differs from `main`, so it ran everything every time. With no commit before HEAD, or nothing changed, everything runs. The format lint follows the same files.
- **Hand checks are made by whoever does the work**, in the built app, driven by a scratch scenario. The owner checks by hand only when asked, and no longer asks for before and after pictures of a control change.
- **Goldens are expected results kept by hand.** Edit them by hand, never regenerate one from the code's own output, and ask the owner before changing or deleting one a task doesn't name. A golden file holds its cases only; the metadata fields nothing read are gone.
- **The stop and crash recordings run through the write engine**, not only against themselves. All of them can; a recording that ever can't is deleted with the tests that only describe it. The shape tests of the recordings stay, each saying what it guards.
- **Tests that need a file that can't be written fail it with EIO**, not with a full disk, as a full disk now ends the paste.
- **The Undo types keep their hand-written `Codable`.** It is the journal's guard on its format.
- **The write engine's callbacks for Undo, caches and progress don't throw**, as nothing in the app throws from them.
- **The app installs its services once at launch, and the tests install theirs.** `ExplorerServices.current` has no fallbacks; the tests got faster without them.
- **Names with the earlier app's vocabulary were renamed only where plainly left over**: `RendererCommand` is `AppCommand`, `InfoLocale.original` is `InfoLocale.appLanguage`, `CSSTextMetrics.swift` is `TextLineMetrics.swift`, and the copy of `JSString.equals` went. `JSString`, `JSText`, `JSRegExp` and `NodePath` keep their names: they name rules the app keeps, and renaming them is large. Others (`sortedJS`, `jsTrimmed`, `isJSWhitespace`, `jsLowercased`, `jsRound`, `nodeText`, `libuvWords`, `menuAccelerator`, `javaScriptNumber`, `PageWindow` and its kin) were not part of the answer and are left. Comments describe the app on its own terms, as `CLAUDE.md` says.
- **The Finder Trash workaround stays as a diff**, with the commit it applies to named in known-issues.md. That keeps the record at no cost.
- **No benchmarks.** The owner removed them on 2026-11-12 and does not want them back: no `tools/bench`, no benchmark tests or budgets, no `--bench` launch modes or timing hooks in the app. Speed is guarded by ordinary tests that bound CPU time (`CPUTime.measureThread`) where a change needs it. The fixture tree `large` holds the two folders the folder-size golden measures.
- **Tools nobody runs are deleted.** `scripts/hands-on-setup.sh`, the `FILETRAIL_TIMING` switch and `tools/acknowledgements` went. The licences the app shows are kept by hand in `Resources/Acknowledgements`. `--snapshot` stays: it draws a window into a PNG without screen-recording permission.

## Left out on purpose

Not done, and not to be done without a plan of its own. Kept so the reasons are not lost and the findings not rediscovered.

- **Batch rename on `NSRegularExpression`.** See "Decisions".
  - The search-result highlight did move to `NSRegularExpression`; batch rename did not.
- **The file clipboard on the system pasteboard.** See "Decisions".
  - known-issues.md now says so for people.
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
- **Flushing a cross-disk move before deleting the original.** Today the original is deleted after comparing kind and size. Recommended later: one full sync of the destination volume before the originals go. Needs a decision on the cost.
  - The move's journal entry now stays until the originals are gone. Still not flushed: the record of a folder move to another disk, which a power cut could leave naming a folder that isn't the paste's.
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

## Must stay

Things that look removable and are not. Don't change them; if a change seems to need it, ask the owner first.

- The coordinator's write slot; hidden-name staging and the journal; the `isStagingName`/`isTemporaryName` checks before recovery touches anything.
- `renamex_np(RENAME_EXCL)` everywhere, with the ask-again loop; `removeEmptyFolder`'s read before `rmdir`.
- Replace's re-check after staging, the counted and lock-scanned permanent delete, and never offering delete-for-good on the startup disk or for an unexplained Trash failure (`Native/TrashItem.swift`).
- The replace-safety checks, made at review and again at run time; `assertNotWrittenByThisPaste`.
- Byte-exact path comparison (`sameText`, `NameKeys.Exact`): Swift's `==` treats NFC and NFD as equal.
- The `copyfile` status callback in `Sources/CFileTrail/copyfile.c`; the large-file tests.
- Undo and Redo as they are; `UndoFuzzTests`, `BatchRenameFuzzTests`.
- `JSRegExp.swift` and `expandReplacement` (batch rename's rules, above); `NodePath`; `CopyPasteNames.detectCaseSensitivity`.
- The `fd` binary, `FdProcess`'s `posix_spawn`, the trailing `"--"` in its arguments, `HiddenFilter`.
- FSEvents for folder watching; `ExplorerWindows.reconcile()`; `WorkspaceSplitView`/`WorkspaceSplitController`; `FileRefusingFieldEditor`; `FirstClickGate`; `SecondInstance`; `RenameDrafts`.
- `ExplorerToolbar`'s `applying`/`commitPending` flags; `ContextMenuSession` holding itself on its menu; `holdingTheTab`; `SidebarModel`'s request numbering; `WriteStartingShortcuts.runs(… isRepeat:)`.
- The `density` migration; `PreferencesSanitizer.sanitize`; `@NullEncoded`; the app-state file format.
- The `vtool` restamp in `build-app.sh`, as SwiftPM still stamps the SDK as 26.0 while the app is built with a later one; `FTTestSupport` as a regular target; the release-script tests; `AppClock` and `FILETRAIL_NOW`.
- The app's own clipboard and the rules that keep it truthful.
- Glass only on toasts, the progress card and plain alerts; sheets, Go To and alerts with lists or fields stay opaque.
- Accessibility identifiers and `accessibilityPerformPress()`; the read-only test seams.
- `adopt`/`absorb` and the `ExplorerWindowLike` generic with `FakeWindow`.
- The rule that no paste review starts while a write runs, and that only one runs at a time.
- Coalescing of preference writes to disk while a continuous control is dragged.
- `ElementFinder`, `MouseEvents`, `KeyEvents`, `AutomationPrefs`, `AutomationDraggingInfo`/`AutomationDrag`: many tests press things through them.
- The polling of a running search and the background-tab behavior (one poll a second, search again on return).
- `PlainLabel` and the search field's `SearchTextCell` drawing their own text: AppKit draws a translucent label or placeholder color twice, and their tests fail if a later macOS stops doing so.
