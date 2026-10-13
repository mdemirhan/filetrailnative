// Runtime conflicts through the reference engine (tools/parity/exec/run.ts): the disk changes
// after the review (or part way through the paste), the engine asks, and each answer it allows is
// given. file-operations.md §2.5 and §7 F and I. Input: the scenario. Output: its outcome.

import type { GoldenCase } from "../lib/golden";
import { ADD_MISSING, REPLACE_ALL, SKIP_ALL, dir, execCases, file, mkdir, remove, scenario, write } from "../exec/scenarios";

export const seed = 0;

const INTO = { destination: "destination" };

const fileAppears = (answer: string) =>
  scenario(
    `a file appears where a file is pasted, answered ${answer}`,
    [file("source/a.txt", "pasted\n"), file("source/b.txt"), dir("destination")],
    { sources: ["source/a.txt", "source/b.txt"], ...INTO },
    { answers: [answer], changes: [{ ops: [write("destination/a.txt", "appeared meanwhile\n")] }] },
  );

const folderAppears = (answer: string) =>
  scenario(
    `a folder appears where a folder is pasted, answered ${answer}`,
    [file("source/f/a.txt", "pasted\n"), file("source/f/b.txt"), dir("destination")],
    { sources: ["source/f"], ...INTO },
    {
      answers: [answer],
      changes: [{ ops: [mkdir("destination/f"), write("destination/f/a.txt", "appeared\n"), write("destination/f/c.txt", "c\n")] }],
    },
  );

const sourceChanged = (answer: string) =>
  scenario(
    `the source changes after the review, answered ${answer}`,
    [file("source/a.txt", "as reviewed\n"), dir("destination")],
    { sources: ["source/a.txt"], ...INTO },
    { answers: [answer], changes: [{ ops: [write("source/a.txt", "changed after the review\n")] }] },
  );

const mergeTargetDeleted = (answer: string) =>
  scenario(
    `the folder to merge into is deleted after the review, answered ${answer}`,
    [file("source/f/a.txt"), file("destination/f/b.txt")],
    { sources: ["source/f"], ...INTO },
    { policy: ADD_MISSING, answers: [answer], changes: [{ ops: [remove("destination/f")] }] },
  );

export async function generate(): Promise<GoldenCase[]> {
  return execCases([
    fileAppears("overwrite"),
    fileAppears("keep_both"),
    fileAppears("skip"),
    folderAppears("merge"),
    folderAppears("overwrite"),
    folderAppears("keep_both"),
    sourceChanged("overwrite"),
    sourceChanged("skip"),
    scenario(
      "the source is deleted after the review: only Skip",
      [file("source/a.txt"), file("source/b.txt"), dir("destination")],
      { sources: ["source/a.txt", "source/b.txt"], ...INTO },
      { answers: ["skip"], changes: [{ ops: [remove("source/a.txt")] }] },
    ),
    mergeTargetDeleted("overwrite"),
    mergeTargetDeleted("skip"),
    scenario(
      "the file to replace is changed after the review, answered overwrite",
      [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n")],
      { sources: ["source/a.txt"], ...INTO },
      { policy: REPLACE_ALL, answers: ["overwrite"], changes: [{ ops: [write("destination/a.txt", "saved again meanwhile\n")] }] },
    ),
    scenario(
      "the file to replace is gone after the review: copied without asking",
      [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n")],
      { sources: ["source/a.txt"], ...INTO },
      { policy: REPLACE_ALL, changes: [{ ops: [remove("destination/a.txt")] }] },
    ),
    scenario(
      "a file appears in a merged folder part way through, answered overwrite",
      [file("source/f/a.txt"), file("source/f/b.txt", "pasted b\n"), file("destination/f/old.txt")],
      { sources: ["source/f"], ...INTO },
      { policy: ADD_MISSING, answers: ["overwrite"], changes: [{ afterEvent: 3, ops: [write("destination/f/b.txt", "appeared\n")] }] },
    ),
    scenario(
      "two questions and one answer: the rest are skipped",
      [file("source/a.txt"), file("source/b.txt"), dir("destination")],
      { sources: ["source/a.txt", "source/b.txt"], ...INTO },
      {
        policy: SKIP_ALL,
        answers: ["keep_both"],
        changes: [{ ops: [write("destination/a.txt", "x\n"), write("destination/b.txt", "y\n")] }],
      },
    ),
    scenario(
      "a moved file whose name is taken after the review, answered overwrite",
      [file("source/a.txt", "moving\n"), dir("destination")],
      { mode: "cut", sources: ["source/a.txt"], ...INTO },
      { answers: ["overwrite"], changes: [{ ops: [write("destination/a.txt", "taken\n")] }] },
    ),
    // "Apply to remaining" (writeService.ts standingResolutions, autoResolve): reused, without a
    // question, only for a conflict of the same kind that offers the same answer.
    scenario(
      "two files appear, Keep Both for the rest: the second isn't asked",
      [file("source/a.txt"), file("source/b.txt"), file("source/c.txt"), dir("destination")],
      { sources: ["source/a.txt", "source/b.txt", "source/c.txt"], ...INTO },
      {
        answers: ["keep_both"],
        applyToRemaining: [true],
        changes: [{ ops: [write("destination/a.txt", "x\n"), write("destination/b.txt", "y\n")] }],
      },
    ),
    scenario(
      "Overwrite for the rest, then a deleted source: asked again, as only Skip suits",
      [file("source/a.txt", "as reviewed\n"), file("source/b.txt"), file("source/c.txt", "as reviewed\n"), dir("destination")],
      { sources: ["source/a.txt", "source/b.txt", "source/c.txt"], ...INTO },
      {
        answers: ["overwrite", "skip"],
        applyToRemaining: [true, false],
        changes: [
          { ops: [write("source/a.txt", "changed\n"), remove("source/b.txt"), write("source/c.txt", "changed too\n")] },
        ],
      },
    ),
    scenario(
      "Merge for the rest, then a file inside: a file is asked about",
      [file("source/f/a.txt", "pasted\n"), file("source/f/b.txt"), file("source/g/c.txt"), dir("destination")],
      { sources: ["source/f", "source/g"], ...INTO },
      {
        answers: ["merge", "overwrite"],
        applyToRemaining: [true, false],
        changes: [
          {
            ops: [
              mkdir("destination/f"),
              write("destination/f/a.txt", "appeared\n"),
              mkdir("destination/g"),
              write("destination/g/d.txt", "d\n"),
            ],
          },
        ],
      },
    ),
  ]);
}
