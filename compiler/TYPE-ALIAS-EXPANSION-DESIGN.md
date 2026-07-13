# Type-Alias Expansion — Design

**Status:** IMPLEMENTED — `aa57e3c1`, 2026-06-30 (§10 "AS-BUILT"). Verified live:
`compiler/types/typecheck.mdk` has a `registerData env (DTypeAlias _ name params rhs) = ...`
arm (~line 6007); type aliases now expand transparently, retiring the `data`-wrap
workaround this doc was written to eliminate. The header below ("DESIGN... No source
modified") predates the fix.

Status: DESIGN (read-only investigation). Built and reproduced against
`./medaka` at commit `e9f5866` (BASE_OK). No `.mdk` source was modified.

Goal: make `type X = Y` a **transparent** alias so that `Foo` and its RHS
unify, letting `support/ordmap.mdk` drop the `data OrdMap a = OEmpty | OMap …`
wrapper. Today aliases are parsed and resolve-validated but the typechecker
**never expands them** — `DTypeAlias` has no typecheck arm.

---

## 1. Empirical current behavior (verbatim, on freshly-built `./medaka`)

Note: `medaka check` on a clean file prints a dump of every top-level
signature (that is its success output). An error is the diagnostic lines below.

### 1a. Non-parameterized `type Foo = Int` — REJECTED
```
type Foo = Int
f : Foo -> Foo
f x = x + 1
main = println (f 2)
```
`check`:
```
…:4:18: No impl of Num for Foo
…:4:7: No impl of Display for Foo
```
`run`: `error: type error … run medaka check for details`.
→ `Foo` stays opaque `TCon "Foo"`; `+` / `println` see no Num/Display for it.

### 1b. Structural (alias↔underlying interchange) — REJECTED both directions
```
type Foo = Int
toFoo : Int -> Foo
toFoo x = x          -- :5:10: Type mismatch: Foo vs Int
…(g (toFoo 5))       -- :6:25: Type mismatch: Int vs Foo
```

### 1c. Parameterized `type Pair a = (a, a)` — REJECTED
```
type Pair a = (a, a)
mk : Int -> Pair Int
mk x = (x, x)        -- :3:11: Type mismatch: Pair Int vs (Int, Int)
fst2 : Pair Int -> Int
fst2 p = match p …   -- :5:15: Type mismatch: (a, b) vs Pair Int
```
→ `Pair Int` is an opaque `TApp (TCon "Pair") Int`, never `(Int,Int)`.

### 1d. Alias-of-alias `type A = Int; type B = A` — REJECTED
```
type A = Int
type B = A
h : B -> B
h x = x + 1
main = println (h 3)
```
`check`: `No impl of Num for B`, `No impl of Display for B`. (`A` is itself
opaque, so `B` would still be opaque even after one expansion step → transitive
expansion is required.)

### 1e. Arity mismatch `Pair Int Int` (Pair takes 1) — REJECTED (but wrong reason)
```
type Pair a = (a, a)
bad : Pair Int Int -> Int
…                    -- :4:23: Type mismatch: Pair Int Int vs (a, b)
```
→ Today there is NO arity check; it's an accidental mismatch because the opaque
`Pair Int Int` can't unify with a tuple literal. A real impl needs a dedicated
"wrong number of arguments to type alias" error.

### 1f. Cyclic `type A = B; type B = A` — ACCEPTED (silently!)
```
type A = B
type B = A
x : A
x = x
main = println 0
```
`check` succeeds (dumps signatures incl. `x : A`); `run` prints `0`.
→ Because aliases are never expanded, the cycle never loops — but it is also
never rejected. **Once expansion is added, this MUST be caught or it infinite-
loops.** Same for `type R = List R` (1g, also accepts + runs `0` today).

### 1h. Parameterized stdlib alias `type SMap a = Map String a` — INCONCLUSIVE
My scratch import setup could not resolve `import map` (even a direct
`Map String Int` signature without any alias failed with `Unknown type: Map` /
`Unbound variable: Map` — a scratch project-root issue, not an alias issue).
The alias mechanism for the parameterized case is fully characterized by 1c.
There IS a separate, related finding for the cross-module case — see §4.

---

## 2. Expansion locus — the central fork

### The type representations
- Surface AST type: `Ty = TyCon | TyVar | TyApp | TyFun | TyTuple | TyEffect |
  TyConstrained` (`compiler/frontend/ast.mdk:28`).
- Internal type: `Mono = TVar | TCon | TApp | TFun | TTuple | TEff`
  (`compiler/types/typecheck.mdk:78`).
- The **one seam** that turns surface `Ty` into internal `Mono` is
  `fromAstTypeE` (`typecheck.mdk:2592`). Its `TyCon n` arm produces a bare
  `TCon n` (`:2593`); its `TyApp` arm dispatches through `fromAstTypeApp`
  (`:2595`,`:2611`).

### Candidate A — resolve-time AST rewrite
Substitute each alias's RHS `Ty` into every `Ty` occurrence in the program
before typecheck (in `compiler/frontend/resolve.mdk`).
- Pro: typecheck sees no aliases at all; conceptually simplest downstream.
- Con: resolve currently only *validates* the RHS (`resolve.mdk:544 checkDecl …
  DTypeAlias _ _ _ rhs = checkType …`); it does not rewrite types. A rewrite
  must walk every `Ty` in every decl/annotation — large new surface in resolve,
  and it would lose the alias name for diagnostics (§5). resolve is also in the
  self-compile graph (seed re-mint).
- **Not recommended.**

### Candidate B — typecheck pre-pass + on-demand expansion at the seam (RECOMMENDED)
There is already an exact precedent. `registerAllData` (`typecheck.mdk:8439`,
called at `:7474` and `:9386`) walks all decls in a pre-pass and populates
**global refs** — `recordsRef`, `dataParamKindsRef` (`:1256`,
populated `:4452`). `fromAstTypeApp` (`:2611`) then **consults
`dataParamKindsRef` on demand** during `Ty→Mono` conversion to do kind-directed
elaboration. An alias table is the same pattern:
1. Add `aliasTableRef : Ref (List (String, (List String, Ty)))` next to
   `dataParamKindsRef` (`:1256`), reset it where that one is reset (`:2069`).
2. Register `DTypeAlias pub name params rhs` in `registerData`
   (`typecheck.mdk:4405`, which currently has `registerData env _ = env` for
   non-DData/DRecord at `:4411`) → add an arm storing `(name, (params, rhs))`.
3. Expand at the seam in `fromAstTypeE`/`fromAstTypeApp`: when the head `TyCon
   n` (or applied head) names an alias, recurse `fromAstTypeE` on the alias RHS
   **with `tvs` extended by `zip params argMonos`** (reuse the existing
   `tvs : List (String, Mono)` binding table — no Mono-level substitution
   needed; `TyVar` already resolves through `tvs` at `:2594`).
- Pro: localizes the change to the existing seam + pre-pass; mirrors a proven
  mechanism; keeps the alias name available until the moment of expansion (good
  for diagnostics); only `typecheck.mdk` changes.
- Con: `typecheck.mdk` IS in the self-compile graph → seed re-mint at
  checkpoint. On-demand recursion needs cycle protection (§4).
- **Recommended.** The type rep makes this the natural choice: there is a single
  conversion seam and an established global-table-consulted-at-the-seam idiom.

### Candidate C — lazy expansion inside unification
Expand a `TCon`/applied head when `unifyN` (`typecheck.mdk:2177`) meets it.
- Con: aliases would persist in `Mono` values (as `TCon "Foo"`), so every
  consumer of `Mono` (occurs-check, generalization, `substMono`, the emitter
  path, error printing) would have to know to expand — far more surface than B,
  and easy to miss a site. The bug class (an un-expanded alias silently
  surviving into a place that compares by `TCon` name) is exactly what 1a–1e
  already show.
- **Not recommended.**

### Where the full alias set is known
`registerAllData` runs over `accData ++ prog` (`:9386`), where `accData` carries
**core's + earlier modules' public decls**, and `prog` is the current module;
the prelude is prepended upstream. So a table populated in `registerData` sees
the prelude's, imports', and this module's aliases — *provided exported aliases
reach `accData`*, which today they do NOT (see §4 cross-module).

---

## 3. Parameterized aliases
- **Binding/substitution:** alias `(params, rhs)` applied to `args`. At the
  seam, build `tvs' = tvs ++ zip params (map (fromAstTypeE …) args)` and recurse
  `fromAstTypeE … tvs' rhs`. `TyVar p` in the RHS then resolves to the supplied
  arg via the existing `lookupAssoc n tvs` (`:2594`). Example: `OrdMap a = Map
  String a` applied to `Int` → expand RHS with `a↦Int` → `Map String Int`.
- **Arity check:** when `listLen args /= listLen params`, emit a new
  `type_error` ("type alias `Pair` expects 1 argument, got 2"). Mirror the
  guarded `listLen kinds == listLen args` test already in `fromAstTypeApp`
  (`:2613`). Without it you get the misleading mismatch in 1e.
- **Partial application (unapplied / under-applied alias):** RECOMMEND rejecting
  for v1 — a type alias is not a first-class type constructor (it has no kind of
  its own once expanded), and `tvs'` substitution requires all params bound.
  `OrdMap` alone, unapplied, → arity error. (Higher-kinded alias partial-app is
  a known hard area in real type systems; out for v1.)

---

## 4. Hard cases & required guards

### Cyclic / recursive aliases — MUST reject (today silently accepted: 1f/1g)
On-demand recursive expansion at the seam loops forever on `A=B;B=A` or
`R=List R`. Add a **pre-pass cycle check** over `aliasTableRef`: build the
alias-reference graph (which alias names each RHS mentions, via a `Ty` walk like
`tyVarNames` at `:2479`) and reject any cycle with a new `type_error`
("recursive type alias `A`"). Do this in/after the registration pre-pass, before
any expansion can run. A pre-pass topo check is cleaner than a per-expansion
visited-set and gives a located error. (Note: `type R = List R` is genuinely
recursive and unrepresentable as a transparent alias — reject; the user wants a
`data`/`newtype` there.)

### Transitive alias-of-alias (1d)
`B = A = Int` needs the RHS expansion to itself expand aliases. Since expansion
recurses through `fromAstTypeE`, transitivity is automatic **once the cycle
check guarantees termination** — no separate fixpoint needed.

### Interaction with `data` / `record` / `newtype` / `deriving`
- `data`/`record`: aliases must not shadow real type constructors. The cycle/
  arity pre-pass should also reject an alias whose name collides with a `data`/
  `record` name (or define precedence — recommend reject the collision).
- `DNewtype` (`ast.mdk:304`): a newtype is **nominal** (distinct type) by design
  — do NOT expand it. Only `DTypeAlias` is transparent. Keep them separate.
- `deriving`: aliases have no constructors, so nothing to derive on an alias;
  deriving stays on the underlying `data`. No interaction.
- **Effect-row aliases** (`type Eff = <IO>` etc.): `Ty` can carry `TyEffect`.
  RECOMMEND **out of scope for v1** — effect rows elaborate through a separate
  `etbl`/`EffRow` path (`astEffrowE` `:2573`, `rowArgOf` `:2632`) and an alias in
  a row tail is a distinct, riskier substitution. Restrict v1 expansion to
  type-position (KType) aliases; document row aliases as deferred.

### Cross-module (CONCRETE FINDING — extra work required)
`publicDataDecls` (`typecheck.mdk:9611`), which builds the `accData` that
`registerAllData` consumes for imported modules, keeps only `DData`, `DRecord`,
public `DInterface`, public `DImpl` — **it drops `DTypeAlias`** (falls through
`publicDataDecls (_::rest) = …` at `:9621`). So a `public type Foo = Int`
exported from one module will NOT reach the importer's alias table; the importer
would still see `Foo` opaque. **A complete cross-module fix must also propagate
exported `DTypeAlias` into `accData`** (add a `DTypeAlias VisPublic …` arm to
`publicDataDecls`, or thread a parallel alias accumulator like `allImplDecls` at
`:9633`). Expansion happens during each module's typecheck (after merge into
`accData`), so the importing module's alias table must include the exporter's
public aliases. This is the single biggest "not just typecheck.mdk" wrinkle.

