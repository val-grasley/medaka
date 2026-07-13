# ORCHESTRATING.md — a guide to being the orchestrator

You design and delegate work to subagents, verify their output, and keep the
project's docs/state coherent. You usually do **not** implement directly. Your
durable value is: framing precise tasks, judging results, and holding the thread
across many agents. This doc is a **living guide** — append learnings as the
pattern recurs.

Companion docs: `AGENTS.md` (agent-facing orientation/router), the per-task
**skills** in `.claude/skills/`. The orchestrator's standing operating rules are
in the session prompt; this doc is the reusable distillation.

---

## The core loop

```
scope-read (bounded) → frame a precise prompt → get approval → spawn (bg, isolated worktree)
  → VERIFY empirically → merge to local main → reconcile docs/tasks/memory → next
```

- **Bounded scope-read.** Read just enough to write a precise prompt + STOP
  guardrail — not to fully understand every code arm. Use targeted `grep`/`sed`
  of the specific functions, not whole-file reads. For broader/uncertain scoping
  (where does X live, a full census, a taxonomy), **delegate to an Explore agent**
  and keep only its conclusion — don't fan the reads through your own context.
- **Approval before spawn.** Present each agent's prompt + chosen model; get an
  explicit OK. Surface genuine design decisions as questions (you're a design
  collaborator, not just a dispatcher). Once pre-approved for a class of work,
  chain without re-asking — but still pause when an agent trips a guardrail.

---

## Agents do NOT run the full suite (2026-07-13)

**The old default — every agent runs `make medaka` + `FORCE=1 build_oracles.sh` +
the full gate suite — is what serialized this box.** `build_oracles.sh` compiles
**all 54** probe binaries (54 × `medaka build` + clang) even when the agent's gates
read **four**. Two agents doing that at once already contend; that is why the
"one heavy op at a time GLOBALLY" rule existed. It was a symptom, not a law.

**The new loop:**

```
agent:  make preflight            # targeted: build + run ONLY what the diff touches
        commit on its own branch, REPORT THE SHA
orchestrator:
        verify → push the branch → open a PR → CI runs the FULL suite (free, hosted)
        merge ONLY on green CI
```

- **`make preflight`** (`test/preflight.sh`) derives the gate set from
  `git diff --name-only`, derives the ORACLE set from those gates, and builds only
  those. An agent touching `parser.mdk` builds **9 oracles and runs 11 gates**, not
  54 and 82. It deliberately skips the two expensive things — `diff_compiler_engines`
  (346 fixtures × clang) and the fixpoint — **except** that a `compiler/backend/*`
  change forces the fixpoint, because there it is the decisive gate and finding out
  in CI is too late.
- **`sh test/build_oracles.sh --for '<gate-pattern>'…`** builds only the oracles those
  gates read. A gate names its oracle as `test/bin/<name>`, so the set is *derived*
  from the gate scripts — there is no hand-maintained map to drift. CI shards and
  `preflight.sh` share this one derivation.
- **`make test`** = the IN-LANGUAGE suite (doctests, props, `test "…"` decls). Needs
  no oracles. **`make gates`** = the full 82-gate differential suite. These were the
  same target until 2026-07-13, and the misnomer bit CI immediately.

### ⚠️ THE PREFLIGHT IS A FILTER, NOT AN AUTHORITY

A green preflight means *the gates most likely to notice your change did not break*.
Nothing more. **CI, running the full suite on the PR, is the authority. Do not merge
on a green preflight.**

This matters more than it sounds. A targeted local run re-introduces the *exact*
hazard this project's testing overhaul exists to kill: **a suite reporting green
while testing less than it appears to.** That is not hypothetical —
`diff_compiler_lint_multi` sat "skipped" for months (dash could not parse it, exit 2
was counted as SKIP) and was *also failing* the whole time; and a fresh clone used to
run **zero tests and print "0 failed."** So `preflight.sh` **ends by printing what it
did not run**, and it must stay loud. A miss in the change→gate map then costs a slow
round-trip, not a shipped bug.

### The orchestrator OWNS red CI — watch it, don't wait to be told

**Arm a persistent background `Monitor` on CI as soon as you push anything.** A CI
failure nobody is watching is just a slower version of no CI, and the whole point of
moving the suite off the box was to make the *authoritative* signal cheap — which is
worthless if the signal isn't read.

```
Monitor (persistent, 60s poll):
  gh run list --limit 15 --json databaseId,status,conclusion,headBranch
  -> emit a line for EVERY newly-terminal run, and on failure list the failed jobs
```

⚠️ **Emit on every terminal state, not just failures.** A monitor that greps only for
red is *silent* through a cancelled run, a timeout, or a crashloop — and silence is
indistinguishable from "still running." Seed the seen-set with already-completed runs
at arm time so you only get new events.

**When CI comes back red, the orchestrator acts — it does not just report:**

1. **Diagnose first, from the log** (`gh run view <id> --log-failed`). Establish whether
   it is (a) an infra/workflow bug, (b) a real regression, or (c) an already-known red.
2. **Fix it yourself if it is small and mechanical** — a bad glob, a YAML quoting error,
   a stale golden, a misnamed make target, a missing `chmod +x`. Do not spawn an agent
   to change three characters. (Real examples from this arc: a shard pattern using brace
   expansion that dash cannot expand; `pattern: 'a' 'b'` being invalid YAML; `make test`
   secretly running the 82-gate suite.)
