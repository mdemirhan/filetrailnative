// Writes the Swift tables of the shortcut commands, renderer commands, toolbar items and tree-focus buckets from the reference:
//   bun tools/parity/tables/commands.ts   (then xcrun swift-format format -i -r Sources/FTFoundation/Commands)
import { REPO_ROOT, importReference, referenceRoot } from "../lib/reference";
import { join } from "node:path";
import { writeFileSync } from "node:fs";

const out = join(REPO_ROOT, "Sources/FTFoundation/Commands");
const s: any = await importReference("apps/desktop/src/shared/shortcuts.ts");
const rc: any = await importReference("apps/desktop/src/shared/rendererCommands.ts");
const t: any = await importReference("apps/desktop/src/shared/toolbarItems.ts");
const p: any = await importReference("apps/desktop/src/renderer/lib/shortcutPolicy.ts");

const ZOOM = new Set(["zoomIn", "zoomOut", "resetZoom"]);
const q = (v: string) => JSON.stringify(v);
const swiftString = (v: string) => q(v).replace(/\\u([0-9a-f]{4})/g, "\\u{$1}");

// ---- RendererCommand
const commands: string[] = rc.RENDERER_COMMAND_TYPES.filter((c: string) => !ZOOM.has(c));
{
  let o = "// Generated from apps/desktop/src/shared/rendererCommands.ts (RENDERER_COMMAND_TYPES) by tools/parity; zoomIn, zoomOut and resetZoom are left out (DEVIATIONS D-005).\n\n";
  o += "/// The commands the application menu, the toolbar and the keys send to the explorer window. The raw value is the original's command name.\n";
  o += "public enum RendererCommand: String, CaseIterable, Sendable, Hashable, Codable {\n";
  for (const c of commands) o += `    case ${c}\n`;
  o += "\n    /// Whether `value` names a command (`isRendererCommandType`).\n";
  o += "    public static func isRendererCommandType(_ value: String) -> Bool {\n        RendererCommand(rawValue: value) != nil\n    }\n}\n";
  writeFileSync(`${out}/RendererCommand.swift`, o);
}

// ---- Shortcut commands
const sc = s.SHORTCUT_COMMANDS.filter((c: any) => !ZOOM.has(c.id));
{
  let o = "// Generated from SHORTCUT_COMMANDS in apps/desktop/src/shared/shortcuts.ts by tools/parity; Zoom In, Zoom Out and Actual Size are left out (DEVIATIONS D-005).\n\n";
  o += "public enum ShortcutGroup: String, CaseIterable, Sendable, Hashable {\n";
  for (const g of s.SHORTCUT_GROUPS) o += `    case ${g}\n`;
  o += "\n    /// SHORTCUT_GROUP_LABELS.\n    public var label: String {\n        switch self {\n";
  for (const g of s.SHORTCUT_GROUPS) o += `        case .${g}: ${swiftString(s.SHORTCUT_GROUP_LABELS[g])}\n`;
  o += "        }\n    }\n}\n\n";
  o += "/// The id of a command in the shortcut table; the raw value is the original's id.\n";
  o += "public enum ShortcutCommandID: String, Codable, CaseIterable, Sendable, Hashable {\n";
  for (const c of sc) o += `    case ${c.id}\n`;
  o += "}\n\n";
  o += "extension ShortcutCommands {\n    /// SHORTCUT_COMMANDS, in the original's order.\n    public static let all: [ShortcutCommandDefinition] = [\n";
  for (const c of sc) {
    const parts = [`id: .${c.id}`, `label: ${swiftString(c.label)}`, `group: .${c.group}`, `defaults: [${c.defaults.map(swiftString).join(", ")}]`];
    if (c.menuPath) parts.push(`menuPath: ${swiftString(c.menuPath)}`);
    if (c.fixed) parts.push("fixed: true");
    o += `        ShortcutCommandDefinition(${parts.join(", ")}),\n`;
  }
  o += "    ]\n}\n";
  writeFileSync(`${out}/ShortcutCommandTable.swift`, o);
}

