# Battery and background work

Background work costs little, so nothing further is planned here. Measure before adding anything more elaborate.

## Measured (2026-10-31)

A release build with its own `--user-data-dir`, one window on a folder, 60 s per sample, CPU time from `ps` and power from `top`. The Mac was busy with other work, so small differences mean nothing. A hidden window does the same work as these visible ones, as the watcher doesn't look at visibility.

| Folder watcher latency | Subfolder activity | App CPU per minute | `top` power |
|---|---|---|---|
| 0.05 s | None | 0.39 s | 0.6 |
| 0.05 s | 10 writes a second | 0.38 s | 0.6 |
| 0.25 s | None | 0.37 s | 0.3 |
| 0.25 s | 10 writes a second | 0.37 s | 0.6 |
| 0.05 s | 200 files touched in a tight loop | 1.66 s | 2.7 |
| 0.25 s | 200 files touched in a tight loop | 0.92 s | 1.8 |

Reading the details of 20,000 selected files took under 0.9 s once, in a debug build.

## Decisions

| Item | Decision | Why |
|---|---|---|
| Folder watcher | Latency is 0.25 s. It keeps running while the window is hidden or covered. | The longer latency nearly halves the cost under extreme activity, and the first change still arrives at once. Stopping while hidden would save little and force a full read on each return. |
| Info panel re-reads | Left as is: with the panel open, every outside change re-reads its item. | One extra read per settled change, at most a few a second. With nothing selected it has to re-read anyway. |
| Details during search | Left as is: details of selected files are read during search too, rather than after it ends. | The worst case is a second, once, and waiting would leave the selection's total unknown until the search ends. |
| Date refresh timer | Ticks once a minute only while a window can be seen and its List shows a date under an hour old; otherwise only at midnight. | The pause logic already existed. |

The Info panel on a volume reads its free space again at each tick of that timer, and when its window comes back to the front.

Other repeating timers run only while something is going on, and stop when it ends:

- **A search** asks for new results every 0.12 s while it runs, and once a second while its tab is in the background.
- **A folder size** being calculated is asked about every 0.2 s.
- **A marquee** (dragging to select in the List, Icons or Compact List) looks at the pointer 60 times a second while the button is held, to scroll when it is past the edge.
- **Leftover writes**: when a start finds crash-journal entries it can't finish yet (a disk not connected or not answering), they are tried again once a minute, while nothing is being written, until none is left.
- **A copy** updates its progress while it runs; **an open menu** that changes with Option checks the key 20 times a second; **animations** (a tree row's arrow turning, the Info Row sliding) run at 60 frames a second while they last.
