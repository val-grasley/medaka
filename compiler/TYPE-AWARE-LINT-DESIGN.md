# Type-Aware Lint Tier — Design

**Status:** OPEN — verified live: `grep -n "type oracle\|typeOracle\|TypeOracle"
compiler/tools/lint.mdk` returns zero hits; no type-aware oracle machinery exists in the
current linter, matching AGENTS.md's description of ~20 purely-syntactic rules. Genuinely
still-open, unclaimed forward work with a fully worked-out design (oracle interface,
registry shape, ≥4 candidate rules, effort estimate).

Status: **DESIGN ONLY (read-only pass, 2026-06-29).** Nothing built. This doc
scopes a *type-aware* rule tier for `medaka lint` (`compiler/tools/lint.mdk`),
analogous to `typescript-eslint`'s type-checked rules: rules keep matching the
**raw (pre-desugar) surface AST** for shape, but may **query a side-table of
resolve/type facts** (a "type oracle") harvested by running the pipeline once.

All file:line citations were against a since-discarded agent worktree (path removed,
2026-07-13 doc pass — never a valid path for anyone else).

---

## 1. Problem & non-goal

Today every lint rule is **purely syntactic**: `Rule.check : Positions ->
List Decl -> List Finding` (`compiler/tools/lint.mdk:50-56`) sees only the parsed
decls. That blocks a whole class of high-value rules:

