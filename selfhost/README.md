# selfhost — Medaka-in-Medaka compiler (Stage 1)

The self-hosted Medaka compiler, ported one pipeline stage at a time from the
OCaml reference in `lib/` and validated against it via differential testing.
See the **North star → Stage 1** section of [`../PLAN.md`](../PLAN.md).

Runs **on the existing tree-walking interpreter** (`medaka run …`) — correctness
first; native codegen is Stage 2.

## House style

Idiomatic Medaka, not transliterated OCaml — the self-host port is also how we
*dogfood* the language, so we lean into its idioms rather than minimizing the
diff with `lib/`:
- **Multi-clause functions** with pattern-matching heads (incl. literal heads
  like `keywordOrIdent "let" = TLet`), not `match` on the sole argument. Reserve
  `match` for case analysis on a *computed/local* value.
- **Type signatures on every top-level function.**
- Higher-order functions (`map`, etc.) where they read clearly; treat
  idiom-friction (e.g. the Phase 134 `map` quirk) as a bug to fix, not avoid.
- Structural parallelism with the OCaml reference is kept **only** in the core
  scan/parse algorithms, where it buys byte-for-byte validation.

## Layout

| File | Role |
|------|------|
| `lexer.mdk` | Port of `lib/lexer.mll`. `Token` ADT + `tokenToString` (mirror the OCaml `token_to_string` byte-for-byte) + `tokenize`. Prelude + global externs only — no stdlib import, so `selfhost/` is the sole project root. |
| `lex_main.mdk` | Runnable entry: `medaka run selfhost/lex_main.mdk <src.mdk>` reads the file, tokenizes, prints one token per line in the canonical reference form. |
| `ast.mdk` | The self-host AST — a Medaka mirror of `lib/ast.ml`'s surface (pre-desugar) nodes; the target the parser builds. Constructor names match `ast.ml`. |
| `sexp.mdk` | `programToSexp` — a canonical structural S-expression dump of the AST, mirroring `dev/astdump.ml` byte-for-byte; the parser's validation format (the `tokenToString` analog). |
| `parser.mdk` | Port of `lib/parser.mly`. A **monadic combinator** parser over `List Token` — a `Parser` monad (`Mappable`/`Applicative`/`Thenable`) with `do`-notation + `many`/`sepBy1`/`choice`/`chainl1`; `parse : String -> List Decl`. Precedence is the stratified ladder, one function per level. |
| `parse_main.mdk` | Runnable entry: `medaka run selfhost/parse_main.mdk <src.mdk>` reads the file, parses, and prints the structural S-expression. |
| `desugar.mdk` | Port of `lib/desugar.ml`. Lowers surface sugar to core: the bottom-up `mapExpr`/`mapDecl` engine + the passes `merge_iface_defaults → expand_decl (deriving) → list-comps → questions → do-blocks → sugar`; `desugar : List Decl -> List Decl`. |
| `desugar_main.mdk` | Runnable entry: parse + desugar a file, print the structural S-expression (diffs against `astdump --desugar`). |
| `marker.mdk` | Port of `lib/method_marker.ml`. Marks interface-method / constrained-fn occurrences (`EVar`→`EMethodRef`/`EDictApp`); includes the Phase 78a/78b prelude-shadowing logic. `markWithPrelude : List Decl -> List Decl -> List Decl` (prelude, target). |
| `mark_main.mdk` | Runnable entry: `medaka run selfhost/mark_main.mdk <prelude.mdk> <src.mdk>` parses + desugars both, marks the target, prints the S-expression (diffs against `astdump --mark`). |
| `resolve.mdk` | Port of `lib/resolve.ml` (single-file path). Name-binding / scope / unknown-name checks over a list-based env seeded from runtime + prelude; `resolveProgram : List Decl -> List Decl -> List Decl -> List ResError`. |
| `resolve_main.mdk` | Runnable entry: `medaka run selfhost/resolve_main.mdk <runtime.mdk> <core.mdk> <src.mdk>` prints one diagnostic per line (diffs against `diagdump --resolve`, the harness sorts). |
| `exhaust.mdk` | Port of `lib/exhaust.ml`'s `check_guard_exhaustiveness` (guard coverage over the raw AST; Maranget `useful` matrix). No prelude — the ctor oracle is built from the file's own data decls + builtins. `exhaustToLines : List Decl -> String`. |
| `exhaust_main.mdk` | Runnable entry: `medaka run selfhost/exhaust_main.mdk <src.mdk>` prints one guard warning per line (diffs against `diagdump --exhaust`, the harness sorts). Parses **without** desugaring (guards must still be `EGuards`). |
| `eval.mdk` | Tree-walk interpreter (Stage-1 capstone, **slice 1**). `Value`/`Env` ADTs + `pp_value` (byte-for-byte with `lib/eval.ml`) + the engine: `eval`/`apply`/`match_pat`/binops over `(name, Ref value)` env frames. `evalMain : List Decl -> <Mut> String`. |
| `eval_main.mdk` | Runnable entry: `medaka run selfhost/eval_main.mdk <src.mdk>` parses + desugars a self-contained (prelude-free) file, evaluates it, prints `pp_value` of `main` (diffs against `dev/eval_probe.exe`). |
| `eval_prelude_main.mdk` | Like `eval_main` but prepends one or more parsed prelude files: `medaka run selfhost/eval_prelude_main.mdk <prelude.mdk>... <src.mdk>` — `core.mdk` for interface methods, `+ list.mdk` for the List combinators / comprehensions (diffs against `dev/eval_probe.exe --prelude` / `--prepend`). |
| `eval_run_main.mdk` | **True execution**: `medaka run selfhost/eval_run_main.mdk <prelude.mdk>... <src.mdk>` runs the program for its **stdout** (putStr/putStrLn captured to a buffer), prelude-shadow-dropping the user's redefinitions. Diffs against the `=== EVAL ===` goldens (`test/diff_selfhost_eval_run.sh`). |
| `eval_typed_main.mdk` | **Typed execution** (return-position dispatch): `medaka run selfhost/eval_typed_main.mdk <runtime.mdk> <prelude.mdk>... <src.mdk>` threads desugar → `typecheck.elaborate` (stamps `EMethodAt` tags) → eval on one shared tree, so `pure`/`empty`/do-blocks dispatch by concrete return type. Diffs against `medaka run` (`test/diff_selfhost_eval_typed.sh`). |
| `typecheck.mdk` | HM core (**slice 1**). `Mono`/`Scheme` + union-find `unify`, level-based `generalize`/`instantiate`, `pp_mono`, and `infer`/`inferPat`. `checkToLines : List Decl -> <Mut> String`. |
| `typecheck_main.mdk` | Runnable entry: `medaka run selfhost/typecheck_main.mdk [runtime.mdk] <src.mdk>` prints `name : scheme` per top-level binding (diffs against `dev/tc_probe.exe`; both sorted). With a runtime.mdk arg its externs are seeded into scope, so `core.mdk` (+ a user program) type-checks against the `=== TYPES ===` goldens. |
| `check.mdk` | **Composed front-end** — `medaka run selfhost/check.mdk <runtime.mdk> <core.mdk> <src.mdk>` wires parse → desugar → resolve → exhaust → typecheck into one program (the self-hosted analog of `medaka check`). Prints resolve diagnostics, else guard warnings + inferred schemes. `test/diff_selfhost_check.sh` validates it reproduces the 16 TYPES goldens (clean) and 9 resolve diagnostics (broken). |
| `medaka.toml` | Project config (import root). |

