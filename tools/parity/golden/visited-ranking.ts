// The Go To box's places and their ranking (apps/desktop/src/renderer/lib/places.ts with
// apps/desktop/src/shared/visitedFolders.ts): buildPlaces, rankPlaces and describePlaceLocation.
// Input: { visited, favorites, currentPath, homePath, now, query }.
// Output: { places, ranked, locations } (ranked keeps each match's path and name ranges, in UTF-16 units).

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Visit = { at: number; kind: "goTo" | "stay" };
type VisitedFolder = { path: string; visits: Visit[] };
type Place = {
  path: string;
  name: string;
  displayPath: string;
  isFavorite: boolean;
  isVisited: boolean;
  score: number;
};
type PlacesModule = {
  buildPlaces: (args: {
    visitedFolders: VisitedFolder[];
    favoritePaths: string[];
    currentPath: string;
    homePath: string;
    now: number;
  }) => Place[];
  rankPlaces: (places: Place[], query: string) => Array<{ place: Place; nameRanges: Array<[number, number]> }>;
  describePlaceLocation: (place: Pick<Place, "name" | "displayPath">) => string;
  isPathQuery: (query: string) => boolean;
};

export const seed = 0x60710007;

const NOW = 1_800_000_000_000;
const DAY = 24 * 60 * 60 * 1000;
const HOME = "/Users/demo";

const NAMES = [
  "Downloads", "Old Downloads", "filetrail", "desktop", "Desktop", "render-farm", "Music", "Pictures", "Projects",
  "my_project (2)", "node.modules", "a", "b", "Résumés", "École", "日本語", "🎉 party", "éclair", "Straße", "ΣΑΣ",
  "Photos 2024", "photos-2025", "Library", "Application Support", "Documents", "docs", "src", "apps", "x y z", "Dev [old]",
];
const PARENTS = [
  "/Users/demo", "/Users/demo/src", "/Users/demo/src/filetrail", "/Users/demo/Music", "/Volumes/Backup", "/", "/tmp",
  "/Users/demolition", "/Users/demo/Projects/apps", "/Applications",
];
const QUERIES = [
  "", " ", "d", "D", "down", "DOWN", "dwn", "ownloads", "desk", "apps desk", "src", "farm", "render", "zzz", "é", "e", "eclair",
  "日", "🎉", "party", "ss", "σ", "old", "(2)", "my p", "x z", "  down  load  ", "~", "/", "a", "b", "ab", "photos", "p 2024", "lib",
  "app supp", "docs", "demo", "users", "tmp", "volumes backup",
];

function randomVisits(rng: Prng): Visit[] {
  const count = rng.pick([0, 0, 1, 1, 2, 3, 5, 10]);
  const visits: Visit[] = [];
  for (let index = 0; index < count; index++) {
    const ageDays = rng.pick([0, 0.01, 1, 3.9, 4, 4.1, 10, 14, 14.5, 20, 31, 31.5, 60, 90, 91, 200, 400]);
    visits.push({ at: NOW - Math.floor(ageDays * DAY), kind: rng.chance(0.3) ? "goTo" : "stay" });
  }
  return visits.sort((left, right) => right.at - left.at);
}

