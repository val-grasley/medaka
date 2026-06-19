# Next-orchestrator handoff — Medaka, soak tail (2026-06-18)

You are the **orchestrator** for Medaka, a self-hosting functional language whose native
LLVM backend is now CANONICAL (compiles itself + all user code OCaml-free). You design and
delegate work to subagents, verify their output against gates, and keep `main` + docs
coherent. You usually do NOT implement directly. **Read `.claude/ORCHESTRATING.md` first**
(the orchestrator playbook — core loop, agent-prompt skeleton, verification discipline,
footguns) and `AGENTS.md` (the agent-facing router/map).

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
  `test/diff_selfhost_check_cli_modules.sh`.
- **`medaka doc`** — ported to native (`selfhost/tools/doc.mdk` + `medaka_cli` wiring); byte-identical
  to OCaml, single-file scope. New gate `test/diff_selfhost_doc.sh` (14 fixtures). Fixed a scheme
  name-collision (`lookupScheme` last-match → user-schemes-first ordering, mirroring OCaml).

### Verified gap audit + doc reconcile
5-agent read-only audit reproduced every doc-claimed-open gap on the binary. Finding: the gap docs
(CONSTRUCT-COVERAGE, TYPECHECK-AUDIT, STDLIB, etc.) were systematically stale — most "open" gaps
were already closed (all Gap C/H, most A-series, hadTypeErrors, zip/mut_array/io). Reconciled 11
planning/gap docs to reflect the real open-set.

### Correctness / soundness fixes (all fixpoint-gated, all on `main`)
- **#1 Cross-module Num-obligation soundness hole** (`selfhost/types/typecheck.mdk`): native `check`
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
  `lowerLetBind`/`letGroupClausesOf` helpers in `selfhost/ir/core_ir_lower.mdk`; `isEmittingDecl` in
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
2. **Latent `ppTy` drops effect rows** (new finding from the `doc` port): `selfhost/types/typecheck.mdk`'s
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
- foldMap method-level-constraint gap CLOSED (`diff_selfhost_eval_dict` 25/0 baseline).

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
- `eval_dict` 25/0 + batch 25/0 is the baseline (`diff_selfhost_eval_dict.sh` header updated).
- Deferred native-test modules: string (2 Unicode case-fold doctests), hash_map/hash_set
  (need byte-identical Int64-wrapping `hashInt`) — `diff_selfhost_test.sh` DEFERRED header.
- Stage-4 minor remainders: diagnostics-surfacing layer, coverage.ml/bench_runner.ml port — `PLAN.md`.
- `argStampEnabled` itself still has ~3 emit-only readers — possible further simplification
  (`ARGSTAMP-UNIFY-PLAN.md` §vestigiality). Not urgent.
- `capture_goldens.sh tc` footgun — widen `PRELUDE_DEP_TC` before next bulk `tc` recapture.
- Memory holds the rest (`/Users/val/.claude/projects/-Users-val-medaka/memory/MEMORY.md` index):
  dispatch-gap history, methodology, decided invariants.

## Non-negotiable operating rules (these cost real time this session — see ORCHESTRATING.md)
- **FORCE the oracle binaries:** `FORCE=1 bash test/build_oracles.sh` before ANY gate reading
  `test/bin/*` (`diff_selfhost_test`, `_eval_*`, the parity probe). `build_oracles.sh` mtime-skips
  rebuilds → a `typecheck.mdk`/`eval.mdk` change silently runs STALE source otherwise. Same for
  `./medaka` (rebuild via `make medaka`) and the parity probe binary (it doesn't auto-rebuild).
  A green/red on a stale binary means nothing.
- **The fixpoint is the decisive emitter gate.** Any change to `selfhost/types/typecheck.mdk`,
  `selfhost/eval/eval.mdk`, `selfhost/backend/*`, `selfhost/ir/*` is in the self-compiled emitter
  graph → `selfcompile_fixpoint.sh` C3a+C3b YES is MANDATORY.
- **Golden-diff, not convergence probes.** A probe comparing two modes (e.g. the argstamp parity
  probe) is BLIND to a regression that moves both modes the same wrong way. Gate on the OCaml
  golden (`diff_selfhost_eval_dict`, `diff_selfhost_test`, `diff_selfhost_build`).
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
- **Seed:** emitter-graph changes leave the gz seed (`selfhost/seed/emitter.ll.gz`) stale; agents
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