The OCaml-side validation references live in `dev/`: `lextok.exe` (token-stream
dumper), `astdump.exe` (AST S-expression dumper, with `--parse`/`--desugar`/
`--mark` stage modes), and `diagdump.exe` (`--resolve`/`--exhaust` diagnostics
dumper).

## Validation

```sh
dune build --root .                       # build the reference binary
sh test/diff_selfhost_lexer.sh            # diff the Medaka lexer vs OCaml goldens
```

The harness runs the Medaka lexer over every fixture in `test/diff_fixtures/`
and diffs its token stream against that fixture's golden `=== TOKENS ===`
section (those goldens are emitted by the OCaml `Lexer.tokenize_string`). A
fixture flips from `FAIL` to `ok` as the corresponding lexer behavior is ported;
the stage is done when all pass.

## Status

- ✅ Scaffold + harness wiring (token ADT, canonical serializer, runnable entry,
  diff loop).
- ✅ Tokenizer ported: int/float/string/char literals (with char escapes
  `\n \t \r \0 \\ \'` + `\u{…}`, mirroring Phase 133) + hex/bin/oct literals,
  idents/keywords, operators/punctuation, line + nestable `{- … -}` block
  comments, **string interpolation**, the `@`/`AS_AT` adjacency rule, and the
  INDENT/DEDENT/NEWLINE layout algorithm (plus else-continuation filter and
  leading-operator continuation).
- ✅ **Triple-quoted strings** (`""" … """`): only `"""` closes (single/double
  quotes stay literal), raw newlines are kept, `\{…}` interpolates, and the
  content dedents via `stripIndent` when it opens with a raw newline. An
  interpolation opened from a triple string is tracked by a *negative* interp
  depth so the closing `}` resumes the triple continuation (vs the single-string
  one). Covered by `test/diff_fixtures/triple_str.mdk`.
- ✅ **Validated two ways**, both byte-for-byte against the OCaml reference:
  - **16/16 curated fixtures** — `sh test/diff_selfhost_lexer.sh`.
  - **13/13 real `.mdk` files** (every stdlib module + this lexer lexing itself)
    — `sh test/diff_selfhost_lex_files.sh`, which diffs against
    `dev/lextok.exe` (the OCaml reference dumper). FLOAT literal *text* is
    normalized away (OCaml `%g` vs `floatToString`: `1.0` → `1` vs `1.`; the
    TFloat value is identical). One more serialization-only nuance, not hit by
    any real file: control bytes in STRING/CHAR render `\0` (`debugStringLit`)
    vs `\000` (`%S`) — same value, different debug escaping.
- ✅ Lexer surface complete. The only unhandled construct is *nested* string
  interpolation (a `"…"` string literal inside a `\{…}` expression) — but the
  OCaml reference rejects it too ("Unterminated string literal"), so it isn't
  valid Medaka and there's nothing to mirror.

### Parser (Stage 1, in progress)

- ✅ Scaffold: `ast.mdk`, the `sexp.mdk` structural dumper, the OCaml reference
  dumper `dev/astdump.exe`, and the diff harness — validation in place *before*
  parse logic, same as the lexer.
