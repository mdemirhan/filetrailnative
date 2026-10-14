export const meta = {
  name: 'port-batch',
  description: 'Build, gate, review, fix and merge one batch of File Trail port work packages',
  whenToUse: 'Run by the port orchestrator (docs/port/ORCHESTRATOR.md) with args from state.py batch-args',
  phases: [
    { title: 'Build', detail: 'implementer per work package, in its own worktree' },
    { title: 'Gate', detail: 'run the work package gate commands' },
    { title: 'Review', detail: 'lenses by risk tier; findings need a failing test or a diff' },
    { title: 'Fix', detail: 'at most 2 fix loops' },
    { title: 'Batch check', detail: 'window checks once, on all ready work packages merged together' },
    { title: 'Integrate', detail: 'merge ready work packages into main, one at a time' },
    { title: 'Critic', detail: 'optional end-of-phase check' },
  ],
}

// args: { batchId, repo, integrate, critic, wps: [{ id, title, risk, model, lenses, gate }] }
// Agents read their instructions from the committed files docs/port/state/preamble.md and
// docs/port/state/wp/<id>.md, so the workflow input stays small.
const A = args
// Agent worktrees start from main, the integration branch. Instructions are read by absolute path
// from the orchestrator's checkout, and every agent checks out the branch it needs first.
const PRE = `First read ${A.repo}/docs/port/state/preamble.md and follow it. Your worktree starts on main: never commit to main; check out the branch your role names below.`
const MAX_FIX_LOOPS = 2

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
  },
  required: ['status', 'summary'],
}
const GATE = {
  type: 'object',
  properties: {
    pass: { type: 'boolean' },
    summary: { type: 'string', description: 'One line per gate command: pass/fail and a key number' },
    failures: { type: 'array', items: { type: 'string' }, description: 'At most 40 lines of the relevant output each' },
  },
  required: ['pass', 'summary'],
}
const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          title: { type: 'string' },
          evidence: { type: 'string', description: 'A failing test (code + how to run) or a concrete diff/reference-vs-port comparison' },
          where: { type: 'string' },
        },
        required: ['severity', 'title', 'evidence'],
      },
    },
  },
  required: ['findings'],
}
const FIX = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['fixed', 'partial', 'blocked'] },
    headSha: { type: 'string' },
    summary: { type: 'string' },
    remaining: { type: 'array', items: { type: 'string' } },
  },
  required: ['status', 'summary'],
}
const INTEGRATION = {
  type: 'object',
  properties: {
    merged: { type: 'array', items: { type: 'string' } },
    notMerged: { type: 'array', items: { type: 'object', properties: { wp: { type: 'string' }, reason: { type: 'string' } }, required: ['wp', 'reason'] } },
    ciPass: { type: 'boolean' },
    headSha: { type: 'string' },
    summary: { type: 'string' },
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

const LENSES = {
  parity: 'PARITY: read the cited reference TypeScript and inventory sections and list behavior the Swift code lacks or changes.',
  safety: 'SAFETY: look for data loss, destructive steps the user was not shown, and races above the bar in the reference repo docs/FILE_OPERATION_RISKS.md. Accepted risks listed there are not findings.',
  performance: 'PERFORMANCE: the bar is the original app\'s ballpark, not PLAN.md section 4\'s targets (user, 2026-10-14). Report only what a user would notice: main-thread disk access or a visible hang, or something clearly slower than the original (about 1.5x or worse, measured). Micro-optimizations are not findings.',
  visual: 'VISUAL: build the app, capture the scenarios this work package touches with the capture harness, compare against the reference captures, and list material differences.',
}

function modelOpts(wp) {
  if (wp.model === 'opus') return { model: 'opus' }
  if (wp.model === 'haiku') return { model: 'haiku', effort: 'low' }
  return { model: 'sonnet', effort: 'medium' }
}

const head = (wp) => `${PRE}\n\n# Work package ${wp.id}: ${wp.title}\nRisk: ${wp.risk}. Branch: port/${wp.id}.\nYour brief is ${A.repo}/docs/port/state/wp/${wp.id}.md: read it in full before starting.\n`
// Commands that put windows on screen (GUI tests, captures, bench) all take the GUI lock. They run once per batch,
// in the batch check on all ready work packages merged together, not in each work package's build, gate and fix
// (user, 2026-10-14: the same UI runs were repeating). Per work package only the windowless commands gate.
const isWindowCmd = (c) => c.includes('gui.lock')
const wpGate = (wp) => wp.gate.filter((c) => !isWindowCmd(c))
const windowGate = (wp) => wp.gate.filter(isWindowCmd)
const gateList = (wp) => (wpGate(wp).length ? wpGate(wp).map((c) => `- \`${c}\``).join('\n') : '- `scripts/ci.sh`')
const windowNote = (wp) => (windowGate(wp).length
  ? `\nThe window checks (${windowGate(wp).map((c) => `\`${c}\``).join(', ')}) are not yours to run in full: the batch check runs them once for the whole batch. While you work, run only your own GUI suites and your own scenarios, under the GUI lock, as the preamble says.`
  : '')

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
5. Make the final commit with a message whose last line is the trailer "Port-Stage: implemented". Then run \`git checkout --detach\` so the branch is free for the next agent.
Return status "blocked" only if the brief cannot be done; list why in blockers, and still commit what you have.`,
    { label: `build:${wp.id}`, phase: 'Build', schema: IMPL, isolation: 'worktree', ...modelOpts(wp) },
  )
}

