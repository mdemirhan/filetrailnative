# The search's own walk against fd

How File Trail's own search (`Sources/CFileTrail/search.c`, `WalkSearchRuntime`) compared with the fd 10.5.0 it replaced, on the owner's Mac (16 cores: 12 performance, 4 efficiency), when the owner signed it off (2026-11-24). The decision is "Search walks the disk itself" in [names-and-search.md](../decisions/names-and-search.md); the plan it came from is [plans/search-conditions.md](../plans/search-conditions.md).

## What each found

The same items, compared field by field (path, name, extension, kind, hidden, folder), with the same status, the same limit and the same note of folders that couldn't be read:

- the search golden, 137 cases (the 59 of Skip Files Ignored by Git, which went with fd, aside);
- 1,440 searches of a tree made of what trips searches up: accented names composed and decomposed, the hidden flag on a file and a folder, dot names, packages, links to files, folders and nowhere, `.git` folders and a `.git` file, `node_modules`, a folder named `x.pdf`, a folder that can't be read, names with `*`, `?`, `[`, `{` and a backslash; Plain Text, Glob and Regex, by name and by path, with and without subfolders, hidden items and `.git` folders;
- the fixtures, seven kinds of search in each of those 16 ways;
- 15 kinds of search over `/System/Library`, `/Applications`, `/usr` and the fixtures, with and without hidden items.

Where they differed on purpose: fd refused a Name search with a "/" and a Glob or Regex that finds only names starting with a dot while hidden items are left out, in its own words; the walk refuses the same, in the app's. A Plain Text search with a "/" in a Name search found nothing in fd; the walk says no name has one.

## How long each took

An optimized build of the walk against fd's own; each the best of three runs, the two taking turns, the folders read from memory. Walk / fd under 1 is the walk faster.

