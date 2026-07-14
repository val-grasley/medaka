# Declaration-Shadowing Semantics (standalone fn ⇄ interface method)

**Status:** ENFORCED — the decision matrix is now a GATE
(`test/diff_compiler_shadow_semantics.sh`, added 2026-07-14): it runs every
fixture in `test/shadow_fixtures/` through `check` + `run` + `build`, asserting
each cell's verdict AND (per **S7**) that `run` and the built binary print the
same pinned value. Every cell is conformant except **S-3** (row 26, multi-typaram
interface), which is pinned as a KNOWN-BAD ledger row so it fails the day it is
fixed. Until this gate existed the corpus below **ran nowhere**, and the matrix's
own Status column had silently gone stale in the OK direction (see the note under
§2). **Scope:** a bare name `N` that is BOTH a top-level standalone function AND
an interface-method name (a "shadow"). Peer of `DICT-SEMANTICS.md` /
`LAYOUT-SEMANTICS.md`: clauses S1–S9, a gated decision matrix, and a per-stage
enforcement table. Where the binary disagrees with a clause, the matrix row says
**BUG** — the spec is the target, not a description of present behavior.

**Why this exists.** This one rule produced four bugs in four different stages
(P0-18 arc: typecheck routing `953d9ea1`, mangle/mark ordering `0b4a7882`,
scheme selection → SIGSEGV, cross-module registration `cfc4fa5a`) because each
stage made its own keying assumption about the same rule (§3 makes those keys
explicit). Fixtures: `test/shadow_fixtures/` (one per matrix cell), run by
`test/diff_compiler_shadow_semantics.sh` — see §4. History/context: memory
`project_phase112_standalone_vs_method`, `qa-beta-2026-07-07/P0-18-*.md`.

## 0. Terminology

- **Shadow**: bare name `N` naming both a standalone top-level fn and an
  interface method visible at the call site.
- **Definer shadow**: the standalone is defined in the *call site's own module*
  (in-tree: `stdlib/map.mdk` + `stdlib/hash_map.mdk` `toList`/`isEmpty`,
  `compiler/frontend/parser.mdk` `orElse` — all applied only to no-impl
  receivers, all route standalone).
- **Importer shadow**: the standalone is *imported* from another module (the
  everyday `import map` → `isEmpty m` pattern; the shadowed interface may live
  in the prelude, in the consuming module, or in a third module).
- **Routes** (`compiler/frontend/ast.mdk:69-72`): `RKey tag dicts` = dispatch to
  the impl whose head tycon is `tag`; `RLocal sym dicts` = NOT a dispatch, call
  the standalone (`sym` = the mangled standalone symbol on the build path, `""`
  on the un-mangled run/check path). **`dicts` is the standalone's OWN
  `=>`-constraint dicts** — see clause **S9**. It is `[]` for an unconstrained
  standalone, which is every one of the compiler's own definer shadows.
  ⚠️ Until 2026-07-13 this document, `ast.mdk` and `eval.mdk` all asserted
  *"RLocal carries no dict"* as a settled **invariant**. That invariant WAS the
  S-1 silent miscompile: it is now false by design. Do not restore it.

## 1. The resolution function (clauses S1–S8)

Given an occurrence of bare name `N`:

- **S1 (shadow-hood).** `N` is a shadow iff `N` ∈ funDef-names(visible
  standalones) ∩ iface-method-names(visible interfaces). Definer vs importer is
  classified by where the standalone is defined; the *interface* may live
  anywhere (local, imported, prelude). Shadow-hood is per-module, per-name — not
  per-occurrence.
- **S2 (applied, grounded receiver — the core rule).** A shadow `N` applied to
  an argument whose type grounds to head tycon `T`:
  - if any impl of the shadowed interface for `T` is visible (the impl universe
    is GLOBAL — local ∪ imported ∪ prelude; instances are coherent across
    modules, cf. `DICT-SEMANTICS.md`) → **method dispatch** (`RKey T`);
  - else → **the standalone** (`RLocal`), and the argument must then type
    against the standalone's declared domain — a mismatch is a **located
    reject** at `check` (and at `run`/`build`, which typecheck first).
- **S3 (N-way).** With multiple impls, each occurrence selects the impl whose
  head matches ITS receiver — per-receiver, per-occurrence; the no-impl receiver
  still falls to the standalone. (Gated: `definer_shadow_nway`.)
- **S4 (value position).** A shadow name NOT syntactically applied to its
  receiver (passed to a HOF, bound with `let`, sectioned) denotes the
  **standalone, always** (Phase 112: a method value has no receiver to dispatch
  on). Consequently value-position use over live-impl elements whose type
  mismatches the standalone's domain is a **located reject** — never a silent
  dispatch, never a runtime panic.
- **S5 (ungrounded receiver).** A shadow applied to a receiver that never
  grounds (a polymorphic parameter) routes to the **standalone**, and the
  enclosing function must **monomorphise to the standalone's domain** — it must
  NOT generalize over the shadow's receiver (a generalized wrapper later called
  at a live-impl type would run the standalone on a foreign value). Calling such
  a wrapper outside the standalone's domain is a located reject.
- **S6 (module-independence).** S2's impl query is location-independent: a
  definer shadow whose shadowed interface and receiver impl are *imported*
  behaves exactly like the all-local case (dispatch on live impl, standalone on
  none). Where the standalone/interface/impl each live changes *detection
  bookkeeping*, never the outcome.
