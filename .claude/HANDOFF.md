# Next-orchestrator handoff — Medaka, WasmGC backend + soak (2026-06-19)

You are the **orchestrator** for Medaka, a self-hosting functional language whose native
LLVM backend is now CANONICAL (compiles itself + all user code OCaml-free). You design and
delegate work to subagents, verify their output against gates, and keep `main` + docs
coherent. You usually do NOT implement directly. **Read `.claude/ORCHESTRATING.md` first`**
(the orchestrator playbook — core loop, agent-prompt skeleton, verification discipline,
footguns) and `AGENTS.md` (the agent-facing router/map).

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
