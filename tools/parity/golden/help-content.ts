// Help's content functions (apps/desktop/src/renderer/lib/helpContent.ts): the shortcut list with the keys chosen in
// Settings, the sentences' {command} mentions, and Search help.
// Input: { overrides, returnKeyAction, queries, texts }: shortcut overrides as saved, what Settings → Files says
// Return does, words typed in Search help, and sentences with mentions.
// Output: { shortcuts, mentions, searches }: listShortcuts() as { group, shortcut, description }; each text filled;
// each query's results as { topic, rows: [section, label], shortcuts }.
// The zoom rows are left out of the content (DEVIATIONS D-005): tools/help/without-zoom.ts takes them out of the
// reference's own arrays before the reference's functions run, and the zoom ids are left out of the overrides.

import { withoutZoom } from "../../help/without-zoom";
import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Shortcuts = Record<string, any>;
type Content = Record<string, any>;
type Display = Record<string, any>;

export const seed = 0x4e1b0c57;

const ZOOM = new Set(["zoomIn", "zoomOut", "resetZoom"]);

const KEYS = [
  "Cmd+K", "Cmd+Shift+J", "Cmd+Plus", "Cmd++", "Cmd+Option+Left", "F5", "Cmd+=", "Ctrl+Cmd+S", "Cmd+Y", "Cmd+Option+Y",
  "Cmd+Shift+Y", "Ctrl+Y", "Cmd+;", "Cmd+Left", "Cmd+Up", "Option+Return", "Shift+Space", "F7", "Cmd+Shift+Backspace",
];

const QUERIES = [
  "", "   ", "trash", "TRASH", "cmd+k", "cmd+shift+j", "cmd+f", "glob patterns", "glob", "regex", "favorites", "tab",
  "go back", "cmd+[", "cmd++", "esc", "nothing matches this", "Folder", "folder tree", "{", "`", "return", "f2",
  "rename", "undo", "⌘", "ß", "İ", "Σ", "info", "hidden", "sort", "quick look", "path bar", "*.pdf", "case",
  "disk", "eject", "view as", "full screen",
];

const TEXTS = [
  "{goBack} goes back; {newTab} opens a tab.",
  "*.{jpg,png} and \\d{2} and {nothing}",
  "{openLocationSheet} finds a folder; {ejectVolume} ejects; {renameSelection} renames",
  "{",
  "}",
  "{}",
  "{ goBack }",
  "{goBack",
  "goBack}",
  "{{goBack}}",
  "{go_back} {goBack2} {GoBack}",
  "plain text",
  "",
  "{showInFinder} {toggleFavorite} {emptyTrash} {mergeAllWindows}",
];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const s = await importReference<Shortcuts>("apps/desktop/src/shared/shortcuts.ts");
  const content = await importReference<Content>("apps/desktop/src/renderer/lib/helpContent.ts");
  const display = await importReference<Display>("apps/desktop/src/renderer/lib/shortcutDisplay.ts");
  withoutZoom(content.HELP_TOPICS, content.SHORTCUT_ITEMS);
  const ids = (s.SHORTCUT_COMMANDS as { id: string; fixed?: boolean }[])
    .filter((command) => !ZOOM.has(command.id) && !command.fixed)
    .map((command) => command.id);

  const cases: GoldenCase[] = [];
  const add = (label: string, overrides: Record<string, string[]>, returnKeyAction: string) => {
    const shortcuts = display.createShortcutDisplay(s.resolveShortcuts(overrides), { returnKeyAction });
    cases.push({
      name: `${cases.length}: ${label}`,
      input: { overrides, returnKeyAction, queries: QUERIES, texts: TEXTS },
      output: {
        shortcuts: content.listShortcuts(shortcuts),
        mentions: TEXTS.map((text) => content.fillShortcutMentions(text, shortcuts)),
        searches: QUERIES.map((query) =>
          content.searchHelp(query, shortcuts).map((result: any) => ({
            topic: result.topic.id,
            rows: result.rows.map((entry: any) => [entry.section, entry.row.label]),
            shortcuts: result.shortcuts,
          })),
        ),
      },
    });
  };

  add("the default keys", {}, "rename");
  add("the default keys, Return opens", {}, "open");
  add(
    "keys chosen in Settings",
    { newTab: [], goBack: ["Cmd+Option+Left"], showInFinder: ["Cmd+Shift+J"], copyPath: ["Cmd+=", "Cmd+Plus"] },
    "rename",
  );
  add("Rename with two more keys", { renameSelection: ["F2", "Cmd+Y"] }, "open");
  add("every changeable command unbound", Object.fromEntries(ids.map((id) => [id, []])), "rename");
  for (let index = 0; index < 24; index += 1) {
    const overrides: Record<string, string[]> = {};
    for (const id of rng.pickMany(ids, rng.int(1, 8))) {
      overrides[id] = rng.pickMany(KEYS, rng.int(0, 2));
    }
    add(`random keys ${index}`, overrides, rng.chance(0.5) ? "rename" : "open");
  }
  return cases;
}