---

## 5. Error-message transparency fork
Recommendation: **keep the alias name for display, unify on the expansion** (the
standard HM choice). Feasibility with Candidate B: expansion produces a `Mono`
that no longer records it came from an alias, so by default errors would show
the expansion (`(Int, Int)`, not `Pair Int`). Showing the alias name in
diagnostics would require carrying provenance on `Mono` (a wrapper or a side
table keyed by occurrence) — a larger change. RECOMMEND v1 ships
**expansion-in-errors** (simple, correct, slightly less friendly) and defers
alias-name-preserving diagnostics. Flag this as a decision (§8).

---

## 6. Concrete payoff check (OrdMap migration)
With transparent aliases, `support/ordmap.mdk` could replace
`data OrdMap a = OEmpty | OMap (Map String a)` with
`type OrdMap a = Map String a` (per the AGENTS.md migration note + memory
`project_compiler_stdlib_unification.md`). `OrdMap Int` would expand to
`Map String Int` everywhere, so wrap/unwrap (`OMap`/the `OEmpty` constructor)
disappears.

**Value-restriction interaction (the original blocker) — RESOLVED, not
reintroduced.** The migration note warns a polymorphic empty must be a *nullary
constructor* because a constructor *application* (`OMap Tip`) isn't generalized
(→ monomorphizes to `…Unit`, "Scheme vs Unit"). With an alias, `omEmpty` would
be `Map.empty` (or `Tip`) — i.e. it inherits whatever `Map.empty`'s own
generalization is. `Map.empty` in stdlib is already a properly-generalized
nullary value, so an alias-based `OrdMap` does NOT reintroduce the
constructor-application problem (there is no `OMap` wrapper to apply). The one
thing to confirm at implementation time: `omEmpty = Map.empty` must itself be a
syntactic value (nullary), which it is.

