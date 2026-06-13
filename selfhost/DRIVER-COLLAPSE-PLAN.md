# DRIVER-COLLAPSE-PLAN.md — collapse the dual single-file / multi-module drivers

Status: APPROVED 2026-06-13 (user). Implements `selfhost/TYPECHECK-AUDIT.md §6`
("Dual drivers … the recurring defect"). Collapse the single-file typecheck+eval
paths into the **1-module case of the multi-module path**, in selfhost only, while
the OCaml byte-diff oracle still exists — a prerequisite for the gated `lib/`
removal. **Decision: option A** (see §check) — `check` becomes a real multi-module
checker; we do NOT keep any single-file-only tool variant.

## Why
Three typecheck entry points + two eval entry points run in parallel today; every
fix has to be mirrored across them, and the mirror is forgotten (phases
96/103/121/125/134 loader-only bugs; the `argStampEnabled` emit-vs-eval gate, #55;
the 2026-06-13 map `medaka test` SIGBUS — flat `check` fixed, multi-module `test`
still crashed). Collapsing removes the "other path" so the class can't recur.

## Entry points being collapsed
Typecheck (`selfhost/types/typecheck.mdk`):
- **flat** `checkProgram`/`checkProgramSeeded` (consumed by `check` CLI AND `elaborateDict`)
- **single-file dict** `elaborateDict` (wraps `checkProgramSeeded` + single-program dict-pass)
- **multi-module** `elaborateModules`/`checkModuleFullImpl`/`checkModulesGo` ← the target

Eval (`selfhost/eval/eval.mdk`):
- **flat** `evalProgram`/`evalOutput`
- **multi-module** `evalModules`/`evalModulesOutput`/`evalModulesRootEnv` ← the target

Target: every caller routes through the multi path with a **1-module list**
`[(rootId, decls)]`. The degenerate 1-module case automatically satisfies the flat
path's invariants (one `resetState`; zero imports ⇒ full constraint set), which is
what makes the collapse safe.

## Scope decision: selfhost only
Leave OCaml `lib/` frozen and UNTOUCHED — it is the byte-diff oracle that *verifies*
the collapse. Refactoring it would defeat its purpose and burn effort on
soon-deleted code. The audit's "both compilers" predates the 2026-06-12 canonical
flip; post-flip the OCaml dual-driver only needs to keep producing the same OUTPUT
the selfhost collapse must match. Collapse must land BEFORE `lib/` removal.

## `check` decision — OPTION A (resolve imports)
`check` today is single-file (emits `UnknownModule` for non-core imports). Under A,
`check` routes through the unified multi-module path and RESOLVES imports — fixing
the known "native check is single-file" limitation. Consequence: the
`diff_selfhost_check` byte-diff gate vs OCaml's *single-file* `check` no longer
holds for import-bearing files. **Re-root `check`'s verification** onto the
multi-module oracle: (a) for no-import files, `check` stays byte-identical (1-module
case) — keep that gate; (b) for import-bearing files, verify native `check` output
against OCaml's MULTI-module typecheck (`diff_selfhost_check_modules` already diffs
the native multi path vs OCaml — extend it / add a `check`-CLI variant), and
cross-check that `check` and `build` agree on the same project. This re-root is part
of Phase 4.

## Phases (sequential; each byte-diff-gated vs OCaml + `selfcompile_fixpoint` C3a/C3b YES)
- **Phase 0 — scaffold + equivalence harness (small).** Add `elaborateOne`/`evalOne`/
  `evalOneRootEnv` 1-module wrappers (no caller migrated yet) + a temporary
  `test/diff_flat_vs_onemodule.sh` that runs every existing flat fixture through BOTH
  the flat path and the 1-module wrapper and asserts byte-identical. Proves
  1-module ≡ flat before anything moves. Gates: new harness + `diff_selfhost_check`,
  `diff_selfhost_eval_dict`, `diff_selfhost_eval_run`, fixpoint.
