# Real source locations for the 3 `{0,0}`-range resolver diagnostics (F3)

Error-quality workstream. Three resolver diagnostics emit a dummy `{0,0}` range
(print `<unknown location>`), capping them at rubric A=1, giving them no L score
and no machine `fix`. This design gives them real source locations. Design pass
verified on the binary (base `0d5ef355`).

## The three, and how they split into TWO independent AST changes

| Diag | fixture | needs loc on |
|---|---|---|
| `R-UNKNOWN-TYPE` | `resolve/unbound_type_in_sig` | the **type-reference** node (`TyCon`) |
| `R-PRIVATE-NAME` | `resolve/import_unknown_name` | the **import** node (`DUse`) |
| `R-MODULE-LOAD` | `resolve/unknown_module` | the **import** node (`DUse`) |

So: **Chunk B** = one `DUse` loc unlocks both import diags (cheap, sexp-invisible,
hazard-free). **Chunk A** = a `TyCon` loc unlocks the type diag (expensive, hot path).

## Decisive finding: no positioned type wrapper exists
`compiler/frontend/ast.mdk:28-35` `Ty` has NO `TyLoc`/`Loc` field (unlike expr
`ELoc Loc Expr`). `DUse Bool UsePath` / `UsePath` (L266-298) carry no Loc either.
The parser HAS the positions in hand (`getPos`/`locOfSpan`/`located`,
`parser.mdk:115-172`; the `ELoc` template) — capture is "store what you have".

## Locked decisions (design forks resolved)
- **Fork 1 — TyCon carrier: FIELD `TyCon String (Option Loc)` (A2), NOT a `TyLoc`
  wrapper (A1).** The wrapper is one line cheaper in sexp but silently defeats the
  deep positional matches on `Ty` (`prop_runner` gen/shrink `TyApp (TyCon "List") t`,
  `eval`/`lower`/`typecheck` head-matchers) — a *silent* bug. The field forces
  every `TyCon` site to be touched (~127: 58 constructions add `None`, rest add
  `_`) but the compiler flags each and shape-matches still work. sexp stays
  byte-identical: `tySexp (TyCon c _) = node "TyCon" [escStr c]` (the "serializer
  ignores the field" idiom). Keeps the 74 `*.desugar/mark.golden` + analyze/
  resolve_modules/typecheck_golden byte-identical. `positions` gate unaffected
  (separate side-channel).
- **Fork 3 — R-MODULE-LOAD via ENTRY-SCAN (a), not loader-retype (b).** The
  `unknown module` error is a raw `Result String` deep in the loader
  (`loader.mdk:286/308`), Diag-ified at `diagnostics.mdk:425` with `None` loc.
  Rather than thread `Option Loc` through ~6 loader signatures, parse the failed
  modId out of the message near L425 and find the entry `DUse` whose
  `importModId path` matches → use its (new) loc. Keeps the loader channel
  untouched. (Reassess if the loader is being touched anyway.)
- **Fork 4 — loc on `DUse` (statement granularity), not `UsePath`.** No fix
  precision needed for the import diags (they have no did-you-mean), so
  statement-level is enough; 1 type-def site vs 4 `UsePath` constructors.
- **Fork 2 — is the expensive Chunk A worth it? STAGED DECISION.** Do Chunk B
  first (cheap, unlocks 2/3). Reassess Chunk A (the pervasive `TyCon` field) after
  B lands — it's the only one that yields a machine `fix` (auto-replace the typo,
  and it'd give the Haskell TYPE-aliases `Maybe`→`Option` etc. a fix too), but
  ~127 sites on the hot path. NOTE the fix-span precision constraint
  (`diagnostics.mdk:90-96` recomputes `fix` as `loc.start → start+len(bad)`), so
  Chunk A genuinely needs the token-level `TyCon` loc (a decl-level loc would
  produce a corrupting fix) — the existing `checkType cur` decl-loc thread is
  insufficient.

## Decomposition + order (each independently gated + merged; shared files ⇒ sequential)
1. **Chunk B — `DUse` loc → R-PRIVATE-NAME + R-MODULE-LOAD (Sonnet).** New
   `DUse Bool UsePath Loc` (+ `getPos` capture at `parseImport` `parser.mdk:2065`);
   sexp-invisible (`declSexp` `sexp.mdk:242` adds `_`); thread the loc into
   `importedNamesMM`/`pubErr` (`resolve.mdk:1377-1396`, replaces the `None` at
   1396) for R-PRIVATE-NAME; entry-scan in `diagnostics.mdk:425` for R-MODULE-LOAD.
   ~22 mechanical `DUse` `_`-sites (resolve/loader/typecheck/eval/mangle/lint/
   doctest/lsp). No positional-match hazard. Fully golden-invisible (sexp).
2. **Chunk A — `TyCon` loc → R-UNKNOWN-TYPE (Opus, staged-gated on Fork 2).**
   `TyCon String (Option Loc)` (A2); capture at `parseTyAtom` `parser.mdk:1791`;
   thread the con's own loc into `UnknownType` at `resolve.mdk:220-224` (from the
   TyCon, not `cur`). ~127 sites. sexp-invisible.