3. **Re-spawn the responsible agent** when the failure is inside work it just did, with
   the CI failure pasted in and a STOP guardrail. Do not "fix" an agent's logic for it —
   you'll lose the context it has.
4. **Record it as known-red ONLY with a ledger entry that detects an accidental fix.**
   Never a bare skip. A skip-list cannot notice when the bug is fixed, so it rots — which
   is exactly how `test/ported/` died and how `diff_compiler_lint_multi` sat "skipped"
   for months while also failing.

**Never merge on red, and never merge on a green *preflight*.** The full suite on the
PR is the only authority.

### Branching off an UNVERIFIED base — a judgment call, not a rule

CI is now the authority, but it is also **minutes**, and agents are cheap. Waiting for
green before spawning the next agent serializes the thing you just spent the effort to
parallelize. So: **you MAY branch new work off a base whose CI is still running.** Do it
deliberately, priced against the chance CI comes back red.

**The question is not "is the base green?" It is "if this base turns red, what does it
cost me?"**

Cheap to be wrong (branch freely):
- The new agent's work is **disjoint** from the risky change (different files, different
  subsystem). A red base then gets fixed *underneath* it and the agent's branch rebases
  cleanly, or merges as-is.
- The base's uncertainty is in **docs, CI config, or a gate script**, not the compiler.
- The new work is **additive new files** (a new module, a new gate) rather than an edit
  to something the base touched.

Expensive to be wrong (WAIT):
- The new work **builds directly on** the uncertain change (e.g. the base rewrote the
  emitter and the new agent is emitting IR through it). A red base means the agent's
  premise is void and its work is *discarded*, not rebased.
- The base changed **goldens or the seed**. A red there means recapture, and everything
  downstream of it is now founded on wrong expectations.
- You would have to **re-derive a diagnosis**, not just re-apply a diff.

**Signals that the base is low-risk** (so branch away): the change was doc/config only;
`make preflight` was green locally; the fixpoint + `typecheck_compiler_source` already
passed on it; the diff is additive; CI has already gone green on an *earlier* commit of
the same branch and this push was small.

**Signals that it is high-risk** (so wait, or branch off the last KNOWN-GREEN commit
instead): the emitter/`Value`/dispatch was touched; goldens moved; a shard is already
red; the change is one an agent reported without you verifying it.

**The escape hatch nobody remembers:** you can branch off the **last known-green SHA**
rather than the branch tip. You get parallelism *and* a verified base; the cost is one
merge later. When the tip is risky but you want to keep moving, this is usually the
right answer and it is strictly better than either waiting or gambling.

⚠️ **If you do branch off an unverified tip, say so in the agent's prompt.** Its STEP-0
`BASE_OK` assert will happily pass against a base that CI is about to reject — the assert
proves *ancestry*, not *correctness*. An agent that knows its base is provisional will
STOP and report when something upstream looks wrong, instead of "fixing" your bug for you
and tangling the two changes together.

### CI (2026-07-13)

`.github/workflows/ci.yml`, GitHub-**hosted** runners (free + unlimited on a public
repo; 20 concurrent jobs). **No self-hosted runner** — a fork PR on a public repo with
a self-hosted runner is arbitrary code execution on the host. Do not reintroduce one.

Sharded: 6 gate shards + `inlang`, each cold-bootstrapping from the seed and building
only its own oracles. Every one of the 82 `diff_compiler_*` gates is in **exactly one**
shard (verified: 0 missing, 0 duplicated) — a gate falling between shards would
silently never run. Each shard ends with a **review gate** (`git diff --exit-code`) on
the tree its gates just ran over; it cannot be a separate job, because a fresh checkout
in a fresh VM would never see the drift.

---

## The gap docs lie — reproduce before you trust them (the #1 lesson)

The project's own gap/status docs (gap censuses, audit docs, "known gaps", roadmap
status) are **systematically stale** — they drift faster than anyone updates them.
This session a gap doc mispredicted on **every** contact: items marked OPEN were
already closed (sometimes incidentally, by an unrelated fix); items marked CLOSED were
still broken; and the *documented root cause was wrong ~every time* a route-fragile fix
was attempted. Two consequences:

- **Before you scope or spawn a fix at a "known gap," reproduce it on current main.**
  A throwaway repro (`run` = oracle, `build` + run = native, compare) takes a minute and
  repeatedly saved an Opus agent from being aimed at an already-closed or symptom-shifted
  gap. (Near-miss: a coupled pair was about to get a fix agent — both turned out already
  closed by a mangling change three commits earlier.)
- **Expect symptoms to SHIFT as upstream layers close.** A documented "panic" became a
  "garbage output" became a "SIGSEGV one layer deeper" across successive fixes. Re-scope
  on what the binary does *now*, not what the doc says it did.
- **Tell agents to DIAGNOSE-FIRST and disprove the hypothesis** — bake "the filed root
  cause is a starting point, almost certainly stale; trace it on current main; STOP and
  report if the probe disproves it" into every route-fragile prompt. The agents that did
  this found the real fix; the ones handed a confident-but-wrong root cause would have
  shipped a wrong fix. A clean STOP-with-a-correct-diagnosis is a *success*, not a failure.
- **A landing often closes adjacent gaps.** After a merge, re-verify the broader set
  before spawning the next agent — universal mangling alone closed three separate parked
  gaps + mooted a fourth.
