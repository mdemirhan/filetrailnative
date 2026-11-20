# Reviews

How a review of File Trail's code is reported, whoever makes it. A reviewer asked to look at one part hands its findings back laid out this way, so the report is not sorted again afterwards. [principles.md](../principles.md) says how safety is weighed, which the bar below follows.

## Each finding

Every finding, fixed or not, says:

- **Where it is and what goes wrong**: the file and line, the fault in a sentence, and the case in which someone meets it.
- **How likely and how bad, as two marks.** A finding can be rare and harmful (a file lost at a power cut) or common and harmless. These two are what the owner decides on.
- **How it was checked**: "reproduced" or "read only".
- **Whether it comes from a fix made in the same review.** Those have a line of their own and are never left for later.
- **Its level**: blocker, should fix before release, or can wait.
- **A recommendation**: fix it or leave it, why, and how it would be fixed (the change in a sentence or two, where it goes, and what it costs or puts at risk). A finding left has one too, whichever group it is in: "leave it" says what would change that, and a finding that needs the owner's choice names the choice recommended.

A reviewer also lists, a line each, what it looked at and found right, so that what was covered is known.

## Release blocker or not

Blockers lead the report, and when there are none its first line says so. A blocker is never left by whoever reviews: if it seems one shouldn't be fixed now, the report says why and the owner decides.

A finding blocks a release when:

1. It loses or damages someone's files in a way that can't be undone, in a case a real person would meet. Acting on the wrong item counts, and so does telling of success for something that came out wrong. What Undo or the Trash brings back is not lost.
2. It weakens security or privacy: a file escaping macOS's checks, a write outside the folder chosen, something the person asked to have removed being kept.
3. It crashes or hangs the app in ordinary use, with no special disk and no contrived timing.
4. Something that worked in the last release no longer does; saved tabs, settings and workspaces that fail to load are that.
5. A new feature's main path doesn't work: what the release notes would name has to do what they say.
6. It comes from a fix made in the same review, until it is fixed or the fix taken back.

Not blockers: what is rare and harmless, what only looks off, slowness that doesn't trip the release's frame-time gate, missing tests (unless the path untested is one of the six), docs and comments, and code that goes against a decision without hurting anyone, which is "should fix".

A loss that can't be undone but needs a contrived case (a power cut in a given moment, a disk that lies, an archive made to hurt whoever made it) is not a blocker by itself. It goes under "It needs a choice from the owner", with what guarding against it would cost the ordinary case.

## What was found and not fixed

Each finding left goes into one group, by why it was left, with a line saying so, and under it the recommendation: whether it should be fixed after all, why, and how. The group says why it wasn't fixed in the review; the recommendation says what to do about it now, so the owner can answer each with a yes or a no.

- **The fix costs more than the problem.**
- **It needs a choice from the owner.** How the app behaves, or how it is built, is the owner's to say.
- **Rare.**
- **Harmless.**
- **Couldn't be tested.** The fix or the claim needs a disk, a device or a setup the machine hasn't; it may be cheap, but it can't be shown to work.
- **Older than the change.** A real fault, but not from the work under review.
- **Already decided.** In [decisions.md](../decisions.md) or [known-issues.md](../state/known-issues.md), so it isn't raised in every review.
- **Could simply have been done.** Nothing stood in the way. This group is empty when a review ends: those are fixed, not listed.
