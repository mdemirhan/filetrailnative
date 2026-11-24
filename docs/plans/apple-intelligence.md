# Apple Intelligence, on this Mac only: set aside

Set aside by the owner (2026-11-24), to be taken up again after [search-conditions.md](search-conditions.md). What was planned, what was built and where it is, and what was learned, so a later start doesn't begin from nothing.

## Where the work is

Branch `claude/apple-intelligence-parked`, commit `a3e62231`, on top of `27bf59ac`. It builds; its tests were not run after the parser's last rewrite, and `DescriptionParserTests` still expect the parser's earlier behavior. It is not to be landed as it is. It holds:

- **Search by description**, phase 1 below: `Sources/FTFoundation/Search/DescriptionParser.swift` (the parser), `DescribedSearch.swift` (`SearchFilters` and the parts a sentence is read into), `DescribedSearchReading.swift` (putting the model's labels together with what the parser read), `DescribedSearchText.swift` (the chips' wording, the "Not searched" line, the Settings status lines); `Sources/FTAppKit/Intelligence/` (availability, and the model's reader with its instructions and schema); `Sources/FTFileSystem/Search/DescribedItemCheck.swift` (per-item reads of what fd can't check) and fd's flags in `FdSearchArgs.swift`; `Sources/FTAppKit/Content/Search/DescribedSearchView.swift` (the chips and the yellow line); the session's reading in `SearchSession.swift`; the "Use Apple Intelligence" switch in Settings → General; Help, `features.md` and `privacy.md`.
- **Tests**: `DescribedSearchTests`, `DescriptionParserTests`, `DescribedSearchArgsTests`, `DescribedSearchJudgeTests`, `DescribedSearchSessionTests` (with a stand-in for the model) and `DescribedSearchModelTests` (the real model, with `FILETRAIL_MODEL_TESTS=1`).
- **The Rename sheet's preview listing every item**, not only the first 1,000: `BatchRenamePreviewView` measures a row's height once for each note, not each row (50,000 rows laid out in about 25 ms in a debug build), with its tests and the decision's wording. The owner asked for it (2026-11-24); it was set aside with the rest so search is the only work under way.

The search-conditions plan takes the condition model and the per-item reads from it; what is about descriptions and the model stays parked.

## What was planned

The model macOS runs on the Mac (Foundation Models, macOS 26 and later), never Apple's servers or another company's model: "No network connections" in [privacy.md](../privacy.md) and the App Store's "Data Not Collected" rule them out. Nothing read before it is asked for. What the model says is shown before it acts. Its answer is a structure the app defines (`@Generable`), never free text. One switch in Settings → General, no right-click menu items (the owner, 2026-11-24).

1. **Search by description.** A fourth Match As, Description: a sentence read on Return into chips, and a line saying what couldn't be searched.
2. **The viewer.** A summary of text, PDFs and documents; Live Text on every picture and scanned page (select any part of the text, not only Copy All; this needs no model); a one-line description of a picture (macOS 27).
3. **Rename from Contents**, a mode of the Rename sheet only: the model answers with facts read from each item (what it is, sender, title, date, amount), and the app puts the name together from the parts chosen, so changing them renames without reading again. A regular expression from words, in Replace Text and Regex search.

When it comes back, it comes on top of the conditions: the model's job is to fill in conditions the app already has, from the same list that builds the Add a Condition menu, so it can only ask for what the app can do, and what it gives is chips to look at and change before anything runs.

## What was learned

**Getting the model on a Mac.**

- Apple Intelligence must be on in System Settings, and the Mac's language must match Siri's: a Mac set to English (Turkey) with Siri in English (US) reported the model as not ready until the two matched. The model then downloads by itself, which can take a while; `SystemLanguageModel.default.availability` says `modelNotReady` meanwhile.
- `fm` in the Terminal talks to the same model and is the quickest way to try instructions. The model was "AFM 3 Core Advanced".
- macOS 27 has `LanguageModelError` (`.guardrailViolation`, `.refusal`, and the rest); `LanguageModelSession.GenerationError` is deprecated there, and a deprecation warning fails `scripts/ci.sh`, so the error is read behind `if #available(macOS 27, *)`. `GenerationOptions(samplingMode: .greedy)` gives the same answer to the same sentence, which tests need.
- Availability is `.available`, or unavailable for `.deviceNotEligible`, `.appleIntelligenceNotEnabled` or `.modelNotReady`; Settings showed each in its own words, with a button to System Settings (`x-apple.systempreferences:com.apple.Siri-Settings.extension`) when it was turned off.

