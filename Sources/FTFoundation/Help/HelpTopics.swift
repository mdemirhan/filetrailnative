// The Help window's topics, in the order its sidebar lists them.

extension HelpContent {
    public static let topics: [HelpTopic] = [
        HelpTopic(
            id: .navigation, title: "Getting around",
            intro: "Move between folders with the folder tree, the file list, and the path bar under the list.",
            sections: [
                HelpSection(
                    title: "Folders",
                    rows: [
                        HelpRow(
                            label: "Folder tree",
                            description:
                                "Click a favorite or a folder to open it. The arrow beside a folder shows its subfolders without leaving the folder you are in, and a double-click opens the folder and shows them, or hides them if they are showing. Settings → Browsing → Expand folders with a single click does that on every click."
                        ),
                        HelpRow(
                            label: "File list",
                            description:
                                "Double-click a folder to open it. Back and Forward retrace your steps; hold either button, or right-click it, to pick from the folders it leads to."
                        ),
                        HelpRow(
                            label: "Go to Folder",
                            description:
                                "{openLocationSheet} finds a folder you have opened before, or a favorite, from a few letters of its name; the folders you use most come first. Start with `/` or `~` to type a path instead, and Tab completes it. ⌘⌫ removes the selected folder from the list, if it is one you opened."
                        ),
                        HelpRow(
                            label: "Favorites",
                            description:
                                "Right-click a folder and choose Add to Favorites to pin it in the sidebar. File > Add to Favorites does the same for the selected folder, or for the folder you are in when nothing is selected. Drag a favorite up or down to reorder it, and right-click it for Remove from Favorites. Settings → Browsing → Favorites lists them, and Show favorites puts them in the folder tree or in their own section."
                        ),
                        HelpRow(
                            label: "Disks",
                            description:
                                "Disks you connect, disk images and servers appear under Locations. Opening a disk image opens its disk in a new window, or a new tab if you choose that in Settings; one that asks for a password or a license opens as in Finder. Click ⏏ beside one, right-click it and choose Eject, or select it and press {ejectVolume}, before you disconnect it. When a program is still using the disk, File Trail asks whether to try again or force it."
                        ),
                        HelpRow(
                            label: "Tree root",
                            description:
                                "Use as Tree Root makes a folder the top of the folder tree, until you open a folder outside it. Go > Home returns the tree to your home folder."
                        ),
                    ]),
                HelpSection(
                    title: "Tabs",
                    rows: [
                        HelpRow(
                            label: "New tab",
                            description:
                                "{newTab} opens a tab on the folder you are in. The row of tabs appears with the second tab. A window holds up to \(AppPreferenceLimits.openTabsLimit) tabs."
                        ),
                        HelpRow(
                            label: "Open in New Tab",
                            description:
                                "Right-click a folder, or ⌘-double-click it. ⌘-click works on a folder in the folder tree or the path bar, and File > Open in New Tab on the selected folder."
                        ),
                        HelpRow(
                            label: "Each tab",
                            description:
                                "Keeps its own folder, history, folder tree, selection, view, sort order, hidden files, Folders First and search. A new tab starts on the same folder, with the same folder tree, view, sort order, hidden files and Folders First as the tab it was opened from; its history starts there, with nothing selected and no search. A search keeps running while its tab is in the background."
                        ),
                        HelpRow(
                            label: "Moving between tabs",
                            description:
                                "Click a tab, or use {selectNextTab} and {selectPreviousTab}. Drag a tab to move it along the row, out of the window to give it a window of its own, or onto another window's tabs to move it there."
                        ),
                        HelpRow(
                            label: "Closing",
                            description:
                                "{closeTab} closes the tab, and the window when it is the last tab. {reopenClosedTab} brings back the tab closed last. Right-click a tab for Close Other Tabs and Move Tab to New Window. Duplicate Tab is in the File menu, and Merge All Windows in the Window menu."
                        ),
                        HelpRow(
                            label: "Between tabs",
                            description:
                                "Copy or cut in one tab and paste in another; the clipboard button in the toolbar shows what is waiting to be pasted."
                        ),
                        HelpRow(
                            label: "Next launch",
                            description:
                                "File Trail reopens the tabs you had, each in its own folder. Settings → General → Reopen the last folder and tabs turns that off: it then opens one tab in your home folder."
                        ),
                    ],
                    note:
                        "Only one copy, move or delete runs at a time, whichever tab it was started from. While it runs, the other tabs can browse, search, copy and cut."
                ),
                HelpSection(
                    title: "Windows",
                    rows: [
                        HelpRow(
                            label: "New window",
                            description:
                                "{newWindow} opens a window on the folder you are in, the size of this one and a step down and to the right of it. File > Open in New Window, or Open in New Window in a folder's right-click menu, opens that folder in one."
                        ),
                        HelpRow(
                            label: "Each window",
                            description:
                                "Has its own tabs, Info panel and Info Row, column widths, and whether the folder tree shows and how wide it is. A new window opens with one tab, on the folder you were in, and takes the rest from the window it was opened from. Settings, favorites and the columns shown are the same in every window."
                        ),
                        HelpRow(
                            label: "Moving tabs",
                            description:
                                "Window > Move Tab to New Window, or the same item in a tab's right-click menu, gives the tab a window of its own; it keeps its folder and view, but not its Back and Forward history. Window > Merge All Windows brings the tabs of every other window into this one and closes the others; a window whose tabs would take this one past \(AppPreferenceLimits.openTabsLimit) stays open."
                        ),
                        HelpRow(
                            label: "Workspaces",
                            description:
                                "Window > Workspaces > Save Window as Workspace… keeps the window's tabs by name: each tab's folders and panes, the folder tree, the Info panel and the window's size. Choose the workspace in Window > Workspaces to open it as it was saved in a new window, or hold Option to open it in this one instead. The first five open with {openWorkspace1} to {openWorkspace5}, and in this window with {openWorkspace1InThisWindow} to {openWorkspace5InThisWindow}. A workspace changes only when a window is saved under its name again: the button at the end of the name field lists the saved ones. Settings → Browsing renames, removes and orders them."
                        ),
                        HelpRow(
                            label: "Between windows",
                            description:
                                "Copy or cut in one window and paste in another. Drag items from one window into another to move or copy them there: they go where a drop from Finder would. Edit > Undo undoes the last operation, whichever window it was done in."
                        ),
                        HelpRow(
                            label: "Closing",
                            description:
                                "{closeWindow} closes the window. File Trail stays open with no window, as Finder does: click its icon in the Dock, or use {newWindow} or the Go menu, and a window opens where the last one you closed was. While a copy, move, delete or rename of several items runs, closing the last window asks first, since it would stop it."
                        ),
                        HelpRow(
                            label: "Next launch",
                            description:
                                "File Trail reopens every window you had open when it quit, with its tabs, in the same place; if none was open, it opens one where the last one you closed was. With Settings → General → Reopen the last folder and tabs off, it opens one window."
                        ),
                    ],
                    note:
                        "Only one copy, move or delete runs at a time in all the windows together. Its progress shows in the window it was started from; close that window and it carries on in another."
                ),
                HelpSection(
                    title: "Path bar",
                    rows: [
                        HelpRow(
                            label: "Click a folder",
                            description: "Jumps straight to that folder."),
                        HelpRow(
                            label: "Click a ›",
                            description:
                                "Lists the folders at that level, with the one on your path ticked, so a neighbouring folder is one click away."
                        ),
                        HelpRow(
                            label: "Double-click the bar",
                            description:
                                "Edit the path as text. Suggestions come from the folder you are typing in, and Esc cancels."
                        ),
                    ]),
                HelpSection(
                    title: "Keyboard",
                    rows: [
                        HelpRow(
                            label: "Arrow keys",
                            description: "Move the selection. In the tree, left and right collapse and expand."),
                        HelpRow(
                            label: "Type in the list",
                            description:
                                "Narrows the folder to the names with the letters you type in that order, marks them and selects the best match; a plain letter also finds its accented forms. The chip in the filter's pill says Fuzzy: click it for Contains, which keeps only the names with the letters side by side; the filters you type next start in the mode you chose, as Settings → Browsing sets it. Backspace takes a character back, and Option-Backspace a word. Space types a space while you type and is Quick Look after a pause. Esc shows everything again and keeps the selection. {focusFileSearch} looks for the same text in the subfolders."
                        ),
                        HelpRow(
                            label: "Type in the folder tree",
                            description: "Jumps to the first folder that starts with what you type."),
                    ]),
            ]),
        HelpTopic(
            id: .files, title: "Working with files",
            intro:
                "Select items in the list, then use the keyboard, the File and Edit menus, or right-click for the full set of actions.",
            sections: [
                HelpSection(
                    title: "Opening",
                    rows: [
                        HelpRow(
                            label: "Double-click a file",
                            description: "Opens it, or edits it in your text editor: your choice in Settings → Files."),
                        HelpRow(
                            label: "Open With",
                            description:
                                "Right-click an item for the apps that can open it: the one it opens in, then the apps you keep first (Settings → Files), then every other app macOS offers. Hold Option for Always Open With: every file of that kind then opens in the app you choose, in Finder too. In the Info panel, the Open button names the app the file opens in, and choosing another app beside Opens with does the same as Always Open With."
                        ),
                        HelpRow(
                            label: "Quick Look",
                            description: "{quickLookSelection} previews the selected item without opening it."),
                        HelpRow(
                            label: "Open in Terminal",
                            description:
                                "Opens a Terminal window in the folder. Settings → Files chooses the terminal app."),
                    ]),
                HelpSection(
                    title: "Copying and moving",
                    rows: [
                        HelpRow(
                            label: "Copy, cut, paste",
                            description:
                                "Paste and New Folder go into the folder you are browsing, whatever is selected. To paste into another folder, or make a folder inside it, right-click that folder. Files you copy or cut here paste only in File Trail, not in Finder or other apps, and files copied in Finder don't paste here: drag them between apps instead."
                        ),
                        HelpRow(
                            label: "Image or text as a file",
                            description:
                                "{pasteAsFile} saves an image or text copied in another app, a screenshot or a few paragraphs, as a new file in the folder you are browsing, and selects its name for you to change. An image keeps the format it was copied in; one copied only as TIFF is saved as PNG. Text is saved as plain text (.txt). The Edit menu and the right-click menu of the folder's empty space say which it will be. Undo moves the file to the Trash."
                        ),
                        HelpRow(
                            label: "A file's image or text",
                            description:
                                "{copyContents} puts the image or text of the selected file on the clipboard, to paste in another app: a photo into a message, a file's text into a document. An image keeps its format, with a PNG copy for the apps that read only PNG. Text is copied as it is, and an RTF file keeps its styles. The Edit menu and the file's right-click menu say which it will be. Before copying a file that usually holds a password or a key, such as .env or id_rsa, it asks, and marks the text as private on the clipboard."
                        ),
                        HelpRow(
                            label: "From the folder tree",
                            description:
                                "With the folder tree active, Copy and Cut take the folder the tree is on, with everything in it, and never what is selected in the list."
                        ),
                        HelpRow(
                            label: "What was copied",
                            description:
                                "Copied and cut items flash, then keep a copy or cut icon after their name, and cut items are dimmed. Cut items lose the mark once they are pasted; copied ones keep it, to be pasted again, until you copy or cut something else. A button with their count appears in the toolbar: click it to list them, show one in its folder, take one off, or choose Clear Clipboard. Turn off Mark copied and cut items in Settings → General to hide the marks."
                        ),
                        HelpRow(
                            label: "Drag",
                            description:
                                "Drag items onto a folder to move them there. Dragged to another disk (a USB drive, a network share) they are copied instead, as in Finder. Hold Option to copy, or Command to move. Rest the drag on a folder to open it: its icon wiggles first, and moving the pointer stops it. Keep going into folders inside; drop anywhere in the folder that opened to put the items there, or press Esc to go back to where you started."
                        ),
                        HelpRow(
                            label: "To other apps",
                            description:
                                "Drag items out of File Trail as you would from Finder: into a Finder window or the desktop, onto an app in the Dock to open them, into an email or a message to attach them, or onto the Trash in the Dock. Finder moves or copies them by the same rules; holding Option and Command makes an alias."
                        ),
                        HelpRow(
                            label: "From other apps",
                            description:
                                "Drag files and folders in from Finder or another app: drop them anywhere in the folder on screen, or on a folder in the list, the sidebar or search results. They move or copy by the same rules as a drag inside File Trail, and Option copies; an app that only lets its items be copied gets a copy. Command doesn't work for these drags: let go of it before you drop. Mail attachments, photos from Photos, text and links can't be dropped. Undo takes a drop back like any other move or copy."
                        ),
                        HelpRow(
                            label: "Same name",
                            description:
                                "If an item already exists, you choose for each one: Skip, Keep Both or Replace, and for a folder, Merge, which puts what you paste into the folder already there. Or choose for all of them at once: Skip, Keep All, Replace, and when copying folders, Add Missing, which merges them but adds only what the folder there lacks. Replaced items go to the Trash."
                        ),
                    ]),
                HelpSection(
                    title: "Changing",
                    rows: [
                        HelpRow(
                            label: "Rename",
                            description:
                                "{renameSelection} renames the selected item. With several selected it opens the Rename sheet: replace or add text, number or date them, or change their case, with every new name shown before anything is renamed, and settings saved as presets. Settings → Files chooses whether Return renames or opens."
                        ),
                        HelpRow(
                            label: "Move to Trash",
                            description:
                                "{undo} puts what you just moved to the Trash back. File Trail has no Put Back: to bring back something older, drag it out of the Trash."
                        ),
                        HelpRow(
                            label: "The Trash",
                            description:
                                "The Empty button at the top of the Trash empties it, after asking. Right-click an item there to delete it immediately."
                        ),
                        HelpRow(
                            label: "Tags",
                            description:
                                "Tagged items show colored dots by their name, before it in Icons view and after it in the lists, and a tagged folder takes the tag’s color. Right-click items for Finder’s tag colors: a color goes on the items that don’t have it, or comes off when they all do. The tags are Finder’s own, so Finder shows them too. Undo doesn’t change tags back."
                        ),
                    ]),
                HelpSection(
                    title: "Archives",
                    rows: [
                        HelpRow(
                            label: "Compress",
                            description:
                                "File › Compress, or right-click, makes a zip of the selected items next to them, as Finder’s Compress does: “Photos.zip” for one item, “Archive.zip” for several. Extended attributes and resource forks go into the zip’s __MACOSX folder, so a Mac that opens it gets them back. Undo moves the zip to the Trash."
                        ),
                        HelpRow(
                            label: "Extract",
                            description:
                                "File › Extract, or right-click, takes the selected archives apart next to themselves: zip, tar (also .tar.gz, .tgz, .tar.bz2 and .tar.xz), 7z, RAR and xar, and single files compressed with gzip, bzip2 or xz. An archive holding one item gives that item; one holding several gives a folder named after the archive. A name already taken gets the next number, so nothing is replaced. What comes out of a downloaded archive is checked by macOS as the archive would be. Undo moves what was made to the Trash."
                        ),
                        HelpRow(
                            label: "Extract To",
                            description: "File › Extract To… takes the archives apart in a folder you choose."),
                        HelpRow(
                            label: "What isn’t extracted",
                            description:
                                "An archive protected with a password can’t be opened yet; Archive Utility can. Items whose names would reach outside the folder are left out, and File Trail says how many."
                        ),
                    ]),
                HelpSection(
                    title: "Undo and Redo",
                    rows: [
                        HelpRow(
                            label: "Undo",
                            description:
                                "{undo} takes back the last thing you did to your files. Press it again to take back the one before, and so on, back to when you opened File Trail or last did something that can’t be undone (after about a million items, the oldest are let go). Edit › Undo shows what it will take back, such as “Undo Rename”."
                        ),
                        HelpRow(
                            label: "Redo",
                            description:
                                "{redo} does again what you just took back. Once you do something new, there is nothing left to redo."
                        ),
                        HelpRow(
                            label: "What you can undo",
                            description:
                                "Renaming (one item or several at once), moving items to another folder on the same disk, Move to Trash, New Folder, Copy, Duplicate, Compress, Extract, and replacing an item when you paste."
                        ),
                        HelpRow(
                            label: "Nothing is deleted",
                            description:
                                "When Undo takes away something that was made, such as a copy or a new folder, it moves it to the Trash. So Redo, or the Trash, can always bring it back."
                        ),
                        HelpRow(
                            label: "While typing",
                            description:
                                "While you type a name or a search, {undo} and {redo} work on your typing, not on your files."
                        ),
                        HelpRow(
                            label: "What can’t be undone",
                            description:
                                "Merging folders, moving items to another disk, copying or making a folder on a disk without a Trash (such as a network share), and anything deleted for good: Delete Immediately, Empty Trash, and Move to Trash or Replace on a disk without a Trash. File Trail tells you before you merge folders or delete anything for good. Afterwards Edit › Undo shows “Can’t Undo”, and nothing done before can be undone either."
                        ),
                    ]),
                HelpSection(
                    title: "Undo and Redo: if something has changed since",
                    rows: [
                        HelpRow(
                            label: "It checks first",
                            description:
                                "Before Undo changes anything, it checks that each item is still where you left it. It never puts anything in place of another item, and never deletes anything."
                        ),
                        HelpRow(
                            label: "You edited an item",
                            description:
                                "If you changed something since, such as a copy you edited or a new folder you put files in, Undo tells you and asks before moving it to the Trash. Choose Cancel and everything stays as it is."
                        ),
                        HelpRow(
                            label: "The name is taken",
                            description:
                                "If another item now has the old name, Undo asks, then puts the item back with a number added, such as “Report 2.pdf”. Choose Cancel and everything stays as it is."
                        ),
                        HelpRow(
                            label: "An item is gone",
                            description:
                                "If an item was deleted, emptied from the Trash, renamed or moved in another app, or its folder is gone, Undo can’t take it back. It does everything else and tells you what it left and why. If you’d rather have it all as it was, {redo} brings back what Undo did."
                        ),
                        HelpRow(
                            label: "It couldn’t be done",
                            description:
                                "If Undo couldn’t move an item, for example because you don’t have permission or the Trash refused it, the item stays on the Undo list. Fix what stopped it, and pressing {undo} again tries it again."
                        ),
                        HelpRow(
                            label: "A disk was ejected",
                            description: "Items on a disk that isn’t connected are left as they are."),
                        HelpRow(
                            label: "Stopping",
                            description:
                                "A long Undo shows its progress, and you can stop it. What it has done stays done, and pressing {undo} again carries on from there."
                        ),
                        HelpRow(
                            label: "When you quit",
                            description:
                                "File Trail remembers what you did only while it’s open. After you quit and open it again, there is nothing to undo."
                        ),
                    ]),
            ]),
        HelpTopic(
            id: .search, title: "Searching",
            intro:
                "Search looks for files and folders in the folder you are browsing, as you type in the search field. Return or ↓ moves into the results and Esc shows the folder again. The magnifier in the field opens the options.",
            sections: [
                HelpSection(
                    title: "Plain Text",
                    rows: [
                        HelpRow(
                            label: "draft", code: true,
                            description: "Names containing “draft”"),
                        HelpRow(
                            label: "report (1).pdf", code: true,
                            description: "Found exactly as typed: brackets, dots and `+` have no special meaning"),
                    ],
                    note:
                        "Plain text is how a new search matches. Choose Glob or Regex under Match As in the options to search with a pattern instead."
                ),
                HelpSection(
                    title: "Glob patterns",
                    rows: [
                        HelpRow(
                            label: "*.pdf", code: true,
                            description: "Names ending in .pdf"),
                        HelpRow(
                            label: "report*", code: true,
                            description: "Names starting with “report”"),
                        HelpRow(
                            label: "*draft*", code: true,
                            description: "Names containing “draft”"),
                        HelpRow(
                            label: "photo-??.jpg", code: true,
                            description: "Each `?` is exactly one character: photo-01.jpg, not photo-123.jpg"),
                        HelpRow(
                            label: "*.{jpg,png,gif}", code: true,
                            description: "Any of several endings"),
                        HelpRow(
                            label: "[a-c]*.txt", code: true,
                            description: "Starts with a, b or c. `[!a-c]` means any other character."),
                    ],
                    note:
                        "A glob must match the whole name: `report` only finds a file called exactly “report”, so add `*` where more text may follow."
                ),
                HelpSection(
                    title: "Regex patterns",
                    rows: [
                        HelpRow(
                            label: "draft", code: true,
                            description: "Names containing “draft”"),
                        HelpRow(
                            label: "^report", code: true,
                            description: "Names starting with “report”"),
                        HelpRow(
                            label: "\\.pdf$", code: true,
                            description: "Names ending in .pdf"),
                        HelpRow(
                            label: "\\.(jpg|png)$", code: true,
                            description: "Names ending in .jpg or .png"),
                        HelpRow(
                            label: "^photo-\\d{2}\\.jpg$", code: true,
                            description: "“photo-”, two digits, “.jpg”"),
                    ], note: "A regex matches anywhere in the name unless you anchor it with `^` (start) or `$` (end)."),
                HelpSection(
                    title: "Upper and lower case, and accents",
                    rows: [
                        HelpRow(
                            label: "report", code: true,
                            description: "Plain text ignores case: finds report.pdf and Report-final.pdf"),
                        HelpRow(
                            label: "resume", code: true,
                            description: "A plain letter finds its accented forms: résumé.pdf and Resume.txt"),
                        HelpRow(
                            label: "résumé", code: true,
                            description: "A letter typed with its accent finds only that letter: résumé.pdf"),
                        HelpRow(
                            label: "Report", code: true,
                            description:
                                "In a glob or a regex, a capital letter makes the search case-sensitive: only Report-final.pdf"
                        ),
                    ]),
                HelpSection(
                    title: "Matching the full path",
                    rows: [
                        HelpRow(
                            label: "**/src/**/*.ts", code: true,
                            description: "Glob: .ts files anywhere under a folder named “src”"),
                        HelpRow(
                            label: "**/docs/*", code: true,
                            description: "Glob: items directly inside any folder named “docs”"),
                        HelpRow(
                            label: "/src/.*\\.ts$", code: true,
                            description: "Regex: the same .ts files under “src”"),
                    ],
                    note:
                        "With Match set to Full Path, the pattern is compared with the whole path from the top of the disk, including the folders above the one you search. Start a glob with `**/`. For names alone, use Match: Name."
                ),
                HelpSection(
                    title: "Options",
                    rows: [
                        HelpRow(
                            label: "Search Subfolders",
                            description: "Also look in the folders below the current one."),
                        HelpRow(
                            label: "Hidden files",
                            description:
                                "Found whenever the file list shows them. Showing or hiding them ({toggleHiddenFiles}) with results on screen searches again."
                        ),
                        HelpRow(
                            label: "Skip .git Folders",
                            description: "Keeps Git’s internal files out of the results."),
                        HelpRow(
                            label: "Skip Files Ignored by Git",
                            description:
                                "Inside a Git repository, leaves out what `.gitignore` excludes, such as build output."),
                        HelpRow(
                            label: "Defaults",
                            description:
                                "Options you change in the search field stay with that tab, and new tabs in its window start with them. Settings → Search sets what new windows start with, and changing it there also changes the tab on screen."
                        ),
                    ]),
                HelpSection(
                    title: "Results",
                    rows: [
                        HelpRow(
                            label: "Search elsewhere",
                            description:
                                "The bar above the results switches between this folder, Home, the disk it is on, and the startup disk."
                        ),
                        HelpRow(
                            label: "Filter",
                            description:
                                "The Filter field narrows what was found, by name or by the folder a result is in, without searching again. Its chip says how names match, as typing in a folder does; the folder always has to hold the text as typed. Typing in the results goes to the same filter, and Esc clears it."
                        ),
                        HelpRow(
                            label: "Keep typing",
                            description:
                                "Making plain text longer narrows the results at once. Other changes are searched for when you stop typing."
                        ),
                        HelpRow(
                            label: "Open",
                            description:
                                "Opening a folder in the results goes into it and closes the search. {showLastSearchResults} brings the results back."
                        ),
                        HelpRow(
                            label: "Limits",
                            description:
                                "Search stops at \(ContextMenuRules.groupedCount(SearchLimits.resultLimit)) results. Aliases are not searched for."
                        ),
                    ]),
            ]),
        HelpTopic(
            id: .views, title: "Views and panels",
            intro: "Choose how the list looks and what information sits beside it.",
            sections: [
                HelpSection(
                    title: "The list",
                    rows: [
                        HelpRow(
                            label: "Icons, List and Compact List",
                            description:
                                "The three buttons in the toolbar, the View menu, or {viewAsIcons}, {viewAsDetails} and {viewAsList} switch between large icons with previews of photos, PDFs and other files, a list with columns for date, size and kind, and a compact list of names. Settings → Browsing chooses the columns, and Sizes → Match Finder uses Finder’s text and icon sizes in every view and the folder tree."
                        ),
                        HelpRow(
                            label: "Icon size and column width",
                            description:
                                "The slider at the right of the status bar sets the size of the icons in the Icons view and the width of the columns in the Compact List, and shows the size while it moves. The View menu, {increaseSize} and {decreaseSize} change them a step at a time, and {resetSize} brings back the default size. Sizes → Match Finder keeps sizes of its own."
                        ),
                        HelpRow(
                            label: "Columns in List view",
                            description:
                                "Each column keeps the width you give it. Drag the divider at the right of a column’s heading to make it wider or narrower, or double-click the divider to fit the column to its widest value. When the columns are wider than the pane (a narrow window, or the Info panel open), the list scrolls sideways."
                        ),
                        HelpRow(
                            label: "Sort",
                            description:
                                "The sort button, View > Sort By, or a click on a column heading in List view orders by name, kind, date or size. Choosing the same order again in View > Sort By, or clicking the same heading, reverses it; the sort button has Ascending and Descending. Search results order by name, folder or kind: click their headings in List view."
                        ),
                        HelpRow(
                            label: "Hidden files",
                            description:
                                "Files whose names start with a dot, and items macOS marks as hidden, as Finder hides them. {toggleHiddenFiles} shows them in the tab on screen, with their icons faded; search follows this setting too."
                        ),
                        HelpRow(
                            label: "Dates",
                            description:
                                "Recent dates read the way you would say them: “24 min ago”, “Today, 9:12 AM”, “Yesterday, 6:03 PM”, “Mon, 4:05 PM”. Earlier this year the year is left out; before that, the time. Rest the pointer on a date for the full date and time."
                        ),
                        HelpRow(
                            label: "Permissions",
                            description:
                                "The Permissions column shows the numeric code, such as `644`. Rest the pointer on it for the letters (`rw-r--r--`)."
                        ),
                    ]),
                HelpSection(
                    title: "Information",
                    rows: [
                        HelpRow(
                            label: "Info panel",
                            description:
                                "Details of the selected item at the right: kind, size, dates, permissions and quick actions."
                        ),
                        HelpRow(
                            label: "Info row",
                            description: "The same essentials in a strip under the list."),
                        HelpRow(
                            label: "Folder sizes",
                            description:
                                "With the Info panel or the Info Row open, the folder they show is measured by itself when it is your home folder, a folder in it, or an app: the one you select, or with nothing selected the folder on screen, however you got there (turn it off with Calculate folder sizes automatically in Settings → General). Other folders show no size until you ask: click Calculate in the Info panel, or choose Calculate Size from the right-click menu or {calculateSize}. Right-click empty space to size the folder on screen. With several items selected it sizes the folders among them. The path bar's right end shows the size of the selection, or of the folder on screen when nothing is selected, once every size in it is known. Sizing a folder also sizes every folder inside it."
                        ),
                        HelpRow(
                            label: "What takes the space",
                            description:
                                "Sort List view by Size: each size gets a bar showing its share of the largest item, so the big ones stand out. Folders get a bar once their size is known."
                        ),
                    ]),
                HelpSection(
                    title: "Appearance",
                    rows: [
                        HelpRow(
                            label: "Full screen",
                            description: "⌃⌘F, or the green button of the window. The same key leaves it."),
                        HelpRow(
                            label: "Light, Dark, accent",
                            description: "Settings → General → Appearance. Auto follows macOS. Help follows them too."),
                        HelpRow(
                            label: "Toolbar",
                            description:
                                "View > Customize Toolbar…, or right-click the toolbar. Drag items in from the sheet, along the toolbar to move them, or out of it to remove them. Done when finished. Command-drag moves or removes items without the sheet."
                        ),
                    ]),
            ]),
        HelpTopic(
            id: .shortcuts, title: "Keyboard shortcuts",
            intro:
                "Every shortcut, grouped by what it is for. The menus show them beside each command, and Settings → Shortcuts changes them.",
            sections: []),
    ]

