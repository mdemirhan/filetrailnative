// resolveDuplicateName (packages/core/src/fs/copyPasteNames.ts): the Keep Both / duplicate name chosen in "/target".
// Input: { name, isFolder, isPackage?, taken, reserved, caseSensitive, allTaken }. `taken` are names in
// /target that lstat finds (anything else is ENOENT); `reserved` are names claimed by the same paste, keyed
// by destinationPathKey; `allTaken` makes every lstat succeed. Output: { path } or { error }.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type NamesModule = {
  resolveDuplicateName: (
    sourceName: string,
    destinationDirectoryPath: string,
    fileSystem: { lstat: (path: string) => Promise<unknown> },
    reservedPaths?: ReadonlySet<string>,
    options?: { isDirectory?: boolean; isPackage?: boolean; caseSensitive?: boolean },
  ) => Promise<string>;
  destinationPathKey: (path: string, caseSensitive?: boolean) => string;
};

export const seed = 0x4b0b0001;

type Input = {
  name: string;
  isFolder: boolean;
  isPackage?: boolean;
  taken: string[];
  reserved: string[];
  caseSensitive: boolean;
  allTaken: boolean;
};

const DIR = "/target";
const ZWJ_FAMILY = "👩‍👩‍👧‍👦";
const FLAG = "🇹🇷";
const ACCENTED = "é";

const NAMES = [
  "report.txt", "archive", "notes copy.txt", "x copy 5", "x copy", "copy.txt", "a copycat.txt",
  "draft copy 1.txt", "plan copy 2.md", "big copy 99999", "big copy 99999.bin", "copy", "a copy", " copy",
  "backup.tar.gz", "BACKUP.TAR.GZ", "backup.tar.bz2", "backup.tar.xz", "backup.tar.zst", "Backup.Tar.Gz copy 3",
  ".tar.gz", "x.tar.gz", "x copy.tar.gz", "Tool.app", "Tool.APP", "Talk.key", "Talk copy.key",
  "Trip.photoslibrary", "Photos 2024.v2", "Photos copy", "Movie.fcpxbundle", "Model.custompkg",
  "Backup.sparsebundle", ".env", ".hidden.txt", "..", "...", "a.", "trailing dot.", "two..dots.txt",
  "no extension", "UPPER.TXT", "Café.txt", "Café.txt", "日本語.txt", "résumé copy 9.pdf",
  "ünïcödé copy 10", "emoji 🎉.png", `${ZWJ_FAMILY}.txt`, "a\ncopy.txt", "a copy\n", "a copy 2\nb",
  "x copy 02", "x copy 10", "x copy 1", "x copy 100000", "x copy 0", "x  copy", "x copy copy", "x copy 2 copy 3",
  "sp ace  .txt", "tab\there.md", "İstanbul.txt", "ΑΣ copy.txt", "file.TXT", "a.b.c.d",
];

const FOLDERS = [
  "Photos", "Photos 2024.v2", "Tool.app", "Talk.key", "Movie.fcpxbundle", "Backup.sparsebundle", "x copy",
  "Docs copy 7", "My.Folder", "Model.custompkg", "Plain.dir", "Trip.photoslibrary", "Café", "a.tar.gz",
];

function longName(rng: Prng): string {
  const unit = rng.pick(["a", "é", ACCENTED, "日", ZWJ_FAMILY, FLAG, "x y ", "ab ", "😀"]);
  const bytes = Buffer.byteLength(unit);
  const target = rng.int(236, 290);
  let base = unit.repeat(Math.max(1, Math.ceil(target / bytes)));
  // Sometimes an emoji sequence or a space lands right at the cut.
  if (rng.chance(0.5)) {
    base =
      "a".repeat(rng.int(200, 245)) +
      rng.pick([ZWJ_FAMILY, FLAG, "é", "日", "  ", "é́"]).repeat(rng.int(1, 4));
  }
  return base + rng.pick(["", ".txt", ".tar.gz", ".app", ".jpeg", ".verylongextension"]);
}

