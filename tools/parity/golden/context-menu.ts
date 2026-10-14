// Which items each right-click menu lists, and which shortcut shows beside them
// (apps/desktop/src/renderer/lib/contextMenu.ts, with shortcutPolicy.ts behind getContextMenuShortcutLabel).
// Input: { kind: "items", surface, options } or { kind: "shortcut", action, context }.
// Output: the item list as the menu builds it (separators by key), or the shortcut label (null for none).
// The rules that hide items for a target (the useMemo of useExplorerActions.ts) live in a React hook and can't be
// imported: the Swift port of them is checked case by case in ContextMenuRulesTests.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Menu = {
  getContextMenuItems: (input: Record<string, unknown>) => Record<string, unknown>[];
};
type Policy = {
  getContextMenuShortcutLabel: (action: string, context: Record<string, unknown>) => string | null;
};

export const seed = 0x5e11c7;

const SURFACES = ["content", "search", "treeFolder", "favorite", "trash", "background"];
const ACTIONS = [
  "open", "openInNewTab", "openInNewWindow", "quickLook", "showInfo", "calculateSize", "revealInFolder", "edit", "cut",
  "copy", "paste", "move", "rename", "duplicate", "newFolder", "terminal", "copyPath", "rootTreeHere", "trash",
  // Items that have no shortcut.
  "openWith", "toggleFavorite", "showInFinder", "deleteImmediately", "emptyTrash", "eject", "viewAs", "sortBy",
  "revealInTree", "showPackageContents",
];
const VIEWS = ["explorer", "help", "settings"];
const PANES = ["tree", "content", null];
const KINDS = ["filesystemFolder", "favorite", "favoritesRoot", null];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const menu = await importReference<Menu>("apps/desktop/src/renderer/lib/contextMenu.ts");
  const policy = await importReference<Policy>("apps/desktop/src/renderer/lib/shortcutPolicy.ts");
  const cases: GoldenCase[] = [];

  const addItems = (name: string, surface: string, options: Record<string, unknown>) => {
    cases.push({
      name,
      input: { kind: "items", surface, options },
      output: menu.getContextMenuItems({ surface, ...options }),
    });
  };

  // Every surface with the options left out, then with each option on its own.
  for (const surface of SURFACES) {
    addItems(`${surface}: defaults`, surface, {});
    addItems(`${surface}: remove from favorites`, surface, { favoriteToggleLabel: "Remove from Favorites" });
    addItems(`${surface}: editor`, surface, { textEditorName: "Visual Studio Code" });
    addItems(`${surface}: targets a folder`, surface, { targetsFolder: true });
    addItems(`${surface}: several items`, surface, { renameLabel: "Rename 1,204 Items…" });
    addItems(`${surface}: eject`, surface, { ejectLabel: "Eject “Backup”" });
    addItems(`${surface}: nulls`, surface, {
      favoriteToggleLabel: null, textEditorName: null, renameLabel: null, ejectLabel: null,
    });
  }

  const context = (random: boolean) => ({
    actionNoticeOpen: random ? rng.chance(0.15) : false,
    copyPasteModalOpen: random ? rng.chance(0.15) : false,
    focusedPane: random ? rng.pick(PANES) : "content",
    locationSheetOpen: random ? rng.chance(0.15) : false,
    mainView: random ? rng.pick(VIEWS) : "explorer",
    selectedTreeTargetKind: random ? rng.pick(KINDS) : null,
  });

  // Every action in the plain states, then at random.
  for (const action of ACTIONS) {
    for (const focusedPane of PANES) {
      for (const selectedTreeTargetKind of KINDS) {
        const ctx = { ...context(false), focusedPane, selectedTreeTargetKind };
        cases.push({
          name: `shortcut ${action}: ${focusedPane}/${selectedTreeTargetKind}`,
          input: { kind: "shortcut", action, context: ctx },
          output: policy.getContextMenuShortcutLabel(action, ctx),
        });
      }
    }
  }
  for (let index = 0; index < 600; index += 1) {
    const action = rng.pick(ACTIONS);
    const ctx = context(true);
    cases.push({
      name: `shortcut random ${index}: ${action}`,
      input: { kind: "shortcut", action, context: ctx },
      output: policy.getContextMenuShortcutLabel(action, ctx),
    });
  }
  return cases;
}