| Folder | Search | Found | fd | Walk, 4 threads | Walk / fd | Walk, 8 threads | Walk / fd |
|---|---|---|---|---|---|---|---|
| /System/Library | Plain Text, few found | 0 | 0.834 s | 0.851 s | 1.02 | 0.910 s | 1.11 |
| /System/Library | Plain Text, some found | 44967 | 1.335 s | 0.957 s | 0.72 | 0.975 s | 0.68 |
| /System/Library | Plain Text, up to the limit | 50000 | 1.072 s | 0.304 s | 0.28 | 0.266 s | 0.24 |
| /System/Library | Plain Text, accented | 0 | 0.831 s | 0.849 s | 1.02 | 0.899 s | 1.07 |
| /System/Library | Plain Text, path | 15061 | 0.822 s | 0.951 s | 1.16 | 0.929 s | 1.10 |
| /System/Library | Plain Text, hidden too | 45085 | 0.968 s | 0.942 s | 0.97 | 0.929 s | 1.02 |
| /System/Library | Glob | 101 | 0.826 s | 0.864 s | 1.05 | 0.900 s | 1.07 |
| /System/Library | Glob, path | 3962 | 0.837 s | 0.876 s | 1.05 | 0.901 s | 1.07 |
| /System/Library | Regex | 7718 | 0.826 s | 0.960 s | 1.16 | 0.915 s | 1.09 |
| /System/Library | Regex, capitals | 4 | 0.837 s | 0.889 s | 1.06 | 0.908 s | 1.08 |
| /System/Library | Plain Text, top folder only | 90 | 0.008 s | 0.003 s | 0.33 | 0.003 s | 0.33 |
| /System/Library | Plain Text, long path | 2051 | 0.834 s | 0.866 s | 1.04 | 0.903 s | 1.08 |
| /System/Library | Glob, alternatives | 50000 | 1.464 s | 0.968 s | 0.66 | 0.920 s | 0.63 |
| /System/Library | Regex, path | 50000 | 1.244 s | 0.632 s | 0.51 | 0.552 s | 0.44 |
| /System/Library | Regex, hidden too | 7767 | 0.836 s | 0.896 s | 1.07 | 0.884 s | 1.04 |
| /Applications | Plain Text, few found | 0 | 0.774 s | 0.524 s | 0.68 | 0.651 s | 0.79 |
| /Applications | Plain Text, some found | 19763 | 0.864 s | 0.556 s | 0.64 | 0.654 s | 0.76 |
| /Applications | Plain Text, up to the limit | 50000 | 0.988 s | 0.145 s | 0.15 | 0.106 s | 0.11 |
| /Applications | Plain Text, accented | 0 | 0.762 s | 0.524 s | 0.69 | 0.651 s | 0.82 |
| /Applications | Plain Text, path | 21235 | 0.707 s | 0.594 s | 0.84 | 0.652 s | 0.86 |
| /Applications | Plain Text, hidden too | 19765 | 0.789 s | 0.548 s | 0.69 | 0.663 s | 0.78 |
| /Applications | Glob | 1401 | 0.761 s | 0.532 s | 0.70 | 0.648 s | 0.84 |
| /Applications | Glob, path | 1321 | 0.789 s | 0.580 s | 0.74 | 0.645 s | 0.79 |
| /Applications | Regex | 23906 | 0.738 s | 0.621 s | 0.84 | 0.664 s | 0.80 |
| /Applications | Regex, capitals | 46 | 0.868 s | 0.559 s | 0.64 | 0.645 s | 0.81 |
| /Applications | Plain Text, top folder only | 54 | 0.008 s | 0.003 s | 0.33 | 0.003 s | 0.33 |
| /Applications | Plain Text, long path | 6217 | 0.766 s | 0.540 s | 0.70 | 0.647 s | 0.81 |
| /Applications | Glob, alternatives | 50000 | 1.038 s | 0.183 s | 0.18 | 0.141 s | 0.14 |
| /Applications | Regex, path | 12862 | 0.773 s | 0.760 s | 0.98 | 0.687 s | 0.85 |
| /Applications | Regex, hidden too | 23931 | 0.852 s | 0.623 s | 0.73 | 0.668 s | 0.77 |
| /usr | Plain Text, few found | 0 | 0.059 s | 0.034 s | 0.58 | 0.043 s | 0.72 |
| /usr | Plain Text, some found | 296 | 0.070 s | 0.035 s | 0.50 | 0.043 s | 0.65 |
| /usr | Plain Text, up to the limit | 31898 | 0.415 s | 0.083 s | 0.20 | 0.072 s | 0.17 |
| /usr | Plain Text, accented | 0 | 0.061 s | 0.035 s | 0.57 | 0.044 s | 0.73 |
| /usr | Plain Text, path | 122 | 0.064 s | 0.037 s | 0.58 | 0.043 s | 0.66 |
| /usr | Plain Text, hidden too | 296 | 0.064 s | 0.035 s | 0.55 | 0.045 s | 0.75 |
| /usr | Glob | 18 | 0.061 s | 0.035 s | 0.57 | 0.043 s | 0.73 |
| /usr | Glob, path | 19 | 0.058 s | 0.035 s | 0.60 | 0.044 s | 0.74 |
| /usr | Regex | 256 | 0.061 s | 0.040 s | 0.65 | 0.043 s | 0.70 |
| /usr | Regex, capitals | 0 | 0.059 s | 0.037 s | 0.64 | 0.045 s | 0.81 |
| /usr | Plain Text, top folder only | 3 | 0.008 s | 0.003 s | 0.33 | 0.003 s | 0.33 |
| /usr | Plain Text, long path | 28 | 0.063 s | 0.035 s | 0.55 | 0.043 s | 0.69 |
| /usr | Glob, alternatives | 675 | 0.077 s | 0.042 s | 0.54 | 0.044 s | 0.59 |
| /usr | Regex, path | 198 | 0.070 s | 0.045 s | 0.64 | 0.045 s | 0.66 |
| /usr | Regex, hidden too | 256 | 0.062 s | 0.040 s | 0.64 | 0.044 s | 0.78 |
| the fixtures | Plain Text, few found | 0 | 0.012 s | 0.008 s | 0.62 | 0.008 s | 0.61 |
| the fixtures | Plain Text, some found | 4 | 0.010 s | 0.008 s | 0.73 | 0.008 s | 0.76 |
| the fixtures | Plain Text, up to the limit | 1482 | 0.033 s | 0.013 s | 0.39 | 0.013 s | 0.39 |
| the fixtures | Plain Text, accented | 266 | 0.015 s | 0.008 s | 0.51 | 0.008 s | 0.50 |
| the fixtures | Plain Text, path | 0 | 0.012 s | 0.015 s | 1.22 | 0.015 s | 1.52 |
| the fixtures | Plain Text, hidden too | 4 | 0.010 s | 0.008 s | 0.77 | 0.008 s | 0.61 |
| the fixtures | Glob | 0 | 0.010 s | 0.003 s | 0.26 | 0.003 s | 0.26 |
| the fixtures | Glob, path | 1 | 0.010 s | 0.007 s | 0.70 | 0.005 s | 0.47 |
| the fixtures | Regex | 337 | 0.015 s | 0.005 s | 0.34 | 0.005 s | 0.35 |
| the fixtures | Regex, capitals | 0 | 0.010 s | 0.003 s | 0.26 | 0.003 s | 0.26 |
| the fixtures | Plain Text, top folder only | 2 | 0.008 s | 0.003 s | 0.33 | 0.003 s | 0.33 |
| the fixtures | Plain Text, long path | 0 | 0.012 s | 0.015 s | 1.26 | 0.015 s | 1.18 |
| the fixtures | Glob, alternatives | 2 | 0.010 s | 0.005 s | 0.50 | 0.005 s | 0.45 |
| the fixtures | Regex, path | 0 | 0.010 s | 0.008 s | 0.77 | 0.005 s | 0.52 |
| the fixtures | Regex, hidden too | 337 | 0.012 s | 0.005 s | 0.42 | 0.005 s | 0.40 |
| All | | | 26.50 s | 19.78 s | 0.75 | 20.67 s | 0.77 |

(The fd column is the 4-thread run's; the 8-thread run timed fd again, at 26.88 s in all.)

## What was tried on the way

- **`getattrlistbulk`, like the folder-size walk:** it reads each item's attributes, which a search needs of none but those it finds. In a debug build it was 10–47% behind fd on single searches, and slower the more threads it had (12 threads: 30% behind fd overall). `readdir`, reading the folder's entries alone, matched fd on `/System/Library` and beat it on `/Applications` at 4 threads.
- **A debug build against fd's release build** made the walk look 15% slower than it is; the table above is of an optimized build, as the app ships.
- **Regex:** one `NSRegularExpression` shared by the threads made them wait on each other (4 threads over 475,000 names: 0.063 s shared, 0.038 s one each), and reading the thread's clock at each progress report of a match, to stop a runaway pattern, cost as much as the matching. One for each thread, and the clock read only after 256 reports, took Regex on `/System/Library` from 1.36 to 1.11 of fd. Swift's own `Regex` was up to four times slower than `NSRegularExpression`; Rust's regex engine was left out (see the decision).
- **Plain Text** is matched from a name's bytes when it is ASCII, without making a string; a Glob's longest plain run is looked for in the bytes before the regular expression.