- **"Fixed" can be TRUE and MISLEADING — a one-backend fix is a half fix.** This project has
  two backends (LLVM + WasmGC). A compiler fix for a partially-applied-constructor miscompile
  landed in the LLVM emitter and **never reached the WasmGC one**. My bug-verifier said FIXED
  (correctly!), so I reverted the library's workaround, re-verified under native `build` — all
  green — and was one command from merging a library that **silently no longer compiled to
  wasm**. Only the wasm tandem gate caught it. **When a fix lands, re-verify it on every
  target/config the code actually ships to, not just the one the repro used.**
- **A spot-check is not a diff — and an agent disproving YOU is a success.** I "verified" that
  overflow-page reads worked by sampling a few indices of a patterned payload. They matched. The
  read path was in fact **silently corrupting data** — my pattern used 1000-char blocks, so the
  4-byte payload shift landed inside the same block and every sample still matched. An agent's
  byte-level `cmp` caught it (diverged at byte 1817) and overturned a "verified fact" I had
  already told the user. **For data fidelity, compare bytes, not samples.** And bake
  "disprove my premises" into prompts — it fired twice this session, both times against me.

Run this same discipline as a **verified audit before any milestone**: fan out read-only
agents by domain that REPRODUCE each claimed item (don't recite the doc) and report what
they observe. It catches both directions — already-fixed-but-marked-open *and*
marked-closed-but-actually-broken (this is how the pre-flip soundness gaps surfaced).

---

## The agent-prompt skeleton

Every delegated task prompt should contain, in order:

1. **One-line project framing** + what the task is.
2. **STEP 0 — sync + VERIFY BASE:** `git merge main --no-edit` as the agent's first
   action (orchestrator work is ahead of origin on LOCAL main), THEN a base assert:
   `git merge-base --is-ancestor <expected-tip-SHA> HEAD && echo BASE_OK || echo BASE_STALE`
   — must print `BASE_OK`, else STOP+report. (This session an agent silently built Phase 5
   on a base missing two prior phases because local `main` was behind the real tip and its
   merge pulled the stale `main`; a redo was needed. The base-check makes this impossible.)
   NEVER fetch/origin/push.
3. **Environment rules:** how to build (e.g. worktree `--root .`), the no-`eval`
   /PATH quirks, no-`dune test`, the `perl -e 'alarm N; exec @ARGV'` timeout shim.
4. **Context (verified facts):** the root cause + file:line pointers you already
   confirmed, and the existing template/precedent to mirror. This is where your
   bounded scope-read pays off — hand the agent the map, not a treasure hunt.
5. **The task**, with latitude on implementation where the approach is uncertain.
6. **Gates:** the exact commands + expected numbers that prove correctness
   (differential suites, fixpoint, a minimal repro). Be explicit — "byte-identical"
   with counts. **For any gate that reads `test/bin/*` oracle binaries (`diff_compiler_test`,
   `diff_compiler_eval_*`, …), prefix it with `FORCE=1 bash test/build_oracles.sh`** — that
   builder *mtime-skips* rebuilds, so after a `typecheck.mdk`/`eval.mdk` change the gate
   otherwise silently runs a STALE oracle (see Failure modes). Tell the agent to rebuild
   `./medaka` (`make medaka`) AND force-rebuild oracles after every source change before gating.
7. **STOP guardrail:** "if the probe disproves the hypothesis / the fix balloons /
   a design decision appears, STOP and report with options — do NOT force the
   prescribed fix." Scope hypotheses are often wrong; make stopping safe and cheap.
8. **Output discipline:** commit on the agent's own branch, REPORT the SHA, **do
   NOT merge to main** (you verify + merge), don't re-mint expensive artifacts.
9. **Report-back contract:** "your final message is the ONLY thing I see — be
   self-contained, WAIT for gates to finish and report real numbers, do not leave
   background tasks running and end."

---

## Every agent prompt MUST demand a FRICTION REPORT

Bake this into the report-back contract of **every** agent you spawn:

> **Surface everything that fought you.** In your final report, include a section listing
> any bug, gap, missing feature, pain point, workaround you had to invent, unclear or
> misleading error message, stale/wrong documentation, or surprising behavior you hit —
> **even if you worked around it and even if it is unrelated to your task.** Do not
> silently absorb friction. If you had to do something ugly to make progress, say what
> and why. If an error message sent you down the wrong path, quote it. A clean report
> that hides three workarounds is worse than a messy one that names them.
>
> **Explicitly include MISSING STDLIB FUNCTIONS.** Did you hand-roll a helper because
> `stdlib/` didn't have it? Did you reach for something obvious by name and find it
> absent? Did you write the same three-line utility a second time? **Name it.** A
> function you had to write yourself is a stdlib gap discovered by USE — which is worth
> far more than one discovered by planning, because it comes with a real call site
> attached. Say what you wanted, what you wrote instead, and where.

**Why this is not optional.** Agents are extremely good at *routing around* problems and
then never mentioning them. Everything they route around is a bug the user will hit
later, with less context and less patience. This session alone, agents silently worked
around: `medaka run` being unable to read `args`; `import … as` not parsing despite
SYNTAX.md advertising it; `emitProgram` name-colliding across two backends with no
aliasing available; `/bin/sh` being dash so a gate could not even be parsed. **Every one
of those was a real, filed-worthy defect that surfaced only because an agent happened to
mention it in passing.**

**The orchestrator TRIAGES the friction report.** For each item: reproduce it (the gap
docs lie — see above), then either fix it, file it in the backlog / PLAN.md, or record it
as a known-red ledger entry with accidental-fix detection. **Do not let it evaporate.**
An agent's incidental "oh, I had to work around X" is one of the highest-signal inputs
you get — it is a bug found by *use* rather than by *audit*, which is the only kind that
reliably matters.

---

## Review every agent PR before merging

An agent's own report is a claim, not a review. After an agent opens a PR (and after CI
is green), spawn a **Sonnet reviewer** over the diff. It is cheap, it is parallel, and it
catches the class of thing gates cannot: style drift, obvious inefficiency, a missing
test, a comment that lies, a workaround left in.

