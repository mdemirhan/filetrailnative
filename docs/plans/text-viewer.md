# Text viewer and editor

Reading text and code files with syntax colors, and editing them in place, inside a pane.
The mocks are on the design canvas "File Trail Text Viewer" (boards 1–9; board 7 is clickable).
This plan follows them.

## What it is

A pane can show a file instead of a folder.
There are two ways in, and the rest of what the viewer does is in the viewer (the design canvas, boards 10 and 11).

- **Open in Viewer (⌘E)**, in the File menu after Open and in a file's right-click menu after Open With, shows the selected file in place of the active pane's folder.
  It's a step of the pane's Back and Forward: Back returns to the folder with the file selected, and Forward shows the file again.
  Esc (in Read) and ⌘W close it too.
- **Open in Other Pane (⌥⌘↓ or ⌥⌘E)** on a file shows it in the other pane's viewer, opening the second pane first with one pane, and that viewer follows the list's selection: text, Markdown as it reads, pictures and other files as Quick Look shows them, a folder by its name.
  It is the second pane like any other: Two Panes closes it and brings it back as it was.
- **While a pane shows a file, its folder's commands are dimmed**: views, sorting, groups, filters, and the commands on the list's items.

### The viewer's bar and menu

- The bar shows only what applies now: the name and whether it has unsaved edits;
  for a file in place, its place among the folder's files and the steps to the next and previous;
  for a file beside the list, **Follow**;
  **Save** while there are edits;
  **Source or Preview** for Markdown;
  **Read or Edit**;
  the **⋯ menu**;
  and, last at the right end, a **✕** that closes the viewer, as Close Viewer does.
