# App Store listing

The text and pictures for File Trail's page on the Mac App Store, ready to paste into App Store Connect. Each field is within Apple's limit (counted below it). The App Store shows the description as plain text, so it uses capitals for headings and `•` for lists, not Markdown.

What still has to be done before the app can be submitted is in the plan, [plans/app-store.md](plans/app-store.md). Lines marked **Check** describe something the App Store build may do differently from today's app; settle them there first, and change the text to match.

## App information

| Field | Value |
|---|---|
| Name (30) | `File Trail` |
| Subtitle (30) | `Search, Two Panes, Cut & Paste` |
| Bundle ID | `com.filetrail.native` |
| SKU | `filetrail-mac` |
| Primary language | English (U.S.) |
| Primary category | Utilities |
| Secondary category | Productivity |
| Content rights | Contains no third-party content that needs rights. |
| Age rating | 4+ (every answer in the questionnaire is None or No) |
| Copyright | `2026 Mustafa Demirhan` |
| Price | The owner's choice (see plans/app-store.md) |

A name of `File Trail – File Manager` (25) would also be searched by "file manager"; the subtitle and keywords below already cover it.

## URLs

| Field | Value |
|---|---|
| Support URL (required) | `https://github.com/mdemirhan/filetrailnative/issues` |
| Marketing URL | `https://github.com/mdemirhan/filetrailnative` |
| Privacy Policy URL (required) | `https://github.com/mdemirhan/filetrailnative/blob/main/docs/privacy.md` |

## Promotional text (170)

Can be changed at any time without a new version.

```text
Find any file as you type, work in two folders side by side, and gather files from many folders to move them in a single paste. Native, fast and private.
```

## Keywords (100)

Comma separated, no spaces. Words already in the name and subtitle (file, trail, search, two, panes, cut, paste) count without repeating them. Apple's rules leave out other apps' names, so "Finder" is not among them.

```text
manager,browser,dual,pane,folder,tree,rename,batch,archive,unzip,rar,7z,size,disk,space,fuzzy,regex
```

## Description (4,000)

```text
File Trail is a file browser for people who spend their day in files. Instant search, a real folder tree, two panes side by side and true cut and paste come together in a fast, native Mac app that keeps the keyboard shortcuts you already know.

SEARCH AS YOU TYPE
• Results from the folder you are in appear as you type, each with the folder it lives in.
• Plain text, glob or regular expression, by name or full path. Case and accents never get in the way: "resume" finds "Résumé".
• No index to build or wait for. Widen a search to your Home folder or the whole disk with one click.
• Inside a Git repository, leave out .git and everything .gitignore excludes.
• Group and sort results by folder, kind, date, size or tag.

TWO FOLDERS, ONE WINDOW
• Split any tab into two panes, each with its own folder, view and history.
• Copy to the other pane with F5, move with F6, or drag across.
• Save a layout as a tab view or a window view and bring it back with one shortcut.

TRUE CUT AND PASTE
• Command-X cuts and Command-V moves.
• Gather files from many folders onto one clipboard, then copy and move them all in a single paste.
• Choose what happens on a name clash: Skip, Keep Both, Replace, Add Missing, or Replace Older to bring a backup up to date.
• Anything replaced goes to the Trash, moves to another disk are verified before the original is removed, and one Undo reverses the whole paste.

READ AND EDIT IN PLACE
• Open a file in the window with Space: code and text highlighted for about 60 languages, Markdown rendered, pictures, PDFs, movies and documents shown in full.
• Switch to Edit, make a change and save, without leaving the folder.
• Show files in the second pane and they follow your selection as you move through the list.

MADE FOR THE KEYBOARD
• Go To finds any folder you have visited from a few letters.
• Type in any folder to filter it, with fuzzy matching.
• The command palette finds every command by name.
• Assign your own shortcuts to any command, and see them all in the built-in Help.

EVERY FOLDER YOUR WAY
• List, Icons, Compact List and Previews, which fills the pane with large previews.
• Group any view by name, date, size, kind or tag.
• Give a folder its own view, sort order and columns, kept until you change them.
• Ask for a folder's size and see every folder inside it measured at once, with a bar for each.

SMALL JOBS, NO EXTRA APPS
• Rename many files at once, with a preview of every new name.
• Extract zip, tar, 7z, RAR and xar archives, and compress to zip.
• Convert images to JPEG, HEIC, PNG, TIFF or AVIF.
• Save a copied screenshot or text as a file with Paste as File.

FAST AND PRIVATE
• Smooth with thousands of files, and a slow disk or server never freezes the window.
• No account, no analytics and no network connections. Your files stay on your Mac.
• Native Swift and AppKit, in the system's look, in Light and Dark.
• Open source under the MIT License.

File Trail needs a Mac with Apple silicon and macOS 26 Tahoe or later.
```

