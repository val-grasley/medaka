# Next-orchestrator handoff — Medaka (2026-07-13)

## 🚦 READ THIS FIRST: how work lands now

**`main` is PROTECTED. You cannot push to it.** Everything goes through a PR.

```sh
git checkout -b <topic>
# ... work; `make preflight` while iterating ...
git push -u origin <topic>
gh pr create --fill
gh pr merge --auto --merge      # self-merges the moment all 9 checks go green
```

**9 required checks:** six `gates (…)` shards, **`soundness`**, `seed-health`, `inlang`.
**0 approvals** — the checks are the gate, not a human. **No admin bypass.**

- **`soundness` must never be dropped.** It runs the compiler-source typecheck + the
  self-compile fixpoint. **All 83 gates pass on an ill-typed compiler** (`make medaka` does
  not gate on type errors) — that is exactly how a compiler with unbound constructors shipped
  to main today, with every gate green.
- **A PR must be up to date with main before it merges** (strict). CI therefore tests **your
  branch merged onto main**, not your branch alone. This is load-bearing: two green branches
  have merged cleanly into a **crashing** tree.
- **No merge queue, and there cannot be one** — GitHub requires an org-owned repo; this one is
  user-owned. `strict` is the mitigation. The `merge_group:` trigger is already in `ci.yml`, so
  a queue is a one-line ruleset addition the day this moves to a `medaka` org.

## 🚨 THE ONE THING THAT WILL BITE YOU: agents build in YOUR worktree

The harness injects **your** `CLAUDE.md` path into every subagent's context, so agents `cd`
into **your** tree. **Four incidents in one session** (T32):

- one ran `make medaka` concurrently with mine, same `./medaka` — its build exited 0 and was
  **worthless**;
- one's `git diff > patch` swept up a sibling's unstaged golden;
- one had uncommitted **emitter** edits present while I ran `refresh_seed.sh`;
- one had its uncommitted `typecheck.mdk` semantics change **swept into my commit by
  `git add -A`** — `ab395e0b`'s message claims it touches only test ledgers. It does not.

**Rules, until the harness is fixed:**
1. **State the absolute worktree path in every agent prompt**, and tell the agent to ignore the
   CLAUDE.md path in its context.
2. **STAGE COMMITS BY PATH. NEVER `git add -A`.**
3. Never run `refresh_seed.sh` / `make medaka` in a tree you have not just confirmed clean.

## Verifying the seed (if you ever suspect contamination)

C3a passing does **NOT** prove the seed is clean — I claimed that and was wrong. A contaminated
seed affects the *codegen* of the intermediate generation while the emission still comes from
source, so C3a can pass with a dirty seed. The only real test is a byte comparison:

```sh
git worktree add --detach /tmp/chk <sha> && cd /tmp/chk
gunzip -c compiler/seed/emitter.ll.gz > /tmp/committed.ll
sh test/refresh_seed.sh && sh test/refresh_seed.sh    # TWICE — see below
gunzip -c compiler/seed/emitter.ll.gz > /tmp/fresh.ll
cmp /tmp/committed.ll /tmp/fresh.ll                   # identical => clean
```

**`refresh_seed.sh` is ONE pass and is NOT idempotent after a codegen change — run it TWICE.**
Pass 1 mints with the old-generation emitter (`C3a: NO`); pass 2 mints with an emitter built
from the new seed and converges (`C3a: YES`).

**A stale seed can make the fixpoint SEGFAULT on a perfectly correct change.** After the
arg-tuple removal the fixpoint died at step 2 while `make medaka` succeeded and all 83 gates
passed. Nothing was wrong with the merge — the *intermediate* generation, compiled by the stale
seed's fat pre-optimization codegen, blew the stack. **Re-mint before you go bug-hunting.**

## State of the tree

- `run_gates.sh` baseline: **83 passed / 0 failed / 0 skipped**
- Coverage: **103 of 110** gates in CI; the rest ledgered in `test/CI-COVERAGE-EXCEPTIONS.txt`
  (one, `build_construct_coverage`, is **RED and unexamined** — 138 ok / 1 failing)
- Fixpoint: C3a YES + C3b YES byte-for-byte · compiler source type-clean
- `run_gates` now **REFUSES** to run against stale oracles (they don't fail, they *lie* — three
  agents were burned, one nearly re-diagnosed its own already-fixed bug from a stale binary)

## Open bugs, worst first

| | |
|---|---|
| **T33(a)** | **SILENT.** A definer shadow whose standalone is *constrained* miscompiles — build prints **garbage**, even with no impl at the receiver head. The `RLocal`-vs-dict-passing seam. Fix = thread a dict through ast + route + eval + LLVM + wasm. Real work, not a patch. |
| **T30** | A duplicate top-level function name **SEGFAULTS the emitter** instead of erroring; the diagnostic ("clauses must be contiguous") gives *actively wrong* advice. |
| **T34** | **TWO auto-print contracts.** The llvm gate's probe prints `false`; `medaka build` prints `False`. The gate validates a path users never take. Also: there is **no supported way** to regenerate a `test/llvm_fixtures` golden — AGENTS.md's recipe is wrong for that corpus. |
| **T33(b)** | A multi-typaram interface bypasses the definer-shadow machinery entirely (loud, not silent). |
| **T21** | 11th quadratic: `resolve`'s scopes are `List String` with linear `contains`. Top allocator, 3.82x per doubling. |
| **T19** | `medaka check` runs the front end 2–3x per invocation (~3x constant factor). |
| **T27** | Missing stdlib: an effectful traversal family (`mapMut`/`foldlMut`/`zipWithMut`). Because `map`/`zip`/`foldl` are pure, **every** `<Mut>` traversal in the compiler gets hand-rolled — the emitter carries four near-clones. |
| **T20** | Diagnostic quality: a **fabricated `1:0` source location**; leading-`->` in a multi-line signature rejected with a misleading "indentation" error. |

## What the friction rule is worth

Most of today's best finds came from the mandatory FRICTION REPORT, not from the assigned
tasks: the formatter writing a raw NUL that made `grep` silently blind; the two-rebuild
benchmarking trap (an agent measured its own 2.2x win as a 2.5x *slowdown*); the stale-oracle
false REDs; `preflight` being broken for every compiler change. **Keep demanding it, and keep
demanding it name MISSING STDLIB FUNCTIONS.**

---
---

# ── ARCHIVE (previous handoffs below) ──

# Next-orchestrator handoff — Medaka, WasmGC backend + soak (2026-06-19)

## RESUME — ⚖️ TMC PARITY ARC SHIPPED + MERGED TO MAIN: both backends apply TMC to the SAME functions, gated. LLVM gained dispatch-graph (b′) TMC; a SILENT guarded-arm TRMC miscompile found+fixed. Branch `tmc-parity-arc`, merged. (2026-07-13)

**Merge note:** main advanced mid-arc (snapshot-R1 gate migration, `a9f0a8a5` — parse/desugar/mark
goldens deleted for an in-process snapshot family). Merged main into the arc, resolved by taking the
deletions + re-cutting the 3 changed backend snapshots (`rm test/snapshots/compiler/<f>.md` +
`--new`); `diff_compiler_tmc_parity` added to the CI backend shard (the new
`ci_shard_coverage` meta-gate caught it) and made self-provisioning (builds the wasm probes instead
of skipping). **Seed re-minted from the MERGED source** (both sides had minted; post-merge mint is
the valid one) — cold `bootstrap_from_seed` PASS. Post-merge: run_gates **81/81** (the new suite),
stack 10/10, fixpoint C3a/C3b YES, type-clean.

Plan: `/root/.claude/plans/ancient-stargazing-planet.md`. Owning docs: `compiler/TRMC-DESIGN.md` §Phase 3 (rewritten — SHIPPED), `compiler/WASMGC-TRMC-DESIGN.md` header note. PLAN.md "Native TMC parity" row CLOSED.

