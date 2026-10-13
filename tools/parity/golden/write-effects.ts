// The path helpers of packages/contracts/src/writeEffects.ts.
// Input: { fn, ... } with fn one of:
//   pathsChangedByWrite { targetPath?, destinationDirectoryPath?, items: [{sourcePath, destinationPath}], trashedPaths? } -> { paths }
//   isAffectedByChange { path, changed } -> { value }
//   changeMatcher { path, changed } -> { matcher: [holdsChange, isAtOrInsideChange, isAffected] }
//   isFollowedMove { item, action } -> { value }
//   itemsForOtherWindows { action, targetPath?, items: [{sourcePath, destinationPath, status}] } -> { indices } (of the items kept)

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Item = { sourcePath: string | null; destinationPath: string | null; status: string };
type EffectsModule = {
  pathsChangedByWrite: (result: {
    targetPath?: string | null;
    destinationDirectoryPath?: string | null;
    items: ReadonlyArray<{ sourcePath: string | null; destinationPath: string | null }>;
    trashedPaths?: readonly string[];
  }) => string[];
  isAffectedByChange: (path: string, changedPaths: readonly string[]) => boolean;
  createChangeMatcher: (changedPaths: readonly string[]) => {
    holdsChange(path: string): boolean;
    isAtOrInsideChange(path: string): boolean;
    isAffected(path: string): boolean;
  };
  isFollowedMove: (item: Item, action: string) => boolean;
  itemsForOtherWindows: <T extends Item>(result: {
    action: string;
    targetPath?: string | null;
    items: readonly T[];
  }) => T[];
};

export const seed = 0x3e0e0004;

const NAMES = ["a", "b", "ab", "a b", ".Trash", "é", "é", "A", "x"];
const ACTIONS = ["paste", "move_to", "trash", "rename", "batch_rename", "duplicate", "delete"];
const STATUSES = ["completed", "completed", "completed", "failed", "skipped"];

function randomPath(rng: Prng): string {
  const depth = rng.int(0, 4);
  let path = "";
  for (let level = 0; level < depth; level++) {
    path += `/${rng.pick(NAMES)}`;
  }
  const form = rng.int(0, 11);
  if (path === "") {
    return form === 0 ? "" : form === 1 ? "//" : form === 2 ? "relative" : "/";
  }
  return form === 0 ? `${path}/` : form === 1 ? `/${path}` : form === 2 ? path.slice(1) : path;
}

function randomPaths(rng: Prng, count: number): string[] {
  return Array.from({ length: count }, () => randomPath(rng));
}