## AS-BUILT — both chunks DONE (fixpoint C3a/C3b YES, ZERO re-mint, sexp-invisible)
- **Chunk B — `2d9138fb`.** `DUse Bool UsePath Loc`; captured in `parseImport`;
  sexp-invisible; ~25 mechanical sites. `R-PRIVATE-NAME` located via
  `usePathLocsOf`/`withResErrorLoc` threading the DUse loc through
  `collectImports`/`importedNamesMM`/`pubErr`; `R-MODULE-LOAD` via the Fork-3
  entry-scan (`unknownModuleIdOf` + `findImportLoc` matching `importModId`, wired
  into `runCheckCmd`/`runCheckJsonCmd`). **Unplanned discovery:** the multi-module
  `Loc.file` is always `""` (loadProgram carries no per-module path) — fixed with
  a fallback-file variant (`ppResErrorLocatedF`) using the CLI entry path (correct
  when the bad import is in the entry module; a transitive dep degrades to the
  entry file rather than the old `<unknown location>`). Both fixtures now
  `file:1:0:`. desugar/mark/resolve_modules byte-identical.
- **Chunk A — `9d6398ad`.** `TyCon String (Option Loc)` (field, decision A2);
  captured in `parseTyAtom`; `tySexp` ignores it (byte-identical). ~40 sites
  (fewer than the 127-estimate — many grep hits were comments/dup patterns) across
  typecheck/prop_runner/core_ir_lower/eval/parser/printer/desugar/fuzz_gen/lint/
  doc. `checkType` threads the TyCon's own loc (`orElseLocL loc cur`) into
  `UnknownType` → `diagnostics.mdk` auto-builds the precise `fix` span.
  **Payoff:** `R-UNKNOWN-TYPE` now located + machine `fix` (`Strng`→`String`), AND
  every type-position hint including the Haskell type-aliases (`Maybe`→`Option`,
  `Monad`→`Thenable`, …) now carries an agent-applicable `fix`. desugar/mark 114/0,
  `diff_compiler_test` (prop_runner positional matches) green, positions 6/0.
- **Fork 2 resolved: Chunk A WAS done** (the machine-fix payoff across all
  type-position hints justified the ~40-site cost; it came in far cheaper than the
  127-estimate and fully sexp-invisible).

## Verify (each chunk): fixpoint C3a/C3b (error-path/loc-only → NO re-mint),
`diff_compiler_{check,check_json,resolve,resolve_modules,desugar,mark,typecheck_golden,positions,parse,build}`
byte-identical (sexp-invisibility is the whole point), + reproduce the fixture's
new real `range` in `--json`. Chunk A additionally: prop_runner/eval/lower still
behave (no silent type-match break).