### WHAT SHIPPED (5 commits, each independently gated)
- **P0/P4 census + gate** — `test/tmc_census.sh` + `test/diff_compiler_tmc_parity.sh` (globbed by run_gates; needs `sh test/wasm/build_wasm_oracle.sh`, else skip exit 2). Both emitters write `; tmc:` / `;; tmc:` markers per TMC decision; the gate FAILS on any per-function set diff. check_main graph: **149 == 149 byte-identical** (11 groups incl. lexer `scan`, `layout`, `intersperse` + ~40 members + 98 Stage-1/impl fns).
- **P1 detection lift** — Stage-3 dispatch-graph detection moved from `wasm_emit.mdk` into shared `backend/trmc_analysis.mdk` (hook-parameterized). WAT byte-identical; emitter IR byte-identical (DCE'd until P2).
- **P2 LLVM (b′) emit — the 2026-06-22 deferral's obstacles both dissolved.** No musttail needed: detection v4 proves the root is the group's sole external entry, so the whole group INLINES into the root's one define (`gdisp_<m>` blocks, `br` edges, LOCAL alloca dest = Stage-1 protocol; members emit no standalone define). Detection non-termination was already fixed by the Stage-3 algorithm (pass-0 tables + 256-cap BFS): measured **~0.6% of emit**; whole-emit vs pre-arc seed emitter ≈ **+4–8%** on check_main. The compiler's own lexer token spine is now O(1) NATIVE stack (fixture `dispatch_group_deep`, 2M deep). `bprime-llvm-wip.patch` deleted (superseded).
- **P3 wasm mixed-ctor TMC** — `wTrmcUniformCtor` gate retired; mixed leaf-ctor sets link via `$__tmc_dctor` dispatch (singleton sets byte-identical to before — whole corpus WAT verified). Made v5 stage-1-claims backend-identical. Fixtures `w_trmc_mixed_ctor` + `mixed_ctor_deep`.
- **🐛 SILENT MISCOMPILE fixed (found by reading for the port):** `emitGuardedArm` had no TrmcOn branch — a guarded arm in a TRMC tail-position match value-emitted into the dead `trmcdecend`/`unreachable` block (UB: native printed `[]`/0, interpreter + wasm correct). Fixture `guard_arm_trmc` (2M deep). Commit `02446e85`.

### STATE
- run_gates **83/0/0** (incl. the new parity gate); diff_native_stack 10/10; fixpoint C3a/C3b YES; compiler type-clean; **seed RE-MINTED on this branch + cold `bootstrap_from_seed` PASS** (covers the re-mint previously owed for #35 — testing-arc merged first, per the deferral plan).
- wasm gates: 149 ok / **4 pre-existing FAILs** (`w7_array_*`: "unbound variable 'index'" — Index-arc fallout, reproduced on pristine main) + typed 7/1 (`disp_hof_shadows_method` oracle build type error). NOT this arc's; worth filing.
- Engines-ledger gotcha: a new deep fixture in `test/wasm/fixtures/` auto-enrolls in `diff_compiler_engines` — add its `eval:no-tco` line to `test/engine_divergence.txt` (done for `w_trmc_mixed_ctor`).

### OPEN / NEXT
- Merge the branch; re-run `sh test/run_gates.sh` + `bash test/bootstrap_from_seed.sh` post-merge (seed is valid as long as no other emitter-graph change lands in between).
- File the 4+1 pre-existing wasm gate failures (Index arc).
- DISTRIBUTION-DESIGN D2 Track 2 can be marked done; the "native self-compile in 8 MB" claim is untestable as-is (Track 1's 256 MB worker pthread self-provisions regardless).

## RESUME — 🗄️ THE SQLITE LIBRARY NOW SPEAKS SQL + the dogfood flushed 10 compiler bugs (2 P0 silent miscompiles, 1 P0 `fmt` corrupting source). Branch `sqlite-arc`, merged to main. (2026-07-13)

Ran the **SQLite workstream** in parallel with a compiler orchestrator (they owned `compiler/`, I owned `sqlite/` + docs). Everything was **pure-library**, so no fixpoint / seed re-mint was ever owed. All five sub-agents ran in isolated worktrees, each independently gated + merged.

### ⭐ DO-FIRST
- **`bash sqlite/findings/verify_compiler_bugs.sh` — the bug list is SELF-CHECKING.** It re-runs every repro against the current `./medaka`, prints OPEN/FIXED per bug, **and prints the `WORKAROUND(id)` sites in the library to revert when one closes**. Do NOT trust the prose in `COMPILE R-BUGS.md`; run the script. It already caught B1 being fixed upstream mid-session (`ced6342d`), and I reverted that workaround.
- **⚠️ B10 is a live footgun: `medaka fmt --write` DESTROYS SOURCE.** A float literal ≥ 1e15 is rewritten to scientific notation that **the lexer cannot read back** (it rejects every exponent form). `fmt --check` runs in the **pre-commit hook**, so the hook tells you to run the command that corrupts your file. Latent only because no committed `.mdk` currently holds such a literal. **AGENTS.md's "fmt is safe, 0 corruptions repo-wide" is a claim about the CORPUS, not the tool.**
- **The whole test suite is blind to build-only bugs — every doctest runs under the interpreter.** The SQL parser shipped 32/32 green doctests while *every arithmetic operator in its grammar* was silently miscompiled in the native binary. **A differential `run`-vs-`build` gate over the existing doctest corpus would have caught 4 of these 10 for free.** Strongly recommended.

### WHAT SHIPPED (all merged; 22/0 native oracles vs the real `sqlite3` CLI, 11/0 WasmGC tandem)
`medaka run sqlite/main.mdk db.sqlite "<any SQL>"` now creates, queries and mutates a real `.sqlite` that `sqlite3` validates (`integrity_check=ok`) and reads back byte-identically.
- **SQL front end** — `sqlparse.mdk` (expressions; built on the `parsec` dogfood lib via a cross-project dep) → `sqlstmt.mdk` (SELECT/INSERT/UPDATE/DELETE/CREATE TABLE) → `sqlexec.mdk` + `schemadef.mdk` → `main.mdk` CLI. Unsupported SQL = clean `Err`, **never a silently dropped clause**.
- **Query engine UNIFIED** (the big design fix): `Select` + `AggQuery` were two disjoint ADTs/executors — no aggregates over joins, no ORDER BY/LIMIT on aggregates, and aggregates were smuggled as **fake column names** (`eCountStar = ECol "count(*)"`). Now one `Select`, one executor, real pipeline, genuine `EAgg` node. Dissolved the "ORDER BY can't reference a computed column" limitation for free. `AggQuery` kept as a shim → every prior oracle passed untouched.
- **Overflow pages read+write.** Reads were **silently corrupting** payloads past the local/overflow boundary (correct length, wrong bytes — the "out of scope" comments were stale, and my own spot-check was too coarse to see it; an agent's byte-level `cmp` caught it). Removed the **mutate wall**: UPDATE/DELETE rewrite the whole file, so one >4 KB row used to make *every* mutation on that table fail.
- **Expression surface**: `||`, `LIKE`, `IN`, `BETWEEN`, `CASE`, `COALESCE`/`IFNULL`, `TRUE`/`FALSE`, scalar string fns — NULL semantics pinned against `sqlite3` (120 SQL strings, 0 diffs).

### 🐛 THE DOGFOOD YIELD → `sqlite/findings/COMPILER-BUGS.md` (10 bugs; 1 already closed)
2 P0 **silent** build miscompiles (partially-applied constructor — **FIXED upstream**; cross-module record **update** writing the wrong slot — OPEN), P0 `fmt` source corruption, `check`-accepts/`build`-rejects (`deriving (Eq)` over an `Array` field — and **`lint` recommends the unbuildable program**), multi-module `run` not gating type errors (**exit code is 1 either way**, so exit-code tests miss it), `run` dropping stdout on panic, `exit` unbound under `run`, `Float` unable to round-trip through display (**`0.1 + 0.2` prints `0.3`**), and `medaka test` treating a Markdown blockquote as a doctest — which had **silently disabled every doctest in `rowtype.mdk` for months**.

Also found **in our own engine** by feeding real SQL text to both engines: `compilePred` evaluated SQL's 3-valued logic as 2-valued — accidentally right under a top-level WHERE, **wrong under `NOT`**. Every prior oracle hand-built its query as an ADT, so none had ever put a `NOT` over a nullable column.

### 🧠 LANGUAGE DESIGN: `<Mut>` effect masking → `MUT-SCOPING-DESIGN.md` (decision-ready, surfaced in PLAN.md)
Two independent authors hit the same wall: `<Mut>` is contagious, so a pure fn can't use a local mutable buffer (allocate→fill→freeze is unavailable to pure code). Cost: a duplicated stdlib encoder + an O(chunks×bytes) gather. **The classification question turns out to be settled, and the answer is NEITHER capability NOR purity tracker:** `check_policy.mdk:588` drops `Mut` from the manifest, AND a **pure-TYPED function observably returns two answers across a mutation** (alloc + reads are pure). It's a *writer-discipline marker*. `stdlib/runtime.mdk:190` already ships two **unchecked trusted masks** with a comment naming the missing feature ("Medaka has no effect masking"). Recommends a `mut` block (trusted, with a perimeter check) — and records the tempting `runMut`-no-`Ref`-in-result proposal **with the 3 counterexamples that kill it** (all reproduced on the binary).

### ENV / PROCESS
- **`sqlite3` and `wasm-tools` were MISSING from this box** — and both fail as *success*: the sqlite oracles die on the first CREATE TABLE, and every wasm gate prints "skipping" and **exits 0** (this was the standing "1 skip" in `run_gates` 78/0/1 — the WasmGC tandem gate had never actually run here). Both added to `ops/provision.sh`.
- **Two sqlite oracles had NEVER been able to pass** (`update_expr`, `writer_api`): each `mv`'d a binary onto itself. 16/2 → 18/0. (main fixed these independently — same bug, same session.)
- **Isolated agent worktrees are cut from `main`, NOT from your session branch.** Bake `git reset --hard <branch>` into STEP 0.
- **Agents disproved the orchestrator twice** (my "overflow read works" was wrong; my `runMut` soundness argument was wrong). Both times the STOP-and-disprove instruction is what caught it. Keep it in every prompt.

### OPEN (next session)
Library: TEXT-operand arithmetic returns NULL where sqlite3 coerces (`'7'+1`=8 — a **wrong answer**); `rowid` pseudo-column unaddressable; `SELECT` with no `FROM`; then indexes / WITHOUT ROWID / b-tree balancing / transactions+WAL.
Compiler: the 9 still-OPEN bugs (run the script).


You are the **orchestrator** for Medaka, a self-hosting functional language whose native
LLVM backend is now CANONICAL (compiles itself + all user code OCaml-free). You design and
delegate work to subagents, verify their output against gates, and keep `main` + docs
coherent. You usually do NOT implement directly. **Read `.claude/ORCHESTRATING.md` first`**
(the orchestrator playbook — core loop, agent-prompt skeleton, verification discipline,
footguns) and `AGENTS.md` (the agent-facing router/map).

## RESUME — 🐛 BUG-FINDING SESSION. 3 landings, but the REAL output is a filed bug queue + the discovery that our green signal covered only ~60% of the gates. `main` = `49d8d1d7`. ⚠️ SEED RE-MINT OWED. (2026-07-13)

This session set out to do the `#18` operator-interface arc and ended up mostly finding bugs — several
severe, all reproduced and root-caused, all filed as tasks with minimal repros. **Read the BUG QUEUE
below before picking anything up; it is the payload.**

### ⭐ DO-FIRST STATE
- **`main` = `49d8d1d7`.** Globbed suite `run_gates` **78/0/1**; fixpoint **C3a YES / C3b YES**;
  compiler source type-clean. Warm `make medaka` fine.
- **⚠️ SEED RE-MINT IS OWED — cold `bootstrap_from_seed` is RED, and that is EXPECTED, not a break.**
  `#35` changed the emitter graph (`llvm_emit.mdk` + `wasm_emit.mdk`). I verified cold bootstrap fails.
  **The re-mint was DELIBERATELY DEFERRED (Val's call)** because the parallel `testing-arc` session is
  concurrently rewriting `eval.mdk`/`core_ir_eval.mdk`, which would invalidate a re-mint immediately.
  **Do ONE re-mint after BOTH settle** (`sh test/refresh_seed.sh`, then verify `bash test/bootstrap_from_seed.sh` C3a PASS).
- **⚠️ TWO ORCHESTRATOR FOOTGUNS BIT ME AT ONCE while verifying `#35` — I nearly rejected a CORRECT fix.**
  (1) A `cd /root/medaka && …` chain meant my "sync the worktree" step ran in the **primary checkout**, so I
  rebuilt+tested against **pre-merge source**. Use `git -C <abs-worktree>` for every step. (2) `medaka build`
  shells out to `./medaka_emitter`, and `make medaka`'s `find -newer` short-circuit can leave that binary NOT
  carrying a compiler-graph change → **`FORCE_EMITTER_REBUILD=1 make medaka`** when verifying emitter work.
  **Before blaming an agent for a red repro, confirm the fix is even IN the source you compiled** (`grep` for
  its new symbol).

### ⭐⭐ THE BIGGEST FINDING — "the tree is green" was measuring ~60% of the tree
**`test/run_gates.sh` globs ONLY `test/diff_compiler_*.sh`** (`pat="${1:-diff_compiler_*}"`). A read-only audit
found **~53 real correctness gates OUTSIDE that glob — 10 of them RED**, some for days, unnoticed. This drift has
now happened TWICE (fixed once by `121ee5147` on 2026-07-07, back 6 days later after the Index arc).
- **Cleaned up this session (10 red → 3):** `diff_native_cli` 48/107 → **107/0**; `bootstrap_{desugar,mark,typecheck}` → green;
  `build_cmd` → green; two sqlite oracle scripts that `mv`'d a file **onto itself** and died before running a single
  test → fixed, both pass.
- **STILL RED (all filed):** the 4 wasm Index-arc fixtures (`w7_array_*`, real backend gap), `disp_hof_shadows_method`
  (**a real typecheck REGRESSION**, task #39), and `build_construct_coverage`'s stale `let_else` fixture.
- **➡️ HIGHEST-LEVERAGE STRUCTURAL TASK: widen `run_gates`** (task in the list) so this stops recurring. The auditor's
  recommendation (endorsed): don't rename these into `diff_compiler_*` — add a second explicit manifest. Two footguns
  for whoever does it: the sqlite scripts need **`bash`** (not `sh`) and `MEDAKA_ROOT` exported from the repo root.

### ✅ SHIPPED (all merged, gated, fixpoint YES)
- **`#35` — ⚠️ SILENT MISCOMPILE, under-applied data constructor — ✅ LLVM FIXED / ❌ WASM STILL BROKEN (REOPENED)** (`d1bbfdcb`).
  `mkAdd = Bin OAdd` (arity 3, 1 arg), saturated later → `run` correct, `build` produced a **malformed cell**
  (`E-NONEXHAUSTIVE-MATCH`). Root: `emitApp`'s ctor arm called `emitCtorAlloc` with **no saturation check**, allocating a cell
  from however many args were present. The comment at `llvm_emit.mdk:5320` *asserted* the invariant ("emitApp only builds the
  cell when the ctor is SATURATED") and it was never enforced. Fixed via `emitCtorApp` (saturated → unchanged/byte-identical;
  under → ctor PAP; over → `mdk_apply`). **LLVM half is verified good** (trigger matrix run==build, llvm 196/0, fixpoint YES).
  **⚠️ THE WASM HALF DOES NOT WORK — see task `#35-wasm`.** `diff_wasm` is **147/5** on main and `ctor_pap_arity` fails
  `wasm-tools validate` (`type mismatch: expected (ref eq), found i32`) — the exact pre-fix symptom. `emitCtorApp` IS present in
  `wasm_emit.mdk`, so it's not a lost merge: either the agent measured a stale wasm oracle, or its assumption that "`emitAppTail`
  routes back through `emitAppRef` so it's covered for free" is wrong. **Independently caught by the `sqlite-arc` session**
  (`a26a1bef`), not by me.
  **⭐ HOW I MISSED IT — the session's own lesson, self-inflicted: the wasm gates are OUTSIDE the `run_gates` glob**, so my
  "78/0/1 green" never covered them and I merged on the agent's self-reported wasm numbers. **Re-run wasm gates yourself, with a
  freshly-rebuilt wasm oracle** (it timed out once under CPU contention this session — a stale-oracle hazard).
- **`#18a` — `++` → `Semigroup`** (`5fff0680`). Closed a **build-path SIGSEGV** (the native `++` primitive was
  memory-unsafe on a non-List/String operand). `++` on a no-`Semigroup` type now rejects at check. `typecheck.mdk`-only:
  the dict-pass layer rewrites a stamped `EBinOp` → `EMethodAt` **upstream of Core IR**, so eval/LLVM/wasm needed nothing.
- **`#18c` — unary `-` → `Num.negate`** (`49d8d1d7`). `EUnOp` had **no `Ref Route` field at all**; added one and threaded
  it through 16 files. `-v` on a user `impl Num` now dispatches to their `negate`; `-s` on a String rejects.
- **`#24` — tree-wide removed-construct gate** (`d710a226`): `test/check_removed_constructs.sh`. Verified it catches all 7
  removed constructs and has **0 false positives across 1659 files**. NOT yet enrolled as a ratchet (2 findings open).
- **Test-corpus cleanup** (`431d4072`): ~66 stale goldens recaptured. Verified by tallying EVERY changed line — 57×`+index`,
  57×`+setIndex`, 1 orphaned `btick`. Nothing blessed.

### 🐛 THE BUG QUEUE — reproduce-verified, root-caused, ranked by severity
All have minimal repros in their task descriptions. **The two silent miscompiles are the reason I recommended bugs-before-features.**
1. **`#38` ⚠️ SILENT MISCOMPILE — record update writes the WRONG record's slot.** Two record types sharing a field name at
   different slot indices + a `{ r | f = v }` site on each → `build` writes the wrong slot AND tags the cell as the wrong type.
   `run` correct. Root: `emitRecordUpdate` (`llvm_emit.mdk:~7996`) finds the record **by searching for the first type having a
   field of that name** (`findRecordByLabel`) — bare-name first-wins, the P0-9 hazard again. **The fix is signposted:**
   `fieldIdxByName(table, recName, label)` sits directly above and resolves correctly *given a record name*, and the sibling
   `emitVariantUpdate` takes its ctor name explicitly. `CRecordUpdate` just doesn't carry the receiver type. Check wasm too.
2. **`#40` ⚠️ multi-module `run` does not gate on CONSTRAINT/missing-impl errors — it EXECUTES the ill-typed program.**
   Exact repro filed by another session at `sqlite/findings/repro_multimodule_run_typecheck_gap/` (`0ba2a1f7`, `sqlite-arc`).
   **Three traps that hid it (I initially declared it NOT-REPRODUCIBLE and was WRONG):** must be multi-module (single-file
   gates correctly); must be a **constraint/missing-impl** error (a plain `Type mismatch` IS gated); and **the exit code is 1
   either way** — `run` still exits nonzero, just for the wrong reason (unrelated runtime panic). Any "does run reject this?"
   probe answers yes. Assert on the DIAGNOSTIC and on whether the program EXECUTED.
3. **`#42` ⚠️ THE FLOAT-FIDELITY ARC — three filed bugs that are ONE problem, and it is ACTIVELY DESTROYING SOURCE.**
   (a) `floatToString` truncates to ~12 sig digits — `0.1 + 0.2` prints `0.3`, not `0.30000000000000004`. It prints a value that
   **is not the float you have**; print-then-reparse gives a *different* Float. (b) The **lexer REJECTS scientific-notation float
   literals** (`1e308` → `Unbound variable: e308`) — long-standing. (c) ⚠️ **Therefore `medaka fmt --write` DESTROYS SOURCE**
   (B10, verified by `sqlite-arc`, `sqlite/findings/COMPILER-BUGS.md`): `big = 9000000000000000.0` → fmt writes `big = 9e+15`
   via `floatToString` → **the lexer can't read it back and the file no longer compiles.**
   **⚠️⚠️ THIS IS LIVE IN OUR OWN WORKFLOW** — the pre-commit hook runs `medaka fmt`, and every agent prompt instructs
   `medaka fmt --write` before committing. Any `.mdk` with a float ≥ 1e15 is silently destroyed.
   **They are one arc:** the correct fix for (a) is shortest-round-trip (Ryu/Grisu), and the shortest round-trip of a large float
   *is* scientific notation — so fixing (a) makes (c) WORSE unless (b) is fixed too. The printer must emit only what the lexer can
   read. **One property test pins all three: for any Float `f`, `parse(floatToString f) == f` and `lex(print f)` succeeds.**
   Blast radius: `stdlib/json.mdk` serializes Floats through this (data-corruption path); sqlite Float columns; any Float golden.
4. **`#39` REGRESSION — `check` wrongly REJECTS a valid program** where a fn PARAMETER shadows a same-named top-level fn
   (`applyEq eq x y = eq x y`). My hypothesis (BISECT, don't trust it): the **P0-19 shadow work over-firing on a local binder**,
   NOT the Index arc as the audit guessed. ⚠️ Do NOT fix by weakening P0-19 — it closed two silent-build-garbage holes.
5. **`#31` `newtype` is ENTIRELY UNUSABLE** — `newtype F = F Int; F 5` → `Unbound variable: F` on check/run/build. It's
   DOCUMENTED in SYNTAX.md, and the trim removed named impls on the rationale that "newtype-wrappers are the accepted answer".
   **One missing arm:** `registerData` (`typecheck.mdk:5587`) handles `DData`/`DTypeAlias` and drops `DNewtype` on its catch-all.
   Everything else in the pipeline already handles `DNewtype`. **Blast radius ~ZERO** (0 uses in `compiler/`+`stdlib/`). Closes 9
   trimmed test cases + un-skips the parked `newtype_ctor_fn` fixture. **Best value-to-risk item on the board.**
6. **`#45`** the REAL bug under `#18a`'s regression: **arg-dispatch indices are not re-offset when impl-`requires` dict params
   are prepended** (Phase 83/84). Consequence: `++`/`-` on an impl's abstract `requires` tyvar stay on the structural builtin
   (so a user-Monoid `foldMap` still panics — a residual, NOT a regression). Also contains a SECOND latent bug **proven on
   pristine main**: `binop_parametric_eq` passes only because it's a single-method impl.
7. Cheaper bites: **`#41`** `run` discards buffered stdout on panic (build flushes) — vicious debugging footgun;
   **`#44`** doctest extractor eats a Markdown blockquote (the marker IS `>`) → unlocated panic kills EVERY doctest in the file
   (silently disabled all of `rowtype.mdk`'s for months); **`#37`** derived `Debug` doesn't parenthesize nested ctor args
   (`B L 1 B L 2 L 3`) so it can't be a tree oracle; **`#36`** parse error in an IMPORTED module reports unlocated;
   **`#46`** ⚠️ **`capture_goldens.sh` (full run) silently BLANKS a golden** — the tool we use to establish ground truth
   destroys it; **`#32`** `EVariantUpdate` missing from eval's dispatcher (one arm; helpers already exist).

### 🔀 MERGE TRIAGE — other live sessions (check before you branch)
- **`testing-arc` OWNS task `#43`** (`exit` unbound under `run`) — and found the whole class: a **37-extern interpreter gap**,
  plus a capability-coverage gate to prevent recurrence. **Do not spawn that.** It is rewriting `eval.mdk`/`core_ir_eval.mdk`
  structurally (`data Value e`, "medaka run can do IO"). ⚠️ **`#18c` touched `eval.mdk`** (a mechanical `EUnOp` passthrough arm)
  — expect a merge conflict there; it is small and mechanical.
- **`sqlite-arc` is compiler-clean** (confined to `sqlite/` + `test/` + docs; its apparent `typecheck.mdk` diff is a
  branch-base artifact). It merges clean. It is also the source of several bugs above — it's dogfooding, and it's working.

### PROCESS LEARNINGS (new)
- **A failed reproduction is NOT evidence of absence until you've checked your probe COULD have seen the bug.** I publicly told
  Val his `#40` report was stale. It wasn't — my probe was blind to it (wrong error class + exit-code-based assertion). New
  memory: `feedback_probe_the_diagnostic_not_the_exit_code`.
- **The orchestrator must run the FULL suite before merging, not just the fast/decisive gates.** I merged `#18a` after the
  fixpoint + behavioral probes were green, and the full suite then caught a real regression → had to revert main. Green-then-merge,
  never merge-then-green.
- **Cross-workstream collisions are invisible to agents.** `#18a` made `1 ++ 2` a (correct) check error, which broke a *layout*
  fixture that used `++`-on-Int incidentally — and that fixture is only typechecked by a gate OUTSIDE the `run_gates` glob. Neither
  the agent nor `run_gates` could have caught it. The orchestrator is the only one who can see across.

## MERGE — 🔀 local Index-arc main ⨝ origin (Netcup move + #35 close). (2026-07-13, last macOS session's final act)

Synced the macOS work laptop's local `main` (the Index arc #16, below) with `origin/main` (the Netcup-box work: the machine move + #35 close, next section). **Disjoint changes** — the sole textual conflict was this file (two RESUME logs). Post-merge reconciliation:
- **#35 (`ctor_collision`) is CLOSED by the remote** (`837d737b`, the P0-9 port into `compiler/ir/core_ir_eval.mdk`'s per-module frames). So the merged tree is **`run_gates` 78/0/1 — fully green**; my Index entry's "the 1 fail is #35" is superseded, and the remote correctly notes it was **never an x86 bug** (red on Mac too) and the fix file was `core_ir_eval.mdk`, NOT `core_ir_lower.mdk` (the memory `project_ctor_collision_x86_divergence` is thus resolved — plain #35).
- **Seed RE-MINTED post-merge** — the remote changed a compiled compiler file (`core_ir_eval.mdk`), so my Index-arc seed was stale against the merged source. Re-minted from merged source; cold `bootstrap_from_seed` C3a + `selfcompile_fixpoint` C3b re-verified, full `run_gates` re-verified, before pushing.
- **Dev now lives on the Netcup Linux box** (next section) — the Index arc's Mac-centric notes (Docker, `medaka_emitter` borrow paths, Apple-clang perf) belong to the retired environment.

## RESUME — ✅ INDEX ARC #16 SHIPPED: typeclass indexing `a[i]` / `a[i][j]` / `a[i] := v` + coded `E-INDEX-OOB`. Seed RE-MINTED (cold C3a + fixpoint C3b PASS). Tree GREEN. (2026-07-12)

The user gated "go straight to the Index arc"; **#16 (Index+IndexMut CORE) is done end-to-end**. Design was decision-ready (`INDEX-DESIGN.md` + a new `INDEX-16-PLAN.md` that resolved the one open seam). Shipped as 7 isolated-worktree sub-stages, each gated+merged; owning memory **`project_index_arc_16_shipped`** has full detail.

### ⭐ DO-FIRST STATE
- At the time this arc landed on the macOS laptop, `run_gates` was **77 pass / 1 fail / 1 skip**, the 1 fail being the pre-existing **#35** `ctor_collision` — **now CLOSED by the merge with origin** (see the MERGE note above; the remote's `core_ir_eval.mdk` port fixes it, so the merged tree is 78/0/1).
- **Seed re-minted** (`2379ff24`) — adding the `indexError` extern forced it (pre-arc seed can't emit the new stdlib). Cold `bootstrap_from_seed` C3a + `selfcompile_fixpoint` C3b both PASS.

### WHAT SHIPPED (#16a–#16e + 16b-2 + 16d, all merged)
- `Index c k v` / `IndexMut c k v requires Index` interfaces in `stdlib/core.mdk`; impls Array/List/String (prelude → **no import needed**) + Map/MutArray (their modules). `index`/`setIndex` methods; `a.[i]`→`index a i` desugar (F2a **retires the built-in `EIndex` path**); `a[i] := v`→`setIndex` (two-pass desugar for the post-order hazard); bare **`a[i]`** grammar (F1 `TLBracketTight` lex + `postfixTail`); printer renders bare `a[i]`. Write is in-place `<Mut>` for Array/MutArray only. OOB → coded `E-INDEX-OOB` via a new `indexError : String -> a` abort extern (reuses `@mdk_oob`/`wasmTrap`).
- **Two latent bugs the full differential suite caught** (stage agents only run full-pipeline probes; the ORCHESTRATOR runs the suite): **#16d** prelude-free probe regressions (`eval_main` is `~prelude:false`; F2a makes `.[i]` need the prelude `index` → fixture migration to `arrayGetUnsafe`/prelude-bearing harness); **#16e** a return-position-dispatch value-rep SEGFAULT on build (a return-only-param method returning an array-slot `Char` was mis-typed as the head type → `mdk_string_eq` deref → SIGSEGV; fixed in `core_ir_lower.mdk` by restricting `ifaceReturnsSelfEntry` to the HEAD param). Both were general (minimal repros used a plain user interface), pre-existing-latent, exposed by the arc.

### ⭐ NEXT (still open in the Index arc — user-gated):
- **#17 slicing `a[i..j]`** — bare-slice grammar (currently DEFERRED: the tight-bracket branch rejects `..` with a clean error; `a.[i..j]` dot-form still works). Native/wasm slice is NOT bounds-checked (`E-SLICE-OOB` interpreter-only) — closing that is a rider.
- **#18 operator-interface generalizations** — `++`→`Semigroup` (GOLD), ranges→minimal `Enum`, unary `-`→`Num.negate`. SKIP overloaded literals. Independent of Index (single-param classes) but shares front-end files → serial. May sweep up a #30 eval-gap (user `++`).

### PROCESS LEARNINGS (new this arc)
- **The full differential suite is the ONLY thing that catches probe-context + codegen regressions** a self-hosting feature introduces — green fixpoint + agent full-pipeline probes are NOT enough (both #16d and #16e passed those). Always run the whole `run_gates` (and eyeball the OUTPUT-comparing gates eval/llvm/build separately from dump gates) before merging a feature that changes desugar/emit.
- **A missing `import` mimics a dispatch bug** — I mis-aimed an Opus agent at the typechecker for what were missing-`import` errors; it correctly disproved the hypothesis. See `project_stdlib_impl_needs_import_to_dispatch`.
- **Golden recapture after a front-end/emit change spans ~8 families with distinct capture paths** (`--frozen desugar/mark/fmt/printer`; lex/tc/core_ir_sexp regenerate by mirroring each gate's RUN+strip_unit pipe; `diff_fixtures` TYPES need a surgical splice). Only indexing fixtures actually shift, so the changed-file count stays small — a good benign-ness signal. The recapture-agent choked on `build_oracles` respawn (TaskStop+reap+DIY).
## RESUME — 🖥️ NEW HOME: dev moved to a dedicated x86_64 Linux box. Docs + memories swept. (2026-07-13)

**The machine changed.** Primary dev is no longer the macOS work laptop — it is a **dedicated
Netcup x86_64 Linux box** (Debian 13, 12-core EPYC / 32 GB), repo at **`/root/medaka`**.
Everything about the old environment that shaped our workflow is gone with it:

- **Build and gate NATIVELY.** `make medaka`, `sh test/run_gates.sh`. **Do NOT route anything
  through `scripts/docker-dev.sh`** — Docker isn't installed, and the DLP scanner it existed to
  escape (Cyberhaven, a macOS-work-laptop problem) doesn't exist here. `docker/README.md` now
  carries a SUPERSEDED banner. Any prior instruction to "bake Docker routing into every agent
  prompt" is RETIRED.
- **The Mac is retained for macOS smoke-testing only** → the **dual-platform invariant still
  holds**: every build/test script must run on BOTH Linux and macOS (`stat -c %Y` *or*
  `stat -f %m`; system `-lgc` *or* `brew --prefix bdw-gc`; no Mach-O-only link flags). Linux is
  now the default arm.
- **⚠️ Every perf number on record predates the move** (Apple M5 / macOS / Apple clang) and is
  NOT comparable to anything measured today — different ISA, clang, libc, GC build.
  `PERF-RESULTS.md` + `PERF-RUNTIME.md` carry stale-machine banners. **Re-baseline
  (`sh test/bench.sh`) before calling anything a regression or a win.**
- **GitHub access is clean:** the box has its own **deploy key** (read+write) and a personal git
  identity — the work account is not involved. (`ssh -T git@github.com` answers `Hi
  val-grasley/medaka!` — naming the *repo* is how a deploy key identifies itself.)
- ✅ **`ops/` provisioning is ON `main`** (merge `12a69487`, pushed): `ops/provision.sh`
  (self-contained box provisioning: deps + node24 + clone + cold-bootstrap + hook + oracles +
  gates), `ops/snipe_hetzner.py` + `ops/cloud-init.yaml` (Hetzner restock fallback),
  `ops/README.md`, plus the `build_oracles.sh` `stat -c`-first Linux portability fix (`ac503dff`).

Docs updated for the move: `AGENTS.md` ("Where you're running" + Environment gotcha),
`README.md` (per-platform prereqs), `docker/README.md`, `compiler/PERF-{RESULTS,RUNTIME,SCOPE}.md`,
`.claude/ORCHESTRATING.md` (primary-checkout path). Memories: `project_netcup_build_box` (now
LIVE), `project_cyberhaven_docker_workflow` (SUPERSEDED), `feedback_serialize_heavy_builds`.

### ⚡ THE `JOBS=4` CAP IS RETIRED — use the script defaults (MEASURED 2026-07-13)

Older RESUME entries below (and old agent prompts) say to bake `FORCE=1 JOBS=4 bash
test/build_oracles.sh` / `INNER_JOBS=2` into everything, "because JOBS is a memory ceiling."
**Both halves of that are now disproven on this box. Do not cap JOBS. Just run
`FORCE=1 bash test/build_oracles.sh` and `sh test/run_gates.sh`.**

Swept on the 12-core / 31 GB box (every gate config re-verified 78/0/1, so nothing won by racing):

| `build_oracles` JOBS | 4 (old cap) | 6 | 8 | 10 | **12 (default)** | 16 | 24 |
|---|---|---|---|---|---|---|---|
| wall | **427s** | 332s | 294s | 288s | **277s** | 275s | 299s ↑ |
| peak mem | 3.3 GB | 4.1 | 5.0 | 5.6 | 6.4 | 8.1 | 10.9 |

`run_gates`: 4×2 → 66s · **7×3 (default) → 54s** · 12×2 → 49s. Peak mem ~2 GB flat.

- **Memory NEVER binds** — 10.9 of 31 GB even at JOBS=24. The 2026-07-08 OOM was a 10-core Mac
  *with a DLP scanner hooking every file op*, not a property of the workload.
- **The cap cost +54% wall-clock** (427s vs 277s) on a command we run constantly.
- **What survives:** JOBS=24 is *slower* than 12 (thrash) — same effect that made concurrent
  agent builds pathological. So **one build-heavy op at a time, GLOBALLY** still holds, and it's
  exactly what makes the uncapped default safe. Don't stack heavy ops; don't hobble the one running.

### ✅ TASK #35 CLOSED — the tree is now FULLY GREEN (`run_gates` **78 / 0 / 1**, was 77/1/1)

The last red gate (`diff_compiler_core_ir_modules` → `ctor_collision`) is fixed. Two corrections
worth carrying:

- **It was never an x86 arch bug.** I briefly mis-filed it as one because it surfaced on the first
  non-Mac bootstrap. It was red on the Mac too — exactly the pre-existing task #35. The mechanism
  is plain first-declaration-order lookup in a bare-name cell table: no hash iteration, no
  `readdir`, no uninitialized read — nothing that *could* differ across ISAs. **Lesson: a red gate
  on a new machine is usually not the machine's fault. Read this DO-FIRST block before diagnosing.**
- **The old entry below named the wrong file.** The un-ported P0-9 fix was NOT in
  `compiler/ir/core_ir_lower.mdk` — lowering was fine. The per-module frames are built in
  **`compiler/ir/core_ir_eval.mdk`** (`cBuildModInfos` / `cInstallModGroups`).

**Root cause:** `cevalModules` installed *every* module's ctors into one flat global frame keyed by
**bare name**; `installConsts`+`findCell` is last-write-wins, so `boxmod`'s arity-5 `Bin` and
`bagmod`'s arity-4 `Bin` collapsed into one cell and a module constructed via the *other* module's
arity → saturate early → apply the surplus arg → `E-NOT-A-FUNCTION`. **Fix:** port P0-9's
per-module **local** ctor frame (which shadows the global; the global stays for `Type(..)`
cross-module ctor imports). Verified order-independent — flipping import order previously produced
a *different* error (`no matching impl`), same collision, and now both orders are correct.

Gated: `core_ir_modules` 5/0 · `run_gates` **78/0/1** (FORCE-rebuilt oracles) · fixpoint **C3a YES /
C3b YES** (committed seed still bootstraps — **no re-mint owed**) · compiler source type-clean ·
fmt + lint clean. Two new AGENTS.md gotchas landed from it (the `evalModules`/`cevalModules`
lockstep rule, and the shared-fixture-corpus trap that let P0-9 ship "green").

## RESUME — ✅ PRE-INDEX RUNWAY: trim finish, dispatch cleanup, testing-DX, a compiler-wide type-safety gate, and a ~53× parse speedup. `main` = `b5fd5e84`. Seed RE-MINTED (cold C3a PASS). Tree GREEN (run_gates 77/1/1). (2026-07-11)

A very long, high-throughput session. Everything design→delegate→isolated-worktree→VERIFY→merge; fixpoint C3a/C3b YES on every landing; **seed re-minted at the end (`b5fd5e84`, cold `bootstrap_from_seed` C3a PASS)** batching ~15 emitter-graph changes. User PAUSED before the Index arc — it needs an explicit go-ahead.

### ⭐ DO-FIRST STATE
- **`main` = `b5fd5e84`.** Tree green: `FORCE=1 build_oracles` then `run_gates` → **77 pass / 1 fail / 1 skip**. The 1 fail is a **pre-existing** bug (task #35, NOT this session): `diff_compiler_core_ir_modules`'s `ctor_collision` — the P0-9 cross-module ctor-collision fix (`2b17677f`) patched `eval.mdk` but was never ported to `compiler/ir/core_ir_lower.mdk`'s per-module frames. Contained (Core-IR module-eval only; `run`/`llvm`/`build` fine).
- **NEW required gate: `bash test/typecheck_compiler_source.sh`** (wired in AGENTS.md). Strict-typechecks the WHOLE compiler source via the `diagnostics_project_main` oracle — the bootstrap emit path does NOT gate on `hadTypeErrors()`, so ill-typed compiler source builds + fixpoints green without this. It found 3 real latent bugs this session. **Run it (alongside fixpoint) for any compiler `.mdk` change.** Now ~1 min (was ~4 min pre parse-fix).
- **`CLI_OPT` now defaults to `-O2`** (`test/build_native_medaka.sh`): `check`/`run`/`test` ~2× faster, `make medaka` +~4s. Opt out with `CLI_OPT=-O0`.
- **⚠️ THE #1 PROCESS LESSON (recurred on ~5 agents): a multi-minute gate is INCOMPATIBLE with the agent loop.** Agents background the slow gate and empty-report / respawn (or lazily silence the error). **RULE: the ORCHESTRATOR runs any multi-minute gate; AGENTS verify with the FAST per-file `medaka check --allow-internal <file>` (seconds) and are told NOT to run the slow gate.** (The ~4min typecheck gate caused this; it's ~1min now after the parse-perf fix, but keep the rule for future slow gates.)

### ⭐ NEXT UP (USER-GATED): the INDEX ARC — needs the user's explicit "go"
Design done + persisted: **`INDEX-DESIGN.md`** on main. **BLOCKER F0 already FIXED** (#19: return-only-param method dispatch). **REFRAME:** most of indexing already exists — `EIndex`/`ESlice` AST nodes, `a.[i]` dot-bracket surface, `E-INDEX-OOB` in all 3 backends. The work is (a) TYPECLASS-ify (open `Index c k v`, make `Map` indexable) vs today's closed monomorphic union, and (b) NEW bare `a[i]` postfix grammar (bare `a[i]` currently parses as application). Three sequential phases (share front-end files → strictly serial; each independently gated+merged):
- **#16 Index+IndexMut CORE** — first, after #24. **LOCKED forks (Val):** F1 lex-time tight-bracket (`a[i]` vs `a [i]`); F2 desugar `a[i]`→`index a i`, `a[i]:=v`→`setIndex a i v` (discriminate LHS before the generic `:=`→`setRef`); F3 `IndexMut` in-place `<Mut>`, **Array/MutArray ONLY** (Map writes stay functional via `Map.insert`, not `[]:=`); F4 include `List` index (O(n)) but DOCUMENT; F5 String/List **read-only**; F6 no multi-key `a[i,j]` (chain `a[i][j]`); F7 write class `IndexMut requires Index`; F8 slicing = Phase 2; F9 `IndexMut` carries `<Mut>`. Interfaces: `Index c k v { index : c -> k -> v }`, `IndexMut c k v requires Index c k v { setIndex : c -> k -> v -> <Mut> c }`. Impls: Array/Map(`requires Ord k`, returns `v` not Option, OOB=key-not-found)/List/String.
- **#17 slicing `a[i..j]`** — Phase 2, after #16.
- **#18 operator-interface generalizations** — Phase 3: `++`→`Semigroup` (GOLD, interface exists but bypassed), ranges→minimal `Enum`, unary `-`→`Num.negate`. SKIP overloaded literals. Independent of Index (single-param classes) but shares front-end files → serial. NOTE: the `++`→Semigroup work may sweep up one of the #30 eval-gaps (user `++` dispatch).

### ✅ SHIPPED this session (all merged, fixpoint YES)
- **Language trim 5/5:** `record`/`function`/backtick/`let-else` removed + **named-impl + `@Name` + `default impl` removed** (A+B, census-backed — the multi-instance feature was ≈0 real use; newtype-wrappers are the accepted answer). Kept the most-specific-wins/overlap engine (needed for plain impls).
- **F0** return-only-param dispatch fix (`74c5902f`).
- **`medaka test` RESTORED** (`1b76088e`): `test "…" = …` DTest execution was silently dead since the OCaml removal; new `test_runner.mdk` + a **DTest typecheck arm** + `runExpectation` dropped (assertions are `Expectation` VALUES, panics abort). 202 ported assertions live again.
- **Compiler-source typecheck gate** (`test/typecheck_compiler_source.sh`) — found + fixed 3 real latent bugs (lsp `ConPayload` import, `check_policy` runPlugin arity, `classify (TIndent _)` nullary-ctor-over-application).
- **Diagnostic-location family (pain-point #3) closed:** mislocated pattern-arity error (`currentLoc` stale in pattern inference — `ed1ab0b3`); unlocated multi-module imported errors now surface located (`1c33afa1`); unlocated record-field-in-destructuring-pattern errors (`adda79e4`).
- **PERF:** `CLI_OPT=-O2` default + **O(N²)→O(N log N) parse fix** (`offsetToLineCol` re-scanned whole source per AST node; now binary-search over precomputed line-starts) → `check typecheck.mdk` **~47s→0.9s (~53×)**, byte-identical locations (`9ee30064`).
- Pre-flight bugs: P0-7 wasm TCO, P0-8 playground host imports, `--version`, `fmt <dir>`, playground-build E-NONEXHAUSTIVE fix, FINDINGS reconcile, capture_goldens `--frozen` mode.

### REMAINING TODOS (open — the session task list, captured here for durability)
1. **#24 removed-construct tree-wide lint** — the LAST tooling item, do BEFORE Index (user: "keep all 5 tooling ahead of Index"). A lint/CI rule flagging removed constructs across the whole tree incl. non-gated `test/` (would've caught the stale `let_else_fail` fixture this session cleaned).
2. **#16 → #17 → #18 the Index arc** (above; user-gated).
3. **#29 `expectPanic` + internal catchable-panic primitive** (FOLLOW-ON, after Index; blocked on #28 done). LOCKED design: an INTERNAL-ONLY catch extern (on the internal-extern restriction list, `stdlib/test.mdk`-only, forbidden to user code — preserves no-user-facing-try/catch). Approach **(a)**: catch ONLY in `expectPanic`; an UNEXPECTED test panic still aborts. Build the primitive general enough that upgrading to **(b)** per-test isolation is additive. `add-primitive` w/ backend: `eval.mdk` + `medaka_rt.c` (setjmp/longjmp) + `llvm_emit`.
4. **#30 triage 12 native-eval gaps** — the `medaka test` restoration trimmed 12 ported cases that abort under `medaka run`: `EVariantUpdate`, user Semigroup/Monoid `++` dispatch, poly-monad dispatch on Option/Result, newtype constructors. Reproduce + triage (the `++` one may be fixed by #18).
5. **#35 port P0-9 ctor-collision fix to `core_ir_lower.mdk`** (the 1 red gate; pre-existing).
6. **P1-1 Int-literal-overflow diagnostic** (deferred; Int silently wraps at 63 bits — a check-time diagnostic; frontend, separable).
- Also the broader **P1/P2/P3 punchlist** (reconciled + stamped in `qa-beta-2026-07-07/FINDINGS.md` on 2026-07-11) — mostly Sonnet-mechanical polish + a few deeper (P1-4 perf, P2-1/P2-2 validation gaps).

### PROCESS LEARNINGS (new this session)
- **Slow-gate rule** (above, the #1 lesson).
- **Stale goldens after front-end changes:** a session of trim/AST changes leaves stage-output goldens (desugar/mark/lex/core_ir/sexp) stale — `run_gates` looks red even with FRESH oracles. At a checkpoint, `FORCE=1 build_oracles` + `run_gates`, then recapture — but **confirm each diff matches a known change before recapturing** (a real regression hiding among stale goldens is the risk; the fixpoint doesn't cover these dump gates). Use `capture_goldens.sh --frozen <tag>` for frozen families.
- **Perf attribution:** a "slow typecheck" was actually slow PARSING (location machinery). Verify hotspots by WALL-CLOCK scaling + a stub experiment, not profiler samples (per `PERF-RESULTS.md`).
- **The typecheck gate + `--json` divergence pattern:** human-text error paths kept discarding the accumulated `(code,msg,loc)` list that `--json` renders — recurred in both the multi-module deflection and the field-error cases. When a check error is unlocated in text but located in `--json`, the fix is routing the existing list to the text output, not new machinery.

## RESUME — ✅ BIG soundness + language-trim session (2026-07-10→11). `main` = `2dcf888d`. Seed RE-MINTED (cold bootstrap green).

A long, high-throughput session: soundness cluster → OOB security fix → language streamlining. Every landing design→delegate→isolated-worktree→verify→merge; ALL fixpoint C3a/C3b YES; **seed re-minted at the end (`2dcf888d`, cold `bootstrap_from_seed` C3a PASS)** — locks in all wins + greens cold bootstrap (was deferred-stale). Owning memories `project_beta_qa_sweep_2026_07_07`, `project_oob_memory_safety_audit`, `project_shadow_semantics_spec`. PLAN.md top entries have per-item detail.

**SHIPPED (all merged, fixpoint YES):**
- **P0-19** shadow-conformance — all 4 SHADOW-SEMANTICS BUG cells (`ef0874f3` rows 12/13 silent soundness holes; `ebb8ee90` rows 10/14 value-position + cross-module dispatch).
- **`bytesToFloat64` userland OOB heap read (P0 security, `39a755a2`)** — found by a dedicated audit; gate + bounds-check. **Audit verdict: the rest of the indexed surface is AIRTIGHT.** `internalExterns` is a hand-maintained denylist — invert to allowlist someday. See `project_oob_memory_safety_audit`.
- **run≠build parity cluster:** P0-2(c) refutable-let SIGSEGV→`E-LET-REFUTE` trap (`ed8be866`); P0-10 hash-under-run (`16a53cdd`); P0-9 map+set ctor collision (`2b17677f`); P0-2(a)+(b) silent stack-overflow/cyclic-value → clean coded errors + native sigaltstack backstop (`b32fff20`).
- **P0-3 deriving-on-records Part 1** (`6636e356`): `data X = X{…}` deriving works both pipelines.
- **⭐ Language streamlining (user-directed, "keep it clean = actually delete the machinery"):** consolidated records onto `data` — **`data X = { … }` name-omission sugar** (`f441a796`) + **removed the `record` keyword & DELETED `DRecord`** end-to-end (`442cb766`, −291 LOC) which **DISSOLVED P0-20 + P0-3's record residual by deletion**. Removed the **`function` keyword** (`acd1f5b8`) and **backtick infix** (`f6dabd5a`).

**⭐ DO-FIRST context for next session:**
- **The "native DCE/codegen miscompile" (from the backtick bite) is a NON-BUG** — an Opus agent proved emitted IR byte-identical live-vs-dead; root cause was the PRELUDE (`core.mdk`) using the removed construct → binary fails to load prelude on EVERY program. **LESSON: a construct-removal census MUST scan `stdlib/core.mdk` (always-loaded) for real uses.**
- **Trim batch PAUSED at 3/5** (user). Remaining, both entangled (PLAN.md trim STATUS block has the map): **`let-else`** (shares `emitLetElse`/`letElseHead` with the P0-2c refutable-let SOUNDNESS fix — protect it; touches llvm+wasm emit) and **`let rec … with`** (surgical: drop only the `with` grouping). Plus the **`!`→deref + `!=`→`/=` "negation coherence" bite** (`!x`→`.value`, `!`-on-Bool→`not` hint, `!=`→`/=` swap + 54-site migration — machinery half-built, flip `firstSlashEqIdx`). Roadmap also queues **record field defaults** (the deliberate "no labeled args" answer) + interface generalizations (`++`→Semigroup etc.) + indexing.
- **OPTIONAL zero-re-mint follow-up:** migrate the 8 compiler-internal records (`Env`/`Rule`/`Oracle`/…) from explicit `data X = X{…}` to the short `data X = {…}` — byte-identical IR, the new seed parses it.

**PROCESS notes (recurring this session):**
- **Empty-report + respawning-oracle-pool failure mode hit MULTIPLE agents** (they end with a stray "…in progress" line + re-kick `build_oracles` each wake). Fix: **`TaskStop` the agent FIRST** (stops the respawn), then reap the pool (kill `build_oracles.sh` parents before `medaka build` children), then salvage (commit complete WIP) or discard+re-spawn (if incomplete). Bake into prompts: **NEVER bare `build_oracles`; single oracle via `FORCE=1 JOBS=1 … --build-one <name>`; WAIT-and-report, never end with gates running.**
- **Fresh isolated worktrees lack `./medaka_emitter` + cold-bootstrap-from-seed WAS stale** — agents borrowed `cp .../iridescent-wondering-wozniak/medaka_emitter ./` to warm-build. (The re-mint fixes cold bootstrap now.)
- Verify-before-merge caught an **incomplete salvage** (function removal left `rare_constructs` multi-stage + `andthen_pure_map` goldens stale → red main; cleaned up `9fc3da3a`).

## RESUME — ✅ P0-18 fully closed + P0-5 mutability PIVOT shipped + a pre-beta LANGUAGE-COHERENCE design pass (2026-07-09 evening). `main` = `b708ee06`

A long design-heavy session. Two implementations shipped; a large amount of language design locked + queued. Owning memory **`project_prebeta_language_coherence_2026_07_09`** (full detail); PLAN.md top entries; three read-only audit docs on main. **Everything verified in Docker, fixpoint C3a/C3b YES throughout, ZERO seed re-mints.**

**✅ SHIPPED this session:**
- **P0-18 fully closed** (`953d9ea1` run/check + `0b4a7882`/`01ac360d` build-path Option-3 + `cfc4fa5a` importer-no-impl residual): definer-shadow-vs-method dispatch correct on run AND build, incl. N-way + importer cases. A formal **`SHADOW-SEMANTICS.md`** conformance spec (`c1ea45d8`) then surfaced **P0-19** (below).
- **P0-5 mutability MODEL PIVOT** (`31f4ea80`+`b80ea8c7`): dropped `let mut` entirely; mutability now lives ONLY in `Ref` + `<Mut>`. `=` is declaration-only; mutate via new **`:=`** (`x := v`→`setRef`); **read a Ref via `.value`** (NOT `!` — `!` is boolean-not). Bare reassign → `R-IMMUTABLE-ASSIGN`; `let mut` → clean parser error. All `mut` logic stripped (inert `DoLet`/`ELet` Bool field kept — full removal was ~87 sites/18 files). Verified: agreement 20/0, llvm 195/0 byte-identical, fixpoint YES.

**⭐ DO FIRST tomorrow: P0-19** — the 2 SILENT BUILD-GARBAGE shadow-conformance holes (rows 12 & 13: `useIt x = size x; useIt (Box 3)` and `size "hi"` → check accepts, build prints garbage — same class as the P0-18 hole just closed) + rows 10/14 divergences. **Fully mapped:** `SHADOW-SEMANTICS.md` §5 has per-cell repros + hypotheses, §4 the gate-adoption plan, and the **fixtures already exist** in `test/shadow_fixtures/`. Soundness-first per the sequencing. Opus; reproduce-first; the REJECT-expected cells become `diff_compiler_run_check_agreement` `.expected=REJECT` regressions.

**QUEUED language batches (DECIDED, specified, not built — all in PLAN.md + the memory; strictly sequential, shared front-end files):**
1. **Trim + `!`→deref:** REMOVE `function` kw (→ beginner-hint), backtick infix, `let rec…with` group, `let-else`; REPURPOSE `!` boolean-not → Ref-deref sugar (`!x`→`.value`; `not` = sole negation). Completes OCaml-clean refs. Audit: `LANGUAGE-SURFACE-AUDIT.md`. KEEP-FOR-FUTURE: `>>`/`<<`.
2. **Interface generalizations:** `++`→`Semigroup` (GOLD — interface exists but bypassed), unary `-`→`Num.negate`, ranges→minimal `Enum`. SKIP overloaded literals. Audit: `INTERFACE-CANDIDATES.md`.
3. **Indexing `Index`/`IndexMut`** (PRE-BETA): unified multi-param `Index c k v` (arrays+maps, NO associated types — `FromEntries c e` at core.mdk:888 proves the pattern). `a[i]`→`index a i` (element, `E-INDEX-OOB`), `a[i] := v`→`setIndex`. NEW postfix `[expr]` grammar. Needs a design pass first (verify 3-param multi-param works; List O(n) impl call).
4. Then remaining **P0 bugs:** P0-2 (silent crashes), P0-10 (hash under run), P0-12 (REPL), playground trio P0-7/8/9 (needs node≥24 in `docker/Dockerfile` first — cheap prereq bite).

**OPS / gotchas for next session:**
- **Cyberhaven still spikes to ~3 cores during in-Docker FORCE-oracle rebuilds** (the Docker VM disk image is a host file the scanner re-scans; incremental builds stay ~idle at 1.4 cores). **Workflow change owed: stop baking blanket `FORCE=1 build_oracles` (all 67) into agent prompts** — force only affected oracles, keep the `medaka-work` volume warm. A data-backed IT allowlist request was drafted + delivered to the user.
- **114 stale `agent-*` worktrees** have accumulated (`git worktree list`) — prune the merged ones (preserve any running agent's + this orchestrator's). Leave any the harness won't release.
- **Verification is Docker-only** (`scripts/docker-dev.sh`); the agreement gate + llvm differential do NOT read `test/bin` oracles (fresh `./medaka` / captured text goldens), so most decisive checks skip the FORCE storm.

## RESUME — ✅ Beta-hardening batch 2 (usage-constrained, Sonnet-only small wins): P0-15 + P0-14 fixed, P0-4 retired, P1-9 keyword subset (2026-07-09). `main` = `d0fdf122`

A short, usage-constrained session — small Sonnet-sized bites only, each design→delegate→isolated-worktree→salvage→verify→merge. **All fixpoint C3a/C3b YES, ZERO seed re-mints** (verify against the committed seed before assuming otherwise). Owning memory `project_beta_qa_sweep_2026_07_07` (batch-2 entry has full detail).

**Landed (all merged, gated, fixpoint YES):**
- **P0-15** (`71c737a3`) — an attribute (`@inline`/…) on a **signature-less** def silently unbound it. Desugar keeps the `DAttrib` wrapper on the inner def, but 5 top-level collectors matched `DFunDef` directly with no transparent `DAttrib` arm (resolve `userValueNames`/`preludeValueNames`, typecheck `funDefs`/`dictPassDecl`, eval `funDefs`, core_ir_lower `funClausesOf`) → added the arm to each. Fixture `p0_15_attr_no_sig` in the run≡check gate.
- **P0-14** (`36407355`) — `export import` re-export built to `unbound variable 'double'` (run worked). `private_mangle.mdk`'s export map was locally-defined-names-only; now carries `(name, definer)` pairs built as a dependency-ordered fold that chases the `DUse True` chain to the ORIGINAL owner (mirrors eval's `pubReexports`). Fixture `test/llvm_fixtures_modules/reexport/`.
- **P0-4** (`00edd460`) — verified ALREADY-FIXED on main (positional record patterns run==check==build); filed run-only E-NONEXHAUSTIVE was stale. Closed in FINDINGS, no code.
- **P1-9 subset** (`547df921`) — beginner hints for Python `elif`/`class`/`try`/`except`/`finally` (extended `isForeignKwTok`+`foreignKwMsg`; fire on the `keyword …:` shape). Parser-only. FINDINGS marks the REST of P1-9 explicitly deferred (each needs different/new machinery — value-aliases need the "is Haskell" note generalized; `xs[0]`/`#` are parse-hint shapes; `reverse` needs an import-hint).

**run≡check agreement gate now 13/1** (the 1 is still the deferred `p0_18_standalone_fn_shadows_iface_method` — NOT a regression; see batch-1 RESUME below for its Option-A plan, the top user-directed NEXT item when there's Opus headroom).

**⚠️ TWO process facts for next session:**
1. **Every fix agent this session hit the empty-report + uncapped-oracle-OOM failure mode** (ended "gates running in background", committed nothing, left a respawning `build_oracles`/`xargs` pool). All salvaged cleanly (WIP live+correct in the worktree → `fmt`+`lint`+commit on branch → gate serially at JOBS=4 myself). To reap the pool: kill the parent `bash build_oracles.sh` + `xargs -P` PIDs FIRST (else children respawn), then the `medaka build` children. The root cause: agents capped `make medaka` but ran plain `FORCE=1 bash build_oracles.sh` (defaults JOBS=10). **Bake `FORCE=1 JOBS=4 bash test/build_oracles.sh` into prompts — the cap must be on EACH heavy command, and it's a MEMORY ceiling.**
2. **The user flagged an IT-managed DLP scanner (`Cyberhaven`) that hooks file-I/O during builds and compounds the OOM.** We can't/shouldn't touch it; the JOBS cap is the only lever we control. The one external fix (user's to raise with IT): allowlist the build-output/scratch dirs. Recorded in [[feedback_serialize_heavy_builds]].

**Housekeeping:** the main-checkout `./medaka` (`/Users/val/medaka`) is STALE (pre-batch-2 source) — rebuild with `make medaka` before trusting a gate run FROM the primary checkout. Three agent worktrees from this session (`agent-a2d7d82a…`, `agent-ad927af7…`, `agent-a99af1ab…`) remain harness-locked; leave them for the harness to reclaim.

## RESUME — ✅ Beta-hardening batch 1: 8 P0-class items landed; run≠check theme largely CLOSED (2026-07-08). `main` = `76bda5a1`

Worked the beta-hardening fix queue (`qa-beta-2026-07-07/FINDINGS.md`). Design→delegate→isolated-worktree→verify→merge; **all 8 fixpoint-clean, NO seed re-mint owed** (verify against committed seed before assuming otherwise). Owning memory `project_beta_qa_sweep_2026_07_07`.

**⭐ NEXT UP (user-directed): the ONE deferred item — do it FIRST.** `p0_18_standalone_fn_shadows_iface_method` (a name that's both a standalone fn AND an interface method miscompiles: `size (Box 3)` runs the standalone `n+1` on a Box → run panic / build garbage). Fully diagnosed + planned in **`qa-beta-2026-07-07/P0-18-STANDALONE-DISPATCH-DESIGN.md`** — the user chose **Option A (principled per-receiver fix)**. It's the LAST failing fixture in the run≡check agreement gate (`test/diff_compiler_run_check_agreement.sh` → 12/1; this is the 1). Root cause = typecheck leaks the standalone's param type onto the method occurrence's receiver tyvar → routes `RLocal`. Non-local, careful (blast radius = 5 stdlib definer-shadows + normal dispatch); re-verify eval/llvm/build gates + fixpoint. **The current 1-red in `run_gates` is THIS known-deferred fixture, not a regression.**

**Landed this session (all merged, gated, fixpoint C3a/C3b YES):**
- **P0-6** `medaka test` exits nonzero on any doctest/prop failure (`0c669f2a`).
- **P0-11** parse errors report at the offending token, not the `1:0` decl head — highest-leverage UX, collapses ~a dozen findings; `check` + `--json` (`98d2a89`). New gate `diff_compiler_parse_error_loc`.
- **P0-13** sibling imports resolve from the entry file's own dir (`entrySearchRoots`) across run/check/build/test from any cwd (`81a32a3d`). New gate `diff_compiler_run_entry_subdir`.
- **P0-16** `add(1, 2)` tuple-call beginner hint (human + JSON help/fix), zero false positives (`995a451b`).
- **P0-1 (run≠check core)** `run`/`build` now gate on `check`'s FULL diagnostic predicate (routes by module count like `checkRoute`) and PRINT real diagnostics instead of "run medaka check" — the 4 P0-1 under-accept cases now reject (`96894932`).
- **P0-17** `check` rejects an impl missing a required (non-defaulted) interface method → located `T-INCOMPLETE-IMPL` (`78907363`). Crux: ran post-desugar from the ungated `checkModuleFullImpl` core so defaults are distinguishable; whole tree green (no false positives).
- **P0-18 (map-key)** function-keyed `Map` now rejected `No impl of Ord for (Int -> Int)` — a `checkReqOne` guard-reorder, contained, no re-mint (`76bda5a1`).
- **Docs** SYNTAX.md drift (setRef, Map/Set import, 63-bit Int, @inline example, stale OCaml pointer, dead `bench`) (`aaeea054`).
- **run≡check agreement gate** `test/diff_compiler_run_check_agreement.sh` — the FIXTURES.md §3 differential harness (run/build verdict must == check's). Now **12/13** (only the deferred standalone fixture red).

**⚠️ PROCESS LESSON (new memory `feedback_serialize_heavy_builds`): concurrent isolated-agent builds THRASH the box** (observed load **62 on 10 cores** with 2-3 agents + orchestrator verifies building at once) → starved processes → dropped API connections + the "agent backgrounds gates then drops with nothing committed" failure mode (cost real rework: P0-13 took 3 attempts, a verify raced an agent in the same worktree). **User-approved rule (2026-07-08): STRICT SEQUENTIAL heavy builds + `JOBS=4 INNER_JOBS=2`** — one build-heavy op at a time GLOBALLY (agents spawned one-at-a-time, verify+merge, then next; orchestrator verifies NEVER overlap an agent build); read-only/doc agents still parallelize. Bake the JOBS cap into every agent prompt. Also: I initially forgot `isolation: worktree` and 3 agents collided in the shared worktree (recovered) — ALWAYS pass `isolation: worktree`.

**Remaining P0 queue (13 items, none started; batch under the sequential discipline):** the deferred standalone fix (above, DO FIRST); crash class P0-2 (silent SIGSEGV/SIGBUS — some hard, deep-recursion stack-overflow detection), P0-4 (positional record pattern, likely eval-driver), P0-3 (deriving on records — **design fork**), P0-5 (mutability enforcement — **design fork**); playground trio P0-7/8/9 (front door); quick wins P0-10 (hash_map under run), P0-12 (REPL), P0-14 (`export import` build panic), P0-15 (attributes unbind defs). P0-3 and P0-5 need a Val design decision before spawning.

## RESUME — ⭐ (superseded above) beta-hardening fix queue from the 2026-07-07 QA sweep. Start at `qa-beta-2026-07-07/FINDINGS.md`

An 8-agent adversarial QA sweep (identification-only, no diagnosis) filed the pre-beta triage
queue in-repo: **`qa-beta-2026-07-07/FINDINGS.md`** (18 P0 launch blockers + P1–P3, each with
a minimal repro + expected behavior), **`qa-beta-2026-07-07/FIXTURES.md`** (regression-fixture
plan by harness), **`qa-beta-2026-07-07/reports/`** (8 raw per-area reports with full repro
detail). Owning memory `project_beta_qa_sweep_2026_07_07`; PLAN.md's top status entry has the
recommended attack order. Orchestration guidance for the next session:
- **Read FINDINGS.md "Cross-cutting themes" first.** Theme 1 (`medaka run` executes ill-typed
  programs that check/build reject — P0-1) and Theme 2 (all body-level parse errors report at
  the decl head 1:0 — P0-11) are the two highest-leverage fixes; each collapses many findings.
- **Land FIXTURES.md §3's run-vs-check agreement gate EARLY** — it pins the biggest class and
  turns the remaining P0s into red-fixture-then-fix bites.
- The P0s are mostly independent, worktree-able bites: silent SIGBUS/SIGSEGV crashes (P0-2),
  deriving-on-records broken in BOTH pipelines opposite directions (P0-3), positional record
  patterns run-only failure (P0-4), mutability not enforced + branch-write emitter panic
  (P0-5), `medaka test` exits 0 on failure (P0-6), playground trio (P0-7 wasm TCO loss on
  un-annotated tail calls / P0-8 worker.js missing host imports / P0-9 map+set false warnings
  + interpreter ctor collision), hash_map unusable under run (P0-10), REPL dies on any parse
  error (P0-12), cwd-relative module resolution (P0-13), `export import` build panic (P0-14),
  attributes unbind signature-less defs (P0-15), tuple-call hint (P0-16), impl-completeness
  unchecked (P0-17), check-silent/run-error dead ends (P0-18).
- Findings are repros, not diagnoses — expect some filed hypotheses to be wrong (per the
  debug-pipeline skill's history); verify empirically before fixing. Some overlap
  already-filed PLAN.md items (record deriving Display divergence, hashInt, run-path
  auto-print); FINDINGS.md is the superset — reconcile there as items close.
- Cheap parallel wins: the FIXTURES.md "Doc fixes" list (SYNTAX.md corrections: broken
  attribute example, `set_ref`→`setRef`, Map/Set import requirement, 63-bit Int, stale
  OCaml ground-truth pointer, dead `bench`).

## RESUME — ✅ Playground deferred items + thorough gate sweep + dogfood fixes DONE (2026-07-07). `main` = `f1c76e09`
Long multi-batch session clearing the playground-filed deferred items, then a full gate audit, then live guide-author dogfood findings. Design→delegate→isolated-worktree→verify→merge throughout; **three batched seed re-mints** (each cold `bootstrap_from_seed` C3a PASS). Owning memory `project_playground_deferred_items_batch` (full detail); PLAN.md "2026-07-07 batch" entries. **~20 fixes landed, ZERO session regressions** (a thorough gate sweep verified every failure was stale-golden or pre-existing-at-`54344aba`).
- **Batch 1–2:** ppScheme constraint display; multi-clause exhaustiveness (root cause = entry-only oracle, not 524-partial cleanup; found+fixed a latent `findTvarN` bug); composite-main auto-print (in-process wrap+re-check, covers the single-process playground); signed-main sig-strip; type-error spans (lexer string-span + whole-binop + arg); runtime-trap coding (native + **wasm coded traps + Bool parity** → playground no longer shows generic "program panicked"); emit-entry dedup (correct consolidation, not a suppress).
- **Batch 3 — gate sweep + pre-existing bugs + dogfood:** **KEY LESSON — `run_gates` only covers the 72 `diff_compiler_*`; the ~40 bootstrap/selfcompile/effect/build/wasm/native_cli/doctest gates drift silently — a green run_gates + fixpoint is NOT a full check.** Fixed pre-existing bugs the sweep found: `mdk_apply` name collision (helper→`__mdk_apply`), `maximum`/`minimum` over derived-Ord ADT native crash (MIXED GAP-2-phase-b), `lsp_harness` (Frame import), `check-policy` stray eval. Dogfood (guide author): **binder type annotations** (block-let/do-bind/where — do-bind was silently DROPPING the binder; parser-only, enforced); **composite-main Display obligations** (composite-w/-non-Display was a **SIGSEGV** → located error + LSP-visible via `analyzeFrom`; function-main `Ambiguous`→`No impl`; `record`-keyword deriving-hint); **bind-outside-do** (`x <- act` in bare block: panic → clean `T-BIND-OUTSIDE-DO`).
- **⭐ OPEN DESIGN DECISION for Val:** inline PARAMETER annotations (`(x : Int) => x`, `f (x : Int) = x`, pattern ascription `(n : Int) => …`) don't parse — intentional (signature-driven style) or add? Binder-position annotations (let/do/where) now work; params are the one gap left.
- **DEFERRED (filed, not started):** standalone `where` signature line (`go : Int` on its own line — needs a `LetBind` AST signature slot + re-mint); stdlib `string` Unicode case-folding (2 doctests, ASCII-only impl — needs a Val call: accept ASCII + fix doctests, or implement folding); composite-main **run-path** auto-print (interp still warns — the emit path is done); **B4 stdlib coded-OOB seam** (`Array.set`/`MutArray.set` → `[E-INDEX-OOB]`, the last runtime-trap bite — needs a new coded-OOB extern across backends); type-error span Bite 4 (poly-Num-through-call); placeholder playground `href="#"` links (blocked on the public repo/docs existing); `hash_map`/`hash_set` `hashInt` doctest; do-bind fmt round-trip is cosmetically lossy (semantically correct + idempotent).

## RESUME — ✅ Playground QA soak + error-message copy pass DONE (2026-07-06). `main` = `a337ba17`
A long human-in-the-loop session driving the in-browser playground: the user reported issues live, each reproduced → fixed (design→delegate→isolated-worktree agent→verify→merge) → re-verified in a rebuilt `playground.wasm`. Then a full user-facing **message copy** review. All error-path/entry/string changes → **fixpoint C3a/C3b YES throughout, ZERO seed re-mints** (the committed seed still cold-bootstraps — a function/message rename adds no new syntax; verified via the fixpoint's step-0 seed bootstrap, so re-mint is NOT owed). Full detail + the DEFERRED list is in **PLAN.md's top "Current status (2026-07-06)" entry**; owning memory `project_playground_qa_and_message_copy`. Highlights:
- **Playground:** header/examples redesign; **stdlib imports bundled** (20 pure modules as `stdlib.extra`; math/fs/net/time/io/test excluded — native-only); **compile-warning surfacing** (new `__MEDAKA_WAT_DIAGS__` marker so a non-exhaustive `match` shows its `W-NONEXHAUSTIVE` squiggle + still runs).
- **Container API rename:** maps `get`/`has`/`set`, sets `has`/`insert`, `has` membership, `getMin`/`getMax`. ⚠️ `insert`→`add` for sets was REVERTED (collides with `Num.add`).
- **Diagnostic-location fixes** (improve `check`/LSP too): unknown-import loc; import-name squiggle narrowed to the bad name (added `Loc` to `UseMember`); parse-error line off-by-one; `main () =`/no-`main` → friendly located error not a wasm trap (+ squiggle on the head); duplicate-unbound dedup; leftover-token parse error now names the token + gives a layout/indentation hint.
- **Message copy:** `compiler/MESSAGE-AUDIT.md` (~226 strings audited); em-dash→period pass (82 msgs) + 57 author-authored copy edits; centralization assessed + REJECTED (dynamic templates — standardize in place).
- **Process notes:** ran ~10 isolated-worktree agents; the em-dash + copy passes each proved goldens punctuation-/edit-only via a validator; ONE agent was mistakenly non-isolated and made a probe edit in the orchestrator worktree (reverted, tree re-verified clean) — **always pass `isolation: worktree` even for "read-only" investigation agents that might probe-build**. `run_gates` 73/0 at wrap.
- **⭐ DEFERRED (clear entries in PLAN.md):** (1) **runtime-trap-format unification** — 4 backends trap differently; route eval/array/mut_array errors through the coded+located channel, add Core-IR source locs to native traps, dedup `T-EFFECT-PARAM` (needs design; wasm drops `panic` messages); (2) **type-error span precision** (narrow `currentLoc` vs offending operand); (3) **multi-clause-function exhaustiveness** (one-line gate but ~524 false-positive warnings → needs per-clause locs + tree-wide partial-fn cleanup); (4) remaining rare-path em-dashes (loader/build_cmd); (5) playground placeholder `href="#"` links; (6) **bare non-Unit `main` run/build divergence** — `run` warns for all; `build` auto-prints scalars/String but crashes composites with `llvm spike: cannot print an ADT value` (fork A: uniform auto-print via Debug / B: uniform reject / C floor: route the composite crash through the friendly `mainNonUnitMsg` guard, never an `llvm spike`); (7) **type display drops constraints** — `ppScheme` shows `add_ : a -> a -> a` not `Num a => a -> a -> a` (in `check --types` + LSP/playground hover; inferred correctly, display-only fix). **Pre-existing surfaced:** hash_map/hash_set `hashInt` doctest failure; `bootstrap_typecheck` missing goldens; `error_quality_fixtures` caret drift (owed a clean recapture).

## RESUME — ✅ `medaka lint` pre-commit hook COMPLETE — whole tree at 0, all 4 rules ratchet-gated (2026-07-02). `main` = `73ae235`
Extended the pre-commit hook to **also gate `medaka lint`**, then drove the **whole tree (compiler+stdlib+sqlite) to 0 `medaka lint` findings** and made the hook a **RATCHET** — any NEW warning of any rule fails the commit. Owning memory: `project_lint_precommit_hook` (full detail there). Highlights:
- **`match-on-param` 127→0, ALL FIXED** (emitters 111→multi-clause IR-preserving no-re-mint `f546f3d`; only 4 `Thenable`-`traverse` impls inline-suppressed). **`duplicate-body` ~232→0** = ~119 FIXED by extracting shared modules (`entry_support`/`diagnostics`/`demo_support`/`emit_support` — B2 `54c9f19` IR-identical, no re-mint) + ~110 directive-suppressed (distinct-ADT/codec/`*W`/self-contained-demo).
- **Suppression feature EXTENDED to cross-file rules** (`applySuppressionsMulti` + `runCrossFileReport` wiring) — `-- lint-disable-*` now works for `rule-duplicate-body` too.
- **Ratchet hook (`5008440`):** 3 per-file rules per staged `.mdk` + `rule-duplicate-body` via a **per-root** whole-project scan. GOTCHA: `medaka lint` mishandles the exit code with MULTIPLE root args → hook loops one root at a time (possible CLI bug to file).
- **Wave A salvage lessons (prior session limit-kill):** verify agent branches with the FULL gate suite incl. wasm/oracle builds (not just `diff_compiler`) — caught un-exported `entry_support` API (native build enforces module privacy; interpreter lenient), stdlib desugar/mark golden drift (recapture; `mark_main` takes `<prelude> <target>`), and a dead unbound `readAllDecls` in `wasm_emit_typed_main.mdk` that only the wasm-oracle build catches.
- **USER PRINCIPLES (durable):** "fix, don't suppress" wherever sensible (triage confirmed most advisory findings were genuinely fixable); linter rules must stay GENERAL (use inline directives for project-specific exceptions, never bake project structure into a rule); goal = 0 warnings so a new warning is unambiguously new.

### ✅ DONE + merged (main, ≤ e9ab626):
- **Two false-positive lint rules fixed to be context-aware (`761c415`):** `rule-hand-rolled-derivable` + `rule-stdlib-reimpl` were flagging correct code (primitive-type instances that can't derive: `impl Eq Int/Float/Bool/String/Char/Unit/Array`; stdlib defining its own `reverse`/`take`/etc.). Fix threads the file **path** into `Rule.check`/`lintProgram`/`lintToLines` + an `isStdlibPath` helper (skip stdlib-owned files) + a data-decl predicate (`oGetCtors` — only flag derivable types with a `data`/`record` decl). Now **0/0 repo-wide**, still fire on genuine user code (fixture `test/lint_fixtures/derivable_needs_datadecl.mdk`). NOTE (agent finding): deriving DOES work for some prelude ADTs (Option/List) — so the fix uses the stdlib-skip, NOT a false "deriving-unavailable" predicate.
- **ESLint-style inline suppression directives (`8343ac6`):** `-- lint-disable-line <rules>`, `-- lint-disable-next-line <rules>`, `-- lint-disable-file <rules>` (omit rule names = all rules). Seam: findings filtered post-`lintProgram` by `applySuppressions src` recovering directives from the lexer's `collectComments` side-channel. Wired into `medaka_cli.mdk` lint arm + `lintToLines`. Fixture `test/lint_fixtures/inline_suppression.mdk`.
- **`lint --fix` comment-loss bug FIXED (`3209dbd`):** `--fix` spliced printer output (comment-free) over a decl's line span, silently DROPPING interior comments. Fix = bail on any decl whose `[declPosLine,declPosEndLine]` span contains a comment (`spanHasComment` in the shared `collectSplices`, reusing `collectComments`). Covers BOTH fixers. Leading doc-comments (outside span) still allow the fix. **VERIFIED comment-safe on wasm_emit (2182 comments preserved).** ⚠️ FOOTGUN THIS SESSION: I first "verified" with a STALE `./medaka` (worktree behind main) → saw 94 comments dropped → false alarm; a fresh build showed 0 loss. Always rebuild before trusting a `--fix` comment test.
- **Pre-commit hook extended (`d527c82`):** `.githooks/pre-commit` now runs fmt-check THEN `medaka lint --only=<GATED> --deny=<GATED>` per staged `.mdk` (`test/` excluded). `GATED_LINT_RULES="rule-hand-rolled-derivable,rule-stdlib-reimpl"` (the two zero-FP rules). Advisory rules (`rule-match-on-param`, `rule-duplicate-body`) still warn under plain `lint` but DON'T block. Intentional exceptions → inline directive. Installed clone-wide at `.git/hooks/pre-commit`; AGENTS.md §Build&test updated. **Hook end-to-end tested** (fmt-clean FP file → blocked at lint; advisory-only → passes; suppressed → passes). NOTE: stdlib files are exempt from both gated rules (isStdlibPath), so the concurrent stdlib session won't be blocked.

### Open follow-ups (none blocking):
- **Possible CLI bug:** `medaka lint --deny=<rule> <root1> <root2> …` returns exit 0 even when a later root has a finding (single-root is correct). The hook works around it by looping per-root; worth fixing in the CLI so multi-target lint exit codes aggregate.
- **General (non-project-specific) rule idea, deferred:** whether `rule-match-on-param` should structurally not-flag impl methods where multi-clause is unsafe (the `Thenable`/`pure` eval-loop) — using inline directives for the 4 sites for now, per "keep rules general."

## RESUME — ✅ `medaka fmt` hardened → whole-repo formatted → pre-commit hook LIVE (2026-07-01). `main` = `2f36d92`+
A dogfood-driven arc that took `medaka fmt` from "unsafe on real code" to a working git pre-commit hook. Method: format one real file at a time, review the diff WITH the user, delegate each fix to an isolated-worktree agent (design→delegate→independently-verify→merge). **7 formatter issue classes fixed** (each: repro → agent → gates → merge):
- **C** (`b129bf3`) else-if ladder in body/statement position (`printIfBody` reuses `ifRhsElsePart`). **K/N** (`ac93e00`) pattern parens — `PCon` stopped self-parenthesizing inside tuples (K), `printPatAtom` wraps `PRec` in arg position (N). **E+H** (`3576974`) width-aware record-`data` field wrap (E, `group`+`FlatAlt`) + `else do`/`else match` keyword adjacency (H). **O/P/R** (`9d90651`) def/arm body breaks at `=`/`=>` before mangling its interior (new `hangAtSep` combinator; chains excluded). **L Stage 1+2** (`1e29b75`) verbatim safety-net: any non-data decl with **interior trailing comments** is preserved VERBATIM (comment corruption was THE trust-blocker; the OCaml `format_program` never handled interior comments either — a "full port" wouldn't fix it, see design doc). **U** (`f52a2c3`) idempotency — `collectChain` now peels the transparent `ELoc` paren-wrapper so `(a++b)++c` and `a++b++c` converge.
- **Whole-repo soak (the milestone gate):** 175 files → **0 parse failures, 0 comment corruptions (strings stripped), 0 non-idempotent.** fmt is SAFE + idempotent repo-wide.
- **Bulk adoption (`0616360`+merge+`77cc645`):** `medaka fmt --write` on all 148 non-`test/` source `.mdk`. **Proof it's behavior-preserving: the compiler rebuilt from its own reformatted source reaches fixpoint C3a/C3b (byte-identical IR)** + `diff_compiler_llvm` 186/0, `check` 73/0, `eval_run` 50/0, stdlib doctests pass. NO seed re-mint (fmt preserves emitted IR). `test/` fixtures deliberately NOT formatted.
- **Pre-commit hook LIVE (`2f36d92`):** `.githooks/pre-commit` (installed at the shared `.git/hooks/`) rejects unformatted staged `.mdk` (`fmt --check`; `test/` excluded; `--no-verify` bypass; warns-and-allows if `medaka` unbuilt). Real-`git commit` reject test verified. **⚠️ ACTIVE clone-wide** — agents/devs must `medaka fmt --write` changed `.mdk` before committing (now in AGENTS.md). BAKE THIS INTO FUTURE AGENT PROMPTS that edit `.mdk`.
- **Design doc:** `compiler/FMT-COMMENT-INTERLEAVING-DESIGN.md` (`75251e8`). Memory: `project_fmt_hardening_and_commit_hook`.
- **✅ FOLLOW-UP LANDED (same session):** **T** (`8834d83`) — single-application body now hangs at `=` (new `hangAlwaysAtSep` + `isSelfIndentingArg` classification: plain app-spine hangs, lambda/list/record/block arg stays inline). **L Stage 3+4** (`e76ff5e`) — operator-chain interior comments now INTERLEAVE (format, not verbatim): `identChar`'s `-- 0-9`/`-- A-Z` stay attached to their operand across reflow. **fmt/printer-only → NO re-mint** (the agent did chains WITHOUT a parser side-channel). Two more **combined bulk-reflows** (`8834d83`-driven + `15a38c0`) took the whole repo to the new fixed point (compiler rebuilt from reformatted source → fixpoint C3a/C3b YES each time). Repo is FULLY fmt-clean at `15a38c0`.
- **✅ L Stage 5 (block/do/let statement-level interior comments) — DONE (`e3eb764` + reflow `36ce0c9`).** Completed from the preserved WIP (clean merge, no conflicts). do-blocks/let-groups/bare-blocks with one trailing comment per single-line statement now FORMAT with comments attached across reflow (`printDeclBlockCommented`/`stmtsCommented` + a `LineComment` Doc node); multi-line statements / standalone interior comments fall back to the verbatim safety-net (count-mismatch gate → never drops/misplaces). The **parser.mdk side-channel** (`declChainLines`/`blockStmtLines`, statement→source-line) is **consumed ONLY by fmt → emit-invisible → NO RE-MINT** (fixpoint C3a YES, verified). Gates: fmt 59/0, printer 28/0, parse 28/0, correctness-sweep 0-loss, whole-repo idempotency 0. **Comment interleaving is now COMPLETE for both chains (Stage 3+4) and blocks (Stage 5).** (Pre-existing `diff_compiler_desugar` 99/9 is the OTHER session's stdlib golden staleness — base64/fs/hex/math/path/time missing goldens + byteparser promotion — NOT this work; confirmed 9-failing on main without the change.)
- **KEY LESSON (bake into future fmt work): every formatter-behavior change SHIFTS the fmt fixed point → a repo-wide reflow is owed after each.** T alone re-dirtied 24-25 files. With the hook ACTIVE + a concurrent session editing the same hot files (typecheck/eval/emit/parser), this causes reflow-vs-semantic-edit churn. Batch formatter changes, then ONE reflow; or freeze the formatter while a concurrent session is hot.
- **Process notes:** shared `main` with a concurrent session (P1-stdlib) throughout — every merge was a re-checked 3-way (their math externs touched the compiler graph; baseline fixpoint stayed green, no re-mint owed); the bulk-format raced their landings (re-formatted on their latest base rather than conflict-merging). Two agents hit the empty-report failure mode (salvaged per playbook). The C agent shipped a WRONG design first (unconditionally-flat ladder → wide chains overflow); caught by an orchestrator wide-input probe, replaced with the `ifRhsElsePart` reuse.

## RESUME — ✅ P1 standard library: 8 modules shipped (path/hex/base64/math/bytes-LE/fs/time/net) (2026-07-01). `main` = `efece85`

Grew the stdlib past the P0 core toward "batteries a pragmatic language ships." Design-first (two decision-ready docs), then delegated each module to an isolated-worktree agent (design→delegate→independently-verify→merge). Owning docs: `P1-STDLIB-DESIGN.md` (5-language comparison + P1/P2/P3 tiers + per-item cost tags), `NET-DESIGN.md`, `STDLIB.md` Modules 13–19; memory `project_p1_stdlib_workstream`.

- **Shipped (all gated + in STDLIB.md):** `path` (POSIX, pure), `hex`+`base64` (RFC 4648, pure), `math` (22 libm externs, native-only — wasm traps like `floatRem`), byteparser/bytebuilder **little-endian** mirrors (pure), `fs` (remove/rename/stat + copyFile/mkdirAll/walkDir), `time` (Duration + Hinnant UTC civil calendar + monotonic/sleep), `net` (blocking TCP client+server+DNS, `withConnection` brackets).
- **Two "build-only, by design" modules — `fs` and `net`:** the tree-walking interpreter (`medaka run`) is a deliberately **pure, FFI-free, deterministic oracle** (it *fakes* clock/random with canned values — that's what keeps the `diff_compiler_eval_*` gates deterministic). File/net externs are unbound under `run`; those programs use `medaka build`. Making `run` do real IO = widening eval's effect boundary across ~94 sites + the driver — a **decided non-goal** (see STDLIB.md Module 17 + memory). Don't re-litigate.
- **`math`/`fs`/`time` extern batches + `net` externs** touch `llvm_emit.mdk` → seed re-minted **twice** (`5706c54`, `9bb510c`); cold `bootstrap_from_seed` C3a PASS + fixpoint C3a/C3b YES both times.
- **`net` effect wiring is free:** `("Net", PPrefix None)` was already seeded in `typecheck.mdk`, so `connect "h" p` α-recovers `<Net "h">` into `manifest`/`check-policy` with zero compiler change. Gate: `test/diff_net.sh` (build-run loopback + API-roundtrip fixtures + a wasm-reject leg; net can't be doctested — unbound under the interpreter).
- **PROCESS LESSON (ran concurrent with the fmt session above):** a parallel session that bulk-reformats + commits to `main` rapidly **collides with emitter-touching bites** (it reformats `llvm_emit`/`wasm_emit` out from under a branch → non-ff / stale-format merge). Fixes: (1) land emitter bites **atomically** — `git merge --no-verify <sha>` into current `main` in ONE op (merge-into-branch-then-ff leaves a gap for `main` to move), verify AFTER in a worktree; (2) new-file bites (`stdlib/net.mdk`, `test/diff_net.sh`) don't collide; (3) the fmt hook normalizes `<X _>`→`<X "_">` — VERIFIED semantically equivalent (`effect_builtin_param_domain` 12/0). Also: `medaka build` from a non-standard shell needs `export MEDAKA_EMITTER=$PWD/medaka_emitter`.
- **Open P2 backlog (none blocking):** csv, a small regex, datetime timezones, more codecs, net v1.5 (UDP / socket options). Interpreter-file/net-IO stays a non-goal.

## RESUME — ✅ Capability effects: WS-3b builtin-extern flip DONE — the LAST OCaml-deferred item (2026-07-01). `main` = `1cd2749`

Closed the one capability-effects item that was deferred **specifically until the OCaml compiler was retired** (the frozen oracle registered Env/Exec as atomic + read the embedded `runtime.mdk`, so the extern re-annotation would have broken the oracle gate). The native machinery (domain registry, α hole-fill, `check-policy`, `manifest`) was already landed; the OCaml oracle was the sole blocker. Three source commits + one doc reconcile, each designed→delegated→independently-verified→merged. Owning docs: PLAN.md top status entry + `EFFECTS-CONFORMANCE-ROADMAP.md` (WS-3b/E4 now CLOSED); memory `project_effects_semantics_spec`.

- **`25435fb` (Sonnet)** — flipped `getEnv → <Env _>`, `runCommand → <Exec _>` in `stdlib/runtime.mdk` (`args` left bare — Unit arg, nothing to refine). Domains were ALREADY pre-registered in `seedEffectDomains` (Env=Set, Exec=Prefix), so refinement fires with NO registry edit / NO per-program `effect` decl: `getEnv "HOME"` → `<Env {"HOME"}>`. New gate `test/effect_builtin_param_domain.sh` drives the REAL stdlib builtins (no local extern shadow).
- **`5e7c856` (Sonnet)** — BONUS the flip surfaced: top-level `PSet` (Env) was missing from `compiler/tools/check_policy.mdk`'s `atomToToml`/`atomToAllowTok`/`parsePolicyTok`, so `manifest` rendered `Env = true` (unbounded!) instead of `Env = ["HOME"]` and `--allow Env={…}` wrongly rejected. Added the three `PSet` arms + `export`ed `decodeSetParam` in `typecheck.mdk`.
- **`2d010b2` (Sonnet, salvaged)** — flipped all nine file-IO externs to `<FileRead _>`/`<FileWrite _>` (Prefix domain, already registered → no manifest gap). **Blast radius measured tiny: 1 of ~300 file-IO call-sites passes a literal path; the rest are dynamic → hole unfilled → degrade to ⊤ = old bare label → escape-safe, ZERO golden churn.** (Agent hit the "waiting" empty-report mode — committed nothing, left an orphan `build_oracles`; salvaged its live-but-uncommitted worktree edits, reaped the orphan, re-verified from scratch.)
- **`1cd2749`** — reconciled PLAN.md + EFFECTS-CONFORMANCE-ROADMAP.md.
- **Verification (orchestrator-rerun):** `effect_builtin_param_domain` **12/0**, `effect_param_domain` 6/0, `effect_set_domain` 5/0, `effect_product_domain` 8/0, `check_policy` 4+7/0, `manifest_emit` 6/0, `typecheck` 14/0, `typecheck_golden` 57/0, `check` 73/0 — **ZERO golden churn**; **fixpoint C3a/C3b YES**; **NO seed re-mint** (runtime.mdk is the typecheck-time extern catalog; effects erase → emitted IR unchanged).
- **Remaining effect ledger — NONE OCaml-deferred; all downstream of "does a manifest consumer exist yet?" (a plugin host):** WS-5 extern-row assurance (a standing lint/review discipline — DISCUSSED + DECLINED this session: for a solo author it guards the wrong end, the extern catalog is author-trusted, and a drift-lint can't verify the C primitive anyway); Wasm custom-section manifest emission (`backend/wasm_emit.mdk` seam — infra for a host that doesn't exist); Phase 146b user-facing parameterized effects (`effect Fetch "x.com"` — the one with standalone solo value, but a larger language-surface task, not a close-out). **Capability-effects close-out considered DONE.**

## RESUME — ✅ Tandem SQL: SIX query-engine features shipped (ORDER BY / INNER+LEFT JOIN / DISTINCT / arithmetic+UPDATE-SET-expr / computed SELECT columns) (2026-07-01). `main` = `e567238`

A focused dogfood-soak workstream on the pure-Medaka SQLite **query engine** (`sqlite/lib/{select,mutate}.mdk`). Six features, each **designed→delegated→independently-verified→merged**, each gated vs the real `sqlite3` CLI AND native==wasm via the tandem oracle `test/wasm/diff_sqlite.sh` (grew 3→9 probes). **ALL PURE LIBRARY** → NO seed re-mint, NO fixpoint concern (select/mutate are outside the self-compile graph). **Soak result: ZERO compiler bugs across all six** — every order/join/distinct/arithmetic/projection shape ran `run`==`build`==native==wasm, including the historically-fragile Float-in-`Cell` arithmetic. Owning docs: PLAN.md top status entry + `SQLITE-DESIGN.md` (status line updated to point at as-built); memory `project_sqlite_mutation_and_wasm`.

Landed (commit / model / tandem-probe-count-after):
- **Multi-column ORDER BY** (`fa8ecba`, Sonnet, 4/0): `orderBy : List (String,Bool)`; `withOrderBy` appends (single-col byte-identical); per-key direction-aware comparator.
- **INNER JOIN — single + N-way** (`0d599c1`, Opus, 5/0): additive `joins : List Join` (`Join={table,on:SqlExpr}`); qualified `table.col` names (`validQualIdent`); executor refactored to a shared cell-based pipeline (`runOverCells`) — both paths materialize `List (List Cell)` + one combined `lookup`; nested-loop concat filtered by the ON predicate. This BROKE the single-table assumption cleanly.
- **LEFT JOIN** (`b1c1acf`, Sonnet, 6/0): `JoinKind=JInner|JLeft` + `leftJoin`; schema-derived right-table width threaded into the loop; `crossOne` null-pads (`l ++ replicate width CNull`) unmatched left rows; WHERE-vs-ON semantics fall out (WHERE runs post-join → drops null-padded rows like sqlite3); nullable side decodes via `tOption`.
- **DISTINCT** (`ea68fdd`, Sonnet, 7/0): dedups on PROJECTED values BEFORE limit → needs `Eq a` → separate `queryDistinct : Eq a => …` (plain `query` stays unconstrained); `runOverCellsDistinct` tail = filter→sort→decode→`nub`→slice; `distinct:Bool` field + `withDistinct` + render.
- **SQL arithmetic + UPDATE…SET `<expr>`** (`4d6d502`, Opus, 8/0): `ArithOp`/`EArith` on `SqlExpr` + `eAdd/eSub/eMul/eDiv/eMod`; exported `compileValue`/`compileOperand` evaluator with EXACT sqlite semantics (NULL-prop; `CInt⊕CInt→CInt` for +−* else CFloat; int-div truncates toward zero; `÷0`/`%0→NULL`; modulo sign follows dividend). `mutate.Assign` now carries a `SqlExpr` RHS (per-row eval; all RHS evaluated against ORIGINAL cells before assigning → `SET a=b,b=a` swaps). Bonus: WHERE-with-arithmetic falls out.
- **Computed SELECT columns** (`f4b437d`, Opus, 9/0): additive `columns : List SqlExpr` (default `[]`=`SELECT *` byte-identical) + `withColumns`; projection compiled via `compileValue` against the same `lookup` (so it works over JOINs) and applied RAW-row→projected-`List Cell` BEFORE decode; DISTINCT dedups on projected values. **v1 limit:** WHERE/ORDER BY reference ORIGINAL columns only (ORDER-BY-on-computed deferred).

**Process notes (all clean this session):** every agent reported the right branch + SHA, no empty-report/stale-oracle/stray-binary failure modes triggered, no STOP guardrails hit. The additive-field pattern (mirroring ORDER BY→DISTINCT→columns) + "prior features as byte-identical regression guards" made each bite low-risk; Opus for the executor-refactor/semantics-heavy bites (JOIN, arithmetic, projection), Sonnet for the well-templated additive ones (ORDER BY, LEFT JOIN, DISTINCT). Node v24 via nvm for the wasm gate throughout.

**Next tandem bites (scouted, ranked, none blocking):** string functions / `||` concat (extend the evaluator to text — enables computed text cols / `SELECT upper(name)`); ORDER-BY-on-computed-column (lift the projection v1 limit — sort projected rows); subqueries (large — `SqlExpr`/`Select` recursion, scalar + `IN`). Index-use is a perf rewrite with no observable tandem diff → deprioritized.

## RESUME — ✅ Type aliases + value restriction + stdlib-unification step 2 + SQLite UPDATE/DELETE + WasmGC port + aggregates + Float-on-wasm FULLY CLOSED (2026-06-30). `main` = `ee2b53e`

A long, productive session. Nine distinct workstreams, each designed→staged→independently-verified→merged. **NO seed re-mints were needed this entire session** — a recurring happy outcome (the compiler's own source never hit the newly-fixed patterns, so `selfcompile_fixpoint` C3a kept passing against the committed seed; and all the wasm work is outside the LLVM self-compile graph). Verify fixpoint-against-committed-seed before assuming a self-compile-closure change needs a re-mint (the lesson from the type-lost-Float root fix). Owning memories listed per item.

**Language / typechecker:**
- **Transparent type-alias expansion (5 stages, `29efddf`→`6d9eaec`; payoff `22d6a88`):** `type X = Y`, parameterized `type Pair a=(a,a)` (+ arity check), `export type` across modules; cyclic aliases rejected (were a stack-overflow crash). Locus: typecheck pre-pass `aliasTableRef` expanded at `fromAstTypeE`/`fromAstTypeApp` + resolve `expTypesDirect` + typecheck `publicDataDecls` (cross-module = TWO layers, my repro found layer 1). `support/ordmap.mdk` dropped its `data OrdMap` wrapper for `export type OrdMap a = Map String a`. Memory `project_type_alias_expansion`. v1 wart: alias-error locs at the decl.
- **Relaxed value restriction (`386a543`):** `isNonexpansive` now generalizes ctor-app/record of non-expansive args (SML non-expansive set) — `e = MkBox []` generalizes. SOUND: `Ref` (the sole uppercase mutable-cell extern) excluded by name. Memory `project_value_restriction_relaxed`.

**Compiler↔stdlib unification (step 2, `09e0154` + `4621272`):** `support/util.mdk`'s `reverseL`/`zipL`/`joinWith` → stdlib `list`/`string`; then 4 quadratic local string-join re-rolls → `util.joinWith`. **Measurement FLIPPED the assumption:** `import list`/`string` is NEAR-FREE (core-defined instances → no new surface) while delegating hot helpers to prelude Foldable methods costs +56% (lost short-circuit). AGENTS.md cost bullet + `HELPER-CENSUS.md` corrected. Memory `project_compiler_stdlib_unification`.

**SQLite (owning memories `project_sqlite_mutation_and_wasm`, `project_wasm_float_hardening`):**
- **UPDATE/DELETE rowid-faithful CRUD (`a0fb00d`):** read-transform-rewrite via `select.compilePred`; new explicit-rowid writer (`d8cebbd`); `sqlite/lib/mutate.mdk`; refuses index/WITHOUT-ROWID/IPK-SET with clean `Err`.
- **WasmGC port (`8cff4f3`→`3a633d7`):** SQLite (in-memory + file, full CRUD) runs `--target wasm` == native. ZERO emitter construct gaps — blocker was 9 missing externs. Shared tandem oracle `test/wasm/diff_sqlite.sh`. Closed 3 general wasm gaps (W-SQLITE-1/2/3).
- **Aggregates + GROUP BY (`d493676`) — FIRST tandem feature:** COUNT/SUM/AVG/MIN/MAX + GROUP BY + HAVING; native byte-matches `sqlite3`, native==wasm via `diff_sqlite`. Surfaced the Float-on-wasm arc below.

**Float on WasmGC — FULLY CLOSED** (EMITTER-GAPS.md "W-SQLITE-4 + type-lost-Float", designs `WASM-FLOAT-TYPING-DESIGN.md`/`SHARED-FLOAT-RESIDUAL-DESIGN.md`/`WASM-POLY-NUM-DESIGN.md`):
- **W-SQLITE-4 (`b5eb960`/`2d321af`, faddF removal `f657831`):** wasm `cexprIsFloat` blind to Float param/return/field → registries from `declSigTypeNames`/`ctorFieldTypeNames`.
- **Type-lost-Float ROOT fix, approach C (`f3d4f71` C-core + `27969e7` C3):** monomorphic concrete-Float binop anchored only via a poly-HOF value miscompiled (native garbage / wasm trap). Typecheck stamps a grounded-only binop scalar-tag (reusing the comparison-operator `pendingBinopSites` infra) → `CBinPrim` field → both emitters read it. GOTCHA: the `EBinOp` route `Ref` doesn't survive the dictPass→lower boundary → tag relocated into a surviving `EAnnot` node.
- **Polymorphic-Num, approach A (`8afc613`):** `sq x=x*x`/`myMax` on Float trapped (wasm has no dict-dispatched arith path). Ported native's runtime value-tag dispatch: `$mdk_value_add/…` helpers + `$float` arms on `$mdk_value_cmp`/`_eq` (Ord/Eq sibling); `emitBinRef` routes ONLY polymorphic operands (`numPolyLocalsRef`), static fast path preserved. B (monomorphization) was the XL alternative — DEFERRED to the instance-DCE roadmap.
- **C4 auto-print (`ee2b53e`):** bare Float value main printed garbage → `mainTypeIsFloat` hint (mirrors `mainTypeIsUnit`) → prints `6.0`.
- **Net:** every Float shape now runs wasm==native — arithmetic (C+A) AND auto-print (C4), monomorphic AND polymorphic. Gates: `diff_wasm` 154/0, `diff_sqlite` 3/0, `diff_compiler_llvm` 186/0, fixpoint C3a/C3b YES throughout. Node v24 via nvm (default v20 too old for WasmGC).

**Open / next (nothing blocking):** more tandem SQL features (JOINs, indexes, UPDATE SET expressions) — each auto-gets a wasm test via `diff_sqlite.sh`'s CORPUS; B/monomorphization (strategic, instance-DCE roadmap); the deferred wasm-modules single-file prelude-linkage gap (`fold`/`fromInt` in the single-file wasm entry — noted during the poly-Num probes, unrelated). `.gitignore` now covers the sqlite demo/probe root binaries.

## RESUME — ✅ fmt 3 bugs fixed + 2 new lint rules/upgrades + type-aware-lint design (sqlite fmt/lint dogfood review, 2026-06-29). `main` = `bb32190`

A file-by-file review of the sqlite library through `medaka fmt` + `medaka lint` — "what do they catch, what do they miss, what should we fix in the tools." Six commits, each independently orchestrator-verified + merged; seed re-minted ONCE at checkpoint (fmt + exhaust touched the self-compile graph), cold `bootstrap_from_seed` C3a PASS, fixpoint C3a/C3b YES. Memory: `project_fmt_three_bugs_fixed`, `project_type_aware_lint_design`, `project_medaka_lint` (updated).

- **fmt was UNSAFE on real code — 3 bugs fixed (`67fef29`):** (#1) `fmt --check` was a NO-OP (`FmtCheck => ()` in `medaka_cli.mdk` discarded the formatted text → always exit 0; whole-dir `--check` sweeps falsely reported every file clean). (#2) `export <sig>` printed on its own line (`printer.mdk` `text "export\n"` vs siblings' `"export "`) → `fmt --stdout sqlite/lib/sqlite.mdk` no longer PARSED + non-idempotent. (#3) single-variant `data X = X {f:T -- cmt}` field comments orphaned below the decl (ConNamed flattened) → real re-attachment via new `printNamedFieldData` (`fmt.mdk`). (#4 bonus, needed for #2's repro to parse) neg-literal as a wrapped app-arg re-lexed as infix `-` → unary-precedence paren. Gates: `diff_compiler_fmt` 47/0, `_printer` 28/0, sqlite idempotency sweep clean. **Discovery method:** perturb a copy + `diff <(fmt --stdout f) f` + a `fmt(fmt(x))==fmt(x)` idempotency sweep — sqlite.mdk failed both, pinpointing the corruption.
- **New lint rule `rule-bind-then-destructure` + autofix (`23db203`):** dogfood-driven (user spotted it). `v <- e; match v {(tuple) => body}` (bind then immediately single-arm-destructure as the do-block's FINAL stmt) → `(tuple) <- e` with body flattened (tuple destructuring in `<-` was ALREADY supported run+build — the code just didn't use it). Fires on irrefutable patterns, autofix is an AST rewrite. `diff_compiler_lint` 6/0, `_lint_fix` 3/0.
- **Tier 0 syntactic oracle (`cedc505`):** wired `exhaust.mdk`'s EXISTING `buildOracle : List Decl -> Oracle` (purely syntactic ctor table, NO typecheck) into the linter → `rule-bind-then-destructure` now proves single-ctor irrefutability (`Box x <-` fires, `Some`/`Ok` skip). `exhaust.mdk`: `export oGetCtors/oGetCtorType` (in self-compile graph → seed re-mint `09aa961`, fixpoint YES). Design doc `compiler/TYPE-AWARE-LINT-DESIGN.md` (on main). **CRUX from the design pass:** NO `Loc→Type` map exists (LSP hover is name-keyed) → true `typeOfLoc` = LARGE deferred (Tier 2); most lint value is SYNTACTIC (Tier 0). Tier 1 (name-keyed schemes) + §6 deriving-sharpening deferred. Gates `diff_compiler_lint` 7/0, `_lint_fix` 4/0.
- **sqlite cleanup applied (`48cfa72`):** `lint --fix` on dbwriter/select/main — 8 findings fixed (1 bind-then-destructure + 7 match-on-param); `magicBytes` deduped into `header.mdk` (exported, imported). All 4 files typecheck; all 8 sqlite oracles PASS byte-identical. Demos left as-is (intentional standalone dup).
- **match-on-param autofix improved (`bb32190`):** the review found the §8 autofix BAILED whenever an arm body referenced the scrutinee param. Fix: a `PWild` arm whose body references the scrutinee now emits the clause with the param NAME (not `_`), re-binding it; non-wildcard refs still bail. `pageCountOf`/`buildTablePages` now auto-fixable. `diff_compiler_lint_fix` 5/0.

**Tool verdict:** lint is solid (high precision, correctly conservative, `--fix` bails rather than emit broken code). fmt had real corruption bugs the review caught precisely because no committed file exercised those shapes (the soak thesis paying off).

**Open follow-ups (none blocking):** Tier 1 name-keyed schemes + §6 deriving-sharpening (deferred per design); sqlite demo binaries (`sqlite_reader`/`sqlite_writer`/`writer_api_demo`/…) are NOT gitignored (an agent committed 5 of them by accident; orchestrator rebuilt a clean commit dropping them — worth a `.gitignore` entry); the abstract-record `Oracle(..)` resolve-vs-emit inconsistency (build's resolve rejects `(..)` on an abstractly-exported record; emitter accepts it — minor, worked around by importing the type abstractly).

**Process notes (recurred — see ORCHESTRATING.md):** two agents mis-reported their branch (real commits on current HEAD — merged by SHA); the Tier 0 agent hit the empty-report failure mode (committed nothing, left orphan `build_oracles`, ended mid-verification) — salvaged + verified from scratch, its final state converged byte-identical to the salvage; one agent committed stray build-artifact binaries (`git add -A`) — caught by the pre-merge `git diff --stat` surface check. KEY environment note: **agents spawned without `isolation: worktree` SHARE the orchestrator's worktree filesystem + git HEAD** (one left my worktree on its branch) — sequence heavy builds, don't run two at once.
## RESUME — ✅ Compiler MAY use stdlib; OrdMap→stdlib `Map` shipped + policy changed (2026-06-29). Commit `59f0545` (merged to `main`)

Measurement spike → policy change → first migration step. **The compiler can now import `stdlib/`** (AGENTS.md rule rewritten). The long-feared blocker — monomorphization / instance-level DCE — was never actually a blocker; it was a cost decision, and the measured cost is small. Owning memory: `project_compiler_stdlib_unification`. PLAN.md "Current status (2026-06-29) — compiler MAY use stdlib".

- **What landed (`59f0545`):** `support/ordmap.mdk` retired its hand-rolled weight-balanced tree and now wraps stdlib `Map` (`import map`), so it can't diverge from `stdlib/map.mdk`. Consumers (`typecheck.mdk`/`llvm_emit.mdk`/`util.mdk`) only swapped `OTip`→`omEmpty`. Seed re-minted (emitter graph grew). No build-infra change (`build_native_medaka.sh` already passed `$STDLIB`).
- **Measured cost:** `medaka` +34 KB (+1.25%), full self-compile +0.65s (+4.8%) — the whole `Map` instance surface for one type. **Verified:** all 53 entries native-compile; selfcompile_fixpoint C3a/C3b YES; self-gates (selfproc 3/0, check_modules 2/0, resolve_modules 13/0) + user gates (eval_dict 28/0, eval_run 50/0, check 72/0, typecheck_golden 57/0) green; **zero golden changes** (behaviourally invisible).
- **Three migration gotchas (carry forward — also in AGENTS.md + PLAN.md):** (1) **value restriction** — a polymorphic empty must be a NULLARY constructor; a constructor application (`OMap Tip`/`OMap (fromList [])`) is NOT generalized → monomorphises to `…Unit` → "Scheme vs Unit" cascade; fix = `data OrdMap a = OEmpty | OMap (Map String a)`. (2) **type aliases are NOT expanded** (`type X = Y` → "X vs Y") — must `data`-wrap. (3) **gates running the emitter/probes over compiler source need the `$STDLIB` root** — fixed in `selfcompile_fixpoint` + `diff_compiler_{selfproc,check_modules,check_modules_batch,resolve_modules}` + `profile_compiler`; any new such gate needs it.
- **Coupling note:** a `stdlib/map.mdk` change that perturbs emitted IR now forces a seed re-mint + fixpoint re-validation (feature, not bug — silent divergence → build gate).
- **Next:** `support/util.mdk` → stdlib `list`/`string` as a second *measured* step (`HELPER-CENSUS.md`). Open language idea: make the typechecker expand type aliases (would let `type OrdMap a = Map String a` drop the wrapper).

## RESUME — ✅ `medaka lint` modular linter SHIPPED + 2 emitter record-scanner gaps FIXED (2026-06-29). `main` = `4adcea6`

New CLI tool: a modular, rule-based linter (per-file + cross-file rules, `--fix`, recursive project targets). Built in staged, independently-gated, orchestrator-verified landings (design → framework+rules → CLI+gate → `--fix`+location-fix → multi-file → cross-file tier). Building it surfaced two latent emitter record-scanner gaps, **both since FIXED** (see the sub-bullet below — `73d51c0` + `5049b43`, seed re-minted). Linter v1 itself needed no seed re-mint (tool outside the emitter graph). Fixpoint C3a/C3b YES throughout; `diff_compiler_lint` 5/0, `_lint_fix` 2/0, `_lint_multi` 1/0, `_lint_crossfile` 1/0, `_exhaust` 5/0. Owning module `compiler/tools/lint.mdk`; memory `project_medaka_lint`.

- **Architecture:** runs on the **RAW pre-desugar AST** (mirrors `checkGuardExhaustiveness` — desugar destroys the surface shapes the rules detect). Registry of `Rule { name, descr, severity, enabled, check : Positions -> List Decl -> List Finding, fix : Option (Decl -> Option (List Decl)) }` records (`allRules`) — adding a rule = one fn + one list entry. Findings render via `diagnostics.mdk`'s carat path; goldens are location-stripped. Tool + entries are OUTSIDE the self-compile graph; only the `medaka_cli.mdk` `lint` arm is in-graph (hence the fixpoint check per stage).
- **v1 rules** (all default `warning`): `rule-match-on-param` (§8 guard-free `f x = match x` ≥2 arms → multi-clause), `rule-hand-rolled-derivable` (§6 `impl Eq/Ord/Debug` over a single named type → `deriving`), `rule-stdlib-reimpl` (§7a top-level fn named like a curated stdlib fn).
- **CLI:** `medaka lint [--fix] [--disable=R,…] [--only=R,…] [--deny=R,…] [paths…]`. ESLint-style severity — exit 1 iff any **error**-severity finding; `--deny=<rule>` promotes to error. `--fix` autofixes **§8 only** (printer-rendered decls spliced over the decl line-span bottom-up; guard-free safe subset — guarded matches still warn, left byte-identical; fixed file runs + re-lints clean). Targets: multi-file, dir, or no-arg project (walks up to `medaka.toml`), **recursive into subdirs** (skips dotdirs). §6/§7a are suggest-only (can't prove equivalence / safe deletion). Dogfood proof: `medaka lint sqlite/` flagged real §8 sites.
- **Cross-file rule tier (`a29df3f`, 2026-06-29):** a second registry `CrossFileRule { …, check : List (path, Positions, decls) → List Finding }` (`allCrossFileRules` + `runCrossFileRules`, all record access inside `lint.mdk`) that sees ALL project files at once, rendered under a `cross-file:` header. First rule **`rule-duplicate-body`** — flags top-level functions with a **structurally-identical body** (keyed by `ir.sexp.exprSexp`, the existing ELoc-stripped serializer; ≥10-AST-node threshold) across ≥2 files. Calibration: parsec 0, stdlib 12 (genuine map↔set/hash parallel helpers), compiler 142 (deliberate no-stdlib dup) — zero false positives. Fixpoint C3a/C3b YES; **no seed re-mint** (cold `bootstrap_from_seed` PASS with existing seed). Gate `diff_compiler_lint_crossfile`.
- **🟢 Two latent emitter gaps surfaced — BOTH FIXED (2026-06-29):** (1) ✅ FIXED (`73d51c0`) — `scanExprRecords` (`llvm_emit.mdk`) lacked a `CList` arm → record-in-list-literal missed field layout → `CFieldAccess: unknown field`; added `scanExprRecords (CList es) = scanExprsRecords es`. (2) ✅ FIXED (`5049b43`, seed re-minted) — the filed "cross-module function-field SIGSEGV" was DISPROVEN; REAL bug = **type-unaware field resolution** (`findFieldIdx` resolved `CFieldAccess` by label only → two records sharing a field name at DIFFERENT indices loaded the wrong offset → garbage/SIGSEGV). Fix mirrors the Bug-3 `Ref String` idiom: widened `EFieldAccess Expr String (Ref String)` + `CFieldAccess CExpr String String` (record name, `""`=unknown), typecheck `setRef rname` in `inferFieldAccess`, emitter resolves by `(record,label)` with label-only fallback; same fix to the sibling `isFloatFieldAccess`-by-label bug. **Diagnose-first key finding:** the emit-path record name is MANGLED (record name = ctor → `<mid>__<name>`) while type refs stay unmangled, so the design's exact `lookupRecordByName` missed → new mangle-aware `lookupRecordByMangledHead`. run==build on Int/function/Float collisions, fixpoint C3a/C3b YES, full `diff_compiler_*` 0-failing, fixture `field_collision`, ~21 files (mostly mechanical `_`-threading; load-bearing: `rewriteArgScoped` ref-preserve + sexp emit/parse in sync). `printer.mdk` is grep-detected as binary → needed `grep -a` (a sweep-skip trap).
- **Process note:** the Stage-3 agent hit the empty-report failure mode (committed nothing, left an orphan `build_oracles` running, ended with "waiting for the monitor"). Salvaged per playbook — committed its WIP, reaped the orphan, reconciled a git race (its later self-recommit was byte-identical to the salvage, `749993d`). Verified independently from git + gates.
- **Open follow-ups (none blocking):** §3 match-on-computed-value rule (deferred, FP-prone); cross-file rule tier; recursive subdir walk; config-file rule toggles; autofix for §6/§7a.

## RESUME — ✅ SQLite write P5/P6/P7 + query ORDER BY DONE; seed re-minted (2026-06-29). `main` = `ad22486`

Continued the SQLite library write path. Three bites landed, each verified vs the `sqlite3` CLI by the orchestrator with independent data; seed re-minted ONCE (P5 added an extern; P6/P7 were library-only), cold `bootstrap_from_seed` C3a PASS. Owning doc `SQLITE-WRITE-DESIGN.md` (updated through P7); design menu came from a read-only scout. Memory: `project_sqlite_capstone`.

- **P5 — REAL column write (`0bfc328`).** New extern `floatToBytes64 : Float -> Array Int` (exact inverse of `bytesToFloat64`), mirrored at its sites (`stdlib/runtime.mdk`, `runtime/medaka_rt.c` memcpy+BE-bytes, `compiler/backend/llvm_preamble.mdk`+`llvm_emit.mdk` `isNumExtern`, `compiler/eval/eval.mdk` host-delegating prim). `recordenc.mdk` encodes serial-type-7; `writer.mdk` gained `TReal`/`colTypeSql TReal = "REAL"`. Verified: `sqlite3` reports the column `real` and `sum()` over it is correct. **Bonus fix:** `pBytesToFloat64` (the READ-side interp arm) overflowed Medaka's 63-bit int for floats with MSB byte ≥ 0x40 (e.g. `3.14`) — rerouted through the host C `bytesToFloat64`; run==build now. Fixpoint C3a/C3b YES; goldens `runtime.{desugar,mark}` recaptured.
- **P6 — multi-page write (`aed32e3`, pure-library, `sqlite/lib/dbwriter.mdk`).** Removed the single-leaf cap. Rows bin-pack into leaf pages under ONE table-interior (0x05) root: page 1 = sqlite_master leaf (rootpage stays 2); single-leaf input keeps the OLD byte-identical 2-page output (degenerate path preserved); else page 2 = interior, leaves = 3..N, each non-rightmost leaf an interior cell `[4-byte BE child][max-rowid varint]`, last leaf in the header's right-most-pointer. Unbalanced (no redistribution — out of scope; `integrity_check` accepts valid trees). Verified vs `sqlite3` at 700/937/1000+ rows: `integrity_check` ok, leaf-crossing filters + aggregates correct. Gate `sqlite/test/multipage_write_oracle.sh` (≥3 leaves). All existing sqlite oracles re-run green.
- **Residual (write, deferred, clean `Err`):** overflow pages (single row > ~4088 B); multi-INTERIOR trees (≳tens of thousands of rows / ~450 leaves); full b-tree balancing; `UPDATE`/`DELETE`; transactions/journal/WAL.
- **P7 — multi-table write (`6c383d0`, pure-library `dbwriter.mdk`+`writer.mdk`).** N tables in one `.db`. Core refactor: per-table b-tree building parameterized by an absolute BASE page number (new `buildTablePages basePage batches`; interior child pointers + right-most-pointer are absolute final-file page numbers). New `buildDatabaseMulti` allocates page 1 = `sqlite_master` leaf with one record per table, then walks tables assigning contiguous page ranges (`rootpage` = range start, advance by `pageCountOf`). Single-table `buildDatabase` now routes through `buildDatabaseMulti [(…)]` → N=1 byte-identical (existing goldens unchanged). New public `writeTables`/`buildTables` in `writer.mdk`. Verified vs `sqlite3` at 3 tables mixed single-leaf+multi-page (rootpages 2/3/8 with my n=850 probe; cross-table JOIN + interior-page aggregate correct); gate `multitable_write_oracle.sh`. Residual clean-`Err`: sqlite_master records must fit ONE leaf page (~tens of tables; multi-page sqlite_master out of scope).
- **✅ ORDER BY DONE (2026-06-29, `98ad5e0`, pure-library):** `orderBy : Option (String, Bool)` field + `withOrderBy` builder on `Select`; executor sorts raw rows via `cellOrder` (SQLite type order NULL < Int/Float numeric < Text < Blob; DESC reverses → NULLs last) BEFORE offset/limit; `render` emits `ORDER BY col ASC|DESC` between WHERE and LIMIT/OFFSET. `select_oracle.sh` extended (ASC/DESC/NULL/TEXT/+LIMIT) — byte-identical to `sqlite3`.
- **Next clean SQLite bites:** `UPDATE`/`DELETE` (mutation — larger, multi-bite arc); WasmGC port of the bytes-first API (browser SQLite + a real soak of the just-hardened wasm emitter); async SQL server.

## RESUME — ✅ WasmGC E24-peer FIXED; #24 elevated (masks ALL real-prelude wasm) (2026-06-29). `main` = `d143972`

Closed the WasmGC parallel of E24 (the LLVM-E24 wasm follow-up that was carried "PENDING"). Emitter-only, no seed/fixpoint (wasm_emit.mdk is outside the self-compile graph). Ledger: EMITTER-GAPS.md **E24 → wasm residual NOW CLOSED**. Branch `fix/wasm-e24-hof-shadows-method`, commit `d143972` (merged to local main).

- **DIAGNOSE-FIRST overturned the filed repro.** The literal `pickEq (==) 2 3` `--target wasm` failure (`expected (ref eq) but nothing on stack` at `$mdk_impl_List_foldMap`) is **NOT a pickEq bug** — it's the SEPARATE pre-existing **#24** real-prelude point-free impl-arity gap, which blocks **EVERY** real-prelude modules-path program (verified: even `main = 5` fails identically). So #24 is more impactful than its "low pri" label suggested — it gates the entire `diff_wasm_modules` path (0 ok / 20 gap).
- **The genuine E24-peer** reproduces in the prelude-free path when a method-named HOF param ALSO collides with a top-level fn name and is applied: `eq a b = 999; pickEq eq x y = eq x y; main = pickEq (a b => a+b) 2 3` → oracle/LLVM `5`, wasm emitted `return_call $eq` (wrong top-level callee) → silent miscompile `999`. **Root cause (both `compiler/backend/wasm_emit.mdk`):** (1) `emitAppRef`/`emitAppTail` CVar arms resolved a head to a direct `call $<toplevel>`/ctor WITHOUT a leading `contains f0 env` check; (2) the closure-usage scan (`exprUsesClosures`/`appUsesClosures`, now thread a `locals` set; `stmtUsesClosures`→`blockUsesClosures`) didn't count a shadowing-local head → `$argarr`/`$clos` types undeclared → parse failure. **Fix:** both check `contains … env` FIRST (mirrors `emitVarRefPlain` + LLVM `isLocal`) → local head applies indirectly.
- **Gates (re-run by orchestrator under node v24):** `diff_wasm` 139/0, `diff_wasm_typed` 8/0 (new fixture `test/wasm/fixtures_typed/disp_hof_shadows_method.mdk`), `diff_wasm_modules` 0/20-gap/0-fail (unchanged), LLVM `diff_compiler_llvm` 186/0.

### ✅ #24 — wasm real-prelude point-free impl arity — DONE (2026-06-29, `fbbe633`)
foldMap-class impls emitted an UNDER-APPLIED `fold step empty` (missing the container arg) → `assemble_check` validate fail + `diff_wasm_modules` 0/20-gap, blocking ALL real-prelude wasm validation. **Root cause (confirmed by WAT probe):** `gatherImplGroup` (`wasm_emit.mdk` ~2782) computed the lifted `$mdk_impl_<tag>_<method>` define arity as `maxI (implGroupArity clauses) (methodArityOf m)` — but a point-free impl carrying a leading `requires` dict (`foldMap` requires `Monoid m`) has that `$dict_Monoid` counted in `implGroupArity` (=2: dict+f) while `methodArityOf "foldMap"`=2 is USER args only, so `max(2,2)=2` → eta no-op → container dropped → `$mdk_impl_List_foldMap` took 2 params but its body called `$mdk_impl_List_fold` (needs 3) with 2 → validate underflow. **Fix:** define arity now adds the leading dict count: `maxI (implGroupArity clauses) (methodArityOf m + nDicts)` (new `wLeadingDictPats`/`firstImplClausePats` helpers, reusing `wIsDictParamName`), mirroring LLVM `gatherGroup`. `nDicts=0` for dict-free point-free impls (`length`/`toList`) → unchanged. **Gates (orchestrator-reverified, node v24):** `diff_wasm_modules` **21/0** (was 0/20-gap — the foldMap blocker masked all 20), `diff_wasm` 139/0, `diff_wasm_typed` 8/0, LLVM 186/0. Fixture `test/wasm/fixtures_modules/rp_foldmap_list.mdk`. No seed re-mint (outside self-compile graph). **Residual (punch-list, non-blocking):** ~~the DEFAULT-define path (`emitDefaultDefineW` ~3027) has the same latent `maxI … methodArityOf` shape and would mis-size a point-free *default* with a leading dict, but its restamp logic already defers cross-interface method-level dicts and no current fixture reaches it — out of scope for #24.~~ ✅ NOW CLOSED (`e68365c`, 2026-06-29). The default-path twin DOES trigger — on a CROSS-MODULE impl of a prelude interface (`data Bag a; impl Foldable Bag` in a USER file → `fillImplDefaults` specializes prelude defaults same-module-only, so `foldMap`@Bag keeps the default fallback → routes through `emitDefaultRKeyRef`→`emitDefaultDefineW`, NOT the concrete `gatherImplGroup` path). Same fix: `arity = maxI (listLen pats0) (methodArityOf method + nDicts)`. No `restampCrossIface`/`reqDict` port needed — the wasm dict-pass already routes the cross-interface `empty` to the RDict dict param upstream (the deliberate wasm-vs-LLVM architectural difference; LLVM re-derives it in the emitter). Fixture `test/wasm/fixtures_modules/rp_default_foldmap_user.mdk`; `diff_wasm_modules` 21→**22/0**. **SIDE-FINDING (✅ NOW FIXED `6b86824`, 2026-06-29):** `medaka run` (eval.mdk interpreter) FAILED this same program with `no matching impl for dispatch` — a separate eval gap for CONSTRAINED cross-module unspecialized defaults (unconstrained `length`@Bag ran fine; constrained `foldMap`@Bag didn't). Root (instrumented): `pickByTag` returned the WHOLE VMulti when the Bag route tag matched no candidate, so every sibling specialized default (List/Option/Result) got applied to the Bag receiver → inner List-`fold` VMulti applied to Bag → hard panic before `collectPartials` could reach the real default. Fix: `pickByTag` now selects the untagged interface DEFAULT (bare VClosure/VThunk, never VTypedImpl) when no tag matches — mirrors LLVM `emitDefaultRKey`; arg-tag fallback preserved only when there's also no default. Eval-contained ~12 lines, fixpoint C3a/C3b YES, `diff_compiler_eval_typed_modules` 13/0, fixture `test/eval_typed_modules_fixtures/cross_module_default_constrained/` (loader path). run==build now.

## RESUME — ✅ #23 SIGTRAP FIXED (inferred-constraint iface-loss) (2026-06-28). `main` = `a57378b` (worktree branch, + seed re-mint)

Closed FACE 2 of the gap-3/slice-7/#23 cluster — the last run≠build silent miscompile in the cluster. `app2 f = f 2 3; main = println (app2 (==))` (and `useIt eqBoth`, the lambda form, and the transitive `useApp g = app2 g`) BUILT but exited 133 (SIGTRAP) while `medaka run` was correct. Memory: `project_gap3_slice7_two_distinct_bugs`. Ledger: EMITTER-GAPS.md **#23 / slice-7 SIGTRAP** (now CLOSED).

- **Root cause (diagnose-first overturned the handoff's framing).** The prior "`processSCC` defaulting reads only `pendingImplObligations`" framing was a SYMPTOM, and its "app2's constraint flows through `pendingDictApps` not `pendingCallObligations`" claim was empirically WRONG. Dumping the emit-path Core IR showed `main` → `(CDict "app2" (RNone RNone))` (two NULL dict words). The real cause: the inferred constraint's **iface name was lost** — `ifaceForConstraintId` only recovers the iface from a **bare-`TVar`** obligation occ, but a `fromInt`/method-site Num constraint records a **COMPOUND occ** → `""`. Empty iface ⇒ `routeUndeterminedTop ""` → silent `RNone` (not even the `AmbiguousImpl` error a real `"Num"` would raise), AND `recordCallObligations` skips empty-iface slots so defaulting never saw the var as Num.
- **Fix (typecheck-only, `compiler/types/typecheck.mdk`):** **(A) `ifaceForInferredId`** — when `ifaceForConstraintId` returns `""`, fall back to `schemeObligationsRef` (robust to compound occ; covers own-body literals) then a `pendingDictApps` slot scan (recovers a constraint FORWARDED from a constrained callee, `useApp g = app2 g`). Fallback-only ⇒ existing routes byte-identical. **(B)** `processSCC` Num-defaulting now also feeds the group's `pendingCallObligations`/`pendingDictApps` Num deltas (`numCallObls`/`numDictObls`) into `defaultGroupNum`/`defaultEachMember`, grounding the now-identifiable ambiguous var to Int BEFORE route resolution (→ `RKey "Int"`). The `not arg-reachable` filter still protects genuinely-poly vars (Float-pinned result stays Float).
- **Gates:** `diff_compiler_*` 68/68 (build gate 42/42 with new fixture `test/build_diff_fixtures/num_hof_ambig.mdk`); fixpoint C3a/C3b YES; cold `bootstrap_from_seed` PASS; seed re-minted; `medaka test` core 9/9 + list 12/12 (neq-hang canary clean). Controls (addBoth/twice/sumPair Float+Int/Int+Float-pinned/branch) unregressed.
- **LESSON:** the prior "next step" (ground via pendingDictApps delta) was necessary but INSUFFICIENT — the var was unidentifiable-as-Num (empty iface) until (A).

### ⏳ Still pending (carry forward)
- **WasmGC parallel of E24** — ✅ FIXED 2026-06-29 (`d143972`, see top RESUME).

## RESUME — ✅ E24 emitter name-shadowing FIXED; #23 SIGTRAP deferred (2026-06-28). `main` = `5942477` (worktree branch, + seed re-mint)

Re-diagnosed the gap-3/slice-7/#23 cluster on current main (`GAP3-SLICE7-DESIGN.md` was stale at `197e550`; the manifestation shifted post-#21/#22). The two brief repros are TWO DISTINCT bugs, NEITHER being the doc's `debug`/`sequence` arg-stamp framing. Memory: `project_gap3_slice7_two_distinct_bugs`.

- **FACE 1 — `pickEq eq x y = eq x y` build-reject — ✅ FIXED (E24, emitter-only LLVM).** A HOF PARAMETER named like an interface method (`eq`/`compare`/`cmp`/`show`/`map`) applied in the body was mis-routed by `llvm_emit.mdk`'s `emitApp` → `emitMethodArgDispatch` → arg-tag over primitive Int/String impl groups (no ctor cell tag) → `emitTagMatch []` slice-7. The emitter-side analogue of the front-end E15/E18 scope guards. Fix: `if isLocal env fname then emitIndirect` as the first check in `emitApp`'s CVar arm (mirrors `emitVar`'s isLocal-first priority). Fixture `test/build_diff_fixtures/hof_shadows_method.mdk`. Gates: 68/68 `diff_compiler_*` + 41 build + fixpoint C3a/C3b YES + cold `bootstrap_from_seed` PASS; seed re-minted. Ledger: EMITTER-GAPS.md **E24**.
- **FACE 2 — `app2 f = f 2 3; main = println (app2 (==))` SIGTRAP (#23) — ✅ NOW FIXED (2026-06-28, see the RESUME entry above).** ~~🔴 OPEN~~ The "Num-defaulting reads only `pendingImplObligations`" diagnosis here was a symptom; the real root was inferred-constraint iface-loss. Closed typecheck-only via `ifaceForInferredId` + processSCC call/dict-delta defaulting.

### ⏳ PENDING WasmGC FIXES (carry forward)
- **WasmGC parallel of E24 — ✅ FIXED 2026-06-29 (`d143972`).** See top RESUME entry. Was NOT the literal `pickEq (==)` repro (that's #24); the real bug was a method-named HOF param colliding with a top-level fn → `emitAppRef`/`emitAppTail` + closure-usage scan now check `contains … env` first.

## RESUME — ✅ sqlite dogfood review batch + 7 run≠build bugs (2026-06-27/28). `main` = `d843ae3` (+ seed re-mints)

A file-by-file review of the sqlite library produced a 10-task batch + flushed 7 run≠build compiler bugs (5 fixed across both backends, 2 deferred/filed). ALL merged + verified (full `diff_compiler_*` 0-fail, fixpoint C3a/C3b YES, cold `bootstrap_from_seed` PASS, every sqlite oracle byte-identical, wasm gates green under node v24). Memory: `project_sqlite_review_batch`.

**New language/stdlib features (run==build, fixpoint-verified):**
- **UTF-8 codec externs** — `stringToUtf8Bytes`/`stringFromUtf8Bytes` (expose the runtime String's UTF-8 backing / build a String from bytes) + `stdlib/string.mdk` `toUtf8`/`fromUtf8`/`utf8ByteLength`. Filled a real gap (string.mdk was codepoint-only).
- **Float `%` completed** — `%` was ~90% built; eval lacked the `VFloat` arm (run errored, build worked). Fixed via a `floatRem` extern (C fmod == LLVM frem). REPRODUCE-FIRST WIN — almost reimplemented a working operator.
- **Negative literal in application position** — `f -1` → `f (-1)` ("Rule C": lexer `TMinusTight` for `<space>-<digit>`; `parseApp` grabs it only when the head is non-numeric, so `5 -1` stays subtraction). All 6 `TMinus` parser sites broadened.
- **`Ordering` Eq/Ord** — fixed a run≠build bug (`o == Lt` check-accepted + run=True but BUILD FAILED; no Eq instance). Hand-written impls (the `Eq` constructor collides with the `Eq` class → `deriving (Eq)` ambiguous).
- **`bytebuilder.emitBeUint`** promoted (public unsigned mirror of `emitBeSint`).

**✅ FIXED (`0c7cb79`; `main` now `abc0769` + seed):** a user fn defining a CONSTRAINED free function whose name SHADOWS a prelude free function failed on `medaka run` with `unbound identifier: $dict_<name>_0` while `build` worked. DIAGNOSE-FIRST disproved the filed cause (joint dict-pass `collect_arities` bare-name keying — WRONG). Real cause: typecheck's `discoverPromotedModules` flattens `coreDecls ++ userModules` into one bare-name program for promotion discovery; the prelude's concrete `isEven : Int -> Bool` SIGNATURE pins the user's same-named fn to `Int -> Bool` there → never discovered constrained → no dict param at define, but the real per-module pass routes the body through `$dict_isEven_0` → unbound at run. Fix: `dropShadowedCore` (typecheck.mdk) drops shadowed core defs+SIGNATURES before discovery. **`isEven`/`isOdd` re-added to the prelude.**

**✅ ALSO FIXED — CDict/CMethod-as-value as a first-class HOF arg (run≠build), both backends:** a `=>`-constrained named fn / typeclass method passed UNAPPLIED to a HOF (`filter myParity [..]`) RAN but BUILD FAILED (`unsupported Core IR node CDict`) on LLVM, and mis-compiled on wasm. Fix: emit a **dict-capturing closure** for CDict/CMethod-in-value-position — LLVM `emitDictValue` (#21, `67c1b0b`), wasm via eta-expand-through-`emitClosure` (#22, `c300c9f`, both arms). EMITTER-GAPS **E23** (closed both backends). run==build (and ==wasm under node v24).

**🔴 OPEN follow-ups (both documented in PLAN open-issues + memory):**
- **#23 — slice-7 / gap-3 / ARGSTAMP-UNIFY** (DEFERRED by user decision): a typeclass method / constrained fn dispatched over a GENERIC or PRIMITIVE receiver via indirection. Two faces — call-site literals (`pickEq (==) 2 3`) → clean slice-7 BUILD REJECTION; HOF-body literals (`app2 f = f 2 3; app2 (==)`) → silent **runtime SIGTRAP** (built binary exits 133, run prints the correct value). Full fix = the decision-ready design `GAP3-SLICE7-DESIGN.md` (Fix A typecheck arg-stamp grounding + Fix B generic-receiver dict ABI, shipped together) — the "irreducible residual" `compiler/ARGSTAMP-UNIFY-PLAN.md` (COMPLETE) left. Cross-cutting, route-fragile → design-re-validate-first + staged. A standalone kickoff prompt for this exists (ask the last session, or reconstruct from GAP3-SLICE7-DESIGN.md). Closing it also re-enables generic prelude free fns (e.g. promoting `sequence`/`traverse` to free functions).
- **#24 — wasm real-prelude point-free impl arity** — ✅ FIXED 2026-06-29 (`fbbe633`, see top entry). `gatherImplGroup` define arity now adds the leading `requires`-dict count; `diff_wasm_modules` 0/20-gap → 21/0.

**What to do next:** #23 (ARGSTAMP-UNIFY — the substantive one; a design-ready doc + kickoff prompt exist) and #24 (wasm, low pri). Otherwise normal native-only dev / continued dogfood soak.

**Cleanups:** five dogfood libs (dbwriter/recordenc/select/writer/main) had each RE-ROLLED the stdlib list/string toolkit under a misapplied "no stdlib import — keep lightweight" comment (that's compiler-only) — all de-rolled to stdlib. Plus: select `cmp*`→prelude `compare`/`Ordering` + Select param-destructure/record-update; btree §12 constants + `pageHdrOffset` + `bStep`; `Display Cell` (recordfmt) / `Display Row` (btree) consolidation; rowtype `cellShape`→derived `debug`; dbwriter/recordenc adopted the MutArray `bytebuilder` Builder for sequential encoding.

**What to do next:** the `CDict`-as-HOF-arg emitter gap (run≠build) is the notable open item. Otherwise normal native-only dev / continued dogfood soak.

## RESUME — ✅ Internal-only array externs RESTRICTED behind `--allow-internal` (2026-06-27). `main` = `8e0390f` (+ seed re-mint)

Referencing `arrayGetUnsafe`/`arraySetUnsafe`/`arrayBlit`/`arrayFill`/`arraySortInPlaceBy` from a
non-stdlib module is now a resolve-phase compile error (`InternalExternAccess` in `compiler/frontend/resolve.mdk`)
unless `--allow-internal` is passed (run/build/check). User-driven (caught an agent using `arrayGetUnsafe`
in user code). Two staged agents, each independently verified + merged; seed re-minted; cold
`bootstrap_from_seed` C3a byte-for-byte PASS; fixpoint C3a/C3b YES; full `diff_compiler_*` 0-fail incl. new
`diff_compiler_internal_extern` 8/0.

- **Part 1 — enforcement (`1b94b42`, Opus):** trust is PER-MODULE via the loader's **owning root**
  (`stdlibTrustedMods` in `loader.mdk` — modId is NOT a reliable discriminator: `import array` → bare
  `"array"`); `--allow-internal` additionally trusts the entry project. New `InternalExternAccess` ResError
  (mirrors `PrivateNameAccess`). Guarded `*G` resolve variants thread `allowInternal` + trusted set; LSP/
  playground/REPL kept on the unguarded path → front-end goldens byte-identical. `__fallthrough__` EXCLUDED
  (compiler-generated by desugar → would false-flag every guard). KEY INSIGHT: the compiler self-compiles via
  the emitter entry (`llvm_emit_modules_main`), which never runs resolve, so `make medaka`/fixpoint/bootstrap
  need NO flag; only `build_oracles`' `medaka build` of compiler entries got it. The anticipated chicken-egg
  (every self-compile script needs the flag) did not materialize.
- **Part 2 — dogfood rewrites (`f2e6019`, Sonnet + orchestrator golden fix):** sqlite/parsec/byteparser
  rewritten off the unsafe externs to safe public API — reads `arrayGetUnsafe i arr` → `arr.[i]` sugar (no
  import); writes → `Array.set` (already in `stdlib/array.mdk`); region copies → a NEW safe bounds-checked
  `Array.blit` added to `stdlib/array.mdk`. sqlite oracles byte-identical (safe ops are exact equivalents).
  **VERIFY-DON'T-TRUST CATCH:** the agent reported "all diff gates 0 failing" but had botched the
  `stdlib/array.mdk` golden recapture (near-swap: `array.mark.golden` −112 / `array.lextok.golden` +102) → the
  `mark` gate actually FAILED. Caught on independent re-verify and fixed by regenerating from the native
  entries (mark/desugar/lextok are FROZEN families `capture_goldens.sh` skips; post-OCaml the native
  `test/bin/{mark,desugar,lex}_main` IS the reference — `mark_main core.mdk f.mdk | sed '$ s/()$//; ${/^$/d;}'`).

Memory: `project_internal_extern_restriction`. **Escape hatch:** advanced users / a project that genuinely
needs the unsafe primitives pass `--allow-internal`.

**What's next (unchanged from prior):** gap 3 (generic prelude free-fn slice-7, deferred by design); broader
dogfood/library work (the soak thesis). No active fire.

## RESUME — ✅ FIVE `run≠build` codegen bugs FIXED (2026-06-27). `main` = `b9739ee` (+ seed re-mint)

A reproduce-first sweep (while re-checking the already-DONE L2 structured-dict task) surfaced four
distinct bugs where `medaka run` (interpreter, the correct oracle) was right but `medaka build`
(native LLVM) miscompiled — `medaka check` accepted all four. A fifth (List `.[]` index/slice — the
sibling of Bug 3) was found while verifying the handoff. They survived self-compile because the
compiler's own source never uses these forms. **All five are now fixed**, each diagnose-first,
independently gated (fixpoint C3a/C3b YES + the relevant `diff_compiler_*` 0-fail), and merged;
**seed re-minted, cold `bootstrap_from_seed` C3a byte-for-byte PASS.** Per-bug result (run==build on
every repro now):

- **Bug 3 — String `.[]` index/slice (`493a5eb`):** typecheck stamps a receiver-kind discriminator
  (AST `Ref String`, the `EBinOp` Route idiom) → new `CStringIndex`/`CStringSlice` Core IR nodes
  (leaves `CIndex`/`CSlice` + the hot array emit arms byte-identical) → UTF-8/codepoint-aware string
  emit. Filed root cause HELD. Residual (separate pre-existing gap, untouched): **List**-index on
  build still on the array path; wasm string-index hits its existing catch-all.
- **Bug 1 — comparison operators on a bare constraint tyvar (`7450cf6`):** top-level constrained
  operators now route the enclosing fn's forwarded class dict via a new `enclDictVarOf` keyed on
  `funConstraintsRef[encl]` (the enclosing fn's OWN declared constraint slots, by fn name — NOT the
  global `activeDictVars`, which is the line between a legit constrained operand and a stale
  cross-impl id collision). The `inImpl` gate was too coarse. Filed root cause HELD. No D7 re-key
  (D7 not observably broken). Real-world: `HashSet`/`HashMap` membership of non-primitives now correct.
- **Bug 2 — partial/escaping method closure dict capture (`95ee25b`):** filed `freeVars`-miss
  hypothesis REFUTED — two emitter holes on the RDict/RDictFwd path: (A) `emitMethod` dispatched
  under-applied dict-routed methods as saturated → new `emitMethodPap`; (B) closure-returning
  constrained fns eta-saturate to `dict+args+__eta` but call sites under-supply → a new define-arity
  table `defArityOf` (signature arity ≠ define arity; the fnArity shortcut broke self-compile). All 7
  case-matrix rows incl. the hardest (bare escaping return) build==run. Ledger: EMITTER-GAPS.md **E22**.
- **Bug 4 — poly-Unit main spurious `0` (`9f83b42`):** main's zonked result type WAS reachable —
  `mainSchemeRef` (the channel backing `mainTypeIsAsync`). New `mainTypeIsUnit` (normalize the scheme
  → `TCon "Unit"`) threaded to the emitter via `installMainIsUnitHint`, consulted by `mainIsUnit`.
  Value mains still auto-print (no `pp_value` regression). Root cause HELD.
- **Bug 5 — List `.[]` index/slice (`b9739ee`):** the sibling of Bug 3 for **List** receivers
  (`[10,20,30].[1]` → run `20`, build garbage; index 0 worked only by offset coincidence). Typecheck's
  `indexKind` already stamped `"List"`, so AST/typecheck needed no change; mirrored Bug 3's option B —
  new `CListIndex`/`CListSlice` Core IR nodes (Array `CIndex`/`CSlice` hot path byte-identical) emitting
  two new C runtime externs `mdk_list_index`/`mdk_list_slice` that walk cons cells, matching the
  interpreter EXACTLY (negative index → head; past-end → `@mdk_oob` panic; slice clamps, no panic).

**Common thread:** three of four were "type/dict info known at typecheck but lost or not-threaded at
emit" — the same class as the historical float-arith bugs (`project_arith_on_typelost_floats_bug`).
Memory entries: `project_string_index_slice_emit_bug`, `project_comparison_operator_forwarded_dict_bug`,
`project_partial_method_closure_dict_capture_bug`, `project_polymorphic_unit_main_autoprint_bug`.

**Reproduce/build (read `AGENTS.md` first):** warm build `make -C <worktree-root> medaka` (needs
`./medaka_emitter`); `./medaka run f.mdk` vs `MEDAKA_ROOT=<root> MEDAKA_EMITTER=<root>/medaka_emitter
./medaka build f.mdk -o /tmp/out && /tmp/out`. Verification bar for any backend fix: a fixture driving
the BUILD path with run==build==correct; all `diff_compiler_*` 0-fail; `selfcompile_fixpoint.sh`
C3a/C3b YES; then re-mint the seed (`sh test/refresh_seed.sh`) + `bootstrap_from_seed.sh` cold PASS.
`FORCE=1 bash test/build_oracles.sh` before trusting any `test/bin/*` gate.

**What's next (verified current 2026-06-27):**
- **gap 3 (generic prelude free-fn slice-7)** — genuinely DEFERRED by design (`GAP3-SLICE7-DESIGN.md`,
  zero current callers, the "irreducible primitive residual" scheduled in `ARGSTAMP-UNIFY-PLAN.md`).
  Needs cross-cutting Fix A (arg-stamp grounding) + Fix B (generic-receiver dict ABI) shipped together.
- **broader dogfood/library work** — the recurring soak thesis (a real library flushes real bugs); the
  String/List `.[]` bugs were exactly this class. The `.[]`-on-other-containers question is now settled
  (String, Array, List all build==run); a future dogfood may surface a Map/Set/other index path.

The **D2 fn-level cross-module dict-arity collision is CLOSED** (`6e73a15`/`d759765`, on main) — routes
by import-source module identity. Only a *purely hygienic* AST-origin `EVarFrom` re-key remains (no
observable bug; just retiring the bare-name fallback for the wildcard/re-export corner). Not a priority.

## RESUME — 🏁 OCaml reference compiler REMOVED + `selfhost/`→`compiler/` rename (2026-06-26). `main` = `f6ff59d`

**The soak tail is DONE: the OCaml `lib/` is deleted and the compiler source dir is renamed. Medaka is now a single, native, self-hosting compiler with no OCaml anywhere.** Memory: `project_ocaml_removed_selfhost_renamed_compiler`. Design/scoping: `LIB-REMOVAL-DESIGN.md`. Tag `oracle-frozen` preserves the last `lib/`-present commit.

**Why now:** making `sequence` a default method (entry below) put `identity` in a default-method body the frozen OCaml resolver couldn't bind → the oracle could no longer typecheck the prelude, so its differential value was already gone. User decided: proceed to removal. Seed-mint independence was verified first (`test/refresh_seed.sh` uses the native emitter; no OCaml blocker).

**Staged, each gated + merged (orchestrator re-verified cold bootstrap + fixpoint independently):**
- **A+B (`a3f2e05`)** — de-OCaml'd the kept gates: re-rooted `diff_compiler_check_json`/`check_policy` to native committed goldens; stripped the OCaml leg from `effect_hole`/`effect_param`; deleted the `doc` differential gate. (User chose: re-root json+policy, drop doc.)
- **`oracle-frozen` tag** on `a3f2e05` (the last lib/-present commit).
- **C+D (`06356a8`)** — `git rm -r` `lib/`+`bin/`+`gen/`+`dev/`, 18 `test/test_*.ml`, `test/thorough/`, all dune stanzas, `dune-project`, Makefile `reference:` target (−46k lines). Re-pointed `capture_goldens`/`bench`/`profile`/`refresh_seed`/`diff_native_cli` off OCaml. Cold `make clean && make emitter && make medaka` + `selfcompile_fixpoint` C3a/C3b YES, independently re-run.
- **F (`fa5983c`)** — `git mv selfhost compiler` + `selfhost`→`compiler` token sweep (incl. docs) + 67 `diff_selfhost_*.sh`→`diff_compiler_*.sh` + lockstep golden updates. **Seed re-mint REQUIRED** (the build-driver entry's usage-string literal embeds the path → emitted IR changed). `selfcompile_fixpoint` C3a passed current-vs-current but strict `bootstrap_from_seed` caught the committed-seed drift; re-minted native, cold C3a PASS byte-for-byte. **LESSON: `selfcompile_fixpoint` C3a does NOT detect committed-seed staleness — only `bootstrap_from_seed.sh` does; run it after any string-literal/path change to the build-driver graph.**
- **E (`f6ff59d`)** — semantic docs reframe: AGENTS.md/README.md/PLAN.md now describe the native-only `compiler/` pipeline (the old OCaml `lib/` pipeline tables/build instructions are gone). `.claude/skills/` + the triage hook path updates are a follow-up in flight.

**Carried-over PRE-EXISTING gate debt — ✅ NOW CLEARED** (recapture pass `357e2ad`/`e6409e5`/`c5bf490`, golden-only, fixpoint C3a/C3b YES). All three families were diagnosed BENIGN (no native bug) and recaptured: `diff_native_cli` `check/` (~57 → **93/0**; the diff was uniformly the `sequence`/`traverse` prelude-method signature-dump lag, NOT OCaml drift); `bootstrap_resolve` (~15 → **15/0**; OCaml-sexp error tags → native human-readable, same errors/locations, none dropped); `bootstrap_typecheck` (2 → **12/0**; `index_default`/`poly_let` — native defaults Num-poly literals to `Int` and is strictly more precise/sound than the un-defaulted OCaml goldens). These were NOT caused by the removal/rename (C3b-proven semantically null).

**What to do next:** normal native-only dev. The big architectural cleanup is complete. Open items unchanged: gap 3 (generic prelude free-fn slice-7), fn-level D2 `EVarFrom` re-key (deferred), broader dogfood/library work.

## RESUME — `sequence` default method + UNIVERSAL default-method specialization (2026-06-26). `main` = `f333125`

**The `sequence`-per-impl residual is closed *principledly*, and the mechanism generalizes. Seed re-minted, cold `bootstrap_from_seed` C3a PASS. ⚠️ This change retires the OCaml oracle in practice — see the consequence below.**

Five-commit arc (all merged, each gated + reproduced on the binary):
- **B — emit dict-source (`066b9ea`):** `emitDispatchChain` sources a dispatched impl-method's
  method-level `=>` constraint dict (`traverse`'s `Thenable m`) from the caller's ambient dict arg, not
  an OOB dispatch-cell load → fixes the user-file generic free-fn build SIGSEGV.
- **Universal default-method specialization (`8a9aa3e`):** new `fillImplDefaults` desugar pass
  (`compiler/frontend/desugar.mdk` + `lib/desugar.ml` mirror) synthesizes a concrete-receiver per-impl
  copy of every same-module interface default into each impl that omits it. A default that
  *sibling-dispatches on the receiver* (`sequence ta = traverse identity ta`) thus gets a concrete
  receiver (RKey) and works. Closes the whole class. Design: `TRAVERSABLE-DEFAULT-METHOD-DESIGN.md`.
- **`sequence` as a default (`f6c7f33`):** moved into the `Traversable` interface; 3 per-impl copies deleted.
- **Emitter dict-threading for *literal* universal (`6ae5248` + guard removal `265b0a2`):** two more gaps
  blocked specializing Ord/Foldable — (1) `typecheck.mdk registerImplRequires` keyed every method under
  one impl tyvar id (encl-blind first-match → wrong witness; fixed with encl-aware
  `activeDictVarForEncl`), (2) `llvm_emit.mdk gatherGroup` eta-expanded eta-short defaults to
  `methodArityOf`, dropping leading dict params (fixed: include dict pats). **Bonus: fixed a pre-existing
  parametric `Ord` soundness bug** — `max [1,2] [1,3]`→`[1,2]`. Then the Ord/Foldable blocklist was removed.
- **Verification (orchestrator-independent):** fixpoint C3a/C3b YES; `diff_compiler_build` 36/0 (foldMap
  fixture green), `_llvm` 183/0, `_eval_dict` 28/0, `_typecheck`/`_errors` 12/40, **`_typecheck_golden`
  57/0** (I recaptured these — the agent had mislabeled them "pre-existing"; they were the benign
  `sequence`/`traverse` prelude-scheme ripple, verified uniform across all 57); core 38 doctests + 9 props,
  list 63 + 12; `run == build` on `sequence`/`clamp`/parametric-`max`/`foldMap`.

**⚠️ CONSEQUENCE — the OCaml oracle no longer typechecks the prelude.** `sequence` as a default puts
`identity` in a default-method body the frozen OCaml resolver can't bind (`core.mdk:764: Unbound
variable: identity`), so `_build/default/bin/main.exe check <anything>` now FAILS. Foreseen (design §7),
accepted (native-canonical; all native gates rerooted off OCaml and green), but the OCaml-pipeline gates
(`@thorough`, dune unit suites) are now broken for **all** prelude-using programs — the oracle is
effectively retired for typecheck/eval. **This brings the `lib/` removal decision forward** — worth
raising next session: the soak's differential-oracle safety net is largely gone, so either accept and
proceed toward `lib/` removal, or (if the oracle's value is still wanted) fix the OCaml resolver to bind
`identity` in default bodies (un-freezing `lib/`).

**Gap 3 (OPEN, dodged):** a truly generic *prelude free function* over a typeclass with a
generic/primitive receiver still fails `build` (slice-7 `arg-tag dispatch on impl type that owns no
constructors`). Specialization dodges it (concrete receivers); only bites a future generic prelude
free-fn. Filed in PLAN. Memory: `project_generic_monadic_dispatch_gaps` (updated).

**What to do next:** continue the soak; raise the `lib/`-removal question (see consequence above). Other
open items unchanged: gap 3, fn-level D2 `EVarFrom` re-key (deferred), broader dogfood/library work.

## RESUME — F1b loader module-identity + CFieldAccess (abstract-export diagnostic) BOTH CLOSED (2026-06-25). `main` = `542be47`

**Two backlog items closed; seed re-minted twice at checkpoints; cold `bootstrap_from_seed` PASS. Clean soak checkpoint.**

- **F1b loader module identity — ✅ DONE (`cf8e12d` core + `33972aa`/`ac4b04a` realpath, seed `6a1a67e`).**
  The cross-package double-load (same file under two import spellings → `conflicting impl`) is fixed
  **loader-contained**: the loader rewrites every `DUse` to one canonical dep-name-prefixed modId derived
  from where the import resolves (`canonicalModId`/`rewriteDecls` in `compiler/driver/loader.mdk`), so both
  spellings collapse BEFORE resolve/typecheck/eval (which stay string-keyed and were NOT touched —
  containment is the whole point, fixpoint-verified). Single-root loads = provable no-op. The exotic
  **two-dep-NAMES** corner (same file under two different dep names) is ALSO closed via a new
  `canonicalizePath : String -> <FileRead> String` realpath extern (`33972aa`: `runtime.mdk` +
  `medaka_rt.c` + `llvm_preamble`/`llvm_emit` + `lib/eval.ml` parity) that realpath-normalizes roots so the
  first-declared name wins. Native-only (no oracle mirror). Design: `F1B-MODULE-IDENTITY-DESIGN.md`. GOTCHA:
  a *compiler-used* extern makes the standard `selfcompile_fixpoint` fail on the stale seed (chicken-egg) —
  verify via re-mint + cold bootstrap. Gates: `cross_project_twonames` 3/3, `cross_project_deps` 3/3,
  fixpoint YES.

- **CFieldAccess cross-module record dot-access — ✅ RESOLVED as a NON-BUG + diagnostic fix (`4710d3a`
  resolve + `e3e7e1b` typecheck, seed `542be47`).** The filed "native emitter panics `CFieldAccess`" was
  DOUBLY stale (gap-docs-lie): it's a typecheck/resolve rejection (emitter never reached) AND the canonical
  compiler is CORRECT — cross-module record fields work with `public export data` (or the `record` keyword).
  The repro tripped on `export data` being **abstract by design** (exports the type name, not its fields).
  Real fix = the misleading diagnostic: both destructure (resolve, local signal: type in `env.types` owns
  no fields) and dot-access (typecheck, needed threading — abstract tycon names reach neither `recordsRef`
  nor `dataParamKindsRef`; a whole-program `abstractRecordTypesRef` is overwrite-seeded by the multi-module
  check drivers) now say `'Point' is exported abstractly; … declare it \`public export\` to expose its
  fields.` Native-only. A SIGSEGV (2nd under-applied `fieldVerdict` caller) was caught + fixed mid-flight.
  Fixtures: `test/eval_typed_modules_fixtures/cross_module_record_fields/` +
  `test/resolve_module_fixtures/abstract_record_field/`. Memory: `project_abstract_export_field_diagnostic`.

**What to do next:** continue the soak. Outstanding open items: the `sequence` per-impl dispatch
residual (the default-method/generic-free-fn forms still misdispatch — `traverse`/`sequence` ship as a
`Traversable` typeclass, gap 1 turned out oracle-only and is closed), the fn-level D2 `EVarFrom` re-key
(supervised, deferred), and broader dogfood/library work. The `lib/` removal soak tail continues.

## RESUME — D2 method-constraint + export-import re-export CLOSED (2026-06-25). `main` = `a35c87b`

**Two soundness fixes landed, sealing the last cross-module method-dispatch gap and general re-export support.**

- **D2 cross-module method-constraint dict mis-dispatch CLOSED (`221af36`).** Non-prelude sibling-module
  interface methods carrying a USER `=>` constraint (the `btraverse : Thenable m => …` / `foldMap` shape)
  mis-dispatched cross-module: `check` silently accepted, `run` panicked, `build` SIGSEGVd. Root: NOT the
  bare-name collision the `EVarFrom` re-key targets — it was **stale-sweep first-match shadowing**:
  `methodConstraintsRef` accumulated multiple entries per (uniquely-named) method from successive elaborate
  sweeps; `crossModuleMethodConstraintsRef` wasn't re-keyed, so bare first-match returned a STALE entry
  with ids disjoint from the live instantiation subst → empty dict route. Fix: read-side
  `alignedMethodConstraintIds` helper in `recordMethodDicts` (`compiler/types/typecheck.mdk`). The fn-level
  `EVarFrom` re-key (`compiler/WS2-REKEY-DIAGNOSIS.md`) remains deferred (separate collision class).
  Fixture: `test/eval_typed_modules_fixtures/cross_module_method_userconstraint/`.

- **`export import` re-export seed gap CLOSED (`a35c87b`).** A value/fn/method re-exported through an
  intermediate module via `export import` was `Unbound` at the downstream importer. Root: `publicValNames`
  collected only DEFINED names; `DUse` fell through its catch-all → a re-export-only module seeded an empty
  `pubV` into typecheck's `depEnv`. Fix: `reexportSeed prog depEnv` helper (typecheck.mdk) walks `DUse True`
  decls, threads each re-exported member's scheme by IDENTITY (no re-generalization — preserves original-definer
  constraint ids so `221af36`'s alignment stays diamond-safe), appended to `pubV` at all four driver loops.
  General (value/fn/method), transitive, no private-name leak. New fixture:
  `cross_module_method_userconstraint_diamond/` (leaf→mid→main via `export import`). Design doc:
  `REEXPORT-METHOD-SCHEME-DESIGN.md` (committed). Design record: `D2-REKEY-DESIGN.md` (also committed).

**Gates (all green, `a35c87b`):** `diff_compiler_eval_typed_modules` 8/0, `diff_compiler_eval_dict` 28/0,
`diff_compiler_typecheck_errors` 40/0, `diff_compiler_build` 36/0, `selfcompile_fixpoint` C3a/C3b YES,
diamond + 4-module chain verified run AND build. Seed re-minted (batched). `diff_native_cli` 57-failing =
pre-existing baseline (stale `check/*` Alternative+ordering goldens), unchanged.

**What to do next:** continue the soak. The outstanding pre-existing open items are the fn-level D2
`EVarFrom` re-key (supervised, deferred), F1b loader module-identity, and `CFieldAccess` cross-module
dot-access. The `sequence` default/free-fn dispatch residuals (from the Traversable session) are still
open but do not block any feature.



## RESUME — ✅ RESOLVED 2026-06-25: the 3 return-position-`pure` dispatch gaps (`Traversable` shipped). `main` = `1e889fe` (historical)

> **STATUS: DONE — kept for the diagnosis record.** All three gaps below were closed on 2026-06-25
> (`b5ae3a2` + `bf7243c` + `104c69a`, seed `da2469d`); `traverse`/`sequence` are now a real
> `Traversable t` typeclass in `stdlib/core.mdk`. The key correction: **every filed symptom had
> shifted** — gap 1 was an oracle-only artifact (already correct on native, no code change); gap 2
> was a native-`build` SIGSEGV (CDict-spine eta-saturation, NOT the filed `[[1,2,3]]` which was the
> oracle); gap 3 was a native-`run` panic (unregistered impl-body method-level constraint dicts).
> Gaps 2/3 were **distinct roots**, not the one shared root predicted below. Residual: `sequence`
> ships per-impl (default-method/free-fn forms still misdispatch). See PLAN.md → Compiler / language
> and memory `project_generic_monadic_dispatch_gaps`. The original framing follows for the record.

**This is the task to start on.** Adding generic `traverse`/`sequence` to the stdlib (dogfooding the
sqlite library, which had a hand-rolled `mapResult`) surfaced **three related compiler dispatch gaps**,
all in the same area: **return-position `pure` dispatch through the dict-passing machinery**. They are
filed as three OPEN items in **PLAN.md → "Compiler / language"** (+ the Open issues index table) and in
memory **`project_generic_monadic_dispatch_gaps`**. Fixing them (likely one shared root in the
dict-pass/typecheck/eval seam) would unblock promoting `traverse`/`sequence` to a real `Traversable t`
interface AND fix a latent `foldMap` bug.

**What shipped (working, on `main`):** `traverse : Thenable m => (a -> <e> m b) -> List a -> <e> m (List b)`
and `sequence : Thenable m => List (m a) -> m (List a)` as **free functions in `stdlib/list.mdk`**
(`4ff3b68`); sqlite uses `traverse` (`mapResult` deleted). 67/67 list doctests, native run, all sqlite
oracle suites green, `diff_compiler_test list` byte-identical. The functions carry inline warning comments
pinning the workaround forms — **do not "simplify" them** (each simplification re-triggers a gap below).

**The three gaps (ordered easiest→hardest to reason about):**
1. **Multi-clause generic-`pure` overflow.** A generic `Thenable m =>` self-recursive fn whose body has a
   return-position `pure`, written as SEPARATE clauses (`t f [] = pure []` / `t f (x::xs) = …`),
   **stack-overflows in eval**; the single-clause inner-`match` form works. Bisected: it's the
   multi-clause-ness itself (NOT the `<e>` row, NOT the fn arg, NOT generic-recursion-with-`pure` alone).
   Confirmed on the OCaml oracle; **native repro UNVERIFIED** — step 0 is to check whether native also
   overflows (native dict-passing differs). Suspect: multi-clause desugar (clauses → one tuple-matching
   lambda) × dict-passing of the leading dict on the recursive self-ref.
2. **Point-free constrained binding mis-dispatch.** `sequence = traverse identity` (point-free) returns
   `[[1,2,3]]` (List's `pure`) instead of `Some [1,2,3]`; **eta-expanding** to `sequence xs = traverse
   identity xs` fixes it. A CAF with no argument to anchor the `m` dict defaults to the wrong instance.
3. **Per-method-constraint dict conflation — THE `Traversable` blocker.** Generalizing to `interface
   Traversable t requires Mappable t, Foldable t` with `traverse : Thenable m => …` (exactly the shape of
   `Foldable`'s `foldMap : Monoid m => …`) **typechecks but mis-evaluates**: when the method dispatches on
   a container `t` that is ITSELF a `Thenable` (List), the per-method `m` dict is bound to the
   *container's* Thenable, so return-position `pure` lifts into the wrong monad
   (`traverse (Some-fn) [1,2,3]` → `[[1,2,3]]`). **Not source-workable** — delegating the impl body to a
   free helper that takes `m`'s dict explicitly STILL fails (method gets the wrong dict before forwarding).
   `foldMap` is the same latent shape, just never exercised this way. The interface IS expressible (no
   language-capability gap) — it's purely an eval/dict dispatch bug. Repro recipe: re-add the `Traversable`
   interface + List/Option/Result instances to `stdlib/core.mdk` (after the `Foldable` impls, ~line 731)
   and `medaka test stdlib/core.mdk` — the `Some [1,2,3]` doctests FAIL with `[[1,2,3]]`, the `None`
   short-circuit cases pass. (This was tried + reverted this session; it's clean to reconstruct.)

**Likely shared root:** all three are the dict-passing machinery failing to thread/distinguish the correct
dictionary for a return-position method/`pure` — gap 3 is the sharpest (a per-method constraint dict vs an
in-scope instance of the same class for the dispatch type). Fix lands in `compiler/` (dict_pass / typecheck
/ eval) and must mirror into the frozen `lib/` oracle for gate parity. **Verify gap 1 reproduces on native
first** before assuming all three are oracle-only. **Reach for the `debug-pipeline` skill** + instrument
eval's `EVar`/`EMethodRef`/`EDictApp` resolution arms (the technique that nailed Phase 134 — see AGENTS.md
Gotchas). **Payoff when fixed:** promote `traverse`/`sequence` from `list.mdk` to a `Traversable` interface
in `core.mdk` (List/Option/Result/Array instances) + a correct `foldMap`.

## RESUME — 🏁 SQLite READ **+ WRITE** library complete + a long soak run (2026-06-24). `main` = `e68913a`

**Medaka now READS and GENERATES real `.sqlite` files** — a database it builds from scratch passes
`sqlite3 PRAGMA integrity_check`, and `sqlite3` queries/aggregates over it. This session extended the
read-path capstone with full **v1 write support** plus a long soak run that flushed five real
compiler/tooling bugs. Owning docs: **`SQLITE-WRITE-DESIGN.md`** (write design + byte-format map + slice
log), `SQLITE-DESIGN.md` (read). Every landing was reproduced on the binary, gated, merged; **seed is
CURRENT** (re-minted at `6053bc3`; cold `bootstrap_from_seed` PASS; all subsequent slices were pure-library
so no re-mint pending).

**SQLite WRITE v1 (P0–P4, all merged):** `writeFileBytes` extern (`a97e34b`, 5 sites incl. `llvm_preamble`,
re-minted); `byteparser/lib/bytebuilder.mdk` byte builder (`75ccf95`); `sqlite/lib/recordenc.mdk` record
encoder (`c4b9731`); `sqlite/lib/dbwriter.mdk` byte-perfect single-page writer (`691baa1`); `sqlite/lib/
writer.mdk` typed `CREATE TABLE`+`INSERT` API (`4e582a6`). int/text/null/blob, IPK-as-rowid or auto-rowid,
single leaf page (clean `Err` on overflow). Each slice `sqlite3`-verified (integrity_check + SELECT +
Medaka-reader round-trip). **Deferred (write):** floats (needs a `floatToBytes64` extern); page
splits/multi-page; `UPDATE`/`DELETE`; overflow pages; transactions/journal/WAL.

**Compiler/tooling bugs the dogfood surfaced + FIXED this session:**
- **Native method-shadow run≠build soundness bug** (`96529b3`) — a user fn shadowing a prelude interface
  method (`eq`/`gt`/…): `check` wrongly rejected, `run` silently dispatched to the *prelude* method (wrong
  answer), `build` was correct. Fixed both facets (check prelude-isolation + eval dispatch precedence) to
  match the oracle. Found via the Phase-2 phantom-`Expr` design.
- **`arrayBlit`/`arraySetUnsafe` missing from the native interpreter** (`ecd2eee`) — `MutArray.push` panicked
  under `run`/`test`, worked under `build`+oracle. Added to `compiler/eval/eval.mdk`.
- **Loader cross-package relative-import resolution, F1** (`ec8c19c`) — a dependency module's intra-package
  `import lib.X` now rebases to the dep root (+ transitive deps). Native-only (cross-project deps are
  native-only).
- (earlier soak) 6 deferred dogfood findings fixed (#1–5, #8), #6 documented; the inline-`let`-missing-`in`
  located diagnostic (`8686e26`).

**Diagnosed + BACKLOGGED (PLAN open-items, full diagnoses there):**
- **F1b** — loader does NOT canonicalize module identity: the same file under two import spellings
  (`lib.byteparser` vs `byteparser.lib.byteparser`) double-loads → `conflicting impl`. NOT loader-contained
  (path-dedup at load breaks `resolve.mdk`'s string-keyed `findExports`); needs a cross-cutting
  loader+resolve+typecheck module-identity change (Option A canonical dep-prefixed modId rewrite, or B
  path-based identity end-to-end). The agent STOPped per guardrail with a clear scoping. **Impact:** the
  shared `bytebuilder` can't be used alongside `recordenc`; the write path stays self-contained.
- **`CFieldAccess` cross-module record dot-access** — ✅ RESOLVED 2026-06-25 (`e3e7e1b`; see top RESUME).
  Was a non-bug (canonical compiler correct with `public export`); the filed emitter-panic framing was
  stale. Original note: ~~emitter panics on `r.field` for an imported record; workaround = destructure.~~

**Also this session (earlier):** stale-gate hygiene — 4 stale-golden gates fixed (`diff_compiler_check`
17/57→74/0, `desugar`/`mark` 98/1→99/0, `lex_files` 12/1→13/0; all un-recaptured-golden debt from prior
sessions). 2 PRE-EXISTING failing gates filed (`effect_hole` 4/4 — a possible capability-soundness gap, WS-2
territory; `lsp_b4` 1/1 completion-env). SQLite **float read path** (`tFloat` coerces `CInt`, per SQLite's
REAL-as-integer affinity) + **Phase-2 typed query ADT** (`Select`/`SqlExpr`/phantom `Expr a`/injection-safe
`render`/ADT-driven `query`).

**NEXT (clean bites):** write float columns (P5, needs `floatToBytes64` extern — a 4-site fixpoint cycle);
then the harder write phases (page splits/multi-page → `UPDATE`/`DELETE`). Or a fast-follow: WasmGC SQLite
in the browser (bytes-first API makes it additive), async SQL server. Or tackle a backlogged bug (F1b
module-identity; the `effect_hole` capability-soundness divergence).

**METHODOLOGY notes:** (1) the dogfood thesis held all session — building a real read+write library flushed
5 genuine bugs the corpus never hit; lean into it. (2) Every "fix the X" turned out deeper than framed
(method-shadow was 2 facets not applied-params; F1 was really F1+F1b) — the DIAGNOSE-FIRST + STOP guardrail
caught each; re-surface the corrected scope to the user before forcing. (3) Verify every landing on the
*fresh binary* (run `sqlite3 integrity_check` yourself), not the agent's prose — agents committed to
self-named branches (`sqlite-phase2-select`) and to a SHARED branch despite isolation; merge by reported
SHA + confirm `MAIN_CONTAINS`. (4) Adding an extern/stdlib decl ripples to `runtime.{desugar,mark}` goldens
— recapture. (5) Seed currency: P*-pure-library slices don't stale the seed; check `git log <lastmint>..main
-- compiler/ lib/ stdlib/ runtime/` before deciding to re-mint.

## RESUME — 🏁 SQLite read-path library v1 COMPLETE (dogfood capstone) (2026-06-23). `main` = `de44b58`

**A pure-Medaka SQLite library reads real `.sqlite` files of any size and returns TYPED Medaka values,
byte-identical to the `sqlite3` CLI.** This was a soak/dogfood capstone (user idea): build a real library
to flush compiler bugs + exercise IO/parsing/the type system. Owning doc: **`SQLITE-DESIGN.md`** (scope,
phasing, RowType API, effects, slice plan, all decisions). PLAN.md hub row updated. Every landing was
reproduced on the binary, gated, and merged; **all emitter-graph changes fixpoint-verified; seed re-minted
(`848f712`), `bootstrap_from_seed` cold-start PASS.**

**Landed (in order):** `readFileBytes` + bitwise externs (`1b25c9b`, fixpoint YES — String is NOT byte-clean,
so binary IO needs this); `byteparser/` binary parser-combinator lib (`986bbd4`, own project); **cross-project
`[dependencies]` in the native loader** (`0ad8ae9`, fixpoint YES — a real gap the capstone surfaced + closed:
`medaka.toml [dependencies] name = "../path"`, resolved in `compiler/driver/loader.mdk`); file-format reader
(`6657238`); multi-page B-tree interior-page traversal (`86b1ffa`); typed `RowType` combinators + SELECT
executor (`8d4c39c`, the Caqti no-GADT model — phantom param + closure decoder); INTEGER PRIMARY KEY rowid-
substitution fix in the typed path (`ccd650a`); `bytesToFloat64` extern + un-stub `beFloat64` (`359957a`,
fixpoint YES); library hygiene — stdlib de-dup + STYLE §8 multi-clause (`de44b58`).

**What works:** open a real DB → header → B-tree (leaf + interior) → records (NULL/8–64-bit int/text/blob) →
`sqlite_master` schema → SELECT with a typed `RowType` + optional predicate → `List` of typed Medaka records,
IPK rowid correct. Float **decode** works (`bytesToFloat64`/`beFloat64`); 31+ doctests; differential oracles
vs `sqlite3` (`sqlite/test/{oracle,multipage_oracle,typed_oracle}.sh`).

**NEXT (all pure-library, clean first tasks):** (1) wire `tFloat` into `RowType` (now `bytesToFloat64` exists);
(2) float columns (serial-type 7) in the reader's record decoder; (3) Phase-2 **ADT query model** (`Select`/
`SqlExpr` sum types + injection-safe `render` + phantom-typed `Expr a`). **Fast-follows** (PLAN tasks): WasmGC
port (bytes-first `fromBytes : Array Int -> Result String Db` API makes it additive — browser SQLite +
capability-wedge demo) + async SQL server (the real `<Net>`/async forcing function; SQLite itself is sync).

**Deferred / parked:** 8 dogfood compiler findings (PLAN.md → Known parser gaps: `record` keyword blocks a
`record.mdk` module; `/=` mis-lex w/ misleading error; layout parse error w/ leading-`let`+multiline-if;
multi-line `->` sigs; spurious non-exhaustive on partial record patterns; in-module doctest parse error;
OCaml-oracle-only false-reject on `let`-bound width in a phantom-poly body — native correct; `intBitsToFloat`
≥2^61 literal emitter overflow). All have workarounds. A **`medaka lint`** future workstream was filed
(PLAN.md) for issues detectable-but-inappropriate-for-`fmt` (the STYLE §8 immediate-match→multi-clause that
was hand-cleaned here is the motivating case).

**METHODOLOGY learnings (important):** (1) **Verify-with-your-OWN-data, not the agent's fixtures.** The IPK
bug (`ccd650a`) typechecked + ran but failed on any `INTEGER PRIMARY KEY` table — the agent's fixture used a
plain `INTEGER` id and hid it; a 1-minute hand-probe with my own schema caught it. (2) **`isolation:"worktree"`
is NOT reliable** — agent #11 (`bytesToFloat64`) committed to the SHARED orchestrator branch (`orch-sqlite`)
despite an isolation request, and rode into `main` under a later docs merge **unverified**. ALWAYS, before
merging ANY branch (including your own working branch), check the FULL commit range (`git diff --stat
<merge-base>..<tip>` + `git log`), not just the commit you think you made. I caught it post-merge and verified
(fixpoint YES) but it could have shipped unverified. (3) Cross-project deps + a dep importing stdlib both
work (proven by the `minilib` gate + parsec). (4) For user libraries, the no-stdlib rule does NOT apply
(that's compiler-only) — they SHOULD import stdlib; the de-dup pass fixed this.

## RESUME — Formatter hardening (3 fmt bugs + style rules) (2026-06-23). `main` = `966b546`

**Dogfooding `fmt` on `parsec` surfaced + fixed 3 formatter bugs and settled 2 style rules.** All
NATIVE-ONLY: `printer.mdk`/`fmt.mdk` are OUTSIDE the emitter self-compile graph (so no fixpoint for
them); the one in-graph helper `util.mdk` had its seed re-minted (`5a1f3be`, `bootstrap_from_seed`
C3a PASS). The `diff_compiler_fmt`/`_printer` goldens are **native-sourced** (reroot made them
native-vs-native), so each fix recaptured them and the frozen OCaml `lib/fmt.ml` was left alone.
Memory: `project_formatter_doc_ir` (updated). Authoritative detail: PLAN.md top formatter block.

- **fmt bug — inner-block comment relocation** (`838f21d`): trailing comments on a bare block's inner
  statements (all but the last) were dumped below the block; `fmt.mdk` now splices them back inline by
  source-line. (Both compilers had it; native-only fix since goldens are native-sourced.)
- **fmt bug — nested if/else-if collapse** (`226f139`): an `else`-position `if` was flattened to one
  >80-char line; now ladders (`else if … then` cascade, recursive, width-respecting).
- **fmt bug — head-alone wrapping** (`226f139`): an overflowing single-arg application isolated its
  head (`Parser`/`orElse` alone); now keeps `= head (…` inline and breaks inside the argument.
- **`::` tight everywhere** (`9c14bcb`, STYLE §9): expression-position cons now matches patterns; only
  `::` affected (`+`/`++`/`==` stay spaced). User decision; Medaka has no user-defined operators.
- **STYLE §10 — `export` on its own line** above a value signature is INTENTIONAL (Idris-style; reviewed
  and kept, documented so it isn't "fixed" as an inconsistency). `export data`/`export impl` collapse.
- **Regression fixture** `test/fmt_fixtures/wrap_elseif_headarg` gates the two wrapping fixes (no prior
  golden coverage); `diff_compiler_fmt` 45/0.
- **`parsec` formatted** (`b9cd7b3`), semantics unchanged (run==build byte-identical).
- **Deferred (cosmetic):** import overflow = one-per-line; fill-to-width is a possible future tweak.
- **METHOD note:** the `diff_compiler_fmt` golden being native-sourced is what makes these native-only
  (no need to touch frozen `lib/`). Verify that for any future fmt change. Also: when adding a fmt
  fixture, `capture_goldens.sh fmt` writes only the new fixture's golden (others byte-identical) —
  clean, no corpus churn.

## RESUME — Block-expressions inside brackets LANDED (2026-06-23). `main` = `5e041ab`

**`match`/`do`/`function`/`record` blocks can now sit directly inside `( ) [ ] { }`** — the layout wart
that forced `parsec` to lift every `=> match` body into a named helper. Grew out of the dogfood session
below. Design + LOCKED scope: `LAYOUT-BRACKETS-DESIGN.md`; spec `LAYOUT-SEMANTICS.md §6.1`; memory
`project_layout_brackets`. Staged, each gated + merged; seed re-minted (`bootstrap_from_seed` C3a
byte-for-byte PASS; fixpoint C3a/C3b YES throughout).

- **Design pass** (read-only Plan agent) reproduced the boundary, wrote the design. CAVEAT: it claimed
  "two gates" with the grammar excluding block forms — Stage 1+2 EMPIRICALLY DISPROVED that half via
  `menhir --interpret` (match/do/function/record already parsed in brackets via `expr_no_block→expr_lam`;
  only the bare-`INDENT` block was a real grammar gap). Reproduce-before-trust beat the design doc again.
- **Stage 1+2 grammar** (`2ca1df3`) — added a contained `bracket_block` nonterminal in both `lib/parser.mly`
  and `compiler/frontend/parser.mdk`, **zero new Menhir conflicts** (5→5).
- **Stage 3 lexer** (`8abe0aa`, the crux) — a **bracket-frame stack** in BOTH lexers, byte-identical:
  free-form is the default inside brackets; a herald (`isOpener`: match/do/function/record) arms a nested
  layout context, closed on dedent-≤-herald-col OR the matching closer (force-flush pending DEDENTs).
  Free-form continuation UNCHANGED — `diff_compiler_lexer`/`bootstrap_lex` 57/0 (the byte-identical-lexer
  invariant held). bare-`INDENT` block DEFERRED (no keyword to arm it without regressing free-form).
- **Dogfood payoff** (`5e041ab`) — reverted 6 `parsec` helpers to inline bracketed blocks, byte-identical
  output.
- **Deferred (by design):** `let…in` & `if/then/else` inside brackets; bare-`INDENT` block; closer on its
  own line after a herald block (grammar shape — closer must be on the last arm's line).
- **METHOD:** the design→staged-by-ascending-risk→isolate-the-lexer playbook worked; the grammar was
  isolated from the lexer so the crux was localizable. Two agent self-assessments needed orchestrator
  correction (the grammar misread above; earlier the loader-in-emitter-graph claim) — verify load-bearing
  claims yourself.

## RESUME — Dogfood parser-combinator library + 4 bugs it surfaced (2026-06-23). `main` = `5855012`

**A soak session driven by building a REAL library** (user goal: dogfood important language features).
Built `parsec/` — a char-level parser-combinator library + a TOML parser on top — which surfaced four
genuine compiler/tooling bugs the test corpus never hit. All reproduced on the binary, gated, merged;
seed re-minted (`bootstrap_from_seed` C3a byte-for-byte PASS; fixpoint C3a/C3b YES). Authoritative
detail: PLAN.md top "## Current status (2026-06-23) — dogfood soak session 2"; memory
`project_dogfood_parsec`.

- **The library** (`03720e7`/`40dd1d2`/`50da658`/`5fc6ee8`): an `Alternative` typeclass (`noMatch` +
  `orElse`, **named methods, NO `<|>` operator** — user wants Medaka leaner than Haskell on operators)
  in `stdlib/core.mdk` + `List`/`Option` impls; `parsec/lib/parser.mdk` (`Parser a` with
  Mappable/Applicative/Thenable/Alternative + do-notation + the usual combinators); `parsec/lib/toml.mdk`
  + `toml_demo.mdk`. Run==build byte-identical throughout — higher-kinded dispatch holds across the
  tree-walker and native codegen.
- **Finding #1 (`521a96e`)** — run/build accepted programs `check` rejects: the guard checked only
  `hadTypeErrors`, so RESOLVE-phase errors slipped past run/build. Now run/build gate on resolve errors
  before eval/emit. Closes the long-open "emit lacks a hadTypeErrors guard before codegen" for the
  resolve channel.
- **Finding #2 (`521a96e`)** — native multi-module `check` raw-ADT-printed resolve errors; now all 18
  `ResError` variants render humanely, byte-identical to the oracle.
- **Finding #1b (`a987a7a`, unmasked by #1)** — the compiler source violated its own Phase-148
  contiguity rule (`eval`/`declSexp` split by intervening decls; `dropS`/`clauseArity`/
  `isDictParamName`/`startsWithStr` were dead DUPLICATE defs). Made contiguous / removed dups —
  fixpoint-proven behavior-preserving. (METHOD NOTE: the fix agent first mis-diagnosed this as a
  resolver false-positive; reproduce-before-trust — `evalMethodAt` genuinely sat between two `eval`
  clause blocks — corrected it.)
- **Finding #3 (`e2846d0`)** — `medaka test` couldn't resolve project-sibling imports (doctests in a
  `medaka.toml` project importing a sibling failed `unknown module`). Two bugs: `loader.mdk`
  `findProjectRoot` returned `""` for a bare dir name (walk-up stopped); the doctest path keyed the root
  module by last-path-component not full dotted id. NOTE: `loader.mdk` IS in the emitter self-compile
  graph (`llvm_emit_modules_main` imports it) — required fixpoint + seed re-mint (the agent wrongly
  thought it wasn't; orchestrator caught it).
- **Golden cleanup (`766cca7`)** — recaptured `core.{desugar,mark,lextok}` goldens left stale when Stage
  A added `Alternative` to core.mdk (only `core.test.golden` had been recaptured). **LESSON: a
  `stdlib/core.mdk` edit ripples to the WHOLE per-stage golden suite (desugar/mark/lextok/sexp), not just
  `test` — recapture all + run those gates at the merge.**

**Soak status:** four real bugs found+fixed this session → the soak clock effectively continues (good
dogfood = real-program use keeps surfacing bugs). `lib/` stays frozen. The `parsec/` project is itself a
reusable soak asset — extend it (more TOML/JSON/expr parsers) to keep flushing bugs.

## RESUME — 🏁🏁 SERVER-FREE BROWSER PLAYGROUND LANDED (2026-06-22). `main` = `7d59a70`

**The Medaka compiler, compiled to WasmGC, now runs IN THE BROWSER — the playground compiles +
runs Medaka entirely client-side, no backend.** This realizes the `WASM-SELFHOST-ROADMAP.md` §1
goal. Owning docs: `playground/README.md` (living), `PLAYGROUND-DESIGN.md` (§6.1 now SUPERSEDED —
the compile-server/container plan is obsolete; ships as a pure static site). Memory:
`project_playground_workstream` (authoritative). User-verified in a real browser (Chrome + Firefox):
compiles+runs `15`/`[2,4,6,8,10]`/greeting AND surfaces diagnostics.

Built in 5 staged agents (all merged, native-canonical, NO fixpoint/seed — playground entry +
wasm_emit are OUTSIDE the self-host graph; the decisive checks are the Node round-trip + the
browser smoke):
- **Stage 0** (`c56f224`) — `playground/build_compiler_wasm.sh` self-compiles the emit entry to
  `dist/compiler.wasm` (2.3MB, assembles+validates+round-trips). GOTCHA: self-compiling the emitter
  needs BOTH roots `compiler stdlib` (emitter imports `stdlib/hash_map` via dce.mdk).
- **Stage 1** (`0e3d6cf`) — browser WAT→wasm assembler `playground/vendor/wat2wasm/` (Rust `wat`
  crate **=1.252.0**, exact lineage match to native wasm-tools; wasm-bindgen blob ~708KB COMMITTED →
  static site has no Rust dep). Rust toolchain installed this session (cargo 1.96, ~/.cargo).
- **Stage 2** (`e1363f6`) — COMBINED entry `compiler/entries/playground_main.mdk`: front-end runs
  ONCE; outputs `__MEDAKA_DIAGNOSTICS__`+JSON (errors, byte-identical to `check --json`) or
  `__MEDAKA_WAT__`+WAT (clean). WHY: the emit entry's error path compiles to a SILENT `unreachable`
  trap (0 bytes out) — errors must route through the panic-free analyze path; emit runs only after a
  clean analyze. `playground/compile.mjs` = env-agnostic seam. Node round-trip 4/4 (orchestrator-verified).
- **Stage 3** (`2c512c8`) — fully client-side: `compiler-worker.js` (compile+assemble off UI thread)
  → `main.js` (fetch 4 assets once) → `worker.js` runner (10s kill-timer). `server.js` stripped to
  STATIC-ONLY (no /compile/subprocess) — the visible "no backend" change. Node integration 8/8.
- **Stage 4** (`e95da8c`) — docs (README/PLAYGROUND-DESIGN/WASM-SELFHOST-ROADMAP/PLAN) + `build_site.sh`
  (assembles deployable `playground/site/`).

**2 browser-smoke fixes (orchestrator, on main):** `84b98d5` — the WasmGC feature-detect probe was a
MALFORMED module (func-body length prefix 6, actual 7) → `WebAssembly.validate` false on EVERY engine
→ false "unsupported" banner (validate hardcoded wasm probes in Node 24!). `277b1f3` — default sample
used `do` (IO-monad trap, correctly rejected) + `(* 2)` op-section (compiler-parser-rejected) → fixed
to a valid bare-block (always compile-test a shipped default).

**Build/run:** Node ≥22 for finalized WasmGC (system node v20 FAILS); browser Chrome≥119/FF≥120/Safari≥18.2,
**iOS<18.2 has NO WasmGC** (page banners). dist assets gitignored. **NEXT (none blocking):** real CDN
deploy (build_site.sh + upload); purist option-b (WAT→binary encoder IN Medaka, drop the wat2wasm blob)
deferred as a later backend milestone. Static dev server may still be running on :8080 from this session.

## RESUME — 🏁 WasmGC SELF-HOST PUSH: front-end EMITS+ASSEMBLES+VALIDATES; lexer RUNS (2026-06-22). `main` ≈ `a889a23`

**The active workstream + the big result of this session.** Drove the WasmGC backend toward
self-hosting the compiler (the frontend-only-playground goal). Owning doc:
**`compiler/WASM-SELFHOST-ROADMAP.md`** (authoritative status + the gate commands). Memory:
`project_wasmgc_backend`. Every landing below was reproduced on the binary, gated, and merged.

- **🏁 Per-binding emitter-gap census 1428 → 0.** Built a gap-record census mode
  (`compiler/entries/wasm_emit_gaps_main.mdk` + `enableGapRecordW` in `wasm_emit.mdk`) over the
  whole compiler graph (`all_modules_entry.mdk` + `compiler` root). Closed **9 categories**: panic
  + array intrinsics; Ref (`$refbox`); `__fallthrough__` (label encoded in the Core-IR node, NOT a
  mutable ref — the emitter is LAZY, forces strings at final assembly); string-literal clause heads
  + charCode; destructuring/refutable/assign let-binds; UTF-8 codec externs; **nested-closure
  free-var capture** (THE key fix — `freeVarsExpr` lacked compound-value-node arms (CTuple/CRecord/…)
  so do-notation `pure (a,b)` dropped earlier `<-` binds); structural batch (Char/String match-switch
  heads, ctor/tuple lambda-params, record-ctor registration via `registerRecordCtors` in
  `lowerProgramEmit` — the ONE in-graph change, fixpoint + diff_compiler_build verified); char-class
  externs; **IO host surface** (readFile/fileExists/args/getEnv/exit via length+byte-at-a-time host
  imports, `run.js` shim with a swappable vfs seam for the browser). diff_wasm 85→130.
- **🏁 Whole-program LINKAGE closed + VALIDATE_OK.** `check_main.mdk` (the real
  lex→parse→resolve→exhaust→typecheck front-end) emits a **6.77 MB WAT** that now `wasm-tools parse`s
  AND `validate`s. Linkage fix: `scanFnValueUses` had the SAME compound-value-node hole as
  `freeVarsExpr` (value-uses in CTuple/CRecord/CRecordUpdate missed → closure-wrapper ref to an
  undefined fn). Validate layer (peeled class-by-class): eta-saturate plain constrained fns
  (`elem=fold…`), ctor-as-value eta-closures, and the litswitch phantom-`if`-result-in-nested-tower
  bug. Gate: **`test/wasm/assemble_check_main.sh`** (ASSEMBLE_OK + VALIDATE_OK).
- **🏁 The self-hosted LEXER and PARSER RUN under Node.** Runtime layer-1: `debugStringLit`/
  `debugCharLit` were stubbed to `unreachable` but the real lexer quotes every token — added a real
  WAT escape runtime byte-identical to `lib/eval.ml`. Runtime layer-2 (parser): top-level nullary
  value globals (CAF combinator ladder, `parseAppend = chainl1 parseAdd …`) were init'd in SOURCE
  order → a forward-referenced global was still `ref.null` when read (`ref.as_non_null` trap). Fixed
  by **topo-sorting value-global inits by EAGER (non-closure) deps** (ported the LLVM backend's
  `eagerVars`/`orderedValBinds`; the subtlety: do NOT descend lambda bodies — closures resolve globals
  at call-time, so only non-lambda refs are init-order deps). `lex_main`/`parse_main` run under Node.
- **🏁 Runtime layer-3 FIXED — `check_main` now INSTANTIATES + parses args + enters the check logic.**
  The "illegal cast" was list `++` miscompiled as STRING append: `emitBinRef "++"` hard-wired
  `$mdk_str_append` + `ref.cast (ref $str)` (a documented W8 gap), so `buildOracle`'s
  `flatMap dataTypeCtors prog ++ builtinTypeCtors` (list `++`) cast a `$C_Cons` to `$str` → trap.
  Fixed with a runtime-shape-dispatching `$mdk_append` (`$str`→str-append, i31-Nil/`$C_Cons`→recursive
  list append), mirroring LLVM's `@mdk_append`. **Also fixed the `run.js` args delimiter** (was split
  on `\0` — uncarryable in an env var, collapsing multi-arg to one; now `' '`) → the `args()` bug noted
  below is RESOLVED. `check_main`: 3 args reach `withFiles`, check logic runs. (`377365f`, gates 130/6/13
  + VALIDATE_OK.)
- **🏁 Runtime layer-4 FIXED (`f9c9bc3`) — the `singleOp` `unreachable` trap is gone; the self-hosted
  LEXER now lexes `runtime.mdk` fully (749 tokens) byte-identical to the native oracle.** Root: a
  UTF-8 codepoint-count bug in `$mdk_io_result_to_str` (`wasm_preamble.mdk`) — it rebuilt a `$str`
  from the host readFile buffer with `cp_count = byte_len` (a "deliberate approximation"). But
  `$mdk_str_to_chars` allocates its output `Array Char` to `cp_count` and the lexer reads
  `arrayLength src` as the char count, so for multibyte UTF-8 (e.g. an em-dash `—` = 3 bytes / 1
  codepoint in a `runtime.mdk` comment) the decoded array was padded with trailing `\0` chars → a
  stray codepoint-0 fell through every lexer clause head into `singleOp`'s `panic` → `unreachable`.
  Fixed by counting true UTF-8 lead bytes (`(b & 0xC0) != 0x80`) for `cp_count`, mirroring the peer
  `$mdk_chars_to_str`. Emitter-only (`wasm_preamble.mdk`) → no fixpoint/seed. Gates 130/6/13 +
  VALIDATE_OK, all re-verified on freshly-rebuilt binaries.
- **🏁 Runtime layer-5 CLOSED — the WasmGC TRMC arc (Stages 0–2) — the self-hosted lexer now runs to
  COMPLETION under Node.** The blocker was `RangeError: Maximum call stack size exceeded` in the lexer's
  token-list build. Design pass (`compiler/WASMGC-TRMC-DESIGN.md`) diagnosed it as **shape (b′):
  dispatch-into-single-target TMC** — each per-token leaf scanner does `RTok … :: scan …`, so the
  cons-bearing frame stays live to EOF while the recursion target is the single dispatcher `scan`
  (neither the LLVM self-recursive TRMC shape nor general mutual recursion). Fixed via a 3-stage,
  **emitter-only** TRMC port (the existing LLVM TMC is `compiler/TRMC-DESIGN.md`):
  - **Stage 0 (`8c69296`, seed re-minted `6bbcde8`):** made WasmGC cons/ctor recursive struct fields
    `mut` (destination-passing prereq) + lifted the backend-agnostic TRMC analysis out of `llvm_emit.mdk`
    into shared `compiler/backend/trmc_analysis.mdk` (pure code-move; fixpoint C3a/C3b YES — the ONE
    in-graph change of the arc).
  - **Stage 1 (`8737d11`):** WasmGC self-recursive destination-passing TMC (shape a). A 2M-cons builder
    goes from Node call-stack overflow → prints `2000000` with 0 recursive calls in the loop. Gate
    `test/wasm/fixtures/w_trmc_deep_cons.mdk`, `diff_wasm` 131.
  - **Stage 2 (`2688edb`):** the novel **dispatch-into-single-target (b′)** TMC (no LLVM precedent) —
    `detectDispatchGroups` grows a `scan`-rooted TMC group (49 members on the real lexer); each spine
    cons leaf becomes cons-into-dest + `return_call $scan__disploop` (the dest carried in 3 module
    globals, `return_call` IS the loop). Gate `w_trmc_dispatch.mdk` + `DISP-ASSERT` (0 recursive
    `call $scan`), `diff_wasm` 132. **Verified on the binary:** `check_main` now lexes `runtime.mdk`+
    `core.mdk` fully under Node (flat `tokenize→parse→runCheck` trace, no `scan`-recursion tower).
  - All Stage-1/2 work is **emitter-only** (`wasm_emit.mdk` is out of the compiler graph) → no
    fixpoint/seed. Regression gates green throughout (132/6/13 + VALIDATE_OK).
- **🏁 Runtime layer-6 CLOSED (`a332da7`, emitter-only) — `stringToFloat` ported; `check_main` runs
  PAST `floatTok`.** The deferred float-codec extern (`isDeferredFloatExternW`, was `unreachable`) is now
  implemented via a HOST SEAM — the inverse of `floatToString`'s `mdk_float_fmt`: a `mdk_str_to_float`
  import (`run.js`, JS `Number()`) + a WAT runtime `$mdk_string_to_float` that pushes the `$str` bytes
  through the IO path channel, gets an f64, boxes it into `Option Float`. Byte-identical to the native
  `strtod` oracle (`stringToFloat "3.14"` → `Some 3.14`; gate `test/wasm/fixtures_modules/w_string_to_float.mdk`,
  `diff_wasm_modules` 13→14). Wired into `isStrExternW`/`externArityW`/`emitStrExternRef` (removed from
  the deferred stubs). All gates green (132/6/14 + VALIDATE_OK). **Verified on the binary:** `check_main`
  no longer traps at `floatTok` — the trap moved deeper (the next layer).
- **🏁 Runtime layer-7 CLOSED (`f96cd10`, emitter-only) — `stripComments` no longer overflows;
  `check_main` runs past the lexer entirely.** Root: `wasmTrmcTry` required `wTrmcAllPVarParams` (all
  clause params plain PVar/PWild), so `stripComments`' list/ctor pattern params (`[]`/`(RComment _
  _)::rest`/`r::rest`) failed the gate → ordinary clause-dispatch → cons-tail self-call inside
  `struct.new` → overflow. Fix (all `wasm_emit.mdk`): dropped the all-PVar gate (`trmcEligible` already
  vets the clause set); `emitWasmTrmcFn` now emits the clause-dispatch chain with the TMC context LIVE
  for multi-clause/patterned builders (each tail leaf TMC-aware: cons-into-dest / plain-tail-drop / base);
  `wTrmcSelfIdxClauses` scans all clauses for the ctor-tail. **Second real bug fixed:** lifted lambdas
  (`emitLamDefine`/`emitLgLifted`) under a live TMC context leaked `$__tmc_first`/`$tmcloop` into
  functions that don't declare them (invalid wasm) → save+clear the TMC ctx before a lifted body. Gate
  `test/wasm/fixtures/w_trmc_strip_clauses.mdk` + S1B-ASSERT (0 recursive `call $strip`), `diff_wasm`
  133. **Verified:** `check_main` runs past `stripComments` (authoritative run.js trace).
- **🏁 Runtime layer-8 CLOSED (`a76c8b3`, emitter-only) — dispatched `List map` impl-method TMC;
  `check_main` runs through the lexer/layout and into the parser.** The WasmGC self-TMC reached only
  top-level fn binds, not dispatched `$mdk_impl_<tag>_<method>` emission. Fix (`wasm_emit.mdk`):
  generalized `emitWasmTrmcFn`→`emitWasmTrmcCore` (self-ref-agnostic; the only `SelfByVar`-specific bits
  were the self-ref + func-symbol render); added `wTrmcImplTry` (the `trmcImplTry`-analogue, `SelfByMethod
  method tag`) tried by `emitImplGroup` before the ordinary impl body. Reused the existing dest-passing
  machinery verbatim. **Safety net verified:** `mdk_impl_List_map` (cons IS the result) TMC's → 0 self
  calls; `mdk_impl_List_ap` (self inside `++`, non-tail) correctly stays ordinary (the `mentionsSelfMethod`
  walk rejects it — `freeVars` is blind to the `CMethod` name). Gate `w_dispatch_map_stack.mdk` +
  TMC-ASSERT, `diff_wasm_modules` 15. Closes the whole dispatched list-builder class (map/ap/…).
- **🏁 Runtime layer-9 CLOSED (`bab91b2`, emitter-only) — ref-mode comparison miscompile; `check_main`
  runs past the parser into resolve.** BROAD fix (not just `coalesceStep`): `emitBinRef`'s else-branch
  lowered EVERY comparison (`==`/`!=`/`<`/`>`/`<=`/`>=`) as an i31 compare (`ref.cast (ref i31)` +
  `i31.get_s`), but `String ==` operands are boxed `$str` structs → `ref.cast` to i31 traps `illegal
  cast` (Core IR is type-erased — no static type to distinguish `String ==` from `Int ==`). Fix: new
  `$mdk_value_eq`/`$mdk_value_cmp` (`wasm_preamble.mdk`, mirroring LLVM's `@mdk_value_eq`) that dispatch
  on runtime shape (both `$str` → byte-compare; else `ref.eq`/i31 compare); `emitBinRef` routes
  comparisons through them when the program uses strings (`useStrRef`), pure-int keeps the i31 fast path.
  Same shape as layer-3. Gate `str_value_eq_cmp.mdk`, `diff_wasm` 134.
- **🏁 Runtime layer-10 CLOSED (`117a30f`, emitter-only) — refutable NESTED ctor in a function-clause
  head; `check_main` runs past resolve into typecheck.** `variantFieldOwners (Variant cname (ConNamed
  fs))` — `patTestBind`'s `PCon` arm emitted a discriminant test only for the OUTER ctor (`Variant`) then
  descended fields via `bindConFields` which only BINDS (cast+`struct.get`), NO refutability test → the
  nested `ConNamed` cast was unconditional and trapped on a `ConPos` sibling. Fix (`wasm_emit.mdk`):
  descend each field with `patTestBind` (test+bind) via `patTestBindCon`, mirroring `PCons`/`PTuple`/`PList`.
  Gate `w_clause_nested_ctor.mdk`, `diff_wasm` 135.
- **🏁 Runtime layer-11 CLOSED (`9095462`, emitter-only) — synthetic-param/clause-binder name collision;
  `check_main` runs past unification into application inference.** BROAD fix: the multi-clause ABI named
  positional params `$a0/$a1/…` (`synthParams`), but a clause-head pattern var spelled `a1` emitted
  `local.set $a1` and CLOBBERED the second arg's local before it was read → `unifyN`'s `TFun` clause cast
  field-1-of-arg1 to `$C_…TFun` and trapped (TApp had the same latent bug). Fix (`wasm_emit.mdk`):
  `synthParams` emits reserved `$__wparg<i>` + `gname` escapes any user `__wparg<digits>` → distinct from
  every clause-bound var. Gate `clause_param_name_collision.mdk`, `diff_wasm` 136.
- **🏁🏁 Runtime layer-12 CLOSED (`faef8fa`, emitter-only) — MILESTONE: the self-hosted FRONT-END runs
  on WasmGC byte-identical to native.** Root: a `match <Bool>` that lowers to a `CDecision` switch (not an
  `if`) got a **0-slot `br_table`** with both arms dropped, because `ctorsOfType "Bool"` returned `[]`
  (True/False are SYNTHETIC ctors, never in the program's ctor table) → `nOrd=0` → empty tower → fell
  through to `unreachable`. Fix (`wasm_emit.mdk`, 1 arm): `ctorsOfType "Bool" = ["False","True"]`
  (index-aligned to `syntheticCtorOrdinal`). BROAD — every `match <Bool>` lowering to a decision-switch was
  mis-compiled. Gate `match_bool_decision.mdk`, `diff_wasm` 137. **VERIFIED ON THE BINARY (orchestrator,
  independently):** `check_main` (lex→parse→resolve→exhaust→typecheck) compiled to WasmGC runs to COMPLETION
  under Node on `inc x = x+1`/`main = inc 41`, printing all 88 prelude+user schemes (`eq : a -> a -> Bool` …
  `inc : a -> a`, `main : Int`) **byte-identical to the native compiled `check_main` oracle** — the ONLY diff
  is a trailing `0` (the Unit-main auto-print residual below). This is the `WASM-SELFHOST-ROADMAP.md` layer-12
  "diff schemes vs native = self-host-of-the-front-end demo" — MET.
- **🏁 layer-13 CLOSED (`e7cd369`) — check_main WasmGC output EXACTLY byte-identical to native** (trailing
  Unit-main `0` gone; `mainBodyIsUnit` now descends `match`/`block` bodies, approach B). Verified byte-identical.
- **🟢 EMITTER ON WasmGC — THE PUSH IS ON (the whole-compiler / browser-playground goal).** Recon: the
  frontier is a SMALL number of emit/linkage layers (NOT a 12-layer peel — the emitter reuses the front-end's
  fixed codepaths). Progress:
  - **🏁 layer-14 CLOSED (`ab269d6`, emitter-only) — nested requires-dict cell.** `routeWitness` gapped on
    `RKey tag [reqs]` (the `__tuple2__` from `Debug (HashMap k v)`). Ported `llvm_emit.mdk:2896`'s uniform
    nested-dict-cell rep BOTH sides: `$dictcell (struct (field i32) (field (ref $dictarr)))` (a one-level dict
    stays an i31); emit via `routeWitness`, consume via `readDictParam` (i31-vs-`$dictcell` `ref.test`) +
    `loadReqDict` (nested `struct.get 1`/`array.get`). **Emitter census now 0/0** (orchestrator-verified). Gate
    `w_nested_dict_tuple.mdk`, `diff_wasm_modules` 16.
  - **🏁 layer-15 CLOSED (`fbf1da0`, emitter-only) — defaulted-method emission; the full emitter
    ASSEMBLES + VALIDATES.** `Filterable List` inherits `filter` as an interface DEFAULT (only `filterMap`
    concrete) → `RKey "List"` had no `$mdk_impl_List_filter`. Ported llvm's default subsystem
    (`emitDefaultRKey`:3029 / `ensureDefaultEmitted`/`emitDefaultDefine`:3043 / `innerDefaultReqCount`:3292):
    synthesize `$mdk_default_<method>_<tag>` once (`emitDefaultDefineW`/`ensureDefaultEmittedW`), eta-expand
    the point-free default to full arity, `restampIfaceDictsW` rewrites the inner `filterMap` to `RKey tag []`.
    **ORCHESTRATOR-VERIFIED:** the full emitter emits 418,863-line WAT → `wasm-tools parse` OK (0 undefined
    `$mdk_impl_*`/`$mdk_w_*`/`$mdk_default_*`) → `wasm-tools validate` OK (2.3 MB wasm). Gate `rp_filter_list.mdk`,
    `diff_wasm_modules` 17. Deferred (would surface as new undefined symbols, not needed for filter@List):
    cross-iface method-level dicts (foldMap's Monoid `empty`), parametric element `requires` (Ord `lt`→`compare`).
  - **🏁🏁 layer-16 CLOSED (`ca2cdc5` step1 + `e9dd965` step2) — THE EMITTER RUNS ON WasmGC.** The two
    non-tail-recursive list-JOIN overflows (depth ≈ total WAT lines) are gone: **step 1** (`$mdk_append`,
    emitter-only) → iterative destination-passing loop via the `mut $C_Cons` tail (mirrors native
    `mdk_list_append`); **step 2** (`intersperseStr`, IN-GRAPH `support/util.mdk`) → single-self-call
    tail-recursive accumulator (`interspGo`+`reverseL` → `return_call`, byte-identical output; fixpoint
    C3a/C3b YES; seed re-minted). **ORCHESTRATOR-VERIFIED on the binary:** the WasmGC-compiled emitter runs
    end-to-end under Node, compiles `println (1+2)` to a 52,443-line WAT, **that wasm-emitted program
    assembles + runs + prints `3`** — the WasmGC backend compiles a Medaka program to a working module
    entirely in WasmGC (the in-browser-compiler milestone). Gates: native diff 181/13/41/35/92 unchanged,
    diff_wasm 138/6/17, fixpoint YES. **🏁 layer-17 CLOSED (`9af476a`, emitter-only) — WasmGC Int soundness + byte-identity to native.**
    The 2^30 hash divergence was a SYMPTOM of a broad bug: `>2^30` Int arithmetic TRUNCATED to i32 (the
    `WASMGC-DESIGN.md` §2.1 `$boxint`/i64 rep was declared-but-unimplemented). Implemented the rep seam
    `$mdk_box_int`/`$mdk_unbox_int` (i31 fast path / `$boxint` i64) and routed every Int site through it
    (ref-mode + scalar-mode arithmetic/compare/negate/literal/print/`intToString`/`value_cmp`/`value_eq`).
    **ORCHESTRATOR-VERIFIED:** `1000000*1000000` → `1000000000000` on both (was garbage on wasm); AND the
    wasm-compiled emitter's WAT is now **BYTE-IDENTICAL to the native-compiled emitter** (hash deltas gone —
    hashName's djb2 now computes in i64). Gate `w_int64_boundary`, diff_wasm 139/6/18. **Remaining minor
    loose ends (both LATENT/exotic, deferred):** **(a) ✅ CLOSED (`ef1dd3c`, layer-18, emitter-only):** plain-tail IMPL-METHOD self-calls (`fold`/`length`/
    `ap`/etc.) now emit `return_call $mdk_impl_<tag>_<method>` (constant stack) via an `implSelfCtxRef`
    armed only around the ordinary impl body, reusing `trmc_analysis`'s `SelfByMethod`/`isSelfSatApp`
    detection + composing with layer-8's cons-tail `wTrmcImplTry`. Deep `fold (+) 0 [1..=500000] + length …`
    → `125000750000` (overflowed before); emitter stays byte-identical to native. diff_wasm 139/6/20.
    **(b) accepted won't-fix (exotic):** a
    literal-switch pattern-match on a `>2^30` Int LITERAL still reads the scrutinee via `ref.cast (ref i31)`
    (exotic; array-index/range/charcode Int reads stay i31 by design — those values are inherently <2^30).
- **LLVM (b′) dispatch-TMC port — SCOPED & DEFERRED (2026-06-22, user-confirmed).** Attempted to mirror
  the WasmGC (b′) TMC into the native backend for "backend sync"; hit a FUNDAMENTAL ISA wall — LLVM
  `musttail` requires caller/callee arity match, but (b′) groups are heterogeneous-arity (router
  `scanAt` arity-6 → cons-root `scan` arity-5); WASM's `return_call` handles this for free, LLVM can't
  without a uniform-arity dual-define workaround that balloons past the TMC machinery (+ a detection
  non-termination on the real graph). And native doesn't NEED it (deep C stack → (b′) overflow rare;
  consistency, not a live bug). DEFERRED + documented: `TRMC-DESIGN.md` §"Phase 3 … DEFERRED"; reverted
  WIP preserved at `compiler/bprime-llvm-wip.patch` (vs base `243dbb9`). Backends stay in sync on
  self/dispatched-method TMC (Phase 1/2); differ on (b′) by ISA necessity.
- ~~args() bug~~ **RESOLVED** in `377365f` (run.js delimiter `\0`→`' '`; verified `foo bar`→2 args).
- **SEED: re-minted (`11f2229`), `bootstrap_from_seed` PASS** (was stale from the in-graph
  `core_ir_lower.mdk` structural-batch change; fixpoint C3a/C3b held throughout).
- **METHODOLOGY notes from this arc:** (1) the per-binding census measures EMITTABILITY only — it is
  BLIND to whole-program linkage AND runtime correctness; both are separate onion layers found only by
  emit→assemble→run. (2) the SAME compound-value-node bug bit twice (`freeVarsExpr` capture +
  `scanFnValueUses` linkage) — when adding a CExpr-walking pass, cover ALL compound value nodes. (3)
  the lazy emitter forbids mutable-ref-as-state-threaded-across-emit (reads default at use site) —
  encode in the Core-IR node / locals instead. (4) `wasm_emit.mdk` is OUT of the compiler graph (no
  fixpoint/seed) EXCEPT changes to `core_ir_lower.mdk`/`dce.mdk`. (5) ALWAYS rebuild the wasm emitter
  binaries (`bash test/wasm/build_wasm_oracle.sh`) before gating — stale-binary footgun bit twice
  (the 4 new structural fixtures read as failing on a stale emitter). Gate suite: `test/wasm/{diff_wasm,
  diff_wasm_typed,diff_wasm_modules,assemble_check_main}.sh` (130/6/13 + VALIDATE_OK); Node ≥22 (gates
  auto-`nvm use 24`).


## RESUME — Effect-and-capability conformance roadmap substantially CLOSED (2026-06-21). `main` = `9cc7c9f`

**The effect/capability conformance roadmap (`EFFECTS-CONFORMANCE-ROADMAP.md`, audit
`archive/EFFECTS-CONFORMANCE-AUDIT.md`, spec `EFFECTS-SEMANTICS.md`) is substantially CLOSED — E1·E2·E3
fully closed, E4 native-done, E5 standing.** Authoritative status: the roadmap's "✅ Workstream
status" block + memory `project_effects_semantics_spec`. Every landing was native-canonical,
reproduced on the binary, fixpoint-gated (C3a/C3b YES), and merged; seed re-minted (`9cc7c9f`,
`bootstrap_from_seed` PASS).

- **WS-1a/1b/1c** (E1/E6 capability manifest) — `medaka check-policy` ported to the native CLI
  (`f9abda9`), parameter-level policy compare via domain `dsub` (`a5b057a`), and `medaka manifest`
  → TOML `[package.capabilities]` (`41509f6`). The wedge is now real on the canonical binary.
- **WS-2** (E3 α precision, `98bf22b`, **both compilers** in lockstep) — α scope-seeding: enclosing
  function-body `let`s thread into the known-prefix analysis; A4/outer reject→accept,
  computed/helper-laundered stay ⊤ (sound, intraprocedural-only by design).
- **WS-3** (E2 `Set` domain, `5a1d215`, native-only) + **WS-4** (E2 `Product`/structured Net,
  `b948ff3`, native-only) — `Set` (`<L {a,b}>`, ⊑=⊆, card-cap 16) and `Product`
  (`<Net Host="…" Method={…}>`, opt-in `effect Net Product`, pointwise lattice, soundness-critical
  `dsubN` axis-defaulting-to-⊤). Design banked in `WS-4-DESIGN.md`. **Abstraction held: no domain
  add ever touched `unify_row`/escape/manifest-extractor/AST.**
- **WS-3b** (E4 Env/Exec, `2188e6a`) — domain-directed inferred-hole fill landed (Env=Set,
  Exec=Prefix); the **builtin-extern flip in `stdlib/runtime.mdk` is the ONE deferred item**,
  blocked on the frozen OCaml oracle (registers Env/Exec atomic + reads the *embedded* runtime), so
  it rides the `lib/`-removal soak tail and lands with zero further native work.
- **OPEN follow-ups (both by design, neither urgent):** (a) the WS-3b shared-runtime flip
  (soak-tail). (b) **WS-5** extern-row assurance — a standing review discipline (the extern catalog
  is the trusted base), not a code task. Also downstream: Phase 146b parameterized-effect work
  (CAPABILITY-EFFECTS §6a).
- **METHODOLOGY notes from this arc:** (1) every domain add stayed native-only *except* WS-2 (an
  inference change to existing syntax → had to land in BOTH compilers or the diff gates diverge);
  new-syntax domains (Set/Product) are native-only because the frozen oracle is slated for removal.
  (2) **Editing `stdlib/runtime.mdk` stale-bakes the OCaml oracle** until `dune build bin/main.exe`
  regenerates `lib/stdlib_content.ml` — this is exactly why the WS-3b builtin-extern flip can't land
  while `lib/` lives. (3) The new gates `test/effect_set_domain.sh` (5), `test/effect_param_domain.sh`
  (6), `test/effect_product_domain.sh` (8), `test/diff_compiler_check_policy.sh` (4+7), and
  `test/manifest_emit.sh` (6) are the effects canary set — keep them green.

## RESUME — Dict-passing conformance roadmap CLOSED (2026-06-21). `main` = `5d5bd08`

**The dict-passing conformance roadmap (`archive/DICT-CONFORMANCE-ROADMAP.md`, audit `archive/DICT-CONFORMANCE-AUDIT.md`,
spec `DICT-SEMANTICS.md`) is substantially CLOSED — D1 through D10 all resolved.** Authoritative status:
the roadmap's top "STATUS" block + memory `project_dict_semantics_spec`. Each landing was reproduced on the
binary, fixpoint-verified (C3a/C3b YES), and merged. Seed re-minted (`bootstrap_from_seed` PASS).

- **D1** existence gate + dispatch (`afe4b89`/`00cf2f7`/`83bb5c7`/`db091fd`/`72a1477`) — superinterface
  rejection + `expand_supers` superclass evidence + ambiguity-defaulting (sole-impl→default / ≥2→`AmbiguousImpl`).
- **D2** cross-module dict-arity collision (`e488cd9`); **full re-key (Option B) DEFERRED net-negative** —
  empirically proven the conservative fix IS the module-qualified re-key (call site definer-correct via scheme
  resolution); Option B = eval-dict footgun for zero gain.
- **D3** global coherence (`84642d0`) · **D4** WS-3 most-specific return-pos (`fdaefda`) · **D5/D6** WS-4
  guards (`adbbb97`) · **D7** flatten suffices · **D8** WS-5 phantom reject (`aa020b0`) · **D9/D10**
  flag rename + inert removals + doc fixes (`121b9dc`).
- **Found + fixed in passing** (`1765007`): `check` SIGTRAP on `Map`/`Set` literals (resolve missing
  `EHeadAnnot` arm); spurious cross-module `No impl of Ord for Int` (`checkCallObligations` omitted `accData`).
- **OPEN follow-ups:** (a) **WS-2 re-key (Option B)** — user wants it in a SUPERVISED new session (an Opus
  agent prompt was prepared); high-risk/zero-observable-gain cleanup, AST-origin threading through
  resolve/ast/typecheck/eval. (b) **Bug C** — `toList` on a `Map` resolves to the `Foldable` method not the
  `map.mdk` standalone (`map.mdk:350`) → native rejects `No impl of Foldable for Map a` where the oracle
  accepts; Phase-112 standalone-vs-method territory; was masked by the now-fixed SIGTRAP.
- **METHODOLOGY notes from this arc (read before the next dict task):** (1) every "confirmed bug" decomposed
  into finer real gaps under empirical scrutiny — reproduce before merging, always. (2) **3 unattended agents
  silently rooted their worktree at the session-start commit despite self-reporting `BASE_OK`** — verify base
  yourself via `git diff --stat <main> <branch>` (mass deletions / recent fixtures vanishing = stale) +
  `merge-base --is-ancestor <recent-sha>`; bake a `test -f <recent-fixture>` assert into prompts. (3)
  **`FORCE=1 bash test/build_oracles.sh` before `diff_compiler_typecheck_errors`/`_eval_dict`** — they read
  mtime-skipping `test/bin/*` oracles; a hand-edit + un-FORCEd gate gave 5 FALSE failures that cost a wrong
  revert. See ORCHESTRATING.md Failure modes.

## RESUME — Web playground workstream: Stages 1+2 DONE (2026-06-19). `main` was `bd71d40`

**The active workstream** (user-chosen): the in-browser Medaka playground —
**`PLAYGROUND-DESIGN.md`** (design; §6 staging; §6.1 hosting DECIDED; §9 forks for the server half).
Architecture: a trusted compile API (runs `medaka`) + UNTRUSTED user programs compiled to WasmGC that
run sandboxed in the visitor's browser — a live capability-effects wedge demo.

- **Stage 0** (WasmGC `--target wasm` MVP) — MET.
- **Stage 1 — `medaka build --target wasm` CLI flag — ✅ DONE (`1323c36`, native-only).** `--target
  native|wasm` in `compiler/driver/{medaka_cli,build_cmd}.mdk`; wasm branch runs `wasm_emit_modules_main`
  → WAT → `wasm-tools parse`+`validate`. Gate `test/build_wasm_cmd.sh` 4/0. **Residual:** needs a COMPILED
  wasm emitter via `MEDAKA_WASM_EMITTER` (entry `main = match args ()` can't run under interp; same as LLVM
  `MEDAKA_EMITTER`); `make medaka` mints `medaka_emitter` but nothing mints a canonical wasm emitter yet.
- **Stage 2 — static page + Node stub server — ✅ DONE (`3243849`).** `playground/` (5 files, zero npm
  deps, additive): `server.js` (Node HTTP stub — `POST /compile` runs `medaka check --json` then `medaka
  build --target wasm`, returns `application/wasm` bytes or `{errors}`; `PORT` env; probes prereqs),
  `worker.js` (Web Worker runner, host-import ABI copied verbatim from `test/wasm/run.js`, terminable),
  `main.js` (Run→POST→Worker, 10 s kill-timer, WasmGC feature-detect banner, diagnostics pane),
  `index.html` (textarea editor + console), `README.md`. **Independently verified:** good compile → valid
  wasm → run-path output matches oracle (`15`); bad compile → correct `check --json` diagnostics.
  *(Footgun hit during verify: main `./medaka` was stale (pre-Stage-1) → server's `--target wasm` failed
  "takes exactly one input file"; `make medaka` + `build_wasm_oracle.sh` fixed it. The CONTAINER must
  build medaka fresh.)*
- **HOSTING DECIDED (2026-06-19, `bd71d40`, PLAYGROUND-DESIGN §6.1):** static front on a free CDN
  (CF/GH Pages); **compile API as a CONTAINER on Cloud Run / Fly Machines (scale-to-zero, ~$0 hobby,
  platform gives TLS + resource caps).** NOT edge-FaaS (can't exec native binaries). **Stage-3 Medaka
  socket server DEFERRED** — the containerized Stage-2 Node stub IS the v1 production backend; build the
  `<Net>` sockets + HTTP-in-Medaka later as a language/async-reactor milestone, swap into the same image.
- **NEXT — Stage 2b: containerize for Cloud Run/Fly.** A slim Dockerfile bundling `medaka` +
  `test/bin/wasm_emit_modules_main` + `wasm-tools` + `stdlib/*.mdk` (compiler reads stdlib via
  `MEDAKA_ROOT`), `server.js`, env wired, listen on `$PORT`; **build `./medaka` fresh in the image**
  (stale-binary footgun above); a deploy README. No clang on the wasm path → small image. Then Stage 4
  hardening (resource limits — much given by the platform; shareable permalinks; the capability-rejection
  demo). Stage 3 (Medaka server) + Stage 5 (async reactor) are deferred language milestones, NOT launch
  deps; their §9 forks come up only if/when we build the Medaka server.
- **Memory:** `project_playground_workstream`.


## RESUME — WasmGC 2nd backend: MVP MET + W8b DONE (2026-06-19). `main` was `7bae959`→`44c915f`

**The active workstream.** A direct **Core IR → WAT text** WasmGC emitter (`compiler/backend/wasm_emit.mdk`
+ `wasm_preamble.mdk`), paralleling the LLVM emitter. Design + locked forks: **`compiler/WASMGC-DESIGN.md`**
(§9 slice list, §10 forks). Authoritative status: memory **`project_wasmgc_backend`**. PLAN.md hub row added.

- **Slices W1–W9b DONE + on `main`.** W1 toolchain · W2 scalar · W3 ADTs/match (`br_table`) · W4
  closures/`call_ref`/TCO (`return_call`, arity-in-struct) · W5 dispatch (`CMethod`/`CDict`) · W6a strings
  (`(array i8)`+cp_count, byte-write IO) · W7 collections · W8 RNG/hash/string-externs · W9 + **W9b** the
  real-prelude + multi-module pipeline. **MVP = real-`core.mdk`-prelude + multi-file compute+print programs
  compile to WasmGC and run byte-identical to `medaka build`** — independently verified end-to-end (Node 24).
- **Gates** (all green): `test/wasm/diff_wasm.sh` 85 (prelude-free entry), `diff_wasm_typed.sh` 6 (typed
  entry, own-interface dispatch fixtures), `diff_wasm_modules.sh` 9 (real-prelude/multi-module, incl
  multi-file `mm_sum→43`). Oracle = `./medaka build` (needs `MEDAKA_EMITTER=$PWD/medaka_emitter` env).
- **KEY: `wasm_emit.mdk` + its entries are OUTSIDE the self-host compiler graph** (only `test/bin/wasm_*`
  import them, not `medaka_cli.mdk`) → **no fixpoint, no seed re-mint** for emitter changes. The decisive
  check is the output-diff gate. (The 2 lexer ergonomics fixes this session WERE in-graph → fixpoint + seed.)
- **Engines installed** (engine drift is real — `WASMGC-DESIGN.md` §11): `wasm-tools` 1.252, `wasmtime` 45,
  **Node 24 via nvm** — the default `node` 20.11 FAILS the finalized Wasm 3.0 GC encoding ("invalid array
  index"); the gates auto-`nvm use 24`. `make medaka` may need `FORCE_EMITTER_REBUILD=1` to carry a graph change.
- **DONE — W8b** (main `993d4f3`): Floats (literals → `f64.const`+`struct.new $float`; arith/cmp via
  structural Float recovery; `intToFloat`/`floatToInt`/`hashFloat`/`randomFloat` pure WAT; `floatToString`
  = HOST IMPORT `mdk_float_fmt` reproducing `%.12g` byte-for-byte — the authorized one host-dependent
  formatter, parallel to the IO seam) + `stringIndexOf`/`stringCompare` (pure WAT building Option Int /
  Ordering). Gates 85/6/9. `WASMGC-DESIGN.md` §9/§11 + memory `project_wasmgc_backend` reconciled.
  **DEFERRED (clean gaps):** `stringToFloat` (strtod port). Surfaced 2 pre-existing native float-literal
  gaps → memory `project_float_literal_native_gaps` (LLVM e-form const build bug FIXED `7bae959`;
  scientific-notation source literals still rejected at check by both compilers — open/deferred).
- **WasmGC roadmap AFTER W8b** (next agents): (1) **IO/WASI host surface** — file/exec/stdin/args/env, the
  capability-manifest payoff (this is where the wedge value lands; currently the only big deferred set besides
  `stringToFloat`); (2) **Wasmtime execution cross-check** (a WASI write path — today only `wasmtime compile` accepts the
  module; running needs host imports); (3) **Float-unboxing perf** (starts all-floats-boxed); (4) **browser
  interop** (JS String Builtins) / the in-browser playground (`PLAYGROUND-DESIGN.md`); (5) **self-host-on-WasmGC** (far horizon — needs the withheld IO surface).

### Lexer ergonomics fixes landed this session (both compilers, fixpoint-gated, seed re-minted)
- **Comment-only lines now layout-transparent** + **multi-line `if`/`then`/`else`** (leading `then`/`else`
  continues the `if`). Both in `lib/lexer.mll` + `compiler/frontend/lexer.mdk`, mirrored, no associativity
  change. Memory `project_comment_line_layout_fix`.

## RESUME — 2026-06-18 correctness arc COMPLETE. `main` = `e638673`

**All items below are on `main`, fixpoint-gated (C3a/C3b YES), independently verified, seed re-minted.**


### Stale-golden / gate cleanup (start of session)
- Recaptured stale goldens (desugar/mark/lextok/test) after prior source edits.
- Numlit fixtures failing UNTYPED eval/lexer gates (they need typecheck-time `fromInt`) skip-listed
  in `eval_run` / `eval_run_batch` / `core_ir_run`; float-token normalization added to the curated
  `lexer` gate.
- Native LSP `No impl` type-error diagnostic RANGE fixed (was `{0,0}`; now carries the expr `ELoc`
  span — obligations were checked post-HM with stale `currentLoc`).

### Capability / parity landed
- **`medaka check --json`** — ported to native (was a no-op stub); byte-identical to OCaml oracle.
  Single-file via `analyzeLocated`, multi-module via `analyzeProject`. Gate
  `test/diff_compiler_check_cli_modules.sh`.
- **`medaka doc`** — ported to native (`compiler/tools/doc.mdk` + `medaka_cli` wiring); byte-identical
  to OCaml, single-file scope. New gate `test/diff_compiler_doc.sh` (14 fixtures). Fixed a scheme
  name-collision (`lookupScheme` last-match → user-schemes-first ordering, mirroring OCaml).

### Verified gap audit + doc reconcile
5-agent read-only audit reproduced every doc-claimed-open gap on the binary. Finding: the gap docs
(CONSTRUCT-COVERAGE, TYPECHECK-AUDIT, STDLIB, etc.) were systematically stale — most "open" gaps
were already closed (all Gap C/H, most A-series, hadTypeErrors, zip/mut_array/io). Reconciled 11
planning/gap docs to reflect the real open-set.

### Correctness / soundness fixes (all fixpoint-gated, all on `main`)
- **#1 Cross-module Num-obligation soundness hole** (`compiler/types/typecheck.mdk`): native `check`
  accepted imported function calls with numeric-literal args unifying against NON-`Num` types (e.g.
  `member s 3` with `s : Set Int`). Root: typecheck-module path passed `implDecls=[]` → `fromInt`/`Num`
  never registered → obligation dropped. Fixed by registering iface params over the full universe +
  running `checkImplObligations` on the typecheck path. Broadest fix — every imported numeric-literal
  call was affected.
- **#2 Top-level `DLetGroup` (`let rec … with …`)** wired through resolve/typecheck/marker/eval
  (`run` path).
- **#2b Recursive inferred-constraint dict-forwarding** (`inferDictAtFound`, `anyIdPinned` gate):
  unannotated recursive functions with inferred constraints (`countDown n = … countDown (n-1)`, mutual
  `isEven`/`isOdd`) dropped their forwarded dict → miscompiled in BOTH `run` and `build`. Broad win —
  all unannotated recursive numeric fns were affected.
- **#4/#5 Type-arg-blind impl dispatch**: two `impl`s of one interface sharing a head tycon but
  differing in type args (`MyPair Int Bool` vs `MyPair Bool Int`; `(Int,Int)` vs `((Int,Int),(Int,Int))`)
  dispatched to the FIRST impl in both backends. Fixed by threading the canonical full-type key through
  dispatch (`resolveArgStamp`) AND the Core-IR/LLVM backend. Coverage:
  `test/eval_dict_fixtures/same_head_argpos.mdk` + `test/build_diff_fixtures/same_head_typeargs.mdk`.
- **A7/D10 `DLetGroup` build residual FULLY CLOSED** (`run` AND `build`): `funClausesOf` arm +
  `lowerLetBind`/`letGroupClausesOf` helpers in `compiler/ir/core_ir_lower.mdk`; `isEmittingDecl` in
  `dce.mdk` now includes `DLetGroup`. Coverage: `test/build_diff_fixtures/letgroup_toplevel.mdk`.
- **D5 interp local-shadow**: a local `let` binding shadowing a prelude-method name was mis-dispatched
  to the method in `run` (correct in `build`/oracle). Fixed in `rewriteArgScoped` (return-position arm
  was scope-blind; now skips locally-bound names, mirroring OCaml's `env.locals` skip). Coverage:
  `test/eval_fixtures/local_shadow_method.mdk`.
- **Seed re-minted** (`e638673`); `bootstrap_from_seed` C3a byte-for-byte PASS.

## REMAINING OPEN SET — 5 items (verified on the binary; authoritative next-session TODO)

These are the real soak items. Fix these before calling the soak done and removing `lib/`.

*Tooling (highest urgency — LSP correctness + lib/-removal prerequisite):*
1. **LSP parse-error in imported sibling → silent no-publish** — `didOpen` an entry importing a
   parse-broken sibling: server does NOT crash but emits zero `publishDiagnostics`. Root: the loader /
   `analyzeProject` path panics on a graph-member parse error before diagnostics can surface it. Needs
   loader error-recovery. Memory: `project_lsp_fault_tolerance`. `lib/`-removal-relevant.
2. **Latent `ppTy` drops effect rows** (new finding from the `doc` port): `compiler/types/typecheck.mdk`'s
   `ppTy` renders interface-method effect rows wrong (drops `<IO>` etc.); the doc port worked around it
   with its own `ppTyP`. Affects LSP hover / `check` error rendering / `doc` output broadly. Fixing
   risks wide golden churn — scope carefully.

*Correctness:*
3. **Interp-behind-`build` externs** — `medaka run` (tree-walker) diverges from `build`/oracle on some
   stdlib externs: `import hash_map` (`hashString` unbound under `run`), map `toList` display,
   `arrayBlit`/IO. Build is canonical; lower severity. Need clean fixtures (privacy/API quirks muddled
   quick repros this session).

*Stdlib:*
4. **Genuinely missing**: `<>` Semigroup operator (not lexed at all — cross-cutting: both lexers +
   parser + builtins + `Semigroup` impl); JSON pretty-printer (`json.mdk` has compact `stringify` only);
   `ToJson`/`FromJson` codec interfaces; single-codepoint string indexing (deferred by design).

*Diagnostics:*
5. **Proposed compiler diagnostics** (Phase 147 ctor disambiguation, etc.) remain as-is in PLAN.md.

## Soak clock

The 2026-06-18 correctness arc found AND fixed multiple real soundness/correctness bugs (cross-module
Num over-accept, recursive dict-forwarding, type-arg dispatch, local-shadow misroute). **The soak
clock RESTARTS from this checkpoint.** Seed is FRESH (re-minted at `e638673`, `bootstrap_from_seed`
C3a byte-for-byte PASS). `lib/` stays frozen until a clean bug-free native-only stretch on top of
this base. Best soak activity = real-program use (dogfood `mq`, the jq-in-Medaka project) — surfaces
bugs + satisfies "tooling exercised end-to-end" removal gate.

## PRIOR — #11 Num-polymorphic integer literals + QoL 148/150 + concurrent d0a99a9 merged. `main` was `76177ca`
**#11 SHIPPED end-to-end (2026-06-16), native == OCaml oracle on every front, all diff gates 0-failing,
fixpoint C3a/C3b YES, seed re-minted.** Expression-position integer literals are `Num a`-polymorphic
in both compilers. Design+locked decisions: `NUMLIT-DESIGN.md` (§0). Memory:
`project_numpoly_literals_done` (authoritative). Mechanism: transparent `ENumLit` node + defaulting
pass (ground *ambiguous* not-arg-reachable Num var → Int, §0.2) + post-HM elaboration
(concrete-Int→`LInt`, concrete-Float→`LFloat`, **poly-survivor→`fromInt n` dict-dispatched**). Int-only
(no Fractional); patterns stay Int.

**QoL diagnostics:** Phase 148 (non-contiguous top-level binding clauses → `DuplicateBinding` error,
`7d755a9`) + Phase 150 (`do` on a non-monad → tailored monad message via `EDoOrigin` node, `5d11e77`),
both compilers, fixpoint-clean.

**Tracked follow-ups (low urgency):**
- **`capture_goldens.sh tc` footgun** — corrupts literal-bearing fixtures NOT in `PRELUDE_DEP_TC` on
  recapture. Goldens correct NOW; widen `PRELUDE_DEP_TC` before next bulk `tc` recapture. Memory:
  `project_numpoly_literals_done`.
- **`sum`/`product` `fromInt` workaround STAYS** (won't-do): frozen oracle panics on point-free Float
  seed; native correct. Memory: `project_oracle_fromint_pointfree_gap`.
- **`-0.0` interp/native divergence** — pre-existing, esoteric, deferred. Memory:
  `project_negzero_interp_native_divergence`.

## PRIOR — Async monad COMPLETE through ASYNC-DESIGN §7. (was `main` 463daaa)
**ASYNC FEATURE SHIPPED (2026-06-16).** Value-level effect-poly `Async e a` monad, both backends,
fixpoint-clean. `ASYNC-DESIGN.md` §0 = LOCKED decisions (authoritative); §7 staging all DONE. Memory:
`project_async_design.md`. The stages, in order:
- **Stage 1** (`stdlib/async.mdk`): effect-poly `data Async e a = Done a | Suspend (Unit -> <e> Async e a)`;
  Mappable/Applicative/Thenable; liftIO/yield/runAsync/stepAsync/concurrent; 7 doctests both backends.
- **Effect-row params on data decls** (2c1353a / native fix 85a9cb7): new `Mono` arm `TEff EffRow` /
  OCaml `TEff of effrow` in type-app arg slot; KRow kind-inferred from `<e>` field tails. Native gotcha:
  `instantiateSigTracked` seeds etbl from `effTailNames ++ rowArgNames` else bare KRow arg collapses
  to pureRow → spurious `<IO>` leak. Guard: `test/diff_fixtures/effect_param.mdk`.
- **Stage 2** (26784fb): `main : Async _` driver dispatch BOTH backends. **PARSER LIMITATION:** `<IO>`
  row literal won't parse in type-app arg position → annotate `main` unannotated OR
  `import async.*` + `main : Async e Unit`.
- **Stage 3 / D7** (463daaa): dropped vestigial `Async`/`Time` from `builtInEffects`/`builtin_effects`
  both backends. Fixpoint C3a/C3b green, no seed re-mint.

**Deferred async:** `await`/`sleep`, real parallelism/threads, non-blocking syscalls,
`spawn`/`Task` handles, cancellation/timeouts/select/race/streams.

---
## PRIOR — capability-effects v2 (Stages 1–3a merged). `main` was 4e4e5ce
Soak bug-hunt session. THREE soak fixes found+fixed+MERGED+verified:
- Native-emit scale failure (`unbound 'not'`, ~5% build rate): post-mangle synthesized-prelude-ref
  reconciliation in `dce.mdk` + `llvm_emit.mdk`. Fuzzer 900/900 clean.
- Whole-float rendering → canonical `1.0` (was `1.`): C runtime + OCaml eval + 14 goldens re-captured.
- foldMap method-level-constraint gap CLOSED (`diff_compiler_eval_dict` 25/0 baseline).

**Stage 1** (1c22ffd): effect-row `labels:string-list` → `atom-list` over RefinementDomain, both backends.
**Stage 2b** (56e1b13): known-literal-prefix analysis + inferred-hole `<Net _>` surface form, both backends.
**Stage 3a / Half A** (4e4e5ce): IO decomposition — narrow labels (Stdout/Stderr/Stdin/FileRead/FileWrite/
Env/Exec/Clock/Net/Rand) + `IO` as widening alias. Re-annotated 19 leaf externs. Fixpoint YES.
**Stage 3 Half B (deferred):** extend `check-policy` + manifest emission per-label; port `check-policy`
to native CLI. Then the manifest/platform layer (Spin first) sits on top.

---
## The standing goal: the SOAK, then gated `lib/` removal
Native is canonical; OCaml `lib/`+`bin/` is FROZEN in-tree as the differential oracle. **The user's
gate to delete `lib/` (memory `[[retirement-is-not-removal]]`): a clean day-or-two stretch of
native-only dev where we STOP hitting bugs/gaps.** The 2026-06-18 arc surfaced+fixed multiple real
bugs — the soak clock restarted (see above). Frozen oracle is still earning its keep; `lib/` must
stay. Do NOT `rm lib/` until the user explicitly calls the soak.

## Open items (durably documented — verify before acting; docs drift)
- **5 verified open gaps** — see "REMAINING OPEN SET" above + PLAN.md §"Current status" (authoritative).
- **`lib/` removal** — soak-gated. The endgame.
- `eval_dict` 25/0 + batch 25/0 is the baseline (`diff_compiler_eval_dict.sh` header updated).
- Deferred native-test modules: string (2 Unicode case-fold doctests), hash_map/hash_set
  (need byte-identical Int64-wrapping `hashInt`) — `diff_compiler_test.sh` DEFERRED header.
- Stage-4 minor remainders: diagnostics-surfacing layer, coverage.ml/bench_runner.ml port — `PLAN.md`.
- `argStampEnabled` itself still has ~3 emit-only readers — possible further simplification
  (`ARGSTAMP-UNIFY-PLAN.md` §vestigiality). Not urgent.
- `capture_goldens.sh tc` footgun — widen `PRELUDE_DEP_TC` before next bulk `tc` recapture.
- Memory holds the rest (`/Users/val/.claude/projects/-Users-val-medaka/memory/MEMORY.md` index):
  dispatch-gap history, methodology, decided invariants.

## Non-negotiable operating rules (these cost real time this session — see ORCHESTRATING.md)
- **FORCE the oracle binaries:** `FORCE=1 bash test/build_oracles.sh` before ANY gate reading
  `test/bin/*` (`diff_compiler_test`, `_eval_*`, the parity probe). `build_oracles.sh` mtime-skips
  rebuilds → a `typecheck.mdk`/`eval.mdk` change silently runs STALE source otherwise. Same for
  `./medaka` (rebuild via `make medaka`) and the parity probe binary (it doesn't auto-rebuild).
  A green/red on a stale binary means nothing.
- **The fixpoint is the decisive emitter gate.** Any change to `compiler/types/typecheck.mdk`,
  `compiler/eval/eval.mdk`, `compiler/backend/*`, `compiler/ir/*` is in the self-compiled emitter
  graph → `selfcompile_fixpoint.sh` C3a+C3b YES is MANDATORY.
- **Golden-diff, not convergence probes.** A probe comparing two modes (e.g. the argstamp parity
  probe) is BLIND to a regression that moves both modes the same wrong way. Gate on the OCaml
  golden (`diff_compiler_eval_dict`, `diff_compiler_test`, `diff_compiler_build`).
- **Merge into LOCAL `main` via the MAIN checkout** (`cd /Users/val/medaka && git merge --ff-only
  <branch>`), then ASSERT it advanced (`git rev-parse main` == new tip). Never fetch/push.
  **Never `git checkout <sha>` in a worktree** (detaches HEAD; merges then strand commits on a
  dangling line). Use `git reset --hard <sha>` on the branch.
- **Agent prompts:** STEP 0 = `git merge main` + a `git merge-base --is-ancestor <expected-tip>
  HEAD && echo BASE_OK` assert. Hand the agent the verified root cause + file:line; a
  STOP-with-precise-diagnosis is a success, not a failure (the gap docs are systematically stale —
  tell agents to reproduce + disprove the hypothesis on current main). Agents commit on THEIR branch
  + report the SHA; YOU verify + merge.
- **Bounded orchestrator reading:** scope-read just enough to frame a precise prompt; delegate
  deep exploration to read-only agents; keep conclusions, not file dumps.
- **Seed:** emitter-graph changes leave the gz seed (`compiler/seed/emitter.ll.gz`) stale; agents
  do NOT re-mint (they rely on the fixpoint). The ORCHESTRATOR re-mints
  (`CHECK_OCAML=0 bash test/refresh_seed.sh` → verify `bootstrap_from_seed.sh`) only at real
  checkpoints. Currently FRESH (re-minted at `e638673`; `bootstrap_from_seed` C3a PASS byte-for-byte).
- Build in the worktree with `dune build --root .`; never `dune test` (hangs); opam env is pre-set
  (no `eval $(opam env)`). The task list is SESSION-LOCAL — durable items go in PLAN.md/docs/memory.

## How to start
Ask the user what they want, or — if told to proceed autonomously — pick the highest-value open
item that advances the soak (likely: close one of the 5 documented gaps above, or chase whatever a
real-use bug report surfaces). For anything non-trivial, scope read-only first, present the plan,
then delegate + verify + merge. Surface genuine design decisions as questions; act on sensible
defaults otherwise.
