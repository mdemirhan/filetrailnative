# Decisions: must stay

Part of the owner's decisions: [the index](../decisions.md) lists the other parts.

Things that look removable and are not. Don't change them; if a change seems to need it, ask the owner first.

- The coordinator's write slot; hidden-name staging and the journal; the `isStagingName`/`isTemporaryName` checks before recovery touches anything.
- `renamex_np(RENAME_EXCL)` everywhere, with the ask-again loop; `removeEmptyFolder`'s read before `rmdir`.
- Replace's re-check after staging, the counted and lock-scanned permanent delete, and never offering delete-for-good on the startup disk or for an unexplained Trash failure (`Native/TrashItem.swift`).
- The replace-safety checks, made at review and again at run time; `assertNotWrittenByThisPaste`.
- Byte-exact path comparison (`sameText`, `NameKeys.Exact`): Swift's `==` treats NFC and NFD as equal.
- The `copyfile` status callback in `Sources/CFileTrail/copyfile.c`; the large-file tests.
- Undo and Redo as they are; `UndoFuzzTests`, `BatchRenameFuzzTests`.
- `JSRegExp.swift` and `expandReplacement` (batch rename's rules, in [the standing decisions](../decisions.md)); `NodePath`; `CopyPasteNames.detectCaseSensitivity`.
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
