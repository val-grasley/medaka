# MAP-SET-AMBIGUITY-DESIGN.md — ambiguous unqualified-import occurrence (use-time / approach A)

**Status:** IMPLEMENTED — see `compiler/frontend/resolve.mdk`, `AmbiguousOccurrence
String (List String) (Option Loc)` error constructor wired at the use-site emission
this doc specifies, and fixture `test/resolve_module_fixtures/map_set_ambiguous_use/`.
**Decision (user):** USE-time ambiguity
(Haskell "Ambiguous occurrence"), NOT import-time. Owning roadmap row: PLAN.md
Compiler/language. Skill: **add-language-feature** (resolve-rooted).

## 0. Problem

`stdlib/map.mdk` and `stdlib/set.mdk` (and `list.mdk`) export same-named *standalone*
functions (`size`, `fromList`, `member`, `union`, `insert`, `singleton`, …; plain
functions, not interface methods). With both `import map.*` and `import set.*`
unqualified, each colliding name becomes ONE flat binding — neither compiler is
type-directed. Native binds the **leftmost** import, the frozen OCaml oracle binds
the **rightmost**. Result: silent wrong-module dispatch (native crashes
`applied non-function`/`non-exhaustive match`/`no matching impl` by import order;
oracle silently picks the other module, occasionally numerically-coincidentally
"right"). This is two-flavors-of-broken on an ill-defined program. The fix: make it
a clear ERROR.

## 1. Mechanism (use-time / A)

Importing two modules with overlapping unqualified names is **fine**. The error fires
only when the program **uses** an unqualified name contributed by **≥2 distinct
non-`core` modules** *and* the use resolves to that import (not a local, not the
same-module top-level, not qualified). The A payoff: `import map.* ; import set.*`
with no colliding use stays valid (strictly less disruptive than import-time B).

