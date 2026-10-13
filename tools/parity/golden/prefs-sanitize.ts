// Reading a saved app-state.json (apps/desktop/src/main/appStateStore.ts): every preference is checked, the windows
// are read back, and a file saved by an older version is migrated.
// Input: { defaultTheme, text }: the theme a new install starts with (null: the store's own default) and the file's
// text. Output: the state the store holds after reading it ({} for a file that is not an object or not JSON).
// The Rename sheet's settings and presets belong to the batch-rename package: here they are absent, junk, the
// default, or an empty list, which that package's sanitizer and the passthrough give the same answer for.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type StoreModule = { AppStateStore: new (path: string, dependencies: unknown) => { state: unknown } };

export const seed = 0x9ef5a7a1;

const ICONS = [
  "home", "applications", "desktop", "documents", "downloads", "trash", "folder", "star", "drive", "code", "terminal",
  "globe", "music", "photos", "videos", "archive", "cloud", "server", "projects", "books", "camera", "toolbox", "network",
];
const TOOLBAR = [
  "back", "forward", "up", "refresh", "view", "sort", "title", "clipboard", "viewOptions", "search", "goToFolder",
  "foldersFirst", "hidden", "folderTree", "infoPanel", "infoRow", "newTab", "openSelection", "quickLook", "editSelection",
  "moveSelection", "renameSelection", "duplicateSelection", "newFolder", "trashSelection", "copySelection",
  "cutSelection", "pasteSelection", "openInTerminal", "showInFinder", "revealInFolder", "calculateSize", "copyPath",
  "theme", "settings", "help", "topSeparator",
];
const PATHS = ["/", "/Users/me", "/Users/me/Documents", "/Applications", "/Volumes/Backup", "/Users/me/.Trash", "  /x  ", "relative/path", "é/ñ", "/a b/c"];
const DETAIL = ["modified", "size", "kind", "created", "permissions"];
const SEARCH = ["folder", ...DETAIL];
const JUNK: unknown[] = [
  null, 0, 1, -1, 0.5, 1.5, 99.5, 1000000, 1e9, "", "x", " ", "auto", "true", true, false, [], {}, [null], [1, 2], { a: 1 },
  ["modified"], { modified: true }, "#12345", "#FFFFFF", " #AbCdEf ", "#abcdeg",
];

function pickJunk(rng: Prng): unknown {
  return rng.pick(JUNK);
}

function randomTab(rng: Prng): Record<string, unknown> {
  const tab: Record<string, unknown> = {
    path: rng.chance(0.15) ? null : rng.pick(PATHS),
    treeRootPath: rng.chance(0.5) ? null : rng.pick(PATHS),
    favoritePath: rng.chance(0.7) ? null : rng.pick(PATHS),
    viewMode: rng.pick(["icons", "list", "details"]),
    searchViewMode: rng.pick(["icons", "list", "details"]),
    sortBy: rng.pick(["name", "modified", "kind", "size"]),
    sortDirection: rng.pick(["asc", "desc"]),
    includeHidden: rng.chance(0.3),
    foldersFirst: rng.chance(0.7),
    favoritesExpanded: rng.chance(0.7),
    locationsExpanded: rng.chance(0.7),
  };
  for (const key of Object.keys(tab)) {
    const roll = rng.next();
    if (roll < 0.06) delete tab[key];
    else if (roll < 0.12) tab[key] = pickJunk(rng);
  }
  return tab;
}

function randomOrder(rng: Prng, keys: string[]): unknown {
  const roll = rng.next();
  if (roll < 0.1) return pickJunk(rng);
  const order = rng.pickMany([...keys, "name", "bogus"], rng.int(0, keys.length + 3));
  return roll < 0.5 ? order : keys.filter(() => rng.chance(0.7));
}

