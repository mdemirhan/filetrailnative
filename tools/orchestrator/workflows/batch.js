export const meta = {
  name: 'port-batch',
  description: 'Build, gate, review, fix and merge one batch of File Trail port work packages',
  whenToUse: 'Run by the port orchestrator (docs/port/ORCHESTRATOR.md) with args from tools/orchestrator/schedule.py start',
  phases: [
    { title: 'Build', detail: 'implementer per work package, in its own worktree' },
    { title: 'Gate', detail: 'windowless gate commands, alongside the reviewers' },
    { title: 'Review', detail: 'lenses by risk tier; findings need a failing test or a diff' },
    { title: 'Fix', detail: 'at most 2 fix loops' },
    { title: 'Window check', detail: 'window checks once on the ready work packages merged together, then the visual review of its captures' },
    { title: 'Integrate', detail: 'merge ready work packages into main, one at a time' },
    { title: 'Critic', detail: 'optional end-of-phase check' },
  ],
}

// args: { batchId, repo, integrate, critic, wps: [{ id, title, risk, model, lenses, gate }] }
// The orchestrator normally starts one batch per work package as soon as its dependencies have merged
// (schedule.py), so a work package merges as soon as it is ready and nothing waits on a slower neighbour.
// Agents read their instructions from the committed files docs/port/state/preamble.md and
// docs/port/state/wp/<id>.md, so the workflow input stays small.
const A = args
// Agent worktrees start from main, the integration branch. Instructions are read by absolute path
// from the orchestrator's checkout, and every agent checks out the branch it needs first.
const PRE = `First read ${A.repo}/docs/port/state/preamble.md and follow it. Your worktree starts on main: never commit to main; check out the branch your role names below.`
const MAX_FIX_LOOPS = 2
const CAPTURES = '~/Library/Caches/filetrail-port/batch-captures'

const CARRY = {
  type: 'array',
  description: 'Work you leave for a later work package, one item each, addressed to its id (from your brief, PLAN.md or docs/port/state/orchestrator.json). The orchestrator appends each to that package\'s brief.',
  items: { type: 'object', properties: { wp: { type: 'string' }, text: { type: 'string' } }, required: ['wp', 'text'] },
}
const IMPL = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['done', 'already_done', 'blocked'] },
    headSha: { type: 'string' },
    summary: { type: 'string', description: 'What was built, in at most 8 lines' },
    testsAdded: { type: 'number' },
    sharedFileRequests: { type: 'array', items: { type: 'string' } },
    deviations: { type: 'array', items: { type: 'string' } },
    blockers: { type: 'array', items: { type: 'string' } },
    carryOver: CARRY,
  },
  required: ['status', 'summary'],
}
const GATE = {
  type: 'object',
  properties: {
    pass: { type: 'boolean' },
    summary: { type: 'string', description: 'One line per gate command: pass/fail and a key number' },
    failures: { type: 'array', items: { type: 'string' }, description: 'At most 40 lines of the relevant output each' },
    flaky: { type: 'array', items: { type: 'string' }, description: 'Tests that failed once and passed when rerun alone' },
  },
  required: ['pass', 'summary'],
}
const FINDINGS = {
  type: 'object',
  properties: {
    checked: { type: 'array', items: { type: 'string' }, description: 'Every item of your checklist, each with one word: matches, differs, or not-applicable' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          wp: { type: 'string', description: 'The work package the finding belongs to (window-check visual review only)' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          title: { type: 'string' },
          evidence: { type: 'string', description: 'A failing test (code + how to run) or a concrete diff/reference-vs-port comparison' },
          where: { type: 'string' },
        },
        required: ['severity', 'title', 'evidence'],
      },
    },
  },
  required: ['checked', 'findings'],
}
const FIX = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['fixed', 'partial', 'blocked'] },
    headSha: { type: 'string' },
    summary: { type: 'string' },
    remaining: { type: 'array', items: { type: 'string' } },
    carryOver: CARRY,
  },
  required: ['status', 'summary'],
}
const WINDOW_CHECK = {
  type: 'object',
  properties: {
    pass: { type: 'boolean' },
    summary: { type: 'string', description: 'One line per command: pass/fail and a key number' },
    failures: {
      type: 'array',
      items: { type: 'object', properties: { wp: { type: 'string' }, detail: { type: 'string' } }, required: ['wp', 'detail'] },
      description: 'Each failure with the work package it belongs to and at most 40 relevant lines',
    },
    flaky: { type: 'array', items: { type: 'string' } },
    captures: { type: 'string', description: 'Absolute path of the copied capture output' },
  },
  required: ['pass', 'summary'],
}
const INTEGRATION = {
  type: 'object',
  properties: {
    merged: { type: 'array', items: { type: 'string' } },
    notMerged: { type: 'array', items: { type: 'object', properties: { wp: { type: 'string' }, reason: { type: 'string' } }, required: ['wp', 'reason'] } },
    ciPass: { type: 'boolean' },
    headSha: { type: 'string' },
    summary: { type: 'string' },
    carryOver: CARRY,
  },
  required: ['merged', 'notMerged', 'ciPass', 'summary'],
}
const CRITIC = {
  type: 'object',
  properties: {
    gaps: { type: 'array', items: { type: 'object', properties: { title: { type: 'string' }, evidence: { type: 'string' }, suggestedWp: { type: 'string' } }, required: ['title', 'evidence'] } },
    summary: { type: 'string' },
  },
  required: ['gaps', 'summary'],
}