function nullable(rng: Prng, path: string): string | null {
  return rng.chance(0.1) ? null : path;
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const mod = await importReference<EffectsModule>("packages/contracts/src/writeEffects.ts");
  const cases: GoldenCase[] = [];
  const add = (label: string, input: Record<string, unknown>, output: Record<string, unknown>) => {
    cases.push({ name: `${label} #${cases.length}`, input, output });
  };

  const changed = (label: string, input: Parameters<EffectsModule["pathsChangedByWrite"]>[0]) =>
    add(label, { fn: "pathsChangedByWrite", ...input }, { paths: mod.pathsChangedByWrite(input) });
  const affected = (label: string, path: string, changedPaths: string[]) =>
    add(label, { fn: "isAffectedByChange", path, changed: changedPaths }, {
      value: mod.isAffectedByChange(path, changedPaths),
    });
  const matcher = (label: string, path: string, changedPaths: string[]) => {
    const built = mod.createChangeMatcher(changedPaths);
    add(label, { fn: "changeMatcher", path, changed: changedPaths }, {
      matcher: [built.holdsChange(path), built.isAtOrInsideChange(path), built.isAffected(path)],
    });
  };
  const forOtherWindows = (
    label: string,
    action: string,
    targetPath: string | undefined,
    items: Array<{ sourcePath: string | null; destinationPath: string | null; status?: string }>,
  ) => {
    const full: Item[] = items.map((item) => ({ ...item, status: item.status ?? "completed" }));
    const kept = mod.itemsForOtherWindows({ action, ...(targetPath === undefined ? {} : { targetPath }), items: full });
    add(
      label,
      { fn: "itemsForOtherWindows", action, ...(targetPath === undefined ? {} : { targetPath }), items: full },
      { indices: kept.map((item) => full.indexOf(item)) },
    );
  };

  // Hand-picked, from writeEffects.test.ts and its edges.
  changed("target and items", {
    targetPath: "/Users/demo/Dest",
    items: [
      { sourcePath: "/Users/demo/a.txt", destinationPath: "/Users/demo/Dest/a.txt" },
      { sourcePath: "/Users/demo/Old", destinationPath: null },
    ],
  });
  changed("trashed", {
    destinationDirectoryPath: "/Users/demo/Dest",
    items: [{ sourcePath: "/Users/demo/a.txt", destinationPath: "/Users/demo/Dest/a.txt" }],
    trashedPaths: ["/Users/demo/.Trash/a.txt"],
  });
  changed("empty", { items: [] });
  changed("empty strings skipped", { targetPath: "", items: [{ sourcePath: "", destinationPath: null }] });
  changed("root swallows", { targetPath: "/", items: [{ sourcePath: "/a/b", destinationPath: "/c" }] });
  changed("trailing slash folder", { targetPath: "/b/", items: [{ sourcePath: "/b/x", destinationPath: "/b/y" }] });
  changed("trailing slash then sibling", { targetPath: "/b/", items: [{ sourcePath: "/b", destinationPath: "/bc" }] });
  changed("duplicates", { items: [{ sourcePath: "/a", destinationPath: "/a" }, { sourcePath: "/a", destinationPath: "/a/b" }] });
  changed("nfc and nfd kept apart", {
    items: [{ sourcePath: "/Café", destinationPath: "/Café/x" }],
  });
  changed("double slash", { items: [{ sourcePath: "//a", destinationPath: "/a" }, { sourcePath: "/a//b", destinationPath: null }] });
  changed("copy of many files", {
    destinationDirectoryPath: "/Volumes/Backup",
    items: [
      ...Array.from({ length: 300 }, (_, index) => ({
        sourcePath: `/Users/demo/Photos/${index % 10}/IMG_${index}.jpg`,
        destinationPath: `/Volumes/Backup/Photos/${index % 10}/IMG_${index}.jpg`,
      })),
      { sourcePath: "/Users/demo/Photos", destinationPath: "/Volumes/Backup/Photos" },
    ],
  });
  const projects = ["/Users/demo/Projects/app"];
  for (const path of ["/Users/demo/Projects/app", "/Users/demo/Projects", "/", "/Users/demo/Projects/app/src",
    "/Users/demo/Projects/application", "/Users/demo/Music", "/Users/demo/Projects/", "/Users/demo/Projects/app/", ""]) {
    affected("affected", path, projects);
    matcher("matcher", path, projects);
  }
  matcher("matcher trailing slash change", "/Users/demo/Projects/", ["/Users/demo/Projects/"]);
  matcher("matcher trailing slash inside", "/Users/demo/Projects/x", ["/Users/demo/Projects/"]);
  matcher("matcher root change", "/a", ["/"]);
  matcher("matcher empty", "/a", []);
  forOtherWindows("folder known", "paste", "/b", [
    { sourcePath: "/a/F", destinationPath: "/b/F" },
    { sourcePath: "/a/F/x", destinationPath: "/b/F/x" },
    { sourcePath: "/a/F/y", destinationPath: "/b/F/y" },
    { sourcePath: "/a/F/z", destinationPath: null },
  ]);
  forOtherWindows("trailing slash target", "trash", "/b/", [
    { sourcePath: "/b/x", destinationPath: null },
    { sourcePath: "/b/y", destinationPath: null },
  ]);
  forOtherWindows("tab follows", "move_to", undefined, [
    { sourcePath: "/a/F", destinationPath: "/b/F", status: "failed" },
    { sourcePath: "/a/F/x", destinationPath: "/b/F/x" },
  ]);
  forOtherWindows("relative names", "trash", undefined, [
    { sourcePath: "x", destinationPath: null },
    { sourcePath: "x", destinationPath: null },
    { sourcePath: "y", destinationPath: "" },
  ]);
  forOtherWindows("moved folder then its contents", "move_to", "/b", [
    { sourcePath: "/a/F", destinationPath: "/b/F" },
    { sourcePath: "/a/F/x", destinationPath: "/b/F/x" },
    { sourcePath: "/a/F/sub/y", destinationPath: "/b/F/sub/y" },
    { sourcePath: "/a/G", destinationPath: "/b/G" },
  ]);
  for (const action of ["rename", "batch_rename"]) {
    for (const status of ["completed", "failed"]) {
      add(
        "followed move",
        { fn: "isFollowedMove", action, item: { sourcePath: "/a/F", destinationPath: "/b/F", status } },
        { value: mod.isFollowedMove({ sourcePath: "/a/F", destinationPath: "/b/F", status }, action) },
      );
    }
  }
  for (const item of [
    { sourcePath: "/a", destinationPath: "/a", status: "completed" },
    { sourcePath: null, destinationPath: "/a", status: "completed" },
    { sourcePath: "/a", destinationPath: null, status: "completed" },
    { sourcePath: "", destinationPath: "/a", status: "completed" },
    { sourcePath: "/Café", destinationPath: "/Café", status: "completed" },
  ]) {
    add("followed move edge", { fn: "isFollowedMove", action: "rename", item }, { value: mod.isFollowedMove(item, "rename") });
  }

  // Random.
  while (cases.length < 210) {
    const kind = rng.int(0, 4);
    if (kind === 0) {
      const items = Array.from({ length: rng.int(0, 8) }, () => ({
        sourcePath: nullable(rng, randomPath(rng)),
        destinationPath: nullable(rng, randomPath(rng)),
      }));
      changed("random changed", {
        ...(rng.chance(0.5) ? { targetPath: randomPath(rng) } : {}),
        ...(rng.chance(0.4) ? { destinationDirectoryPath: randomPath(rng) } : {}),
        items,
        ...(rng.chance(0.3) ? { trashedPaths: randomPaths(rng, rng.int(0, 3)) } : {}),
      });
    } else if (kind === 1) {
      affected("random affected", randomPath(rng), randomPaths(rng, rng.int(0, 5)));
    } else if (kind === 2) {
      matcher("random matcher", randomPath(rng), randomPaths(rng, rng.int(0, 6)));
    } else if (kind === 3) {
      const item: Item = {
        sourcePath: nullable(rng, randomPath(rng)),
        destinationPath: nullable(rng, randomPath(rng)),
        status: rng.pick(STATUSES),
      };
      add("random followed", { fn: "isFollowedMove", action: rng.pick(ACTIONS), item }, { value: 0 });
      const last = cases[cases.length - 1] as GoldenCase;
      last.output = { value: mod.isFollowedMove(item, (last.input as { action: string }).action) };
    } else {
      forOtherWindows(
        "random other windows",
        rng.pick(ACTIONS),
        rng.chance(0.6) ? randomPath(rng) : undefined,
        Array.from({ length: rng.int(0, 10) }, () => ({
          sourcePath: nullable(rng, randomPath(rng)),
          destinationPath: nullable(rng, randomPath(rng)),
          status: rng.pick(STATUSES),
        })),
      );
    }
  }
  return cases;
}