// ---- Toolbar items
{
  const icons = [
    "back","forward","up","location","hidden","hiddenShown","refresh","icons","list","details","drawer","sidebar","edit","chevron","open","theme","close","sortAsc","sortDesc","help","settings","search","trash","infoRow","foldersFirst","copy","cut","paste","clear","stop","move","duplicate","newFolder","terminal","copyPath","rename","separatorVertical","more","overflow","sort","title","newTab","quickLook","showInFinder","revealInFolder","calculateSize",
  ];
  const used = new Set(t.TOOLBAR_ITEM_DEFINITIONS.map((d: any) => d.icon));
  for (const u of used) if (!icons.includes(u as string)) throw new Error(`icon ${u} missing`);
  let o = "// Generated from apps/desktop/src/shared/toolbarItems.ts by tools/parity.\n\n";
  o += "/// The icon a toolbar item draws (`ToolbarIconName`).\npublic enum ToolbarIconName: String, CaseIterable, Sendable, Hashable {\n";
  for (const i of icons) o += `    case ${i}\n`;
  o += "}\n\npublic enum ToolbarItemKind: String, Sendable, Hashable {\n    case button, toggle, menu, composite, separator\n}\n\n";
  o += "/// The items of the toolbar over the file list; the raw value is what is saved in the toolbar's order.\n";
  o += "public enum ToolbarItemID: String, Codable, CaseIterable, Sendable, Hashable {\n";
  for (const d of t.TOOLBAR_ITEM_DEFINITIONS) o += `    case ${d.id}\n`;
  o += "}\n\nextension ToolbarItems {\n    /// TOOLBAR_ITEM_DEFINITIONS, in the original's order.\n    public static let definitions: [ToolbarItemDefinition] = [\n";
  for (const d of t.TOOLBAR_ITEM_DEFINITIONS) {
    const parts = [`id: .${d.id}`, `label: ${swiftString(d.label)}`, `icon: .${d.icon}`, `kind: .${d.kind}`];
    if (d.commandType) {
      if (ZOOM.has(d.commandType)) throw new Error("zoom toolbar command");
      parts.push(`commandType: .${d.commandType}`);
    }
    if (d.topRequired) parts.push("topRequired: true");
    if (d.shortcutCommand) parts.push(`shortcutCommand: .${d.shortcutCommand}`);
    if (d.tooltipLabel) parts.push(`tooltipLabel: ${swiftString(d.tooltipLabel)}`);
    if (d.allowDuplicates) parts.push("allowDuplicates: true");
    o += `        ToolbarItemDefinition(${parts.join(", ")}),\n`;
  }
  o += "    ]\n\n    /// DEFAULT_TOP_TOOLBAR_ITEMS.\n    public static let defaultTopItems: [ToolbarItemID] = [\n";
  for (const id of t.DEFAULT_TOP_TOOLBAR_ITEMS) o += `        .${id},\n`;
  o += "    ]\n\n    /// The order the items are offered in while the toolbar is customized (TOP_TOOLBAR_PALETTE_ORDER).\n    static let paletteOrder: [ToolbarItemID] = [\n";
  // The palette order is a module-private const; read it from the source.
  const src = await Bun.file(join(referenceRoot(), "apps/desktop/src/shared/toolbarItems.ts")).text();
  const block = /const TOP_TOOLBAR_PALETTE_ORDER[^=]*=\s*\[([\s\S]*?)\];/.exec(src)![1]!;
  const palette = [...block.matchAll(/"([A-Za-z]+)"/g)].map((m) => m[1]);
  for (const id of palette) o += `        .${id},\n`;
  o += "    ]\n}\n";
  writeFileSync(`${out}/ToolbarItemTable.swift`, o);
  console.log("palette", palette.length);
}

// ---- Tree-focus buckets
{
  const keep = (id: string) => !ZOOM.has(id);
  let o = "// Generated from apps/desktop/src/renderer/lib/shortcutPolicy.ts (the tree-focus bucket tables) by tools/parity; the zoom commands are left out (DEVIATIONS D-005).\n\n";
  o += "/// What a command or key does while the folder tree has the keyboard.\npublic enum TreeFocusShortcutBucket: String, Sendable, Hashable {\n    case treeNavigation, globalExplorer, contentOnly\n}\n\n";
  o += "extension ShortcutPolicy {\n    /// RENDERER_COMMAND_TREE_FOCUS_BUCKETS.\n    public static func treeFocusBucket(of command: RendererCommand) -> TreeFocusShortcutBucket {\n        switch command {\n";
  const byBucket = new Map<string, string[]>();
  for (const [id, bucket] of Object.entries(p.RENDERER_COMMAND_TREE_FOCUS_BUCKETS)) {
    if (!keep(id)) continue;
    if (!byBucket.has(bucket as string)) byBucket.set(bucket as string, []);
    byBucket.get(bucket as string)!.push(id);
  }
  for (const [bucket, ids] of byBucket) o += `        case ${ids.map((i) => "." + i).join(", ")}:\n            .${bucket}\n`;
  o += "        }\n    }\n}\n\n";
  o += "/// The explorer's raw key handlers (`RAW_EXPLORER_SHORTCUT_IDS`).\npublic enum RawExplorerShortcutID: String, CaseIterable, Sendable, Hashable {\n";
  for (const id of p.RAW_EXPLORER_SHORTCUT_IDS) o += `    case ${id}\n`;
  o += "}\n\nextension ShortcutPolicy {\n    /// RAW_EXPLORER_SHORTCUT_TREE_FOCUS_BUCKETS.\n    public static func treeFocusBucket(of shortcut: RawExplorerShortcutID) -> TreeFocusShortcutBucket {\n        switch shortcut {\n";
  const raw = new Map<string, string[]>();
  for (const [id, bucket] of Object.entries(p.RAW_EXPLORER_SHORTCUT_TREE_FOCUS_BUCKETS)) {
    if (!raw.has(bucket as string)) raw.set(bucket as string, []);
    raw.get(bucket as string)!.push(id);
  }
  for (const [bucket, ids] of raw) o += `        case ${ids.map((i) => "." + i).join(", ")}:\n            .${bucket}\n`;
  o += "        }\n    }\n}\n";
  writeFileSync(`${out}/TreeFocusBuckets.swift`, o);
}
console.log("commands", commands.length, "shortcut commands", sc.length);
