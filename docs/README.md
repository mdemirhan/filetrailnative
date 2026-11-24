# docs

What is kept here, by what it is for. A new file goes into the folder that fits what it is for; a plan moves to `records/` once it is done.

| Where | What it holds |
|---|---|
| [principles.md](principles.md) | The few rules over everything else: how a decision is read, how safety is weighed, how work is done with the owner. Read first. |
| [decisions.md](decisions.md), [decisions/](decisions/) | The owner's decisions, each with its reason: the standing ones and an index in the file, the rest by area in the folder. |
| [process/](process/) | How work is done here: [commands.md](process/commands.md), what a new command needs (the table, the menus, the palette, Help, Settings); [reviews.md](process/reviews.md), how a review is reported; [debugging.md](process/debugging.md), what was learned finding a stalled test run and a permission question. |
| [state/](state/) | What is true of the app now: [known-issues.md](state/known-issues.md), its limits and open issues; [battery.md](state/battery.md), what it does in the background; [tech-debt.md](state/tech-debt.md), engineering work left for later. |
| [plans/](plans/) | Work planned or under way: [search-conditions.md](plans/search-conditions.md) (conditions beside a search's text: kind, size, dates, tags, attributes), [apple-intelligence.md](plans/apple-intelligence.md) (set aside: search by description, the viewer's summary and picture text, Rename from Contents; where the work is parked and what was learned), [archives.md](plans/archives.md), [test-suite-audit.md](plans/test-suite-audit.md), [text-viewer.md](plans/text-viewer.md), [free-space-check.md](plans/free-space-check.md), [one-path-type.md](plans/one-path-type.md) (every path a `DiskPath`: what is in place, the steps, the bar for done), [file-name-type.md](plans/file-name-type.md) (a type for names with no `==`: to be investigated first, and may not be worth doing), [tab-and-window-views.md](plans/tab-and-window-views.md) (tab views and window views beside folder views; workspaces removed), [app-store.md](plans/app-store.md) (the Mac App Store: the sandbox, the build and upload, and the owner's decisions it waits on). |
| [records/](records/) | What is finished and kept for the record: [search-walk.md](records/search-walk.md) (the search's own walk against the fd it replaced: what each found and how long each took), [command-palette.md](records/command-palette.md), [folder-sizes.md](records/folder-sizes.md), [file-operations-review.md](records/file-operations-review.md), [clipboard-shelf.md](records/clipboard-shelf.md) and [group-by.md](records/group-by.md) (the plans of the clipboard that gathers and of Group By, both built), [finder-trash-workaround.diff](records/finder-trash-workaround.diff). |
| [features.md](features.md) | Everything the app does, by area, for people deciding whether to use it. The README is the product page, with the highlights, and links here. A feature added or changed gets its line here. |
| [development.md](development.md) | Building from source, checking a change, making a signed app and a release, and how the code is laid out. |
| [privacy.md](privacy.md) | The privacy policy, for the App Store listing and anyone who asks. |
| [app-store-listing.md](app-store-listing.md) | The text, screenshots and review notes of the Mac App Store page, ready for App Store Connect. What the app needs first is in [plans/app-store.md](plans/app-store.md). |
| [screenshots/](screenshots/) | The pictures of the README and of features.md, made by `scripts/readme-screenshots.sh`. They stay here: the README and the script name this place. |
| [frame-timings.json](frame-timings.json) | The frame times of each release, written by `scripts/release.sh`, which names this place. |

How the commands, the tests and the tools work is in [CLAUDE.md](../CLAUDE.md) and [tools/capture/README.md](../tools/capture/README.md).
