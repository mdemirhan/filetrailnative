# B-SRCH: Search (sessions per tab, options, scopes, results, refinement filter, background tabs, Show Last Search Results)

Improvements it belongs to: A1.

What this area does better than Finder, in code terms:
- Search is incremental and mostly local: typing makes one `fd` walk per pause (400 ms), and text that only gets longer is applied by filtering the results already found, with no new walk and no wait (`isNarrowerTextQuery` plus `refinedSearchResults`).
- Each tab owns a complete search session (query, scope, options, sort, results, selection of both lists, job id and cursor). A search keeps running in the worker while its tab is in the background and is polled once a second, so the tab shows finished results when it is shown again.
- Results never show under another query's text: a new query keeps only the results that provably still match (`keepMatchingResults`), clears everything else at once, and drops answers from older searches by a session counter.
- Hiding results (Esc, Done, opening a folder) stops the walk; the results are cached and come back with the query in the field (focus the field in the same folder, or Show Last Search Results), re-running only if the walk was cut off or the hidden-files setting changed.
- Search follows the file list's hidden-files setting, offers a scope bar (folder, Home, disk, Macintosh HD that excludes /Volumes), a plain-text mode that matches literally, smart case, Git-aware skipping, a 20,000-result cap, and a results filter that matches name or folder.

Legend. Evidence file names are under `/Users/tcmudemirhan/src/tsproj/filetrail` (original, pinned): `useExplorerSearchController.ts`, `useSearchSession.ts`, `useExplorerTabs.ts`, `useExplorerNavigationController.ts`, `useExplorerShortcuts.ts`, `useExplorerActions.ts` are in `apps/desktop/src/renderer/hooks/`; `SearchBar.tsx`, `SearchOptionsMenu.tsx`, `ExplorerWorkspace.tsx` in `apps/desktop/src/renderer/components/`; `searchResults.ts`, `searchRefinement.ts`, `listFilter.ts`, `explorerTabs.ts`, `rendererCommandAvailability.ts`, `contentSelection.ts` in `apps/desktop/src/renderer/lib/`; `App.tsx` in `apps/desktop/src/renderer/`; `fdSearch.ts` in `packages/core/src/search/`; `appPreferences.ts`, `shortcuts.ts` in `apps/desktop/src/shared/`. Terms: "results shown" means `searchResultsVisible` is true and the committed query is non-empty (search mode). "Committed query" is the trimmed text the results on screen stand for. "Base query" is the text the running or finished `fd` walk was started with. "Field" is the toolbar search field (placeholder "Search"). "Filter field" is the field in the results bar (placeholder "Filter by name or folder").

## 1. Starting a search: live typing, Return, thresholds

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-001 | Typing in the field searches by itself when the trimmed text is at least 2 characters long and the keyboard has been still for 400 ms (`LIVE_SEARCH_MIN_LENGTH = 2`, `LIVE_SEARCH_DELAY_MS = 400`). Each keystroke cancels the pending timer and starts a new 400 ms wait, so a burst of keys makes one search for the text the typing stopped at. | useExplorerSearchController.ts:44, 47, 609-625, 433-448 | T-b49c92ba |
| B-SRCH-002 | Length is measured on the trimmed text: leading and trailing spaces do not count toward the 2-character minimum, and the search is started with the trimmed text (the field keeps the untrimmed text). | useExplorerSearchController.ts:613-614, 480 | - |
| B-SRCH-003 | One trimmed character does not start a search, however long the keyboard rests (480 ms with "s" produces no `search:start` and no results pane). | useExplorerSearchController.ts:614-619 | T-b49c92ba |
| B-SRCH-004 | When the timer fires it first checks that the field still holds the same trimmed text; if the field changed or was emptied in the meantime, nothing is searched. | useExplorerSearchController.ts:439-441 | T-985cc237 |
| B-SRCH-005 | A live search is started with `live: true` (so a pattern that does not parse yet is reported quietly) and with `keepMatchingResults: true`, and in the scope returned by `resolveSearchRootPath` (B-SRCH-040). | useExplorerSearchController.ts:442-446 | T-b49c92ba |
| B-SRCH-006 | Every search request carries the options set at that moment (pattern mode, match scope, recursive, skip .git, skip ignored) plus `includeHidden` from the file list; a fresh launch sends `patternMode: "text"`. | useExplorerSearchController.ts:536-546; appPreferences.ts:426-431 | T-b49c92ba |
| B-SRCH-007 | Return in the field (form submit) calls `submitSearch` and does not wait for the 400 ms timer: it cancels any pending live search first, and searches whatever the length, including 1 character. | useExplorerSearchController.ts:629-651; ExplorerWorkspace.tsx:1340-1344 | T-b49c92ba |
| B-SRCH-008 | Return when the trimmed field text equals the committed query and the scope is unchanged does not start a new search (`search:start` count stays the same). It marks the search as not live (`setSearchStartedLive(false)`) so a pattern error now shows in full. | useExplorerSearchController.ts:633-643 | T-b49c92ba |
| B-SRCH-009 | Return when text only grew since the base query (refinable, B-SRCH-020) applies the refinement at once without a new search and also marks the search not live. | useExplorerSearchController.ts:644-648 | - |
| B-SRCH-010 | Return with any other text starts a search immediately (not live, with `keepMatchingResults: true`). | useExplorerSearchController.ts:649 | - |
| B-SRCH-011 | After Return, once the results are on screen, the field is dismissed: popover closed, field blurred, focus given to the content pane (results list). | useExplorerSearchController.ts:260-266; App.tsx:2711-2720 | T-b49c92ba, T-24fd84fd |
| B-SRCH-012 | After Return, if the results for the query were already on screen and the search is not running, the first result is selected at once, but only if the selection is empty. | App.tsx:2711-2719, 2060-2065; useExplorerSearchController.ts:640-643 | T-b49c92ba |
| B-SRCH-013 | After Return, if the search is still running (or just started), no result is selected yet; the first result (in sorted order) is selected when the status leaves "running", provided results are still shown, the content pane has focus and the selection is empty at that moment. | App.tsx:2066-2088 | - |
| B-SRCH-014 | The "select the first result when done" request is forgotten when another tab is shown (reset in a layout effect on `activeTabId`). | App.tsx:2076-2079 | - |
| B-SRCH-015 | Return with an empty or whitespace-only field does not search: `startSearch` clears the committed search entirely (B-SRCH-070). | useExplorerSearchController.ts:483-486 | - |
| B-SRCH-016 | A search cannot start while no folder is open (`rootPath` empty): `startSearch` returns without any state change. | useExplorerSearchController.ts:487-489 | - |
| B-SRCH-017 | Text that is too short (under 2 trimmed characters) shown while a cached search exists clears the committed search at once: results pane closes, folder list returns, cache is dropped, and the field keeps the typed text ("s"). | useExplorerSearchController.ts:614-619; 303-328 | T-b49c92ba |
| B-SRCH-018 | Starting a search from a typed list filter (see B-SRCH-052) searches at once with `live: true`, whatever the length (no 2-character minimum, no 400 ms wait), in the folder on screen, and ignores any earlier search's scope. | App.tsx:2077-2092 | T-21dd6904 |
| B-SRCH-019 | A search is started with the query trimmed; the committed query, base query and their refs are set to the trimmed text at start. | useExplorerSearchController.ts:480, 515-518 | - |