function randomWidths(rng: Prng, keys: string[]): unknown {
  if (rng.chance(0.1)) return pickJunk(rng);
  const widths: Record<string, unknown> = {};
  for (const key of keys) {
    const roll = rng.next();
    if (roll < 0.15) continue;
    widths[key] = roll < 0.25 ? pickJunk(rng) : rng.pick([0, 10, 35.5, 36, 59.5, 60, 79.5, 80, 139.5, 140, 200.5, 300, 719.5, 720, 721, 5000, -5, 152.4999]);
  }
  return widths;
}

function randomBooleans(rng: Prng, keys: string[]): unknown {
  if (rng.chance(0.1)) return pickJunk(rng);
  const record: Record<string, unknown> = {};
  for (const key of keys) {
    const roll = rng.next();
    if (roll < 0.15) continue;
    record[key] = roll < 0.25 ? pickJunk(rng) : rng.chance(0.5);
  }
  return record;
}

function randomApp(rng: Prng): unknown {
  const roll = rng.next();
  if (roll < 0.15) return pickJunk(rng);
  const app: Record<string, unknown> = {
    appPath: rng.pick(["/Applications/Zed.app", " /Applications/Zed.app ", "", "  ", "/System/Applications/TextEdit.app"]),
    appName: rng.pick(["Zed", " Zed ", "", "  ", "TextEdit"]),
  };
  if (rng.chance(0.2)) delete app[rng.pick(["appPath", "appName"])];
  return app;
}

function randomShortcutOverrides(rng: Prng): unknown {
  if (rng.chance(0.15)) return pickJunk(rng);
  const keys = ["Cmd+Y", "Cmd+U", "cmd+shift+k", "A", "Cmd+C", "Cmd+Tab", "F5", "nonsense", 7, null];
  return Object.fromEntries(
    rng.pickMany(["newTab", "goBack", "goForward", "copy", "refreshOrApplySearchSort", "bogus", "quickLookSelection"], rng.int(0, 4)).map((id) => [
      id,
      rng.chance(0.9) ? rng.pickMany(keys, rng.int(0, 3)) : pickJunk(rng),
    ]),
  );
}

