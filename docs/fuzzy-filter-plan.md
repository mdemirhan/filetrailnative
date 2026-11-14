# Fuzzy filtering plan

The owner's decisions of 2026-11-14 on the list filter, the search results' filter and Plain Text search, and the
work that carries them out. Each phase lands as one commit, with its box ticked in that commit. When every phase is
done this file is deleted and `docs/decisions.md` keeps what it decided.

## Decisions (the owner, 2026-11-14)

1. **Fuzzy filtering is a setting, on by default.** Settings → Browsing, "Filter matches": Fuzzy or Contains. Fuzzy
   keeps a name when the letters typed appear in it in order, with anything between them; no rule about word starts.
   Contains is today's "name contains the text". Anything Contains keeps, Fuzzy keeps too.
2. **One setting covers both filters**: the list filter, and the filter typed over search results. Over search
   results the name follows the setting; the folder a result is in is always matched by Contains.
3. **Accents match one way.** A plain letter typed finds it with or without an accent ("e" finds e, é, è, ê, ë); a
   letter typed with an accent finds only that letter ("é" finds é, composed or decomposed). Letters that are not an
   accent on a base letter (ø, ł, đ, ı) stay letters of their own. This replaces the old rule that "e" doesn't find
   "é". It applies wherever names are matched against what is typed: the two filters, the sidebar's type-to-select,
   Go To, and Plain Text search.
4. **Plain Text search is matched as the filters are.** fd is given a regular expression that finds every accented
   and decomposed form, ignoring case, for every Plain Text query (one path, digits and punctuation included); the
   app's matcher then decides which results count, and marks them. Plain Text search ignores case always (no smart
   case). Regex and Glob searches are unchanged: fd's smart case, names as stored.
5. **No fuzzy search through fd**, for now. Out of scope.
6. **Search stops at 50,000 results**, not 20,000, and there is no setting for it. Results are folded once as they
   arrive, and a filter that grows by letters at its end narrows the previous matches instead of all results.
7. **Marked letters** show what the filter matched, in the list and over search results. Over search results, the
   filter's marks replace the search's while a filter is typed.
8. **The filter pill**: Liquid Glass (an exception to "glass only on toasts, the progress card and plain alerts",
   approved by the owner), Finder's filter symbol, the mode word (Fuzzy or Contains) as a clickable chip that switches
   the setting, the typed text, the count, the ✕. It springs up when a filter starts and drops away when cleared;
   with Reduce Motion it only fades. The search bar's filter field shows the same clickable mode word.
9. **No matches** turns the pill's edge red with a small shake. The list already says what found nothing, with a
   "Search Subfolders" button that searches the folder for the text, as ⌘F does with a typed filter.
10. **No caret, no editable field.** The arrows keep moving the selection in every view.
11. **⌥⌫ deletes the filter's last word.**
12. **Space**: never starts a filter. While a filter is typed, Space types a space for a second after each key and
    then does what it is assigned to (Quick Look by default). With nothing assigned to Space, Space always types a
    space into a filter. A command assigned to Space no longer stops Space from typing into a filter.
13. **⌘Y is a second default shortcut for Quick Look**, as in Finder.

## Phases

- [x] **1. The matcher, the setting and the marks.** `NameMatcher` in FTFoundation: built from the typed text and a
      mode, it says whether a name matches and which UTF-16 ranges of the name as stored to mark (several ranges for
      fuzzy), and scores a fuzzy match for the selection (a name that starts with the text, then one that contains
      it, then the best score). One-way accents. `ListFilter` matches through it. The `listFilterMatch` preference
      (fuzzy | contains, default fuzzy), sanitized, with a pop-up in Settings → Browsing. Marks for the list filter in
      the List, Icons and Compact List; `NameHighlight` and `MarkedName` take several ranges. The sidebar's
      type-to-select and Go To fold accents the same one way.
- [ ] **2. Search results at 50,000.** Each result's folded name and folder computed once as it is read, off the main
      thread. The filter narrows the previous matches when the new text extends the old (both filters). The limit
      is 50,000. A CPU-time test bounds one keystroke over 50,000 results.
- [ ] **3. Plain Text search as the filters match.** `FdSearchArgs` gives fd the accent-aware, case-ignoring pattern
      for Plain Text; the runtime's reading of results drops what the matcher rejects before it counts toward the
      limit; Plain Text marks come from the matcher. A test runs one table of queries and names (composed,
      decomposed, upper case, e/é, ß, final sigma, ø, ı) through the list filter and a real fd search over files
      spelled exactly so, and expects the same answer from both.
- [ ] **4. The pill and no matches.** Glass, symbol, clickable mode chip, spring in and out (fade with Reduce Motion),
      red edge and shake on no matches, the mode word in the search bar's filter field, ⌥⌫. The "no matches"
      state's Search Subfolders button sat at the left of the Compact List in the phase 1 check: put it under the text.
- [ ] **5. Space and ⌘Y.** The Space rule above; ⌘Y added to Quick Look's defaults.
- [ ] **6. README and screenshots.** The README says how typing filters now (letters in order, the marks, the mode
      chip, Settings → Browsing) and that Plain Text search finds accented names from plain letters. A new README
      screenshot, `docs/screenshots/filter.png`, shows a fuzzy filter typed in a folder: the pill with its chip and
      count, the matched letters marked. Its scene goes in `tools/capture/readme/` and is taken with
      `scripts/readme-screenshots.sh`; the other screenshots are taken again where the change shows in them.
- [ ] **7. Wrap-up.** `docs/decisions.md` takes the decisions above (replacing "Plain 'e' doesn't find 'é'" and the
      glass rule's list); Help says how filtering, Space and Plain Text search work; this file is deleted. The app is
      checked by hand with an `--automation` scenario: typing a filter in each view, the mode chip, no matches,
      a 50,000-result search with a filter typed over it.

Help, its golden and the tests change with the phase whose behavior they describe.

## Log

- 2026-11-14: Measured on an M4 Max over a home folder of 738,221 items: fd took the same CPU time (about 0.75 s)
  for `--fixed-strings` and for the accent-aware pattern; nearly all the time is the system reading folders. One
  keystroke of the search results' filter: 20 ms at 20,000 results today, 7 ms with names and folders folded once;
  18 ms at 50,000 folded once, fuzzy or not. Sorting 50,000 results by name: 78 ms.
- 2026-11-14: Phase 1. The setting is "Typing filters by" in Settings → Browsing. Over search results a name the filter
  didn't match (its folder did) keeps the search's marks. Checked in a debug build: "trpcd" in a fixture folder marks
  T, r, p, C and d in the List, Icons and Compact List, and Contains then shows no matches. `CommandRoutesTests`'
  `theMenuDimsWhatCantRunAsTheWindowIsWhenAsked` failed once in a full AppKit run and passed alone.
