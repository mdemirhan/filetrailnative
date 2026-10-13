// The reference's paste analysis (tools/parity/exec/analysis.ts) on hand-picked trees from
// file-operations.md §2 and §7 A–C: conflict classes, packages, links, case and normalization,
// pastes into themselves, nested picks, blocked Replaces, locked and unreadable items, Keep Both
// names, destination-only counts, warnings, and per-item overrides.
// Input: the scenario. Output: report, choices, resolution (see analysis.ts).

import type { GoldenCase } from "../lib/golden";
import {
  ADD_MISSING,
  KEEP_ALL,
  REPLACE_ALL,
  SKIP_ALL,
  type Scenario,
  type ScenarioItem,
  analysisCases,
  dir,
  file,
  link,
  scenario,
} from "../exec/scenarios";

export const seed = 0;

const INTO = { destination: "destination" };
const NFC = "Café";
const NFD = "Café";

const copy = (name: string, tree: ScenarioItem[], sources: string[], policy = REPLACE_ALL, destination = "destination") =>
  scenario(name, tree, { sources, destination }, { policy });
const cut = (name: string, tree: ScenarioItem[], sources: string[], policy = REPLACE_ALL, destination = "destination") =>
  scenario(name, tree, { mode: "cut", sources, destination }, { policy });

// More than 100 items: the large batch warning.
const manyFiles = Array.from({ length: 120 }, (_, index) => file(`source/many/f${String(index).padStart(3, "0")}.txt`, "x"));

