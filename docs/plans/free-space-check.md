# A free-space check before a paste

Not started.
Today a paste starts with no look at the room on the destination: the first "no space" error ends it, the rest is "Not started", and a partly copied folder is not put in place ("A full disk ends a paste" in [decisions/file-operations.md](../decisions/file-operations.md)).
Nothing is lost, but someone copying 40 GB to a stick with 30 GB free waits for 30 GB to be written before learning it can't fit.
Finder says so before it starts.

## What it would do

- Before the paste writes anything, compare what it will write on each disk with that disk's room, and when it can't fit, say so in the paste review ("This needs 40.2 GB on “Stick”, which has 29.8 GB free.") with Paste off, rather than start.
- Moves within one disk write almost nothing and are left out.
  A Replace counts what it writes;
  the items it puts in the Trash still take room until the Trash is emptied, so they are not counted as freed.
- The room is the disk's room for important use (`volumeAvailableCapacityForImportantUsageKey`), which counts what macOS would purge, as Finder does.
- The sizes come from the review's own walk of the items, so it costs no second walk.
  Where the review hasn't walked a folder (one copied whole with no conflict inside), its size is walked then: that is the cost to measure first, on a home folder and on a slow stick.
- A share or a disk that can't say its room is left to the paste as today.
- "A full disk ends a paste" stays: the room can be taken by another app while the paste runs.

## Open for the owner

- Whether a paste that only just fits (within, say, 1%) asks or goes on.
- Whether the check may add a walk where the review didn't make one, once its cost is measured ("A guard that adds a question or a step to a common action, or slows one enough to notice, needs the owner's yes").