const CHECKLIST = `Your checklist is your brief: every test file or T- id it lists, every F- id it cites, every inventory section under Spec, and every bullet of its Goal. Go through each item against the reference and the port, and return each in \`checked\` with matches, differs or not-applicable. A finding comes from an item that differs.`
const LENSES = {
  parity: `PARITY: read the cited reference TypeScript and inventory sections and list behavior the Swift code lacks or changes. ${CHECKLIST}`,
  safety: `SAFETY: look for data loss, destructive steps the user was not shown, and races above the bar in the reference repo docs/FILE_OPERATION_RISKS.md. Accepted risks listed there are not findings. The original's own tests are the bar (user, 2026-10-14): a case the original doesn't handle is not a finding. Your checklist is each write path the brief names; return each in \`checked\`.`,
  performance: 'PERFORMANCE: the bar is the original app\'s ballpark, not PLAN.md section 4\'s targets (user, 2026-10-14). Report only what a user would notice: main-thread disk access or a visible hang, or something clearly slower than the original (about 1.5x or worse, measured). Micro-optimizations are not findings. Return the paths you measured or read in `checked`.',
}

// Commands that put windows on screen (GUI tests, captures, bench) all take the GUI lock. They run once, in the window
// check on the ready work packages merged together, not in each build, gate and fix (user, 2026-10-14). The bench is
// report-only and runs at wave ends, not here. A full capture tier runs only the scenarios the batch changed plus the
// smoke set when the harness has --changed.
const isWindowCmd = (c) => c.includes('gui.lock')
const wpGate = (wp) => wp.gate.filter((c) => !isWindowCmd(c))
const windowGate = (wp) => wp.gate.filter((c) => isWindowCmd(c) && !c.includes('bench/run.sh'))
const gateList = (wp) => (wpGate(wp).length ? wpGate(wp).map((c) => `- \`${c}\``).join('\n') : '- `scripts/ci.sh`')
const windowNote = (wp) => (windowGate(wp).length
  ? `\nThe window checks (${windowGate(wp).map((c) => `\`${c}\``).join(', ')}) are not yours to run in full: the window check runs them once. While you work, run only your own GUI suites and your own scenarios, under the GUI lock, each once when ready, as the preamble says.`
  : '')
const FLAKY = 'If a test fails, rerun just that test once (with --filter). If it passes alone, it is flaky: list it under flaky and treat it as passing; don\'t rerun whole suites.'
const visualWanted = (wp) => (wp.lenses || []).includes('visual')

function modelOpts(wp) {
  if (wp.model === 'opus') return { model: 'opus' }
  if (wp.model === 'haiku') return { model: 'haiku', effort: 'low' }
  return { model: 'sonnet', effort: 'medium' }
}

const head = (wp) => `${PRE}\n\n# Work package ${wp.id}: ${wp.title}\nRisk: ${wp.risk}. Branch: port/${wp.id}.\nYour brief is ${A.repo}/docs/port/state/wp/${wp.id}.md: read it in full before starting.\n`

