# Folder sizes

The plan, now built, for how File Trail measures folders: what asks for a measurement, in what order measurements run, what stops one, what each view shows while it waits, runs, ends or fails, and how long a size stays true.
Today's behavior grew one fix at a time;
this puts it in one place, says where it falls short, and proposes one set of rules.
The owner answered its questions on 2026-11-16 and 2026-11-17 ("Decisions" below);
the standing rules are in [decisions/file-operations.md](../decisions/file-operations.md).
It is kept here for the record.

What is said of today was read in the code and, where marked *(tried)*, seen in a debug build driven by a scratch scenario on the owner's home folder.

## How it works today

### The pieces

- **The walker** (`Sources/CFileTrail/foldersize.c`, `NativeFolderSize`): one walk at a time, on 4 threads, at the utility QoS when the app started it itself.
  It stays on the disk it starts on and is best effort (decision 8, step 1): what is gone, changed or can't be read is left out, and each size says why (`FolderSizePartial`).
  Before step 1 it failed as incomplete when a listing broke part way or a sub-folder was replaced or went with its parent.
  Every folder inside is measured whole and handed back as it finishes.
  Stop sets a flag the threads look at before each listing: a walk stopped *(tried)* ended within 40–50 ms.
- **The jobs** (`FolderSizeJobs`, one for the app): the queue, and the cache of every size measured, for all windows.
  One job runs;
  each window has at most one more waiting, and asking again replaces it.
  A window's new request stops that window's running walk and goes first;
  another window's walk is left to finish, and the new request waits behind it.
  Nothing checks whether the folder asked for is already being walked or waiting.
- **The window's cache** (`WindowFolderSizes`, one for each window or tab): what that window knows, asked of the jobs as its views draw folders (one request for all the folders of a redraw, a folder not known asked again only after 5 s), and a running job looked at every 0.2 s or as soon as it ends.
  It repaints its own views at most every 100 ms.
  Another window's walk does not repaint it.
- **Auto measure** (`AutoFolderSizeController`, in the Info controller): with *Calculate folder sizes automatically* on and the Info panel or the Info Row open, the folders they describe are measured once they have stayed 0.5 s: Show Info's item, else the items selected (several are measured one after another, from the top of the list down, one at a time), else the folder on screen;
  only the home folder, folders in it, and bundles anywhere.
  A selected folder being measured stays measured while the selection grows;
  Stop on any of them, its own measurement or one asked for (`WindowFolderSizes.wasStopped`), ends the rest until the selection changes, and a size forgotten after a change is measured again.
  It stops its own walk when the folder changes, when both views close or the setting goes off.
  While another folder of the window is being measured it waits, as starting would stop that one, and measures once it ends.

### What asks for a measurement

| Asked by | Measures | Forced (cache ignored) | Started as |
|---|---|---|---|
| Auto measure | the folders the Info panel or Info Row describes | no | automatic |
| File ▸ Calculate Size, its key, the palette | the selected folders, else the tree's folder, else the folder on screen | yes for one folder; no for several | asked |
| Right-click ▸ Calculate Size | the right-clicked item or the selection; a sidebar folder not otherwise shown opens the Info panel | yes for one; no for several | asked |
| "Calculate" in the Info panel or Info Row | that folder, or the selected folders | no | asked |
| The refresh button beside a size | the same | yes | asked |

The List's Size column, sort by size and the status bar never start a walk: they show what is known ("--" until then, "Calculating…" while it runs) and sort folders without a size last.

### What stops a measurement

1. Stop in the Info panel or Info Row.
2. Any new request from the same window, while the window's walk runs: Calculate Size on B stops Calculate Size on A. A has no total;
   what it measured inside is kept.
3. A new run of several folders replaces the window's earlier run, with the folders it hadn't reached.
4. Auto measure, of its own walk only, when its folder changes or the views close.
5. Closing the window or tab;
   quitting.
6. A write by the app inside the folder being walked: the walk is stopped and run again under the same job.

## Where it falls short

Each is found in the code;
those marked *(tried)* were seen in the app.

1. **A folder you asked for is thrown away by the next one you ask for** (stop rule 2).
   Finder measures both.
