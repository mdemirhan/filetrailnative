# Deviations from the original

Each entry is an intentional difference between the native port and the Electron app. Each one is **proposed** until the user approves it at a wave gate.

| ID | Area | Original | Native port | Why | Status |
|---|---|---|---|---|---|
| D-001 | Tabs | In-window tab strip; tab context menu has Duplicate Tab | System tab bar; Duplicate Tab only in the File menu and its shortcut | Native window tabs chosen on 2026-10-13 | approved (decision) |
| D-002 | Tabs | Middle-click closes a tab | Not available; ⌘W or the tab's close button | The system tab bar owns tab clicks | approved 2026-10-13 |
| D-003 | Tabs | Hovering a file drag over a tab for 700 ms switches to it | Not available | The system tab bar owns drags over tabs | approved 2026-10-13 |
| D-004 | Drag | `system:readDragChangeCount` throws (addon export missing), so the "same drag came back" check never runs | The check works, using `draggingSequenceNumber` | A bug in the original, not a behavior | approved 2026-10-13 |
| D-005 | View | Whole-window zoom 75–150% (View › Zoom In/Out/Actual Size, ⌘+ / ⌘− / ⌘0, a zoom setting in Settings) | Not available; the UI is fixed at the original's 100% metrics. The `zoomPercent` preference is still read when importing settings and is ignored | Decided by the user on 2026-10-13: not worth the complexity | approved 2026-10-13 |
