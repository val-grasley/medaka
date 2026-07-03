# TYPECHECK ERROR FRAMING — Design (Tier-3 "typecheck mis-framing" reservoir)

Owning workstream: error-message quality (`compiler/ERROR-QUALITY.md`,
`test/error_quality_fixtures/GRADING.md`; memory `project_error_quality_workstream`).
This design targets the graded corpus's largest remaining quality reservoir:
type errors that surface with a misleading frame. Read-only design pass +
orchestrator verification of the parity claim. Base `e5326a4e`.

All seams are in `compiler/types/typecheck.mdk` (~11k lines).

## The three sub-problems (reproduced on the current binary)

| fixture | current CLI (primary → secondary) | sub-problem |
|---|---|---|
| `too_few_args` | `No impl of Num for (Int -> Int)` | 1 (operator-on-function) |
| `if_branch_mismatch` | `No impl of Num for String` | 1 |
| `list_heterogeneous` | `No impl of Num for String` | 1 |
| `cons_type_mismatch` | `No impl of Num for String` | 1 |
| `arg_order_swapped` | `Type mismatch: Int vs String` → `No impl of Num for String` | 1 (secondary) + 3 |
| `too_many_args` | `Type mismatch: Int vs a -> b` → `ambiguous 'Debug a'` | 2 + 3 |
| `apply_non_function` | `Type mismatch: Int vs a -> b` → `ambiguous 'Debug a'` | 2 + 3 |
| `wrong_arg_type_in_map` | `Type mismatch: a b vs String` → `ambiguous 'Debug a'` → `'Mappable a'` | 2 + 3 |
| `record_missing_field` | `Missing field age …` → `No impl of Debug for Person` | 3 (primary already good) |
| `record_wrong_field` | `Field aeg does not belong …` → `ambiguous 'Debug a'` | 3 (primary already good) |

1. **Num-mis-framing.** Integer literals are Num-polymorphic (`inferNumLit`/
   `inferNumLitBare`, ~L4087-4116): a literal becomes a fresh var carrying a
   deferred `("Num",…)` obligation. Unifying that fresh var against `String`
   *succeeds*; the failure only surfaces post-inference in
   `checkOneImplObligation` (~L8317, `pushTypeErrorOnceAt "T-NO-IMPL"`; message
   `noImplFoundMsg`, ~L8356). `numlitRefs` records literal-sourced vars →
   lets us distinguish a literal (`1`) from an operator (`x + 1`).
2. **Leaked raw tyvars / "not a function".** `inferApp` (~L4469-4480) does
   `unify ft (TFun xt eff r)` with `xt`/`r` fresh; when `ft` is a concrete
   non-arrow (`Int`), `typeMismatch` (~L2278) renders `Int vs a -> b`. Both
   `apply_non_function` and `too_many_args` (`inc 1 2`) are genuinely
   "applied a non-function." Seam: guard *before* the unify — if `normalize ft`
   is a concrete non-arrow head, emit `T-NOT-A-FUNCTION`.
3. **Cascade storms.** Secondary `ambiguous 'Debug a'`
   (`checkUndeterminedObligation` ~L8167-8172) / `No impl …`
   (`checkOneImplObligation` ~L8317) errors pile onto an already-errored node.
   Two shapes: *unresolved-var* cascades (errored node's result is a free var →
   kill with a **poisoned-var set**) and *concrete-result* cascades
   (`record_missing_field`: result is concrete `Person` → needs **per-node
   snapshot-restore**). Precedent already exists: `inferDefaultMethodBody`
   (~L8090-8104) snapshots `pendingImplObligations` and restores on error to
   drop a spurious cascade. Generalize that pattern.

## Fork 1 — RESOLVED (was a false alarm; the blocker does not exist)

The design pass flagged that sub-1/sub-2 reframes conflict with "OCaml-parity"
goldens (`int_vs_string`, `value_restriction`, `mut_generalization`,
`tuple_arity` in `test/typecheck_error_fixtures/`) captured while "the OCaml
oracle is still TRUSTED" (`test/capture_goldens.sh` header).

**Verified false.** The OCaml compiler (`lib/`, `bin/`, `_build/`) was removed
2026-06-26; `diff_compiler_typecheck_errors.sh` runs `test/bin/typecheck_main`
+ `test/bin/check_main`, which `test/build_oracles.sh` builds from `compiler/`
source via native `medaka build`. The `.tc.golden` files are **checked-in
native output**; the "OCaml TRUSTED" line in `capture_goldens.sh` is a stale
pre-removal header comment. Re-capturing after a reframe simply re-derives the
improved *native* text — there is no external oracle to disagree with. So the
Num/tyvar reframes are a deliberate quality decision + routine native golden
re-capture, exactly like every prior change in this workstream. **No policy
blocker; all three sub-problems are in scope.** (When touching those goldens,
also refresh the stale `capture_goldens.sh` header.)