- The ⋯ menu holds Save (⌘S), Revert to Saved, Next File (⌥⌘]) and Previous File (⌥⌘[), Find (⌘F), the language, the appearance and themes, the text size, Wrap Lines and Line Numbers, Edit in Text Editor, and Close Viewer (Esc: the pane's folder again).
  Its keys are the viewer's own, taken while it has the keyboard; none is in the menu bar.
  Save File, Next File and Previous File are commands of the shortcut table under a Viewer heading, so Settings → Shortcuts changes their keys, the ⋯ menu writes the keys chosen, and the command palette runs them; Find (⌘F) and Esc stay as they are.
- **Read or Edit is remembered**: a file opens the way the last one was left, and a workspace keeps it with each pane.
- **Following goes on while editing.**
  A new selection with unsaved edits asks Save, Don't Save or Cancel;
  Cancel keeps the edited file and puts the list's selection back on it.
  Follow turned off keeps one file whatever the list selects.
- **The keyboard** goes into the text when its pane is focused.
  In Read the arrows, Space, Home and End scroll, and Tab moves to the next pane;
  the page and half-page keys move the text in Read and Edit.
  Esc in Edit goes to Read and Return in Read goes to Edit, for that file only;
  Esc in Read closes the viewer, in place and beside the list: the pane shows its folder again, and the panes stay as they are.
  With a file that isn't text the viewer itself has the keyboard, so Esc and Tab work the same. ⌘S saves only in the pane that shows the file.
- **The pane's bottom bar** shows the file's line, language and format instead of the folder's path.
- **Save** writes in place (the file keeps its identity, tags and permissions) in the file's own encoding, byte order mark and line endings.
  Leaving a file with edits asks: Back, another file, closing the viewer, the pane, the tab or the window, and quitting.
- **Changed on disk**: a file with no edits is read again and keeps its place.
  With edits, a bar says another app changed it while it was being edited, with Keep My Edits and Use Their Version.

### What it shows

- **Text is told by what is in the file, not its name**: a byte order mark, else valid UTF-8, else Windows Latin 1 for bytes with few control characters.
  A file with a zero byte and no byte order mark is not text, and says so with Quick Look and Open With.
- **About 60 languages and formats are colored**: Swift, C, C++, Objective-C, C#, Java, Kotlin, Scala, Groovy, Go, Rust, Zig, Dart, JavaScript, TypeScript, Python, Ruby, PHP, Perl, Lua, R, Julia, Haskell, OCaml, F#, Elixir, Erlang, Clojure, Lisp, the shells, PowerShell, batch files, SQL, GraphQL, Protocol Buffers, Thrift, Terraform, Nix, CMake, Make, Dockerfile, assembly, Vim script, LaTeX, logs, HTML, XML and property lists, Markdown, YAML, TOML, INI, Java properties, `.env`, ignore files, CSS, SCSS, Less and diffs.
  The language is found from the file's name, its extension, then a `#!` line, and the header's language pop-up changes it for that file.
- **Markdown** reads as its rendered Preview, and Edit shows the source.
  Source and Preview are a switch in the header.
  The Preview has the keyboard and takes the keys of the text in Read: the arrows, Space, Home and End, the page and half-page keys move it, Return is Edit in the source and Esc there the Preview again.
  Between the two, by Return and Esc, Read and Edit or Source and Preview, the place is kept: the line at the top of one is at the top of the other (from the Markdown line each piece of the Preview comes from), and Edit begins with the caret on it.
  A picture on the disk shows in the Preview, fitted to the pane;
  one on the web shows as its description.
- **Limits**: a file up to 50 MB is shown and can be edited, colors up to 10 MB.
  A larger file says it is too large to view here, with Edit in Text Editor.
- **Find** (⌘F while the viewer has the keyboard) is the system's find bar over the text, with Replace while editing.

### The theme

The viewer's text area has its own appearance: **Match App, Light or Dark**, and one light and one dark color theme (Paper, Mist, Sand; Graphite, Midnight, Ink).
It is one setting for the whole app, in the header's theme menu, with the font size, Wrap Lines and Line Numbers.
Settings has no page for it: the General page keeps to the app's own theme and accent.
The pane's header and status bar follow the app's appearance.

### Saved with the window

The viewer is part of the pane it is in, so a workspace, a saved tab, Reopen Closed Tab and Duplicate Tab bring it back: a following viewer pane, a pinned file and its Source or Preview, a file in place.
A following viewer keeps the file it showed, and that file is selected in the list again when the window comes back, so the workspace opens showing what was being read.
Unsaved edits are not kept.

## How it is built

- **FTFoundation/TextViewer**: the lexer (a line at a time, with a state carried from line to line, so an edit re-lexes only until the states agree again), the language table, text decoding and encoding, the themes.
  No dependency.
- **FTAppKit/TextViewer**: the viewer (a TextKit 1 `NSTextView` with a line-number ruler, colors as layout-manager temporary attributes for the lines on screen only, so a large file colors only what is shown), its header and status, the file loading and saving, Quick Look's preview view for other files, the Markdown preview (the system's Markdown parser).
- **The pane**: the viewer takes the place of the pane's list (`ContentPaneView.list`), so the pane's top line, path bar, header slots and keyboard checks stay as they are.
  A pane holds `viewer` state: in place, or following, or pinned.
- **Commands** (`docs/process/commands.md`): Open in Viewer (⌘E) is the one new command;
  Open in Other Pane takes files as well.
  Eject and Edit in Text Editor have no default key.
  The viewer's own keys are handled by the viewer. ⌘C, ⌘V, ⌘A, ⌘Z and ⌘F go to the text while the viewer has the keyboard, not to the files.
- **Saved state**: `OpenTabPreference` and `OpenPanePreference` gain an optional `viewer` record (mode, path, Markdown view), read by the sanitizer with a fallback, so older files read as no viewer.

## Decided for the owner to confirm

What is built where no answer was given yet;
each is a small change if the answer is otherwise.

1. **Highlighting is the app's own lexer, not tree-sitter.**
   Tree-sitter's generated parsers are one to fifteen MB of C each, so 30 languages are tens of MB of source and a longer build.
   The lexer colors about 60 languages with no dependency;
   tree-sitter can come later behind the same interface, with the owner's yes once its size is measured.
2. **Limits**: shown and editable up to 50 MB, colored up to 10 MB.
3. **Six built-in themes**, no imported ones.

## Later, not in this change

- Split (source and preview side by side) for Markdown.
- Reading a file over 50 MB a page at a time.
- Previews for HTML, CSV and SVG.
- Tree-sitter, if the owner wants it (above).
- Space showing the viewer in place of Quick Look, as a setting.
