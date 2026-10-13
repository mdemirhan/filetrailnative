// The reference's paste analysis (tools/parity/exec/analysis.ts) on seeded random trees: one to
// three picks (files, folders, links, packages, some locked, read-only or unreadable) pasted,
// copied or cut, into a destination that holds items of the same names, of the same kind or
// not, to some depth; now and then into the pick's own folder, into itself, or with two picks
// landing on one name. Input: the scenario. Output: report, choices, resolution.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { ADD_MISSING, KEEP_ALL, REPLACE_ALL, SKIP_ALL, type Scenario, type ScenarioItem, analysisCases, scenario } from "../exec/scenarios";

export const seed = 20261013;

const COUNT = 90;
const NAMES = [
  "a.txt",
  "A.txt",
  "b",
  "notes.md",
  "Café.txt",
  "Café.txt",
  "x copy.txt",
  ".hidden",
  ".DS_Store",
  "archive.tar.gz",
  "sub",
  "Sub",
  "data",
  "Tool.app",
  "Talk.key",
  "photo.jpg",
];
const POLICIES = [SKIP_ALL, ADD_MISSING, KEEP_ALL, REPLACE_ALL];

type Kind = "file" | "dir" | "symlink";

// One folder's worth of distinct names: no two the same once case and normalization are folded,
// as the startup disk sees them.
function namesFor(rng: Prng, count: number): string[] {
  const chosen: string[] = [];
  const keys = new Set<string>();
  for (let attempt = 0; attempt < count * 4 && chosen.length < count; attempt += 1) {
    const name = rng.pick(NAMES);
    const key = name.normalize("NFD").toLowerCase();
    if (!keys.has(key)) {
      keys.add(key);
      chosen.push(name);
    }
  }
  return chosen;
}

function kindFor(rng: Prng, name: string): Kind {
  if (name === "Tool.app" || name === "Talk.key" || name === "sub" || name === "Sub" || name === "data") {
    return rng.chance(0.85) ? "dir" : "file";
  }
  const roll = rng.next();
  return roll < 0.75 ? "file" : roll < 0.9 ? "dir" : "symlink";
}

// Adds `path` of `kind` and, for a folder, random contents; `twin` (the same path on the source
// side) makes the destination reuse its names, so conflicts nest.
function addItem(
  rng: Prng,
  items: ScenarioItem[],
  path: string,
  kind: Kind,
  depth: number,
  twin: string[] | null,
  label: string,
): string[] {
  if (kind === "symlink") {
    items.push({ path, kind: "symlink", target: rng.pick(["a.txt", "../elsewhere", "sub"]) });
    return [];
  }
  if (kind === "file") {
    const flags = rng.chance(0.05) ? ["uchg"] : undefined;
    const mode = rng.chance(0.04) ? "0444" : undefined;
    items.push({ path, kind: "file", content: `${label} ${path}\n`.repeat(rng.int(1, 3)), ...(mode ? { mode } : {}), ...(flags ? { flags } : {}) });
    return [];
  }
  const roll = rng.next();
  const mode = depth > 0 && roll < 0.04 ? "0000" : roll < 0.08 ? "0555" : undefined;
  items.push({ path, kind: "dir", ...(mode ? { mode } : {}) });
  if (depth >= 3) {
    return [];
  }
  const names = twin !== null && twin.length > 0 && rng.chance(0.7) ? overlapping(rng, twin) : namesFor(rng, rng.int(0, 4));
  for (const name of names) {
    addItem(rng, items, `${path}/${name}`, kindFor(rng, name), depth + 1, null, label);
  }
  return names;
}

// Mostly the same names, sometimes a few others.
function overlapping(rng: Prng, names: string[]): string[] {
  const kept = names.filter(() => rng.chance(0.7));
  const keys = new Set(kept.map((name) => name.normalize("NFD").toLowerCase()));
  for (const extra of namesFor(rng, rng.int(0, 2))) {
    if (!keys.has(extra.normalize("NFD").toLowerCase())) {
      kept.push(extra);
    }
  }
  return kept;
}

function randomScenario(rng: Prng, index: number): Scenario {
  const items: ScenarioItem[] = [];
  const picks: string[] = [];
  const twoFolders = rng.chance(0.12);
  const pickNames = namesFor(rng, rng.int(1, 3));
  pickNames.forEach((name, pickIndex) => {
    const folder = twoFolders ? `source/${pickIndex % 2 === 0 ? "one" : "two"}` : "source";
    const path = `${folder}/${name}`;
    const kind = kindFor(rng, name);
    const children = addItem(rng, items, path, kind, 0, null, "new");
    picks.push(path);
    // The destination's item of the same name, often of the same kind, reusing names inside.
    if (rng.chance(0.65)) {
      const sameKind = rng.chance(0.75);
      const destinationKind: Kind = sameKind ? kind : kind === "dir" ? "file" : "dir";
      addItem(rng, items, `destination/${name}`, destinationKind, 0, destinationKind === "dir" ? children : null, "old");
    }
  });
  // Two picks of one name from two folders.
  if (twoFolders && rng.chance(0.5)) {
    const name = pickNames[0] as string;
    const other = `source/two-dup/${name}`;
    items.push({ path: other, kind: "file", content: "same name\n" });
    picks.push(other);
  }
  if (!items.some((item) => item.path === "destination" || item.path.startsWith("destination/"))) {
    items.push({ path: "destination", kind: "dir" });
  }
  for (const name of namesFor(rng, rng.int(0, 2))) {
    const path = `destination/${name}`;
    if (!items.some((item) => item.path === path || item.path.normalize("NFD").toLowerCase() === path.normalize("NFD").toLowerCase())) {
      addItem(rng, items, path, kindFor(rng, name), 1, null, "only");
    }
  }
  const roll = rng.next();
  const firstPick = picks[0] as string;
  const destination =
    roll < 0.06 ? firstPick.slice(0, firstPick.lastIndexOf("/")) : roll < 0.1 ? firstPick : roll < 0.13 ? `${firstPick}/sub` : "destination";
  const mode = rng.chance(0.3) ? "cut" : "copy";
  return scenario(
    `random ${String(index + 1).padStart(3, "0")}: ${mode} ${picks.length} into ${destination}`,
    items,
    { mode, sources: picks, destination },
    { policy: rng.pick(POLICIES) },
  );
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  return analysisCases(Array.from({ length: COUNT }, (_, index) => randomScenario(rng, index)));
}
