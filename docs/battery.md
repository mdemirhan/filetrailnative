# Battery and background work

Nothing here has been measured, so the order is a judgment. Measure with Activity Monitor's Energy tab or Instruments before changing anything.

| Item | What happens | Where | Likely cost |
|---|---|---|---|
| Folder watcher | The FSEvents stream is recursive and keeps running while the window is hidden or covered. The Electron app did the same. | `Sources/FTFileSystem/Watch/FSEventsFolderWatcher.swift` | Probably the largest, when folders under the watched one are busy |
| Info panel re-reads | With the panel open, every outside change re-reads its item, even if nothing it shows changed. No flicker. (`B-INFO-018`, `B-VIEW-190`, `T-cb87a875`) | `Sources/FTAppKit/InfoPanel/InfoController.swift` | An extra disk read per change |
| Details during search | Details of selected files are read during search too, where the Electron app waited. (`B-INFO-089`) | `selectionDetails` in `InfoController.swift` | Small |
| Date refresh timer | The minute timer keeps ticking while the window is hidden, because `RelativeClock.shared` never gets `isWindowVisible`. The pause logic exists and is tested, only unwired. (`B-INFO-083`, `B-INFO-197`) | `RelativeClock.swift` | Very small |

Other repeating timers run only during an animation, an open menu or a copy.
