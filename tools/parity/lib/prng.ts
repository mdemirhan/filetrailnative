// A small seeded PRNG (mulberry32), so a suite's random cases are the same on every run.

export class Prng {
  private state: number;

  constructor(seed: number) {
    this.state = seed >>> 0;
  }

  // A float in [0, 1).
  next(): number {
    this.state = (this.state + 0x6d2b79f5) >>> 0;
    let t = this.state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  // An integer in [min, max], both included.
  int(min: number, max: number): number {
    return min + Math.floor(this.next() * (max - min + 1));
  }

  chance(probability: number): boolean {
    return this.next() < probability;
  }

  pick<T>(items: readonly T[]): T {
    if (items.length === 0) {
      throw new Error("pick from an empty list");
    }
    return items[this.int(0, items.length - 1)] as T;
  }

  // `count` items, each picked independently.
  pickMany<T>(items: readonly T[], count: number): T[] {
    return Array.from({ length: count }, () => this.pick(items));
  }
}
