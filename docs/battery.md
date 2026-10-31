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
| Info panel re-reads | Left as is: with the panel open, every outside change re-reads its item. (`B-INFO-018`, `B-VIEW-190`, `T-cb87a875`) | One extra read per settled change, at most a few a second. With nothing selected it has to re-read anyway. |
| Details during search | Left as is: details of selected files are read during search too, where the Electron app waited. (`B-INFO-089`) | The worst case is a second, once, and waiting would leave the selection's total unknown until the search ends. |
| Date refresh timer | Rests while no window can be seen. (`B-INFO-083`, `B-INFO-197`) | The pause logic already existed. |

The Info panel's free space is read once a minute while the panel is on a volume, on the same timer.

Other repeating timers run only during an animation, an open menu or a copy.