**This is a different job from the gates.** Gates prove *behavior*; the reviewer judges
*craft*. Green CI on a bad diff is still a bad diff.

See **`.claude/skills/pr-review/SKILL.md`** for the playbook the reviewer runs. Keep the
reviewer READ-ONLY — it reports findings; you decide what to act on, and the *authoring*
agent fixes them (it has the context; you do not).

---

## Verifying a landing — never trust prose

An agent saying "done, all gates green" is a claim, not evidence. Verify, bounded
to the decisive checks:

- **For a feature that EXPANDS the set of accepted programs (a type-system change), the decisive
  check is probing the newly-accepted FRONTIER yourself — not the agent's fixtures.** Agents'
  fixtures cluster on the happy path and on shapes the stdlib already exercises. This session,
  #11 (Num-polymorphic literals) shipped Stages 0-4 "all gates green," but the agents never tested
  a *user* polymorphic-literal fn applied to Float (`inc x = x + 1; inc 2.5`) — which typechecked
  but **panicked at runtime** (a soundness hole), and separately built to **silent garbage** (a
  pre-existing emitter gap the feature newly exposed). Both were found by a 60-second hand-probe of
  the frontier the feature opened, AFTER the agents reported green. Ask: "what programs does this
  newly accept, and do they actually RUN/BUILD correctly across every instantiation (Int *and*
  Float)?" — then run those, on `run` AND `build`, vs the oracle. A clean fixpoint + green
  differentials do NOT cover behavior the existing corpus never had.

- `git log main..<branch>` — the commits actually exist; `git diff --stat` — the
  change surface matches the report (additive where it should be).
- Re-run the **critical** gate(s) yourself — for an emitter/codegen change, the
  fixpoint + one differential + the minimal repro. You don't need to re-run
  everything; pick what would catch a lie or a subtle break.
- **Pick the decisive check per change type.** For a self-hosted-emitter change the
  **fixpoint (C3a/C3b) is the single strongest test** — it recompiles the *whole compiler*
  with the change and proves it self-reproduces byte-for-byte. For a code *transform*
  (e.g. TRMC), an **IR-shape assertion** proves it actually fired — e.g. grep the eligible
  function's emitted body for *no* `call @mdk_<self>`. A green output-differential proves
  behavior is preserved (the gates compare program OUTPUT, so a pure rename/transform is
  invisible to them but a mis-route shows as wrong output). One decisive check > re-running
  the whole suite.
- `ps` for **orphan processes** — agents sometimes spawn background gate runs and
  end without reaping them; kill leftovers (they burn CPU).
- Watch for the **empty-report failure mode**: an agent that committed but left
  gates running in the background and ended with "waiting on the monitor…". Treat
  the commit as unverified and gate it yourself.
- **Force-rebuild the oracle binaries before you re-run a `test/bin/*` gate yourself.**
  `test/build_oracles.sh` mtime-skips, so your own "re-verify" can read a stale binary too —
  `FORCE=1 bash test/build_oracles.sh` first. A green/red on a stale oracle means nothing
  (this masked a real prop regression as "9/0 unchanged" until a forced rebuild showed 5/4).
- Only after green: `git merge <branch> --no-edit` into local main **in the primary checkout**
  (`git -C /root/medaka merge`), then **confirm the integration branch actually advanced**:
  `git rev-parse main` == the new tip (and `git reflog main` shows the merge). A "Fast-forward"
  printed on a *detached HEAD* is indistinguishable from one on the branch — this session that
  silently stranded two phases (see Failure modes). Then reconcile docs/tasks/memory.

---

## Hand-offs that don't rot — make the bug list EXECUTABLE

"The gap docs lie" (above) says *reproduce before you trust them*. That is the diagnosis. This is
the **remedy**, and it worked so well this session it should be the default whenever you hand a
list of defects to someone else (another orchestrator, a future session, a human).

**Do not hand over prose. Hand over a script.**

- **Encode every verified repro in a status script** (`verify_<topic>.sh`) that re-runs each one
  against the current binary and prints **OPEN / FIXED** per item. Status report, **not a gate** —
  always exit 0, so nobody wires it into CI and starts ignoring it. Put a
  **"⚠️ DO NOT TRUST THIS LIST — RUN THE SCRIPT"** banner at the top of the companion doc.
  Payoff: while my branch was in flight, another orchestrator fixed one of my P0s. The script
  detected it **with zero bookkeeping from either of us.** A static list would have been wrong
  within hours.
- **Tag every workaround in the code with a greppable marker** — `WORKAROUND(B2): … revert when
  B2 closes` — and have the script **print the marker sites beneath its OPEN/FIXED report.** Then
  the same command that tells you a bug is fixed tells you exactly which lines to delete.
  Otherwise workarounds quietly become permanent architecture long after the bug is gone. (We
  were carrying 7 workarounds for 4 bugs; one got reverted the same day its bug closed.)
