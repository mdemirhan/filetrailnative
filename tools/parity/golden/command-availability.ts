// Which commands the window can run (apps/desktop/src/renderer/lib/rendererCommandAvailability.ts, with
// shortcutPolicy.ts and applicationMenuState.ts behind it).
// Input: the window's state. Output: { disabled, newTab, favorite, showInFinder, calculateSize, openTerminal, openPaths }:
// every command that can not run (in the menu state's order), and the targets the command rules resolve.
// The zoom commands are not in the Swift port (DEVIATIONS D-005); they are always available in the original, so they
// never show in `disabled`.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Availability = {
  canRunToolbarRendererCommand: (command: string, context: unknown) => boolean;
  resolveNewTabTargetPath: (context: unknown) => string | null;
  resolveFavoriteTargetPath: (context: unknown) => string | null;
  resolveShowInFinderPaths: (context: unknown) => string[];
  resolveCalculateSizePaths: (context: unknown) => string[];
};
type MenuState = {
  buildApplicationMenuState: (args: Record<string, unknown>) => { disabledCommands: string[] };
};
type Targets = {
  resolveOpenInTerminalPaths: (input: unknown) => string[];
  resolveOpenSelectionPaths: (input: unknown) => string[];
  resolveEditSelectionPaths: (input: unknown) => string[];
  resolveRootTreeTargetPath: (input: unknown) => string | null;
};

export const seed = 0xc0a7a11b;