function gate(wp, round) {
  return agent(
    `${PRE}\n\n## Your role: gate runner for work package ${wp.id}
In your own worktree, run \`git checkout --detach port/${wp.id}\`, then run each gate command below from the repo root, in order:
${gateList(wp)}
Report pass only if every command exits 0. Do not change or commit anything. For each failure, quote at most 40 relevant lines.`,
    { label: `gate:${wp.id}#${round}`, phase: 'Gate', schema: GATE, isolation: 'worktree', model: 'haiku', effort: 'low' },
  )
}

function lensesFor(wp) {
  // Every work package gets at least a parity review (the low-risk "no reviewer" cut was undone on 2026-10-14).
  if (wp.lenses && wp.lenses.length) return wp.lenses
  if (wp.risk === 'low') return ['parity']
  return wp.risk === 'high' ? ['parity', 'safety', 'performance'] : ['parity', 'performance']
}

function review(wp, lens) {
  const opts = lens === 'parity' ? { model: 'sonnet', effort: 'medium' } : { model: 'opus' }
  return agent(
    `${head(wp)}
## Your role: reviewer, lens ${lens}
${LENSES[lens]}
In your own worktree, run \`git checkout --detach port/${wp.id}\` and review the change (\`git diff main...port/${wp.id}\`).
Try to show that this work package does NOT match the original. Every finding must come with evidence: a failing test (give its code and how to run it) or a concrete side-by-side of reference behavior vs port behavior with file:line on both sides. Findings without evidence are dropped. Do not commit. Report only findings of medium severity or higher, at most 10, most severe first. An empty list is a fine answer.`,
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
Make the last commit's message end with the trailer "Port-Stage: fixed-${round}", then run \`git checkout --detach\`.`,
    { label: `fix:${wp.id}#${round}`, phase: 'Fix', schema: FIX, isolation: 'worktree', ...modelOpts(wp) },
  )
}

async function runWp(wp) {
  const report = { id: wp.id, status: 'blocked', findings: [], fixes: [] }
  const built = await implement(wp)
  if (!built) return { ...report, blockers: ['implementer did not return'] }
  Object.assign(report, { headSha: built.headSha, summary: built.summary, sharedFileRequests: built.sharedFileRequests || [], deviations: built.deviations || [], blockers: built.blockers || [] })
  if (built.status === 'blocked') return report

  let gateResult = await gate(wp, 0)
  report.gate = gateResult
  let findings = []
  if (gateResult && gateResult.pass) {
    const reviews = await parallel(lensesFor(wp).map((lens) => () => review(wp, lens)))
    findings = reviews.filter(Boolean).flatMap((r) => r.findings).filter((f) => f.severity !== 'low')
    report.findings = findings
  }
  for (let round = 1; round <= MAX_FIX_LOOPS; round++) {
    if (gateResult && gateResult.pass && findings.length === 0) break
    const fixed = await fix(wp, round, gateResult, findings)
    report.fixes.push(fixed)
    if (fixed && fixed.headSha) report.headSha = fixed.headSha
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

phase('Build')
log(`Batch ${A.batchId}: ${A.wps.map((w) => w.id).join(', ')}`)
const spentBefore = budget.spent()
const reports = await pipeline(A.wps, (wp) => runWp(wp))

const BATCH_CHECK = {
  type: 'object',
  properties: {
    pass: { type: 'boolean' },
    summary: { type: 'string', description: 'One line per command: pass/fail and a key number' },
    failures: {
      type: 'array',
      items: { type: 'object', properties: { wp: { type: 'string' }, detail: { type: 'string' } }, required: ['wp', 'detail'] },
      description: 'Each failure with the work package it belongs to and at most 40 relevant lines',
    },
  },
  required: ['pass', 'summary'],
}

function batchCheck(wps, round) {
  const cmds = [...new Set(wps.flatMap(windowGate))]
  return agent(
    `${PRE}\n\n## Your role: batch checker for batch ${A.batchId}, round ${round}
In your own worktree, make a throwaway branch from main and merge these work package branches into it, in order, with \`git merge --no-ff\`:
${wps.map((w) => `- port/${w.id}`).join('\n')}
If a merge conflicts, resolve it only if it is trivial (imports, lists, both sides kept); otherwise abort that merge, run the commands on that branch alone afterwards, and say so in the summary. Never push or keep the throwaway branch, and commit nothing to a port/ branch.
Then run each command below once, from the repo root, in order:
${cmds.map((c) => `- \`${c}\``).join('\n')}
Report pass only if every command exits 0 (a bench run is report-only: pass it and quote its numbers). For each failure, find which work package it belongs to: by which branch added or changed the failing test, scenario or code, and if that isn't clear, by rerunning just the failing test or scenario on each branch alone. Rerun only the failing item, never a whole suite.`,
    { label: `batch-check:${A.batchId}#${round}`, phase: 'Batch check', schema: BATCH_CHECK, isolation: 'worktree', model: 'sonnet', effort: 'medium' },
  )
}