    static let shortcutItems: [HelpShortcutItem] = [
        HelpShortcutItem(group: .navigation, .command(.goBack), "Go back"),
        HelpShortcutItem(group: .navigation, .command(.goForward), "Go forward"),
        HelpShortcutItem(group: .navigation, .command(.goEnclosingFolder), "Open the enclosing folder"),
        HelpShortcutItem(
            group: .navigation, .command(.openSelectedItem),
            "Open the selected item, or expand or collapse the folder in the tree"),
        HelpShortcutItem(group: .navigation, .command(.openLocationSheet), "Go to a folder by name or path"),
        HelpShortcutItem(group: .navigation, .command(.goHomeRootTree), "Go Home and root the folder tree there"),
        HelpShortcutItem(group: .navigation, .command(.goDocuments), "Go to Documents"),
        HelpShortcutItem(group: .navigation, .command(.goDesktop), "Go to Desktop"),
        HelpShortcutItem(group: .navigation, .command(.goDownloads), "Go to Downloads"),
        HelpShortcutItem(group: .navigation, .command(.goLibrary), "Go to your Library folder"),
        HelpShortcutItem(group: .navigation, .command(.goMacintoshHD), "Go to Macintosh HD"),
        HelpShortcutItem(group: .navigation, .command(.goApplications), "Go to Applications"),
        HelpShortcutItem(group: .navigation, .command(.goTrash), "Go to the Trash"),
        HelpShortcutItem(
            group: .navigation, .command(.rootTreeAtSelection), "Root the folder tree at the selected folder"),
        HelpShortcutItem(group: .navigation, .command(.newWindow), "New window, on the same folder"),
        HelpShortcutItem(group: .navigation, .command(.newTab), "New tab, on the same folder"),
        HelpShortcutItem(group: .navigation, .command(.openSelectionInNewTab), "Open the selected folder in a new tab"),
        HelpShortcutItem(
            group: .navigation, .command(.openSelectionInNewWindow), "Open the selected folder in a new window"),
        HelpShortcutItem(group: .navigation, .command(.moveTabToNewWindow), "Move the tab to a window of its own"),
        HelpShortcutItem(group: .navigation, .command(.mergeAllWindows), "Bring every window's tabs into this window"),
        HelpShortcutItem(group: .navigation, .command(.saveWorkspace), "Save the window's tabs as a workspace"),
        HelpShortcutItem(group: .navigation, .command(.openWorkspace1), "Open the first workspace"),
        HelpShortcutItem(group: .navigation, .command(.openWorkspace2), "Open the second workspace"),
        HelpShortcutItem(group: .navigation, .command(.openWorkspace3), "Open the third workspace"),
        HelpShortcutItem(group: .navigation, .command(.openWorkspace4), "Open the fourth workspace"),
        HelpShortcutItem(group: .navigation, .command(.openWorkspace5), "Open the fifth workspace"),
        HelpShortcutItem(
            group: .navigation, .command(.openWorkspace1InThisWindow), "Open the first workspace in this window"),
        HelpShortcutItem(
            group: .navigation, .command(.openWorkspace2InThisWindow), "Open the second workspace in this window"),
        HelpShortcutItem(
            group: .navigation, .command(.openWorkspace3InThisWindow), "Open the third workspace in this window"),
        HelpShortcutItem(
            group: .navigation, .command(.openWorkspace4InThisWindow), "Open the fourth workspace in this window"),
        HelpShortcutItem(
            group: .navigation, .command(.openWorkspace5InThisWindow), "Open the fifth workspace in this window"),
        HelpShortcutItem(
            group: .navigation, .command(.toggleTwoPanes),
            "Show a second pane beside this one, or close the pane you aren't in"),
        HelpShortcutItem(group: .navigation, .command(.switchToOtherPane), "Move the keyboard to the other pane"),
        HelpShortcutItem(
            group: .navigation, .command(.openSelectionInOtherPane), "Open the selected folder in the other pane"),
        HelpShortcutItem(
            group: .navigation, .command(.copyToOtherPane), "Copy the selected items into the other pane's folder"),
        HelpShortcutItem(
            group: .navigation, .command(.moveToOtherPane), "Move the selected items into the other pane's folder"),
        HelpShortcutItem(group: .navigation, .command(.swapPanes), "Swap the two panes"),
        HelpShortcutItem(
            group: .navigation, .command(.closeTab), "Close the tab (the window, when it is the last tab)"),
        HelpShortcutItem(group: .navigation, .command(.selectNextTab), "Next tab"),
        HelpShortcutItem(group: .navigation, .command(.selectPreviousTab), "Previous tab"),
        HelpShortcutItem(group: .navigation, .command(.reopenClosedTab), "Reopen the tab closed last"),
        HelpShortcutItem(group: .navigation, .command(.duplicateTab), "Duplicate the tab"),
        HelpShortcutItem(group: .navigation, .command(.closeWindow), "Close the window"),
        HelpShortcutItem(group: .navigation, .command(.focusTreePane), "Focus the folder tree"),
        HelpShortcutItem(group: .navigation, .command(.focusContentPane), "Focus the file list"),
        HelpShortcutItem(
            group: .navigation, .fixed("Tab"),
            "Move between the tree and the list, or with two panes, the tree, the left pane and the right pane"),
        HelpShortcutItem(group: .navigation, .fixed("Shift+Down"), "Extend the selection (Shift+Up, the other way)"),
        HelpShortcutItem(group: .navigation, .fixed("Home"), "Select the first item (End, the last)"),
        HelpShortcutItem(group: .navigation, .command(.halfPageDown), "Move half a page down"),
        HelpShortcutItem(group: .navigation, .command(.halfPageUp), "Move half a page up"),
        HelpShortcutItem(group: .navigation, .command(.pageDown), "Move one page down"),
        HelpShortcutItem(group: .navigation, .command(.pageUp), "Move one page up"),
        HelpShortcutItem(
            group: .navigation, .fixed("Shift+PageDown"),
            "Extend the selection by a page (Shift with any of the page keys above)"),
        HelpShortcutItem(group: .navigation, .command(.refreshOrApplySearchSort), "Refresh the current folder"),
        HelpShortcutItem(group: .files, .command(.openSelection), "Open"),
        HelpShortcutItem(group: .files, .command(.editSelection), "Edit in your text editor"),
        HelpShortcutItem(group: .files, .command(.quickLookSelection), "Quick Look"),
        HelpShortcutItem(
            group: .files, .command(.calculateSize),
            "Calculate the size of the selected folders, or of the folder on screen"),
        HelpShortcutItem(group: .files, .command(.renameSelection), "Rename"),
        HelpShortcutItem(group: .files, .command(.undo), "Undo the last file operation (in a text field, its typing)"),
        HelpShortcutItem(group: .files, .command(.redo), "Redo what was undone"),
        HelpShortcutItem(group: .files, .command(.copy), "Copy"),
        HelpShortcutItem(group: .files, .command(.cut), "Cut"),
        HelpShortcutItem(group: .files, .command(.paste), "Paste"),
        HelpShortcutItem(
            group: .files, .command(.pasteAsFile), "Save the image or text copied in another app as a file"),
        HelpShortcutItem(group: .files, .command(.duplicateSelection), "Duplicate"),
        HelpShortcutItem(group: .files, .command(.moveSelection), "Move to another folder"),
        HelpShortcutItem(group: .files, .command(.newFolder), "New folder"),
        HelpShortcutItem(group: .files, .command(.trashSelection), "Move to Trash"),
        HelpShortcutItem(group: .files, .command(.emptyTrash), "Empty the Trash (asks first)"),
        HelpShortcutItem(group: .files, .command(.ejectVolume), "Eject the disk selected in the sidebar"),
        HelpShortcutItem(group: .files, .command(.selectAll), "Select all"),
        HelpShortcutItem(group: .files, .command(.copyPath), "Copy the path"),
        HelpShortcutItem(
            group: .files, .command(.copyContents), "Copy the selected file's image or text, to paste in another app"),
        HelpShortcutItem(group: .files, .command(.showClipboard), "See what is waiting to be pasted"),
        HelpShortcutItem(group: .files, .command(.clearClipboard), "Empty the clipboard"),
        HelpShortcutItem(group: .files, .command(.openInTerminal), "Open in Terminal"),
        HelpShortcutItem(group: .files, .command(.showInFinder), "Show in Finder"),
        HelpShortcutItem(group: .files, .command(.toggleFavorite), "Add to or remove from Favorites"),
        HelpShortcutItem(group: .files, .fixed("Esc"), "Cancel a dialog (Cmd+. also works)"),
        HelpShortcutItem(group: .search, .command(.focusFileSearch), "Find files"),
        HelpShortcutItem(
            group: .search, .fixed("Down"), "Move from the search field into the results (Return also works)"),
        HelpShortcutItem(group: .search, .command(.showLastSearchResults), "Show the last results again"),
        HelpShortcutItem(group: .search, .command(.revealInFolder), "Show the selected result in its folder"),
        HelpShortcutItem(group: .search, .command(.refreshOrApplySearchSort), "Run the search again"),
        HelpShortcutItem(group: .search, .fixed("Esc"), "Close the results"),
        HelpShortcutItem(group: .views, .command(.toggleFolderTree), "Show or hide the folder tree"),
        HelpShortcutItem(group: .views, .command(.toggleInfoPanel), "Show or hide the Info panel"),
        HelpShortcutItem(group: .views, .command(.toggleInfoRow), "Show or hide the Info row"),
        HelpShortcutItem(group: .views, .command(.toggleHiddenFiles), "Show or hide hidden files"),
        HelpShortcutItem(
            group: .views, .command(.togglePinFilter),
            "Keep the filter typed in the list as you go to other folders, or let it go"),
        HelpShortcutItem(group: .views, .command(.viewAsIcons), "View as icons"),
        HelpShortcutItem(group: .views, .command(.viewAsDetails), "View as a list, with columns"),
        HelpShortcutItem(group: .views, .command(.viewAsList), "View as a compact list of names"),
        HelpShortcutItem(group: .views, .command(.viewAsPreviews), "View as large previews of the files"),
        HelpShortcutItem(
            group: .views, .command(.increaseSize), "Bigger icons in the Icons view, wider columns in the Compact List"),
        HelpShortcutItem(group: .views, .command(.decreaseSize), "Smaller icons, or narrower columns"),
        HelpShortcutItem(group: .views, .command(.resetSize), "Icons or columns back to their default size"),
        HelpShortcutItem(group: .views, .command(.sortByName), "Sort by name"),
        HelpShortcutItem(group: .views, .command(.sortByKind), "Sort by kind"),
        HelpShortcutItem(group: .views, .command(.sortByModified), "Sort by date modified"),
        HelpShortcutItem(group: .views, .command(.sortBySize), "Sort by size"),
        HelpShortcutItem(group: .views, .command(.toggleFoldersFirst), "Keep folders first, or not"),
        HelpShortcutItem(group: .views, .command(.fullScreen), "Enter or leave full screen"),
        HelpShortcutItem(group: .views, .command(.minimize), "Minimize the window"),
        HelpShortcutItem(group: .views, .command(.hide), "Hide File Trail"),
        HelpShortcutItem(group: .views, .command(.hideOthers), "Hide other apps"),
        HelpShortcutItem(group: .views, .command(.customizeToolbar), "Customize the toolbar"),
        HelpShortcutItem(group: .views, .command(.settings), "Settings"),
        HelpShortcutItem(group: .views, .command(.openHelp), "Help"),
        HelpShortcutItem(group: .views, .command(.openKeyboardShortcuts), "Keyboard shortcuts"),
        HelpShortcutItem(group: .views, .command(.quit), "Quit File Trail"),
        HelpShortcutItem(group: .views, .fixed("Esc"), "Clear the search in Help"),
    ]
}