- ✅ **Slice 1** (`parser.mdk`): the arithmetic ladder, application, atoms
  (literals, vars/constructors, parens, tuples, list literals), simple param
  patterns, the type grammar, and top-level `DFunDef`/`DTypeSig`.
- ✅ **Slice 2**: the rest of the operator ladder (`||`, `&&`, comparisons,
  `::` right-assoc, `++`), `=>` lambdas, single-line `if`/`then`/`else`, and
  postfix field access (`.field`) — via a generic `chainLeft`/`chainRight`.
- ✅ **Slice 3**: single-line `let … in`, **`match`** with indented arms (the
  first `INDENT`/`DEDENT` layout handling), the full pattern hierarchy
  (constructor application, `::`, tuple, list patterns), and a single-expression
  indented decl body. Validated on `test/parse_fixtures/`.
- ✅ **Rewritten as a monadic combinator parser** (after Phase 136 unblocked
  recursive polymorphic combinators and a perf comparison showed it's perf-neutral
  vs direct recursive descent). Same grammar/AST output (10/10 corpus still
  matches), but dogfoods `do`/`Thenable`/a custom `Parser` monad. The progress
  guard now lives in a primitive `many` (stops on failure *or* no-progress, so it
  can't loop). Recursive parsers must recurse through a `do`-continuation, never
  by passing themselves as a strict argument (that forces a recursive value mid-
  definition → `CamlinternalLazy.Undefined` under strict eval).
- ✅ **Slice 4**: multi-statement indented blocks — bare blocks (`EBlock`) and
  `do`-blocks (`EDo`) with `DoExpr`/`DoBind`/`DoLet` statements.
- ✅ **Slice 5**: effect types (`<IO> Unit`, `<IO, Mut> a`, `<IO | e> a`, the bare
  tail `<e> a`).
- ✅ **Slice 6**: `data`/`record` declarations — inline + block forms,
  visibility prefixes, positional and named-field payloads, `deriving (…)`.
- ✅ **Slice 7**: string interpolation (`"…\{expr}…"` → `EStringInterp` of
  alternating `InterpStr`/`InterpExpr` parts).
- ✅ **Slice 8**: function guards (`EGuards` of `| guard, … = body` arms, incl.
  `<-` pattern-bind guards), unary minus (`EUnOp "-"`, tighter than `*`),
  expression type annotations (`EAnnot`, loosest level) + `_` lambda params
  (`PWild`), and record literal/update expressions (`ERecordCreate` /
  `ERecordUpdate`). **15/15 real `test/diff_fixtures/` files** parse identically.
- ✅ **Slices 9–13**: everything the real stdlib needs —
  - imports (`DUse`/`UsePath`), `extern` (`DExtern`), `export`/`public export`
    visibility, constrained sigs (`TyConstrained`);
  - `where` blocks (`ELetGroup` w/ clause coalescing), range literals
    (`ERangeList`), array literals, as-patterns (`PAs`), full lambda-LHS →
    pattern conversion;
  - block-form `if`/`match` bodies, else-less `if`, `prop`/`test`/`bench` decls;
  - `interface`/`impl` (`DInterface`/`DImpl`: supers, defaults, named impls,
    `requires`, multi-clause methods), the full operator ladder (`|>` `>>` `<<`
    `!` + backtick infix), operator sections (`ESection`), unit/literal
    patterns.
- ✅ **Stage 1 parser complete.** Validated byte-for-byte against the OCaml
  reference (`dev/astdump.exe`) on **all 13/13 real stdlib `.mdk` files**, the
  **15/15 real `test/diff_fixtures/`**, **23/23 curated `test/parse_fixtures/`**,
  and — the milestone — **its own entire 6-file source** (`selfhost/*.mdk`,
  including `lexer.mdk` and `parser.mdk` parsing themselves). The reference
  dumper `dev/astdump.ml` was extended in lockstep so no decl/expr renders as a
  `TODO` placeholder on any stdlib file.
- ✅ **List comprehensions** (`EListComp`, generator/guard/`let` qualifiers),
  added after the fact so `hash_map.mdk`'s `keys`/`values` dogfood
  `[k | (k, _) <- entries m]`. Required extending `dev/astdump.ml` first (it had
  rendered `EListComp` as `TODO`).
- ✅ **Remaining surface-grammar gaps closed** — `function` (`EFunction`), `?`
  (`EQuestion`), array slice/index `e.[lo..hi]`/`e.[i]` (`ESlice`/`EIndex`),
  array range `[|lo..hi|]` (`ERangeArray`), `let mut` + assignment
  (`DoAssign`/`DoFieldAssign`), let-else (`DoLetElse`), do-block function-let,
  range patterns (`PRng`, int + char), `if` match-arm guards, and record
  patterns (`PRec`, `C { f = p, … }` / `C { .. }`). Most needed a
  `dev/astdump.ml` extension first (they were `TODO`). Toy coverage lives in
  `test/parse_fixtures/rare_constructs.mdk`. **Parser surface-grammar coverage is
  now complete** — the only remaining unhandled surface is lexer-side (nested
  interpolation / triple-quoted strings).

  *(Parser combinators were spiked and parked — blocked on Phase 136; see PLAN.)*

## Roadmap — remaining Stage 1 stages

Lexer, parser, **desugar**, **method_marker**, **resolve** (single-file path),
and **exhaust** (guard-coverage pass) are done. What remains is the **typecheck**
and **eval** capstones (typecheck also drives the type-aware `check_match`
exhaustiveness, distinct from the guard pass ported here). This section sketches
how to port them.

**Validation infrastructure for every remaining stage is already built** (the
"de-risk first" pass):
- `dev/astdump.exe` takes `--desugar` / `--mark` to dump the AST after those
  stages (the `--parse` default is unchanged). `test/diff_selfhost_{desugar,mark}.sh`
  diff the self-host stage against it.
- `dev/diagdump.exe --resolve|--exhaust` dumps each stage's diagnostics in a
  canonical, sorted, location-stripped form. `test/resolve_fixtures/` (9) and
  `test/exhaust_fixtures/` (5, incl. negative controls) are the net-new negative
  corpus + committed goldens; `test/diff_selfhost_{resolve,exhaust}.sh` run them.

### The methodology carries over

Every remaining stage is **differentially testable against the OCaml reference**,
the same way the lexer/parser were — and most of the oracle infrastructure
already exists:

- **AST→AST stages** (desugar, method_marker) keep the same `program` type, so
  they dump as S-expressions through the existing `dev/astdump.exe` ↔
  `selfhost/sexp.mdk` machinery. The diff is just `source → both pipelines →
  compare dumps`, and the **entire corpus** (stdlib + `test/diff_fixtures/` +
  `selfhost/`'s own source) becomes the test set for free. First task for each:
  add a dump mode to `astdump` (e.g. run `Desugar.desugar_program` before the
  `strip_locs` dump) and mirror any new/changed node in `ast.mdk`/`sexp.mdk`.
- **typecheck** emits type *schemes* — already serialized as the `=== TYPES ===`
  section of every `test/diff_fixtures/*.golden` (see `dev/gen_golden.ml`). The
  diff is inferred-scheme-per-binding.
- **eval** produces runtime values (closures/refs — not serializable), but its
  **stdout** is already captured as the `=== EVAL ===` golden section. The diff
  is program output: run it, compare what it printed.
- **resolve / exhaust** emit *diagnostics* (error / warning strings) — trivially
  diffable, but they need **negative fixtures** (programs with deliberate unbound
  vars, privacy violations, non-exhaustive matches); today's corpus is all valid
  programs, so this is net-new test material.

Each new IR shape gets the same `ast.mdk ↔ sexp.mdk ↔ dev/astdump.ml` lockstep
treatment used throughout the parser port. Mutable-state-heavy designs re-express
with `Ref` + the `hash_map`/`map` stdlib (which is exactly why those were flagged
Stage-0 prerequisites in `../PLAN.md`).

### Stages, in suggested order (easy-first; hardest last)

| # | Stage | ~LOC | Difficulty | In → Out | Validate via |
|---|-------|------|-----------|----------|--------------|
| 1 | ✅ **desugar** | ~980 | low–med | `program → program` | astdump `--desugar`, **60/60 corpus** |
| 2 | ✅ **resolve** | ~1000 | med | `program → diagnostics` (+ name env) | diagdump `--resolve`, **full corpus + 9 fixtures** |
| 3 | ✅ **method_marker** | ~420 | low–med | `program → program` (marks `EMethodRef`/`EDictApp`) | astdump `--mark`, **full corpus** |
| 4 | ✅ **exhaust** | ~465 | hard (algorithm) | `program → warnings` | diagdump `--exhaust`, **full corpus + 5 fixtures** |
| 5 | ✅ **eval** | ~2350 | hard (plumbing) | `program → values / stdout` | `dev/eval_probe.exe` + **all 16 `=== EVAL ===` goldens** (untyped *and* typed paths) |
| 6 | ✅ **typecheck** | ~4650 | **very hard** | `program → schemes` | `dev/tc_probe.exe` + **all 16 `=== TYPES ===` goldens** |

1. ✅ **Desugar — DONE.** `selfhost/desugar.mdk` + `desugar_main.mdk`: the
   bottom-up `mapExpr`/`mapDecl` engine plus the passes `merge_iface_defaults →
   expand_decl (Eq/Debug/Display/Generic deriving) → desugar_list_comps →
   desugar_questions → lower_do_blocks → desugar_sugar`. Matches
   `astdump --desugar` byte-for-byte on all 60 corpus files (incl. desugaring
   its own source). Key wins that made it tractable: desugar is deterministic
   with no stateful gensym (positional `__a%d` / fixed `__x`,`__fallthrough__`
   names), and its output uses only nodes `sexp.mdk` already renders. Deferred
   (unused by the corpus; the self-host AST lacks the `ESetLit`/`EMapLit` nodes
   they target): record-pun desugaring, container-literal lowering, Ord/Arbitrary
   deriving, and record deriving.
   > **Prelude-access prerequisite (NEW — decided next).** Both resolve and
   > method_marker need the *prelude*'s names (resolve seeds prelude
   > value/type/ctor/interface names so a file using `map`/`eq` resolves clean;
   > `--mark` marks prelude-method references — e.g. list.mdk gets 22 EMethodRef
   > for `eq`/`map`/`compare`/…). Desugar didn't need this (purely syntactic on
   > the file). The reference reads them from the embedded `Prelude.program`
   > (= `stdlib/core.mdk`). **Recommended approach** (no new build step, mirrors
   > how the multi-module loader already takes sibling files): have
   > `resolve_main.mdk`/`mark_main.mdk` take the prelude path as an extra arg
   > (`… stdlib/core.mdk <file>`), parse+desugar it, and extract the name sets —
   > the selfhost parser+desugar already match the reference on core.mdk, so the
   > extracted names will match `Prelude.program`'s. The harnesses pass the path.
   > (Alternative: a build-time generated `prelude_names.mdk`, in the spirit of
   > `gen/embed.ml`. Left as a design choice.)