- **S7 (path agreement).** `run`, `check`, and `build` agree on every cell:
  `check` accepts iff `run` and the built binary produce the (identical)
  defined value. A shadow cell where they disagree is a conformance bug even if
  each path is individually defensible.
- **S8 (arity).** The per-receiver machinery in typecheck is gated to
  single-parameter interface methods (`singleParamIfaceMethod`), but the
  *specified* outcome for a multi-param method shadow is the same S2 rule keyed
  on the first parameter. (Observed: the ordinary arg-position dispatch path
  covers this today — matrix row 8.)

### S9 — a CONSTRAINED standalone (added 2026-07-13; closes S-1)

When S2/S4/S5 resolve a shadow occurrence to **the standalone**, and that
standalone is itself `C a => …`, the occurrence is an **ordinary constrained
call**: `C` is solved at the receiver's type and the dictionary is supplied at
the call site, exactly as at a non-shadow call site. **`RLocal` therefore DOES
carry dicts** (`RLocal sym dicts`, mirroring `RKey tag dicts`).

> **The shadowed interface decides WHICH function; the standalone's own
> constraints decide WHICH DICTS. They are different interfaces.**

A `C` with no impl at the receiver's type is a **located reject at `check`**
(`No impl of Num for String` for `size "hi"`), never a runtime panic.

**Why this clause exists.** Both halves of dict-passing key off the same name
sets, and a constrained shadow is in **both**: the marking prePass is a
first-match guard chain whose *shadow* arm is tested **before** the *dict* arm
(`typecheck.mdk` `rewriteRPDict` / `rewriteRPDictArg` / `rewriteArgScoped`), so
the occurrence became `EMethodAt` and was **never marked as a dict application**
— while `dictPassDecl`, keyed on the same dict-name set, still gave the
**definition** its leading dict parameter. Def arity 2, call arity 1: the call
silently **under-applied**, the first real argument landed in the dict slot, and
`build` **exited 0 printing a raw heap pointer**.

**Do NOT "fix" this by reordering the guard chain so the dict arm wins.**
`EDictAt` carries no route and cannot dispatch — that would break matrix row 5
(`size (Box 3)` → the impl), which works. A shadow occurrence is genuinely
*undecided* at mark time; `EMethodAt` is the node that can be either. The fix is
to give its `RLocal` arm a dict channel.