2. **The front window can wait minutes behind a window you are not looking at**: an automatic walk of a home folder in a window behind, or in a hidden tab, holds the one walk, and Calculate Size in the front window waits with a spinner and no word why.
   Nothing stops a tab's automatic walk when the tab goes behind another.
3. **The same folder can be walked twice**: two windows asking for it (or for it and a folder holding it) each get a job, run one after the other, with no reuse.
4. **Other windows don't hear of a size that arrives**: a window showing a folder another window measured keeps "--" until something redraws it.
5. **Waiting looks like running**: a request behind another window's walk shows the spinner and "Calculating…", as if it ran.
6. **A failed walk looks like one never started**: the Info panel and Info Row show "Calculate", the List "--", and the error message is kept but shown nowhere.
   Auto measure doesn't try it again, so the folder looks forgotten.
7. **A size measured again inside a folder leaves the folder's size as it was**: measuring `~/Library/Caches` again after it shrank leaves `~/Library` and `~` with their old totals, so a folder can read smaller than what is inside it.
8. **Changes made outside the app leave sizes stale** until measured again: only the app's own writes clear or adjust them.
   A download, a build or Terminal's `rm` is not seen.
   Kept as it is (decision 4).
9. **What couldn't be read is not said**: a folder with no access counts as empty, silently;
   Finder does the same.
   Kept as it is (decision 6).
10. **Stop just as a walk finishes** shows no size until the folder is asked about again (known-issues.md).
11. **Hard links are counted each time they are met** (the walker keeps no record of the files it has seen).
    How iCloud files not downloaded to the Mac are counted, and how Finder counts either, is not checked.
    Left as it is (decision 7).
12. **A walk fails when something changes while it runs**: a sub-folder replaced by a file or a link, or gone with a folder above it, or a listing broken part way by a read error, fails the whole measurement, with no size at all.
    These happen most in `~` and `~/Library`, the folders measured most.
    Replaced by best effort (decision 8).

## Proposed rules

### Two kinds of request

- **Asked**: anything the person did to measure a folder (Calculate Size by any route, the Calculate link, the refresh button).
- **Automatic**: auto measure.