function implement(wp) {
  return agent(
    `${head(wp)}
## Your role: implementer
You are in your own fresh git worktree (it starts on main).
1. If \`git log main..port/${wp.id} --grep='Port-Stage: implemented' -1\` prints a commit (only this branch's own commits count, never ones inherited from main), the work is already done: return status "already_done" with that sha and a summary taken from the git log. Change nothing.
2. If branch port/${wp.id} exists, an earlier run was interrupted: \`git checkout port/${wp.id}\` and continue from its commits. Otherwise \`git checkout -b port/${wp.id} main\`.
3. Do the work in the brief. Commit as you go with messages "wip(${wp.id}): ...".
4. Run the gate commands below until they all pass:
${gateList(wp)}${windowNote(wp)}
${FLAKY}
5. Make the final commit with a message whose last line is the trailer "Port-Stage: implemented". Then run \`git checkout --detach\` so the branch is free for the next agent.
Return status "blocked" only if the brief cannot be done; list why in blockers, and still commit what you have. Put work you leave for later packages in carryOver, addressed to their ids.`,
    { label: `build:${wp.id}`, phase: 'Build', schema: IMPL, isolation: 'worktree', ...modelOpts(wp) },
  )
}

function gate(wp, round) {
  return agent(
    `${PRE}\n\n## Your role: gate runner for work package ${wp.id}
In your own worktree, run \`git checkout --detach port/${wp.id}\`, then run each gate command below from the repo root, in order, once:
${gateList(wp)}
Report pass only if every command exits 0. ${FLAKY} Do not change or commit anything. For each failure, quote at most 40 relevant lines.`,
    { label: `gate:${wp.id}#${round}`, phase: 'Gate', schema: GATE, isolation: 'worktree', model: 'haiku', effort: 'low' },
  )
}

function lensesFor(wp) {
  // Every work package gets at least a parity review (the low-risk "no reviewer" cut was undone on 2026-10-14).
  // The visual lens reviews the window check's captures, after it (visualReview).
  const lenses = wp.lenses && wp.lenses.length ? wp.lenses : wp.risk === 'low' ? ['parity'] : wp.risk === 'high' ? ['parity', 'safety', 'performance'] : ['parity', 'performance']
  return lenses.filter((l) => l !== 'visual')
}

function review(wp, lens) {
  // High-risk parity gets Opus: a fast Sonnet pass over a large port found nothing it could show (P3-04).
  const opts = lens === 'parity' && wp.risk !== 'high' ? { model: 'sonnet', effort: 'medium' } : { model: 'opus' }
  return agent(
    `${head(wp)}
## Your role: reviewer, lens ${lens}
${LENSES[lens]}
In your own worktree, run \`git checkout --detach port/${wp.id}\` and review the change (\`git diff main...port/${wp.id}\`). Don't run GUI tests, captures or the bench.
Try to show that this work package does NOT match the original. Every finding must come with evidence: a failing test (give its code and how to run it) or a concrete side-by-side of reference behavior vs port behavior with file:line on both sides. Findings without evidence are dropped. Do not commit. Report only findings of medium severity or higher, at most 10, most severe first. An empty list of findings is a fine answer when \`checked\` shows the work.`,
    { label: `review:${wp.id}:${lens}`, phase: 'Review', schema: FINDINGS, isolation: 'worktree', ...opts },
  )
}

