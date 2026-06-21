# Dictionary-Passing Conformance Roadmap

**Companion to** [`DICT-CONFORMANCE-AUDIT.md`](DICT-CONFORMANCE-AUDIT.md) and the
target spec [`DICT-SEMANTICS.md`](DICT-SEMANTICS.md). This document sequences the
work to bring the **canonical** implementation (`selfhost/*.mdk` → `./medaka`)
into conformance with the formal dict-passing semantics.

## STATUS — overnight 2026-06-21: roadmap substantially CLOSED

All conformance D-items are resolved (closed, or deferred-with-justification). Each
landing below was reproduced on the binary first, fixpoint-verified (C3a/C3b YES),
and merged to local `main`. Sequence of commits: `afe4b89`→`72a1477` (+ D9).

| Item | Status | Commit / note |
|------|--------|---------------|
| **D1** existence gate (WS-1a) | ✅ closed | `afe4b89` + multi-module over-reject fix `00cf2f7` |
| **D1** dispatch (WS-1b) | ✅ closed | sole-impl emit fix `83bb5c7` + `expand_supers` flatten `db091fd` + **ambiguity-defaulting `72a1477`** (sole→default / ≥2→`AmbiguousImpl`). Return-pos superclass under a `=>` constraint now run==build==oracle (sole 43, chain3b 1005). |
| **D2** cross-module arity collision | ✅ closed | `e488cd9` (module-qualified define-side arity). **Full re-key (Option B) DEFERRED as net-negative** — empirically proven (agent `a95c…`): `e488cd9` IS the principled module-qualified re-key; the call site is already definer-correct via scheme resolution (not bare-name); remaining bare table serves a collision-free E6 job. D2 dissolved (verified 3-way 1/2/3 reversed-order, unsignatured-promoted). Adding an `EVar` origin field = eval-dict footgun risk for zero gain. |
| **D3** global coherence | ✅ closed | `84642d0` — orphan cross-module `impl C T` conflicts rejected (names both modules); user-only impl set (prelude excluded); fixpoint = selfhost-self-coherence canary. |
| **D4** return/phantom overlap | ✅ closed | `fdaefda` (WS-3) — most-specific-wins route stamped for ground return-position. |
| **D5/D6** well-formedness (WS-4) | ✅ closed | `adbbb97` — cyclic-superinterface rejected; instance-termination depth fuse. |
| **D7** supers fidelity | ✅ sufficient | `expand_supers` flatten (`db091fd`) closes the dispatch gap; the two-field `VDict.supers` record (deluxe form) is non-defect / observationally-equivalent — not pursued. |
| **D8** phantom-position | ✅ closed | `aa020b0` (WS-5) — method not mentioning its interface param rejected at check. |
| **D9** vestigial argStamp flag / **D10** stale docs | ✅ closed | `121b9dc` — `argStampEnabled`→`emitArgStampPasses` rename + 2 inert flag/guard removals (parity probe 26/26, provably zero behavioral change) + stale-comment corrections in the gap docs. |

**Found bugs — FIXED this session (not conformance items, surfaced in passing):**
- ✅ `medaka check` SIGTRAP on a `Map`/`Set` literal — RESOLVE stage missing `EHeadAnnot` arm (`Map{}` desugars to `EHeadAnnot`, fell off the match → panic). Fixed `1765007` (`resolve.mdk` arm mirroring the oracle: `import map.*` accepts, bare/no-import rejects `UnknownType`, never crashes).
- ✅ `stdlib/json.mdk` / any multi-module import → spurious `No impl of Ord for Int` — `checkCallObligations` (`typecheck.mdk:8188`) omitted `accData` (where prelude `impl Ord Int` lives) while sibling `checkImplObligations` included it. Fixed `1765007` (thread `accData` — unifies the N>1 obligation universe with N=1).

**Newly-discovered — NOT fixed (logged for follow-up):**
- **Bug C:** `toList` on a `Map` — native `check` rejects `No impl of Foldable for Map a` (and misdispatches at runtime), while the oracle accepts. Root: `toList` is BOTH `map.mdk`'s standalone fn (`map.mdk:350`) AND a `Foldable` method; native resolves to the *method* (needs `Foldable (Map a)`) instead of the imported *standalone*. Phase-112 standalone-vs-method resolution territory. Was masked by the SIGTRAP above; surfaced once it was fixed.
- The OCaml oracle is **known-wrong** on ambiguous multi-impl dispatch (silent first-declared-wins); native now rejects (`AmbiguousImpl`) — an intentional native>oracle divergence (like cyclic/phantom).