## What's New

Not shown for a first version. For each later one, the release notes, which are already written for the people who use the app (`docs/decisions/code.md`), shortened to what matters most.

## Screenshots

The Mac App Store takes 1 to 10 screenshots at 16:10: 1280 × 800, 1440 × 900, 2560 × 1600 or 2880 × 1800. Today's README screenshots are 2224 × 1474 with a window shadow, so they are taken again at 2880 × 1800 from the same scenes in `tools/capture/readme/` (plans/app-store.md, "Store page and pictures"). Each gets a short caption above the window, in this order:

| # | Scene | Caption |
|---|---|---|
| 1 | `search.json` | **Find any file as you type.** No index, no waiting. |
| 2 | `two-panes.json` | **Two folders in one window.** Copy with F5, move with F6. |
| 3 | `cut-paste.json` | **True cut and paste.** Gather from many folders, paste once. |
| 4 | `paste-conflict.json` | **Built never to lose a file.** Replaced items go to the Trash. |
| 5 | `viewer.json` | **Read and edit beside the folder.** About 60 languages in color. |
| 6 | `go-to.json` | **Any folder in a few keystrokes.** Go To learns where you go. |
| 7 | `command-palette.json` | **Every command at your fingertips.** And shortcuts you choose. |
| 8 | `folder-sizes.json` | **See what takes the space.** Every folder measured in one pass. |
| 9 | `previews.json` | **Look through pictures a pane at a time.** |
| 10 | `dark-mode.json` | **At home in Light and Dark.** Native Swift and AppKit. |

An App Preview video (up to 30 seconds, 1920 × 1080) is optional and can come later: typing a search, splitting into two panes, F5, then gathering from two folders and one paste.

## App Privacy

In App Store Connect, App Privacy: **Data Not Collected**. File Trail has no analytics, no crash reporting of its own and makes no network connections ([privacy.md](privacy.md)).

## Notes for App Review

```text
File Trail is a file browser. It needs no account and makes no network connections.

The first time it opens, File Trail asks you to choose the folders it may show, as the App Sandbox requires: choose Macintosh HD (or your Home folder) in the panel and press Grant Access. It remembers the choice. Disks you connect later are granted the same way the first time they are opened.

Things to try:
• Type in the search field in the toolbar: results appear as you type.
• Press Command-\ to show two panes, select a file and press F5 to copy it to the other pane.
• Select a file, press Command-X, go to another folder and press Command-V to move it. Command-Z undoes it.
• Press Space on a text file to read it in the window; choose Edit to change it.
• Press Shift-Command-P for the command palette.

```

**Check:** the second paragraph describes the access flow the App Store build is to have (plans/app-store.md, "Folder access"). Keep it in step with what is built, and add a line for Empty Trash if the App Store build keeps it.

## Export compliance

File Trail uses no encryption of its own. `ITSAppUsesNonExemptEncryption` is `NO` in the App Store build's Info.plist, so App Store Connect doesn't ask with each build.