function fix(wp, round, gateResult, findings) {
  const problems = [
    gateResult && !gateResult.pass ? `Gate failures:\n${gateResult.summary}\n${(gateResult.failures || []).join('\n---\n')}` : '',
    findings.length ? `Review findings:\n${findings.map((f, i) => `${i + 1}. [${f.severity}] ${f.title} (${f.where || ''})\n${f.evidence}`).join('\n\n')}` : '',
  ].filter(Boolean).join('\n\n')
  return agent(
    `${head(wp)}
## Your role: fixer, round ${round}
In your own worktree: \`git checkout port/${wp.id}\`. If \`git log main..port/${wp.id} --grep='Port-Stage: fixed-${round}' -1\` prints a commit (only this branch's own commits count), return status "fixed" with that sha.
Fix the problems below. For each finding, first add its failing test, then make it pass. A finding you can show is wrong (the reference behaves like the port): say so in remaining, with the evidence, and leave the code.
${problems}

Then run the gate commands until they pass:
${gateList(wp)}${windowNote(wp)}
For a window-check failure, rerun only the failing GUI test or scenario under the GUI lock to prove the fix.
${FLAKY}
Make the last commit's message end with the trailer "Port-Stage: fixed-${round}", then run \`git checkout --detach\`.`,
    { label: `fix:${wp.id}#${round}`, phase: 'Fix', schema: FIX, isolation: 'worktree', ...modelOpts(wp) },
  )
}

async function runWp(wp) {
  const report = { id: wp.id, status: 'blocked', findings: [], fixes: [], carryOver: [] }
  const built = await implement(wp)
  if (!built) return { ...report, blockers: ['implementer did not return'] }
  Object.assign(report, { headSha: built.headSha, summary: built.summary, sharedFileRequests: built.sharedFileRequests || [], deviations: built.deviations || [], blockers: built.blockers || [], carryOver: built.carryOver || [] })
  if (built.status === 'blocked') return report

  // The gate and the reviewers only read the branch, so they run side by side.
  phase('Gate')
  const [gateFirst, ...reviews] = await parallel([() => gate(wp, 0), ...lensesFor(wp).map((lens) => () => review(wp, lens))])
  let gateResult = gateFirst
  report.gate = gateResult
  report.reviewChecked = reviews.filter(Boolean).map((r) => (r.checked || []).length)
  let findings = reviews.filter(Boolean).flatMap((r) => r.findings).filter((f) => f.severity !== 'low')
  report.findings = findings
  for (let round = 1; round <= MAX_FIX_LOOPS; round++) {
    if (gateResult && gateResult.pass && findings.length === 0) break
    const fixed = await fix(wp, round, gateResult, findings)
    report.fixes.push(fixed)
    if (fixed && fixed.headSha) report.headSha = fixed.headSha
    if (fixed && fixed.carryOver) report.carryOver.push(...fixed.carryOver)
    gateResult = await gate(wp, round)
    report.gate = gateResult
    // Fixes come with the findings' tests, so a passing gate proves them; reviewers are not re-run.
    findings = gateResult && gateResult.pass ? [] : findings
  }
  const ok = gateResult && gateResult.pass && findings.length === 0
  report.status = ok ? 'ready' : 'blocked'
  if (!ok) report.blockers = [...(report.blockers || []), 'gate or findings still open after fix loops']
  return report
}