---

## 7. Staged implementation plan (ascending risk, each gateable)

All stages touch `compiler/types/typecheck.mdk` (in the self-compile graph) →
**seed re-mint + `selfcompile_fixpoint` at the checkpoint**.

| # | Stage | Touches | Gate | Driver |
|---|-------|---------|------|--------|
| 1 | Alias table: `aliasTableRef` + `registerData` arm (`:4411`) + reset (`:2069`) | typecheck.mdk | builds; no behavior change yet | Sonnet (mechanical) |
| 2 | Non-parameterized expansion in `fromAstTypeE` `TyCon` arm (`:2593`) | typecheck.mdk | repro 1a/1b accept; `diff_compiler_check*` | **Opus** (seam-fragile: must not perturb existing `TCon` paths / kind elaboration) |
| 3 | Parameterized expansion via `tvs` extension in `fromAstTypeApp` (`:2611`) + arity error | typecheck.mdk | repro 1c accept, 1e gives arity error | **Opus** (route-fragile) |
| 4 | Cycle + recursive-alias pre-pass rejection | typecheck.mdk | repro 1f/1g now REJECT with `type_error`; no infinite loop | Sonnet→Opus (graph walk mechanical; placement matters) |
| 5 | Cross-module: propagate `DTypeAlias VisPublic` through `publicDataDecls` (`:9611`) | typecheck.mdk | exported alias used in importer (multi-module fixture) | **Opus** (accData semantics) |
| 6 | Payoff: migrate `support/ordmap.mdk` to `type OrdMap a = Map String a` | ordmap.mdk (NOT this task) | full gate suite + fixpoint + seed re-mint | separate task |