const ZOOM = new Set(["zoomIn", "zoomOut", "resetZoom"]);
const KINDS = ["directory", "file", "symlink_directory", "symlink_file", "bundle", "other"];
const HOME = "/Users/me";
const FOLDERS = [
  "", "/", HOME, `${HOME}/Documents`, `${HOME}/.Trash`, `${HOME}/.Trash/old`, "/Volumes/Backup", "/Volumes/Backup/.Trashes/501",
  "/Volumes/Backup/.Trashes", "/Applications", "relative", "/a//b", "/a/b/", "//", "/é", "/é",
];
const NAMES = ["a.txt", "b.md", "c", "Folder", "Thing.app", "link", "é.txt", "é.txt", "d d"];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const a = await importReference<Availability>("apps/desktop/src/renderer/lib/rendererCommandAvailability.ts");
  const menu = await importReference<MenuState>("apps/desktop/src/renderer/lib/applicationMenuState.ts");
  const t = await importReference<Targets>("apps/desktop/src/renderer/lib/shortcutTargets.ts");
  const cases: GoldenCase[] = [];

  const entryOf = (path: string, kind: string) => ({
    path,
    name: path.split("/").at(-1) ?? path,
    extension: "",
    kind,
    isHidden: false,
    isSymlink: kind.startsWith("symlink"),
  });

  const add = (label: string, input: Record<string, any>) => {
    const entries = (input.entries as { path: string; kind: string }[]).map((entry) => entryOf(entry.path, entry.kind));
    const context: Record<string, unknown> = {
      shortcutContext: input.shortcut,
      currentPath: input.currentPath,
      selectedPathsInViewOrder: input.selectedPaths,
      activeContentEntries: entries,
      selectedEntry: input.selectedEntry ? entryOf(input.selectedEntry.path, input.selectedEntry.kind) : null,
      selectedTreeTargetPath: input.selectedTreeTargetPath,
      copyPasteClipboard: input.clipboardHasItems
        ? { type: "ready", mode: "copy", sourcePaths: ["/x/y"], sourceEntries: {}, capturedAt: "now" }
        : input.clipboardEmptyReady
          ? { type: "ready", mode: "copy", sourcePaths: [], sourceEntries: {}, capturedAt: "now" }
          : { type: "empty" },
      pasteDestinationPath: input.pasteDestinationPath,
      isSearchMode: input.isSearchMode,
      openItemLimit: input.openItemLimit,
      writeOperationLocked: input.writeOperationLocked,
    };
    for (const key of ["canGoBack", "canGoForward", "hasCachedSearch", "tabCount", "trashPath", "homePath", "trashIsEmpty", "ejectTargetPath"]) {
      if (input[key] !== undefined) context[key] = input[key];
    }
    const state = menu.buildApplicationMenuState({
      viewMode: "list",
      sortBy: "name",
      foldersFirst: true,
      hiddenFilesShown: false,
      folderTreeOpen: true,
      infoPanelOpen: false,
      infoRowOpen: false,
      favoriteIsSet: false,
      textEditing: input.textEditing,
      canRun: (command: string) => a.canRunToolbarRendererCommand(command, context),
    });
    const target = { ...context, focusedPane: (input.shortcut as { focusedPane: unknown }).focusedPane };
    const selection = {
      focusedPane: input.focusedPane,
      lastFocusedPane: input.lastFocusedPane,
      contextMenuPaths: input.contextMenuPaths,
      selectedContentPaths: input.selectedPaths,
      selectedTreePath: input.selectedTreeTargetPath,
      currentPath: input.currentPath,
    };
    cases.push({
      name: `${cases.length}: ${label}`,
      input,
      output: {
        disabled: state.disabledCommands.filter((command) => !ZOOM.has(command)),
        newTab: a.resolveNewTabTargetPath(target) ?? null,
        favorite: a.resolveFavoriteTargetPath(target) ?? null,
        showInFinder: a.resolveShowInFinderPaths(target),
        calculateSize: a.resolveCalculateSizePaths(target),
        openTerminal: t.resolveOpenInTerminalPaths(selection),
        openPaths: t.resolveOpenSelectionPaths(selection),
        editPaths: t.resolveEditSelectionPaths(selection),
        rootTree: t.resolveRootTreeTargetPath({
          focusedPane: input.focusedPane,
          lastFocusedPane: input.lastFocusedPane,
          contextMenuFolderPath: input.contextMenuFolderPath,
          selectedContentFolderPath: input.selectedContentFolderPath,
          selectedTreePath: input.selectedTreeTargetPath,
          currentPath: input.currentPath,
        }),
      },
    });
  };

  const base = (): Record<string, any> => ({
    shortcut: {
      actionNoticeOpen: false,
      copyPasteModalOpen: false,
      focusedPane: "content",
      locationSheetOpen: false,
      mainView: "explorer",
      selectedTreeTargetKind: null,
    },
    currentPath: `${HOME}/Documents`,
    selectedPaths: [],
    entries: [],
    selectedEntry: null,
    selectedTreeTargetPath: null,
    clipboardHasItems: false,
    clipboardEmptyReady: false,
    pasteDestinationPath: null,
    isSearchMode: false,
    openItemLimit: 5,
    writeOperationLocked: false,
    textEditing: false,
    focusedPane: "content",
    lastFocusedPane: null,
    contextMenuPaths: [],
    contextMenuFolderPath: null,
    selectedContentFolderPath: null,
  });

  // Hand-picked.
  add("nothing selected", base());
  add("one file selected", {
    ...base(),
    selectedPaths: [`${HOME}/Documents/a.txt`],
    entries: [{ path: `${HOME}/Documents/a.txt`, kind: "file" }],
    selectedEntry: { path: `${HOME}/Documents/a.txt`, kind: "file" },
    homePath: HOME,
  });
  add("everything on a folder tree", {
    ...base(),
    shortcut: { ...base().shortcut, focusedPane: "tree", selectedTreeTargetKind: "filesystemFolder" },
    selectedTreeTargetPath: `${HOME}/Documents`,
    focusedPane: "tree",
    homePath: HOME,
    trashPath: `${HOME}/.Trash`,
  });
  add("in the trash", {
    ...base(),
    currentPath: `${HOME}/.Trash`,
    selectedPaths: [`${HOME}/.Trash/old`],
    entries: [{ path: `${HOME}/.Trash/old`, kind: "directory" }],
    homePath: HOME,
    trashIsEmpty: false,
  });
  add("a dialog open", { ...base(), shortcut: { ...base().shortcut, locationSheetOpen: true }, homePath: HOME });
  add("help", { ...base(), shortcut: { ...base().shortcut, mainView: "help" }, homePath: HOME });
  add("a text field is edited", { ...base(), textEditing: true, shortcut: { ...base().shortcut, copyPasteModalOpen: true } });

  const randomPath = (parent: string, name: string) => (parent === "/" ? `/${name}` : `${parent}/${name}`);
  while (cases.length < 300) {
    const input = base();
    const folder = rng.pick(FOLDERS);
    input.currentPath = folder;
    input.shortcut = {
      actionNoticeOpen: rng.chance(0.07),
      copyPasteModalOpen: rng.chance(0.07),
      focusedPane: rng.pick(["content", "content", "tree", null]),
      locationSheetOpen: rng.chance(0.07),
      mainView: rng.pick(["explorer", "explorer", "explorer", "help", "settings"]),
      selectedTreeTargetKind: rng.pick([null, "filesystemFolder", "favorite", "favoritesRoot"]),
    };
    input.focusedPane = rng.pick(["content", "tree", null]);
    input.lastFocusedPane = rng.pick(["content", "tree", null]);
    const count = rng.pick([0, 0, 1, 1, 2, 3, 6, 8]);
    input.entries = Array.from({ length: count }, (_, index) => ({
      path: rng.chance(0.85) ? randomPath(rng.chance(0.8) ? folder : rng.pick(FOLDERS), `${rng.pick(NAMES)}${index}`) : rng.pick(FOLDERS),
      kind: rng.pick(KINDS),
    }));
    const pool = input.entries.map((entry: { path: string }) => entry.path);
    input.selectedPaths = rng.chance(0.3)
      ? []
      : Array.from({ length: rng.pick([1, 1, 2, 3, 7]) }, () => (pool.length > 0 && rng.chance(0.85) ? rng.pick(pool) : randomPath(rng.pick(FOLDERS), rng.pick(NAMES))));
    input.selectedEntry = rng.chance(0.5) && input.entries.length > 0 ? rng.pick(input.entries) : null;
    input.selectedTreeTargetPath = rng.chance(0.6) ? rng.pick(FOLDERS) : null;
    input.clipboardHasItems = rng.chance(0.4);
    input.clipboardEmptyReady = !input.clipboardHasItems && rng.chance(0.2);
    input.pasteDestinationPath = rng.chance(0.6) ? rng.pick(FOLDERS) : null;
    input.isSearchMode = rng.chance(0.3);
    input.openItemLimit = rng.pick([1, 2, 5, 5, 50]);
    input.writeOperationLocked = rng.chance(0.2);
    input.textEditing = rng.chance(0.15);
    input.contextMenuPaths = rng.chance(0.15) ? [rng.pick(FOLDERS)] : [];
    input.contextMenuFolderPath = rng.chance(0.15) ? rng.pick(FOLDERS) : null;
    input.selectedContentFolderPath = rng.chance(0.3) ? rng.pick(FOLDERS) : null;
    const optional = (key: string, value: unknown) => {
      if (rng.chance(0.6)) input[key] = value;
    };
    optional("canGoBack", rng.chance(0.5));
    optional("canGoForward", rng.chance(0.5));
    optional("hasCachedSearch", rng.chance(0.5));
    optional("tabCount", rng.pick([0, 1, 2, 5]));
    optional("trashPath", rng.chance(0.2) ? null : rng.pick(FOLDERS));
    optional("homePath", rng.chance(0.15) ? "" : HOME);
    optional("trashIsEmpty", rng.pick([true, false, null]));
    optional("ejectTargetPath", rng.chance(0.4) ? null : rng.pick(FOLDERS));
    add(`random ${cases.length}`, input);
  }
  return cases;
}