function windowCheck(wps, round) {
  const cmds = [...new Set(wps.flatMap(windowGate))]
  const dest = `${CAPTURES}/${A.batchId}-${round}`
  return agent(
    `${PRE}\n\n## Your role: window checker for batch ${A.batchId}, round ${round}
In your own worktree, make a throwaway branch from main and merge these work package branches into it, in order, with \`git merge --no-ff\`:
${wps.map((w) => `- port/${w.id}`).join('\n')}
If a merge conflicts, resolve it only if it is trivial (imports, lists, both sides kept); otherwise abort that merge, run the commands on that branch alone afterwards, and say so in the summary. Never push or keep the throwaway branch, and commit nothing to a port/ branch.
Then run each command below once, from the repo root, in order. If \`tools/capture/run.sh --help\` (or its header) shows a \`--changed\` option, run every \`tools/capture/run.sh --tier wp\` below as \`tools/capture/run.sh --changed main\` instead (the scenarios this batch changed plus the smoke set):
${cmds.map((c) => `- \`${c}\``).join('\n')}
Report pass only if every command exits 0. ${FLAKY} For each failure, find which work package it belongs to: by which branch added or changed the failing test, scenario or code, and if that isn't clear, by rerunning just the failing test or scenario on each branch alone. Rerun only the failing item, never a whole suite.
Finally copy tools/capture/out to ${dest} (\`rm -rf ${dest}; mkdir -p ${CAPTURES}; cp -R tools/capture/out ${dest}\`) and return its absolute path in captures.`,
    { label: `window-check:${A.batchId}#${round}`, phase: 'Window check', schema: WINDOW_CHECK, isolation: 'worktree', model: 'sonnet', effort: 'medium' },
  )
}

function visualReview(wps, captures) {
  return agent(
    `${PRE}\n\n## Your role: visual reviewer for batch ${A.batchId}
The window check has just captured this batch's scenarios in the original app and in the port, merged: ${captures}. Each scenario folder holds both sides' screenshots and geometry and a diff/ folder (summary.json, the geometry report, the pixel diff). Don't run the apps or the capture harness again.
The work packages and their briefs (read the briefs' scenario and layout sections):
${wps.map((w) => `- ${w.id} ${w.title}: ${A.repo}/docs/port/state/wp/${w.id}.md`).join('\n')}
For every scenario a work package added or touched, look at both screenshots side by side and at the geometry report. List material differences from the original: layout, fonts, sizes, spacing, colors, missing or extra elements. For each, name the work package it belongs to (wp), the scenario, and the evidence (element, both frames or values, the screenshot files). Differences the briefs or docs/port/DEVIATIONS.md accept, and offsets the geometry report attributes to another package's unfinished chrome, are not findings. Return in \`checked\` each scenario you looked at, with matches or differs. Report medium severity or higher only, at most 10.`,
    { label: `visual:${A.batchId}`, phase: 'Window check', schema: FINDINGS, model: 'opus' },
  )
}

phase('Build')
log(`Batch ${A.batchId}: ${A.wps.map((w) => w.id).join(', ')}`)
const spentBefore = budget.spent()
const reports = await pipeline(A.wps, (wp) => runWp(wp))
const reportOf = (id) => reports.find((r) => r && r.id === id)