Mechanical (Sonnet): stage 1, the graph-walk part of stage 4.
Route-fragile (Opus): stages 2,3,5 (they edit/extend the `Ty→Mono` seam and
cross-module accumulators — the documented bug-prone areas).

Stage 6 is the user-facing payoff and a separate change set (edits stdlib +
re-mints seed); stages 1–5 are the language feature.

---

## 8. Design forks needing a human decision
1. **Expansion locus** — recommend Candidate B (typecheck pre-pass + on-demand
   expansion at `fromAstTypeE`). Confirm vs A (resolve rewrite) / C (unify).
2. **Parameterized + partial application scope for v1** — recommend: full
   parameterized expansion WITH arity checking; reject unapplied/under-applied
   aliases. Confirm we don't need first-class partial alias application in v1.
3. **Recursive/cyclic aliases** — recommend reject (cannot be transparent).
   Confirm (vs. some future equi-recursive treatment — not advised).
4. **Error transparency** — recommend show the *expansion* in diagnostics for
   v1; defer alias-name-preserving errors (needs `Mono` provenance). Confirm.
5. **Effect-row aliases** — recommend OUT for v1 (separate `etbl`/EffRow path).
   Confirm.
6. **Cross-module scope in v1** — including stage 5 (`publicDataDecls`
   propagation) is required for an exported alias to work in an importer. Confirm
   v1 includes cross-module, or whether v1 ships single-module-only first.