async function run(mod: NamesModule, input: Input): Promise<GoldenCase["output"]> {
  const takenPaths = new Set(input.taken.map((name) => `${DIR}/${name}`));
  const fileSystem = {
    lstat: async (path: string) => {
      if (input.allTaken || takenPaths.has(path)) {
        return {};
      }
      throw Object.assign(new Error(`ENOENT: ${path}`), { code: "ENOENT" });
    },
  };
  const reserved = new Set(
    input.reserved.map((name) => mod.destinationPathKey(`${DIR}/${name}`, input.caseSensitive)),
  );
  const options: { isDirectory?: boolean; isPackage?: boolean; caseSensitive?: boolean } = {
    isDirectory: input.isFolder,
    caseSensitive: input.caseSensitive,
  };
  if (input.isPackage !== undefined) {
    options.isPackage = input.isPackage;
  }
  try {
    return { path: await mod.resolveDuplicateName(input.name, DIR, fileSystem, reserved, options) };
  } catch (error) {
    return { error: (error as Error).message };
  }
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const mod = await importReference<NamesModule>("packages/core/src/fs/copyPasteNames.ts");
  const cases: GoldenCase[] = [];
  const seen = new Set<string>();
  const add = async (label: string, input: Input) => {
    const name = `${label}: ${JSON.stringify(input.name.slice(0, 40))} #${cases.length}`;
    if (seen.has(name)) {
      return;
    }
    seen.add(name);
    cases.push({ name, input, output: await run(mod, input) });
  };

  const base = (name: string, isFolder: boolean, isPackage?: boolean): Input => ({
    name,
    isFolder,
    taken: [],
    reserved: [],
    caseSensitive: false,
    allTaken: false,
    ...(isPackage === undefined ? {} : { isPackage }),
  });
  const nameOf = (output: unknown): string | undefined => {
    const path = (output as { path?: string }).path;
    return path === undefined ? undefined : path.slice(DIR.length + 1);
  };

  // Hand-picked: each name alone, then with the first candidates taken one by one.
  for (const name of NAMES) {
    await add("free", base(name, false));
    const input = base(name, false);
    for (let step = 0; step < 3; step++) {
      const next = nameOf(await run(mod, input));
      if (next === undefined) {
        break;
      }
      input.taken = [...input.taken, next];
      await add(`taken ${step + 1}`, { ...input, taken: [...input.taken] });
    }
  }
  for (const name of FOLDERS) {
    for (const isPackage of [undefined, true, false]) {
      const input = base(name, true, isPackage);
      await add("folder", input);
      const first = nameOf(await run(mod, input));
      if (first !== undefined) {
        await add("folder taken", { ...input, taken: [first] });
      }
    }
  }
  // Copy numbers past what an Int holds: JavaScript numbers are doubles, so the next number rounds and,
  // from 2^53, stops growing. Only free names here: a taken one would keep the reference looping.
  const hugeNumbers = ["9223372036854775807", "9223372036854775808", "99999999999999999999"];
  for (let length = 15; length <= 25; length++) {
    hugeNumbers.push("1" + "0".repeat(length - 1), "9".repeat(length));
  }
  hugeNumbers.push("9007199254740990", "9007199254740991", "9007199254740992", "9007199254740993");
  hugeNumbers.push("9007199254740994", "18014398509481984", "100000000000000000000000");
  for (const digits of hugeNumbers) {
    await add("huge number", base(`x copy ${digits}.txt`, false));
  }
  await add("huge number, no extension", base("x copy 99999999999999999999", false));
  await add("huge number, folder", base("x copy 9223372036854775807", true));
  // Exhaustion and a volume that fails every lookup.
  for (const name of ["report.txt", "x copy 5", "Tool.app", "archive"]) {
    await add("all taken", { ...base(name, name === "Tool.app"), allTaken: true });
  }
  // Names claimed by the same paste, with case and normalization differing.
  await add("reserved", { ...base("a.txt", false), reserved: ["a copy.txt"] });
  await add("reserved case", { ...base("a.txt", false), reserved: ["A COPY.TXT"] });
  await add("reserved case, sensitive", {
    ...base("a.txt", false),
    reserved: ["A COPY.TXT"],
    caseSensitive: true,
  });
  await add("reserved nfd", { ...base("Café.txt", false), reserved: ["Café copy.txt"] });
  await add("reserved nfc", {
    ...base("Café.txt", false),
    reserved: ["Café copy.txt"],
    caseSensitive: true,
  });
  await add("reserved and taken", {
    ...base("a.txt", false),
    reserved: ["a copy.txt", "a copy 3.txt"],
    taken: ["a copy 2.txt"],
  });

  // Random.
  while (cases.length < 520) {
    const isFolder = rng.chance(0.25);
    let name = rng.chance(0.2) ? longName(rng) : rng.pick(isFolder ? [...FOLDERS, ...NAMES] : NAMES);
    if (rng.chance(0.15)) {
      name = rng.pick(["", "x ", "y"]) + name;
    }
    const input: Input = {
      name,
      isFolder,
      taken: [],
      reserved: [],
      caseSensitive: rng.chance(0.3),
      allTaken: false,
    };
    if (isFolder && rng.chance(0.5)) {
      input.isPackage = rng.chance(0.5);
    }
    // Take the next few candidates, as a busy folder would.
    const steps = rng.pick([0, 0, 1, 2, 3, 5]);
    for (let step = 0; step < steps; step++) {
      const next = nameOf(await run(mod, input));
      if (next === undefined) {
        break;
      }
      input.taken.push(next);
    }
    if (rng.chance(0.2)) {
      const reservedName = nameOf(await run(mod, input));
      if (reservedName !== undefined) {
        input.reserved.push(
          rng.chance(0.5) ? reservedName.toUpperCase() : reservedName.normalize("NFD"),
        );
      }
    }
    if (rng.chance(0.1)) {
      input.taken.push(rng.pick(NAMES));
    }
    await add("random", input);
  }
  return cases;
}