const checked = reports.filter((r) => r && r.status === 'ready').map((r) => A.wps.find((w) => w.id === r.id)).filter((w) => windowGate(w).length)
let windowResult = null
let visualFindings = []
if (checked.length) {
  phase('Window check')
  for (let round = 0; round <= MAX_FIX_LOOPS; round++) {
    const inBatch = checked.filter((w) => reportOf(w.id).status === 'ready')
    if (!inBatch.length) break
    windowResult = await windowCheck(inBatch, round)
    // The visual review runs once, on the first round's captures.
    if (round === 0 && windowResult && windowResult.captures && inBatch.some(visualWanted)) {
      const visual = await visualReview(inBatch.filter(visualWanted), windowResult.captures)
      visualFindings = visual ? visual.findings.filter((f) => f.severity !== 'low') : []
      for (const w of inBatch) reportOf(w.id).findings.push(...visualFindings.filter((f) => f.wp === w.id))
    } else {
      visualFindings = []
    }
    const failures = (windowResult && windowResult.failures) || []
    const failing = inBatch.filter((w) => failures.some((f) => f.wp === w.id) || visualFindings.some((f) => f.wp === w.id))
    if (!windowResult || !failing.length || round === MAX_FIX_LOOPS) break
    await parallel(failing.map((w) => async () => {
      const mine = failures.filter((f) => f.wp === w.id)
      const gateLike = mine.length ? { pass: false, summary: `Window check (on the merged batch) failed for ${w.id}:`, failures: mine.map((f) => f.detail) } : null
      const fixed = await fix(w, `window-${round + 1}`, gateLike, visualFindings.filter((f) => f.wp === w.id))
      const report = reportOf(w.id)
      report.fixes.push(fixed)
      if (fixed && fixed.headSha) report.headSha = fixed.headSha
      if (fixed && fixed.carryOver) report.carryOver.push(...fixed.carryOver)
      const g = await gate(w, `window-${round + 1}`)
      if (!g || !g.pass) { report.status = 'blocked'; report.gate = g; report.blockers = [...(report.blockers || []), 'windowless gate failed after the window-check fix'] }
    }))
  }
  if (windowResult && !windowResult.pass) {
    const failed = new Set((windowResult.failures || []).map((f) => f.wp))
    for (const r of reports) {
      if (r && r.status === 'ready' && checked.some((w) => w.id === r.id) && (failed.has(r.id) || !(windowResult.failures || []).length)) {
        r.status = 'blocked'
        r.blockers = [...(r.blockers || []), 'window checks still failing after fix loops']
      }
    }
  }
  for (const r of reports) if (r && checked.some((w) => w.id === r.id)) r.windowCheck = windowResult
}
const ready = reports.filter((r) => r && r.status === 'ready')

let integration = null
if (A.integrate && ready.length) {
  phase('Integrate')
  integration = await agent(
    `${PRE}\n\n## Your role: integrator for batch ${A.batchId}
You work in the orchestrator's checkout (${A.repo}), which has main checked out. Do not switch branches here and do not touch docs/port/state/.
Another batch's integrator may use this checkout at the same time, so take the merge lock first and hold it until you are done:
\`until mkdir ~/Library/Caches/filetrail-port/integrate.lock 2>/dev/null; do sleep 20; done; echo ${A.batchId} > ~/Library/Caches/filetrail-port/integrate.lock/owner\`
Release it as your very last step, also when you stop early or something fails: \`rm -rf ~/Library/Caches/filetrail-port/integrate.lock\`.
Merge these branches one at a time, in this order, with \`git merge --no-ff port/<id> -m "Merge <id>: <title>"\`:
${ready.map((r) => `- port/${r.id}${r.sharedFileRequests && r.sharedFileRequests.length ? ` — shared-file requests to apply after merging it: ${r.sharedFileRequests.join('; ')}` : ''}`).join('\n')}
After each merge, run \`scripts/ci.sh\` (if it exists; never the window checks, which already ran) and fix any break the merge caused, committing the fix on main. ${FLAKY} If a merge conflicts in a way you cannot resolve without changing a work package's design, abort that merge (\`git merge --abort\`) and list it in notMerged with the reason.
When all merges are done, if tools/parity-matrix/sync.ts exists, run \`bun tools/parity-matrix/sync.ts\` (it updates docs/port/parity/ from the merged tests' citations and results) and commit the result as "Sync parity matrix after ${A.batchId}". If a merge conflicts only inside docs/port/parity/, take main's side and let the sync rebuild it.
A shared-file request you don't apply goes in carryOver, addressed to the package that should do it.
Return the merged ids, the final head sha and whether the last CI run passed.`,
    { label: `integrate:${A.batchId}`, phase: 'Integrate', schema: INTEGRATION, model: 'sonnet', effort: 'medium' },
  )
}

let critic = null
if (A.critic) {
  phase('Critic')
  critic = await agent(`${PRE}\n\n## Your role: phase critic\n${A.critic}`, {
    label: `critic:${A.batchId}`, phase: 'Critic', schema: CRITIC, model: 'sonnet', effort: 'medium',
  })
}

return { batchId: A.batchId, reports, windowCheck: windowResult, integration, critic, spentOutputTokens: budget.spent() - spentBefore }
