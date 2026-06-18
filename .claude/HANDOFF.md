# Next-orchestrator handoff — Medaka, soak tail (2026-06-17)

You are the **orchestrator** for Medaka, a self-hosting functional language whose native
LLVM backend is now CANONICAL (compiles itself + all user code OCaml-free). You design and
delegate work to subagents, verify their output against gates, and keep `main` + docs
coherent. You usually do NOT implement directly. **Read `.claude/ORCHESTRATING.md` first**
(the orchestrator playbook — core loop, agent-prompt skeleton, verification discipline,
footguns) and `AGENTS.md` (the agent-facing router/map).

## Multi-session state — RECONCILED (concurrent `d0a99a9` now merged)
This session ran alongside at least one other (several agent worktrees + a concurrent branch existed).
As of this handoff the state is reconciled and on `main`:
- **`main` branch tip = `76177ca`** — holds THIS session's #11 arc + QoL 148/150, the concurrent
  `d0a99a9` work, its completion fix, and a fresh seed. **Fully gated, all diff gates 0-failing,
  fixpoint C3a/C3b YES, `bootstrap_from_seed` C3a PASS.**
- **Concurrent `d0a99a9` (Unit-`main` no-autoprint + native printer `ENumLit` arm/fmt SIGTRAP) — MERGED**
  (`62e8f80`). It landed INCOMPLETE (suppressed Unit-main in native-emit only → 5 `diff_selfhost_llvm`
  interp-vs-golden failures); **completed in `7540a7e`** by suppressing the Unit-`main` auto-print in
  `dev/eval_probe.ml` too + recapturing the 5 stale `.eval.golden`. **Now native, interp, and CLI all
  agree: a Unit `main` prints nothing; value `main`s print their result.** This RETIRES the old
  "run/build print a trailing `0`, compare `head -1`" workaround — Unit mains are clean now. Memory:
  `project_unit_main_no_autoprint`. **GOTCHA for whoever merges another concurrent branch:** that
  Unit-main change touched the emitter graph (`llvm_emit.mdk` `mainIsUnit`) — re-mint the seed after
  (done here). And a "native-emit-only" output change will silently fail `diff_selfhost_llvm` (golden
  from `dev/eval_probe`) unless the OCaml probe is aligned too — always run the FULL diff battery, not
  just the build gate, after an output-semantics change.
- **`project_head_stale_goldens_fmt_regression` memory is now mostly stale** — its "STILL OPEN" Num
  defaulting + `default_body` wording are CLOSED (`18176ea`); its fmt/Unit-main items are merged. Trust
  this HANDOFF + `project_numpoly_literals_done` over it.