## 0. Principles

- **Target the canonical binary.** The OCaml `lib/*.ml` oracle is frozen and being
  retired; do not invest in its divergences except as a *porting source* (it
  already implements some checks selfhost lacks — D1, D4).
- **Close gaps generally, not per-symptom** (project ethos). D2 and D3 share one
  root (identity is bare-name, IE is per-module); fix the root, retire the
  containment workarounds — don't add another scope filter.
- **Keep observational-equivalents and deliberate design choices.** D7
  (param-threading vs closure-capture) and the most-specific-wins overlap policy
  (D4) are *not* defects to "fix"; they are non-goals (§6) unless a real
  divergence forces them.
- **Verify on the binary, differentially.** Every change must keep
  `diff_selfhost_*` green and add a fixture that fails before / passes after. The
  frozen oracle remains a useful second opinion during the soak (D1's fix should
  make native *match* the oracle's `MissingSuperImpl` rejection).

## 1. Priority and dependency order

```
        ┌─────────────────────────────────────────────┐
        │ WS-4a  W1 acyclic-supers guard  (must precede │
        │        any superclass-evidence wiring)        │
        └───────────────────┬───────────────────────────┘
                            │ unblocks
        ┌───────────────────▼───────────────────────────┐
   D1   │ WS-1  Superclass evidence                      │  SOUNDNESS — do first
        │   1a existence gate (port, cheap)              │
        │   1b supers-tree + projection route (spec-true)│  folds in D7
        └────────────────────────────────────────────────┘
   D2   ┌────────────────────────────────────────────────┐
   D3   │ WS-2  Module-qualified dict identity + global IE│  SOUNDNESS+COHERENCE
        │       (one root for I1 collision and C4/I2)     │  cross-cutting
        └────────────────────────────────────────────────┘
   D4   WS-3  Dispatch-lookup uniqueness for return/phantom overlap   COHERENCE
   D6   WS-4b W2 instance-termination guard                            ROBUSTNESS
   D8   WS-5  Phantom-position: reject-at-check or document            FIDELITY
 D9,D10 WS-6  Strict-§7 cleanup + doc/comment hygiene                  CHEAP WINS
```

**Do-now cheap wins (independent, low-risk, land any time):** WS-4a, WS-4b, WS-5,
WS-6.

> **CORRECTION (2026-06-20, empirically established — see WS-1b below).** The graph
> above is wrong on two edges. **WS-1a is DONE** (`afe4b89`+`00cf2f7`). **WS-1b is
> NOT blocked by WS-4a** — `expand_supers` is one-level/non-recursive and cannot
> hang on a cycle, so the acyclic guard was never its gate. The spec-true WS-1b
> (superclass-evidence flatten) is instead **BLOCKED BY WS-2**: appending a super
> dict slot to `clamp : Ord a` (Ord requires Eq) trips the **bare-name dict-arity
> under-fill (D2)** → SIGSEGV. Real order: **WS-2 (identity-keyed dict arity) →
> WS-1b**. The concrete return-position SIGTRAP WS-1b targeted is already CLOSED via
> an emitter sole-impl-dispatch fix (`83bb5c7`), so WS-2 is now the next item.

## 2. Workstreams

### WS-1 — Superclass evidence (closes D1; folds in D7) — **highest priority**

**Spec:** §3 `super` (projection), §6 C2 (existence + consistency), §5
(return-position superclass dispatch). **Lands in:** `selfhost/types/typecheck.mdk`
(+ `selfhost/frontend/ast.mdk` for the new route, `selfhost/eval/eval.mdk` and
`selfhost/backend/llvm_emit.mdk` + `wasm_emit.mdk` for projection). **Skill:**
`add-language-feature` (threads a route through ast → typecheck → eval → emit).

Two stages; ship 1a first (restores soundness floor), then 1b (spec-true form).

**WS-1a — existence gate (minimal, restores oracle parity). ✅ DONE (2026-06-20, `afe4b89`).**
Ported as `checkSuperImpls` (+ `ifaceSupersOf`/`superImplExists`/`tyIsConcrete` helpers) in
`selfhost/types/typecheck.mdk`, wired at all 5 `checkCoherence` driver sites; needed `Super(..)`
added to the `frontend.ast` import (the missing ctor import was SIGTRAPping under the gap-tolerant
emitter). Concreteness gate mirrors the oracle: parametric `impl Monoid (Bag a)` is deferred;
concrete `impl Monoid Color` without `impl Semigroup Color` now rejects with the byte-identical
message. Fixture `test/typecheck_error_fixtures/missing_super_impl.mdk`. Gates green (typecheck_errors
36/0, check 51/0, eval_dict 26/0); fixpoint C3a/C3b YES (orchestrator-verified). **Multi-module
verified + over-rejection fixed (`00cf2f7`):** the gate fires correctly in the multi-module path too
(single-file *and* imported impls); an initial under-rejection worry was disproved empirically. The
real multi-module defect was the OPPOSITE — an **over-rejection**: `checkModuleFullDiags` searched
`accData ++ prog` for the super-impl, but `accData` (via `publicDataDecls`) drops `DImpl`, so a valid
`impl Monoid Color` whose `impl Semigroup Color` lived in an *imported* module was falsely rejected.
Fixed with a parallel `accImpls` accumulator (`allImplDecls`, threaded through `checkModulesDiagsGo`/
`checkModulesEntryFullGo`, seeded from `coreDecls`) feeding `checkSuperImpls prog (accImpls ++ accData
++ prog)` — `accData` left untouched so `buildOracle`/`registerAllData` are unperturbed. Guard legs in
`test/diff_selfhost_check_cli_modules.sh` (7/0). **No residual under-rejection.**

Port `check_superinterface_obligations` (`lib/typecheck.ml:4857-4875`) into
selfhost as a self-contained post-pass over the impl table using the already-stored
interface `supers` field: for each `impl C T`, require `impl D T` to exist for every
`D ∈ super(C)`, else emit `MissingSuperImpl`. Wire it into the same driver sites as
`checkCoherence` (`typecheck.mdk:4915` neighborhood; the 6 invocation sites). This
alone closes the **declaration-site** half of D1 and makes
arg-position superclass dispatch *sound* (the impl is guaranteed present).
- *Gate:* a fixture `impl Mon Bag` without `impl Sem Bag` must move from native
  `check` rc 0 → rc 1 with `MissingSuperImpl`, matching the oracle. Existing
  `diff_selfhost_*` stay green.
- *Effort:* low. *Risk:* low (additive check; the only risk is over-rejecting a
  legitimate program — mirror the oracle's exact predicate, including default/named
  impl handling).

**WS-1b — `supers` evidence + projection route (spec-true; also closes D7).**
**PARTIAL (2026-06-20, `83bb5c7`): the concrete return-position SIGTRAP is CLOSED;
the spec-true `expand_supers` evidence is DEFERRED behind WS-2 (see below).**

> **Empirical finding (supersedes the plan below).** The motivating bug was a real
> run≠build divergence: a return-position superclass method under a subclass-only
> constraint (`build : Sub a => Int -> a; build n = mk n`, `mk` from super `Sup`)
> ran correctly in the interpreter (`107`) but the native binary **SIGTRAPped**.
> Diagnosed: the ambiguous constraint var is unpinned, so the site routes `RNone`
> → passes a **null dict** (`i64 0`); `emitMethodDispatch` did `inttoptr 0; load`
> → null-deref. Fixed narrowly + generally in `selfhost/backend/llvm_emit.mdk`: a
> **sole-impl method** (one tagged impl, no `requires` element dicts) now dispatches
> by **direct call**, skipping the dict head-tag load — mirroring eval's
> `narrowMethod`/`oneOrMultiV` sole-impl pick and the existing arg-position
> single-impl-group optimization. Grounded callers unaffected; null/sole-impl
> callers no longer deref null. Fixture `test/build_diff_fixtures/super_returnpos.mdk`
> (golden `43`); gates `diff_selfhost_build` 30/0, `eval_dict` 26/0, fixpoint
> C3a/C3b YES.
>
> **The prescribed `expand_supers` flatten was implemented, tested, and REVERTED:**
> appending a superinterface dict slot to a super-bearing constraint **destabilizes
> working prelude code** — `clamp : Ord a => …` (since `Ord requires Eq`) gains a
> second dict param whose Eq slot the **bare-name-keyed native call site under-fills**
> → SIGSEGV (build-diff `clampc`). That under-fill is precisely **D2** (dict arity
> keyed by bare name, not binding identity). **So the spec-true WS-1b is BLOCKED BY
> WS-2, not WS-4a** — the dependency graph (§1) had this wrong: `expand_supers`'s
> own traversal is one-level/non-recursive (it cannot hang on a cycle), so WS-4a was
> never the real gate; the real gate is identity-keyed dict arity (WS-2). Do WS-2
> first, then revisit the flatten.

Original plan (the spec-true form, deferred):
Give evidence a real superclass dimension so return/phantom-position superclass
methods dispatch from the static dict, not arg-tag:
1. Build superclass evidence at `inst` time — when constructing `DictC⟨T̄⟩`, resolve
   each `D ∈ super(C)` through entailment and store it (the spec's `supers.D`).
   Concretely, extend the dict value/route: either a distinct `supers` slot in
   `VDict`/`RKey` (spec-true two-field shape, closes D7), or — cheaper, matching the
   oracle — the `expand_supers` *flatten* (`lib/typecheck.ml:3191-3209`) that adds
   each superclass as a sibling dict slot resolved by `assum`. The flatten is sound
   and smaller; the two-field record is the spec letter and removes the D7 fidelity
   gap. **Recommendation:** flatten first (parity with a proven design, unblocks
   return-position superclass), record-shape only if D7 fidelity is later wanted.
2. Add the projection at the use site so a superclass method under a subclass-only
   constraint resolves to the carried evidence (`super(e).D`), never re-resolves.
- *Gate:* a return-position superclass method (e.g. a `Bounded`-style `super`
  needing `mempty` from a superclass under a subclass-only `=>`) must produce
  identical `run` and `build` output and route through the dict (verify via an
  Int-element probe where arg-tag is *incapable*, à la the §7 proof).
- *Effort:* medium. *Risk:* medium — touches the route type (every `Route` match
  site) and both emitters. **Blocked by WS-4a** (a cyclic `requires` would hang the
  new resolution).

### WS-2 — Module-qualified dictionary identity + global IE (closes D2 and D3)

> **STATUS (2026-06-20, `e488cd9`): D2 cross-module collision CLOSED (partial WS-2).**
> The observable D2 bug is fixed and verified robust (2-way, 3-way, both-sides,
> reversed-import-order — `run`==`build` in all). It was NOT purely latent: a diamond
> re-export of two same-bare-name constrained fns of different dict arity made the
> arity-1 call site size to the arity-2 entry (last-write-wins) → over-application →
> `intToString: not an Int` on `run` (native `build` recovered via arg-stamp). Root:
> `discoverPromotedModules` flattens all modules into one bare-name `funConstraintsRef`.
> **Fix taken (conservative/additive, NOT the full re-key):** a parallel
> `crossModuleFunConstraintsQualRef : ((module,name), arity)` table populated per-module
> by `attributeModuleArities`; `scopeArities` uses it + the scope's module-id set to drop
> the out-of-scope twin **for colliding bare names only** (non-colliding names keep the
> old bare path → all goldens byte-identical). `mid` threaded via the loader's existing
> `(mid,prog)` pairs through `elabModulesGo`/`checkModuleFullImpl` — **NO** AST/resolve
> change (lower risk than the scoped `EVar`-origin approach). `dictParamName` left bare
> (body-local). Fixture `test/eval_typed_modules_fixtures/cross_module_dict_arity/`
> (drives `evalModules`; golden native-captured — the frozen oracle PANICS on the
> collision, so it's skipped in `capture_goldens.sh`, not gated against the oracle).
> Gates: fixpoint C3a/C3b YES; eval_dict 26/0, build 30/0, resolve 15/0, argstamp parity
> 26/26, all green.
>
> **NOT done (deferred follow-ups):** (1) the principled full re-key + **retirement of the
> bare `crossModuleFunConstraintsRef` + Phase-134 per-scope decl-filter + empty-entry
> seeding** — the qualified table is an additive mirror, the workarounds stay; (2) the AST
> module-origin threading (avoided); (3) **WS-1b's `expand_supers` is NOT unblocked by this**
> — the `clamp` Eq-slot under-fill is a *different* facet (define-side super-slot expansion
> vs call-side arity computation, not a name collision); it needs its own arity-sync fix.
> (4) **D3 global IE/coherence — deferred** (Stage C, orthogonal, see below).


**Spec:** §8 I1 (identity-keyed arity), §6 C4 / §8 I2 (single global IE). **Lands
in:** `selfhost/frontend/resolve.mdk` (qualified identity), `selfhost/driver/loader.mdk`
(global IE assembly after topo-sort), `selfhost/types/typecheck.mdk`
(`funConstraintsRef`, `scopeArities`, `registerMember`, `checkCoherence`,
`dictParamName`), `selfhost/eval/eval.mdk` (lookup). **Skill:**
`add-language-feature` (threads `module_id` resolve → typecheck → dict-keys → eval).

These two divergences share one root and should be fixed together:
1. **Key dictionary arity by module-qualified binding identity**, not bare name.
   Replace the `(String, List Int)` arity tables (`funConstraintsRef`,
   `collect_arities`) and `dictParamName`/`$dict_<fn>_<slot>` with a `(module_id,
   name)` key. This **dissolves the D2 collision class outright** — no two distinct
   bindings can ever share an arity slot — and lets the `crossModuleFunConstraintsRef`
   accumulator + per-scope decl-filter + empty-entry workarounds be **retired**.
2. **Assemble one global `IE`/`CE`** after the loader's topo-sort, before any
   per-module typecheck, and run a **single global `checkCoherence`** over it.
   Import scoping then governs *name visibility* only, not evidence identity (§8 I2).
   This makes C2/C4 globally true and removes the "coherence holds only per-module"
   gap (D3).
- *Gate:* a new `test_loader`/`diff_selfhost` fixture with two modules each defining
  `impl C T` (no import edge) must be rejected by the global coherence check; a
  fixture with two public constrained same-named cross-module bindings of different
  arity must compile and run correctly (the D2 latent repro). All existing gates green.
- *Effort:* high (cross-cutting, touches resolve/loader/typecheck/eval). *Risk:*
  medium-high — the per-module assembly is load-bearing for import scoping and the
  `resetState` discipline; do it as its own change with the full `diff_selfhost_*`
  suite + `selfcompile_fixpoint` as the safety net. Land **after** WS-1 so the
  superclass evidence is already identity-correct when it goes global.

### WS-3 — Dispatch-lookup uniqueness for overlap in return/phantom position (closes D4)

**Spec:** §6 C1, §5 side condition. **Lands in:** `selfhost/types/typecheck.mdk`
(stamp a key route at the use site for a most-specific-wins pair) and/or
`selfhost/eval/eval.mdk` + emitters (error on non-unique match in
return/phantom position). **Skill:** `harden-typechecker` (the decision is
elaboration-time; runtime is a guard).

Keep the most-specific-wins / named / single-default **policy** (deliberate). Close
only the unsound corner: when a permitted-overlap predicate is dispatched with **no
determining argument** (return/phantom position), the evaluator must not fall back to
arg-tag. Either (a) stamp a concrete key route at elaboration when the result type
grounds the instance, or (b) make `findImplEntry`/`select_impl_by_head` **error** on
a non-unique match in that position rather than pick first. Correct the false comment
at `lib/typecheck.ml:4494`.
- *Gate:* a fixture with a most-specific-wins instance pair used in return position
  must either resolve deterministically (route stamped) or be rejected — never
  silently arg-tag. *Effort:* low-medium. *Risk:* low (narrow, guarded).

### WS-4 — Well-formedness guards (closes D5, D6)

**Spec:** §3 W1, W2. **Lands in:** `selfhost/frontend/resolve.mdk` (W1, at
`checkSuper`/`registerInterface`) and `selfhost/types/typecheck.mdk` (W2, at
`implRequiresRoutesRec`). **Skill:** `harden-typechecker`.

- **WS-4a (W1, do early — gates WS-1b):** DFS cycle check over the interface
  `requires` graph at registration; reject `interface A requires B` /
  `B requires A` with a clear error. *Must land before WS-1b* or superclass-evidence
  resolution can hang. *Effort:* low. *Risk:* low.
- **WS-4b (W2):** a structural-decrease / fuel / `seen` guard on
  `implRequiresRoutesRec` so a non-shrinking `impl C (T a) requires C (T (T a))`
  terminates with a "cannot resolve / non-decreasing instance context" error
  instead of diverging. A Paterson-coverage condition is the principled form; a
  depth/`seen` fuse is the cheap form. *Effort:* low. *Risk:* low.

### WS-5 — Phantom-position decision (closes D8)

**Spec:** §5 phantom position. **Lands in:** `selfhost/types/typecheck.mdk`
(classifier already exists: `returnPosMethodNames` / `dispatchTyparams`). **Skill:**
`harden-typechecker`.

A method whose class param is absent from its signature cannot dispatch. Decide and
implement one of: **(a)** reject such a method declaration at `check` with a clear
diagnostic ("method `m` does not mention interface parameter `a`; cannot dispatch"),
or **(b)** support it via an explicit type/proxy argument threaded as the dict
selector. (a) is the pragmatic choice unless a `Proxy`/`TypeRep` surface is wanted.
Today it silently mis-runs. *Effort:* low (a) / high (b). *Risk:* low.

### WS-6 — Strict-§7 cleanup + doc/comment hygiene (closes D9, D10) — cheap wins

**Lands in:** `selfhost/types/typecheck.mdk`, the stale docs. **Skill:** none
(mechanical).

- **D9:** stamp the standalone-shadow site (`typecheck.mdk:4567`)
  `RKey<receiverHead>` on **both** paths (impls already converge), delete the
  `:4567` flag read and the dead `:8165` guard, and rename `argStampEnabled` →
  `emitArgStampPasses` (it would then gate only emit-only codegen passes, never a
  dispatch decision). Removes the misleading "dispatch fork" appearance; the parity
  probe already proves zero observable change.
- **D10:** prune/correct the verified-false comments and docs:
  `DISPATCH-GAPS-SCOPE.md:411-476`, `EMITTER-GAPS.md:74` (#21 SIGSEGV — closed),
  `ARGSTAMP-UNIFY-PLAN.md:95` (mutual-rec emit — green), the
  `argStampEnabled OFF on eval` comments in `typecheck.mdk` (gates removed),
  `lib/typecheck.ml:4494` ("enforces uniqueness" — false).
- *Effort:* low. *Risk:* none (docs + a provably-inert flag). Do these first to stop
  the stale docs misleading the WS-1/WS-2 implementers.

## 3. Summary table

| WS | Closes | Spec | Skill | Effort | Risk | Gate |
|----|--------|------|-------|--------|------|------|
| 1a | D1 (decl gate) | §6 C2 | add-language-feature | Low | Low | `impl Mon Bag` w/o `Sem` → `MissingSuperImpl` |
| 1b | D1 (dispatch) + D7 | §3 super, §5 | add-language-feature | Med | Med | return-pos superclass `run==build`, dict-routed |
| 2 | D2 + D3 | §8 I1, §6 C4/I2 | add-language-feature | High | Med-High | cross-module overlap rejected; same-name diff-arity OK |
| 3 | D4 | §6 C1, §5 | harden-typechecker | Low-Med | Low | most-specific pair in return-pos: routed or rejected |
| 4a | D5 (W1) | §3 W1 | harden-typechecker | Low | Low | cyclic `requires` rejected |
| 4b | D6 (W2) | §3 W2 | harden-typechecker | Low | Low | non-shrinking instance terminates with error |
| 5 | D8 | §5 phantom | harden-typechecker | Low | Low | phantom method rejected at `check` (or proxy-dispatched) |
| 6 | D9 + D10 | §7 | — | Low | None | parity probe stays 26/26; docs match binary |

## 4. Verification strategy

- **Per-workstream fixture:** each WS adds a fixture that *fails before, passes after*,
  placed in the gate that drives the affected path — `test_loader` for cross-module
  (D2/D3, never `test_run`/doctest, which mask loader-only bugs), the `diff_selfhost`
  build/eval gates for dispatch (D1/D4).
- **Differential safety net:** keep `diff_selfhost_eval_dict` (26/0),
  `diff_selfhost_build` (29/0), `diff_selfhost_llvm` (181/0),
  `argstamp_parity_probe` (26/26), and `selfcompile_fixpoint` green across every
  change. A dict-passing change that breaks the fixpoint is a self-miscompile.
- **Oracle as second opinion during soak:** for D1 specifically, the frozen oracle
  *already* rejects the under-specified program; WS-1a's success criterion is native
  `check` matching the oracle. Use the oracle this way before `lib/` removal; after,
  the native interpreter is the sole reference and the fixtures carry the contract.
- **Sequencing guard:** WS-4a (W1) must merge before WS-1b, or the new superclass
  resolution can hang on a cyclic `requires`. WS-2 should merge after WS-1 so the
  superclass evidence is identity-correct when the IE goes global.

## 5. Non-goals (deliberate divergences — do **not** "fix")

- **Most-specific-wins / named / single-default overlap** (the permitted half of D4)
  is a design feature; WS-3 closes only the *return/phantom-position arg-tag* corner,
  not the policy.
- **Param-threaded instance context vs closure-capture** (D7) is observationally
  equivalent; only fold it into WS-1b if the two-field `{methods, supers}` record is
  chosen for the superclass fix, not as standalone work.
- **The OCaml oracle's §7/§3 divergences** are out of scope — `lib/` is frozen and
  the diff gates already police it until removal.
