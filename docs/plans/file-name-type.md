# Plan: a type for names, with no `==` (to be investigated first)

**Status:** not started, and not decided. Written on 2026-11-21 for whoever carries it out, person or agent. It comes after [one-path-type.md](one-path-type.md) is done; read that plan and the code it left before this one.

**This may not be worth doing.** The first part of the work is an investigation whose honest outcome can be "leave names as they are" or "a lint is enough". Do that part, write up what was found with a recommendation, and stop for the owner's answer. Nothing in the second part is started before it.

## The idea

A path has one right way to be compared: by its bytes. A name has two, and which is right depends on the question.

- **"Is this the same directory entry?"** By bytes. Two names that differ only in how an accent is encoded, or only in letter case on a disk that keeps case, are two entries.
- **"Would this name clash with that one in this folder?"** As the folder's disk compares names: it may ignore case, and it may take the composed and decomposed spellings of an accent for one name. The rule differs per disk (APFS, case-sensitive APFS, HFS+, exFAT, FAT, network shares).

Swift's `String` gives a third answer: equal when canonically equivalent, case kept. It is right for neither question, and it is what `==`, `hasPrefix`, `Set<String>` and `[String: X]` use. So a name held as a `String` can be compared wrongly without anything looking wrong.

The proposal: a type for names (say `FileName`) that has **no `==` and is not `Hashable`**, so every comparison has to say which question it is asking: `isSameEntry(as:)`, or `clashes(with:in:)` with the folder's rules, or an explicit key for a set or a dictionary. Giving it byte equality, as `DiskPath` has, was considered and is not proposed: it would make the clash question wrong by default.

## Why it might not be worth it

Say so plainly in the findings if these hold.

- **Names are text far more than paths are.** They are typed, trimmed, validated, split at the extension, numbered, transformed by the Rename sheet, measured and drawn. A type means unwrapping at all those places, and each unwrap is a place the rule can leak again.
- **The exact and the folded comparisons already have homes**: `NameKeys.Exact`, and `NameKeys.nameKey` / `looseKey` / `placeKey` / `destinationPathKey` / `namesMatchIgnoringCase`. If nearly every comparison of names already goes through them, a type adds ceremony and prevents little.
- **A lint may catch what is left** at a hundredth of the cost.
- **The harder problem may be elsewhere**: whether the app's model of each disk's folding is right at all (see "Known faults" below). A type centralises where the folding is asked for; it does not make the folding correct.

## Part 1: the investigation

Read-only. No source changes, no builds needed beyond what the measurements take. Deliver a document (`docs/records/file-name-type-findings.md`, or a section added to this plan) with the numbers, the lists and a recommendation.

### 1. Every place a name is compared or used as a key

Over `Sources/`, by module (FTFoundation, FTFileSystem, FTOperations, FTAppKit). A name here is one path part: what `DiskPath.name` and `NodePath.basename` return, an entry's `name`, what a person types in a rename, a `destinationName`, a template's or an archive's name.

For each site record: file and line, what is compared, and which question it is asking:

| Class | Meaning |
|---|---|
| exact | the same entry, by bytes |
| folded | a clash, as the disk compares |
| shown | order or text for a person (sorting, type-to-select, filtering, highlighting): the collator's or the matcher's rules, not identity |
| text | an operation on the name as text (extension, numbering, trimming, a pattern) |
| other | not a file name after all |

