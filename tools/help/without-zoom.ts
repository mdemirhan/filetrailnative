// The reference's Help content with the zoom rows taken out (DEVIATIONS D-005): the zoom commands are not in the port's
// command table, so no sentence or shortcut row may name them. Changes the reference's arrays in place, so the
// reference's own functions (listShortcuts, searchHelp) then answer for the content the port has.

type Row = { label: string };
type Section = { title: string; rows: Row[] };
type Topic = { sections: Section[] };
type Item = { command?: string };

const ZOOM_COMMANDS = new Set(["zoomIn", "zoomOut", "resetZoom"]);

export function withoutZoom<T extends Topic, I extends Item>(topics: T[], items: I[]): { topics: T[]; items: I[] } {
  for (let index = items.length - 1; index >= 0; index -= 1) {
    if (ZOOM_COMMANDS.has(items[index]?.command ?? "")) {
      items.splice(index, 1);
    }
  }
  for (const topic of topics) {
    for (const section of topic.sections) {
      const at = section.rows.findIndex((row) => row.label === "Zoom");
      if (section.title === "Appearance" && at >= 0) {
        section.rows.splice(at, 1);
      }
    }
  }
  return { topics, items };
}
