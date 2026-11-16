# Folder sizes

The plan for how File Trail measures folders: what asks for a measurement, in what order measurements run, what stops one, what each view shows while it waits, runs, ends or fails, and how long a size stays true. Today's behavior grew one fix at a time; this puts it in one place, says where it falls short, and proposes one set of rules. The owner's answers to the questions at the end become entries in [decisions/file-operations.md](../decisions/file-operations.md), and this file moves to `records/` once it is built.

What is said of today was read in the code and, where marked *(tried)*, seen in a debug build driven by a scratch scenario on the owner's home folder.

## How it works today

### The pieces

- **The walker** (`Sources/CFileTrail/foldersize.c`, `NativeFolderSize`): one walk at a time, on 4 threads, at the utility QoS when the app started it itself. It stays on the disk it starts on, counts a folder it has no access to as empty (as Finder does), and fails as incomplete when a listing breaks part way or a sub-folder is replaced or goes with its parent (decisions/file-operations.md). Every folder inside is measured whole and handed back as it finishes. Stop sets a flag the threads look at before each listing: a walk stopped *(tried)* ended within 40–50 ms.
- **The jobs** (`FolderSizeJobs`, one for the app): the queue, and the cache of every size measured, for all windows. One job runs; each window has at most one more waiting, and asking again replaces it. A window's new request stops that window's running walk and goes first; another window's walk is left to finish, and the new request waits behind it. Nothing checks whether the folder asked for is already being walked or waiting.
- **The window's cache** (`WindowFolderSizes`, one for each window or tab): what that window knows, asked of the jobs as its views draw folders (one request for all the folders of a redraw, a folder not known asked again only after 5 s), and a running job looked at every 0.2 s or as soon as it ends. It repaints its own views at most every 100 ms. Another window's walk does not repaint it.
- **Auto measure** (`AutoFolderSizeController`, in the Info controller): with *Calculate folder sizes automatically* on and the Info panel or the Info Row open, the folder they describe is measured once it has stayed 0.5 s: Show Info's item, else the one item selected, else the folder on screen; only the home folder, folders in it, and bundles anywhere. It stops its own walk when the folder changes, when both views close or the setting goes off. While another folder of the window is being measured it waits, as starting would stop that one, and measures once it ends.

### What asks for a measurement

| Asked by | Measures | Forced (cache ignored) | Started as |
|---|---|---|---|
| Auto measure | the folder the Info panel or Info Row describes | no | automatic |
| File ▸ Calculate Size, its key, the palette | the selected folders, else the tree's folder, else the folder on screen | yes for one folder; no for several | asked |
| Right-click ▸ Calculate Size | the right-clicked item or the selection; a sidebar folder not otherwise shown opens the Info panel | yes for one; no for several | asked |
| "Calculate" in the Info panel or Info Row | that folder, or the selected folders | no | asked |
| The refresh button beside a size | the same | yes | asked |

The List's Size column, sort by size and the status bar never start a walk: they show what is known ("--" until then, "Calculating…" while it runs) and sort folders without a size last.

### What stops a measurement

1. Stop in the Info panel or Info Row.
2. Any new request from the same window, while the window's walk runs: Calculate Size on B stops Calculate Size on A. A has no total; what it measured inside is kept.
3. A new run of several folders replaces the window's earlier run, with the folders it hadn't reached.
4. Auto measure, of its own walk only, when its folder changes or the views close.
5. Closing the window or tab; quitting.
6. A write by the app inside the folder being walked: the walk is stopped and run again under the same job.

## Where it falls short

Each is found in the code; those marked *(tried)* were seen in the app.

1. **A folder you asked for is thrown away by the next one you ask for** (stop rule 2). Finder measures both.
2. **The front window can wait minutes behind a window you are not looking at**: an automatic walk of a home folder in a window behind, or in a hidden tab, holds the one walk, and Calculate Size in the front window waits with a spinner and no word why. Nothing stops a tab's automatic walk when the tab goes behind another.
3. **The same folder can be walked twice**: two windows asking for it (or for it and a folder holding it) each get a job, run one after the other, with no reuse.
4. **Other windows don't hear of a size that arrives**: a window showing a folder another window measured keeps "--" until something redraws it.
5. **Waiting looks like running**: a request behind another window's walk shows the spinner and "Calculating…", as if it ran.
6. **A failed walk looks like one never started**: the Info panel and Info Row show "Calculate", the List "--", and the error message is kept but shown nowhere. Auto measure doesn't try it again, so the folder looks forgotten.
7. **A size measured again inside a folder leaves the folder's size as it was**: measuring `~/Library/Caches` again after it shrank leaves `~/Library` and `~` with their old totals, so a folder can read smaller than what is inside it.
8. **Changes made outside the app leave sizes stale** until measured again: only the app's own writes clear or adjust them. A download, a build or Terminal's `rm` is not seen.
9. **What couldn't be read is not said**: a folder with no access counts as empty, silently; Finder does the same.
10. **Stop just as a walk finishes** shows no size until the folder is asked about again (known-issues.md).
11. **Hard links are counted each time they are met** (the walker keeps no record of the files it has seen). How iCloud files not downloaded to the Mac are counted, and how Finder counts either, is not checked yet.