2. ✅ **Resolve — DONE (single-file path).** `selfhost/resolve.mdk` +
   `resolve_main.mdk`: a name environment (lists, not hashtables) seeded with
   primitives + runtime externs (runtime.mdk) + the prelude (core.mdk, both
   passed by path like the marker; `program_is_core` suppresses the prelude seed
   when resolving core itself), then `checkType`/`checkPat`/`checkExpr`/
   `checkDecl` returning **error lists** (pure — no mutable ref; locations
   dropped since the self-host AST has none). Scope threads locally-bound names
   through lambdas/lets/match/do/comprehensions/where-groups; `build_env` collects
   user names + import stubs and detects DuplicateDefinition (order-sensitive,
   seeded) and ExternWithBody. Matches `diagdump --resolve` byte-for-byte on the
   whole corpus *and* the 9 `test/resolve_fixtures/` negative cases — validated
   both ways (right errors on broken files, no false positives on valid ones).
   **Deferred:** the multi-module path (the reference's `resolve_module` —
   imports validated against real exports, privacy, aliases; the
   PrivateNameAccess / NoExportedConstructors / UnknownModule errors) — not
   exercised by `diagdump --resolve`, which uses the single-file path. Also not
   yet hit by any corpus file: QuestionMisplaced / AsPatternMisplaced /
   NonRecursiveValueLet. **Perf hook (still open):** give each variable reference
   a resolved `(frame, slot)` address — see *Performance* below.