- **Worktree hygiene:** several worktrees were live (`agent-af09870d`, `fluttering-jumping-platypus`,
  `keen-stirring-lecun`, `rosy-marinating-backus`@`aeeed21`-stale, plus this session's
  `lively-herding-gizmo`). Audit `git worktree list`; prune the ones whose branches are merged into
  `main` (preserve any with unmerged commits + any still-running agent's).

## RESUME — #11 Num-polymorphic integer literals COMPLETE (run + build, both compilers, full parity; + concurrent d0a99a9 merged). `main` = 76177ca
**#11 SHIPPED end-to-end (2026-06-16), native == OCaml oracle on every front, all diff gates 0-failing,
fixpoint C3a/C3b YES, seed re-minted (`bootstrap_from_seed` C3a PASS).** Expression-position integer
literals are `Num a`-polymorphic in both compilers. Design+locked decisions: `NUMLIT-DESIGN.md` (§0).
Memory: `project_numpoly_literals_done` (authoritative). Mechanism: transparent `ENumLit` node +
defaulting pass (ground *ambiguous* not-arg-reachable Num var → Int, §0.2) + post-HM elaboration
(concrete-Int→`LInt`, concrete-Float→`LFloat`, **poly-survivor→`fromInt n` dict-dispatched**). Int-only
(no Fractional); patterns stay Int. **Landing log:** Stages 0-2 OCaml `eac278b`; Stages 3-4 selfhost
`7424b64`; soundness fix `e7031e6`/`183b7b4`; emitter Gap E/C4 `a8b95d7`; obligation hole `68d9da1`;
gate re-rooting `bee51ba`; value-level defaulting + default-method error `4fc5f47`/`18176ea`.

**The soak found SIX real native/oracle divergences in #11 — all closed. #11 was bug-dense; the
differential oracle earned its keep. Each was found by verifying the feature's FRONTIER, not agent
"green" reports (see the ORCHESTRATING note added this session):**
1. **Run-path soundness hole** — interim static-`VInt` stamp made `inc 2.5` typecheck but PANIC at
   runtime; fixed by routing surviving-poly literals through `fromInt` (dict-dispatched). `e7031e6`/`183b7b4`.
2. **Emitter Gap E/C4** — unannotated poly-`Num` fn at Float (`dbl x = x+x`, no literal) built to SILENT
   GARBAGE (`LTNum` seeded only when `dsig=Some` → integer `add` on Float box); seeded `LTNum` for any
   unannotated arith-used param + `reservedCtorsOfType` Foldable fallback. `a8b95d7`.
3. **Obligation hole** — native `check` ACCEPTED `g = f "hello"` (`f:Num a=>a->a`, concrete `Num String`
   at a let-binding) → typechecked then crashed; selfhost constraint tracking was fused with dict/emit
   and empty on the plain check path; added always-on `schemeObligationsRef`/`checkCallObligations`. `68d9da1`.
4. **Gate-blindness** — two typecheck gates' goldens came from a no-prelude probe that #11's `1`→`fromInt 1`
   breaks (`Unbound fromInt`); re-rooted prelude-dependent fixtures onto `dev/tc_module_probe` via a
   `PRELUDE_DEP_TC` name-list (test-only). `bee51ba`.
5. **Value-level Num defaulting** — native left `nums=[1,2,3]` as `List a` vs oracle/§0.2 `List Int`; the
   no-prelude HM driver wasn't recording the literal's `Num` obligation at all (so nothing to default);
   recorded it unconditionally + suppressed the no-prelude reject for a grounded `Num Int`; + specialized
   default-method-body error. `4fc5f47`/`18176ea`.
6. **fmt printer ENumLit gap** — found+fixed by the CONCURRENT session (`d0a99a9`, now MERGED) +
   its Unit-main completion `7540a7e`. See the reconciliation section at top.

**QoL diagnostics (this session, on `main`):** Phase 148 (non-contiguous top-level binding clauses →
`DuplicateBinding` error, `7d755a9`) + Phase 150 (`do` on a non-monad → tailored monad message via an
`EDoOrigin` node, `5d11e77`), both compilers, fixpoint-clean.

**Tracked follow-ups (low urgency, in PLAN.md + memory):**
- **`capture_goldens.sh tc` footgun** — corrupts literal-bearing fixtures NOT in `PRELUDE_DEP_TC`
  (poly_let, index_default, effects, records, signatures, missing_field, unknown_field_create) to
  `Unbound fromInt` on recapture. Goldens are correct NOW; widen `PRELUDE_DEP_TC` before the next bulk
  `tc` recapture. Memory: `project_numpoly_literals_done`.
- **`sum`/`product` `fromInt` workaround STAYS** (won't-do): reverting → the frozen oracle panics on the
  point-free Float seed while native is correct. Memory: `project_oracle_fromint_pointfree_gap`.
- **`-0.0` interp/native divergence** — pre-existing, esoteric, deferred. Memory: `project_negzero_interp_native_divergence`.

## PRIOR — Async monad COMPLETE through ASYNC-DESIGN §7. (was `main` 463daaa)
**ASYNC FEATURE SHIPPED (2026-06-16).** Value-level effect-poly `Async e a` monad, both backends, fixpoint-clean. `ASYNC-DESIGN.md` §0 = LOCKED decisions (authoritative); §7 staging all DONE. Memory: `project_async_design.md`. The stages, in order:
- **Stage 1** (`stdlib/async.mdk`): effect-poly `data Async e a = Done a | Suspend (Unit -> <e> Async e a)`; Mappable/Applicative/Thenable; liftIO/yield/runAsync/stepAsync/concurrent; 7 doctests both backends. §2.1 encoding validated on the binary → CPS fallback NOT needed; trampoline stack-safe for COMPILED programs (`-O2` TCO), interpreter caps deep chains ~100–500k.
- **Effect-row params on data decls** (2c1353a / native fix 85a9cb7): new `Mono` arm `TEff EffRow` / OCaml `TEff of effrow` in type-app arg slot; KRow kind-inferred from `<e>` field tails. Native gotcha: `instantiateSigTracked` seeds etbl from `effTailNames ++ rowArgNames` else bare KRow arg collapses to pureRow → spurious `<IO>` leak. Guard: `test/diff_fixtures/effect_param.mdk`.
- **Stage 2** (26784fb): `main : Async _` driver dispatch BOTH backends, type-directed (main head tycon == "Async"). OCaml `bin/main.ml` Run → apply root_env `runAsync` to forced main. Native: `mainSchemeRef`+`mainTypeIsAsync` (typecheck.mdk), `evalModulesOutputAsync` over root FULL env (eval.mdk), `medaka_cli` run arm picks path. Type-level only → fixpoint-safe. **PARSER LIMITATION:** `<IO>` row literal won't parse in type-app arg position → annotate `main` unannotated OR `import async.*` + `main : Async e Unit`.
- **Stage 3 / D7** (463daaa): dropped vestigial `Async`/`Time` from `builtInEffects`/`builtin_effects` both backends; `<Async>`/`<Time>` → `UnknownEffect`. Vocabulary-only → IR unchanged, fixpoint C3a/C3b green, **no seed re-mint**. `language-design.md` `<Async>`/`<Time>` prose deliberately left (intent doc for superseded design; SYNTAX.md = binary ground truth).
**ASYNC FEATURE SHIPPED (2026-06-16).** Value-level effect-poly `Async e a` monad, both backends, fixpoint-clean. `ASYNC-DESIGN.md` §0 = LOCKED decisions (authoritative); §7 staging all DONE. Memory: `project_async_design.md`. The stages, in order:
- **Stage 1** (`stdlib/async.mdk`): effect-poly `data Async e a = Done a | Suspend (Unit -> <e> Async e a)`; Mappable/Applicative/Thenable; liftIO/yield/runAsync/stepAsync/concurrent; 7 doctests both backends. §2.1 encoding validated on the binary → CPS fallback NOT needed; trampoline stack-safe for COMPILED programs (`-O2` TCO), interpreter caps deep chains ~100–500k.
- **Effect-row params on data decls** (2c1353a / native fix 85a9cb7): new `Mono` arm `TEff EffRow` / OCaml `TEff of effrow` in type-app arg slot; KRow kind-inferred from `<e>` field tails. Native gotcha: `instantiateSigTracked` seeds etbl from `effTailNames ++ rowArgNames` else bare KRow arg collapses to pureRow → spurious `<IO>` leak. Guard: `test/diff_fixtures/effect_param.mdk`.
- **Stage 2** (26784fb): `main : Async _` driver dispatch BOTH backends, type-directed (main head tycon == "Async"). OCaml `bin/main.ml` Run → apply root_env `runAsync` to forced main. Native: `mainSchemeRef`+`mainTypeIsAsync` (typecheck.mdk), `evalModulesOutputAsync` over root FULL env (eval.mdk), `medaka_cli` run arm picks path. Type-level only → fixpoint-safe. **PARSER LIMITATION:** `<IO>` row literal won't parse in type-app arg position → annotate `main` unannotated OR `import async.*` + `main : Async e Unit`.
- **Stage 3 / D7** (463daaa): dropped vestigial `Async`/`Time` from `builtInEffects`/`builtin_effects` both backends; `<Async>`/`<Time>` → `UnknownEffect`. Vocabulary-only → IR unchanged, fixpoint C3a/C3b green, **no seed re-mint**. `language-design.md` `<Async>`/`<Time>` prose deliberately left (intent doc for superseded design; SYNTAX.md = binary ground truth).

**Note:** the `@thorough` 25-failure note below is RESOLVED (see #11 RESUME above — they were stale goldens from G9, recaptured).

**Deferred async (per ASYNC-DESIGN non-goals):** `await`/`sleep`, real parallelism/threads, non-blocking syscalls, `spawn`/`Task` handles, cancellation/timeouts/select/race/streams. The robust-runtime swap (§5) replaces scheduler internals only — `Async`'s public face + laws + `concurrent` contract + `main : Async` must stay fixed.

---
## PRIOR — capability-effects v2 in progress (paused, resumable). `main` was 4e4e5ce → Stage 1/2a/2b/3a landed
Soak bug-hunt session. Worktrees/branches were pruned to 4 (housekeeping). THREE soak fixes found+fixed+MERGED+verified (fixpoint C3a/C3b YES each):
- **Native-emit scale failure** (`unbound 'not'`, ~5% build rate): post-mangle synthesized-prelude-ref reconciliation in `selfhost/ir/dce.mdk` + `selfhost/backend/llvm_emit.mdk`. Fuzzer now 900/900 clean (`test/fuzz_diff.sh` TIER=1 native).
- **Whole-float rendering → canonical `1.0`** (was `1.`): `runtime/medaka_rt.c` (×2) + `lib/eval.ml` (×2, deliberate oracle edit) + `dev/astdump.ml`/`lib/ast.ml` cosmetic; 14 goldens re-captured. nan/inf now bare. Decided change — memory `project_float_tostring_trailing_dot` (RESOLVED).
- **foldMap method-level-constraint gap CLOSED** (eval_dict 25/0, batch 25/0): `crossModuleMethodConstraintsRef` accumulator + register method dict slots after body inference in `selfhost/types/typecheck.mdk`. `diff_selfhost_eval_dict` now **25 ok / 0 failing** — the 3-failing / 18-batch baseline is gone.

**Capability-effects research pass DONE:** `CAPABILITY-EFFECTS-RESEARCH.md` committed to main. Recommendation: dual-layer manifest (TOML `[package.capabilities]` now + WIT world later); target Spin/Fermyon first; 5 forks identified (extern-namespace sealing on native is the sharp one).

**BOOKKEEPING CLEARED THIS CHECKPOINT:** EMITTER-GAPS.md entry for scale-bug added; PLAN.md / HANDOFF / eval_dict header updated. **Seed RE-MINTED** (commit 8718b05, `bootstrap_from_seed` PASS C3a byte-for-byte) — fresh as of this checkpoint.

**New minor finding (logged, deferred):** `-0.0` literal renders `0.0` interp vs `-0.0` native (sign-of-zero lost in interp) — pre-existing, esoteric, uncovered by gates.

**NEXT direction — CAPABILITY-EFFECTS v2 (language-level, in progress).** The user reprioritized: get the effect-system language features right BEFORE the manifest/platform layer (avoids downstream rewrites). Design LOCKED + committed: `CAPABILITY-EFFECTS-V2-DESIGN.md` (§0 = locked fork decisions, authoritative). Shape: parameterized effects over a general **RefinementDomain** repr (Prefix domain first — trailing-`*`, local known-literal-prefix analysis, widen to ⊤ on dynamic; **set-of-atoms-per-label**, NOT join); **IO decomposition** into narrow labels + `IO` as a widening alias (re-annotate ~21 externs only, cheap migration); **security-vs-internal taxonomy** axis (drives the manifest). Syntax: `effect Net Prefix` / `internal effect Mut`. NON-GOAL: `Throws`/typed-error effects (Result canonical; panic sole uncatchable escape — honors no-catchable-panics). Both typecheckers change in lockstep; every stage fixpoint-gated.
- **Stage 1 DONE + merged** (main 1c22ffd): effect-row `labels:string-list` → `atom-list` over RefinementDomain, in lib/typecheck.ml + selfhost/types/typecheck.mdk. Behavior byte-identical (all params ⊤). Prefix domain arms written but unreachable; Stage 2 adds the analysis + parser with ZERO row-repr changes. Fixpoint C3a/C3b YES, all diff gates green.
- **Stage 2a DONE + merged** (main bff2700 + CLI gate 0ecbc68): Prefix domain algebra (`dsub`/`djoin`/`dmeet`/`drender`), label→domain registry, `prefix_pattern_ok` delimiter validation, parser `effect Net Prefix` / `internal effect Mut` / `<Net "a.com/*">`, subsumption wired into the open/closed row check — both backends. NOTE: a reported "col-17 parse defect" was a PHANTOM (orchestrator's own worktree was stale, behind the grammar-rule commit); no defect existed. Real gap (closed): unit tests parse via raw `Parser.program Lexer.token`, bypassing the indentation lexer the CLI uses → no CLI coverage. Fixed with fixture `test/diff_fixtures/effect_param.mdk` + gate `test/diff_selfhost_effect_param.sh` (4/0).
- **Stage 2b DONE + merged** (main 56e1b13): known-literal-prefix analysis α (§2.4) over desugared core string forms + inferred-hole `<Net _>` surface form, both backends. Leaf extern carries the hole; each call site fills it via `α(first arg)`; concrete `<Net "a.com/*">` annotations are the granted bound checked via `dsub`. Hole encoded non-structurally as `PPrefix (Some "_")` (eff_hole_src sentinel), de-holed to ⊤ before dsub/render. α: literal⇒Known; `++`⇒left prefix; let/EVar/ELet⇒propagate; EIf/EMatch⇒LCP-if-all-Known; EApp/fn-param/field⇒Unknown⇒⊤ (the intraprocedural no-exfiltration guarantee). Gate `test/diff_selfhost_effect_hole.sh` (6/0): admits `a.com/foo`, REJECTS sibling-host + computed-URL through BOTH CLIs. Fixpoint C3a/C3b YES; parse/typecheck/resolve diff gates clean.
- **Stage 3a (Half A) DONE + merged** (main 4e4e5ce): IO decomposition. Narrow labels (Stdout/Stderr/Stdin/FileRead/FileWrite/Env/Exec/Clock/Net/Rand) as resolver builtins (`built_in_effects` / `builtInEffects`) with a security-vs-internal taxonomy table (`builtin_effects` in lib/typecheck.ml :303; `ioAliasLabels` selfhost); `IO` as a widening union alias (narrow⊑IO ACCEPT, IO⊑narrow REJECT, IO excludes Mut/Panic) via `expand_io_in_bound`+`atoms_escape` (OCaml) / `expandIoInBound`+`atomsEscape` (selfhost) at the two unify-row leak sites + `EffectEscape`. Re-annotated 19 leaf externs in `stdlib/runtime.mdk` (`<IO>`→narrow; allocBytes/assert_snapshot kept `<IO>`). Only 2 goldens moved (runtime.desugar + runtime.mark) — **every delta verified row-only `TyEffect("IO")`→narrow, nothing semantic**. VERIFIED independently before merge: fixpoint C3a/C3b YES; effect_param 4/0; effect_hole 6/0; full diff battery green (typecheck 12/0, resolve 14/0, parse 27/0, build 25/0, test 9/0, eval 20/0, llvm 180/0); test_typecheck OCaml suite + @thorough (147) EXIT=0. (The agent-reported "#55 25-fail baseline" was stale — build gate is 25/0.) Seed NOT re-minted (defer to checkpoint).
- **Stage 3 Half B (NEXT, deferred to platform layer):** extend `check-policy` + manifest emission to carry per-label params; port `check-policy` to the native CLI (currently OCaml-only, fork i).
Then the manifest/platform layer (the earlier `CAPABILITY-EFFECTS-RESEARCH.md` dual-layer TOML+WIT recommendation, Spin first) sits on top.

**Prior (superseded) NEXT note — manifest-format design — is deferred until the v2 language features land.**

## Where things stand (`main` branch = 76177ca; concurrent d0a99a9 MERGED — see top; nothing pushed)
The big multi-session arc is essentially done. Verify current state, don't trust this verbatim:
- `cd /Users/val/medaka && git log --oneline -20 main` (the recent landings) AND `git worktree list`
  (check for the concurrent `fix/unit-main-autoprint-fmt-numlit` branch + agent worktrees still live).
- In a worktree: `export PATH="$HOME/.opam/5.4.1/bin:$PATH" && export MEDAKA_EMITTER=$PWD/medaka_emitter && make medaka && FORCE=1 bash test/build_oracles.sh && bash test/selfcompile_fixpoint.sh` (should print C3a YES / C3b YES — the decisive emitter gate).

DONE (don't re-do; full record in `PLAN.md` "Current status" + `PLAN-ARCHIVE.md` Stage-3/4 logs):
gate re-rooting (every correctness gate OCaml-free, `selfhost/REROOT-PLAN.md`); the
single-file/multi-module **driver collapse** (`selfhost/DRIVER-COLLAPSE-PLAN.md`, closes audit
§6; `medaka check` resolves imports); native dispatch gaps #55/#54/#50/#21 (the latter genuinely
solved, not contained); the map Foldable false-positive+SIGBUS; native stdlib test expansion;
fuzz_gen ported native; the cross-module **ctor-name collision** emitter fix (universal ctor
mangling); the **`argStampEnabled` eval-vs-emit dispatch unification** COMPLETE (eval now threads
dicts like emit — `selfhost/ARGSTAMP-UNIFY-PLAN.md`); emit-path Set-literal/mutual-rec dict fixes (#44).

DONE this session (2026-06-15) — a style-audit + hygiene arc, all on local main, every merge
fixpoint-gated byte-identical:
- **Style audit** of selfhost: trailing-comma-on-break + width-triggered import wrapping (#18);
  trailing-operator line continuation (both lexers) + Option-B binop width-breaking (both formatters)
  (#19); derive smart-constructors in `desugar.mdk` (#21); cross-module protocol-name constants in
  `support/util` (#22); block-form `data`/`record` + `deriving` parser fix, both parsers (#23).
  New `STYLE.md` (5 hand-source conventions). AGENTS.md: the no-stdlib rule + *why* (instance
  surface / compile-time / isolation — DCE already shakes plain fns; not just binary size).
- **Helper centralization** (#25, `selfhost/HELPER-CENSUS.md` is the audit): the compiler's
  hand-rolled generic helpers consolidated into `support/{util,char,path}.mdk` (2 new themed
  modules); ~23 duplicate clusters collapsed, ~6 O(n²) impls dropped (drifted `joinWith`/`reverseL`/
  `joinNl`/`joinDot`), dedup promoted to OrdMap O(n·log n). typecheck.mdk included. Net ~−365 lines.
- **#24 correctness fix:** match-arm refutable pattern-guard binders (`x if Some v <- e => …`) now
  scope into later guard qualifiers AND the arm body in the native pipeline — was a NATIVE-only
  divergence (`frontend/resolve.mdk` `checkArm` + `types/typecheck.mdk` `inferArms` didn't thread
  the binders; OCaml always did; `medaka run` evaluated correctly, only `check` rejected). Fixed both
  passes; AGENTS.md guard note corrected (the prior "fails in both backends" was wrong).
- Fixed an inherited stale lsp/session golden (the semanticTokensProvider capability) + re-fmt'd the
  import lines the centralization batches left unwrapped.

## The standing goal: the SOAK, then gated `lib/` removal
Native is canonical; OCaml `lib/`+`bin/` is FROZEN in-tree as the differential oracle. **The
user's gate to delete `lib/` (memory `[[retirement-is-not-removal]]`): a clean day-or-two stretch
of native-only dev where we STOP hitting bugs/gaps.** **The 2026-06-16/17 #11 arc surfaced+fixed
SIX real native/oracle divergences (run-path soundness, emitter Gap E/C4, obligation hole,
gate-blindness, value-level defaulting, fmt-printer ENumLit) — so the soak clock RESTARTS HARD from
this checkpoint.** #11 was a bug-dense feature and the frozen oracle caught every divergence; that is
strong evidence the soak is NOT yet clean and `lib/` must stay. Do NOT `rm lib/` until the user
explicitly calls the soak. Until then: keep native canonical, fix what real use surfaces, keep all
gates + fixpoint green. **Best next soak activity = real-program use (dogfood `mq`, the jq-in-Medaka
project) — that is exactly what surfaces these bugs and satisfies the "tooling exercised end-to-end"
removal gate.**

## Open items (all durably documented — verify before acting; docs drift)
- **`lib/` removal** — soak-gated (above). The endgame.
- `eval_dict` 25/0 + batch 25/0 is the current baseline (`diff_selfhost_eval_dict.sh` header updated): foldMap method-level-constraint gap CLOSED 2026-06-15. All 25 fixtures pass.
- Deferred native-test modules: string (2 Unicode case-fold doctests), hash_map/hash_set
  (need byte-identical Int64-wrapping `hashInt`) — `diff_selfhost_test.sh` DEFERRED header.
- Stage-4 minor remainders: diagnostics-surfacing layer, coverage.ml/bench_runner.ml port — `PLAN.md`.
- `argStampEnabled` itself still has ~3 emit-only readers — a possible further-simplification
  follow-up (`ARGSTAMP-UNIFY-PLAN.md` §vestigiality). Not urgent.
- #11 full Num-polymorphic integer literals — `PLAN.md` (deferred, post-flip; not a gate).
- Memory holds the rest (`/Users/val/.claude/projects/-Users-val-medaka/memory/MEMORY.md` index):
  dispatch-gap history, the "parity probe is BLIND to equal-ON/OFF regressions → use
  diff_selfhost_eval_dict golden-diff" methodology, decided invariants.

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
  dangling line — happened this session). Use `git reset --hard <sha>` on the branch.
- **Agent prompts:** STEP 0 = `git merge main` + a `git merge-base --is-ancestor <expected-tip>
  HEAD && echo BASE_OK` assert (an agent silently built on a stale base this session). Hand the
  agent the verified root cause + file:line; a STOP-with-precise-diagnosis is a success, not a
  failure (the gap docs are systematically stale — tell agents to reproduce + disprove the
  hypothesis on current main). Agents commit on THEIR branch + report the SHA; YOU verify + merge.
- **Bounded orchestrator reading:** scope-read just enough to frame a precise prompt; delegate
  deep exploration to read-only agents; keep conclusions, not file dumps.
- **Seed:** emitter-graph changes leave the gz seed (`selfhost/seed/emitter.ll.gz`) stale; agents
  do NOT re-mint (they rely on the fixpoint). The ORCHESTRATOR re-mints
  (`CHECK_OCAML=0 bash test/refresh_seed.sh` → verify `bootstrap_from_seed.sh`) only at real
  checkpoints. Currently FRESH (re-minted at `76177ca`, after merging d0a99a9 emitter change;
  `bootstrap_from_seed` C3a PASS byte-for-byte). NOTE: the concurrent `d0a99a9` is emit/printer work
  — if you merge it, re-check whether its changes touched the emitter graph and re-mint if so.
- Build in the worktree with `dune build --root .`; never `dune test` (hangs); opam env is pre-set
  (no `eval $(opam env)`). The task list is SESSION-LOCAL — durable items go in PLAN.md/docs/memory.

## How to start
Ask the user what they want, or — if told to proceed autonomously — pick the highest-value open
item that advances the soak (likely: close one of the documented gaps above, or chase whatever a
real-use bug report surfaces). For anything non-trivial, scope read-only first, present the plan,
then delegate + verify + merge. Surface genuine design decisions as questions; act on sensible
defaults otherwise.