## 2. Refinement: narrowing without searching again

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-020 | A typed text is refined (applied without a new walk, no wait) only when all hold: pattern mode is "text"; results are shown; status is "running" or "complete" (not "cancelled", "error", "truncated", "idle"); the walk did not truncate; the scope that typing would use equals the current scope root; and the new text contains the base query by the base's case rule. | useExplorerSearchController.ts:585-594 | T-06c0cfba, T-40eae612 |
| B-SRCH-021 | Refinement changes only the committed query (and its ref), clears the cached results selection, and applies an empty selection: whatever was selected in the results becomes unselected. The base query, job and results are untouched. | useExplorerSearchController.ts:596-604 | T-06c0cfba |
| B-SRCH-022 | While committed differs from base, displayed results are the found results filtered by `matchesTextQuery(result, committedQuery, matchScope)`; results that arrive later from the still-running walk are filtered the same way. When committed equals base, no filtering. | useExplorerSearchController.ts:120-128 | T-06c0cfba |
| B-SRCH-023 | Text with no match, when refined, empties the list straight away; the results pane stays open and shows "No matches" (status complete) or "Searching…" (status running). | useExplorerSearchController.ts:120-128; SearchBar.tsx:181-203 | T-06c0cfba |
| B-SRCH-024 | Taking characters back, down to the base query (e.g. "soup" back to "so"), un-narrows: all found results show again, because committed equals base. | useExplorerSearchController.ts:122, 585-594 | T-06c0cfba |
| B-SRCH-025 | Text that is shorter than the base but still 2+ characters, or unrelated text, is not refinable; it is searched after the 400 ms rest. Example: base "so", typing "on" runs a new `search:start` for "on" and the old list is cleared. | useExplorerSearchController.ts:620-624; 500-512 | T-06c0cfba |
| B-SRCH-026 | `isNarrowerTextQuery(base, next)` is false when base is empty or next is shorter than base; otherwise, if base contains an uppercase letter (Unicode `Lu`), true iff `next.includes(base)` exactly; else true iff `next.toLowerCase().includes(base)`. Same-length equal text is "narrower". | searchRefinement.ts:28-33, 10-12 | T-9dadd92e |
| B-SRCH-027 | Smart case: a query with any uppercase letter matches case-sensitively (`includes`), any other query matches case-insensitively (haystack lower-cased). Matching is literal text, never a pattern ("a.c" does not match "abc"; "(1).p" matches "report (1).pdf"). | searchRefinement.ts:15-24 | T-e566169a |
| B-SRCH-028 | The haystack is the file name for scope "name" and the full path for scope "path". | searchRefinement.ts:20 | T-dc2d82a3 |
| B-SRCH-029 | A longer text that adds a capital to a lowercase base is refinable (stricter); a lowercase continuation of a base that had a capital is not ("Re" to "readme" is not narrower). | searchRefinement.ts:28-33 | T-9dadd92e |
| B-SRCH-030 | If the walk stopped at its 20,000-result limit (status "truncated"), a longer text is never refined: it is searched for itself after the 400 ms rest, and the old list stays until that search starts. | useExplorerSearchController.ts:589-590 | T-40eae612 |
| B-SRCH-031 | If a walk reports `truncated` while committed differs from base (typed further while it ran), the controller abandons the refinement and starts a new live search for the committed text in the resolved scope, keeping matching results. | useExplorerSearchController.ts:372-384 | T-40eae612 |
| B-SRCH-032 | The same truncated-and-narrower condition found in a background tab on attach (`jobId` null, `truncated`, committed differs from base) makes the attach report "search must run again". | useExplorerSearchController.ts:866-874 | - |
| B-SRCH-033 | When a new search starts with `keepMatchingResults` and results are shown, pattern mode is "text" and the new root equals the current root, the results that provably also match stay on screen while the new walk runs: longer new text keeps only results matching it; shorter new text that is contained in the old query (by the new text's case rule) keeps all of them; unrelated text keeps none. Otherwise the list is cleared at start. | useExplorerSearchController.ts:500-514; searchRefinement.ts:38-52 | T-2d1cc088, T-c68ee1c1 |
| B-SRCH-034 | Kept results are remembered by path; results of the new walk with a kept path are dropped on arrival so none is listed twice. | useExplorerSearchController.ts:512, 360-364 | T-40eae612 |
| B-SRCH-035 | Unrelated new text clears the old results immediately when its search starts, even while the new search is still running with zero results: the list never shows results for a query no longer in the field. | useExplorerSearchController.ts:500-514 | T-c68ee1c1 |
| B-SRCH-036 | `keepMatchingResults` for unrelated queries, or when the previous query is empty, returns an empty list. | searchRefinement.ts:38-52 | T-2d1cc088 |
| B-SRCH-037 | Refinement for glob or regex modes never happens; every change of such text goes through the 400 ms live search. | useExplorerSearchController.ts:587 | - |
| B-SRCH-038 | The list filter typed into the results (B-SRCH-117) is dropped whenever the committed query changes, including by refinement, because the filter belongs to the list identified by path, "search"/"folder" and committed query. | useExplorerNavigationController.ts:639-648, 2406-2411 | - |
| B-SRCH-039 | Result metadata (modified, size, ...) is thrown away and re-requested whenever the committed query or the search root changes, including on every refinement. | App.tsx:1735-1742 | - |

## 3. Scope of a typed search

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-040 | The scope a typed or submitted search uses: the root of the search on screen if results are shown, a root is set, and the folder the search was started from (`searchOriginPath`) is still the open folder (so a widened scope survives further typing); otherwise the open folder. | useExplorerSearchController.ts:452-459 | - |
| B-SRCH-041 | A new search records the open folder as its origin (`searchOriginPathRef`) and the root as `searchRootPath`. | useExplorerSearchController.ts:520, 524 | - |
| B-SRCH-042 | A search for the base query never runs in a scope other than the one chosen: option changes, ⌘R and hidden-files re-runs use `searchRootPath || currentPath`. | useExplorerSearchController.ts:664-668, 716, 205 | - |

## 4. Search field: focus, keys, clear button

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-043 | The field's placeholder is "Search"; the form's accessible name is "Find files in current folder"; spell check is off. | ExplorerWorkspace.tsx:1328-1383 | - |
| B-SRCH-044 | Focusing the field (any focus event) clears the pane focus (`setFocusedPane(null)`), clears the pane type-to-select text, opens the search popover state (the shell gets class "active"), and calls `showCachedSearchResults({fromField: true})`. | App.tsx:2733-2739 | T-0d7af669 |
| B-SRCH-045 | Focusing the field brings back the cached results and their query only if the folder open now is the folder the search was started from; in another folder the field is left as it is (empty), ready to search there. | useExplorerSearchController.ts:224-228 | T-0d7af669 |
| B-SRCH-046 | Bringing the cached results back sets the field text to the committed query (also overwrites any other draft text when results are already visible). | useExplorerSearchController.ts:229-230 | T-0d7af669 |
| B-SRCH-047 | Mouse-down anywhere in the field form except on the clear button sets the pointer-intent flag, clears pane focus and type-ahead, and focuses the input on the next animation frame. | ExplorerWorkspace.tsx:1328-1339; App.tsx:2701-2709 | - |
| B-SRCH-048 | ⌘F (command `focusFileSearch`, menu Edit > Find Files…) clears pane focus and type-ahead, opens the popover, shows cached results if allowed (B-SRCH-045), and on the next animation frame focuses the field and selects all its text. | App.tsx:2091-2108; shortcuts.ts:352-357 | T-21dd6904 |
| B-SRCH-049 | The menu form of the command switches to the explorer main view first, then does the same on the next animation frame. | useExplorerShortcuts.ts:1445-1451 | - |
| B-SRCH-050 | ArrowDown in the field (not during IME composition) prevents default; when results are shown it dismisses the field (blur, popover closed, focus to content pane) and selects the first result if nothing is selected; when no results are shown nothing else happens. | ExplorerWorkspace.tsx:1366-1374; App.tsx:2721-2728 | - |
| B-SRCH-051 | Esc in the field (stops propagation, prevents default): with results shown it hides them (B-SRCH-065); with no results shown it abandons the draft (cancels the pending live search and empties the field and its ref); then in both cases dismisses the field and gives focus to the content pane. | ExplorerWorkspace.tsx:1375-1381; App.tsx:2738-2748 | T-985cc237, T-e6c30f5d |
| B-SRCH-052 | ⌘F while the file list has a typed filter and search mode is not shown carries the filter text into search: the filter is cleared, the field gets the text, the search starts at once (B-SRCH-018) in the open folder, and the field takes focus on the next frame. | App.tsx:2077-2092, 2098-2103 | T-21dd6904 |
| B-SRCH-053 | The clear button inside the field (title "Clear Search", accessible name "Clear file search") exists only while the field's trimmed text is non-empty; its mouse-down is prevented so it does not steal focus. | ExplorerWorkspace.tsx:1384-1395 | T-985cc237 |
| B-SRCH-054 | Clicking the clear button abandons the draft, clears the committed search completely (B-SRCH-070) and puts focus back into the field; the field stays empty and the results pane is gone. | App.tsx:2749-2755 | T-985cc237 |
| B-SRCH-055 | Esc before anything was searched (pending live search) forgets the typed text and prevents the search from starting: after 480 ms there is no `search:start`, the field is empty, no results pane. | useExplorerSearchController.ts:655-659 | T-985cc237 |
| B-SRCH-056 | The search popover state (shell class "active") closes when focus leaves the shell for something outside it (blur with related target outside) or on a mouse-down outside the shell and the search options menu. | App.tsx:2016-2036, 2690-2699 | - |
| B-SRCH-057 | When a search is submitted or dismissed the field loses focus and the content pane gets it, so keystrokes go to type-to-filter on the results (B-SRCH-117). | App.tsx:2711-2716; useExplorerSearchController.ts:260-266 | T-24fd84fd |
| B-SRCH-058 | After typing in the field a search result list appears while the field keeps keyboard focus, so typing can continue (live search does not move focus). | useExplorerSearchController.ts:442-446 | T-b49c92ba |
| B-SRCH-059 | The toolbar title in search mode is `Searching “<name of search root>”` (root "/" is "Macintosh HD"); the subtitle is empty. | App.tsx:2800-2808; explorerTabs.ts:128-133 | - |

## 5. Showing, hiding and clearing results; Show Last Search Results

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-060 | Search mode is `searchResultsVisible && committedQuery.trim().length > 0`. A cached search (committed query non-empty) can exist without being shown. | useExplorerSearchController.ts:153-154 | T-0d7af669 |
| B-SRCH-061 | While results are shown, the file list is replaced by the results: the list uses its own view mode (`searchViewMode`, default "details"), not the folder's view mode. | App.tsx:570-572; appPreferences.ts:395 | - |
| B-SRCH-062 | Esc with the content pane focused and search mode shown (and no list filter text to clear first, B-SRCH-117) hides the results and keeps focus in the content pane. | useExplorerShortcuts.ts:1605-1609 | - |
| B-SRCH-063 | The results bar's Done button (title "Close Search Results (Esc)", accessible name "Close search results") closes the popover, blurs the field, hides the results and focuses the content pane. | App.tsx:2502-2508; SearchBar.tsx:126-133 | T-bccba4a0 |
| B-SRCH-064 | Hiding results is not a navigation: the cached results, query, scope, options and sort stay in memory. | useExplorerSearchController.ts:248-258 | T-0d7af669 |
| B-SRCH-065 | Hiding results cancels a pending live search, empties the field (draft ""), sets results hidden, and restores the folder list's selection that was saved when the search started, limited to items that still exist in the folder (`sanitizeContentSelection`). | useExplorerSearchController.ts:248-258; contentSelection.ts:27-56 | T-0d7af669, T-e6c30f5d |
| B-SRCH-066 | The folder list's selection is saved when a search starts from the folder list (`browseSelectionRef`), and kept updated while the folder list is the visible list; selection changes made in results update the separate cached-results selection. | useExplorerSearchController.ts:490-493; useExplorerActions.ts:836-843 | - |
| B-SRCH-067 | Hiding results while the walk is still running cancels the job (`search:cancel`), sets the status "cancelled" and marks the search interrupted so it runs again when shown. | useExplorerSearchController.ts:208-218 | T-c68ee1c1 |
| B-SRCH-068 | A search whose start request is still being answered when the results are put away is cancelled when the answer arrives (`searchInterrupted` set, status "cancelled"). | useExplorerSearchController.ts:550-556 | - |
| B-SRCH-069 | Opening any folder (tree, favorite, back, forward, opening a folder result, reveal) hides the results and empties the field, unless the open is a reload caused by the hidden-files toggle or marked `keepSearchResults`. The cache stays. | useExplorerNavigationController.ts:913-923, 1770-1783 | - |
| B-SRCH-070 | Clearing the committed search (field text under 2 chars with a cache, ✕, empty Return) cancels the pending live search and the job, bumps the session counter, empties query/base/root/results, status "idle", error none, truncated false, hides results, forgets the cached results selection, and restores the folder list's selection. After this no cache exists. | useExplorerSearchController.ts:303-328 | T-985cc237 |
| B-SRCH-071 | Show Last Search Results (⇧⌘F, menu Edit > Show Last Search Results) is available only when a cached search exists and results are not already shown. | rendererCommandAvailability.ts:244-245; shortcuts.ts:358-363 | - |
| B-SRCH-072 | The ⇧⌘F key handler itself only requires that a cached search exists (`hasCachedSearch`); it works from any folder, regardless of where the search started. | useExplorerShortcuts.ts:508-518 | - |
| B-SRCH-073 | Showing cached results sets the field to the committed query, sets results visible, restores the cached results selection (paths no longer in the displayed results dropped), and with `focusPane` gives the content pane focus. | useExplorerSearchController.ts:229-245 | T-0d7af669 |
| B-SRCH-074 | If the walk was interrupted (results hidden while running, or tab cut off) or the hidden-files setting differs from the one the results were found with, showing them starts the same search again in `searchRootPath || currentPath`: the old results are cleared and the cached selection is lost; the pane is focused if requested. | useExplorerSearchController.ts:231-237 | - |
| B-SRCH-075 | When results are shown from another folder than where they were found (via ⇧⌘F), they show with their own root; the scope bar highlights a scope only if its path equals `searchRootPath`. | useExplorerSearchController.ts:238-246; App.tsx:2490-2494; SearchBar.tsx:58-62 | - |
| B-SRCH-076 | Esc in the tree or elsewhere than content pane or field does not hide results. | useExplorerShortcuts.ts:1605 | - |

## 6. Options menu (magnifier button)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-077 | The magnifier with a chevron at the left of the field is a menu button (accessible name "Search options", title "Search Options", haspopup menu, expanded state). | SearchOptionsMenu.tsx:260-290 | T-bb52ae88 |
| B-SRCH-078 | The menu content in order: heading "Match" with radio "Name" and "Full Path"; separator; heading "Match As" with radios "Plain Text", "Glob", "Regex"; separator; checkbox "Search Subfolders"; separator; checkboxes "Skip .git Folders" and "Skip Files Ignored by Git". Checkmarks show current values (`aria-checked`). | SearchOptionsMenu.tsx:219-255; appPreferences.ts:27-31 | T-bb52ae88 |
| B-SRCH-079 | There is no hidden-files item: search includes hidden files exactly when the file list shows them (`includeHidden`, ⇧⌘.). | SearchOptionsMenu.tsx:21, 232-255; useExplorerSearchController.ts:544 | T-bb52ae88 |
| B-SRCH-080 | Defaults of a launch: Plain Text, Name, Search Subfolders on, Skip .git Folders on, Skip Files Ignored by Git off. | appPreferences.ts:426-431 | - |
| B-SRCH-081 | Opening with the mouse (click with pointer detail) keeps keyboard focus in the field. Opening from the keyboard (detail 0, Return/Space on the button) focuses the first menu item once the menu is placed. | SearchOptionsMenu.tsx:272-282, 93-99 | T-bb52ae88, T-4fdb6b39 |
| B-SRCH-082 | The button's mouse-down and the menu's mouse-down are prevented, so clicking never moves focus out of the field. | SearchOptionsMenu.tsx:229, 271 | T-73242d97 |
| B-SRCH-083 | Choosing an item applies it, closes the menu and returns focus to the field (to the button if there is no field). | SearchOptionsMenu.tsx:186-190, 64-66 | T-73242d97 |
| B-SRCH-084 | The menu hangs below the search shell (anchor is the shell), 12 px margin, repositions on window resize, and is kept inside the window. | SearchOptionsMenu.tsx:68-91, 61 | - |
| B-SRCH-085 | While the menu is open its keys are handled in the capture phase and never reach the field's Esc handling or explorer shortcuts. Esc: closes the menu, returns focus to the field. Tab: closes, returns focus to the field. | SearchOptionsMenu.tsx:121-142 | T-4fdb6b39, T-89efb9bf |
| B-SRCH-086 | ArrowDown/ArrowUp move focus between items with wrap-around; with no item focused ArrowDown goes to the first, ArrowUp to the last. Home/End jump to first/last only when an item is focused. | SearchOptionsMenu.tsx:144-162 | T-4fdb6b39 |
| B-SRCH-087 | Return or Space on a focused item chooses it. Return with no item focused and focus not on the button just closes the menu (the form then submits the search). | SearchOptionsMenu.tsx:163-171 | T-4fdb6b39 |
| B-SRCH-088 | The menu closes without moving focus on a mouse-down elsewhere (not inside menu or button) and when the window loses focus (`blur`). | SearchOptionsMenu.tsx:111-120, 173-181 | T-ada18c17 |
| B-SRCH-089 | The off-screen measuring copy of the toolbar item (`interactive` false) never opens a menu and has no tab stop. | SearchOptionsMenu.tsx:262-284 | T-8b5cf7e7 |
| B-SRCH-090 | Changing any option while a committed search exists (results shown or cached) starts that search again at once with the new option, in `searchRootPath || currentPath`, without keeping old results (the list is cleared) and showing the results. With no committed search it only stores the option. | useExplorerSearchController.ts:661-709, 461-575 | T-73242d97 |
| B-SRCH-091 | The five options are per tab session and are not saved: the search options set in the field last for this run; the saved defaults come from Settings and apply to the next search (a Settings edit updates the live option values in an open window without re-running). | App.tsx:1717-1720, 1816-1827; useExplorerSearchController.ts:770-783 | - |
| B-SRCH-092 | A new tab starts with the pattern mode, scope, subfolders, Git options and sort of the search on screen when it was created. | useExplorerSearchController.ts:879-911 | - |
| B-SRCH-093 | Plain Text mode passes `--fixed-strings`; Glob passes `--glob`; Regex passes neither; Full Path passes `--full-path`; non-recursive passes `--max-depth 1`. | fdSearch.ts:84-95 | T-1fb059e6, T-43cff062 |

## 7. Scope bar (results bar)

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-094 | The results bar has a toolbar named "Search scope" with the label "Search:" and a segmented control of places; exactly the one whose path equals the search root is pressed. | SearchBar.tsx:50-72 | T-bccba4a0 |
| B-SRCH-095 | Scope options, in order, deduplicated by path (first wins): the open folder labelled with curly quotes (“name”), Home, the disk root of the open folder when it is not "/" (labelled by its name), and "/" labelled "Macintosh HD". | App.tsx:2930-2951 | - |
| B-SRCH-096 | Each scope button's tooltip is its full path. | SearchBar.tsx:60 | - |
| B-SRCH-097 | Clicking the already selected scope does nothing. Clicking another one starts the committed query again from that root (`changeSearchRoot`): results cleared at start, selection emptied, no old results kept. | SearchBar.tsx:63-67; useExplorerSearchController.ts:726-731 | T-bccba4a0 |
| B-SRCH-098 | Choosing a scope with no committed search or an empty path does nothing. | useExplorerSearchController.ts:726-731 | - |

## 8. Results list: order, columns, highlight, folder label, status line

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-099 | Results stream in arbitrary order and are shown sorted live by the chosen column and direction (default Folder/path ascending, saved preference); there is no explicit apply. | useExplorerSearchController.ts:116, 129-132; appPreferences.ts:431-432 | T-4802ec5b |
| B-SRCH-100 | New batches are appended in arrival order to the stored list (`appendSearchResults`); sorting is applied for display only and never mutates the stored array. | searchResults.ts:14-30 | T-920069db |
| B-SRCH-101 | Sort by "path" compares full paths with locale comparison, base sensitivity (case and accent-insensitive). | searchResults.ts:55 | T-4802ec5b |
| B-SRCH-102 | Sort by "name" compares names the same way, then paths as tie-breaker. Descending reverses the whole order. | searchResults.ts:38-43, 28-29 | T-bc11048e |
| B-SRCH-103 | Sort by "kind": folders (kind directory or symlink_directory) first; then files with an extension grouped by lower-cased extension (locale order); then files without an extension; each group by name then path. Packages (kind bundle) count as files with their extension. Descending reverses everything, so extensionless files lead. | searchResults.ts:44-68 | T-cbadd337 |
| B-SRCH-104 | Clicking a column header: the active sort column flips direction; a different sortable column starts ascending. Sortable columns: Name (name), Folder (path), Kind (kind); other columns do not sort. | useExplorerSearchController.ts:733-743; App.tsx:579-597 | - |
| B-SRCH-105 | Results' columns: Name first (default width 300), then the optional columns marked visible in Settings in their order (defaults: Folder 240 px, Modified, Size visible; Kind, Created, Permissions hidden); Folder width limited to 80..720. | App.tsx:579-596; appPreferences.ts:213-235 | - |
| B-SRCH-106 | The sort menu items and "Folders First" are not available in search mode (the results have their own order chosen in the headers); the toolbar Sort By button is disabled. | rendererCommandAvailability.ts:247-252; ExplorerWorkspace.tsx:1300-1305 | - |
| B-SRCH-107 | The Folder column shows the folder of the result relative to the search root joined with " › " ("src › lib"); a result directly in the root shows the root's name; root "/" shows "Macintosh HD" for root-level results; root trailing slashes are ignored. | searchResults.ts:119-129 | T-7d602a4b |
| B-SRCH-108 | Matched text in names is highlighted only for name scope with plain text or regex modes: case-insensitive unless the query contains an uppercase letter; plain text is escaped (so "c++" and "(1).pdf" highlight literally); glob mode, path scope, empty query and regex that JavaScript cannot parse are not highlighted. | searchResults.ts:99-117 | T-a2a3a813 |
| B-SRCH-109 | The status line shows `<N> result(s)`: singular when the total is 1. While running it is prefixed "Searching… ". When a filter hides some, it reads `<shown> of <total> results`. With selection it appends ` · <n> selected` and, when known, the size (`Calculating…` while computing). Parts are joined with " · ". | searchResults.ts:72-97; App.tsx:2471-2479 | T-88a11cc8, T-56a22bbc |
| B-SRCH-110 | The status line total counts the refined, sorted results (before the filter field), shown counts the filtered ones. | App.tsx:2471-2479; useExplorerSearchController.ts:135-146 | - |
| B-SRCH-111 | The path bar in search mode shows the selected result's path when exactly one result is selected; otherwise the search root. | App.tsx:2512-2515 | - |
| B-SRCH-112 | Rows load only the metadata the visible rows need, in batches per parent folder (`directory:getMetadataBatch`), each path requested once per (query, root). | App.tsx:1745-1778 | - |
| B-SRCH-113 | Every result is an entry with name, extension, kind, hidden and symlink flags (symlink always false). Packages show as single items (kind bundle). | explorerAppUtils.ts:655-664; fdSearch.ts:359-361 | T-502a84b4 |
| B-SRCH-114 | The tab view keeps result views separate: `viewKey` is `search:<root>:<committed query>`, so a new query or root is a new view (scroll resets to its own). | App.tsx:2516 | - |

## 9. Results bar: filter field, Stop, banner, empty states, errors

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-115 | The filter field narrows the results shown by name or by the folder (relative to the search root), case-insensitive substring, without searching again; placeholder "Filter by name or folder", accessible name "Filter results". Order is kept. | SearchBar.tsx:75-105; listFilter.ts:19-33 | T-6de3068b |
| B-SRCH-116 | The filter matches the result's `relativeParentPath` (folder relative to root; "." for root-level results), not the label shown in the Folder column; typing "." therefore matches every root-level result. | listFilter.ts:25-33; fdSearch.ts:353, 364 | - |
| B-SRCH-117 | Typing in the content pane while results are shown goes into the same filter text (the field mirrors it). Backspace erases one character, Esc clears the whole filter (and does not hide the results), Space counts as text within 1000 ms of the last character and otherwise is Quick Look. | useExplorerShortcuts.ts:803-826; useExplorerNavigationController.ts:598-630; listFilter.ts:6 | - |
| B-SRCH-118 | Every change to the filter selects one result: the first filtered result whose name starts with the text, else the first match; no match leaves the selection empty. | useExplorerNavigationController.ts:546-562; listFilter.ts:36-49 | T-96d467f3 |
| B-SRCH-119 | Esc in the filter field clears the filter if there is text; with the field empty it returns the keyboard to the results (content pane focused). Return and ArrowDown in the filter field also return focus to the results. | SearchBar.tsx:84-100 | T-6de3068b |
| B-SRCH-120 | A clear button (title "Clear Filter (Esc)", name "Clear filter") appears only when the filter has text; its mouse-down is prevented. | SearchBar.tsx:106-113 | T-6de3068b |
| B-SRCH-121 | The filter field keeps focus when the user clicks into it after a Return search; the caret is not stolen back by the results pane. | App.search.test.tsx:543-565 | T-24fd84fd |
| B-SRCH-122 | If a selection lead that is outside the filtered list but inside the unfiltered results appears (reveal, new selection from elsewhere), the filter is cleared so the selected item is visible. | useExplorerNavigationController.ts:664-683 | - |
| B-SRCH-123 | The filter is dropped when the folder, the kind of list (folder vs search), or the committed query changes; it is saved per tab and restored with the tab. | useExplorerNavigationController.ts:639-666; useExplorerTabs.ts:358-367 | - |
| B-SRCH-124 | A Stop button (accessible name "Stop search", title "Stop Search", spinner, label "Stop") appears only after the status has been "running" for 400 ms; it disappears when the search finishes. | SearchBar.tsx:10, 42-43, 115-125; useDelayedFlag.ts | T-5615383e |
| B-SRCH-125 | Stop cancels the live timer and the job; the status becomes "cancelled", the error is cleared, and the results found so far stay on screen. After Stop, longer text is no longer refinable (status "cancelled") and is searched afresh. | useExplorerSearchController.ts:291-301, 589 | - |
| B-SRCH-126 | If the user shows another tab's search before Stop finishes cancelling, the status is not changed (session counter check). | useExplorerSearchController.ts:293-297 | - |
| B-SRCH-127 | When the walk hit the 20,000 limit a banner reads "Showing the first 20,000 matches." below the bar. | SearchBar.tsx:135-137; fdSearch.ts:7 | T-2aaf9a83 |
| B-SRCH-128 | With no rows, the state view: error quiet → "Incomplete pattern" / "Keep typing, or press Return to see what is wrong with it."; error → "Search failed" plus the message; rows present → nothing; running → "Searching…"; results exist but filter hides all → `No results match “<filter>”` / "Nothing found has that in its name or folder. Press Esc to see all the results."; otherwise "No matches" / "Try other text, or another location above." Error takes precedence over rows. | SearchBar.tsx:144-204 | T-c08713b3, T-d8e16e8e |
| B-SRCH-129 | An error is "quiet" while the search was started by typing (`searchStartedLive`) and the mode is not plain text; Return (or any non-live start) shows the same error in full. Plain text never produces a quiet error. | App.tsx:2523; useExplorerSearchController.ts:525, 643, 646 | T-d8e16e8e |
| B-SRCH-130 | A search whose start request fails or whose poll fails ends with status "error" and the message (job cleared, polling stopped). | useExplorerSearchController.ts:407-420, 562-574 | - |

## 10. Running a search: polling, session counter, cancellation

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-131 | Starting a search first bumps a session counter, cancels the previous job, and abandons itself if another search started in the meantime. | useExplorerSearchController.ts:494-499 | T-c68ee1c1 |
| B-SRCH-132 | A start also: clears selection (empty), clears cached results selection, status "running", error none, truncated false, elapsed none, remembers the hidden-files setting used, sets results visible at once. | useExplorerSearchController.ts:515-533 | - |
| B-SRCH-133 | Polling starts at cursor 0 immediately after `search:start` answers, then repeats every 120 ms until the response says done. | useExplorerSearchController.ts:41, 560-561, 403-405 | - |
| B-SRCH-134 | An answer is ignored unless its session counter and job id are still current. | useExplorerSearchController.ts:346-348 | T-c68ee1c1 |
| B-SRCH-135 | On done, the job id is cleared and polling stops; the elapsed time is stored (not shown; a search that finished while its tab was in the background has none). | useExplorerSearchController.ts:388-402 | - |
| B-SRCH-136 | Results from the search that arrive while committed differs from base are filtered per B-SRCH-022. | useExplorerSearchController.ts:120-128 | - |
| B-SRCH-137 | Unmounting the window cancels its active job and timers. | useExplorerSearchController.ts:179-194 | - |
| B-SRCH-138 | Closing a tab (or all other tabs) cancels the search job of each closed tab. | useExplorerTabs.ts:519-523, 554, 567, 594, 605 | - |
| B-SRCH-139 | Changing the hidden-files setting while results are shown and were found with the other setting starts the same query again (the folder reload underneath does not close the results). If results are hidden, the next showing runs it again. | useExplorerSearchController.ts:196-206, 231; useExplorerNavigationController.ts:1765-1783 | - |
| B-SRCH-140 | ⌘R (menu View > Refresh, `refreshOrApplySearchSort`) in search mode runs the same search again (clearing results first); outside search mode it refreshes the folder. | useExplorerSearchController.ts:711-717; useExplorerShortcuts.ts:602-610, 1256-1261; shortcuts.ts:135-139 | - |
| B-SRCH-141 | After a write operation that completes at least one item, when it was started in the tab on screen from search results (or the tab is in search mode), the active search is run again so results reflect disk. The old results are cleared at that start. | useExplorerActions.ts:1128-1137 | T-636f3c2e |
| B-SRCH-142 | Items removed by another window or outside the app while results are shown also re-run the search. | useExplorerActions.ts:1480-1489 | - |
| B-SRCH-143 | Duplicate from results: one folder at a time; items from several folders show the toast "Duplicate items from one folder at a time". | useExplorerActions.ts:3379-3388 | - |
| B-SRCH-144 | The controller has no dependency on write-operation state: a search may be started, typed or refined while an operation is running. | useExplorerSearchController.ts:50-943 | - |
| B-SRCH-145 | Dropping a selection from the results onto the results list starts no copy/move (`copyPaste:analyzeStart` and `copyPaste:start` are not invoked); dragging from results to a tree folder does move. | App.search.test.tsx:567-584 | T-576bf206, T-636f3c2e |
| B-SRCH-146 | Folders in search results do not spring open under a held drag. | App.tsx:1301-1306 | - |

## 11. Working with results: open, reveal, selection

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-147 | Opening results (Return, double-click) always opens (never the edit-in-editor activation); a single folder result navigates into it (history push), which leaves search mode (B-SRCH-069); a package opens externally. More than the open-item limit (default 5) shows the limit notice. | useExplorerActions.ts:4340-4348, 3325-3343, 3229-3236; appPreferences.ts:424 | - |
| B-SRCH-148 | Reveal in Folder (context menu, File menu) is enabled in search mode with a selection; it closes the popover, blurs the field, navigates to the parent folder (replace if already there, else push), selects the item there and focuses the content pane. Nothing happens if navigation fails. | useExplorerActions.ts:2750-2766, 2862-2868; rendererCommandAvailability.ts:236-239 | - |
| B-SRCH-149 | Leaving search results notes nothing in the folder view memory (scroll/selection of the folder), because the results are not the folder. | useExplorerNavigationController.ts:1016-1020 | - |
| B-SRCH-150 | Starting a new search empties the selection of the results; a refinement empties it; changing option, scope, ⌘R and re-run empty it. | useExplorerSearchController.ts:533, 600-603 | - |
| B-SRCH-151 | Add to Favorites has no target in search mode (the favorite target resolves to null), so it is unavailable. | rendererCommandAvailability.ts:92-94 | - |
| B-SRCH-152 | Context menu on a result uses the surface "search". | App.tsx:2433 | - |

## 12. Tabs: one session per tab, background tabs

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-153 | Each tab has its own search session; only the tab on screen is live. Leaving a tab detaches its session (stops its timers and polling, keeps the job running in the worker, bumps the session counter so late answers are dropped). | useExplorerSearchController.ts:758-806; useExplorerTabs.ts:270-290 | - |
| B-SRCH-154 | A session holds: draft, committed and base queries, root, origin folder, pattern mode, match scope, recursive, skip-git options, sort column and direction, visibility, results, status, error, live flag, truncated, elapsed, job id, cursor, pending live text, kept paths, interrupted flag, hidden-files setting used, and both selections (folder list and results). | explorerTabs.ts:29-61; useExplorerSearchController.ts:770-800 | - |
| B-SRCH-155 | Showing a tab restores its session exactly (field text, options, sort, results, selections), closes the popover, and resumes polling from the saved cursor if a job is running. | useExplorerSearchController.ts:810-864 | - |
| B-SRCH-156 | Text typed in the field and still waiting for the 400 ms rest when the tab was left is searched for as if just typed, with a new 400 ms wait after the tab comes back. | useExplorerSearchController.ts:858-861, 767-768 | - |
| B-SRCH-157 | A search that was left before the worker answered `search:start` was cancelled on that answer; on return its status is "cancelled", flagged interrupted, and (if results are shown with a query) re-run. | useExplorerSearchController.ts:818-820, 843, 850, 870-874 | - |
| B-SRCH-158 | A re-run on return also happens when the session was interrupted, when the walk stopped short in the background with narrower committed text, or when the tab's hidden-files setting differs from the one the results were found with. It happens after the tab has been rendered. | useExplorerSearchController.ts:865-875; useExplorerTabs.ts:855-857 | - |
| B-SRCH-159 | While any background tab has a running job, each such tab is asked for an update every 1000 ms (one request per tab at a time); new results are appended, cursor, status, error and truncated updated, and a finished job is let go with no elapsed time. | useExplorerTabs.ts:46, 199-243, 883-895; explorerTabs.ts:271-299 | - |
| B-SRCH-160 | The answer is discarded if the tab was shown or closed meanwhile, or the job/cursor changed; if the tab is shown while an answer is on its way, the saved session is flagged `pollInFlight`. | useExplorerTabs.ts:211-227, 189-197 | - |
| B-SRCH-161 | If an answer was lost in flight and the next one says done with no items, the results are gone from the worker: the session is marked cancelled/interrupted (background) or a re-run is requested (foreground, first answer after return) instead of showing an empty list. | explorerTabs.ts:274-282; useExplorerSearchController.ts:349-359 | - |
| B-SRCH-162 | Items from a poll in a background tab skip paths in the kept set. | explorerTabs.ts:283-296 | - |
| B-SRCH-163 | A poll error in a background tab sets that session's job to none, status "error" with the message. | useExplorerTabs.ts:236-243 | - |
| B-SRCH-164 | A tab in search mode is labelled `“<query>” in <root name>` with the tooltip `Searching <root path>`, and shows a searching indicator while the status is "running"; labels of search tabs are not disambiguated. | explorerTabs.ts:141-163, 165-174, 307-320 | - |
| B-SRCH-165 | Duplicate Tab, Open in New Tab/Window, and a tab moved to a new window do not carry the search; the new tab shows the folder. Closed tabs reopen without their search. | useExplorerTabs.ts:615-632, 488-513, 662-690; explorerTabs.ts:112-122 | - |
| B-SRCH-166 | Showing a tab in search mode applies the saved results selection against an empty entry list (the list resolves it once results exist); in folder mode against the folder entries. | useExplorerTabs.ts:354-362 | - |
| B-SRCH-167 | Tab changes are refused while a dialog or sheet is open, a notice is up, or the explorer view is not shown. | useExplorerTabs.ts:391-396 | - |
| B-SRCH-168 | Each window (and tab) has its own search state; the runtime numbers jobs `search-1`, `search-2`, ... and each window cancels the job ids it started. | fdSearch.ts:111, 120 | - |
| B-SRCH-169 | The elapsed time is kept in the session and unused for display ("How long it took is for the log, not the window"). | searchResults.ts:70-71 | - |

## 13. Engine: fd arguments and job runtime

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-170 | fd is run with `--type f --type d --print0 --absolute-path --color never`: files and folders only; symbolic links are not found and `isSymlink` is false for every result. | fdSearch.ts:62-65, 361 | T-43cff062 |
| B-SRCH-171 | Without "Skip Files Ignored by Git", `--no-ignore` is passed; with it, fd's default ignore handling (ignore files inside Git repos) applies. | fdSearch.ts:66-70 | T-4db03fbc |
| B-SRCH-172 | "Skip .git Folders" passes `--exclude .git`. | fdSearch.ts:71-75 | T-4db03fbc |
| B-SRCH-173 | Searching "/" adds `--exclude /Volumes` (Macintosh HD alone); a disk root such as /Volumes/Backup or a deeper folder named Volumes is searched normally. | fdSearch.ts:77-82 | T-d1d5f835 |
| B-SRCH-174 | `--hidden` is passed only when hidden files are shown (`includeHidden`). Hidden means a leading dot. | fdSearch.ts:96-98, 361 | T-43cff062 |
| B-SRCH-175 | The pattern is passed after `--` (a query starting with "-" is a pattern), followed by the root path. The fd working directory is the resolved root. | fdSearch.ts:100-103, 119-124 | T-d3ef54f8 |
| B-SRCH-176 | Output is NUL-separated; a trailing slash marks a folder; trailing slash is removed from the path; folder is "bundle" if its name is a macOS package name, else "directory"; extension is the lower-cased extension of the name without dot. | fdSearch.ts:347-366 | T-502a84b4 |
| B-SRCH-177 | `relativeParentPath` is the parent folder relative to the root, "." for root-level items. | fdSearch.ts:353, 364 | T-c5416c0d, T-bf72fb90 |
| B-SRCH-178 | Entries split across stdout chunks are reassembled; an unterminated tail is flushed on close. | fdSearch.ts:240-266, 292-298 | T-850d45cb, T-bf72fb90 |
| B-SRCH-179 | `getUpdate(jobId, cursor)` returns the items from the cursor (clamped to 0..length), `nextCursor`, `done`, `truncated`, `error`, `status`; the final response carries all remaining items. | fdSearch.ts:155-193 | T-c5416c0d |
| B-SRCH-180 | After a job has been drained, later polls return an empty, done response with the same terminal status and a clamped cursor, instead of throwing; the last 64 finished jobs are remembered. | fdSearch.ts:47-57, 158-168, 224-238 | T-f6427548 |
| B-SRCH-181 | An unknown job id throws `Unknown search job: <id>`. | fdSearch.ts:170 | T-9db0e2f7 |
| B-SRCH-182 | Cancel: kills with SIGTERM, status "cancelled", done; cancelling a finished or unknown job is a no-op returning ok; later polls answer "cancelled" and done. | fdSearch.ts:195-210 | T-b00e33ee |
| B-SRCH-183 | At 20,000 items the job is marked truncated (status "truncated", done) and fd is killed with SIGTERM; items beyond are discarded. A search with exactly 20,000 matches is marked truncated. | fdSearch.ts:7, 276-285 | - |
| B-SRCH-184 | Exit code 0 is "complete"; any other exit code is an "error" with fd's message; a termination by a signal other than SIGTERM is an error "fd exited via signal <S>"; a process error event is an error with its message. | fdSearch.ts:287-325 | T-68fe0d57, T-3af83ea8, T-c942ad03 |
| B-SRCH-185 | The error text is fd's stderr without the "[fd error]:" prefix and without the closing "Note: ..." advice; if stderr is empty the text is "fd exited with code <n>". | fdSearch.ts:338-345, 320-324 | T-b3e43aa8 |
| B-SRCH-186 | Closing the runtime kills all running jobs and forgets all job records. | fdSearch.ts:212-222 | T-9db0e2f7 |
| B-SRCH-187 | The request schema requires non-empty `rootPath` and `query`; defaults: text, name, recursive, no hidden, skip .git, do not skip ignored. | ipc.ts:1076-1090 | - |

## 14. Edge cases and interactions

| ID | Behavior | Evidence | Test ids |
|---|---|---|---|
| B-SRCH-188 | ⌘F, ⇧⌘F and ⌘R do nothing while an action notice, a copy/paste dialog, the location sheet is open, or the main view is not the explorer. | shortcutPolicy.ts:310-317; useExplorerShortcuts.ts:1582-1584 | - |
| B-SRCH-189 | An alert (notice) swallows Esc and Return to dismiss itself: Esc does not hide search results while it is open. | useExplorerShortcuts.ts:1492-1500 | - |
| B-SRCH-190 | Keys whose target is a text field or select (inline rename field, filter field, search field) are not taken by the explorer's raw shortcuts: Esc in an open inline rename field does not hide results. | useExplorerShortcuts.ts:1528-1530 | - |
| B-SRCH-191 | Switching tab closes an open inline rename. | useExplorerTabs.ts:311 | - |
| B-SRCH-192 | When the window loses focus the options menu closes; the running search is not paused or cancelled. | SearchOptionsMenu.tsx:173-181 | - |
| B-SRCH-193 | A search that finds nothing (for example in an empty folder) completes normally and shows "No matches" with "Try other text, or another location above." (the folder list is not shown). | SearchBar.tsx:198-203 | - |
| B-SRCH-194 | Whatever fd reports through its exit code decides the outcome: exit 0 is a complete search, any other exit is an error that shows fd's text (B-SRCH-128, B-SRCH-185); the code does no permission handling of its own. | fdSearch.ts:315-325 | - |
| B-SRCH-195 | The Trash, favorites and tree selection are untouched by search; search results never replace the folder in `currentPath`, history or the tree. | useExplorerSearchController.ts:461-575 | - |
| B-SRCH-196 | A folder that is deleted or renamed while its results are shown is not specially handled by the search code; results remain until a re-run (B-SRCH-141 and B-SRCH-142). | useExplorerSearchController.ts (no handler) | - |

## Open questions

- Changing a search option (or ⌘R) while the results are hidden but a cached query exists runs `startSearch`, which sets the results visible again without restoring the field text (the field stays empty). Intended or an oversight? The Swift port should copy it unless told otherwise (useExplorerSearchController.ts:661-709, 461-575).
- `showCachedSearchResults` without `fromField` (⇧⌘F, menu) shows results from a folder other than the open one; the scope bar then has no pressed segment if the root is not among the open folder's scopes. No test covers this (useExplorerSearchController.ts:220-246, App.tsx:2930-2951).
- Metadata of results is dropped and re-requested on every refinement keystroke because it is keyed to the committed query (App.tsx:1735-1742). Likely incidental; kept as a rule (B-SRCH-039).
- The results filter matches `relativeParentPath` ("." for root-level results), so typing "." matches all root-level results (listFilter.ts:25-33). Likely incidental.
- What fd does with unreadable folders (exit code and stderr) is not decided in this repo; the bundled fd's behavior should be confirmed against the reference build before specifying the permission-error case.
- A folder deleted or renamed while its results are shown has no handling in the search code; whether the folder watcher or tab-follow logic changes the search root or origin was not traced (useExplorerTabs.ts:897+).
- Whether starting a search is blocked while an inline rename field is open was not found in the code; only tab switches close the inline rename (useExplorerTabs.ts:311).
- The search view mode default is "details" while a code comment in App.tsx:574-577 calls it "List"; confirmed by appPreferences.ts:395 but the UI label of "details" was not traced.
- The elapsed time of a search is stored but never displayed (searchResults.ts:70-71); confirm nothing else reads it before dropping it.