3. ✅ **Method_marker — DONE.** `selfhost/marker.mdk` + `mark_main.mdk`:
   interface-method / constrained-fn `EVar`s → `EMethodRef`/`EDictApp` (just the
   name; the typecheck-filled ref is irrelevant pre-typecheck), backtick `EInfix`
   with a marked op → prefix-applied marked ref, methods take precedence. Name
   sets union the prelude + target; the marker reuses desugar's `mapProg`. The
   **prelude-via-path approach worked** — `mark_main` takes `stdlib/core.mdk` as
   an arg and extracts the name sets from a parse+desugar of it. The
   prelude-shadowing logic is fully ported: Phase 78b (`shadow_rename` —
   `map.mdk`'s standalone `isEmpty` → `isEmpty#shadow`) and Phase 78a (drop a
   *droppable* shadowed prelude constrained fn from the constrained set — `count`/
   `find` dropped, `clamp` kept because a core prop references it). Matches
   `astdump --mark` byte-for-byte on the whole corpus, incl. the marker marking
   its own source. Simplification still standing: `shadow_rename` skips the
   "name is also a local binder" exclusion (no corpus file triggers it).
4. ✅ **Exhaust — DONE (guard-coverage pass).** `selfhost/exhaust.mdk` +
   `exhaust_main.mdk`: the standalone `check_guard_exhaustiveness` (Phase 91(2))
   over the **raw pre-desugar AST** (function/where guards still `EGuards`).
   Warns once per same-name clause group whose guards may fall through *unless*
   the non-falling-through clauses' patterns already cover every input — decided
   by a faithful port of the Maranget `useful` pattern-matrix recursion
   (`specialize`/`default`/`head_ctors`/`useful`), with multi-param coverage
   reduced to one synthetic `__tupleN__` column. The constructor oracle is built
   from the file's own data decls + the syntactic builtins (Bool/List/Unit), so
   **no prelude is needed**. Groups gathered from top-level `DFunDef` clauses,
   `where`/let-group (`ELetGroup`) clauses reached anywhere in a body, impl
   methods, and interface defaults. Matches `diagdump --exhaust` byte-for-byte on
   the full corpus + all 5 `test/exhaust_fixtures/` cases (incl. the
   `useful`-machinery "excused by catch-all" control and the multi-warning case).
   The type-aware `check_match` exhaustiveness is **not** here — it lives inside
   typecheck (it needs the scrutinee type), so it ports with that stage.