let ready = reports.filter((r) => r && r.status === 'ready')
const checked = ready.map((r) => A.wps.find((w) => w.id === r.id)).filter((w) => windowGate(w).length)
let batchCheckResult = null
if (checked.length) {
  phase('Batch check')
  for (let round = 0; round <= MAX_FIX_LOOPS; round++) {
    const inBatch = checked.filter((w) => reports.find((r) => r && r.id === w.id).status === 'ready')
    if (!inBatch.length) break
    batchCheckResult = await batchCheck(inBatch, round)
    if (!batchCheckResult || batchCheckResult.pass || round === MAX_FIX_LOOPS) break
    const failing = inBatch.filter((w) => (batchCheckResult.failures || []).some((f) => f.wp === w.id))
    if (!failing.length) break
    await parallel(failing.map((w) => async () => {
      const failures = batchCheckResult.failures.filter((f) => f.wp === w.id)
      const fixed = await fix(w, `batch-${round + 1}`, { pass: false, summary: `Batch check (window checks on the merged batch) failed for ${w.id}:`, failures: failures.map((f) => f.detail) }, [])
      const report = reports.find((r) => r && r.id === w.id)
      report.fixes.push(fixed)
      if (fixed && fixed.headSha) report.headSha = fixed.headSha
      const g = await gate(w, `batch-${round + 1}`)
      if (!g || !g.pass) { report.status = 'blocked'; report.gate = g; report.blockers = [...(report.blockers || []), 'windowless gate failed after the batch-check fix'] }
    }))
  }
  if (batchCheckResult && !batchCheckResult.pass) {
    const failed = new Set((batchCheckResult.failures || []).map((f) => f.wp))
    for (const r of reports) {
      if (r && r.status === 'ready' && (failed.has(r.id) || !(batchCheckResult.failures || []).length)) {
        r.status = 'blocked'
        r.blockers = [...(r.blockers || []), 'batch window checks still failing after fix loops']
      }
    }
  }
  for (const r of reports) if (r && checked.some((w) => w.id === r.id)) r.batchCheck = batchCheckResult
  ready = reports.filter((r) => r && r.status === 'ready')
}

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
After each merge, run \`scripts/ci.sh\` (if it exists; never the window checks, which the batch check already ran) and fix any break the merge caused, committing the fix on main. If a merge conflicts in a way you cannot resolve without changing a work package's design, abort that merge (\`git merge --abort\`) and list it in notMerged with the reason.
When all merges are done, if tools/parity-matrix/sync.ts exists, run \`bun tools/parity-matrix/sync.ts\` (it updates docs/port/parity/ from the merged tests' citations and results) and commit the result as "Sync parity matrix after ${A.batchId}". If a merge conflicts only inside docs/port/parity/, take main's side and let the sync rebuild it.
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

return { batchId: A.batchId, reports, batchCheck: batchCheckResult, integration, critic, spentOutputTokens: budget.spent() - spentBefore }
