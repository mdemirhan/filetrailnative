# Deviations from the original

Each entry is an intentional difference between the native port and the Electron app. Each one is **proposed** until the user approves it at a wave gate.

| ID | Area | Original | Native port | Why | Status |
|---|---|---|---|---|---|
| D-001 | Tabs | In-window tab strip; tab context menu has Duplicate Tab | System tab bar; Duplicate Tab only in the File menu and its shortcut | Native window tabs chosen on 2026-10-13 | approved (decision) |
| D-002 | Tabs | Middle-click closes a tab | Not available; ⌘W or the tab's close button | The system tab bar owns tab clicks | proposed |
| D-003 | Tabs | Hovering a file drag over a tab for 700 ms switches to it | Not available | The system tab bar owns drags over tabs | proposed |
| D-004 | Drag | `system:readDragChangeCount` throws (addon export missing), so the "same drag came back" check never runs | The check works, using `draggingSequenceNumber` | A bug in the original, not a behavior | proposed |