5. 🚧 **Eval — IN PROGRESS (slice 1 of N).** The **Stage-1 capstone**: a
   tree-walk interpreter (`selfhost/eval.mdk` + `eval_main.mdk`) that makes the
   self-hosted compiler *executable on itself*. Plumbing-heavy (per-frame env
   refs, `VMulti` typeclass dispatch, dict-passing semantics) but not
   algorithmically deep. **Validation bridge:** rather than wait for typecheck,
   the engine is exercised on the UNTYPED path — `dev/eval_probe.exe`
   (`Eval.eval_program ~prelude:false` → `Eval.pp_value`) is the oracle, and
   fixtures in `test/eval_fixtures/` are self-contained / prelude-free, each
   aggregating its results into one `main` value rendered by `pp_value`
   byte-for-byte on both sides (`test/diff_selfhost_eval.sh`).
   - **Slice 1 (DONE):** the engine core — literals, vars, application, lambdas/
     closures, let / letrec / let-groups, bare blocks, `match` (+ guards), `if`,
     binary/unary operators (incl. structural `==`/`<` mirroring OCaml's
     `=`/`compare` on `value`), tuples, lists, ADTs (constructor builders +
     pattern matching), multi-clause dispatch (`VMulti`, first-pattern-match),
     and recursion. The env is `(name, Ref value)` frames back-patched via
     `set_ref` (so the cluster carries `<Mut>`; `VPrim` holds a `Value -> <Mut>
     Value`). 7/7 fixtures match.
   - **Slice 2 (DONE):** arrays (`VArray`, `EArrayLit`), indexing (`a.[i]`),
     slicing (`a.[lo..hi]`), and ranges (`[lo..hi]` / `[|lo..=hi|]`), plus the
     **extern kernel** — each primitive a `VPrim` wrapping the reference's own
     native extern with the Value-boundary marshalling `lib/eval.ml`'s
     `primitives` table does (e.g. `stringToChars` wraps native chars into
     one-codepoint `VChar`s; `charFromCode`/`stringIndexOf` return `Some`/`None`
     `VCon`s; `stringCompare` returns `Lt`/`Eq`/`Gt`). Curried multi-arg externs
     nest `VPrim`s. Covers the int/string/char/array kernel (IO/Rand/Panic
     externs are out of scope — the oracle compares a computed value, not
     effects). 9/9 fixtures match.
   - **Slice 3 (DONE):** records and refs — `record`-declared values as
     `VRecord` (create / `.field` access / `{ r | f = v }` update / `Point { x,
     y }` patterns; no constructor-field-order map needed since `record` types
     aren't in `ctor_field_order`), `VRef` + `Ref`/`set_ref` externs + `.value`
     read, and block-local rebinding (`let mut` / `x <- e` via `DoAssign`).
     11/11 fixtures match. (Named-field *data variant* constructors — the VCon
     `ctor_field_order` path + `EVariantUpdate` — stay deferred.)
   - **Slice 4a (DONE) — typeclass method dispatch (user-defined).** `VTypedImpl`
     (head-type tag, dispatch positions, args-seen) + a process-global ctor→type
     table (a top-level `Ref`, mirroring `lib/eval.ml`'s `ctor_to_type` Hashtbl)
     feeding `runtimeTypeTag`. `DInterface`/`DImpl` install: each impl method is
     tagged `VTypedImpl` and same-named methods coalesce into one `VMulti`, sorted
     most-specific-first by free-type-var count; interface **defaults** install
     untagged as a fallback. `apply` gained the `VMulti` arg-tag filter (only
     candidates at a dispatching slot are filtered; if all are filtered out the
     original set is kept) and a tag-preserving `VTypedImpl` arm. Dispatch
     positions come from `dispatchPositionsOf` walking each method's declared
     type for args mentioning the interface type param. Validated on
     self-contained interface/impl fixtures via the existing `prelude:false`
     oracle — 14/14 fixtures match (multi-method interfaces, recursive ADTs,
     default + override).
   - **Slice 4b (DONE) — prelude loading.** `selfhost/eval_prelude_main.mdk`
     prepends the parsed+desugared `core.mdk` (by path, like the marker/resolve
     stages) and evaluates the whole thing, so the eval runs **real
     prelude-using programs**: `Eq`/`Ord`/`Debug`/`Display`/`Num` methods and
     `deriving` all dispatch through `core.mdk`'s impls. Validated against
     `eval_probe --prelude` (`eval_program ~prelude:true`, the embedded prelude)
     — `test/eval_prelude_fixtures/` (3 fixtures: `debug`/`display` over builtin
     + nested types, `Eq`/`Ord` builtin + derived, numeric/combinators).
     Mechanisms added: **`VThunk`** lazy deferral of nullary top-level bindings
     (forced + memoised on first lookup, so point-free prelude defs can reference
     anything installed later, any order); point-free impl methods either deferred
     (`VThunk`, return-position) or **eta-expanded** (`\$eta => body $eta`,
     arg-dispatched, Phase-121 style); and the rest of the pure extern kernel
     (`debugStringLit`/`debugCharLit`, char predicates, bounds, `stringToFloat`).
   - **Still out of scope (untyped-path limits):** **return-position dispatch**
     that needs types — `empty`/`pure`/`minBound` with no discriminating arg stay
     a `VMulti`/error, exactly as the reference's untyped path does; matching the
     typed `=== EVAL ===` goldens for *those* programs would need the elaborated
     (typed + dict-passed) AST. Also still deferred: IO externs (`putStr` etc.) —
     the oracle compares a computed `main` value, not stdout.
   It can be developed against the **reference's** typed + dict-passed AST, so it
   does **not** require typecheck to be ported first; `dict_pass` is the small
   prerequisite for the method-dispatch slices.
6. 🚧 **Typecheck — IN PROGRESS (slice 1 of N).** The complexity engine,
   deliberately last: Hindley–Milner unification (union-find over mutable cells,
   occurs-check), interface/impl coherence, and the Phase-69/69.x dictionary-
   passing elaboration. **Validation bridge:** like eval, the engine is exercised
   WITHOUT the prelude — `check_program_no_prelude` (a `~prepend_prelude` flag
   gating the prelude prepend / impl seeding / registry check) is the oracle via
   `dev/tc_probe.exe`, and `test/typecheck_fixtures/` are self-contained. Because
   the `=== TYPES ===` rendering is `pp_scheme = pp_mono` (constraints dropped),
   the engine slice needs only the HM core, not the dict-passing layer.
   - **Slice 1 (DONE):** `selfhost/typecheck.mdk` + `typecheck_main.mdk` — the HM
     core: `Mono` (`Ref`-based union-find tyvars) / `Scheme = Forall ids mono`,
     level-based `generalize`/`instantiate`, `unify` (occurs-check + level
     adjust), `pp_mono` (matching the reference renderer — `a,b,c…` by
     appearance, `TApp`/`TFun` precedence parens), and `infer`/`inferPat` for
     literals, vars, application, lambdas, let (let-poly), let-groups, if,
     tuples, lists, annotations, ADT constructors (`DData` → ctor schemes), and
     match. 3/3 fixtures match (combinators, ADTs+patterns+recursion, let-poly).
   - **Slices 2–8 (DONE):** operators (by shape), type signatures, interface
     method schemes, records, effect-row annotation labels, externs, and finally
     **dependency-ordered SCC-merged letrec processing** — the prelude has
     forward references and mutual recursion throughout, so groups are
     type-checked in topological order (a callee generalized before its callers
     instantiate it) with cycles merged into one letrec group. With runtime.mdk's
     externs seeded into scope (not output, mirroring `initial_env`'s
     `Runtime.entries`), the self-hosted typechecker infers the **entire
     `core.mdk` prelude** (84/84 schemes) and matches **all 16 `=== TYPES ===`
     goldens** (full prelude + user program) byte-for-byte. The key correctness
     point: a signed binding reports its sig *unified with its body* generalized
     (so `sum : (Foldable t, Num a) => t a -> a` with body `fold (+) 0` reports
     the specialized `a Int -> Int`), not the raw sig.
   - **Not needed for `=== TYPES ===` (constraints aren't rendered):** the
     constraint-solving / coherence / dict-passing machinery. It IS needed for a
     complete self-hosted *elaboration* (mark → typecheck → dict_pass → eval), but
     the type-scheme output the goldens check is constraint-free.
   - **Genuine remaining limits** (don't surface in the goldens): inferred effect
     *propagation* (an unsigned function calling an effectful extern), and the
     "signature too general" error.

**Ordering rationale.** Easy-first builds momentum and reuses the existing
harness while Medaka fluency matures, leaving the type checker for last. Note the
dependency wrinkle: a *complete* self-hosted pipeline also needs `dict_pass`
(small), and the reference's `Elaborate` two-pass orchestration (mark →
typecheck → re-mark → re-typecheck → dict_pass) must be mirrored once both ends
exist.

**End state of Stage 1.** A Medaka-written front-end
(lex → parse → desugar → resolve → mark → typecheck → exhaust) plus the
interpreter (eval), all running on the existing OCaml interpreter and validated
stage-by-stage against the reference — at which point the self-hosted compiler
can process its own source (the bootstrap). Stage 2 (the LLVM backend) follows;
see **North star → Stage 2** in `../PLAN.md`.

---

## Where we are now (all eight stages done) + what's next

All eight stages have validated self-hosted ports matching the OCaml reference
byte-for-byte, plus two integration milestones beyond per-stage validation:

- **Composed front-end** — `selfhost/check.mdk` wires parse → desugar → resolve →
  exhaust → typecheck into one program (`test/diff_selfhost_check.sh`: reproduces
  all 16 `=== TYPES ===` goldens *and* the 9 resolve diagnostics).
- **True execution** — `selfhost/eval_run_main.mdk` runs programs for their stdout
  (output captured to a buffer), matching all 16 `=== EVAL ===` goldens
  (`test/diff_selfhost_eval_run.sh`).
- **Typed eval path (return-position dispatch / RKey)** —
  `selfhost/eval_typed_main.mdk` threads desugar → `typecheck.elaborate` → eval on
  one shared tree, so `pure`/`empty`/do-blocks in a user monad dispatch by their
  concrete return type (`test/diff_selfhost_eval_typed.sh`, oracle = `medaka run`).
  This is the *only* part of dictionary-passing the compiler needs — see below.

### Next: the bootstrap (#3) — "the compiler processes its own source"

The decisive self-hosting milestone. The `box_do` fixture already proves the
exact pattern the parser uses (a user monad with `pure` + do-blocks dispatching
by return type via RKey), so the remaining work is *not* more dispatch machinery
— it's the integration to run the self-hosted compiler on the `selfhost/*.mdk`
sources themselves. Concretely, in rough order:

1. **Multi-module support.** The compiler is many modules with `import`s;
   typecheck/eval currently take a single flat program. Need the loader /
   module-scoping the reference has (`typecheck_module` + the loader's per-module
   frames). The diagnostic stages (desugar/mark/resolve/exhaust) already self-
   process via their corpora, but the typed pipeline does not yet.
2. **Cross-module name clashes.** Same-named *exported* data types collide because
   the loader installs constructors globally — we already hit this once
   (`resolve.Env` vs `typecheck.Env` → renamed to `TcEnv`; `applied non-function:
   Env [...]`). The selfhost modules will surface more; rename or scope them.
3. **`infer` / eval gaps the real modules expose.** The diff-fixtures are small;
   `list.mdk` already forced adding `EArrayLit`/range/index/slice `infer` arms.
   Running the full selfhost source will surface more unhandled `Expr`/`Pat`
   forms (e.g. Array indexing on a non-`List` container — `inferIndex` currently
   assumes `List`), `EStringInterp` residue, etc. Add them as they appear.
4. **Validation target.** Run a selfhost stage's output (e.g. the self-hosted
   parser parsing a `.mdk`) through the self-hosted pipeline and diff against the
   reference doing the same — the "it parses/checks/runs itself" diff.

### Deliberately NOT needed (scoped out by the scout)

The compiler uses **only RKey** return-position dispatch (every site is at a
concrete type — the `Parser` monad, no polymorphic-monad code, no `=>`
constraints in the selfhost source). So the full dictionary-passing system —
`RDict`, dict params, `EDictApp`, `VDict`, the `dict_pass` param-insertion
transform, the two-pass `Elaborate` — is **not** required for the bootstrap. It
*would* be needed for (a) running arbitrary user programs that *do* use
polymorphic-monad code, and (b) the LLVM backend (Stage 2), which consumes the
fully-elaborated AST. Treat it as an LLVM-era / generality task, not a
self-hosting one.

### Known limits carried forward (don't block the bootstrap)

- **Inferred effect propagation** — an unsigned function calling an effectful
  extern doesn't pick up its effect (the typecheck effect rows are
  annotation-only; full open-row inference is unported). Invisible in the
  `=== TYPES ===` goldens.
- **"Signature too general"** is not reported as an error (signed bindings report
  sig-unified-with-body, generalized).
- **Performance** — the interpreter is slow (each run re-parses core/list); the
  lexical-addressing + hash-set perf hooks under *Performance* below are the fix.

### Performance — what to bake into these phases (so we don't forget)

LLVM (Stage 2) raises the ceiling, but the current tree-walker has large,
backend-independent wins available *first*. Most of these should wait until the
pipeline exists and can be profiled — **measure before optimizing**: the
self-hosted compiler is itself the best benchmark (a big, realistic, hot
workload we control), so the prerequisite is cheap observability (per-phase
timing + an allocation counter) to attribute where the time actually goes,
rather than guessing. With that caveat, two items are cheap *now* and expensive
to retrofit, so design them into the initial phases:

- **Lexical addressing — reserve the variable-slot hook in resolve + the Core
  IR (do during stage 2 / IR design).** Today `eval`'s environment is
  `(string * value ref) list list`, so every `EVar` is a linear scan with string
  compares — likely the single hottest cost in the interpreter. The fix is to
  resolve each variable to a `(frame, slot)` index and use array frames for O(1)
  lookup. The first interpreter need not *use* the slot, but resolve should
  *emit* it; adding the field later means re-touching every binding site.
- **A real string builder in the stdlib (do early — we pay for it daily).** The
  lexer, `sexp.mdk`, and the formatter all build strings via left-fold
  `acc ++ charToStr c`. If `++` is copy-based (almost certainly — verify), that's
  O(n²). A mutable byte/char buffer with amortized-O(1) `append` + a single
  `freeze` to `String` (the `mut_array` pattern) fixes it. Backend-independent,
  and the self-host's own lexer/formatter are the immediate beneficiaries.

Recorded for later, **not** initial-phase work (revisit once the front-end is
profilable):

- **Bytecode VM as a "Stage 1.5"** between the tree-walker and LLVM — removes
  per-node AST re-dispatch, gets lexical addressing for free, and its Core IR is
  largely the IR LLVM wants (so it's an on-ramp, not throwaway).
- **Decision-tree pattern-match compilation** (drive it from the same Maranget
  analysis used for exhaustiveness) — tests each scrutinee field once instead of
  re-checking per clause; the parser/lexer are match-heavy, so this helps the
  self-host directly.
- **Static typeclass dispatch** — confirm `EMethodRef` routes resolved at
  elaboration aren't re-searched at runtime in `VMulti`; full monomorphization is
  an LLVM-era concern.
- **Stdlib hygiene** — prefer `Array`/`mut_array` over `List` in hot paths, keep
  common ops tail-recursive, and cache the elaborated+evaluated prelude so the
  many small runs (doctests, test suite) don't re-install it each time.

## Self-host-surfaced compiler fix

**Phase 134 (fixed).** Porting the lexer surfaced a real bug: an `<IO>`-returning
**helper** called from a `match` arm produced no output (clean exit) while the
same logic **inlined** ran correctly. Root cause was *not* the eval driver but
cross-module dict-passing: a private, then-`Num`-constrained 8-arg `emit` in
`lexer.mdk` made `Eval.eval_modules` (which dict-passed the whole program
*jointly*, keying dict-arity by bare name) prepend spurious dict parameters to any
same-named function in another module. `lex_main.mdk`'s unconstrained `emit`
helper then got under-applied, returning a partial closure that was never run.
Fixed by scoping each module's dict-arity table to the references that can resolve
to its own definitions (own decls + transitive importers); the regression is
guarded by `test_loader` (which supplies a genuinely-constrained same-named
sibling). `lex_main.mdk` now uses the clean helper form. (The lexer's `emit` has
since gained a concrete `Int` signature, so it no longer collides on its own.)