function randomPreferences(rng: Prng): Record<string, unknown> {
  const preferences: Record<string, unknown> = {
    theme: rng.pick(["auto", "light", "dark"]),
    accent: rng.pick(["#007aff", "#A550A7", " #d4845a ", "#ffffff"]),
    zoomPercent: rng.pick([75, 100, 125, 150, 99.5, 100.4]),
    viewMode: rng.pick(["icons", "list", "details"]),
    searchViewMode: rng.pick(["icons", "list", "details"]),
    sortBy: rng.pick(["name", "modified", "kind", "size"]),
    sortDirection: rng.pick(["asc", "desc"]),
    foldersFirst: rng.chance(0.7),
    compactListView: rng.chance(0.3),
    compactDetailsView: rng.chance(0.3),
    compactIconView: rng.chance(0.3),
    compactTreeView: rng.chance(0.3),
    singleClickExpandTreeItems: rng.chance(0.3),
    detailColumns: randomBooleans(rng, DETAIL),
    detailColumnOrder: randomOrder(rng, DETAIL),
    detailColumnWidths: randomWidths(rng, ["name", ...DETAIL]),
    searchColumns: randomBooleans(rng, SEARCH),
    searchColumnOrder: randomOrder(rng, SEARCH),
    searchColumnWidths: randomWidths(rng, ["name", ...SEARCH]),
    notificationsEnabled: rng.chance(0.8),
    markClipboardItems: rng.chance(0.8),
    autoCalculateFolderSizes: rng.chance(0.8),
    folderTreeOpen: rng.chance(0.8),
    propertiesOpen: rng.chance(0.3),
    detailRowOpen: rng.chance(0.3),
    topToolbarItems: rng.chance(0.15) ? pickJunk(rng) : rng.pickMany([...TOOLBAR, "bogus", 5, null], rng.int(0, 30)),
    terminalApp: randomApp(rng),
    defaultTextEditor: randomApp(rng),
    openWithApplications: rng.chance(0.15)
      ? pickJunk(rng)
      : Array.from({ length: rng.int(0, 3) }, () => {
          const app = randomApp(rng) as Record<string, unknown>;
          return rng.chance(0.2) ? app : { id: rng.pick(["zed", " zed ", "", "x"]), ...(app && typeof app === "object" ? app : {}) };
        }),
    fileActivationAction: rng.pick(["open", "edit"]),
    diskImageOpensIn: rng.pick(["window", "tab"]),
    returnKeyAction: rng.pick(["rename", "open"]),
    shortcutOverrides: randomShortcutOverrides(rng),
    openItemLimit: rng.pick([1, 5, 50, 0, 51, 10.5, 7]),
    includeHidden: rng.chance(0.3),
    searchPatternMode: rng.pick(["text", "glob", "regex"]),
    searchMatchScope: rng.pick(["name", "path"]),
    searchRecursive: rng.chance(0.8),
    searchSkipGitFolders: rng.chance(0.8),
    searchSkipGitIgnored: rng.chance(0.3),
    searchResultsSortBy: rng.pick(["name", "path", "kind"]),
    searchResultsSortDirection: rng.pick(["asc", "desc"]),
    treeWidth: rng.pick([280, 220, 520, 219.5, 521, 300.5, 0, 9999]),
    inspectorWidth: rng.pick([320, 260, 480, 259.5, 481, 300.5, 0, 9999]),
    restoreSessionOnStartup: rng.chance(0.8),
    openTabs: Array.from({ length: rng.pick([0, 0, 1, 2, 3, 6]) }, () => (rng.chance(0.08) ? pickJunk(rng) : randomTab(rng))),
    activeTabIndex: rng.pick([0, 1, 2, 5, 100, -1, 1.5]),
    treeRootPath: rng.chance(0.4) ? null : rng.pick(PATHS),
    lastVisitedPath: rng.chance(0.3) ? null : rng.pick(PATHS),
    lastVisitedFavoritePath: rng.chance(0.6) ? null : rng.pick(PATHS),
    favorites: rng.chance(0.1)
      ? pickJunk(rng)
      : Array.from({ length: rng.pick([0, 1, 2, 4]) }, () =>
          rng.chance(0.1) ? pickJunk(rng) : { path: rng.pick(PATHS), icon: rng.chance(0.9) ? rng.pick(ICONS) : rng.pick(["rocket", 5, null]) },
        ),
    favoritesPlacement: rng.pick(["integrated", "separate"]),
    favoritesExpanded: rng.chance(0.7),
    locationsExpanded: rng.chance(0.7),
    favoritesInitialized: rng.chance(0.5),
  };
  // Batch rename: see the header.
  const rename = rng.next();
  if (rename < 0.5) {
    // absent
  } else if (rename < 0.7) {
    preferences.batchRenameSettings = rng.pick([null, 0, "x", true, [], [1]]);
    preferences.batchRenamePresets = rng.pick([null, 0, "x", true, {}, { a: 1 }]);
  } else {
    preferences.batchRenamePresets = [];
  }
  // Damage.
  for (const key of Object.keys(preferences)) {
    const roll = rng.next();
    if (roll < 0.04) delete preferences[key];
    else if (roll < 0.1) preferences[key] = key.startsWith("batchRename") ? null : pickJunk(rng);
  }
  return preferences;
}

function randomBounds(rng: Prng): unknown {
  if (rng.chance(0.1)) return pickJunk(rng);
  const bounds: Record<string, unknown> = {
    width: rng.pick([1200, 320, 6000, 319, 6001, 800.5, "800", null]),
    height: rng.pick([760, 320, 6000, 319, 6001, 400.25, "x"]),
    maximized: rng.pick([true, false, "true", 1]),
  };
  if (rng.chance(0.6)) bounds.x = rng.pick([0, 100, -50, 12.5, "1", null]);
  if (rng.chance(0.6)) bounds.y = rng.pick([0, 100, -50, 12.5, "1", null]);
  return bounds;
}