const cases: Scenario[] = [
  copy("a new file into an empty folder", [file("source/a.txt"), dir("destination")], ["source/a.txt"]),
  copy("a new folder tree into an empty folder", [file("source/f/a.txt"), file("source/f/g/b.txt"), dir("destination")], ["source/f"]),
  copy("file over file", [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n")], ["source/a.txt"]),
  copy("file over file, skipped", [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n")], ["source/a.txt"], SKIP_ALL),
  copy("file over file, kept both", [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n")], ["source/a.txt"], KEEP_ALL),
  copy(
    "folder over folder with nested conflicts",
    [
      file("source/f/a.txt"),
      file("source/f/g/b.txt"),
      file("source/f/g/new.txt"),
      file("destination/f/a.txt"),
      file("destination/f/g/b.txt"),
      file("destination/f/g/only.txt"),
    ],
    ["source/f"],
    ADD_MISSING,
  ),
  copy("folder over folder, replaced", [file("source/f/a.txt"), file("destination/f/b.txt")], ["source/f"]),
  copy("folder over folder, kept both", [file("source/f/a.txt"), file("destination/f/b.txt")], ["source/f"], KEEP_ALL),
  copy("file over folder: type mismatch", [file("source/x"), file("destination/x/in.txt")], ["source/x"]),
  copy("folder over file: type mismatch", [file("source/x/in.txt"), file("destination/x")], ["source/x"], KEEP_ALL),
  copy("link over file: type mismatch", [link("source/x", "target"), file("destination/x")], ["source/x"]),
  copy("link over link: file conflict", [link("source/x", "new"), link("destination/x", "old")], ["source/x"]),
  copy("link to a folder over a folder: type mismatch", [dir("source/real"), link("source/x", "real"), dir("destination/x")], ["source/x"]),
  copy(
    "package over package: a file conflict, never merged",
    [file("source/Tool.app/Contents/Info.plist"), file("destination/Tool.app/Contents/Info.plist")],
    ["source/Tool.app"],
    ADD_MISSING,
  ),
  copy(
    "package over a plain folder: a file conflict",
    [file("source/Talk.key/Index.zip"), file("destination/Talk.key/plain.txt")],
    ["source/Talk.key"],
    KEEP_ALL,
  ),
  copy(
    "a document package kept both keeps its extension last",
    [file("source/Notes.rtfd/TXT.rtf"), file("destination/Notes.rtfd/TXT.rtf")],
    ["source/Notes.rtfd"],
    KEEP_ALL,
  ),
  copy(
    "a folder with an extension that isn't a package is merged",
    [file("source/Movie.fcpxbundle/a"), file("destination/Movie.fcpxbundle/b")],
    ["source/Movie.fcpxbundle"],
    KEEP_ALL,
  ),
  copy(
    "a package inside a merged folder is replaced whole",
    [file("source/f/Tool.app/Contents/new"), file("destination/f/Tool.app/Contents/old"), file("destination/f/x.txt")],
    ["source/f"],
    { file: "overwrite", directory: "merge", mismatch: "skip" },
  ),
  copy("copy into its own folder: Keep Both name", [file("folder/a.txt")], ["folder/a.txt"], SKIP_ALL, "folder"),
  copy(
    "copies of copies numbered, look-alikes untouched",
    [file("folder/x copy.txt"), file("folder/copy.txt"), file("folder/draft copy 1.txt"), file("folder/a copycat.txt"), file("folder/big copy 99999")],
    ["folder/x copy.txt", "folder/copy.txt", "folder/draft copy 1.txt", "folder/a copycat.txt", "folder/big copy 99999"],
    KEEP_ALL,
    "folder",
  ),
  copy(
    "Keep Both of .tar.gz and of a folder with a dot",
    [file("source/archive.tar.gz"), file("destination/archive.tar.gz"), file("source/v1.2/a"), file("destination/v1.2/b")],
    ["source/archive.tar.gz", "source/v1.2"],
    { file: "keep_both", directory: "keep_both", mismatch: "keep_both" },
  ),
  copy(
    "Keep Both names reserved across siblings",
    [file("source/a.txt"), file("source/a copy.txt"), file("destination/a.txt"), file("destination/a copy.txt")],
    ["source/a.txt", "source/a copy.txt"],
    KEEP_ALL,
  ),
  copy(
    "Keep Both of a 250-byte name fits it in 255 bytes",
    [file(`source/${"n".repeat(246)}.txt`), file(`destination/${"n".repeat(246)}.txt`)],
    [`source/${"n".repeat(246)}.txt`],
    KEEP_ALL,
  ),
  copy(
    "Keep Both of a name with an absurdly long extension",
    [file(`source/a.${"e".repeat(250)}`), file(`destination/a.${"e".repeat(250)}`)],
    [`source/a.${"e".repeat(250)}`],
    KEEP_ALL,
  ),
  copy(
    "Keep Both truncates by whole graphemes",
    [file(`source/${"👩‍👩‍👧‍👦".repeat(10)}${"é".repeat(40)}.txt`), file(`destination/${"👩‍👩‍👧‍👦".repeat(10)}${"é".repeat(40)}.txt`)],
    [`source/${"👩‍👩‍👧‍👦".repeat(10)}${"é".repeat(40)}.txt`],
    KEEP_ALL,
  ),
  copy("destination missing", [file("source/a.txt")], ["source/a.txt"], REPLACE_ALL, "nowhere"),
  copy("destination is a file", [file("source/a.txt"), file("destination")], ["source/a.txt"]),
  copy("source missing", [dir("destination")], ["source/gone.txt"]),
  copy("a folder into itself", [file("source/f/sub/a.txt")], ["source/f"], REPLACE_ALL, "source/f"),
  copy("a folder into its own descendant", [file("source/f/sub/a.txt")], ["source/f"], REPLACE_ALL, "source/f/sub"),
  copy(
    "a folder into its own descendant through a link",
    [file("source/f/sub/a.txt"), link("inside", "source/f/sub")],
    ["source/f"],
    REPLACE_ALL,
    "inside",
  ),
  copy(
    "a folder into its own descendant spelled in another case",
    [file("source/f/sub/a.txt")],
    ["source/f"],
    REPLACE_ALL,
    "SOURCE/F/Sub",
  ),
  copy("a destination given as a link to a folder is followed", [file("source/a.txt"), file("real/a.txt"), link("destination", "real")], ["source/a.txt"]),
  copy("two sources land on one name", [file("one/x.txt"), file("two/x.txt"), dir("destination")], ["one/x.txt", "two/x.txt"]),
  copy("two sources land on one name differing in case", [file("one/x.txt"), file("two/X.txt"), dir("destination")], ["one/x.txt", "two/X.txt"]),
  copy(
    "two sources land on one name differing in normalization",
    [file(`one/${NFC}.txt`), file(`two/${NFD}.txt`), dir("destination")],
    [`one/${NFC}.txt`, `two/${NFD}.txt`],
  ),
  copy("a name differing only in case conflicts", [file("source/README.md"), file("destination/readme.md")], ["source/README.md"]),
  copy("a name differing only in normalization conflicts", [file(`source/${NFC}.txt`), file(`destination/${NFD}.txt`)], [`source/${NFC}.txt`]),
  copy(
    "Replace blocked for the folder holding the item pasted: Merge instead",
    [file("a/f/f/inner.txt"), file("a/f/other.txt")],
    ["a/f/f"],
    REPLACE_ALL,
    "a",
  ),
  copy(
    "Replace blocked for a file holding the item pasted's name: Keep Both instead",
    [file("a/f/x"), file("a/x")],
    ["a/f/x"],
    REPLACE_ALL,
    "a",
  ),
  copy(
    "Replace blocked for a folder holding another item pasted",
    [file("source/f/a.txt"), file("destination/f/g.txt")],
    ["source/f", "destination/f/g.txt"],
  ),
  copy(
    "Replace blocked for a folder holding another item pasted, in another case",
    [file("source/f/a.txt"), file("destination/f/g.txt")],
    ["source/f", "destination/F/g.txt"],
  ),
  copy("nested picks: an item picked with its folder", [file("source/f/a.txt"), file("source/f/b.txt"), dir("destination")], ["source/f", "source/f/a.txt"]),
  copy(
    "destination-only items counted, dotfiles and links too, .DS_Store not",
    [
      file("source/f/a.txt"),
      file("destination/f/a.txt"),
      file("destination/f/.hidden"),
      file("destination/f/.DS_Store"),
      link("destination/f/link", "a.txt"),
      file("destination/f/g/h/deep.txt"),
      dir("destination/f/empty"),
      file("destination/f/one"),
      file("destination/f/two"),
      file("destination/f/three"),
    ],
    ["source/f"],
  ),
  copy("an empty destination folder counts 0", [file("source/f/a.txt"), dir("destination/f")], ["source/f"]),
  copy(
    "a destination folder that can't be read: counts unknown",
    [file("source/f/a.txt"), file("destination/f/g/x.txt"), dir("destination/f/g", { mode: "0000" })],
    ["source/f"],
  ),
  copy(
    "a folder a pasted file would replace counts as lost entirely",
    [file("source/x"), file("destination/x/a"), file("destination/x/b/c")],
    ["source/x"],
  ),
  copy(
    "a source .DS_Store is left out when the destination has one",
    [file("source/f/.DS_Store", "src"), file("source/f/a.txt"), file("destination/f/.DS_Store", "dst")],
    ["source/f"],
    ADD_MISSING,
  ),
  copy("a source .DS_Store is copied when the destination has none", [file("source/f/.DS_Store", "src"), dir("destination/f")], ["source/f"], ADD_MISSING),
  copy("more than 100 items: large batch", [...manyFiles, dir("destination")], ["source/many"]),
  copy(
    "a locked file over a locked file",
    [file("source/a.txt", "new\n", { flags: ["uchg"] }), file("destination/a.txt", "old\n", { flags: ["uchg"] })],
    ["source/a.txt"],
  ),
  copy(
    "a read-only folder over a folder",
    [file("source/f/a.txt"), dir("source/f", { mode: "0555" }), file("destination/f/b.txt")],
    ["source/f"],
    ADD_MISSING,
  ),
  copy(
    "an unreadable folder inside a pasted folder",
    [file("source/f/ok.txt"), file("source/f/closed/x.txt"), dir("source/f/closed", { mode: "0000" }), dir("destination")],
    ["source/f"],
  ),
  copy("an unreadable folder picked itself", [file("source/closed/x.txt"), dir("source/closed", { mode: "0000" }), dir("destination")], ["source/closed"]),
  copy("an unreadable file", [file("source/secret.txt", "s", { mode: "0000" }), file("destination/secret.txt")], ["source/secret.txt"]),
  cut("cut a file on its own disk", [file("source/a.txt"), dir("destination")], ["source/a.txt"]),
  cut("cut a folder on its own disk is renamed whole, unread", [file("source/f/a.txt"), file("source/f/g/b.txt"), dir("destination")], ["source/f"]),
  cut("cut into its own folder: the same item", [file("folder/a.txt")], ["folder/a.txt"], REPLACE_ALL, "folder"),
  cut("cut a folder into a folder: merged item by item", [file("source/f/a.txt"), file("source/f/n.txt"), file("destination/f/a.txt")], ["source/f"], ADD_MISSING),
  cut("cut a folder over a folder, replaced", [file("source/f/a.txt"), file("destination/f/b.txt")], ["source/f"]),
  cut("cut a link", [link("source/l", "somewhere"), dir("destination")], ["source/l"]),
  cut("cut a locked file", [file("source/a.txt", "x", { flags: ["uchg"] }), dir("destination")], ["source/a.txt"]),
  cut("cut a folder into itself", [file("source/f/sub/a.txt")], ["source/f"], REPLACE_ALL, "source/f/sub"),
  cut("cut two sources onto one name", [file("one/x.txt"), file("two/x.txt"), dir("destination")], ["one/x.txt", "two/x.txt"]),
  scenario(
    "per-item overrides: Keep Both and Replace inside a merge, Merge on a file ignored",
    [
      file("source/f/a.txt"),
      file("source/f/b.txt"),
      file("source/f/c.txt"),
      file("destination/f/a.txt"),
      file("destination/f/b.txt"),
      file("destination/f/c.txt"),
    ],
    { sources: ["source/f"], ...INTO },
    {
      policy: ADD_MISSING,
      overrides: [
        { nodeId: "item-1/a.txt", action: "keep_both" },
        { nodeId: "item-1/b.txt", action: "overwrite" },
        { nodeId: "item-1/c.txt", action: "merge" },
      ],
    },
  ),
  scenario(
    "a per-item Replace of a blocked folder becomes Merge",
    [file("a/f/f/inner.txt"), file("a/f/other.txt")],
    { sources: ["a/f/f"], destination: "a" },
    { policy: SKIP_ALL, overrides: [{ nodeId: "item-1", action: "overwrite" }] },
  ),
  scenario(
    "a per-item Skip of a folder skips everything inside",
    [file("source/f/a.txt"), file("source/f/new.txt"), file("destination/f/a.txt")],
    { sources: ["source/f"], ...INTO },
    { policy: REPLACE_ALL, overrides: [{ nodeId: "item-1", action: "skip" }] },
  ),
];

export async function generate(): Promise<GoldenCase[]> {
  return analysisCases(cases);
}
