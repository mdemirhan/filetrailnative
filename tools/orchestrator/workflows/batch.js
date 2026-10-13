export const meta = {
  name: 'port-batch',
  description: 'Build, gate, review, fix and merge one batch of File Trail port work packages',
  whenToUse: 'Run by the port orchestrator (docs/port/ORCHESTRATOR.md) with args from state.py batch-args',
  phases: [
    { title: 'Build', detail: 'implementer per work package, in its own worktree' },
    { title: 'Gate', detail: 'run the work package gate commands' },
    { title: 'Review', detail: 'lenses by risk tier; findings need a failing test or a diff' },
    { title: 'Fix', detail: 'at most 2 fix loops' },
    { title: 'Integrate', detail: 'merge ready work packages into port/integration, one at a time' },
    { title: 'Critic', detail: 'optional end-of-phase check' },
  ],
}

// args: { batchId, repo, preamble, integrate, critic, wps: [{ id, title, risk, model, lenses, gate, brief }] }
const A = args
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
  performance: 'PERFORMANCE: look for main-thread disk access, needless allocations or copies, and anything that breaks the budgets in docs/port/PLAN.md section 4.',
  visual: 'VISUAL: build the app, capture the scenarios this work package touches with the capture harness, compare against the reference captures, and list material differences.',
}

function modelOpts(wp) {
  if (wp.model === 'opus') return { model: 'opus' }
  if (wp.model === 'haiku') return { model: 'haiku', effort: 'low' }
  return { model: 'sonnet', effort: 'medium' }
}

const head = (wp) => `${A.preamble}\n\n# Work package ${wp.id}: ${wp.title}\nRisk: ${wp.risk}. Branch: port/${wp.id}.\n\n${wp.brief}\n`
const gateList = (wp) => (wp.gate.length ? wp.gate.map((c) => `- \`${c}\``).join('\n') : '- `scripts/ci.sh --scope ' + wp.id + '` (if scripts/ci.sh exists)')

function implement(wp) {
  return agent(
    `${head(wp)}
## Your role: implementer
You are in your own fresh git worktree based on port/integration.
1. If \`git log port/${wp.id} --grep='Port-Stage: implemented' -1\` prints a commit, the work is already done: return status "already_done" with that sha and a summary taken from the git log. Change nothing.
2. If branch port/${wp.id} exists, an earlier run was interrupted: \`git checkout port/${wp.id}\` and continue from its commits. Otherwise \`git checkout -b port/${wp.id}\`.
3. Do the work in the brief. Commit as you go with messages "wip(${wp.id}): ...".
4. Run the gate commands below until they all pass:
${gateList(wp)}
5. Make the final commit with a message whose last line is the trailer "Port-Stage: implemented". Then run \`git checkout --detach\` so the branch is free for the next agent.
Return status "blocked" only if the brief cannot be done; list why in blockers, and still commit what you have.`,
    { label: `build:${wp.id}`, phase: 'Build', schema: IMPL, isolation: 'worktree', ...modelOpts(wp) },
  )
}

function gate(wp, round) {
  return agent(
    `${A.preamble}\n\n## Your role: gate runner for work package ${wp.id}
In your own worktree, run \`git checkout --detach port/${wp.id}\`, then run each gate command below from the repo root, in order:
${gateList(wp)}
Report pass only if every command exits 0. Do not change or commit anything. For each failure, quote at most 40 relevant lines.`,
    { label: `gate:${wp.id}#${round}`, phase: 'Gate', schema: GATE, isolation: 'worktree', model: 'haiku', effort: 'low' },
  )
}

function lensesFor(wp) {
  if (wp.risk === 'low') return []
  if (wp.lenses && wp.lenses.length) return wp.lenses
  return wp.risk === 'high' ? ['parity', 'safety', 'performance'] : ['parity', 'performance']
}

function review(wp, lens) {
  const opts = lens === 'parity' ? { model: 'sonnet', effort: 'medium' } : { model: 'opus' }
  return agent(
    `${head(wp)}
## Your role: reviewer, lens ${lens}
${LENSES[lens]}
In your own worktree, run \`git checkout --detach port/${wp.id}\` and review the change (\`git diff port/integration...port/${wp.id}\`).
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
In your own worktree: \`git checkout port/${wp.id}\`. If \`git log port/${wp.id} --grep='Port-Stage: fixed-${round}' -1\` prints a commit, return status "fixed" with that sha.
Fix the problems below. For each finding, first add its failing test, then make it pass. A finding you can show is wrong (the reference behaves like the port): say so in remaining, with the evidence, and leave the code.
${problems}

Then run the gate commands until they pass:
${gateList(wp)}
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

let integration = null
const ready = reports.filter((r) => r && r.status === 'ready')
if (A.integrate && ready.length) {
  phase('Integrate')
  integration = await agent(
    `${A.preamble}\n\n## Your role: integrator for batch ${A.batchId}
You work in the orchestrator's checkout (${A.repo}), which has port/integration checked out. Do not switch branches here and do not touch docs/port/state/.
Merge these branches one at a time, in this order, with \`git merge --no-ff port/<id> -m "Merge <id>: <title>"\`:
${ready.map((r) => `- port/${r.id}${r.sharedFileRequests && r.sharedFileRequests.length ? ` — shared-file requests to apply after merging it: ${r.sharedFileRequests.join('; ')}` : ''}`).join('\n')}
After each merge, run \`scripts/ci.sh\` (if it exists) and fix any break the merge caused, committing the fix on port/integration. If a merge conflicts in a way you cannot resolve without changing a work package's design, abort that merge (\`git merge --abort\`) and list it in notMerged with the reason.
Return the merged ids, the final head sha and whether the last CI run passed.`,
    { label: `integrate:${A.batchId}`, phase: 'Integrate', schema: INTEGRATION, model: 'sonnet', effort: 'medium' },
  )
}

let critic = null
if (A.critic) {
  phase('Critic')
  critic = await agent(`${A.preamble}\n\n## Your role: phase critic\n${A.critic}`, {
    label: `critic:${A.batchId}`, phase: 'Critic', schema: CRITIC, model: 'sonnet', effort: 'medium',
  })
}

return { batchId: A.batchId, reports, integration, critic, spentOutputTokens: budget.spent() - spentBefore }
