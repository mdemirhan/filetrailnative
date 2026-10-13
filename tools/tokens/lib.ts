// Shared helpers for the token generators: reading the pinned reference and CSS colour math.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

export const REFERENCE_REPO = "/Users/tcmudemirhan/src/tsproj/filetrail";
export const REFERENCE_COMMIT = "e4d0872";
export const RENDERER = "apps/desktop/src/renderer";
export const REPO_ROOT = resolve(import.meta.dir, "../..");
export const GOLDEN_DIR = join(REPO_ROOT, "Tests/Golden");

// The file as it is at the pinned commit, never the working tree.
export function referenceFile(path: string): string {
  const result = Bun.spawnSync(["git", "-C", REFERENCE_REPO, "show", `${REFERENCE_COMMIT}:${path}`]);
  if (result.exitCode !== 0) {
    throw new Error(`git show ${REFERENCE_COMMIT}:${path} failed: ${result.stderr.toString()}`);
  }
  return result.stdout.toString();
}

export function writeGolden(name: string, value: unknown): void {
  const path = join(GOLDEN_DIR, name);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

export type Color = { r: number; g: number; b: number; a: number };

const NAMED: Record<string, Color> = {
  white: { r: 255, g: 255, b: 255, a: 1 },
  black: { r: 0, g: 0, b: 0, a: 1 },
  transparent: { r: 0, g: 0, b: 0, a: 0 },
};

export function parseColor(text: string): Color | null {
  const value = text.trim().toLowerCase();
  if (value in NAMED) {
    return { ...NAMED[value] };
  }
  const hex = /^#([0-9a-f]{6})$/u.exec(value);
  if (hex) {
    const n = Number.parseInt(hex[1], 16);
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a: 1 };
  }
  const rgb = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/u.exec(value);
  if (rgb) {
    return {
      r: Number(rgb[1]),
      g: Number(rgb[2]),
      b: Number(rgb[3]),
      a: rgb[4] === undefined ? 1 : Number(rgb[4]),
    };
  }
  return null;
}

// Canonical spelling: #rrggbb when opaque, otherwise rgba(r, g, b, a).
export function formatColor(color: Color): string {
  const r = Math.round(color.r);
  const g = Math.round(color.g);
  const b = Math.round(color.b);
  if (color.a === 1) {
    const hex = (n: number) => n.toString(16).padStart(2, "0");
    return `#${hex(r)}${hex(g)}${hex(b)}`;
  }
  return `rgba(${r}, ${g}, ${b}, ${Number(color.a.toFixed(4))})`;
}

// color-mix(in srgb, A p%, B q%) per CSS Color 4: premultiplied interpolation; a missing
// percentage is the rest of 100%; if they sum to less than 100% the alpha is scaled down.
export function mixColors(a: Color, pa: number | null, b: Color, pb: number | null): Color {
  let p1 = pa;
  let p2 = pb;
  if (p1 === null && p2 === null) {
    p1 = 50;
    p2 = 50;
  } else if (p1 === null) {
    p1 = 100 - (p2 as number);
  } else if (p2 === null) {
    p2 = 100 - p1;
  }
  const sum = p1 + (p2 as number);
  const w1 = p1 / sum;
  const w2 = (p2 as number) / sum;
  const alpha = a.a * w1 + b.a * w2;
  const channel = (x: number, y: number) =>
    alpha === 0 ? 0 : (x * a.a * w1 + y * b.a * w2) / alpha;
  return {
    r: channel(a.r, b.r),
    g: channel(a.g, b.g),
    b: channel(a.b, b.b),
    a: alpha * Math.min(1, sum / 100),
  };
}

// Splits on top-level separators (outside parentheses).
export function splitTopLevel(text: string, separator = ","): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = "";
  for (const ch of text) {
    if (ch === "(") depth += 1;
    if (ch === ")") depth -= 1;
    if (ch === separator && depth === 0) {
      parts.push(current.trim());
      current = "";
    } else {
      current += ch;
    }
  }
  parts.push(current.trim());
  return parts;
}

// Evaluates `color-mix(in srgb, X p%, Y q%)` when both colours are literal; null otherwise.
export function evalColorMix(expression: string): string | null {
  const match = /^color-mix\(\s*in srgb\s*,([\s\S]*)\)$/u.exec(expression.trim());
  if (!match) return null;
  const operands = splitTopLevel(match[1]);
  if (operands.length !== 2) return null;
  const parsed = operands.map((operand) => {
    const percent = /^(.*?)\s+([\d.]+)%$/u.exec(operand);
    const colorText = percent ? percent[1] : operand;
    const color = parseColor(colorText);
    return color ? { color, percent: percent ? Number(percent[2]) : null } : null;
  });
  if (!parsed[0] || !parsed[1]) return null;
  return formatColor(
    mixColors(parsed[0].color, parsed[0].percent, parsed[1].color, parsed[1].percent),
  );
}
