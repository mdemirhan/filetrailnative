export const meta = {
  name: 'port-ui-check',
  description: 'Checkpoint UI run of the File Trail port on main: GUI tests, screenshot comparison, acceptance flows, visual review',
  whenToUse: 'Run by the port orchestrator at phase ends and before the user\'s hands-on checks (docs/port/ORCHESTRATOR.md)',
  phases: [
    { title: 'Window run', detail: 'one agent runs every window check once, on main' },
    { title: 'Visual review', detail: 'reviews the captures the window run took' },
  ],
}

// args: { checkpoint, repo, scenarios?: string, acceptance?: string, bench?: boolean, wps?: [{ id, title }] }
// The only place window checks run (user, 2026-10-14), as the original runs its e2e suite only in CI. Nothing is fixed
// here: failures and visual findings come back attributed to work packages, and the orchestrator turns them into
// fix work packages.
const A = args
const PRE = `First read ${A.repo}/docs/port/state/preamble.md and follow it.`
const CAPTURES = `~/Library/Caches/filetrail-port/checkpoint-captures/${A.checkpoint}`

const RESULT = {
  type: 'object',
  properties: {
    head: { type: 'string', description: 'The main sha that was checked' },
    summary: { type: 'string', description: 'One line per command: pass/fail and a key number' },
    failures: {
      type: 'array',
      items: { type: 'object', properties: { wp: { type: 'string' }, detail: { type: 'string' } }, required: ['wp', 'detail'] },
      description: 'Each failing test, scenario or flow, with the work package that owns it (or "unknown") and at most 40 relevant lines',
    },
    flaky: { type: 'array', items: { type: 'string' } },
    bench: { type: 'string', description: 'The bench numbers, when it ran' },
    captures: { type: 'string', description: 'Absolute path of the copied capture output' },
  },
  required: ['head', 'summary', 'failures'],
}
const FINDINGS = {
  type: 'object',
  properties: {
    checked: { type: 'array', items: { type: 'string' }, description: 'Each scenario you looked at, with matches or differs' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          wp: { type: 'string' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          title: { type: 'string' },
          evidence: { type: 'string' },
          where: { type: 'string' },
        },
        required: ['wp', 'severity', 'title', 'evidence'],
      },
    },
  },
  required: ['checked', 'findings'],
}

phase('Window run')
const run = await agent(
  `${PRE}\n\n## Your role: checkpoint UI run "${A.checkpoint}"
In your own worktree, check out main detached (\`git checkout --detach main\`) and note its sha. Then run each of these once, from the repo root, each under the GUI lock (\`lockf -k ~/Library/Caches/filetrail-port/gui.lock <command>\`, one take per command):
- \`env FILETRAIL_GUI_TESTS=1 swift test --filter FTAppKitTests\`
- \`tools/capture/run.sh ${A.scenarios || '--tier wp'}\`
- \`tools/capture/run.sh --acceptance ${A.acceptance || ''}\`${A.bench ? '\n- `tools/bench/run.sh --report-only` (report-only: quote its numbers)' : ''}
If a test fails, rerun just that test once with --filter; if it passes alone, list it under flaky. Don't rerun whole suites.
For each failure, name the work package that owns it: the one whose brief (docs/port/state/wp/*.md) owns the failing test, scenario, flow or code, using \`git log\` on the files if needed; "unknown" if none does. Fix nothing and commit nothing.
Finally copy tools/capture/out to ${CAPTURES} (\`rm -rf ${CAPTURES}; mkdir -p $(dirname ${CAPTURES}); cp -R tools/capture/out ${CAPTURES}\`) and return its absolute path in captures.`,
  { label: `ui-run:${A.checkpoint}`, phase: 'Window run', schema: RESULT, isolation: 'worktree', model: 'sonnet', effort: 'medium' },
)

let visual = null
if (run && run.captures) {
  phase('Visual review')
  visual = await agent(
    `${PRE}\n\n## Your role: visual reviewer for checkpoint "${A.checkpoint}"
The checkpoint run captured the scenarios in the original app and in the port at main ${run.head}: ${run.captures}. Each scenario folder holds both sides' screenshots and geometry and a diff/ folder (summary.json, the geometry report, the pixel diff). Don't run the apps or the capture harness again.
${A.wps && A.wps.length ? `Focus on the scenarios of these work packages (read their briefs in ${A.repo}/docs/port/state/wp/):\n${A.wps.map((w) => `- ${w.id} ${w.title}`).join('\n')}\nthen look at the rest more quickly.` : 'Look at every scenario.'}
Look at both screenshots side by side and at the geometry report. List material differences from the original: layout, fonts, sizes, spacing, colors, missing or extra elements. For each, name the work package it belongs to (wp, from the briefs), the scenario, and the evidence (element, both frames or values, the screenshot files). Differences the briefs or docs/port/DEVIATIONS.md accept, and offsets from a package not merged yet, are not findings. Return in \`checked\` each scenario you looked at. Report medium severity or higher only, most severe first.`,
    { label: `visual:${A.checkpoint}`, phase: 'Visual review', schema: FINDINGS, model: 'opus' },
  )
}

return { checkpoint: A.checkpoint, run, visual }