- proving a single-arm constructor match (`match x { Just v => … }`,
  `let Just v = x`) is **irrefutable** (needs the constructor's sibling count);
- sharpening §6 `deriving` so it fires only when the type is *actually*
  locally-declared and derivable (needs the constructor/field table);
- sharpening §7a stdlib-reimpl so `reverse`/`map`/… fire only when the local
  definition's **signature matches** the stdlib one (needs the inferred scheme);
- redundant-conversion / redundant-wrapping / `map id` rules (need the inferred
  type of a sub-expression).

**Non-goal: do NOT relocate the linter to a post-typecheck stage.** The linter
deliberately runs on the **raw pre-desugar AST** (`lint.mdk:3-7`), exactly like
`checkGuardExhaustiveness`, because `desugar.mdk` runs first and destroys the
surface shapes rules detect — `EGuards`, `EFunction`, `ESection`, string interp,
`do`-blocks, and match-on-bare-param are all lowered to core before
resolve/typecheck ever see the tree (AGENTS.md "Pipeline" §; `desugar.mdk` runs
FIRST). A rule that pattern-matches on the desugared tree cannot see "this
function body is a `match` on its bare parameter," etc.

So the architecture is **not** "lint the typed tree." It is: **run the pipeline
once to harvest a fact table (the oracle), then run typed rules on the same raw
AST, passing them the oracle.** Surface shape comes from the raw AST; facts come
from the oracle. This mirrors typescript-eslint, where rules still walk the
ESTree (surface) AST and call `services.getTypeAtLocation(node)` into the TS
type-checker on the side.

---

## 2. The crux — is a `Loc`-keyed oracle feasible? (mostly clean, partly messy)

This is the load-bearing finding. Investigated empirically (LSP hover path,
typecheck channels, `Loc` representation).

### 2.1 There is no `Loc -> Type` map anywhere today

The LSP's "hover shows local var types" is **name-keyed, not position-keyed.**
The hover path (`compiler/tools/lsp.mdk:515-558`) uses the cursor position *only*
to scan out the **identifier string** under it (`identifierAt`,
`lsp.mdk:261-271` — pure `Array Char` scan, no AST), then looks that **name** up
in three flat `List (String, Scheme)` association lists (`hoverScheme`,
`lsp.mdk:553-558`; `lookupSchemeL` linear assoc, `:495-499`):

1. `env` — top-level schemes (the typecheck return value);
2. `currentLocalSchemes ()` — let-binders, lambda/clause params, match binders;
3. `currentSeedSchemes ()` — runtime externs.

Table (2) is built as a **side effect of inference**, not by walking a typed
tree: `recordLocalBind name v` appends `(name, mono)` to
`localBindRefs : Ref (List (String, Mono))` (`compiler/types/typecheck.mdk:1442-1466`),
generalized at the end of the run into `localSchemesOut`
(`typecheck.mdk:7507-7508`, module path `:9448`) and read via
`currentLocalSchemes : Unit -> <Mut> List (String, Scheme)` (`:1458`).

Consequences (documented limitations of reusing this machinery):
- keyed by **bare name** — shadowing is *not* disambiguated; `lookupSchemeL`
  returns the first match;
- only answers for **identifier occurrences**, never an arbitrary sub-expression
  (a literal, a `.field` projection, a call result);
- yields a generalized `Scheme`, not the monomorphic instantiated type at the
  occurrence.

### 2.2 `Loc` is span-only, sparse, and not a unique node id

`Loc = Loc String Int Int Int Int` (file, 1-based start line, 0-based start col,
1-based end line, 0-based end col) — `compiler/frontend/ast.mdk:26`. It is **not**
a field on every node; it is carried by a *transparent wrapper*
`ELoc Loc Expr` (`ast.mdk:233`) that the parser puts on **atom/leaf and
statement-form productions only** (`ast.mdk:224-232`). Specifically:

- **interior application / binop nodes are NOT individually wrapped;**
- **`Pat` nodes carry no `Loc` at all** (`ast.mdk:71`);
- `file` is left `""` by the parser, filled by the caller (`ast.mdk:23`);
- every stage strips/recurses `ELoc` transparently, so it is *not* a stable
  unique node id — two nodes with the same span are indistinguishable.

### 2.3 The answer

- **Clean** for a *constructor/datatype* oracle: the constructor table is
  **purely syntactic** and needs neither types nor `Loc` keying (§3.1). The
  highest-value rule (irrefutable single-arm match) lands here.
- **Clean enough** for a *name-keyed* oracle: reusing
  `currentLocalSchemes`/top-level schemes gives `typeOfName`, modulo the
  shadowing caveat. Good for signature-based rules where the rule already has the
  declaration name in hand.
- **Messy** for a *true `typeOfLoc : Loc -> Option Mono`* over arbitrary
  sub-expressions: it **does not exist and is net-new**. Inference discards
  per-node types (it only stamps dispatch *routes* into a handful of `Ref`
  fields — `EBinOp`/`EFieldAccess`/`EIndex`/`EMethodAt`, `ast.mdk:136,144,156,218`
  — never the inferred `Mono`). Building it means a new pass that threads the
  solved `Mono` onto `ELoc`-wrapped nodes and indexes by span-containment, and it
  still cannot answer for pattern nodes or unwrapped interior nodes.

**Recommendation: do NOT build a general `typeOfLoc` first.** Ship the two cheap
tiers (constructor table + name-keyed schemes), which already cover the four
catalog rules below, and gate `typeOfLoc` behind a design fork (§7) as a later
stretch tier.

---

## 3. Oracle interface

Define a `TypeOracle` record bundling the harvested facts. It is built once per
lint invocation (per file or per project — §7 fork) and passed to every typed
rule. Minimal viable set, split by the tier that backs each query:

```
public export record TypeOracle
  -- Tier 0 — constructor/datatype facts (SYNTACTIC; no typecheck) ------------
  ctorCountOfCtor : String -> Option Int        -- ctor name -> its type's sibling count
  ctorCountOfType : String -> Option Int        -- type name -> its constructor count
  typeOfCtor      : String -> Option String     -- ctor name -> its datatype name
  fieldsOfCtor    : String -> Option (List String)
  isLocalType     : String -> Bool              -- type was declared in THIS target set
  -- Tier 1 — name-keyed inferred schemes (typecheck; reuses LSP channel) -----
  schemeOfTop     : String -> Option Scheme     -- top-level name -> generalized scheme
  schemeOfLocal   : String -> Option Scheme     -- let/param/binder name (shadowing-lossy)
  typechecked     : Bool                        -- did typecheck run clean enough to trust Tier 1?
  -- Tier 2 — STRETCH (net-new; behind --type-aware-exprs fork; see §7) -------
  typeOfLoc       : Loc -> Option Mono           -- arbitrary sub-expr type (NOT built initially)
```

Derived helper (pure, on top of Tier 0 — the irrefutability primitive):

```
isIrrefutableArm : TypeOracle -> Pat -> Bool
-- PVar/PWild/PAs(irrefutable)            -> True
-- PTuple ps / PRecord …                  -> all sub-pats irrefutable
-- PCtor c subps                          -> ctorCountOfCtor c == Some 1
--                                            && all sub-pats irrefutable
-- PLit _                                  -> False
```

`Scheme`/`Mono` are the existing types (`typecheck.mdk:680`, `:78`). Rules that
only need the constructor table never touch `Scheme` and stay typecheck-free.

---

## 4. How the oracle is built

### 4.1 Tier 0 — constructor table (free; no typecheck, no `Loc` bridging)

**Reuse `exhaust.mdk`'s exported `Oracle` verbatim.** It is purpose-built, runs
on the **raw pre-desugar decls the linter already holds**, and needs no types:

- `record Oracle { typeCtors, ctorArity, ctorType, ctorFields }`
  — `compiler/frontend/exhaust.mdk:108`.
- `buildOracle : List Decl -> Oracle` — `exhaust.mdk:116` (seeds builtins
  `Bool`/`List`/`Unit`, user decls override).
- accessors `oGetCtors : Oracle -> String -> Option (List String)`
  (`exhaust.mdk:180`), `oGetCtorType` (`:185`), `oGetCtorFields` (`:177`),
  `oGetArity` (`:190`).

`ctorCountOfCtor c = oGetCtorType o c >>= oGetCtors o |> map listLen`;
`isLocalType` = membership in the locally-declared `typeCtors` keys (filter
`buildOracle (userDeclsOnly)` vs the builtin/imported seed). This is the same
oracle typecheck itself stores in `matchOracle` (`typecheck.mdk:9254`), so the
facts are exactly the compiler's own.

**Cost: one `buildOracle` call over the decls. No pipeline run.** This tier is
available even when the file does not typecheck, and even when `--type-aware` is
off, because it is just a syntactic scan of constructors.

### 4.2 Tier 1 — name-keyed schemes (one pipeline run; reuses LSP harvest)

Run the existing non-aborting analysis once and harvest schemes the same way the
LSP does:

- **Single file:** mirror `docSchemes` (`lsp.mdk:479-486`): `desugar` runtime +
  core + user, call
  `checkProgramSchemesWithRuntime : List Decl -> List Decl -> <Mut> List (String, Scheme)`
  (`typecheck.mdk:7460`) → that is `schemeOfTop`. Then read
  `currentLocalSchemes ()` (`typecheck.mdk:1458`) → `schemeOfLocal`. Runtime/core
  sources are read exactly as `runCheckCmd` does (`medaka_cli.mdk:115-128`:
  `MEDAKA_ROOT` + `stdlib/runtime.mdk`/`core.mdk`).
- **Project:** use the loader + diagnostics path —
  `checkModules : List Decl -> List Decl -> List (String,List Decl) -> <Mut> List (String,List (String,Scheme))`
  (`typecheck.mdk:9807`), fed by `loadProgramFilesE`/`loadProgramFilesLocatedE`
  (the string-error `loadProgramFiles`/`loadProgramFilesLocated` wrappers were
  removed with #100 — these return `Result LoadError`, so a dependency's parse
  error arrives attributed to ITS file; flatten with `loadErrorMessage` if the
  caller only wants text).
- **`typechecked` flag:** harvest errors via
  `checkProgramDiags : … -> <Mut> (List (String,Option Loc), List (String,Option Loc))`
  (`typecheck.mdk:9314`) or the boolean `checkErrorsWithRuntime`
  (`typecheck.mdk:9279`). Set `typechecked = (errors == [])`. Crucially,
  `checkProgramSchemesWithRuntime` returns **best-effort schemes even when the
  file has type errors** (it only fails to produce an env if the file doesn't
  *parse* — `docSchemes` returns `None` only on `parseResult == Err`,
  `lsp.mdk:480`), so Tier 1 degrades gracefully: see §6.

**`Loc` bridging in Tier 1: none needed.** Every Tier-1 query is keyed by the
*name* the rule already extracted from the raw decl (the function name, the
shadowed stdlib name), not by a source span. This is exactly why reusing the
LSP's name-keyed channel is sound here and *insufficient* for Tier 2.

The non-aborting accumulator that makes a single harvest safe is
`diagnostics.analyze`/`analyzeLocatedG` (single, `diagnostics.mdk:148-180`) and
`analyzeProject` (project, `:340-353`): they run parse→desugar→resolve→
exhaust→typecheck once, concatenate each stage's diagnostics, and never exit on
error (AGENTS.md "Errors accumulate"). A broken file does not sink the batch
(`wrappedRead` fallback, `diagnostics.mdk:292-305`).

### 4.3 Tier 2 — `typeOfLoc` (STRETCH, net-new; see fork §7)

Not built initially. Would require a new harvest pass that, during/after
inference, walks the typed tree collecting `(Loc, Mono)` from `ELoc`-wrapped
nodes (`ast.mdk:233`) — the only column-precise span carrier — and indexes by
span containment. Open problems: interior app/binop nodes and **all** patterns
are unwrapped (no `Loc`), and `Loc` is not unique, so lookups must be
"smallest enclosing `ELoc` span containing the query span" and will be
approximate. This is the messy part of the crux and is deliberately deferred.

---

## 5. Registry shape & integration

Add a third registry parallel to `Rule`/`CrossFileRule`, additive — no existing
rule changes:

```
public export record TypedRule
  name     : String
  descr    : String
  severity : Severity
  enabled  : Bool
  needsTypecheck : Bool          -- False = Tier-0-only (runs even on type-error files)
  check    : TypeOracle -> Positions -> List Decl -> List Finding
```

`allTypedRules : List TypedRule` registry (one fn + one binding + one list entry
per rule, same convention as `allRules`, `lint.mdk:121-123`). Driver mirrors
`lintProgram` (`lint.mdk:149-156`):

```
lintTypedProgram : List TypedRule -> TypeOracle -> Positions -> List Decl -> List Finding
lintTypedProgram rules orc pos prog = flatMap (runTypedRuleOn orc pos prog) rules

runTypedRuleOn orc pos prog r
  | r.enabled && (r.needsTypecheck => orc.typechecked) =
      map (restampSeverity r.severity) (r.check orc pos prog)
  | otherwise = []
```

This is a **third pass** in the lint run, after the per-file `Rule` pass and the
`CrossFileRule` pass. It reuses `restampSeverity` (`lint.mdk:158`),
`findingToDiag`/`lintToLines` (`:251-262`) and the existing `--deny`/`--disable`/
`--only` filtering unchanged (typed rules are filtered by the same name lists).

### Graceful degradation
- **Tier 0 typed rules** (`needsTypecheck = False`) always run — the constructor
  table needs no pipeline and is valid on un-typecheckable files.
- **Tier 1 typed rules** (`needsTypecheck = True`) are **skipped when
  `orc.typechecked == False`** (the file/project has type errors), avoiding
  findings derived from unreliable best-effort schemes. (Alternative, softer
  policy in §7.)
- **Default flag behavior:** gate the whole typed pass behind **`--type-aware`**
  (opt-in) for v1 — it adds a pipeline run per target (cost) and the project
  path needs the loader + runtime/core sources. The Tier-0-only subset is cheap
  enough that turning it *on by default* is a viable fork (§7). When the flag is
  off, the linter behaves exactly as today.

---

## 6. Touchpoints (all additive)

| File | Change |
|------|--------|
| `compiler/tools/lint.mdk` | New `record TypedRule`, `record TypeOracle`, `isIrrefutableArm`, `lintTypedProgram`/`runTypedRuleOn`, the typed-rule fns + `allTypedRules` registry. (`Rule`/`CrossFileRule` untouched.) |
| `compiler/tools/lint.mdk` | New `import frontend.exhaust.{Oracle(..), buildOracle, oGetCtors, oGetCtorType, oGetCtorFields}` and `import types.typecheck.{Scheme(..), Mono(..)}` (Tier 1). |
| `compiler/driver/medaka_cli.mdk` | In `runLintCmd` (`:764-781`): `let typeAware = hasFlag "--type-aware" argv` (`:765-769`; `lintTargets` at `:942` already strips any `--`-prefixed token, so no change there). When set, build the `TypeOracle` (Tier 0 always; Tier 1 via the harvest below) and call `lintTypedProgram` after the existing per-file/cross-file passes. |
| `compiler/driver/medaka_cli.mdk` | New oracle-build helper near the lint helpers (`lintOneFileReport` `:899`, `parseLintFiles` `:813`): single-file mirrors `docSchemes` (`lsp.mdk:479-486`) + `currentLocalSchemes`; project mirrors `checkModules` fed by `loadProgramFilesE`. Reads runtime/core like `runCheckCmd` (`:115-128`). |
| (reuse, no edit) | `compiler/frontend/exhaust.mdk` `buildOracle`/accessors (`:108-190`); `compiler/types/typecheck.mdk` `checkProgramSchemesWithRuntime` (`:7460`), `currentLocalSchemes` (`:1458`), `checkProgramDiags` (`:9314`), `checkModules` (`:9807`); `compiler/driver/diagnostics.mdk` `analyzeProject` (`:340`). |

No seed re-mint expected: `lint` is outside the self-compile graph (per
MEMORY.md "medaka lint" note — adding rules surfaced emitter gaps but the tool
itself does not re-mint), though new `import`s into `lint.mdk` should be
fixpoint-checked (`selfcompile_fixpoint.sh`) since they widen what the emitter
compiles.

---

## 7. Candidate rule catalog (≥4 typed rules)

**(a) Upgrade `rule-bind-then-destructure` → irrefutable single-arm match.**
Surface shape (raw AST): a `let Pat = e` or a single-arm `EMatch scrut [Arm pat
[] body]` where `pat` is a `PCtor`. **Oracle query:** `isIrrefutableArm orc pat`
(Tier 0 — `ctorCountOfCtor c == Some 1`). Fires only when the constructor is the
sole constructor of its datatype (newtype/single-ctor record), so the match
cannot fail and the bind is safe to flatten. *No typecheck, no `Loc` bridging.*
Highest value, lowest cost — ship first.

**(b) Sharpen §6 `rule-hand-rolled-derivable`.** Current `derivableHit`
(`lint.mdk:442-453`) warns on *any* `impl Eq/Ord/Debug` over a TyCon-headed type,
including imported/abstract/aliased types where `deriving` is impossible.
**Oracle query:** `orc.isLocalType tyName && isSome (orc.ctorCountOfType tyName)`
(Tier 0). Only suggest `deriving` when the type is locally declared with known
constructors/fields — eliminating false positives on types the user cannot
re-declare. *No typecheck.*

**(c) Sharpen §7a `rule-stdlib-reimpl` by signature.** Current `ruleStdlibReimpl`
(`lint.mdk:475-510`) warns purely on name collision against a curated list
(`stdlibNames`, `:469-473`), so an unrelated local `reverse : Matrix -> Matrix`
false-positives. **Oracle query:** `orc.schemeOfTop name` (Tier 1, name-keyed —
no `Loc` needed) compared structurally against the known stdlib scheme for that
name (e.g. `reverse : List a -> List a`). Fire only when the signatures unify.
`needsTypecheck = True` → auto-skipped on type-error files.

**(d) Redundant conversion / wrapping.** Two flavors:
- *Syntactic sub-case (Tier 0/none):* `map id xs`, `xs |> map id` — detect the
  function arg is the bare `EVar "id"`; no types needed (offer as a plain `Rule`,
  not even typed).
- *Type-needing case (Tier 1 name-keyed where possible):* redundant
  `intToString`/`floatToString`/`fromList (toList x)` where the inner expression
  is **already** the target type. When the inner expression is a bare identifier,
  `orc.schemeOfTop`/`schemeOfLocal name` answers it (Tier 1). When the inner
  expression is an arbitrary sub-expression, this needs `typeOfLoc` (**Tier 2,
  deferred**) — which is the rule that motivates the stretch tier but is *not*
  required for v1.

---

## 8. Design forks (need a human decision)

1. **On-by-default vs `--type-aware` flag.** Tier 0 typed rules (a, b, the
   syntactic part of d) need no pipeline run and could be **on by default**
   (they are as cheap as today's rules). Tier 1 rules (c) add a typecheck per
   target. Options: (i) everything behind `--type-aware` (simplest, opt-in);
   (ii) Tier 0 on by default, Tier 1 behind the flag; (iii) auto-enable Tier 1
   only when the project already typechecks clean. **Recommendation: start with
   (i)** for a clean v1, migrate Tier 0 to default once stable.

2. **Whole-project vs per-file oracle.** Per-file harvest (mirror `docSchemes`)
   is simpler and matches the linter's current per-file `Rule` pass, but
   cross-module types are unresolved for imported names. Project harvest
   (`checkModules` + loader) is accurate but costs a full graph load and changes
   the lint effect surface. **Recommendation: per-file for v1**, project as a
   follow-up (the cross-file `CrossFileRule` pass already proves multi-file
   plumbing exists).

3. **`Loc`-keying strategy (the Tier-2 question).** Build a true
   `typeOfLoc : Loc -> Option Mono` (net-new harvest of `(Loc, Mono)` from
   `ELoc` nodes, span-containment index, approximate for unwrapped/pattern
   nodes), **or** stay name-keyed forever and accept that redundant-conversion
   over arbitrary sub-expressions is out of scope. **Recommendation: defer Tier
   2**; revisit only if a concrete rule clearly needs it.

4. **Behavior on type-error files.** Skip Tier 1 rules entirely when
   `typechecked == False` (conservative — proposed default), **or** run them on
   best-effort schemes and risk findings derived from partial inference. Tier 0
   rules are unaffected (no types). **Recommendation: skip Tier 1 on type
   errors.**

5. **Cost / perf.** A typecheck-per-target on large projects is the main cost.
   Mitigations: cache the harvest (the diagnostics path already has a parse cache
   — `loadProgramFilesLocatedCached`, `loader.mdk:601`); only run the typed pass
   when ≥1 typed rule is enabled after `--only`/`--disable` filtering.

---

## 9. Effort estimate

- **Tier 0 framework + first typed rule (a, irrefutable single-arm match):**
  **small.** `buildOracle` is reused as-is; `TypedRule`/`TypeOracle`/
  `lintTypedProgram` mirror existing `Rule`/`lintProgram`; one CLI flag; the rule
  is pure syntactic + ctor-count lookup. No pipeline harvest, no `Loc` bridging.
- **Add Tier 1 (name-keyed schemes) + rules (b)(c):** **medium.** Adds the
  single-file harvest (mirror `docSchemes` + `currentLocalSchemes`), the
  `typechecked` gate, runtime/core source reading, and `Scheme` comparison
  helpers. Risk: new `import`s into `lint.mdk` must pass `selfcompile_fixpoint`.
- **Tier 2 (`typeOfLoc` over arbitrary sub-expressions):** **large** — net-new
  typed-tree harvest pass threading `Mono` onto `ELoc` nodes, span-containment
  index, plus handling unwrapped interior/pattern nodes. Deferred behind fork §7.3.

**Bottom line:** the type-aware tier's highest-value rules (irrefutable match,
sharpened deriving) are a **small** lift on the **already-exported, already-
syntactic** `exhaust.Oracle`, with **no `Loc` bridging required**. The genuinely
`Loc`-bridged, arbitrary-expression capability is the only large/messy piece and
should be deferred.