## Remaining forks (defaults chosen; recorded here)

2. **Reframe aggressiveness (sub-1).** Chosen: **literal-provenance + fully-
   ground only** — reframe `No impl of Num for T` → `Type mismatch: Int vs T`
   only when the Num obligation traces to a literal (`numlitRefs`) AND `T` is a
   fully-ground concrete non-Num head. Avoids mis-claiming "Int vs …" for a
   genuine `+`-on-struct. Operator-sourced Num failures keep a Num-flavored
   message.
3. **Cascade suppression granularity.** Chosen: **poisoned-var set +
   localized snapshot-restore**, NOT a full `TError` sentinel threaded through
   unification (largest churn, deferred).
4. **`too_few_args` `(Int -> Int)` framing.** Chosen: **defer** — it's really
   an arity diagnostic; low ROI. Keep the `numUnimplementableHead` reject
   (soundness-load-bearing, PLAN.md #11); only its *wording* is negotiable.

**Wording ambition (user decision): CONTEXT-AWARE.** Reframed messages should be
site-specific, not just `Type mismatch: X vs Y`:
- if-branches → `if branches have different types: Int vs String`
- list literal → `list elements have different types: Int vs String`
- cons (`::`) → element-vs-list-element framing
- over-application → `applied 2 arguments but 'inc' takes 1` (arity-aware) where
  the callee name/arity is recoverable; else `Int is not a function`
This pushes C/D to require the syntactic context at the reframe site (which node
kind raised the mismatch) and is Opus-sized. Scope: **all four chunks A→D.**

## Staged chunks (ascending risk — each independently gated + merged; same
file ⇒ sequential)

**A — var-poison cascade suppression (Sonnet).** Poisoned-var `Ref (List Int)`
marked in `typeMismatch` (~L2278), consulted by `checkUndeterminedObligation`
(~L8168). Moves `too_many_args`, `apply_non_function`, `record_wrong_field`,
`wrong_arg_type_in_map` on **X**. Native-authoritative golden churn only; error-
path only → no IR change → no seed re-mint.

**B — DROPPED (premise verified false).** The design pass classified
`record_missing_field`'s secondary `No impl of Debug for Person` as a cascade to
suppress. Reproduced on the post-A binary: a **well-formed** `Person` (all fields
present) STILL errors `No impl of Debug for Person` — records don't auto-derive
`Debug`. So the secondary is a **genuine, independent error** (the user must both
add `age` AND give `Person` a `Debug` impl), NOT a type-poisoning cascade.
Suppressing it would HIDE a real missing-impl. GRADING.md over-scored this as a
cascade (X=1); it is correctly two independent errors → its X is fine as-is.
No snapshot-restore chunk is warranted. (Contrast the four A-handled cascades,
whose secondaries were `ambiguous <C> a` on a *free* var left by the primary —
genuinely spurious.)

**C — `T-NOT-A-FUNCTION` reframe (Opus).** Non-function guard in `inferApp`
(~L4473). Moves `apply_non_function`, `too_many_args` on **C/R**. Error-path only.

**D — Num→`Int vs T` reframe (Opus, fork-2-gated).** ~L8317, literal-provenance
+ ground. Moves `if_branch_mismatch`, `list_heterogeneous`, `cons_type_mismatch`,
`arg_order_swapped`(secondary) on **C/R**. Largest golden blast radius
(`int_vs_string`/`value_restriction`/`mut_generalization` `.tc.golden` +
`type_mismatch.check_json.golden` + several error_quality `.out`) — all native,
re-capturable. Error-path only → no re-mint.

## Verification per chunk
- Each: `make medaka` + `FORCE=1 bash test/build_oracles.sh`, then the affected
  gates: `diff_compiler_typecheck_errors`, `diff_compiler_check`,
  `diff_compiler_check_json`, `diff_compiler_typecheck_golden`, and re-capture
  `test/error_quality_fixtures/` (`capture.sh`) + re-grade the moved fixtures.
- Confirm the diff touches only error/obligation-filtering helpers
  (`checkOneImplObligation`/`checkUndeterminedObligation`/`inferApp`/
  `typeMismatch`), never route-stamping (`rewriteBinopExpr`/`setNumlitFloats`)
  which feeds emit → **fixpoint C3a/C3b must stay YES with no re-mint**.

## Non-goals
- `ambiguous_return` — by-design Num-defaulting (emits no diagnostic). Untouched.
- `record_missing_field`/`record_wrong_field` *primary* messages already good.
- Removing the `numUnimplementableHead` rejects (soundness).