And how it is done today: through `NameKeys.Exact`; through a folding key; raw (`==`, `!=`, `hasPrefix`, `hasSuffix`, `contains`, `Set<String>`, `[String: X]`, `firstIndex(of:)`, `sorted()`, `<`); or through another helper (list them: `sameAfterNFC` in the Rename sheet's planning, `JSString.equals`, `JSText.lowercased`, `ItemNames`, `InlineRenameRules`, `NumberedNames`, `CopyPasteNames`).

Give counts per module and class, and **list every raw site of class exact or folded**. Those are the ones a type would change.

### 2. For each raw site: is it wrong today?

Decide which question it should be asking and whether the raw comparison gives a wrong answer in a case a person could meet. For each one that does, write the scenario (the disk, the two names, what the person does, what goes wrong) and whether it was reproduced or only read. A site that is right only because the names it sees are always ASCII or always come from one listing is "right by its inputs": list it apart.

### 3. Known faults to check against

From `docs/records/file-operations-review.md` and the work since; confirm each is still so, and say whether a name type would have prevented it, made it easier to fix, or changed nothing:

- A case-only rename the disk takes for the same name is refused as "already exists" (Greek `ΦΩΣ` to `φως`, `straße` to `STRASSE`): the app's fold is narrower than APFS's and exFAT's.
- On exFAT a case-only batch rename of a name containing Σ is reported as gone though it happened.
- The Rename sheet's preview lowercases where APFS folds fully (ß and ss), so the preview and the run can disagree.
- Replace Text recomposes the untouched part of a name.
- Inline rename drops a change that is only the accent's encoding, because it compares with `==`.
- Name-keyed caches that hold display text (`CompactListViewController.nameWidths`, `IconLabelText.fitted`): two spellings share one measured width. Harmless or not?
- `FolderWatches`' changed names, `changedNameSet`.
- HFS+ stores an accent decomposed whatever was asked, so the name a write asked for is not the name on disk.
- FAT and exFAT list every name decomposed but answer to an item by the spelling it was made or first looked up by since the disk was mounted ([one-path-type.md](one-path-type.md), "A disk whose listing and lookup disagree"): the name a folder's reading gives is asked of the disk, name by name.

### 4. What a type would cost

- How many stored fields, parameters and return values hold a name as a `String` (identifiers `name`, `…Name`, `…Names`; subtract what is not a file name: an app's display name, a person's name, a preset's name).
- How many sites treat a name as text (class "text" above) and would unwrap.
- Which `Codable` forms and goldens hold names (`batch-rename-*.json`, `keep-both-names.json`, `number-names.json`, `item-name-validation.json`, `fit-name.json` and others): a bare-string encoding must leave them byte for byte.
- Test files touched.
- Whether `DiskPath.name` and `DiskPath.appending(_:)` would take and return the type, and what that does to the path code just converted.

### 5. The alternatives, side by side

For each: what it prevents (count the sites from sections 1 and 2), what it costs (section 4), what it leaves open.

1. **Leave it.** Names stay `String`; the rule stays written in `docs/process/paths.md`.
2. **A lint only.** `scripts/ci.sh` fails on `==`, `!=`, `Set<String>` and `[String:` over identifiers named as names outside the helpers, with an allow-list. Try it: write the pattern and run it over `Sources/` as it is, and report how many hits are real, how many false, and whether the false ones can be told apart.
3. **A type at the keys only.** What exists: `NameKeys.Exact` for exact keys, the folding keys for clashes, plus the lint of 2 to keep raw comparisons out.
4. **The full type with no `==`.** As in Part 2.
5. **A type with byte `==`** (as `DiskPath`). Say why this is or is not as bad as claimed above, with the count of folded comparisons it would make wrong by default.

### 6. Is the folding itself right?

A type gives one place to ask "do these clash here?". Look at what that place would have to know and whether the app knows it:

- What the app has per folder today (`caseSensitive`, `isCaseSensitive`, `usesAppleDouble`) and where it comes from.
- What each disk really does (the earlier review probed APFS, case-sensitive APFS, HFS+, exFAT and FAT32 images; `DiskImage` in `Tests/FTTestSupport` mounts them): case folding (simple or full), normalisation on store and on lookup, length limits in UTF-16 units.
- Whether **asking the disk** is the more truthful answer where it matters: looking the candidate name up in the folder and comparing the entry's id with the item's own tells a clash from a rename onto itself with no model of the disk's rules at all (`RenameOperation` already does a version of this). Where a preview must answer without the disk (the Rename sheet's plan over thousands of names), a model is unavoidable: say how far the current one is from each disk.

This section may be the most useful result even if no type is built.

### 7. The recommendation

Give one, with the numbers behind it. A fair bar:

- **Build the type** if the raw exact-or-folded sites are many (dozens, across modules), several are wrong in a way a person meets, and the lint cannot tell them apart from text operations.
- **Lint only** if the raw sites are few or nearly all right by their inputs, and the pattern has few false hits.
- **Leave it** if nearly everything already goes through the helpers and the lint would mostly flag text operations.

Whatever the answer, list the faults found in section 2 as findings in the form of `docs/process/reviews.md` (they can be fixed without any type), and say which of them the recommendation would and would not have prevented.

**Stop here.** Give the owner the findings and the recommendation. Part 2 is carried out only if the owner chooses the type.

## Part 2: the type, if the owner chooses it

A sketch to start from; the investigation will correct it.

### Shape

- `FileName` in `Sources/FTFoundation`, a struct over a `String` held as contiguous UTF-8, `Sendable`, `Codable` as the bare string, a string literal for tests, `text` for showing and editing.
- **No `Equatable`, no `Hashable`, no `Comparable`.** Instead:
  - `isSameEntry(as:)`: by bytes.
  - `exactKey` (`NameKeys.Exact`) for a set or a dictionary of entries.
  - `clashes(with:in:)` and `foldedKey(in:)`, taking the folder's rules (a small value: case-sensitive or not, how it normalises), which replace the scattered folding keys.
  - Sorting stays with the collator (`NaturalOrder`, `ICUCollator`), which takes `text`.
- Where a name is born: a listing, `DiskPath.name`, `nameOnDisk`, what a person typed after `ItemNames`' validation, a name the app makes (`NumberedNames`, `CopyPasteNames`), decoding.
- `DiskPath.name` returns it and `DiskPath.appending(_:)` takes it.

### Things to be aware of

- **The Rename sheet** works on names as text end to end (find and replace, patterns, case changes, numbering, dates). Keep `text` as its working form and wrap at its edges; do not thread the type through the transformations.
- **The extension**: the last dot only; none for a folder, for `.env` or for `a.`; packages keep theirs. `splitItemName`, `NodePath.extname`.
- **Validation and trimming** (`ItemNames`, `InlineRenameRules`): empty, `.`, `..`, `/`, NUL, 255 UTF-16 units; trimming happens before every comparison today. Decide whether a `FileName` can hold an invalid or untrimmed name (typed text in mid-edit is a `String`, not a `FileName`).
- **Slicing by `Character`**: `name.hasPrefix(".")` and its kin are by `Character`, so a name starting with a combining mark behaves oddly. Path and name arithmetic is by bytes or scalars.
- **Case-only and encoding-only renames**: the destination "clashes" with the item itself. The rule that tells this from a real clash is by entry id, not by name; keep it where it is.
- **A disk that respells** (HFS+): the name asked for is not the name stored. After a write, the name on disk is the listing's.
- **`._name` companions** on FAT and exFAT (`CopyPasteNames.isAppleDoubleCompanionName`): matched by name against a sibling.
- **Names shown are not names stored**: a `:` in a name is shown as `/` in places; `displayPath`; kind and extension hiding. The type is the stored name.
- **Goldens and saved formats** must not change; the Undo types and the journal keep their hand-written `Codable`.
- **A name that is not valid UTF-8** is repaired on listing and cannot be addressed. Out of scope; do not make it worse.

### Order, tests, conventions, done

Follow [one-path-type.md](one-path-type.md): by family, each step green and committed, borders marked and removed, the full check at the end of each step, no golden changed. Add to `docs/process/paths.md` a section on names (which question, which call), extend the lint guards to names, and keep the accent and twin suites green, adding to them: two names that differ only in case on a case-sensitive image; a case-only and an encoding-only rename on each disk image; a clash judged by each disk's rule against what the disk itself does.

It is done when no name is compared except through the type's named calls or a listed exception with its reason, the guards and their tests are in `scripts/ci.sh`, `scripts/ci.sh --full` and the release-only tests pass, and a report in the form of `docs/process/reviews.md` says what was done, what was checked and how, and what was left.

## How to work in this repository

As in [one-path-type.md](one-path-type.md), "How to work in this repository": a worktree of its own, commits there and never on `main`, one test run at a time, goldens untouched, comments on the app's own terms, and the owner asked what is the owner's to say. Part 1 changes nothing in `Sources/`; if it writes scratch probes, they stay out of the repository.