- **Separate what YOU reproduced from what an agent claimed.** Mark them differently
  (✅ VERIFIED / 🟡 REPORTED). Agent root-causes were wrong often enough to matter, and a
  confident-but-wrong entry poisons the next person's search.
- **Distinguish the diagnosis from the inference.** An agent reported "we need `runST`". The
  *observation* (two authors hit the same wall, with measured cost) was gold; the *conclusion* was
  premature — the real defect was upstream, in what the effect actually meant. Log what hurt, not
  what you'd build.

## Choosing the model

- **Sonnet** — surgical, scoped, additive, read-only, or mechanical-with-a-clear-
  template work (e.g. wiring, a single additive dispatch arm, audits).
- **Opus** — heavy/risky: real codegen changes, central-dispatch refactors,
  anything with uncertain blast radius, or where debugging depth matters if it
  goes sideways. Default here for edits to the hottest/most-load-bearing file.
- Escalate mid-pattern: a "simple" first step may be Sonnet; the general fix it
  ladders into is Opus.

---

## Parallelism & file hygiene

- Parallelize only **non-overlapping files**. Never put two agents on one file;
  never pile agents onto the single hottest file. Sequential when they share a file
  (each must verify-green + merge before the next branches, to avoid conflicts).
- **The MERGE is where integration bugs live — verify the merged result, not the branches.**
  Two agents on genuinely disjoint files both reported green and git merged them with **zero
  conflicts** — and the merged tree had three real defects neither could have seen: git happily
  auto-merged agent A's `deriving (Eq)` on top of agent B's *deliberately hand-written* `impl Eq`
  (→ overlapping impls), and A's exhaustive `match` predated the new ADT constructor B added
  (→ latent panic). **"No conflict" means textually compatible, not semantically compatible.**
  Always run the full gate suite on the merged tree, never just trust two green branches.
- **Read-only audits parallelize freely** — zero merge risk; good use of otherwise-
  idle time while a write agent runs. For a broad review (a milestone gate), **fan out by
  domain** (typecheck / emitter / parser / error-path) — one consolidated agent is shallower.
- **Doc-edit hygiene under concurrency:** if an agent is concurrently *appending* to a
  shared doc (most agents append an "AS-BUILT" section at EOF), make your own edit a
  **mid-file insert** in a stable region, not an end-append — the 3-way merge then auto-
  resolves (different regions) instead of conflicting at EOF.
- Mind CPU contention with long-running gates from other sessions; read-only/doc
  work doesn't contend, build-heavy work does.

---

## Dogfooding as a bug-finding strategy (when the goal is "find compiler bugs")

Building a real library in the language is the highest-yield bug finder we have — but **only if
you choose the work deliberately.** Two levers:

- **Pick work that stresses NEW language surface, not more of the same shape.** The six SQL query
  features before this session found **zero** compiler bugs — not luck: they were all the same
  shape (add an ADT node, add an evaluator arm, add an oracle). The moment we did work with a
  *different* shape — a parser built on a user-defined monad, byte-chain manipulation, a
  cross-project dependency — bugs fell out immediately. **Before scoping a dogfood task, ask:
  "what part of the language does this exercise that nothing else has?"** If the answer is
  "nothing," it will grow the library and find nothing.