## Proposed rules

### Two kinds of request

- **Asked**: anything the person did to measure a folder (Calculate Size by any route, the Calculate link, the refresh button).
- **Automatic**: auto measure.

A request belongs to the window it came from, and knows whether that window is in front (the key window's front tab).

### Order

- One walk at a time for the app, as now. A second walk on the same disk mostly slows the first; the walker already uses 4 threads.
- The queue runs **asked before automatic**; within each, **the front window's first**, then in the order asked.
- A request for a folder **already running or waiting joins that job**, from whichever window. A request for a folder **inside one being walked** joins it too: the walk hands back every folder inside as it finishes, so it gets its size without a walk of its own.

### What stops what

- **Asked is never stopped by another request.** A second asked folder waits its turn; several asked in a row run in the order asked. Only Stop, closing its window, quitting, or a write that makes it outdated (run again, as now) ends it early. Asking again for the same folder with Recalculate starts it over.
- **Automatic gives way.** An asked request from any window, or an automatic one from the front window, stops a running automatic walk of a window that isn't in front. What that walk measured inside is kept, and it goes back in the queue only if its window still describes that folder.
- **A window has at most one automatic request**, waiting or running; a new folder replaces it, as now.
- **A window or tab that goes behind another drops its automatic request**, waiting or running. When it comes to the front its views ask again.
- **Stop stops the folder's job for every window that joined it** only when no other window still asks for it; otherwise that window just stops showing it.

### What the views show

| State | Info panel and Info Row | List's Size column | Status bar |
|---|---|---|---|
| not measured | Calculate | -- | nothing |
| waiting | a spinner, dimmed, with Stop; tooltip "Waiting for another folder" | Waiting… | Waiting… |
| measuring | spinner and Stop (as now) | Calculating… | Calculating… |
| measured | size, counts, refresh (as now) | size | size |
| failed | "Couldn't Calculate", the message as its tooltip, and Try Again | -- | nothing |
| stopped | Calculate (as now) | -- | nothing |

- **Every window that shows a folder repaints when its size arrives**, not only the window that asked. The jobs already tell each window when a measurement settles; they would tell every window.
- **A failed folder is not measured again automatically** in the same session, so a folder that always fails doesn't keep walking; Try Again does.

### How long a size stays true

- **A size measured again inside a folder corrects the folders holding it**: the difference is added to each, as removals already are (`FolderSizeAdjust`). Where that can't be done exactly (a folder holding it counted on another measurement that is gone), those sizes are forgotten and shown as not measured.
- **Changes from outside the app**: the folder watchers the listings already run tell the cache which folders changed. Two choices, for the owner (question 4):
  - *Forget*: the sizes of the changed folders and those holding them are forgotten; the views show "Calculate" or "--" again, and auto measure measures again what it describes.
  - *Mark*: the sizes stay, shown as possibly outdated (dimmed, with the refresh button), until measured again.
  Only the folder each window has in front is watched today (`FolderWatches`), so a change in a folder not on screen would still go unseen until it is shown.

## Scenarios

Each with today's behavior and the proposed.

**Mainline**

1. *Info panel open, select a folder in the home folder, wait.* Today: measured after 0.5 s, spinner after 0.3 s more, size *(tried)*. Proposed: the same.
2. *Arrow down through twenty folders.* Today: none measured until one stays 0.5 s; the one left is stopped. Proposed: the same.
3. *Calculate Size on one folder.* Today: measured again even when known, at normal priority. Proposed: the same; it now goes ahead of any automatic walk, from any window.
4. *Select five folders, Calculate Size.* Today: measured one after another, known ones skipped; the status bar sums them as they come. Proposed: the same.
5. *Calculate Size on A, then on B before A ends.* Today: A is stopped. Proposed: B waits, both are measured.
6. *Sort by Size after measuring the folder on screen.* Today: every folder inside has its size from that walk, and the bars show. Proposed: the same.

**Several windows**

7. *Window 1 auto-measures the home folder; you switch to window 2 and Calculate Size on a folder.* Today: window 2 waits for the home folder to finish. Proposed: window 1's walk is stopped and put back; window 2's runs now; window 1's runs after, only while window 1 still describes it.
8. *Both windows show `~/Library`; window 1 measures it.* Today: window 2 shows "--" until it redraws. Proposed: window 2 shows the size when it arrives.
9. *Both windows ask for `~/Library`.* Today: walked twice. Proposed: walked once.
10. *Window 1 measures `~`; window 2 asks for `~/Documents`.* Today: waits, then walks `~/Documents` again. Proposed: joins window 1's walk and has its size when that part of the walk is done.
11. *A tab with the Info panel open goes behind another tab while it measures `~`.* Today: it keeps walking. Proposed: stopped and dropped; measured again when the tab comes back, unless known by then.

**Panes**

12. *A second pane opened and closed, then a folder measured in the first.* Today: the first pane hears of its sizes, since both panes now subscribe to the window's cache; before, the pane opened last took them all *(tried)*. Proposed: the same.

**Stopping and failing**

13. *Stop on a folder.* Today: back to "Calculate"; what was measured inside is kept. Proposed: the same, and no other window's view of it is stopped.
14. *A folder whose listing fails part way (a disk ejected, an I/O error).* Today: shows "Calculate"; the error is not shown. Proposed: "Couldn't Calculate" with the message, Try Again.
15. *A folder with sub-folders that can't be read (another user's, a protected app container).* Today: counted as empty, silently. Proposed: the same, unless the owner wants it said (question 6).
16. *Quit while measuring.* Today: the walk stops and nothing waiting runs. Proposed: the same.