- **Phase 1 — `test` doctest+prop split (medium).** `runChosen`/`runProps` always go
  multi (1-module case for no-import files). Preserve `programIsCore` (pass `[]`
  core) + the `coreDictNames` return-pos-only dict set (the `neq`-hang canary: must
  pass `medaka test stdlib/core.mdk` + a prelude-shadowing doctest). Gates:
  `diff_selfhost_test`, `diff_selfhost_eval_run/_dict`, `bootstrap_eval`, fixpoint.
- **Phase 2 — `elaborateDict` → 1-module dict (medium-large).** Reroute single-file
  dict elaboration to the 1-module `elaborateModules`. Verify dict set + route
  stamping byte-identical (`argStampEnabled`/`evalDictLayerActive` set as the
  1-module path expects). Gates: `diff_selfhost_eval_dict(+_batch)`, `_eval_typed`,
  `_core_ir`, `_llvm_modules`, fixpoint.
- **Phase 3 — eval flat → `evalModules` (medium; RISKIEST).** Switch
  `runSingle`/`runPropsSingle` + remaining `evalProgram`/`evalOutput` callers to
  `evalModules`/`evalModulesRootEnv` 1-module. The binding/install/thunk-force-order
  hazard class (phases 96/103/121/125/134). Verify, don't assume, with
  `dev/module_debug.exe` + a prelude-shadowing fixture. Gates:
  `diff_selfhost_eval_run(+_batch)`, `_eval_typed_modules`, `bootstrap_eval`, fixpoint.
- **Phase 4 — `check` → 1-module typecheck, OPTION A (medium).** Route
  `checkToLinesWithRuntime` through the unified path; `check` now resolves imports.
  Re-root the check gate per §check. Gates: re-rooted `diff_selfhost_check`,
  `diff_selfhost_check_modules`, `_typecheck_errors`, `_panic_errors`, fixpoint.
- **Phase 5 — delete flat fns + temporary harness (small).** Delete `checkProgram`,
  `elaborateDict` (+ its discover* fixpoint), `evalProgram`, `evalOutput`. KEEP
  shared helpers (`checkProgramSeeded`, `inferDefaultBodies`, `resetState`,
  `coalesceImpls`, `lookupMethod`, …) — the module path uses them. Remove
  `diff_flat_vs_onemodule.sh` last. Full gate matrix + fixpoint green without the
  flat fns proves redundancy.

## Risk register
- **Eval install/binding/thunk-force order (Phase 3)** — the recurring locus.
  Mitigation: prelude-shadowing fixtures; `module_debug` (same tree both drivers);
  lazy-toplevel-nullary canonical (only `main` drives effects) must hold.
- **`coreDictNames` / `neq`-hang (Phase 1/2)** — if the 1-module joint path sweeps
  arg-position helpers into the dict set, the prop-shrinker hang returns. Canary:
  `medaka test stdlib/core.mdk` at every phase.
- **Surviving-unify-var-id route keying** — collapse re-routes which pass stamps
  routes; a route keyed off a unify-survivor id stamped in `checkProgramSeeded` must
  survive being stamped via `checkModuleFullImpl`. Caught by
  `diff_selfhost_eval_dict` + `_llvm_modules` (output depends on correct dispatch).
- **Fixpoint** — `typecheck.mdk`+`eval.mdk` are in the emitter graph; the collapse
  must be byte-output-preserving for the compiler's OWN source (1-module degenerate
  case ⇒ identical typed/dict tree for self-compile). Hardest invariant; Phase 0's
  harness exists to prove it before any caller moves.
- **Joint dict-pass cross-module collision (Phase 134)** — mooted for 1 module (no
  same-named cross-module fns) + universal mangling (L1 CLOSED). Low risk.

## Verification discipline (every phase)
Byte-diff vs frozen OCaml oracle on the phase's gates + `selfcompile_fixpoint.sh`
C3a YES / C3b YES (mandatory — emitter graph). Sequential: phases share mutable
`typecheck.mdk`/`eval.mdk` + the fixpoint canary, so no parallel edits. Effort:
medium-large overall, dominated by Phase 3 (eval order) + Phase 2 (dict-set).