Two parts:
1. **Import seam (record, don't error):** compute the **ambiguous-names set** = names
   whose in-scope provenance spans ≥2 distinct non-`core` module ids (pairwise
   intersection over per-import name lists). Record it in the resolve env as
   `name → [source module ids]` (the modules are for the message).
2. **Use seam (the new check):** at the `EVar` resolution site, after locals lose, if
   the name is in the ambiguous set (and isn't a same-module top-level), emit
   `AmbiguousOccurrence` located at the use.

## 2. Both-compiler touchpoints (file:line) — MUST move together or `diff_compiler_*` diverge

### Import seam (compute + thread the ambiguous set)
- **OCaml** `lib/resolve.ml`: `build_env` `DUse` arm (`:401-464`); names via
  `imported_names path exp` (`:427`, defn `:296-330`). `use_path` forms
  (`lib/ast.ml:239-244`): `UseWild`→all exports (`:321-327`), `UseGroup`→members
  (`:317`), `UseName` len>1→tail (`:308-313`), bare `UseName [single]`/`UseAlias`→**no
  unqualified names**. `core` excluded `:405`. **Add** a pre-pass building
  `name → module-id list` from each non-`core`/non-bare-alias import, keep ≥2-distinct;
  store in new env field `env.ambiguous` (name → source modules).
- **compiler** `frontend/resolve.mdk`: `buildEnvMM` (`:1232`) →
  `collectImports`/`oneImport`/`realImport` (`:1132-1185`); per-form names in
  `importedNamesMM` (`:1066-1077`, exact mirror). `core` excluded `:1143`. **Add** the
  same fold in `collectImports`; add `ambiguous : List (String, List String)` to the
  `Env` record (`~:120`), set in `buildEnvMM`.

### Use seam (the new check — locals/qualified excluded here)
- **OCaml** `lib/resolve.ml`: `EVar n` arm (`:552-554`) → `lookup_value env scope n`
  (`:471-475`); `scope` (locals) checked first (`List.mem name scope`). **Add**, after
  the unbound check: if `not (List.mem n scope) && not (Hashtbl.mem env.values n) &&
  Hashtbl.mem env.ambiguous n` → `emit (AmbiguousOccurrence (n, …))` (emit attaches
  `!current_loc`, `:477`).
- **compiler** `frontend/resolve.mdk`: `checkVar` (`:304-307`) via `lookupValue`
  (`:316-320`, `contains n scope` first). **Add** the mirror guarded by
  `not (contains n scope) && not (contains n env.values) && isAmbiguous env n` →
  `AmbiguousOccurrence n (ambigMods env n) cur` (`cur` = the same use-site loc
  `UnboundVariable n cur` already uses).

## 3. The three interactions that MUST stay clean (proven on both binaries)
- **Bug-C standalone-shadow** (a name that is an imported standalone AND a prelude
  interface method, e.g. `toList` from `map` + core's `Foldable`): single `import
  map.*` + `toList (fromList …)` → clean, runs the *standalone*. Only **1** non-`core`
  provenance (+ `core`, excluded) → NOT in the ambiguous set → no error. The Bug-C
  `standaloneValuesRef`/`buildStandaloneShadows` typecheck routing is untouched
  (downstream of resolve). ✓
- **Local shadowing** (`f size = size + 1` with both imported): the inner `size`
  resolves to the param — locals checked first + the new check is `not scope`-guarded.
  Stays clean. ✓
- **Qualified / explicit-disjoint** (`import map.{size}` + `import set.{member}`):
  single provenance per name → not ambiguous. This is the real escape hatch. (Bare
  `import map` + dotted `map.size` does NOT resolve as module-qualified — it parses as
  `EFieldAccess` and already type-errors on BOTH binaries — so the `.{…}` group is the
  working hatch.) ✓

## 4. Error shape
New `AmbiguousOccurrence (name, source_modules)`, located at the **use site**,
mirroring `UnboundVariable`'s located shape exactly (byte-identical positions):
- OCaml: `| AmbiguousOccurrence of ident * string list` in `type error`; pretty-print;
  emitted via `emit` so it carries `!current_loc`.
- compiler: `| AmbiguousOccurrence String (List String) (Option Loc)` in `data
  ResError`; add to `resErrorLoc` + `resErrorSexp` serializer (lockstep with OCaml
  `--resolve-modules` diagdump).
- Message: ``ambiguous occurrence: `size` is exported by both `map` and `set` —
  qualify or select per-name with `import map.{size}` / import only one``.

## 5. No-regression shapes (re-verified on both binaries)
| Shape | Under A |
|---|---|
| import-both, **use-neither** | **STAYS CLEAN — the A payoff** |
| import-both, **use ambiguous** | **NOW ERRORS** `AmbiguousOccurrence` at use loc |
| local shadow (`f size = …`) | clean (local wins) |
| single import | clean (1 provenance) |
| explicit disjoint groups (`import map.{size}`) | clean (1 provenance) |
| same module twice | clean (same mod-id, dedup before ≥2 test) |
| `core` + single user import | clean (`core` excluded at seam) |
| Bug-C method+standalone (single module) | clean + still routes standalone |

Only newly-rejected shape: **using** a name from ≥2 non-`core` modules (incl.
`list.*`+`set.*` iff the shared `singleton` is actually used). No corpus file does
this; the compiler graph is grep-clean of overlapping wildcards → fixpoint unaffected.

## 6. Gate plan + staging
Both compilers change identically → differential gates stay **0-failing** (both newly
reject the same uses, byte-identical S-exprs at identical locs).
- Gates: `diff_compiler_resolve` / `_resolve_modules` (primary), `diff_compiler_check_modules`
  / `_check_json` / `_check_cli_modules` (carat parity), `diff_compiler_typecheck` +
  `_errors`, **fixpoint** (`resolve.mdk` in-graph).
- New fixtures in `test/resolve_fixtures/`: `map_set_ambiguous_use.mdk` (import both +
  USE `size` → error) and `map_set_use_neither.mdk` (import both, use neither → clean).
  Capture goldens from **native** legs; prefer `resolve_fixtures` over a full
  multi-section `diff_fixtures` golden (golden-add footgun).

**Staging:** (1) add `AmbiguousOccurrence` to both error types + both serializers +
`resErrorLoc` (no detection) — wire format, gates green. (2) add `ambiguous` env field
+ import-seam population in BOTH `build_env` and `buildEnvMM`/`collectImports`, same
commit. (3) add the use-seam check in BOTH `EVar`/`checkVar` arms, same commit
(locals + same-module + `core` guards). (4) fixtures + native goldens; run resolve/
check/typecheck_errors diffs → 0 failures. (5) `FORCE_EMITTER_REBUILD=1 make medaka`,
verify fixpoint, re-mint seed at the checkpoint (orchestrator).

## 7. Risks
- **Frozen `lib/` MUST be edited for gate parity** (the oracle drives `diff_compiler_*`).
  Known parity exception to "lib is frozen" (cf. effects WS-2, floatToString).
- **Re-export provenance:** attribute a name by the **directly-imported** module-id,
  not the original definer, so a legit single re-export path isn't counted as 2.
- **Same-module-twice:** dedup module-ids before the ≥2 test.
- **Position parity:** emit via the existing `current_loc`/`cur` channel only — don't
  invent a new loc, or carat goldens diverge.
- **Seed staleness** (`resolve.mdk` in-graph): `FORCE_EMITTER_REBUILD=1 make medaka`.
