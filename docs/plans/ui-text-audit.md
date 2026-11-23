# UI text audit (2026-11-23)

Every message, title, label, menu item, tooltip, placeholder, alert, toast, empty state, accessibility label and Help line, read against the code that shows it. Wordings a decision in `docs/decisions/` fixes are left alone unless they confuse; where a row touches one, it says so. Nothing here is changed yet.

Marked ✔ were checked again by hand against the code.

**Done (2026-11-23):** the five wrong texts (the case-only paste clash, the Folder View commands' menu paths, the column header menu's notes, the Permissions row, "copied" for a paste that moves); the four hard to read (Tab View Options' active pane, Batch Rename's Don't Rename and footer, the viewer's conflict bar, the archive's download-mark refusal); every Settings → Shortcuts note; one name each for ⌘I (Get Info), Edit in Text Editor, disk, results, Trash and the folder tree; and the patterns (curly apostrophes and quotes, "operation", Stop rather than cancelled, "can't"). **Left:** raw system error text (rows 1–5 of the first table) and the rest of the rows below.

## The worst, across the app

| # | Where | Now | Proposed | Why |
|---|---|---|---|---|
| 1 | Folder tree row, folder error card — `FTFileSystem/Listing/ListingTypes.swift:214` (via `SidebarCells.swift:295`, `ContentModel.swift:73`) ✔ | "EPERM: operation not permitted, scandir '/Users/me/Desktop'" | EACCES: "You don't have permission to open “{name}”." EPERM: "File Trail isn't allowed to open “{name}”. Allow it in System Settings ▸ Privacy & Security ▸ Files and Folders." ENOENT: "“{name}” is no longer there." Else: "“{name}” couldn't be read." + the system's sentence | Node-style errno text, in red, is the first thing a fresh install shows on Desktop and Documents. |
| 2 | Any copy/move/rename failure with an unmapped errno — `FTOperations/Copy/CopyPasteErrors.swift:52`, `Native/NativeError.swift:29` | "EDEADLK: Resource deadlock avoided, copyfile '/Users/…/a.pdf' -> '/Volumes/…'" | The system's sentence alone, plus own messages for the likely ones (server gone, name the disk refuses, stopped) | 60+ errnos reach result rows, notices and the Rename sheet raw, with full paths. |
| 3 | "…stopped unexpectedly" — `WriteCoordinatorLocal.swift:81`, `WriteCoordinatorUndo.swift:246`, `BatchRenameOperation.swift:119` | "The operation stopped unexpectedly: {errorMessage}" | "{Move to Trash} stopped before it finished. {describeCopyPasteError}" | Uses the raw message even for errnos that have a sentence. |
| 4 | Folder size failure — `FTFileSystem/FolderSize/NativeFolderSize.swift:53`, `FolderSizeCellView.swift:126,191` | "Couldn't Calculate", reason only in a tooltip: "ENOENT: No such file or directory, folder size '/x'" | "Couldn't calculate" with the reason in words on the line: "The folder is no longer there." / "You don't have permission to read this folder." | Hidden reason, errno jargon, title case on a status. |
| 5 | Search failure — `FdSearchRuntime.swift:408,419`, `FdProcess.swift:76,80,119`, `FdBinary.swift:68` | "fd exited with code 1", "spawn {file} failed: pipe", "Bundled fd binary not found for arm64." | "The search stopped unexpectedly. Try again." / "File Trail's search tool is missing or can't start. Reinstall File Trail." | Internal tool name, signals, errnos. |
| 6 | Paste with two names differing only in case — `ClipboardTexts.swift:112` (issue from `CopyPasteAnalysis.swift:311`) ✔ | "Two of the items are named “photo.jpg”, so one would replace the other." | "“Photo.jpg” and “photo.jpg” would be pasted as one item, as “{destination}” doesn't tell upper and lower case apart." | **Wrong**: the user sees two different names. The case clash shares the duplicate-name code and loses its reason. |
| 7 | Six Folder View commands' place — `ShortcutCommandTable.swift:609-625` ✔ | "View > Folder View > Remember View for This Folder" (and Update, Revert, Options, Reset, Manage) | "Layout > Remember View for This Folder" … | **Wrong**: they're in the Layout menu. The palette's place column and Help print the wrong path. |
| 8 | List header menu note — `MainWindowController+FolderView.swift:227` ✔ | "Changes go to “{folder}” view, until Save" | "Changes are for this folder. Update Folder View gives it a view of its own." | **Wrong**: saving makes this folder's own view; the folder above is left alone. Also no "’s". Its sibling at :226 says "until Save", a button not in the menu. |
| 9 | Help, Folder views — `HelpTopics.swift:640` | "…Save gives that folder a view of its own; the folder above is changed in it." | "…Save gives this folder a view of its own; to change the view of the folder above, go to that folder." | Reads as the opposite of what happens. |
| 10 | Info panel Permissions — `SizeText.swift:95-106` ✔ | "Read & Write" for /etc/hosts (root, 644) | Label it the owner's ("Owner: Read & Write"), or show the current user's access as Finder does | The row says what the owner can do without saying so; a user who can't write the file reads "Read & Write". |
| 11 | Paste conflict found while running — `RuntimeConflictText.swift:148-168` | "Another app created it after you reviewed this…" | "It was made after the {paste} began. Choose what to do with yours." | A paste with no conflicts shows no review, so "after you reviewed this" is false. |
| 12 | Result sheet of a paste that moves — `CopyPasteResultText.swift:96,117,177,192` | "2 items couldn't be copied." / "Couldn't copy" | "pasted" / "Couldn't paste" whenever the paste moves anything | Cut-and-pasted items are called copied. |
| 13 | Viewer, file gone — `ViewerHeaderView.swift:523` | "It was deleted, or moved where it can’t be followed." | "It may have been deleted, or moved to another disk." | views.md says never "was deleted", which the app can't know; "can't be followed" is internal. |
| 14 | Viewer conflict bar — `ViewerHeaderView.swift:394-397` | "Another app changed this file. Your edits haven’t been saved." · "Use the File on Disk" / "Keep Mine" | "Another app changed this file while you were editing it." · "Use Their Version" / "Keep My Edits" | "Keep Mine" doesn't say the next Save writes over the other app's change. |
| 15 | Viewer, edited file trashed — `TextViewerController.swift:1231` | "“{name}” was moved to the Trash. Your changes haven’t been saved." (no buttons) | "…Your changes are still here: Save puts the file back where it was." | Reads as if the edits are lost; no way forward. |
| 16 | Batch Rename, "If a name is taken" — `BatchRenameSheetText.swift:47-49` | "Add a Number" / "Skip Those Items" / "Don’t Rename" | "Add a Number" / "Skip Those Items" / "Rename None" | The last two read the same; Don't Rename blocks the whole rename. |
| 17 | Batch Rename footer — `BatchRenameSheetText.swift:243-245` | "12 will be renamed · 2 left as they are · 1 unchanged" | "12 will be renamed · 2 skipped · 1 already has that name" | Two different states a user can't tell apart. Five names for "skipped" in one sheet. |
| 18 | Archive extract refusal — `NativeArchive.swift:28` | "…wasn’t extracted: what is in it couldn’t be marked as downloaded, as the archive is, so macOS wouldn’t check it before it runs." | "…wasn’t extracted. Its items couldn’t be marked as downloaded from the internet, so macOS couldn’t check them before they open. Try extracting it to another disk." | Hard to follow; no next step. |
| 19 | Undo questions — `UndoQuestion.swift:82-83` | "{n} items have names that other items have taken where they would go back." | "The names of {n} items are now taken in the folders they came from." | Hard to parse at the moment a decision is asked for. |
| 20 | Tab View Options — `TabViewOptionsSheet.swift:614` (used at :505, :565, :585) | "What the pane that is active as the tab view is applied starts with." | "What the active pane starts with." (explain "whichever pane is active when you apply it" once) | Can't be read in one go. |
| 21 | Load settings question — `SavedViewSheet.swift:274-279` | "Load the settings of “{name}”?" · "Load them to change that {tab view} here, or keep what this sheet has and save it in its place." · "Keep These" / "Load Settings" | "Edit “{name}”, or Replace It?" · "Load Settings fills the sheet with what “{name}” keeps, so you can change it. Keep These leaves the sheet as it is, and Save then replaces “{name}” with it." | Three pronouns to untangle. |

## Settings → Shortcuts (the screen the report came from)

| Where | Now | Proposed | Why |
|---|---|---|---|
| `ShortcutSettingsModel.swift` refusal, letters/digits | "{keys} on its own types into the file list. Add ⌘ or ⌃." | "Typing {keys} in a list filters it, so a command needs ⌘ or ⌃ with it." | Same shape as the note reported; "on its own" is false for ⇧A, which is refused too. |
| refusal, arrows/Return/Tab | "{keys} on its own moves around the list. Add ⌘, ⌃ or ⌥." | "{keys} already moves, opens or renames in the list. Add ⌘, ⌃ or ⌥." | Wrong for ↩; "on its own" false for ⇧↓. |
| refusal, fixed command | "{keys} is {command}, which can not be changed." | "{keys} is always {command}. Choose another key." | Reads as if the command is locked; "can not". |
| refusal, ⌘. | "{keys} cancels a dialog, as Esc does." | "{keys} is kept for canceling dialogs, as Esc is. Choose another key." | Doesn't say it was refused. |
| refusal, macOS | "macOS keeps {keys} for itself." | "macOS uses {keys} itself, so File Trail never sees it. Choose another key." | No next step. |
| conflict | "{keys} is used by {other}." | "{keys} is already used by {other}. Reassign moves it here." | Says what Reassign does to the other. |
| after Restore Default | "Taken back from {commands}." | "Its default key was taken back from {commands}." | No subject. |
| intro | "Click a key and press the new one. Esc cancels, and ⌫ removes the key." | "Click a shortcut, then press the new keys. Esc cancels; ⌫ removes the shortcut." | "Key" means both the field and the keystroke. |
| Standard group note | "The same in every Mac app, or shared with text fields. They can not be changed here." | "These are the same in every Mac app or used by text fields, so they can't be changed." | Fragment; "can not". |
| Make Bigger hint | "The icons in the Icons view, the columns in the Compact List, the previews in Previews; a PDF or a document a pane shows zooms." | "Resizes the icons, the Compact List's columns or the previews, and zooms a PDF or document a pane shows." | No verb until the end. |
| Mission Control | "…It works here once that is switched off in System Settings → Keyboard → Keyboard Shortcuts." | "…To use it here, turn it off in System Settings → Keyboard → Keyboard Shortcuts → Mission Control." | Exact pane; no loose "It". |
| group heading | "Standard shortcuts" | "Standard Shortcuts" | Sentence case beside title-case siblings. |

## Menus, palette, Help

| Where | Now | Proposed | Why |
|---|---|---|---|
| `ApplicationMenuState.swift:401-402` | "Bigger Text" / "Smaller Text" | "Make Text Bigger" / "Make Text Smaller" | Every other size item starts with "Make". |
| `CommandPalette.swift:261` | "Give this tab what the tab view keeps" | "Apply this tab view to this tab" | Stilted. |
| `HelpTopics.swift:835,838` (also the palette's description) | "Show the next file of the folder, in a file shown in place" | "In the viewer, show the next file in the folder" | Garbled. |
| `HelpTopics.swift:228`, `:197` | "Open in Viewer, Space or {viewFile}…" / "Space types a space while there is a filter… Space opens the viewer again." | Use `{viewFile}` only; drop the hard-coded Space | Wrong once Space is moved to Quick Look. |
| `HelpTopics.swift:91` | "…the one with the blue selection." | "…the one whose selection is in the accent color." | Often not blue. |
| `HelpTopics.swift:135` (+ :140, :640) | One ~230-word paragraph for Tab views | Split into short rows | Unreadable as one block. |
| `HelpTopics.swift:687` | Background-task ring buried in Folder sizes | Its own row, "Background tasks" | About every background task. |
| `HelpContent.swift:126`, `HelpTopics.swift:816,913` (pattern, ~8) | "(Cmd+Left also works)" | "(⌘← also works)" | Keycap beside it uses symbols. Goldens in `help-content.json` move with it. |
| HelpTopics (pattern) | Menu paths with ">", "›", "▸", "→" | ">" for menus, "→" for Settings | Four separators for one thing. |
| `HelpTopics.swift:733,763,756,1008,974,953` | "Go to a page of the PDF, or a slide, a pane shows, by its number"; "Save this window's tabs, by their tab views, by name"; … | Plain rewrites (see the list in the review) | Nested or stilted. |
| `HelpTopics.swift:1025` | Quit, Hide, Minimize, Settings, Help under "Views and panels" | Group "The app and its windows" | No one looks for Quit under Views. |
| `HelpTopics.swift:215` | "choose Edit in the File menu" | "choose {editSelection} (File > Edit in Text Editor)" | No item is called "Edit". |
| `HelpTopics.swift:180` | "ticked", "neighbouring" | "checked", "neighboring" | US spelling elsewhere. |

## Settings pages, context menus, About

| Where | Now | Proposed | Why |
|---|---|---|---|
| `SettingsPages.swift:142` | "Reopen the last folder and tabs" | "Reopen windows and tabs from last time" | It reopens every window. |
| `SettingsPages.swift:145-146` | "Show notifications" | "Show status messages" | On a Mac, notifications mean Notification Center. |
| `SettingsValues.swift:69` | "Couldn't load the settings." | "Couldn't read the settings, so none can be shown. Close Settings and try again." | Blank page, no next step. |
| `SettingsValues.swift:25` | "⌘O and ⌘↓ always open." | "Either way, ⌘O and ⌘↓ open the selection." | "Always" is unclear under the pop-up. |
| `SettingsPages.swift:374` | "More at once opens nothing, and a notice says why." | "Opening more at once does nothing, and a message says why." | Word order. |
| `ActionNotices.swift:19` | "…You can change this in Settings." | "…Select fewer, or raise the limit in Settings → Files." | Where, and the first fix. |
| `ContextMenuCoordinator.swift:657` | "File Trail couldn't put them on the clipboard." | "…{it/them}… Try again." | "Them" for one path. |
| `ActionNotices.swift:29` | "This change will apply to every "{kind}" file…" | "Every “{kind}” will then open in {app}…" | "PDF document file"; straight quotes. |
| `AboutWindowController.swift:106` | "Acknowledgements" | "Acknowledgments" | Apple's spelling. |
| `AboutInfo.swift:51` | "Search: fd {version}" | "Search tool: fd {version}" | "fd" means nothing alone. |

## Main window, lists, folder and tab views

| Where | Now | Proposed | Why |
|---|---|---|---|
| `ContentStateText.swift:28` | "Nothing in this folder has that in its name." | "No name in this folder matches it." | Wrong in Fuzzy mode. |
| `ContentPaneController.swift:756` | "The filter “{query}” is no longer pinned, to show an item it hid" | "Unpinned the filter “{query}” to show an item it was hiding" | Word order. |
| `EntryGroups.swift:253` | "Zero bytes" | "Zero Bytes" | Other group titles are title case. |
| `ExplorerWindows.swift:79` | "A window can have up to 25 tabs" | ⌘T: "No new tab: a window can have up to 25 tabs". Drop: "The tab moved to a window of its own: …" | States the rule, not what happened. With notifications off, ⌘T does nothing, not even a beep. |
| `MainWindowController.swift:1338` | "“{name}” couldn’t be renamed" | "Couldn’t Rename “{name}”" | :1436 says "Couldn't Rename" for the same failure. |
| `ExplorerWindows.swift:82-83` | "The tab view’s folder is gone: the pane shows the folder above it" | "“{folder}” can’t be found, so the pane shows the folder above it" | Names nothing. |
| `MainWindowController+FolderView.swift:229` | "Changes apply to all folders in this pane" | "…except in folders with columns of their own" | Not true for those. |
| `BrowserPane+FolderView.swift:540` | "Saved: another size at the other density" | "Saved: another size for the other Sizes choice in Settings › Browsing" | "Density" is internal. |
| `BrowserPane+FolderView.swift:170,483` | "No view of its own · Folder View Options" | "This folder has no view of its own · Click for Folder View Options" | Two fragments. |
| `ViewsWindow.swift:389` | "These folders will look as the window shows any folder." | "They’ll show the pane’s view again, as other folders do." | Hard to parse. |
| `MainWindowController+FolderView.swift:169` | "Group by “{column}”" | "Group By “{column}”" | Title case beside "Move “{column}” Left". |
| `TabViewOptionsSheet.swift:573-575` | "Over this pane’s list: with Follow on, the file the right pane’s list selects; else the file selected here." | "Opens over this pane’s list. With Follow on, it shows the file selected in the right pane; otherwise, the file selected here." | Telegraphic; "else". |
| `TabViewOptionsSheet.swift:585` | "How the left pane shows search results, kept whole." | "…: kept all together or not at all." | "Kept whole". |
| `TabViewDraft.swift:201-204` | "Documents — the Left Pane Now" | "Documents (in the left pane now)" | Reads as a pane's name. |
| `SavedViewsPane.swift:440-445` | "It is used by “Work”. Their tabs will open as new tabs." | "The window view “Work” uses it. Those tabs will open as plain new tabs." | "Their". |
| `SavedViewsPane.swift:173` | "New tabs" (in What It Keeps) | "Used for new tabs" | Reads as kept. |
| `TabViewDraft.swift:288,320,324,326-328` | "Hidden files hidden"; "Left: viewer"; "Left: edit"; "by name" beside "sorted by Name" | "Hidden files not shown"; "Left: opens the viewer"; "Left: viewer in Edit"; one casing | Typo-like; one-word summaries. |
| `WindowViewOptionsSheet.swift:67` | "None: a New Tab" | "None (a plain new tab)" | Colon reads as a label. |
| `SavedViewNames.swift:42` | "There’s already a tab view called “{name}”." | + "Choose another name." | No next step. |
| `SavedViewsPane.swift:462`, `ViewsWindow.swift:388` | One row, "Remove the tab view?" under "Remove All" | "Remove “{name}”?" | Doesn't name it. |
| `WorkspaceView.swift:486,531` (VoiceOver) | "Resize folders pane", "Resize Info Panel pane" | "Resize Folder Tree", "Resize Info Panel" | Wrong name; "Panel pane". |
| VoiceOver casing (~6), `ListFilterBarView.swift:60,385`, `SearchBarText.swift:39,42` | "Clear filter", "Stop search" | "Clear Filter", "Stop Search" | Same control, two casings. |

## Sidebar, path bar, Info, search, names

| Where | Now | Proposed | Why |
|---|---|---|---|
| `ListingTypes.swift:212,222` | "Path is not a directory: {path}"; "Unknown system error -5: Unknown system error -5" | "“{name}” isn't a folder."; "This folder couldn't be read (error 5)." | Jargon; says nothing twice. |
| `WindowFolderSizes.swift:395`, `FolderSizeJobs.swift:691` | "Unknown error", "Unknown folder size job." | "The size couldn't be calculated. Try again." | "Job". |
| `InfoPreview.swift:127`, `PathBarModel.swift:84-87` | ".Trash" (and "501" in a disk's .Trashes) | "Trash" | Tab, path bar and sidebar say Trash. |
| `InfoPanelModel.swift:338` | "Modified Just now", "Modified Today, 9:12 AM" | lower case after "Modified" | Mid-phrase capital. |
| `InfoActions.swift:155-156` | "Couldn't Change the App" · "PDF document files still open in the app they opened in before." | "Couldn't Change the Default App" · "“PDF document” files still open in the same app as before." | Vague; doubled noun. |
| Info missing values (7 places) | "—", "--", "Not available", "Unavailable", "Not yet available" | "—" for not known yet, "Unknown" for can't be known | Five ways to say none. |
| `SearchBarText.swift:154` | "Nothing found has that in its name or folder. Press Esc to see all the results." | "No result's name or folder matches the filter. Press Esc to clear it." | Stilted. |
| `SearchBarText.swift:47,145` | "Showing the first 50,000 matches." / "No matches" | "results" | Everywhere else says results. |
| `SearchBarText.swift:151` | "…press Return to see what is wrong with it." | "…what's wrong with the pattern." | "It". |
| `TabText.swift:46` vs `PathBarModel.swift:103` | Tab "Favorites", path bar "No folder selected" | "No Folder" / "No folder" | Tab names something not shown. |
| `ToolbarMenus.swift:313,328` | "Group by None" | The field alone ("None") | Reads oddly. |
| `SidebarCells.swift:590-591` (VoiceOver) | "Shown in the left and right pane" | "Shown in both panes" | Grammar. |
| `PathFolderMenu.swift:92,101` | "{n} more folders above" | "{n} more folders not listed" | Suggests scrolling. |
| VoiceOver vs tooltip (7) | "Recalculate folder size" / "Calculate Size Again"; "Find files in current folder" / "Search" | The tooltip's words | Two names; one inaccurate (search covers Home or the disk, and folders). |
| `UndoQuestion.swift:154,160,164` | "Something else was put in “x” since."; "“x” was changed after this was done." | "Other items were put in “x” after it was made."; "“x” has been changed since." | Dangling "since", "this". |
| `ItemNames.swift:27` | "\"{name}\" is not a valid name." | "“{name}” can't be used as a name." | Straight quotes; "is not". |

## File operations

| Where | Now | Proposed | Why |
|---|---|---|---|
| `CopyPasteErrors.swift:11-12` | "You don't have permission to access this item." | "You don't have permission to read it, or to write where it goes." | Blames the item when the destination refuses. |
| `CopyPasteErrors.swift:24-26` | "This volume doesn't support this operation." / "…doesn't accept this name or operation." | "The disk can't do this." / "The disk doesn't accept this name." | Jargon; EINVAL is nearly always a name FAT/exFAT/SMB refuses. |
| `WriteGuards.swift:7` | "The Trash folder is a protected system directory and cannot be modified." | "The Trash itself can't be moved, renamed or deleted." | Jargon, register. |
| `Paths.swift:106-108` | "“{name}” can't be moved." | "“{name}” is a folder macOS needs, so it can't be moved." | No why. |
| `CreateFolderOperation.swift:51`, `TabDragDrop.swift:676` | "Folder destination must be an existing directory." / "Destination must be an existing folder." | "The folder “{name}” is no longer there." | No name; jargon. |
| `FileWriteJournal.swift:124-125` | "File Trail couldn't save its recovery information." | "File Trail couldn't write the record that protects your files while they move. Try again." | "Recovery information". |
| `WriteRecovery.swift:227,243,250`, `StagedPlacement.swift:264` | "…is still under the hidden name “.filetrail-…” in “{folder}”…" | + "View ▸ Hidden Files shows it." | How to see it. |
| `ReplacedItem.swift:60` | "“{name}” couldn't be looked through…" | "“{name}” couldn't be read to check what is in it, so nothing was deleted or replaced." | Odd phrasing. |
| `RuntimeConflictText.swift:173-174` | "Couldn't move “{name}” to the Trash" · "…is on a volume without a Trash, so replacing…" | "Replacing “{name}” would delete it permanently" · "…on a disk without a Trash…" | The user asked for Replace. |
| `CopyPasteResultText.swift:107,249-253` | "Pasted 0 of 3 items into “x”"; "Paste failed", "Copy failed" | "Couldn't Paste 3 Items into “x”"; "Couldn't Paste", "Couldn't Copy" | Self-contradicting; two names. |
| `ReviewSheetText.swift:58` | "This is a large operation (N items in total)." | "That's N items in all, counting what is in the folders." | "Operation". |
| `CopyPasteResultText.swift:139,204` | "…weren't started because the operation was stopped." | "…because the {paste} was stopped." | Name the action. |
| `CopyPasteResultText.swift:226` | "Retry {N} Items" | "Try {N} Items Again" | Rename says Try Again. |
| `ReviewSheetText.swift:104` | "Replace (It is a disk mounted here.)" | "Replace (it's a disk mounted here)" | Capital and full stop inside a menu item. The row form stays (decision). |
| `ReviewSheet.swift:383` (VoiceOver) | "Moved" / "Copied" | "Will be moved" / "Will be copied" | Past tense before it happens. |
| `WriteEndNotices.swift:189-193` | "Move cancelled" | "Move stopped", message "Moved 2 of 5 items" | The button is Stop. |
| `ExecutionContext.swift:8` + 8 sites, `ArchiveOperations.swift:91,193` | "Operation cancelled." | "Stopped before anything was changed." | Jargon; cancel vs Stop. |
| `WriteResultNoticeText.swift:48` | "Stopped before every item was done." | "Stopped before all the items were done." | Ambiguous. |
| `UndoHistoryRows.swift:366` | "Its disk has no Trash" | "The disk it went to has no Trash" | A copy has two disks. |
| `ActivityList.swift:139` | "Moving…" beside "Done" | "Move" once ended | Contradicts itself. |
| `UndoHistory.swift:302` | "Undo Move to Trash of “a.txt”" | "Undo Move of “a.txt”" (Finder's) | Word order. |
| `ToastViews.swift:168` (VoiceOver) | Title and message joined by a space | Join with ". " | No pause. |
| `ClipboardTexts.swift:289` | "“a.txt” goes with the folder added" | "“a.txt” came off: its folder is on the clipboard now" | Hard to parse. |
| `ClipboardTexts.swift:241` | "Put Back the Item Before" | "Put Back the Previous Item" | Before what? |
| `ClipboardTexts.swift:333` | "“a”, “b” and “c”. Keep Both pastes…" | "They are “a”, “b” and “c”. …" | Opens on a fragment. |
| `WindowWriteActions.swift:329,389,494,520,545` | "The folder couldn't be made", "The file couldn't be saved" | "Couldn't Make a New Folder", "Couldn't Paste as File" (as `WriteDialogs.swift` has them) | One failure, two titles. |
| `LocalWriteRules.swift:75` | AppleScript's "Finder got an error: … (-10000)" | "Finder couldn't empty the Trash. Try again, or empty it in Finder." | Raw error number. |
| `EjectPlanning.swift:116` | "An unexpected error occurred (EIO)." | "macOS couldn't eject it: {strerror}." | Errno name. |
| `SystemActions.swift:62` | "Unable to find application named 'Xcode'" | "“Xcode” can't be found. It may have been moved or deleted." | Voice, quotes. |
| `ApplicationPaths.swift:16` | "Invalid application path: {path}. Expected an absolute path to a .app bundle." | "“{name}” isn't an app." | Developer text. |

## Viewer, Batch Rename, Convert Images, dialogs, archives

| Where | Now | Proposed | Why |
|---|---|---|---|
| `TextViewerController.swift:885` | "Save puts it back where it was, with your changes." | "Save makes a new file where it was, with your changes. The one in the Trash stays there." | "Puts it back" sounds like Put Back. Wording from views.md. |
| `ViewerHeaderView.swift:226-232` | Bigger Text, Wrap Lines, Line Numbers, Save in the ⋯ menu of a PDF or picture | Show only for text | Do nothing there. |
| `ViewerHeaderView.swift:97-98,110` | Tooltips "Next File (⌥⌘])", "Save (⌘S)" fixed | The key from the bindings | Wrong once Settings changes the key; VoiceOver reads the symbols. |
| `ViewerHeaderView.swift:129,131` | Tooltip "Save, other files, find, zoom, language and the viewer’s look"; label "Viewer" | "Viewer Options" | Run-on list. |
| `ViewerHeaderView.swift:234,474` | "Open in Text Editor" | "Edit in Text Editor" | Menu, toolbar and Settings say Edit. |
| `ViewerFile.swift:108` | "The file can’t be read. {error}" | The system's reason alone | Says it twice. |
| `ViewerHeaderView.swift:501-523` | "No File Selected", "“x” is too large to view here", "“x” was moved to the Trash." | One style for these titles | Three styles in one slot. |
| `MainWindowController+Viewer.swift:219-221` | "The Linked Item Can’t Be Found" · "…or be on a disk or a server that isn’t connected." | "Can’t Open the Link" · "…moved or renamed, or be on a disk that isn’t connected." | Vague; awkward. |
| `MainWindowController+Viewer.swift:578` | "Page 1 to 12" | "This PDF has 12 pages." | Fragment. |
| `ViewerHeaderView.swift:506` | "A folder. Select a file in it to see it here." | "This is a folder. Open it and select a file to see it here." | Fragment. |
| `ViewerFile.swift:146` | "Some characters can’t be written in {encoding}, the file’s encoding." | "…can’t be saved in {encoding}… Remove them to save." | No next step. |
| `ViewerHeaderView.swift:235` | "Close Viewer ⎋" in Edit | ⎋ only in Read | In Edit, Esc goes to Read. |
| `TextViewerController.swift:1384` vs `ViewerHeaderView.swift:501` | "Nothing selected" / "No File Selected" | One | Same state. |
| `BatchRenameSheetText.swift:168`, `BatchRenameInspect.swift:176,183` | "Left as it is: “a.txt” no longer exists." | "Skipped: “a.txt” is no longer there." | Capital after colon; the decided wording is "is no longer there". |
| `BatchRenameExecution.swift:210` | "…because an item in it is still under a hidden name." | "…wasn’t renamed: a rename inside it didn’t finish. Try again." | Internal. |
| `BatchRenameSheetText.swift:201-204` (VoiceOver) | "a.txt, becomes b.txt, not renamed Left as it is: the name is taken" | "a.txt, becomes b.txt. Skipped: the name is taken." | No pause, says it twice. |
| `BatchRenamePlan.swift:40` | "The name can’t be only an extension." | "The name before the extension can’t be empty." | Actionable. |
| `ConvertImagesSheet.swift:293-295` | "1 of the images is smaller than {w × h}, and images are never made larger" | "1 image is smaller than {w × h}. Choose a smaller size: images are never made larger." | Convert is gray; no next step. |
| `ConvertImagesSheet.swift:321` | "Of an animation, or a file of several pages, only the first is converted." | "Only the first frame of an animation, or the first page of a file with several, is converted." | Backwards. |
| `ConvertImagesSheet.swift:303-304,298,275,189,197,318` | "1 of them can’t be opened as an image"; "{n} images, all already fit…"; "At most 100%"; "keeps no HDR" | See the review: name the file, fix the grammar, say the number was changed and why | Unclear or broken. |
| `ArchiveOperations.swift:298-299` | "1 item was left out: its name reached outside the folder, it was already there, or it can’t be kept here." | "1 item in the archive was left out: its name pointed outside the folder, another item had the same name, or it is a kind of item a folder can’t hold." | Vague. |
| `NativeArchive.swift:22` | "…of a kind File Trail doesn’t take apart." | "…in a format File Trail can’t extract." | Internal word. |
| `MainWindowController+Dialogs.swift:289-290,316-317` | "There’s no folder “x” there yet: Create and Move makes it first."; "…is already in this folder." | "There’s no folder “x” yet. Create and Move makes it, then moves the items."; "…is already in “{destination}”." | Order; which folder. |

## Patterns

- **Straight apostrophes and quotes** in about 100 user strings (file operations ~85, plus Settings, viewer, folder views); the rest use ’ and “ ”.
- **"Operation"** as a user word: 27 strings in file operations alone.
- **Stop vs cancel vs abort**: the button is Stop and Activity says Stopped; toasts say "… cancelled", notices "Operation cancelled.", one place "aborted".
- **"can not"** twice (Settings → Shortcuts); "can't" everywhere else. **"any more"** vs **"anymore"**.
- **Periods at the end of notes** mixed within one sheet (Convert Images, Batch Rename).
- **Menu-path separators**: ">", "›", "▸", "→".

## One thing, several names

- **⌘I**: "Show Info" (right-click menus, Help) vs "Info Panel" (View menu, toolbar, Settings).
- **Edit in Text Editor**: "Edit in {app}" (menus), "Edit in Text Editor" (Settings, palette), "Edit" (toolbar), "Open in Text Editor" (viewer), "Edit in the File menu" (Help).
- **Disk vs volume**: "disk" nearly everywhere; "volume" in copy errors and the no-Trash Replace.
- **Deleting with no Trash**: "deleted immediately", "Delete Permanently", "deleted for good", "permanently erase".
- **Make vs create**: "Couldn't Make a New Folder" vs "Creating Folder…" and "Create Folder".
- **Failure titles**: "Couldn't Paste" vs "Paste failed" vs "The file couldn't be saved".
- **Is no longer there vs no longer exists** (the viewer's is decided).
- **Results vs matches** in search.
- **Folder tree**: "Folder Tree", "Folders" (sidebar heading), "folders pane" (VoiceOver), "sidebar" (Help).
- **Trash vs .Trash**.
- **A pane with no folder**: tab "Favorites", path bar "No folder selected".
- **The Views window**: "Manage Folder Views…" (Layout menu) vs "All Folder Views…" (popover; views.md names this one).
- **Previews at a time**: "Previews at a Time", "Previews", "Preview Size" (bigger means fewer).
- **Sort/Group**: "Sort By:", "Sort", "Sort by".
- **Folders First values**: "Before Files" / "Mixed with Files" vs "folders first" / "folders mixed in".
- **Skipped items in Batch Rename**: "Skip Those Items", "Left as it is", "left as they are", "not renamed", and "unchanged" for another state.
- **Measuring a size again / stopping**: "Calculate Size Again", "Recalculate folder size", "Stop Calculating", "Cancel folder size calculation".
- **Missing values in Info**: "—", "--", "Not available", "Unavailable", "Not yet available".
- **Key hints**: palette "↑↓ to choose ↩ to run esc to close" vs Go To "⇥ Completes".
- **Shortcut groups**: Help's four groups vs Settings' seven, with commands in different ones.
- **px vs pixels** in Convert Images.
- **Move to… vs Move To vs Extract To…** (names-and-search.md writes "Move To", "Extract To").
- **Put Back**: Help says "File Trail has no Put Back" (Trash); the clipboard has a Put Back button.
- **Status messages**: Settings calls them "notifications"; Settings → Files calls an alert "a notice".

Left alone on purpose (decided and clear): "Can't Be Undone", "Finishing…", "was moved to the Trash" / "is no longer there", the several-disks rename refusal, "Can't replace: It is a disk mounted here." on its row, Match / Match As / Skip .git Folders, "Search View", "Forget the Second Pane", Don't Save / Cancel / Save.