function randomSession(rng: Prng): unknown {
  if (rng.chance(0.1)) return pickJunk(rng);
  const full = randomPreferences(rng);
  const keys = [
    "openTabs", "activeTabIndex", "treeRootPath", "lastVisitedPath", "lastVisitedFavoritePath", "viewMode", "searchViewMode",
    "sortBy", "sortDirection", "searchResultsSortBy", "searchResultsSortDirection", "includeHidden", "foldersFirst",
    "favoritesExpanded", "locationsExpanded", "folderTreeOpen", "propertiesOpen", "detailRowOpen", "treeWidth", "inspectorWidth",
    "detailColumnWidths", "searchColumnWidths",
  ];
  return Object.fromEntries(keys.filter((key) => key in full && rng.chance(0.75)).map((key) => [key, full[key]]));
}

function randomWindow(rng: Prng, index: number): unknown {
  if (rng.chance(0.06)) return pickJunk(rng);
  const window: Record<string, unknown> = {
    id: rng.chance(0.08) ? rng.pick(["", 5, null, "window-1"]) : rng.pick([`window-${index}`, `window-${index}`, "window-1", "dup"]),
    bounds: randomBounds(rng),
    session: randomSession(rng),
  };
  if (rng.chance(0.08)) delete window[rng.pick(["bounds", "session"])];
  return window;
}

