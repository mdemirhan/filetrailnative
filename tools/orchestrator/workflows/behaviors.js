export const meta = {
  name: 'port-behaviors',
  description: 'Extract code-derived behavior rules of the original File Trail, one area per agent',
  phases: [{ title: 'Extract', detail: 'one read-only agent per behavior area' }],
}

// args: { repo, areas: [{ key, title, improvements, files, tests }] }
const A = args
const SCHEMA = {
  type: 'object',
  properties: {
    file: { type: 'string' },
    ruleCount: { type: 'number' },
    summary: { type: 'string', description: 'At most 6 lines: what the area does beyond Finder, in code terms' },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['file', 'ruleCount', 'summary'],
}

function prompt(area) {
  return `First read ${A.repo}/docs/port/state/preamble.md (the "Places" and "Rules" parts apply; you change no Swift code).

## Task: behavior rules for "${area.title}" (prefix B-${area.key})
File Trail is being ported from Electron/TypeScript to native Swift. Its improvements over Finder live in code details, not in its README. Write the behavior rules of this area **from the code and its tests**, precise enough that each rule can be proven by one test or one scripted UI step.

Read, in the original at /Users/tcmudemirhan/src/tsproj/filetrail (read-only):
${area.files.map((f) => `- ${f}`).join('\n')}
and the tests that encode this area's behavior:
${area.tests.map((f) => `- ${f}`).join('\n')}
Follow imports into other files when a behavior depends on them. Use docs/port/inventory/*.md in ${A.repo} only as a map, never as the source.

Write ${A.repo}/docs/port/behaviors/${area.key.toLowerCase()}.md (create the folder if needed; do not touch any other file; do not commit). Format:
- A title, then 3-6 lines on what this area does better than Finder, in code terms. Improvements it belongs to: ${area.improvements}.
- Then sections by sub-topic, each with a table: | ID | Behavior | Evidence | Test ids |
  - ID: B-${area.key}-001, -002, … in order.
  - Behavior: one testable rule. State trigger, condition and exact outcome: which item ends up selected, where focus goes, what scrolls, what is restored, what is dimmed or hidden, the exact wording shown, delays and thresholds in ms or px, keys and modifiers, and what does NOT happen. Example of the right grain: "Back to a folder restores the selection and scroll position it had when it was left; if the selected item no longer exists, the next item in sort order is selected" — not "Back works".
  - Evidence: file:line (one or two) where the rule is decided.
  - Test ids: the tests.tsv ids (docs/port/parity/tests.tsv in ${A.repo}; match by file and title) of original tests that check this rule, or "-".
- Cover edge cases: empty folders, folders deleted while shown, permission errors, search mode vs folder mode, several windows or tabs, a write operation running, a dialog or rename field open, the window inactive.
- Expect 60-180 rules. Prefer more, smaller rules over fewer broad ones. Don't invent: if the code is ambiguous, add it under a final "Open questions" section.

Return the file path, the rule count, a short summary and open questions.`
}

phase('Extract')
const results = await parallel(
  A.areas.map((area) => () =>
    agent(prompt(area), { label: `behaviors:${area.key}`, phase: 'Extract', schema: SCHEMA, model: 'sonnet', effort: 'medium' }),
  ),
)
return results.map((r, i) => ({ key: A.areas[i].key, ...(r || { file: null, ruleCount: 0, summary: 'agent returned nothing' }) }))
