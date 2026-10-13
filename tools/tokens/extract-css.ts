// Extracts every custom property of the reference's styles.css `:root`, light and dark blocks,
// with its resolved value, into Tests/Golden/css-tokens.json.
//   bun tools/tokens/extract-css.ts
import {
  RENDERER,
  REFERENCE_COMMIT,
  evalColorMix,
  formatColor,
  parseColor,
  referenceFile,
  writeGolden,
} from "./lib";

const STYLES_PATH = `${RENDERER}/styles.css`;

type Declarations = Map<string, string>;

// Which cascade layer a rule's selector feeds. `:root[data-theme=...]` beats plain `:root`
// whatever the source order, so the layers are merged in that order.
type Layer = "base" | "light" | "dark";

function layerFor(selector: string): Layer | null {
  const normalized = selector.replace(/\s+/gu, "").replace(/'/gu, '"');
  if (normalized === ":root") return "base";
  if (normalized === ':root[data-theme="light"]') return "light";
  if (normalized === ':root[data-theme="dark"]') return "dark";
  return null;
}

function stripComments(css: string): string {
  return css.replace(/\/\*[\s\S]*?\*\//gu, "");
}

type Collected = {
  layers: Record<Layer, Declarations>;
  reducedMotion: Declarations;
};

// Walks the stylesheet by braces, collecting declarations of the `:root` rules at the top
// level and inside the reduced-motion media query. Quoted strings and url() are skipped over.
function collect(css: string): Collected {
  const layers: Record<Layer, Declarations> = {
    base: new Map(),
    light: new Map(),
    dark: new Map(),
  };
  const reducedMotion: Declarations = new Map();
  const stack: string[] = [];
  let buffer = "";
  let i = 0;

  const current = (): { layer: Layer | null; media: boolean } => {
    if (stack.length === 1) return { layer: layerFor(stack[0]), media: false };
    if (stack.length === 2 && /prefers-reduced-motion:\s*reduce/u.test(stack[0])) {
      return { layer: layerFor(stack[1]), media: true };
    }
    return { layer: null, media: false };
  };

  const declaration = (text: string) => {
    const target = current();
    if (!target.layer) return;
    const colon = text.indexOf(":");
    if (colon < 0) return;
    const name = text.slice(0, colon).trim();
    if (!name.startsWith("--")) return;
    const value = text.slice(colon + 1).replace(/\s+/gu, " ").trim();
    if (target.media) {
      reducedMotion.set(name, value);
    } else {
      layers[target.layer].set(name, value);
    }
  };

  while (i < css.length) {
    const ch = css[i];
    if (ch === '"' || ch === "'") {
      const end = css.indexOf(ch, i + 1);
      buffer += css.slice(i, end + 1);
      i = end + 1;
      continue;
    }
    if (ch === "(") {
      let depth = 1;
      let j = i + 1;
      while (j < css.length && depth > 0) {
        if (css[j] === "(") depth += 1;
        if (css[j] === ")") depth -= 1;
        j += 1;
      }
      buffer += css.slice(i, j);
      i = j;
      continue;
    }
    if (ch === "{") {
      stack.push(buffer.trim());
      buffer = "";
    } else if (ch === "}") {
      declaration(buffer);
      buffer = "";
      stack.pop();
    } else if (ch === ";") {
      declaration(buffer);
      buffer = "";
    } else {
      buffer += ch;
    }
    i += 1;
  }
  return { layers, reducedMotion };
}

// Replaces var(--x[, fallback]) with the property's value, recursively. Returns null on a
// reference to a property that is not defined (and has no fallback).
function substituteVars(value: string, lookup: (name: string) => string | null, depth = 0): string | null {
  if (depth > 20) return null;
  let result = "";
  let i = 0;
  while (i < value.length) {
    if (value.startsWith("var(", i)) {
      let level = 1;
      let j = i + 4;
      while (j < value.length && level > 0) {
        if (value[j] === "(") level += 1;
        if (value[j] === ")") level -= 1;
        j += 1;
      }
      const inner = value.slice(i + 4, j - 1);
      const comma = inner.indexOf(",");
      const name = (comma < 0 ? inner : inner.slice(0, comma)).trim();
      const fallback = comma < 0 ? null : inner.slice(comma + 1).trim();
      const found = lookup(name) ?? fallback;
      if (found === null) return null;
      const expanded = substituteVars(found, lookup, depth + 1);
      if (expanded === null) return null;
      result += expanded;
      i = j;
    } else {
      result += value[i];
      i += 1;
    }
  }
  return result;
}

// Evaluates color-mix() calls whose operands are literal, innermost first, then writes every
// colour in its canonical spelling.
function evaluateColors(value: string): string {
  let text = value;
  for (;;) {
    const matches = [...text.matchAll(/color-mix\(/gu)];
    if (matches.length === 0) break;
    let replaced = false;
    for (const match of matches.reverse()) {
      const start = match.index as number;
      let level = 1;
      let j = start + "color-mix(".length;
      while (j < text.length && level > 0) {
        if (text[j] === "(") level += 1;
        if (text[j] === ")") level -= 1;
        j += 1;
      }
      const call = text.slice(start, j);
      if (call.slice(1).includes("color-mix(")) continue;
      const mixed = evalColorMix(call);
      if (mixed === null) continue;
      text = text.slice(0, start) + mixed + text.slice(j);
      replaced = true;
      break;
    }
    if (!replaced) break;
  }
  return text.replace(/rgba?\([^)]*\)/gu, (call) => {
    const color = parseColor(call);
    return color ? formatColor(color) : call;
  });
}

type Token = { raw: string; value?: string; unresolved?: true };

function resolveTheme(declarations: Declarations): Record<string, Token> {
  const out: Record<string, Token> = {};
  const lookup = (name: string) => declarations.get(name) ?? null;
  for (const name of [...declarations.keys()].sort()) {
    const raw = declarations.get(name) as string;
    const substituted = substituteVars(raw, lookup);
    if (substituted === null) {
      out[name] = { raw, unresolved: true };
      continue;
    }
    const value = evaluateColors(substituted);
    out[name] = /var\(|color-mix\(/u.test(value) ? { raw, unresolved: true } : { raw, value };
  }
  return out;
}

const { layers, reducedMotion } = collect(stripComments(referenceFile(STYLES_PATH)));
const merge = (...maps: Declarations[]): Declarations => {
  const merged: Declarations = new Map();
  for (const map of maps) for (const [name, value] of map) merged.set(name, value);
  return merged;
};

writeGolden("css-tokens.json", {
  source: { commit: REFERENCE_COMMIT, file: STYLES_PATH },
  light: resolveTheme(merge(layers.base, layers.light)),
  dark: resolveTheme(merge(layers.base, layers.dark)),
  reducedMotion: Object.fromEntries([...reducedMotion].sort(([a], [b]) => a.localeCompare(b))),
});