**The model is poor at filling a form and good at naming short phrases.** A first design had the model fill every filter of a search from the sentence. On 32 sentences it guessed kinds ("document" for "files"), dropped dates, invented a picture kind for "files larger than 1 MB", called ordinary words unsearchable, and warned about contents for "documents larger than …". A schema phrase by phrase and one of slots did no better. What worked: File Trail's own parser reads everything a list of words can know (sizes, dates and which date, kinds, extensions, tags, attributes, names after "named" or in quotes, folders to leave out), and only the phrases it leaves go to the model, with the whole sentence for context, to be labelled. That read all 32 sentences right. A sentence the parser reads whole never reaches the model, and is searched at once.

**The parser is most of the work, and English is endless.** The owner's own tries found gaps the 32 sentences didn't: "all file names containing trail or file or notes" lost "file" (a word every request has, taken for filler); "documents newer than 2 days old" and "files older than 2 hours" (comparisons, and hours); "pictures larger than 1024px" (pixels, read as bytes). Each was fixed in the parser, and each showed that a fixed grammar posing as English always has another gap. That is why a parser-only Description mode was dropped (the owner, 2026-11-24): without a model there to catch what it misses, it promises English and gives a grammar. The parser stays useful as the first step in front of a model. Rules it came to: a phrase the parser can't read but that holds a number or a unit ("1024 dpi") is said to be not understood, never guessed at; a bare word is a name's word; phrases split at "and", "or", commas and where a clause starts ("contracts | with Acme").

**Searching by description.** Typing doesn't search as it goes in Description; Return reads the sentence. The search field widens to 380 pt while it has the keyboard and scrolls with the caret: that part was useful on its own and landed (`27bf59ac`).

## The model's instructions and schema, as last used

The instructions (each sentence's session is new, with greedy sampling):

```text
File Trail searches a Mac's files by: words in the name, kind (PDF, picture, video, audio, document, spreadsheet,
presentation, archive, code, text, folder, application), extension, size, date (modified, created, added, last
opened, taken), Finder tags, attributes (hidden, executable, read-only, writable, locked, empty, alias, symbolic link)
and folders to leave out. It has already read those parts of the request. You get the phrases it couldn't read, with
the whole request for context.

For each phrase, choose its meaning:
- nameWords: words that would be written in the file's name, such as "invoices", "budget" or "wedding". Give the main
word in its singular form, then up to two close alternatives.
- contents: what is written inside the file, such as "that mention the lease".
- pictureContents: what a picture or video shows, such as "of the beach".
- people: who made, sent or shared it, such as "from Sam".
- origin: where it came from, such as "from Safari" or "that I got on WhatsApp".
- nothing: words that ask for nothing.
```

The prompt: `Request: <sentence>` and, on the next line, `Phrases: "<phrase>", "<phrase>"`.

The answer:

```swift
@Generable(description: "What each leftover phrase of a file search asks for")
struct ModelReading {
    @Guide(description: "One entry for each phrase given, in the same order")
    var phrases: [ModelPhrase]
}

@Generable
struct ModelPhrase {
    @Guide(description: "The phrase, copied exactly")
    var phrase: String
    var meaning: ModelMeaning
    @Guide(
        description: "For nameWords only: words a matching file name would contain, the main word first, then up to two close alternatives. Empty otherwise.",
        .maximumCount(3))
    var nameWords: [String]
}

@Generable
enum ModelMeaning { case nameWords, contents, pictureContents, people, origin, nothing }
```

The examples in the instructions are not among the sentences the model is judged by, so a pass measures what it understood rather than what it copied. The model's answers are matched to phrases by their text, and otherwise to the next phrase not yet matched.

## The sentences it was judged by

Each with what it should be read as; all 32 passed with the parser and the labels, before the owner's later tries above:

- "files larger than 1 MB", "files larger than 2 mb": size over 1 or 2 MB, nothing else.
- "documents larger than 1 mb": Document, over 1 MB. "anything under 10 KB": under 10 KB.
- "pdfs"; "big pdfs": PDF over 100 MB; "big pdfs from this month that mention the lease": PDF, over 100 MB, modified, and "lease" not searched.
- "screenshots from this week": Picture, the word Screenshot, modified. "photos of my dog": Picture, "dog" not searched.
- "invoices from last month": the word invoice, modified. "videos older than a year": Video, modified.
- "spreadsheets changed in the last 3 days, not in node_modules": Spreadsheet, modified, skipping node_modules.
- "folders named backup", "zip files", "swift files" (the extension), "budget spreadsheets", "music" (Audio).
- "presentations from Anna": Presentation, "Anna" not searched. "things I changed today": modified.
- "files named report", "my resume": the word only.
- "apps I haven't opened in a year": Application, last opened before a year ago. "hidden files". "files tagged red".
- "photos taken in March": Picture, taken. "pdfs I downloaded last week": PDF, added.
- "empty folders", "scripts I can run" (Code, executable), "read-only documents created this year".
- "wedding photos from last summer": Picture, the word wedding, modified.
- "contracts with Acme about pricing": the word contract, "pricing" not searched. "pictures I got on WhatsApp": Picture, "WhatsApp" not searched.