---

## 9. LOCKED SCOPE (orchestrator + user decision, 2026-06-30)

v1 = **full feature through cross-module — all of stages 1–5.** The fork answers:

1. **Expansion locus** → **B** (typecheck pre-pass + on-demand expansion at `fromAstTypeE`). Locked.
2. **Parameterized + partial application** → full parameterized expansion WITH arity checking; **reject** unapplied/under-applied aliases. No first-class partial alias application in v1.
3. **Cyclic/recursive aliases** → **reject** (new cycle-check pre-pass). Note: these are silently *accepted* today (nothing expands them), so stage 4 is a behavior change that must not regress the non-cyclic corpus.
4. **Error transparency** → show the **expansion** in diagnostics for v1; alias-name-preserving errors deferred (needs `Mono` provenance).
5. **Effect-row aliases** → **OUT** for v1.
6. **Cross-module** → **IN** (stage 5 `publicDataDecls` propagation). Required for the OrdMap payoff (`support/ordmap` is imported across compiler modules).

**Execution:** stages 1–5 run **sequentially** (all touch `typecheck.mdk` → same hottest file, no parallelism), each independently gated + merged before the next branches. Seed re-mint + `selfcompile_fixpoint` C3a/C3b at the **completed-feature checkpoint** (after stage 5), not per stage — defer the ~10 MB seed churn. **Stage 6 (migrate `support/ordmap.mdk`) is a separate follow-up task**, gated on the feature being in + re-minted.

---

## 10. AS-BUILT (shipped 2026-06-30, main `aa57e3c`)

All 5 stages landed as designed (locus B), each independently fixpoint-gated + merged; seed re-minted once at the checkpoint (cold `bootstrap_from_seed` C3a PASS byte-for-byte).

- **Stages 1+2 (`29efddf`):** `aliasTableRef : Ref (List (String, (List String, Ty)))` populated in `registerData`, reset in `resetState`; non-parameterized + transitive expansion at `fromAstTypeE`'s `TyCon` arm.
- **Stage 3 (`d4f4f41`):** parameterized expansion at `fromAstTypeApp` (param→arg `Ty` substitution, re-expanded); arity error (`aliasArityMsg`) for wrong-arity + unapplied parameterized aliases. NOTE: error reporting made the `Ty→Mono` conversion chain perform `<Mut>` → 11 conversion fns annotated `<Mut>` (propagates cleanly through effect-polymorphic `map`).
- **Stage 4 (`0517cfd`):** `rejectCyclicAliases` pre-pass after `registerAllData` — DFS over alias→alias edges (`tyConNamesInTy` ∩ table keys), each alias on a cycle gets a deduped error AND is removed from the table (so the expansion seam can't recurse). Previously cyclic aliases *crashed* (exit 138, stack overflow); now exit 1 with a clear error.
- **Stage 5 (`6d9eaec`):** cross-module — TWO layers (my repro refined the design, which named only layer 2): (1) `resolve.mdk expTypesDirect` gained a `DTypeAlias True` arm (else the importer rejected the name as private); (2) `typecheck.mdk publicDataDecls` gained a `DTypeAlias True` arm so the full decl (incl. RHS) flows into the importer's `accData` → its `registerData` populates the importer's alias table.

**Known v1 wart (deferred per §5):** alias-error source locations render at the alias decl / `<unknown location>`, not the use site — needs `Mono` provenance, deferred. **Value-restriction interaction:** does NOT reintroduce — an alias-based `OrdMap` uses `omEmpty = Map.empty` (an already-generalized nullary value), no `OMap` wrapper to apply.