function randomPath(rng: Prng): string {
  const parent = rng.pick(PARENTS);
  const name = rng.pick(NAMES);
  return `${parent === "/" ? "" : parent}/${name}`;
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const module = await importReference<PlacesModule>("apps/desktop/src/renderer/lib/places.ts");
  const cases: GoldenCase[] = [];
  const add = (input: {
    visited: VisitedFolder[];
    favorites: string[];
    currentPath: string;
    homePath: string;
    now: number;
    query: string;
  }) => {
    const places = module.buildPlaces({
      visitedFolders: input.visited,
      favoritePaths: input.favorites,
      currentPath: input.currentPath,
      homePath: input.homePath,
      now: input.now,
    });
    const ranked = module.rankPlaces(places, input.query);
    cases.push({
      name: `${cases.length}: ${JSON.stringify(input.query)} over ${places.length} places`,
      input,
      output: {
        places,
        ranked: ranked.map((match) => ({ path: match.place.path, nameRanges: match.nameRanges })),
        locations: ranked.map((match) => module.describePlaceLocation(match.place)),
      },
    });
  };

  // The places of places.test.ts, with every query.
  const hour = 60 * 60 * 1000;
  const stays = (count: number): Visit[] => Array.from({ length: count }, () => ({ at: NOW - hour, kind: "stay" as const }));
  const fixedVisited: VisitedFolder[] = [
    { path: "/Users/demo/src/filetrail/apps/desktop", visits: stays(1) },
    { path: "/Users/demo/src/filetrail", visits: stays(9) },
    { path: "/Users/demo/Downloads", visits: stays(4) },
    { path: "/Users/demo/Music/Old Downloads", visits: stays(10) },
    { path: "/Users/demo/src/render-farm", visits: stays(2) },
  ];
  const fixedFavorites = [HOME, "/Users/demo/Desktop", "/Users/demo/Downloads", "/Users/demo/.Trash"];
  for (const query of QUERIES) {
    add({ visited: fixedVisited, favorites: fixedFavorites, currentPath: "/somewhere/else", homePath: HOME, now: NOW, query });
  }
  add({ visited: fixedVisited, favorites: fixedFavorites, currentPath: "/Users/demo/Downloads", homePath: HOME, now: NOW, query: "" });
  add({ visited: [], favorites: [], currentPath: "/", homePath: HOME, now: NOW, query: "x" });
  add({ visited: [], favorites: ["/", "/Applications", HOME, `${HOME}/.Trash`], currentPath: "", homePath: HOME, now: NOW, query: "" });
  add({ visited: [], favorites: ["/", "/Applications", "/Users/x/.Trash"], currentPath: "", homePath: "", now: NOW, query: "t" });
  // A folder listed twice keeps its first place and its last value; a long list is cut at 50.
  add({
    visited: [
      { path: "/a/one", visits: stays(1) },
      { path: "/a/two", visits: stays(2) },
      { path: "/a/one", visits: stays(5) },
    ],
    favorites: ["/a/two"],
    currentPath: "/",
    homePath: HOME,
    now: NOW,
    query: "",
  });
  add({
    visited: Array.from({ length: 80 }, (_, index) => ({ path: `/many/folder ${index}`, visits: stays(index % 7) })),
    favorites: [],
    currentPath: "/",
    homePath: HOME,
    now: NOW,
    query: "fold",
  });

  while (cases.length < 200) {
    const homePath = rng.chance(0.9) ? HOME : rng.pick(["/", "", "/Users/demolition", "/Users/demo/"]);
    const visited: VisitedFolder[] = [];
    for (let index = rng.int(0, 14); index > 0; index--) {
      visited.push({ path: rng.chance(0.15) ? rng.pick([HOME, "/", "/Applications", `${HOME}/.Trash`]) : randomPath(rng), visits: randomVisits(rng) });
    }
    const favorites: string[] = [];
    for (let index = rng.int(0, 6); index > 0; index--) {
      favorites.push(rng.chance(0.4) && visited.length > 0 ? rng.pick(visited).path : randomPath(rng));
    }
    const all = [...visited.map((folder) => folder.path), ...favorites];
    const currentPath = rng.chance(0.3) && all.length > 0 ? rng.pick(all) : "/somewhere/else";
    let query = rng.pick(QUERIES);
    if (rng.chance(0.5) && all.length > 0) {
      // By code points, so no pair of surrogates is cut in two (JSON cannot carry half of one).
      const leaf = [...(rng.pick(all).split("/").filter(Boolean).at(-1) ?? "x")];
      const start = rng.int(0, Math.max(0, leaf.length - 1));
      query = rng.chance(0.3) ? leaf.filter(() => rng.chance(0.6)).join("") : leaf.slice(start, start + rng.int(1, 5)).join("");
      if (rng.chance(0.25)) {
        query = `${query} ${rng.pick(QUERIES)}`;
      }
    }
    add({ visited, favorites, currentPath, homePath, now: NOW, query });
  }
  return cases;
}
