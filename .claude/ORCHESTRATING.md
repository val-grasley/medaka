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
   with counts. **For any gate that reads `test/bin/*` oracle binaries (`diff_selfhost_test`,
   `diff_selfhost_eval_*`, …), prefix it with `FORCE=1 bash test/build_oracles.sh`** — that
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
  (`git -C /Users/val/medaka merge`), then **confirm the integration branch actually advanced**:
  `git rev-parse main` == the new tip (and `git reflog main` shows the merge). A "Fast-forward"
  printed on a *detached HEAD* is indistinguishable from one on the branch — this session that
  silently stranded two phases (see Failure modes). Then reconcile docs/tasks/memory.

---

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

---

## Big architectural changes — the design→staged→seams playbook

For a large, route-fragile change (this session: TRMC), don't hand one agent the whole
thing. The pattern that worked:

1. **Design-pass first** — a read-only Plan agent that confirms the problem empirically,
   recommends the mechanism, maps the touchpoints, and returns a **decision-ready design
   with an explicit "design forks (need a human decision)" section.** Persist it as a
   `*-DESIGN.md` doc (the implementation agents share one spec; it's also the future record).
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
- Agent leaves detached background gate processes → reap with `ps`/`pkill`.
- A "surgical one-node" scope hypothesis turns out coupled to a deeper issue → the
  STOP guardrail catches it; re-scope rather than ship "panic-gone but output-wrong."
- **About to spawn a fix at a parked gap that's actually already closed** (or whose symptom
  has shifted) → reproduce-on-current-main *before* spawning. See "The gap docs lie."
- Stale worktree: a long-lived orchestrator worktree drifts behind local main →
  `git merge main` it before relying on its state.
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

- **Build:** `dune build --root .` inside a `.claude/worktrees/<name>` worktree
  (plain `dune build` climbs to the parent checkout and fails). Never `dune test`
  (hangs) — run individual suites / `test/diff_selfhost_*.sh` / `test/*_fixpoint.sh`.
- **Local main is ahead of origin.** Orchestrator merges agent branches into LOCAL
  main; never fetch/push. `main` is checked out in the primary checkout
  `/Users/val/medaka` — merge there (`git -C /Users/val/medaka merge <branch>`).
- **Emitter-graph changes (`selfhost/llvm_emit.mdk` etc.) leave the committed seed
  `selfhost/seed/emitter.ll` STALE.** Agents do NOT re-mint — they verify
  `test/selfcompile_fixpoint.sh` (C3a/C3b YES; it self-compiles fresh, doesn't read
  the committed seed) and SKIP `bootstrap_from_seed.sh`. The orchestrator re-mints
  (`test/refresh_seed.sh`, OCaml-only, then verify `bootstrap_from_seed.sh`) only at
  **real release checkpoints** — defer during heavy iteration to avoid ~10 MB churn
  commits. `bootstrap_from_seed` red is expected while the seed is deferred-stale.
- **The decisive emitter gate is the fixpoint** (C3a = native == interpreted
  emission; C3b = native reproduces its own IR). Plus the byte-identical differential
  suite vs the OCaml oracle: `diff_selfhost_llvm` (172) / `_modules` (8) / `_typed`
  (37) / `diff_selfhost_build` (9), and the front-end/typecheck/eval `diff_selfhost_*`
  gates for those stages.
- **The OTHER stale-binary footgun: the `test/bin/*` oracle binaries.** Gates like
  `diff_selfhost_test` / `diff_selfhost_eval_*` run a committed native oracle binary built from
  `selfhost/` source by `test/build_oracles.sh` — which **mtime-skips rebuilds** ("N up-to-date").
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
  (`selfhost/entries/llvm_emit_gaps_main.mdk` over the tool's entry), then close each gap
  principled. EMITTER-GAPS.md is the gap ledger.