A request belongs to the window it came from, and knows whether that window is in front (the key window's front tab).

### Order

- One walk at a time for the app, as now.
  A second walk on the same disk mostly slows the first;
  the walker already uses 4 threads.
- The queue runs **asked before automatic**;
  within each, **the front window's first**, then in the order asked.
- A request for a folder **already running or waiting joins that job**, from whichever window.
  A request for a folder **inside one being walked** waits, and is answered by that walk when it finishes the folder (the walk hands back every folder inside as it finishes), with no walk of its own;
  if the walk doesn't reach it (it gives way, or leaves the folder out), it runs in its turn.
- An automatic job another window asks for becomes one asked for: it no longer gives way.
  A walk already running keeps the priority it started at.

### What stops what

- **Asked is never stopped by another request.**
  A second asked folder waits its turn;
  several asked in a row run in the order asked.
  Only Stop, closing its window, quitting, or a write that makes it outdated (run again, as now) ends it early.
  Asking again for a folder being walked, Recalculate included, joins that walk: its answer is as fresh as a new one.
- **At most 10 asked requests wait, for the whole app.**
  A run of several folders (Calculate Size on a selection) is one request, its folders measured in order, so a selection of 200 folders is measured whole.
  An 11th drops the oldest waiting request, which goes back to not measured;
  the one running is never dropped.
  A request that joined a job already running or waiting doesn't count again.
- **Automatic gives way.**
  An asked request from any window, or an automatic one from the front window, stops a running automatic walk of a window that isn't in front.
  What that walk measured inside is kept, and it goes back in the queue only if its window still describes that folder.
- **A window has at most one automatic request**, waiting or running;
  a new folder replaces it, as now.
- **An automatic request goes when what asked for it no longer wants it**: the Info panel and Info Row describe another folder, both close, or the setting goes off.
  Waiting, it is taken out of the queue;
  running, it is stopped.
  (So it is today, for the window's own request; the rule now holds for a request put back in the queue too.)
- **A tab behind another tab, or a minimized window, drops its automatic request**, waiting or running.
  When it is shown again its views ask again.
  A window merely behind another window keeps its request, behind the front window's.
- **Stop stops the folder's job for every window that joined it** only when no other window still asks for it;
  otherwise that window just stops showing it.

### What the views show

| State | Info panel and Info Row | List's Size column | Status bar |
|---|---|---|---|
| not measured | Calculate | -- | nothing |
| waiting | a spinner, dimmed, with Stop; tooltip "Waiting for another folder" | Waiting… | Waiting… |
| measuring | spinner and Stop (as now) | Calculating… | Calculating… |
| measured | size, counts, refresh (as now) | size | size |
| failed | "Couldn't Calculate", the message as its tooltip, and Try Again | -- | nothing |
| stopped | Calculate (as now) | -- | nothing |

- **Every window that shows a folder repaints when its size arrives**, not only the window that asked.
  The jobs already tell each window when a measurement settles;
  they would tell every window.
- **A failed folder is not measured again automatically** in the same session, so a folder that always fails doesn't keep walking;
  Try Again does.

### Best effort, and what the code knows of it

A measurement counts what it can and gives a size;
it fails only when nothing can be measured.

- **Left out, and the walk goes on**:
  - a sub-folder gone, replaced by a file or a link, gone with a folder above it, or renamed before the walk reached it (*changed*);
  - a sub-folder with no permission to read, counted as an empty folder, as now (*no access*);
  - a listing that breaks part way, or a sub-folder that can't be opened for another reason (an I/O error, too many files open): what was read is counted (*read error*).
- **Failed**: the folder itself is gone, isn't a folder, or can't be opened or listed at all, or the walk can't start (no threads, no memory).
  With what failed as its message.
- **Stopped** stays apart from both, as now.

Each size knows how complete it is: **complete**, or **partial** with the reasons found (*changed*, *no access*, *read error*), for the folder and for every folder inside it the walk hands back, a reason found in a folder carried up to every folder holding it.
The reasons go with the size wherever it goes: the walker's result, the jobs' cache, a job's status and the window's entry.
Nothing shows them for now (decision 8).
They are kept apart because *no access* is ordinary (the home folder without Full Disk Access meets protected app containers on every walk) and the others are not: whatever is done with them later, a note shown on every home folder's size is not wanted.

A size taken off or added to by the app's writes keeps the completeness it had.

### How long a size stays true

- **A size measured again inside a folder corrects the folders holding it**: the difference is added to each, as removals already are (`FolderSizeAdjust`).
  Where that can't be done exactly (a folder holding it counted on another measurement that is gone), those sizes are forgotten and shown as not measured.
- **Changes from outside the app leave sizes as they are**, until measured again (decision 4).
  The refresh button beside a size is how to measure it again.

## Scenarios

Each with today's behavior and the proposed.

**Mainline**

1. *Info panel open, select a folder in the home folder, wait.*
   Today: measured after 0.5 s, spinner after 0.3 s more, size *(tried)*.
   Proposed: the same.
2. *Arrow down through twenty folders.*
   Today: none measured until one stays 0.5 s;
   the one left is stopped.
   Proposed: the same.
3. *Calculate Size on one folder.*
   Today: measured again even when known, at normal priority.
   Proposed: the same;
   it now goes ahead of any automatic walk, from any window.
4. *Select five folders, Calculate Size.*
   Today: measured one after another, known ones skipped;
   the status bar sums them as they come.
   Proposed: the same.
5. *Calculate Size on A, then on B before A ends.*
   Today: A is stopped.
   Proposed: B waits, both are measured.
6. *Sort by Size after measuring the folder on screen.*
   Today: every folder inside has its size from that walk, and the bars show.
   Proposed: the same.

**Several windows**

7. *Window 1 auto-measures the home folder;
   you switch to window 2 and Calculate Size on a folder.*
   Today: window 2 waits for the home folder to finish.
   Proposed: window 1's walk is stopped and put back;
   window 2's runs now;
   window 1's runs after, only while window 1 still describes it.
8. *Both windows show `~/Library`;
   window 1 measures it.*
   Today: window 2 shows "--" until it redraws.
   Proposed: window 2 shows the size when it arrives.
9. *Both windows ask for `~/Library`.*
   Today: walked twice.
   Proposed: walked once.
10. *Window 1 measures `~`;
    window 2 asks for `~/Documents`.*
    Today: waits, then walks `~/Documents` again.
    Proposed: joins window 1's walk and has its size when that part of the walk is done.
11. *A tab with the Info panel open goes behind another tab while it measures `~`.*
    Today: it keeps walking.
    Proposed: stopped and dropped;
    measured again when the tab comes back, unless known by then.
    The same for a minimized window.
12. *Calculate Size on twelve folders one at a time, each while another runs.*
    Today: each stops the one before.
    Proposed: one runs, ten wait, and the oldest waiting is dropped when the twelfth comes.
13. *The Info panel describes `~`, waiting behind window 1's walk;
    you select `~/Documents`.*
    Today: the waiting request is replaced.
    Proposed: the same;
    `~` is taken out of the queue.

**Panes**

14. *A second pane opened and closed, then a folder measured in the first.*
    Today: the first pane hears of its sizes, since both panes now subscribe to the window's cache;
    before, the pane opened last took them all *(tried)*.
    Proposed: the same.

**Stopping and failing**

15. *Stop on a folder.*
    Today: back to "Calculate";
    what was measured inside is kept. Proposed: the same, and no other window's view of it is stopped.
16. *A sub-folder's listing fails part way (an I/O error).*
    Today: the whole folder fails and shows "Calculate";
    the error is not shown.
    Proposed: the size of what was read, partial (*read error*), shown as any size.
17. *A cache folder deleted, or a folder renamed, inside `~/Library` while it is walked.*
    Today: a deleted one is left out;
    a renamed one, or one gone with its parent, fails the walk.
    Proposed: left out, the size shown, partial (*changed*).
18. *The disk is ejected while one of its folders is walked.*
    Today: fails, shows "Calculate".
    Proposed: the folder itself can't be read any more, so it fails: "Couldn't Calculate" with the message, Try Again.
19. *A folder with sub-folders it has no permission to read (another user's, a protected app container).*
    Today: counted as empty, silently.
    Proposed: the same, partial (*no access*), shown as any size (decision 6).
20. *Quit while measuring.*
    Today: the walk stops and nothing waiting runs.
    Proposed: the same.

**Changes**

21. *Move a file into a measured folder in the app.*
    Today: the folders it touched are measured again when next asked for;
    removals are taken off exactly.
    Proposed: the same.
22. *Measure `~/Library/Caches` again after deleting caches in Terminal.*
    Today: Caches is right, `~/Library` and `~` keep their old totals.
    Proposed: they are corrected by the difference.
23. *Download a 4 GB file into `~/Downloads` with another app.*
    Today: `~/Downloads` keeps its old size until measured again.
    Proposed: the same (decision 4).

**Disks and kinds**

24. *Show Info on a folder on another disk or a network volume.*
    Today: not measured automatically;
    Calculate Size measures it.
    Proposed: the same.
25. *A bundle (an app) anywhere.*
    Today: measured automatically.
    Proposed: the same.
26. *The Trash.*
    Today: only the home folder's Trash is measured (known-issues.md).
    Proposed: out of scope here.

## Decisions (2026-11-16, 2026-11-17)

1. **A size asked for is never stopped by another request.**
   A second one waits its turn.
   This is for sizes asked for (Calculate Size by any route, the Calculate link, the refresh button);
   automatic walks give way (2).
   **At most 10 asked requests wait**, for the whole app, a run of several folders counting as one;
   past that the oldest waiting one is dropped, never the one running.
2. **Automatic walks of a window not in front give way** to any asked request and to the front window's automatic one, and are put back in the queue while the window still describes the folder.
   **When the view that asked moves to another folder or closes, its automatic request is taken out of the queue**, or stopped if it runs.
3. **A tab behind another tab, or a minimized window, drops its automatic walk.**
   A window merely behind another keeps its place, after the front window's.
4. **Changes made outside the app leave sizes as they are**, as today.
   Asked to choose between forgetting the sizes of the folders the watchers see change, marking them as possibly outdated, and this;
   the owner chose this.
5. **A walk waiting shows "Waiting…"**, apart from one running: a dimmed spinner with Stop and the tooltip "Waiting for another folder" in the Info panel and Info Row, "Waiting…" in the List's Size column and the status bar.
6. **A size that left out folders it has no permission to read doesn't say so**, as Finder doesn't.
7. **Hard links and iCloud files are counted as they are now**;
   not part of this plan.
8. **Calculating a size is best effort** (2026-11-17): what is gone, changed or can't be read while the walk runs is left out, and the size is shown;
   a measurement fails only when the folder itself can't be measured.
   This replaces the earlier rule that failed a walk when a sub-folder was replaced or went with a folder above it, or when a listing broke part way.
   **The code knows a complete size from a partial one, and why it is partial**, with nothing shown for now, so something can be done with it later.

## Order of work

1. **Best effort in the walker** (done): `foldersize.c` and `NativeFolderSize`: the *changed* and *read error* cases left out instead of failing the walk, and each folder's completeness and reasons handed back with its size and carried up.
   Then the completeness kept with each size in the jobs' cache, a job's status and the window's entry.
   Its tests: a walk with a sub-folder removed, replaced, renamed, unreadable and failing part way, each with its total and reasons;
   the root gone or not a folder fails.
2. **The jobs** (done): `FolderSizeJobs`: asked and automatic kinds, the queue order, front window, joining a job already running or waiting, joining a walk of a folder holding it, the stop rules and the cap of 10 waiting.
   Tests with the fake walker.
   Nothing changes in the views yet.
3. **Every window hears of every size** (done): the jobs say when sizes are stored, and each window looks up again, at most every 0.5 s, the sizes of the folders it shows.
   The front window is told to the jobs by the window controllers (done with step 2).
4. **What runs in the background, in one place** (done; 2026-11-17, the owner's ask).
   Built first as a toolbar item of its own, which the owner turned down on trying it (2026-11-17: its symbol, and the toolbar moving as it came and went);
   then, from mock-ups the owner chose from, a ring at the end of the title's room, part of the title and no toolbar item (nothing moves, it can't be removed or moved, and the title, plain text, gains no border): it fills as the file operation goes on, spins while a size is measured, with "+N" in a pill growing to its left for the others listed, and a check when a file operation completes;
   a click opens the list;
   its list (`TabActivity`, `ActivityView`) rows the file operation and the folder sizes asked for, an automatic walk only while it holds one up (the owner's answer), each with Stop;
   `ActivityCenter` hears the write broadcast and the jobs.
   Left out: a Window ▸ Activity command;
   the owner chose the button only (2026-11-17), as the Undo History list it is like has none.
   Planned: A toolbar button shown only while something runs or waits (as Safari's Downloads), with a ring when how far along is known, and a popover listing every window's work, each with Stop: file operations (what, where, how far, as their card), folder sizes asked for (the folder, its window, running or waiting, folders measured so far).
   A command to open it (Window ▸ Activity), with all `docs/process/commands.md` asks of one.
   The progress card stays as the window's own view.
   No window of its own and no history.
   Open, asked when this step starts: whether automatic walks are listed (*recommended:* not, unless one holds up a size asked for), and whether two windows can run file operations at once (found out: they can't; one runs for the whole app, and another asked for meanwhile is refused with a notice, so the list holds one file operation at most).
5. **The states shown** (done): waiting (a dimmed spinner, "Waiting for another folder", "Stop Waiting"; "Waiting…" in the List and the status bar), and failed ("Couldn't Calculate" with why as its tooltip, and Try Again) in the Info panel and Info Row.
   Help's Folder sizes says how sizes wait and that a size counts what it can.
6. **Sizes kept true** (done): a folder measured again changes the folders holding it by the difference, when their measurement counted the size it had (`FolderSizeAdjust.adjustForRemeasure`);
   otherwise they are forgotten.
   What this leaves: a corrected folder holds sizes of two measurements, so the same folder inside measured again a second time makes the folders holding it forgotten rather than corrected (measured again when next asked for).
7. **Hidden tabs and minimized windows** drop their automatic walks (done): auto measure stands down while its tab is behind another tab or its window is minimized, and asks again when it is shown.
   Tried in the app (two tabs, the home folder);
   no unit test, as the Info controller has none of its own.

Each step is tried in the app with a scratch scenario on a large folder (the home folder) and two windows, and lands on its own.