function randomFile(rng: Prng): unknown {
  const roll = rng.next();
  if (roll < 0.04) return rng.pick([null, 0, "x", [], true, [{ preferences: {} }]]);
  const file: Record<string, unknown> = {};
  if (rng.chance(0.9)) file.preferences = rng.chance(0.07) ? pickJunk(rng) : randomPreferences(rng);
  const shape = rng.next();
  if (shape < 0.35) {
    // Saved before there could be several windows.
    if (rng.chance(0.7)) file.window = randomBounds(rng);
  } else {
    if (shape < 0.95) {
      file.windows = rng.chance(0.07) ? pickJunk(rng) : Array.from({ length: rng.pick([0, 1, 2, 3, 5]) }, (_, i) => randomWindow(rng, i));
    }
    if (rng.chance(0.5)) file.lastClosedWindow = rng.chance(0.1) ? pickJunk(rng) : randomWindow(rng, 9);
    if (rng.chance(0.15)) file.window = randomBounds(rng);
  }
  return file;
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const { AppStateStore } = await importReference<StoreModule>("apps/desktop/src/main/appStateStore.ts");
  const cases: GoldenCase[] = [];
  const add = (label: string, defaultTheme: string | null, text: string) => {
    const store = new AppStateStore("/virtual/app-state.json", {
      ...(defaultTheme === null ? {} : { defaultTheme }),
      fs: {
        existsSync: (path: string) => path === "/virtual/app-state.json",
        mkdirSync: () => {},
        readFileSync: () => text,
        writeFileSync: () => {},
        renameSync: () => {},
      },
      timer: { setTimeout: () => 0, clearTimeout: () => {} },
      onReadError: () => {},
      onPersistError: () => {},
    });
    cases.push({ name: `${cases.length}: ${label}`, input: { defaultTheme, text }, output: JSON.parse(JSON.stringify(store.state)) });
  };

  // Hand-picked.
  add("empty object", null, "{}");
  add("empty preferences", null, '{"preferences":{}}');
  add("not JSON", null, "{");
  add("empty text", null, "");
  add("null", null, "null");
  add("array", null, "[]");
  add("a number", null, "42");
  add("dark install", "dark", "{}");
  add("light install, saved auto", "light", '{"preferences":{"theme":"auto"}}');
  add("light install, saved junk", "light", '{"preferences":{"theme":"purple"}}');
  add("legacy window", null, JSON.stringify({ preferences: { openTabs: [{ path: "/Users/me" }], activeTabIndex: 4, folderTreeOpen: false, treeWidth: 300 }, window: { width: 900, height: 700, maximized: true, x: 10, y: 20 } }));
  add("legacy window with bad size", null, JSON.stringify({ preferences: {}, window: { width: 100, height: 99999 } }));
  add("windows without a list", null, JSON.stringify({ preferences: {}, lastClosedWindow: { id: "w", bounds: {}, session: { openTabs: [{ path: "/a" }, { path: "/b" }], activeTabIndex: 9 } } }));
  add("window list", null, JSON.stringify({ preferences: { favoritesExpanded: false }, windows: [{ id: "a", bounds: { width: 500, height: 500, maximized: false }, session: { openTabs: [{}], activeTabIndex: 3 } }, { id: "a" }, { id: "" }, { id: "b" }, 5] }));
  add("more than fifty windows", null, JSON.stringify({ windows: Array.from({ length: 60 }, (_, index) => ({ id: `w${index}` })) }));
  add("more than a hundred tabs", null, JSON.stringify({ preferences: { openTabs: Array.from({ length: 130 }, (_, index) => ({ path: `/t${index}` })) } }));
  add("old tabs inherit", null, JSON.stringify({ preferences: { includeHidden: true, foldersFirst: false, favoritesExpanded: false, locationsExpanded: false, openTabs: [{ path: "/a" }, { path: "/b", includeHidden: false, favoritesExpanded: true }] } }));
  add("columns", null, JSON.stringify({ preferences: { detailColumnOrder: ["size", "size", "name", "bogus", 5], searchColumnOrder: ["kind", "folder"], detailColumnWidths: { name: 1, modified: 1000, size: 59.5 }, searchColumnWidths: { folder: 79.5, name: "x" } } }));
  add("half widths round up", null, JSON.stringify({ preferences: { treeWidth: 220.5, inspectorWidth: 260.5, zoomPercent: 75.5, openItemLimit: 1.5, detailColumnWidths: { name: 140.5, permissions: 36.5 } } }));
  add("null order is the default order", null, JSON.stringify({ preferences: { detailColumnOrder: null, searchColumnOrder: null } }));
  add("favorites", null, JSON.stringify({ preferences: { favorites: [{ path: " /a ", icon: "home" }, { path: "/a", icon: "star" }, { path: "/b", icon: "rocket" }, { path: "  ", icon: "home" }, "x", null] } }));
  add("pinned apps", null, JSON.stringify({ preferences: { openWithApplications: [{ id: " z ", appPath: " /z.app ", appName: " Z " }, { id: "", appPath: "/a", appName: "A" }, 5], terminalApp: { appPath: "/t.app", appName: "T" }, defaultTextEditor: { appPath: " ", appName: "x" } } }));
  add("empty pinned apps", null, JSON.stringify({ preferences: { openWithApplications: [] } }));
  add("toolbar", null, JSON.stringify({ preferences: { topToolbarItems: ["back", "back", "topSeparator", "topSeparator", "bogus", "title"] } }));
  add("empty toolbar", null, JSON.stringify({ preferences: { topToolbarItems: [] } }));
  add("shortcuts", null, JSON.stringify({ preferences: { shortcutOverrides: { newTab: ["cmd+y", "Cmd+U", "Cmd+I"], copy: ["Cmd+Y"], goBack: ["Cmd+R"] } } }));
  add("accent", null, JSON.stringify({ preferences: { accent: " #ABCDEF " } }));
  add("bad accent", null, JSON.stringify({ preferences: { accent: "#ABCDE" } }));

  while (cases.length < 300) {
    const theme = rng.pick([null, null, "auto", "light", "dark"]);
    const file = randomFile(rng);
    add(`random ${cases.length}`, theme, JSON.stringify(file));
  }
  return cases;
}