**Tie-break rationale.** *Per-receiver* (not lexical shadowing) because a live
impl is the ground truth of intent — the user wrote a method for that exact
type; unconditional lexical shadowing was the pre-`953d9ea1` behavior and
mis-ran `size (Box 3)` on the standalone. *Standalone-fallback on no-impl*
because the stdlib pattern requires it: `map.mdk`'s `toList : Map k v -> List
(k, v)` must win over Foldable's `toList` for a `Map` (there is deliberately no
`impl Foldable Map`), and rejecting would break every `import map` consumer.
*Bare-name-in-value-position = standalone* because dispatch needs a receiver at
the call and a method value carries no evidence (no dict is threaded at value
position on the arg-tag path) — the standalone is the only coherent denotation.

## 2. Decision matrix (re-observed 2026-07-14, post-`eb92cdff`; now GATED)

Axes: shadow kind × receiver impl-status × topology × use form. "Outcome" is
the S1–S9-specified result; **Status** is what the binary actually does on all
three of run / build / check. Fixtures in `test/shadow_fixtures/`.

> ⚠️ **This column used to be STALE, and that is the reason the gate exists.**
> From 2026-07-10 to 2026-07-14 rows 10 / 12 / 13 / 14 read **BUG** while the
> binary was in fact conformant on all four — P0-19 and P0-20 had fixed them,
> and this table was never updated even though the §5 change-log a few
> paragraphs below *said so*. A spec that says BUG where the binary says OK
> sends the next agent down a wrong hypothesis; that is exactly what it did.
> Every Status below is now re-observed empirically **and enforced by
> `test/diff_compiler_shadow_semantics.sh`**, which drives every fixture
> through `check` + `run` + `build` and pins the value. This column can no
> longer drift without a gate going red.

| # | Cell (kind · receiver · topology · use) | Clause | Specified outcome | Fixture | run | build | check | Status |
|---|---|---|---|---|---|---|---|---|
| 1 | not a shadow — standalone only | S1 | ordinary call | — (whole tree) | — | — | — | BASELINE |
| 2 | not a shadow — method only | S1 | ordinary dispatch | — (construct-coverage gates) | — | — | — | BASELINE |
| 3 | definer · no-impl recv (impl exists for another type) · 1-file · applied | S2 | RLocal → 4 | `d1_definer_noimpl.mdk` | 4 | 4 | accept | **OK** |
| 4 | definer · no-impl recv (interface has ZERO impls) · 1-file · applied | S2 | RLocal → 4 | `d1b_definer_noimpl_zeroimpls.mdk` | 4 | 4 | accept | **OK** |
| 5 | definer · live-impl recv · 1-file · applied | S2 | RKey → 3; RLocal → 4 | `d2_definer_liveimpl.mdk` | 3,4 | 3,4 | accept | **OK** |
| 6 | definer · N-way (2 impls + no-impl) · 1-file · applied | S3 | 3, 30, 4 | `d3_definer_nway.mdk` | 3,30,4 | 3,30,4 | accept | **OK** |
| 7 | definer · live impl at PARAMETRIC head (`impl … (P a)`) · applied | S2 | RKey → 9; RLocal → 4 | `d6_definer_parametric_receiver.mdk` | 9,4 | 9,4 | accept | **OK** |
| 8 | definer · TWO-param method shadow · applied | S8 | dispatch 3; standalone 6 | `d7_definer_multiparam_method.mdk` | 3,6 | 3,6 | accept | **OK** (via ordinary arg-dispatch, outside the S2 machinery) |
| 9 | definer · value position · no-impl elements | S4 | standalone → [2, 3, 4] | `d4_definer_value_pos.mdk` | [2,3,4] | [2,3,4] | accept | **OK** |
| 10 | definer · value position · LIVE-impl elements | S4 | located REJECT | `d4b_definer_value_pos_liveimpl.mdk` | reject `Int vs Box` | reject | reject | **OK** (fixed P0-19 batch 2 `ebb8ee90`; was a 3-way split) |
| 11 | definer · ungrounded recv · wrapper used at standalone domain | S5 | 4; wrapper : Int -> Int | `d5_definer_poly_receiver.mdk` | 4 | 4 | accept (but `useIt : a -> Int` — over-general, the row-12 hole) | **OK** (value), caveat on scheme |
| 12 | definer · ungrounded recv · wrapper CALLED at live-impl type | S5 | located REJECT | `d5b_definer_poly_liveimpl_call.mdk` | reject `Int vs Box` | reject | reject | **OK** (fixed P0-19 batch 1 `ef0874f3`; was a silent miscompile) |
| 13 | definer · no-impl recv · domain mismatch (`size "hi"`) | S2 | located REJECT | `d9_definer_reject.mdk` | reject `Int vs String` | reject | reject | **OK** (fixed P0-19 batch 1 `ef0874f3`; was check-over-accept → build garbage) |
| 14 | definer · live impl, interface+impl IMPORTED · applied | S6 | RKey → 3; RLocal → 4 | `d8_definer_imported_impl/` | 3,4 | 3,4 | accept | **OK** (fixed P0-19 batch 2 `ebb8ee90`; now dispatches cross-module) |
| 15 | importer · live impl · interface LOCAL to consumer | S2/S6 | RKey → 3 | `i1_importer_local_iface/` | 3 | 3 | accept | **OK** |
| 16 | importer · no-impl recv · interface LOCAL | S2/S6 | RLocal → 4 | `i1_importer_local_iface/` | 4 | 4 | accept | **OK** |
| 17 | importer · live impl · interface+impl in a THIRD module | S6 | RKey → 3 | `i3_importer_imported_iface/` | 3 | 3 | accept | **OK** |
| 18 | importer · no-impl recv · third-module interface | S6 | RLocal → 4 | `i3_importer_imported_iface/` | 4 | 4 | accept | **OK** |
| 19 | importer · no-impl own type · PRELUDE interface (the stdlib shape) | S2 | standalone → True/False | `i4_importer_prelude_iface/` | T,F | T,F | accept | **OK** |
| 20 | importer · LIVE prelude impl recv (`isEmpty [1,2]`) alongside the shadow | S2 | method → False/True | `i4_importer_prelude_iface/` | F,T | F,T | accept | **OK** |
| 21 | importer · value position | S4 | standalone | — | — | — | — | UNTESTED-NO-FIXTURE (expected ≡ row 9) |
| 22 | importer · N-way | S3 | per-receiver | — | — | — | — | UNTESTED-NO-FIXTURE (expected ≡ row 6) |
| 23 | return-position method shadow (no receiver param, e.g. `pure`-like) | S4 | value-position rule → standalone | — | — | — | — | UNTESTED-NO-FIXTURE |
| 24 | operator-named shadow (`==` etc.) | — | n/a — operator occurrences resolve through the desugared method-call path, not bare-`EVar` funDef intersection | — | — | — | — | UNREACHABLE |
| 25 | definer · **CONSTRAINED** standalone (`size : Num a => a -> a`) · no-impl recv | S9 | RLocal **carrying the standalone's dicts** → 4 | `d10_definer_constrained.mdk` | 4 | 4 | accept | **OK** (fixed 2026-07-13, S-1 / clause S9; was `check` green + `run` E-PANIC + `build` printing a raw heap pointer) |
| 26 | definer · method of a **multi-TYPARAM interface** (`interface Ix a i`) · applied | S8 (does not cover it) | dispatch 4; standalone 3 | `d11_definer_multityparam_iface.mdk` | **E-PANIC `unknown op '*'`** | 4,3 | accepts | **BUG** (**S-3**; `run` diverges from check+build — an S7 violation. Every entry point gates on `singleParamIfaceMethod`, which counts interface TYPE PARAMS, not method params, so this shadow bypasses the machinery entirely. `check`/`build` happen to be per-receiver CORRECT. Pinned KNOWN-BAD by the gate.) |

**Tally: 19 OK · 1 BUG (row 26 / S-3) · 3 UNTESTED-NO-FIXTURE · 1 UNREACHABLE ·
2 baselines.** Rows 10/12/13/14 were BUG until P0-19; row 25 was BUG until S-1.
Row 26 is the only open cell, and it is a **loud** divergence (`run` panics),
not a silent wrong answer.

## 3. Per-stage enforcement table (clause → site → keying assumption)

The four P0-18 bugs were each a *disagreement between two rows of this table*.
Line numbers at `cfc4fa5a`.

| Clause | Stage / site | What it enforces | **Keying assumption** |
|---|---|---|---|
| S1 detect (run/check, definer) | `compiler/types/typecheck.mdk:11451` `buildDefinerShadows`; single-file seed `:8979`; per-module seed `checkModuleFullImpl:11199-11201` → `definerShadowNamesRef`/`standaloneValuesRef` | this module's funDefs that name a method | **bare-name intersection**: funDefs(`prog`) × `allIfaceMethodNames(accData ++ implDecls ++ prog)` — sees imported *interfaces* only via `accData` (public decls); see row-14 BUG |
| S1 detect (run/check, importer) | `typecheck.mdk:11422` `buildStandaloneShadows` (seeded `:11191`) | imported standalones shadowing a method | imported funDef names minus local names, methods scanned across `implDecls ++ prog` (the `cfc4fa5a` fix: LOCAL interfaces included) |
| S1 detect (build path) | `typecheck.mdk:11475` `computeMangledShadowMap` + `unitMangledShadows:11480`, set once at `elaborateModules:11932` (`mangledShadowMapRef`); consumed by `buildDefinerShadows:11460` and `buildStandaloneShadowsGraph:11487-11497` | recover shadows AFTER mangling renamed the standalone | **forward-constructs `mangledName mid m`** per (module, method) and checks it against actual funDefs — exact, not prefix-stripping; empty map on the un-mangled path (inert) |
| S1 mark | `typecheck.mdk:11942` `markRpNames` (∪ `buildStandaloneShadowsGraph`) → `prePassDictArg`/`prePassModulePairArg:11943-11944` rewrite occurrences to `EMethodAt` | occurrences get a route ref | graph-wide name set over USER modules (core excluded) |
| (enabler of the S1 build split) | `compiler/backend/private_mangle.mdk`: `mangleUnits:117`, `buildUnitRenameMap:372`, `renameDecl` DFunDef `~578` + `renameScoped` EVar `~651` rename the standalone def + refs to `<mid>__N`; `renameIfaceMethod:626`/`renameImplMethod:636` leave the method **NAME bare** (header `:34-46`: dispatch is by bare name cross-module) | collision-free private symbols | **the asymmetry**: standalone side mangled, method side bare — which is exactly what defeated name-intersection detection (bug `0b4a7882`); driver order `compiler/entries/entry_support.mdk:133-134` (`runEmitWith`) and `:145-146` (`emitModulesWith`): mangle STRICTLY before mark |
| S2 type + record (definer) | `typecheck.mdk:4909-4912` app-head peel → `definerShadowArgHead:5015` (gated `singleParamIfaceMethod:4969`; fires on `definerShadowNamesRef` OR a mark-seeded `RLocal sym` — the cross-module emit signal) → `inferDefinerShadowApp:5029` + `definerShadowHeadType:5062` | type against the STANDALONE scheme (via the mangled sym on build — the scheme-selection SIGSEGV fix), record the ACTUAL argument mono | route symbol non-empty ⇒ shadow (works cross-module on build); `definerShadowNamesRef` ⇒ shadow (run/check, module-local only) |
| S2 type + record (importer) | `typecheck.mdk:4950` `shadowStandaloneHead` → `inferShadowApp:4979`; standalone schemes stashed in `shadowStandaloneSchemesRef` (`checkModuleFullImpl:11210`, concrete-head pick); impl query table `shadowKeyTableRef` (`:11217`, includes LOCAL impls per `cfc4fa5a`) | live-impl head ⇒ ordinary app (dispatch); else instantiate the IMPORTED standalone scheme + stamp `RLocal` | standalone scheme = the seedVars entry whose first arrow domain has a **concrete head tycon** (never the poly method scheme) |
| S2 no-impl obligation skip | `typecheck.mdk:4670` `recordImplObligation`, skip arm `:4688` | a no-impl shadow receiver is a legitimate standalone fallback, not `No impl of …` | bare name ∈ `definerShadowNamesRef` ∪ `standaloneValuesRef` — skips the obligation for EVERY occurrence of the name, impl-having or not (this un-checks row 13: the domain mismatch is never re-imposed) |
| S2/S3/S5 route stamping | `recordRLocalSite:3456` (gated on `standaloneValuesRef`, suppressed inside `inferDefinerShadowApp`); `resolveRLocalSites:6978` / `resolveRLocalSite:6991`: grounded head + `implExistsForHead` → leave route (dispatch) else `RLocal sym` (`stampRLocalOrFallback:7011`); ungrounded → `RLocal` for definer shadows (`:7006`); build-path RKey via `pendingArgStamps` push (`:5054`) → `resolveArgStamps` | per-receiver decision, deferred to post-inference grounding | receiver mono = the ACTUAL argument mono recorded by `inferDefinerShadowApp` (NOT the standalone's declared domain — the `953d9ea1` fix); impl existence per **head tycon only** |
| route representation | `compiler/frontend/ast.mdk:69-72` (`RKey`/`RLocal String`); sexp `compiler/ir/core_ir_sexp.mdk:43-44` (`RLocal ""` serializes to the old nullary form) | ONE occurrence needs TWO names: bare `N` for dispatch, `<mid>__N` for the standalone | the mangled standalone symbol is **carried in the route**, stamped at resolve time (Fork-2 carry-in-route) |
| lowering | `compiler/ir/core_ir_lower.mdk:144` `EMethodAt name … → CMethod name …` | route + both names survive to the backends | `name` is the single bare field; the RLocal symbol rides the route |
| emit (LLVM) | `compiler/backend/llvm_emit.mdk:3413` `emitMethod … (RKey tag)` → `implFor e name tag`; `:3435` `… (RLocal sym)` → `emitKnownFnSat e ("mdk_" ++ sym)` | S2's two arms at codegen | RKey needs the **bare** method name; RLocal needs the **mangled** symbol |
| emit (WasmGC) | `compiler/backend/wasm_emit.mdk:3076` `emitMethodRef … (RLocal sym)` (peer arm, header `:3071`) | same split, second backend | same two-name split |
| eval | `compiler/eval/eval.mdk` `evalMethodAt … (RLocal sym dicts)` → standalone via env lookup, **then `applyDicts … dicts`** (S9); other routes → arg-tag/dict dispatch (`methodAtNarrow` treats RLocal as not-a-dispatch; `dictOfRoute (RLocal _ _)` is the no-op dict — RLocal's dicts are the call's leading dict ARGS, not a witness FOR the route) | S2 + S9 on the interpreter | run path is UN-mangled: `sym` is `""` and the bare name resolves to the standalone lexically |
| S9 dicts (typecheck) | `shadowStandaloneDicts` / `shadowStandaloneDictSlotsAt` (slot monos, expanded-supers, from the SIGNATURE's id space) → carried on `pendingRLocalSites` (an `RLocalSite` record) → resolved **inside** `resolveRLocalSites` via `routesOfMonosTop` | the standalone's own `=>` dicts, stamped by the SAME single writer as the route | ⚠️ resolve them **inside the stamp** — `resolveRLocalSites` runs BEFORE `resolveDictApps` in `elabModuleStamp`, so routing them through `pendingDictApps` reads `[]` and reproduces the bug with more code |
| S9 reject direction | `recordStandaloneSigObligations` → `pushCallObl` → `checkCallObligations` | `size "hi"` ⇒ located `No impl of Num for String` | ⚠️ obligations must come from the **signature**, not `schemeObligationsRef`: for a signatured binding those are **different id spaces** (generalization vs `sigToSchemeTvs`), so the id lookup silently finds nothing |

## 4. The gate (`test/diff_compiler_shadow_semantics.sh`)

**The matrix in §2 is enforced.** One gate owns the whole corpus
(`test/shadow_fixtures/`, 17 fixture units — 13 single-file `.mdk` plus the
`d8`/`i1`/`i3`/`i4` multi-module directories), and for each it drives all three
paths and asserts:

- the **verdict** — `check`, `run`, and `build` each ACCEPT or REJECT exactly as
  the cell specifies; and
- the **value** — for a cell all three accept, `run`'s stdout and the **built
  binary's** stdout must be byte-identical to each other *and* to a pinned
  expectation. This half is not optional: **S7** is a claim about values, and an
  exit-code-only gate cannot see the bug class this arc keeps producing (P0-20:
  `build` exits 0 while printing a wrong number; S-1: `build` exits 0 while
  printing a raw heap pointer). Both would have graded PASS.

Two properties that keep it from rotting:

- **A coverage self-audit.** The gate diffs the fixture directory's actual
  contents against its own table and FAILS if a fixture is ever added without
  being wired in — the orphan-corpus failure this gate was written to end.
- **KNOWN-BAD rows are a ledger, never a skip-list.** An open bug (today: row 26
  / **S-3**) is pinned to its *current, wrong* behavior, so it is asserted on
  every run and goes **red the day it is fixed** — which is the signal to correct
  the row. This is not theoretical: `d10` (row 25) was added as a KNOWN-BAD row
  pinning the S-1 miscompile, S-1 landed, and the gate went red on the next run.

CI: the `types` shard (`.github/workflows/ci.yml`); `diff_compiler_ci_shard_coverage`
enforces that it is in exactly one shard.

Still **UNTESTED-NO-FIXTURE** (rows 21–23): importer value-position, importer
N-way, and a return-position method shadow. Adding those three fixtures is the
next mechanical step — the gate picks them up automatically once a row is added
to its table (and its coverage audit will fail until one is).

## 5. Residuals — HISTORICAL (all four now CLOSED; kept for the repro + root cause)

> **All four cells in this section are FIXED** (P0-19 batches 1–2, 2026-07-10;
> see the update notes at the end of the section). They are kept because the
> repro and the root cause are the useful part — and because *this section
> saying "fixed" while §2's table still said BUG for the same four rows* is
> precisely the drift the §2 gate now prevents. Read §2's table for current
> status; it is the one that is enforced.

1. **Row 10 — value-position shadow over live-impl elements: three-way split.**
   `d4b`: `map size [Box 1, Box 2]` → check ACCEPTS, run E-PANICs (`unknown op
   '+'` — the standalone on a `Box`), build prints `[1, 2]` (dispatches to the
   impl!). Hypothesis: eval honors S4 (bare value = standalone) while the emit
   path's marked `EMethodAt` value-position occurrence falls into method
   arg-dispatch, and check types the occurrence permissively (obligation
   skipped) — three stages, three different S4 answers.
2. **Row 12 — generalization over the shadow receiver: silent miscompile.**
   `d5b`: `useIt x = size x; useIt (Box 3)` → check ACCEPTS (`useIt : a ->
   Int`), run E-PANICs, build prints a garbage integer (Box pointer + 1).
   Hypothesis: the ungrounded-receiver occurrence is typed against the
   polymorphic METHOD scheme, so the wrapper generalizes instead of
   monomorphising to the standalone's domain (S5), and the RLocal route then
   runs the standalone on any argument.
3. **Row 13 — no-impl + domain mismatch: check over-accepts, build garbage.**
   `d9`: `size "hi"` → check ACCEPTS, run E-PANICs, build prints garbage.
   Hypothesis: `recordImplObligation:4688` skips the impl obligation for every
   occurrence of a shadow name, and nothing re-imposes the standalone's domain
   on the check path — the S2 "must then type against the standalone" half is
   unenforced.
4. **Row 14 — definer shadow with imported interface+impl: no dispatch.**
   `d8`: local `size : Int -> Int`, `import prov.{Sizeable, Box(..)}`,
   `size (Box 3)` → all three paths reject `Type mismatch: Int vs Box`
   (consistent, loud — but S6 says dispatch to 3). Hypothesis: on the
   multi-module run/check path the occurrence is typed directly against the
   local standalone before any per-receiver machinery fires — the
   definer-shadow app path or its `shadowKeyTableRef` impl query doesn't span
   the imported impl universe for a LOCAL standalone.

Rows 12 and 13 are **silent build soundness holes** (check accepts, binary
prints garbage) — the same severity class as the original P0-18 build hole, and
strong candidates for the next fix batch, with rows 10/14 folded in as the
same "which stage owns S4/S6" decision.

> **✅ UPDATE (2026-07-10, `ef0874f3` — P0-19 batch 1):** rows **12 (d5b)** and **13
> (d9)** are FIXED — both now `check`/`run`/`build` REJECT with a located
> `Type mismatch` (`enforceStandaloneDomain` re-imposes the standalone's declared
> domain whenever a definer-shadow occurrence resolves to the standalone, on both
> the marked run/build path and a new un-marked `EVar` check path; gated by
> `shadowKeyTableRef` so live-impl receivers still dispatch). Regression fixtures
> `test/run_check_agreement_fixtures/p0_19_{poly_wrapper_shadow,noimpl_domain_mismatch}`
> (`.expected=REJECT`); agreement gate 22/0, fixpoint C3a/C3b YES. Bonus: row 11's
> over-general wrapper scheme (`useIt : a -> Int`) is fixed to `Int -> Int`.
>
> **✅ UPDATE 2026-07-10 (P0-19 batch 2, `ebb8ee90`, main `ebb8ee90`) — the last two
> cells CLOSED; all 4 BUG cells now conformant.** Row **10 (d4b)** value-position
> now REJECTs `Int vs Box` (d4 over-Int still accepts `[2,3,4]`): a new
> `shadowHeadCtxRef` flag distinguishes "shadow `EVar` as app head" (keeps the
> method scheme for dispatch) from "bare value position" (pinned to the standalone
> scheme via `maybeStandaloneValueMono`). Row **14 (d8)** now DISPATCHES cross-module
> (run+build print `3`,`4`, matching d2): `shadowKeyTableRef` seeded from the global
> `accData ++ implDecls ++ prog` (was missing the imported impl on the check path),
> and both definer-shadow app paths decide per-receiver — a receiver with a visible
> impl fetches the method scheme from `methodIfaceParamsRef`, else the standalone
> scheme. Fixtures `p0_19_value_pos_{shadow=REJECT,ok=ACCEPT}` + a d8 leg in
> `diff_compiler_check_cli_modules` (14/0); agreement 24/0, fixpoint C3a/C3b YES.

> **🐛 NEW CELL + ✅ FIX (2026-07-13, P0-20) — row 25: a LITERAL receiver.  The worst
> cell in the arc: `check` accepted, `run` panicked, and `build` SILENTLY PRINTED A WRONG
> NUMBER.** The matrix above varies the *shape* of the receiver (grounded / ungrounded /
> dict-bound) but never its *provenance*, and that is where the hole was:
>
> ```
> eq : Int -> Int -> Int      -- a definer shadow of the PRELUDE's `Eq` method
> eq a b = a + b
> main = println (eq 1 2)     -- check: Int · run: E-PANIC · build: prints 0
> ```
>
> A **numeric literal is `Num a => a`, i.e. UNGROUNDED at inference time**, so typecheck
> took the S5 (ungrounded ⇒ standalone) arm and typed the site against `eq : Int -> Int ->
> Int`. But typing it against the standalone *unifies `Int` into the receiver* — so by the
> time the POST-inference route resolver (`resolveRLocalSite`) ran, the receiver WAS
> grounded, to `Int`, which has `impl Eq Int`, and it left the site to **dispatch**. The
> TYPE came from one arm and the ROUTE from the other. `eq 1 2` evaluated to a `Bool` that
> `println` rendered with `Display Int`: `run` panicked (`intToString: not an Int`), and
> the native binary printed **`0`** with exit 0. (With a user interface whose method
> returns a `String` the binary printed a raw heap **pointer**; with `abs` it SEGFAULTED.)
> Only literal receivers were affected — `f k = eq k 1` (k : Int, grounded on arrival)
> dispatched consistently on all three paths, which is why the arc missed it.
>
> Per **S2 the answer is DISPATCH** (the receiver grounds to `Int`; `Eq Int` has an impl),
> so `eq 1 2` is now `False` on check == run == build, and the user's own `eq` is reachable
> only at a type with no `Eq` impl — exactly as `d2` already specified for `Box`.
>
> Fix (`compiler/types/typecheck.mdk`): `groundShadowReceiver` performs S5's
> monomorphisation to the standalone's declared domain **BEFORE** the dispatch decision, so
> typecheck asks the S2 impl question about the SAME head the route resolver will see; and
> `pendingRLocalSites` gained a `forceLocal` flag so **the route FOLLOWS THE ARM** typecheck
> actually took instead of being independently re-derived post-inference. The domain lookup
> is sym-aware (`shadowDomainFor`) — on the mangled emit path the standalone is
> `<mid>__eq`, so a bare-name sig lookup is silently inert there, which flips *build* to the
> standalone while check/run dispatch (the same bug, mirrored).
>
> Fixtures: `test/run_check_agreement_fixtures/p0_20_shadow_literal_{receiver,user_iface,
> result_pinned,noimpl_standalone}` — and that gate now also compares the **VALUE** (`run`
> stdout == the built binary's stdout, plus an optional `.out` pin). It graded exit codes
> only, so a build that exits 0 while printing a wrong number was invisible to it: **the
> gate that owns this bug class could not see this bug.** Agreement 42/0, run_gates 83/0/0,
> fixpoint C3a/C3b YES.
>
> **Residuals found while closing this (both pre-existing on `main`, both filed):**
> 1. ~~**A definer shadow whose standalone is CONSTRAINED (`size : Num a => a -> a`) is
>    miscompiled**~~ — **FIXED 2026-07-13 (S-1; see clause S9).** `check` accepted, `run`
>    panicked, and `build` **exited 0 printing a raw heap pointer**, even with no impl at
>    the receiver head. The filing's mechanism was *close but wrong in the way that changes
>    the fix*: the `RLocal` route did not **drop** a dict — **no dict was ever computed for
>    the occurrence**, because the marking prePass's shadow arm is tested before its dict
>    arm, so the call was never marked an `EDictAt` while the *definition* still got its
>    dict param. `RLocal` now carries the standalone's own dicts (S9).
> 2. **A multi-TYPARAM interface (`interface Ix a i`) bypasses the whole definer-shadow
>    machinery** (every entry point is gated on `singleParamIfaceMethod`, which counts
>    interface TYPE PARAMS, not method params). `check` and `build` agree, `run` panics.
>    S8 speaks to multi-*param methods*; it does not cover multi-*typaram interfaces*.

> **🐛 NEW CELL + ✅ FIX (2026-07-14, P0-21) — row 27: S1 ("shadow-hood is per-module")
> was NOT enforced on the single-file/flat path — a user's shadow LEAKED INTO THE
> PRELUDE.** Every cell in the matrix above varies the shadow's *use*; none of them asks
> **whose module the occurrence is in**. That is where the hole was:
>
> ```
> map : Int -> Int      -- defined, and NEVER USED
> map n = n + 1
> main = println "hello"
> ```
>
> **14 errors**, every one of them raised inside the PRELUDE's own bodies
> (`map2`/`map3`/`replaceWith`/`discard` in `stdlib/core.mdk` all call `map`), all reported
> against the user's file at a fabricated `1:0` — including `'map' takes 1 argument(s) but
> is applied to 2` for a call the user never wrote. This is also the source of the
> separately-filed fabricated-`1:0` diagnostics.
>
> Root cause: `checkProgramSeeded` was handed ONE flat program, `core ++ user`, computed
> `buildDefinerShadows prog prog`, and then applied that single name set to **every
> occurrence in the flattened program, core's included**. The multi-module path never had
> this — `checkModuleFullImpl` seeds the shadow set per module and checks `core` in
> isolation, which is why `helper.mdk`'s `map : Int -> Int` and `other.mdk`'s
> `map (x => x*2) [1,2,3]` have always both worked.
>
> Today the leak was "only" a TYPING leak — a leaked prelude occurrence with a live-impl
> receiver still dispatched, so `println 42` and `elem 9 [1,2,3]` were merely accompanied
> by spurious errors, not miscompiled. **That stops being true the moment S2 is inverted so
> a standalone WINS over a same-named method**: the same leaked occurrence would then ROUTE
> the prelude's `println` into the user's `display`. So this is Stage 0 of the inversion
> arc (`compiler/SHADOW-INVERSION-DESIGN.md`) and had to land first.
>
> Fix (`compiler/types/typecheck.mdk`): the flat path now knows **where the prelude ends**.
> Every driver that flattens the prelude into what it checks (`desugar coreP ++ desugared`)
> passes the two halves separately — `checkProgramSeededSplit seed coreProg userProg`
> (`checkToLinesWithRuntime` / `checkErrorsWithRuntime` / `checkProgramDiags` /
> `checkProgramSchemes{,WithRuntime}` each gained the parameter). With the boundary known,
> `definerShadowNamesRef` is scoped exactly as `checkModuleFullImpl` scopes it: it is the
> USER module's shadow set (`buildDefinerShadows prog userProg`) and is toggled **empty
> while a CORE-owned letrec group, or core's impl/default/prop/test bodies, is inferred**
> (`flatShadowScopingRef` / `flatCoreFnNamesRef` / `flatUserShadowNamesRef`,
> `scopeShadowsForGroup`). Every consumer of that ref — `definerShadowVarHead`,
> `definerShadowArgHead`, `maybeStandaloneValueMono`, `recordImplObligation`'s skip arm,
> `resolveRLocalSite` — becomes per-module for free. All three refs are cleared by
> `resetState` and set ONLY by a `checkProgramSeededSplit` with a non-empty prelude, so the
> multi-module path and every prelude-free probe path are byte-identical.
>
> The `=>`-constrained-receiver carve-out (`definerReceiverIsDictVar`) is UNCHANGED and
> still load-bearing — it is what keeps a *user's* constrained fn dispatching through its
> dict in a shadowing module (`accept_constrained_receiver_shadow`). It is no longer what
> saves the prelude's own `neq x y = not (eq x y)`; the prelude is now simply not in the
> shadow's scope.
>
> Fixtures: `test/run_check_agreement_fixtures/p0_21_prelude_shadow_scope` (ACCEPT — the
> repro, plus a *used* `map 3` → 4 alongside prelude `map2`/`discard`/`elem`/`length`) and
> `p0_21_prelude_shadow_scope_reject` (REJECT — `map "hi"`, proving the machinery is still
> live inside the user's own module and P0-19's row-13 hole stays closed). Agreement 46/0,
> run_gates 83/0/0, fixpoint C3a/C3b YES, `make test` green.
>
> **Residual (unchanged, pre-existing):** inside a module that DOES shadow, a
> multi-*param* method (`map : (a -> b) -> f a -> f b`) still peels only its FIRST argument
> as the receiver, so `map (x => x*2) [1,2,3]` in a file that also defines `map : Int ->
> Int` is rejected `Int vs a -> a`. This is the S8 residual, not S1: the already-correct
> multi-module path rejects the identical shape identically, so the two paths now AGREE.
---

## 6. S-1 residuals (open; grep `S1-RESIDUAL`)

Found while closing S-1 (2026-07-13). **Neither is a regression and neither is a silent
wrong answer** — both were already broken on `main`, and both now fail *loudly*. They are
the two shadow occurrences that do **not** flow through an application-head arm.

### S1-RESIDUAL-A — value-position shadow miscompiles at emit (NOT an S-1 bug)

`map size [1,2,3]` (a bare shadow occurrence passed to a HOF) **segfaults at `build`** and
`illegal cast`es under WasmGC. `run` is correct.

⚠️ **This is NOT caused by the constraint, and NOT by S-1.** Verified: an **unconstrained**
shadow (`size : Int -> Int`) in value position segfaults *identically*, and that takes the
`dicts == []` path — byte-identical to pre-S1 codegen. The bug is in the value-position
lift itself (`llvm_emit.mdk` `emitMethodValue` / `emitMethodValDefine`, wasm's
`emitRefExpr` peer), which builds a closure of `methodArityOf name` — the **interface
method's** arity — for a body that calls the **standalone**. S-1's design doc mis-attributed
this row's `build` failure (it saw a GC OOM) to the missing dict.
*Fix location:* `compiler/backend/llvm_emit.mdk` `emitMethodValue`; wasm peer.

> ⚠️ **DOES NOT REPRODUCE as written (2026-07-14, first run of the new gate, on
> `main` post-`eb92cdff`).** Both shapes this entry names build and run
> **correctly**: the unconstrained `size : Int -> Int` + `map size [1,2,3]` is
> fixture `d10`'s neighbour `d4_definer_value_pos.mdk`, which the gate grades
> ACCEPT/ACCEPT/ACCEPT with `build` printing `[2, 3, 4]` (30/30 runs, exit 0, no
> SIGSEGV); the constrained `size : Num a => a -> a` in the same position also
> prints `[2, 3, 4]` on check/run/build. So either the repro needs a shape not
> named here (the stated mechanism — a closure built at `methodArityOf name` for
> a body calling the standalone — requires the method and standalone arities to
> **differ**, and in both shapes above they are both 1), or the S9 landing closed
> it as a side effect. **Needs re-confirmation from the filer with an exact
> repro.** Do not spend time chasing it from this text alone; `d4` now pins the
> working behavior, so if it is a live latent bug the gate will catch it the
> moment it bites.

### S1-RESIDUAL-B — importer shadow on an UNGROUNDED receiver under-applies on `run`

`import prov.{size}` where `prov.size : Num a => a -> a` shadows a local interface method,
called as `size 3`: **`build` and `wasm` are correct (4); `run` still under-applies.**

Cause: a `Num` literal receiver is not grounded when `inferShadowApp` asks
`headTyconMono tx`, so it never reaches that function's *standalone* arm (which does compute
the dicts) and falls to its ordinary-app arm. The occurrence is then recorded by the generic
`recordRLocalSite`, whose dict slots come back empty for this cross-module case. `build` is
unaffected because an importer shadow reaches the standalone through the **mangled symbol**
via `inferDefinerShadowApp`, which does compute them. `inferShadowApp` lacks the
`groundShadowReceiver` call that P0-20 added to `inferDefinerShadowApp` — that asymmetry is
the likely root.
*Fix location:* `compiler/types/typecheck.mdk` `inferShadowApp` (add the P0-20 grounding) or
`recordRLocalSite`'s cross-module slot resolution.