- **Know which execution path your tests actually cover.** Every doctest in this repo runs under
  the **interpreter**. So a bug that exists only in *compiled* code is invisible to the entire
  suite: the SQL parser shipped **32/32 green doctests** while *every arithmetic operator in its
  grammar* was silently miscompiled in the native binary. **Tell agents explicitly that an
  interpreter-green result proves nothing, and require every gate to run against a real `build`.**
  (The systemic fix — a differential `run`-vs-`build` gate over the existing doctest corpus —
  would have caught 4 of this session's 10 bugs for free. Recommended.)
- **Feed the system real input, not hand-built structures.** Every prior oracle constructed its
  query as an ADT by hand; none ever put a `NOT` over a nullable column. The first time we fed
  actual SQL *text* through the same engine, it exposed a wrong-answer bug (3-valued logic
  collapsed to 2-valued) that had been sitting there the whole time.

## Principles (this session's keepers)

- **Close gaps principled, not piecemeal — but ladder up.** The point of a
  canonicalization push is to close gaps so they don't reemerge. Prefer the general
  fix over a half-measure; surface the choice. Incremental is fine **iff** each
  bounded rung reusably composes into the general fix (or is a strict subset) — not
  a throwaway the principled fix discards. Keep a proven fallback if the general fix
  might balloon.
- **Bounded orchestrator research** (see above) — frame, don't exhaustively map.
- **Surface design decisions**, give recommendations not surveys, and act on
  sensible defaults rather than over-asking.
- **Defer expensive regenerations.** Batch costly artifacts (big regenerated files)
  to real checkpoints instead of after every sub-task, to avoid churn commits.
- **For a large task delegated in pieces, give "incremental-landing" permission + ask for the
  next gap.** Tell the agent: land a coherent gated chunk, stub the rest with a recognizable
  marker, and REPORT the precise residual. This keeps a sub-task from ballooning and makes a
  blocked hand-off self-documenting — the honest STOP with a precise punch-list (ideally + a
  pointer to where the fix already exists) is the deliverable, not a failure.

---

## Big architectural changes — the design→staged→seams playbook

For a large, route-fragile change (this session: TRMC), don't hand one agent the whole
thing. The pattern that worked:

1. **Design-pass first** — a read-only Plan agent that confirms the problem empirically,
   recommends the mechanism, maps the touchpoints, and returns a **decision-ready design
   with an explicit "design forks (need a human decision)" section.** Persist it as a
   `*-DESIGN.md` doc (the implementation agents share one spec; it's also the future record).
   Two rules learned the hard way on a language-design question this session:
   - **Ask "does an existing spec already answer this?" FIRST, before reasoning from principles.**
     I was about to write a design doc from scratch; the reviewer found the question *was* already
     answered in a spec I hadn't read — and, better, that **the implementation contradicted the
     spec**. That reframed the whole problem (the defect was in what the effect *meant*, not in
     the feature we thought was missing). One `grep` would have saved an hour of theorising.
   - **Hand the reviewer your hypothesis and tell it to BREAK it — an independent model is worth
     more than a second opinion that agrees.** I proposed a soundness argument for a new construct
     and asked for it to be attacked. It was demolished three ways, and I reproduced all three
     counterexamples on the binary. Ship the design **with the rejected alternative and the
     counterexamples that kill it** — it is the proposal the next person will reach for, and it
     looks right until you try to break it.
2. **Surface the forks to the user**, lock scope (e.g. "do (a), keep (b) a clean future
   extension"), and write the locked scope into the design doc.
3. **Staged implementation agents** — one per sub-part, ordered by ascending risk, each
   **independently gated + merged** before the next branches (same file ⇒ sequential). You
   verify each landing's decisive check (fixpoint + the transform-fired assertion).
4. **Keep deferred-scope seams parameterized** so the deferred (b) is an *additive* later
   patch, not a rewrite — and tell each agent to keep them generic (computed offsets, no
   "zero leading params" assumptions). Then **scope the deferred extension explicitly** (a
   read-only scoping agent) even if you're deferring it — it captures the seam knowledge,
   verifies whether a real target even exists (often none → defer is the principled call),
   and corrects over-optimistic seam notes the implementers left behind.

Re-mint expensive artifacts (the seed) once at the **completed-change checkpoint**, not
per sub-part. A *comment-only* edit to an emitter-graph file does NOT invalidate the seed
(emitted IR is identical) — but any logic change does.

---

## Failure modes seen

- **Agent commits on its OWN-named branch, not the `worktree-agent-<id>` branch.** Several agents
  reported a branch like `wasm-w8-leaf-externs` and committed there; the `worktree-agent-<id>` branch
  stayed at the base. Merging the worktree-id branch is then a silent no-op (this session: gate read
  52/52 instead of 68/68). **Merge by the reported SHA**, and confirm with `git branch --contains <sha>`
  before trusting the merge.
- **An agent's self-reported `BASE_OK` can be FALSE — verify the base yourself before merging.** A
  STEP-0 `git merge main` + `merge-base --is-ancestor` self-check is necessary but not sufficient: this
  session a write-agent reported `BASE_OK` yet its branch was rooted at the *session-start* commit,
  missing every overnight landing (its worktree/merge silently didn't catch up to the real tip). The
  catch was the orchestrator's own pre-merge sanity check: `git diff --stat <main> <branch>` showed
  ~1400 spurious deletions and a recent fixture file listed as *deleted*. **Always `git diff --stat`
  the branch against current main before merging** — a surface that doesn't match the agent's "small
  additive change" report (mass deletions, recent files vanishing) means a stale/wrong base; do NOT
  merge. Cross-check with `git merge-base --is-ancestor <recent-landing-sha> <branch>`. (Bake a base
  assert into agent prompts too — `test -f <a-recent-landing-file>` + `grep -q <a-recent-symbol>` — but
  the orchestrator's diff-stat is the real net, since the agent's own report is what's untrustworthy.)
- **Salvaging a session-limit-killed agent.** An agent can die mid-run (usage limit) having committed
  NOTHING — but its WIP is live in its worktree (`git -C <worktree> status`). Preserve it (commit on
  its branch), then verify INDEPENDENTLY from scratch (it left no report) and give it a real commit
  message. This session W5 was fully salvaged this way; the work was real and correct.
- **Two more stale-binary footguns (beyond `FORCE=1 build_oracles`):** (1) `make medaka`'s
  `find -newer` short-circuit can leave `./medaka` NOT carrying a lexer/compiler-graph change →
  `FORCE_EMITTER_REBUILD=1 make medaka` when verifying such a change. (2) the OCaml oracle
  `_build/default/bin/main.exe` is rebuilt by `dune build --root . bin/main.exe`, NOT by `make medaka`
  — a stale main.exe made a fixed repro falsely read `oracle=REJECT`. Rebuild the specific binary the
  check reads before trusting it.
- Agent commits then ends with an empty/"waiting" report → verify from git + gates.
- **A returned agent with ≈0 tool uses + a boilerplate/empty result = a failed run, not a
  completed one.** Don't act on it; re-spawn (sometimes a different agent type helps).
- **Garbled or stale-verified report.** Beyond the empty report: an agent can return a stray
  monitor/tool echo as its "result" (garbled), OR report "all gates green / no regression"
  computed against STALE `test/bin/*` oracles or a stale `./medaka`. Both are unverified.
  Inspect the branch from git and independently re-run the decisive gate with FORCE-rebuilt
  oracles (`FORCE=1 build_oracles`) + a fresh `make medaka`. This session a "5/4 unchanged vs
  HEAD" claim was actually a real regression masked by a stale oracle.
- **Stranded commits from a detached HEAD.** `git checkout <sha>` in a worktree DETACHES HEAD;
  a later `git merge --ff-only <branch>` then advances the *detached HEAD*, not the branch —
  the work lands on a dangling line and the branch stays put. This stranded two verified
  phases this session (recovered via `git cat-file -t <sha>` + `git reflog <branch>` → FF the
  dangling tip onto main). **Never `git checkout <sha>` in a worktree** (to drop commits use
  `git reset --hard <sha>` ON the branch; to inspect an old commit use a throwaway
  `git worktree add`). After any checkout, assert `git rev-parse --abbrev-ref HEAD` is a branch
  name, not `HEAD`; after any merge, assert the integration branch advanced.
- **Non-isolated background agents SHARE the orchestrator's worktree filesystem + git HEAD.** An Agent spawned WITHOUT `isolation: worktree` runs in your worktree's working dir: it `git checkout -b`s there (leaving YOUR worktree on its branch when it finishes — `git checkout <branch>` later prints "Already on …"), and its builds write the same `./medaka`/`_build` artifacts as yours. Consequences this session: (1) **never run two build-heavy things at once** (your fixpoint + an agent's `make medaka` would corrupt shared artifacts) — sequence heavy builds, spawn build-touching agents one at a time or after your own build finishes; (2) a clean `git status` doesn't prove an agent isn't mid-edit — it may just not have written yet; (3) merge still happens safely in the PRIMARY checkout (`git -C /root/medaka merge <sha>`) — that's a different working dir, so it never disturbs a running agent. For genuinely parallel write-agents on overlapping files, pass `isolation: worktree`.
- **An agent can commit stray build-artifact binaries via `git add -A`.** This session an agent's commit included 5 root-level demo binaries (~250 KB each, not gitignored) alongside the real change. Caught by the standard pre-merge `git diff --stat <main> <branch>` surface check (Bin entries that don't match the reported change). Fix: rebuild a CLEAN commit off main with only the intended files (`git checkout -B clean main; git checkout <agent-sha> -- <good files>; commit`), then merge that — do NOT merge the polluted commit. Bake "commit ONLY your changed source + fixtures, never `git add -A`" into agent prompts.
- Agent leaves detached background gate processes → reap with `ps`/`pkill`.
- **The empty-report + RESPAWNING-oracle-pool failure mode (recurred on MANY agents 2026-07-10, Sonnet AND Opus).** An agent ends its turn with a stray line ("Background scan in progress…", "I'll wait for the oracle build…") instead of a real report, AND it launched a bare `build_oracles.sh` (a big `xargs -P` pool) that didn't finish inside the turn — so each time the harness re-invokes/wakes it, it RESTARTS the pool. Reaping the pool alone doesn't work (it respawns). **Remedy, in order: (1) `TaskStop <agentId>` FIRST to stop the respawn; (2) reap — `pkill -f build_oracles.sh` (PARENTS) then `pkill -f '<worktree>/medaka build'` (children) then `pkill -f 'xargs -P'`; (3) salvage or discard.** Salvage IF the WIP in the agent's worktree is COMPLETE (`git -C <wt> status` + a grep for the target end-state, e.g. `grep EFunction=0`): fmt/build/gate it yourself, commit on its branch, finish any unrecaptured goldens it left. DISCARD + re-spawn if the WIP is a partial/hack (e.g. one file, target not met). **Bake into every agent prompt: NEVER run bare `build_oracles.sh`; build a single oracle with `FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one <name>`; WAIT for gates and REPORT real numbers; never end with anything running.** (Even so, expect some agents to ignore it — the `TaskStop`+salvage loop is routine.)
- **Fresh isolated worktrees have NO `./medaka_emitter`, and a deferred-stale seed makes cold-bootstrap-from-seed FAIL.** So an agent's first `make medaka` in a fresh worktree can't build. Remedy baked into prompts: `cp <a-current-worktree>/medaka_emitter ./medaka_emitter` before `make medaka` (warm path). Keep ONE orchestrator worktree with a freshly-built current emitter for agents to borrow. (A **seed re-mint** — `sh test/refresh_seed.sh` then verify `bash test/bootstrap_from_seed.sh` C3a PASS — fixes cold bootstrap; do it at real checkpoints, it's a ~2.5 MB churn commit. A byte-identical-IR source change, e.g. `data X=X{}`→`data X={}`, needs NO re-mint.)
- **A construct-removal census MUST scan the always-loaded prelude (`stdlib/core.mdk`) for REAL uses** (not just doc-comment/string matches). A missed prelude use makes the *compiled* binary fail to load the prelude → it errors on EVERY program, which mimics a native codegen/DCE miscompile (2026-07-10: a whole Opus agent spent a 12-build bisection before another proved the emitted IR was byte-identical live-vs-dead and the real cause was `core.mdk` using the removed construct). Grep the prelude first; there is no DCE miscompile.
- A "surgical one-node" scope hypothesis turns out coupled to a deeper issue → the
  STOP guardrail catches it; re-scope rather than ship "panic-gone but output-wrong."
- **About to spawn a fix at a parked gap that's actually already closed** (or whose symptom
  has shifted) → reproduce-on-current-main *before* spawning. See "The gap docs lie."
- Stale worktree: a long-lived orchestrator worktree drifts behind local main →
  `git merge main` it before relying on its state.
- **⚠️ A GATE THAT CAN SILENTLY NO-OP WILL. "Green" is not the same as "ran".** Three separate
  instances in one session: (1) every wasm gate shells out to `wasm-tools`, which **was not
  installed** — so each one printed `skipping` and **exited 0**. The suite reported green while
  running *nothing*; the WasmGC tandem gate had never once executed on this machine (this was the
  standing "1 skip" everyone read past). (2) `sqlite3`, the differential oracle for 18 gates, was
  also absent. (3) Two oracle scripts had **never been able to pass** — each `mv`'d a binary onto
  itself and died before running a single assertion. **At session start, prove your gates actually
  execute: check the tool deps exist, and look at assertion COUNTS, not exit codes.** A gate whose
  failure mode is "exit 0" is worse than no gate, because it manufactures confidence.
- **Session start:** `git worktree list` + `ps` — check for other live sessions, orphan
  gate processes, and accumulated stale worktrees (they pile up fast; prune the merged ones,
  preserving your own + any running agent's + branches with unmerged commits).

---

## Bookkeeping

- A `TaskList` chain for multi-step sub-projects (blockedBy dependencies); mark
  in_progress/completed as you go.
- After each landing, reconcile the roadmap doc (`PLAN.md`), and verify root-cause
  claims on the binary before trusting them in docs.
- Record durable workflow learnings in memory; record role learnings **here**.

---

## Medaka specifics

- ⚠️ **THIS DOC STILL CONTAINS STALE OCaml/dune INSTRUCTIONS BELOW.** OCaml, `dune`,
  `opam`, and `_build/default/bin/main.exe` were **REMOVED 2026-06-26**. There is no
  OCaml oracle to diff against — the "differential" gates now compare the native
  compiler against goldens captured *from itself*. Anywhere this file says `dune
  build`, read `make medaka`. Anywhere it says "vs the OCaml oracle", read "vs a
  checked-in golden". Left in place rather than silently rewritten because the
  surrounding *lessons* are still true; but do not follow the commands.
- **Build:** `make -C /absolute/path/to/worktree medaka` (the shell cwd resets between
  calls, so a bare `make medaka` would build the MAIN checkout). A fresh isolated
  worktree has **no `./medaka_emitter`** and cannot cold-bootstrap — `cp
  /root/medaka/medaka_emitter "$PWD/medaka_emitter"` first (the warm path).
- **Never `pkill -f build_oracles.sh` / `pkill -f 'xargs -P'` on this box.** Those are
  box-wide pattern kills; with several sessions running they will terminate *other
  people's* builds. (The sandbox now blocks it, correctly.) Scope every reap to the
  offending agent's own PIDs:
  `ps -eo pid,args | grep "agent-<id>" | grep -v grep | awk '{print $1}' | xargs -r kill`
- **Local main is ahead of origin.** Orchestrator merges agent branches into LOCAL
  main; `main` is checked out in the primary checkout `/root/medaka` — merge there
  (`git -C /root/medaka merge <branch>`). **As of 2026-07-13 pushing IS expected** for
  the PR-based CI flow (see "Agents do NOT run the full suite" above): the orchestrator
  pushes a branch and opens a PR; CI runs the full suite on free hosted runners. Agents
  still never push and never merge.
- **Emitter-graph changes (`compiler/llvm_emit.mdk` etc.) leave the committed seed
  `compiler/seed/emitter.ll` STALE.** Agents do NOT re-mint — they verify
  `test/selfcompile_fixpoint.sh` (C3a/C3b YES; it self-compiles fresh, doesn't read
  the committed seed) and SKIP `bootstrap_from_seed.sh`. The orchestrator re-mints
  (`test/refresh_seed.sh`, OCaml-only, then verify `bootstrap_from_seed.sh`) only at
  **real release checkpoints** — defer during heavy iteration to avoid ~10 MB churn
  commits. `bootstrap_from_seed` red is expected while the seed is deferred-stale.
- **The decisive emitter gate is the fixpoint** (C3a = native == interpreted
  emission; C3b = native reproduces its own IR). Plus the byte-identical differential
  suite vs the OCaml oracle: `diff_compiler_llvm` (172) / `_modules` (8) / `_typed`
  (37) / `diff_compiler_build` (9), and the front-end/typecheck/eval `diff_compiler_*`
  gates for those stages.
- **The OTHER stale-binary footgun: the `test/bin/*` oracle binaries.** Gates like
  `diff_compiler_test` / `diff_compiler_eval_*` run a committed native oracle binary built from
  `compiler/` source by `test/build_oracles.sh` — which **mtime-skips rebuilds** ("N up-to-date").
  After a `typecheck.mdk`/`eval.mdk` change the oracle is often NOT rebuilt → the gate silently
  runs OLD source. This bit **three times in one session** (two agents reached opposite
  conclusions; a real prop regression read as "unchanged"). **RULE: `FORCE=1 bash test/build_oracles.sh`
  before trusting ANY `test/bin/*` gate** (FORCE overrides the mtime skip) — bake it into agent
  prompts touching typecheck/eval and into your own re-verification. Same shape as the `./medaka`
  stale-binary footgun; a green/red on a stale binary means nothing.
- **Decided invariants — do not relitigate** (see memory): retirement ≠ removal
  (lib/ stays frozen until a confidence gate); lazy top-level nullary canonical;
  no catchable panics.
- **A new gap in a tool's native compile** (a tool pulled into the native graph for
  the first time) is the recurring shape: census it gap-tolerantly
  (`compiler/entries/llvm_emit_gaps_main.mdk` over the tool's entry), then close each gap
  principled. EMITTER-GAPS.md is the gap ledger.