**Changes**

17. *Move a file into a measured folder in the app.* Today: the folders it touched are measured again when next asked for; removals are taken off exactly. Proposed: the same.
18. *Measure `~/Library/Caches` again after deleting caches in Terminal.* Today: Caches is right, `~/Library` and `~` keep their old totals. Proposed: they are corrected by the difference.
19. *Download a 4 GB file into `~/Downloads` with another app.* Today: `~/Downloads` keeps its old size. Proposed: forgotten or marked, as the owner decides.

**Disks and kinds**

20. *Show Info on a folder on another disk or a network volume.* Today: not measured automatically; Calculate Size measures it. Proposed: the same.
21. *A bundle (an app) anywhere.* Today: measured automatically. Proposed: the same.
22. *The Trash.* Today: only the home folder's Trash is measured (known-issues.md). Proposed: out of scope here.

## Questions for the owner

1. **Asked never stops asked** (Calculate Size on B waits for A instead of stopping it). *Recommended:* yes. It costs a wait when you change your mind, which Stop covers.
2. **Automatic walks of a window not in front give way** to any asked request and to the front window's automatic one, and are put back in the queue. *Recommended:* yes.
3. **A tab or window that goes behind drops its automatic walk.** *Recommended:* yes for a tab behind another tab and for a minimized window; a window merely behind another window keeps its place in the queue, behind the front window's.
4. **Changes made outside the app**: forget the sizes, mark them as possibly outdated, or leave them as today. *Recommended:* forget, for the folders the watchers see change: simplest, and auto measure measures again what is on screen. It costs a walk each time something changes in a folder you are looking at, so a folder that changes all the time (Downloads while downloading) would walk again and again; a short wait after the last change (2 s) keeps that in check.
5. **Show "Waiting…" apart from "Calculating…".** *Recommended:* yes.
6. **Say when a size left out folders it couldn't read** ("Some folders couldn't be read" as the size's tooltip). *Recommended:* no, as Finder doesn't; revisit if someone asks.
7. **Hard links and iCloud files**: count as today and look at how Finder counts them before deciding. *Recommended:* look first, then ask.

## Order of work

1. **The jobs** (`FolderSizeJobs`): asked and automatic kinds, the queue order, front window, joining a job already running or waiting, joining a walk of a folder holding it, and the stop rules. Tests with the fake walker. Nothing changes in the views yet.
2. **Every window hears of every size** (the jobs tell each window; each repaints what it shows). The front window is told to the jobs by the window controllers.
3. **The states shown**: waiting, failed with its message and Try Again, in the Info panel, the Info Row, the List and the status bar. `help-content.json` and Help if they describe it.
4. **Sizes kept true**: a size measured again inside corrects the folders holding it; then, as the owner decides, changes from outside.
5. **Hidden tabs and minimized windows** drop their automatic walks.

Each step is tried in the app with a scratch scenario on a large folder (the home folder) and two windows, and lands on its own.
