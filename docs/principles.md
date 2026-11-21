# Principles

The few rules that stand over everything else in File Trail: how its decisions are read, how safety is weighed, and how work is done with the owner. Read this first. The decisions themselves, each with its reason, are in [decisions.md](decisions.md); how a review is reported is in [process/reviews.md](process/reviews.md).

They hold for anyone, person or agent, who works here.

## Decisions and safety

- **A decision is a default with its reason, not a wall.** Each entry says why it was made. When the reason doesn't hold in the case at hand, when two entries pull against each other, when following one makes the ordinary case worse, or when what the owner reports goes against it, ask before going on: make an exception here, relax the decision in general, or keep it. Give a recommendation and what each costs. A decision is never followed into a bad result without a word, and never broken without one. What comes of the question is written down: a changed entry says what it replaced and why, and one that is kept says so with the date, so it isn't asked again.
- **Safety is weighed, not absolute.** "No data is lost" and rules like it carry a price, and the price is said before anything is built:
  - What it costs the ordinary case goes beside what it guards against: the time, an extra question or step, the code added. A guard that adds a question or a step to a common action, or slows one enough to notice, needs the owner's yes.
  - The case is named as someone would meet it: who does what, and how often. One that needs a power cut in a given moment, a disk that lies, or an archive made to hurt whoever made it is called contrived, and gets a guard only when the guard costs next to nothing.
  - The cheapest answer that takes the harm away is the one to take, in this order: say what happened; keep the original; prevent it; guarantee it. Most of what protects files here is the second: the original stays and a message says why.
  - What Undo or the Trash brings back is not lost.
  - A guard that needs a guard of its own is where to stop and ask.

## The app

- **The system's look comes first.** Prefer what macOS gives: its controls, its symbols, Liquid Glass where a surface is brief. Where Finder has a command, a key or an order of things, the app follows it unless a decision says otherwise, and what Finder doesn't have sits beside what it is most like. The keys that differ from Finder's are listed in one table ("The keys that differ from Finder's" in [decisions/windows-and-panes.md](decisions/windows-and-panes.md)), each with why; a new one is added there. What the app keeps of its own (font sizes, row heights, its own clipboard for files) is in [decisions.md](decisions.md), each with why.
- **The ordinary case is the one to build for.** What most people do most of the time is to be fast, plain and without questions. A rare case gets what it needs to be safe, and no more.

## Working with the owner

- **Do what was asked.** A list of things to fix is that list: what else is found goes into the report, not into the change. When what was asked leaves something out that looks as if it belonged, say which things stay untouched, and ask.
- **The owner is asked only what is the owner's to say.** A choice of how the app behaves, a decision to change, a cost to accept. What can be found out or tried is found out or tried: a change that needs trying in the app is tried by whoever made it (see [tools/capture/README.md](../tools/capture/README.md)), and the report says what was checked and how, not what the owner might try.
- **Work goes on between its parts.** At the end of one part of a plan, report, ask what the next part leaves open in one go, and carry on with what needs no answer. Stop only for an answer that is truly needed.
- **A report says what is so.** What was done, what was checked and how, what was not, and what failed, in that plainness. A review's findings come as [process/reviews.md](process/reviews.md) lays out.
