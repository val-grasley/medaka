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
| `medaka.toml` | Project config (import root). |

The OCaml-side validation references live in `dev/`: `lextok.exe` (token-stream
dumper) and `astdump.exe` (canonical AST S-expression dumper).

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

Lexer and parser are done. The rest of the reference pipeline
(`desugar → resolve → method_marker → typecheck (runs exhaust) → eval`) is still
OCaml-only. This section sketches how to port it.

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
| 1 | **desugar** | ~980 | low–med | `program → program` | astdump (`--desugar`) over whole corpus |
| 2 | **resolve** | ~1000 | med | `program → diagnostics` (+ name env) | diff error list; needs negative fixtures |
| 3 | **method_marker** | ~420 | low | `program → program` (marks `EMethodRef`/`EDictApp`) | astdump (render marker nodes) |
| 4 | **exhaust** | ~465 | hard (algorithm) | `program → warnings` | diff warning list; needs (non-)exhaustive fixtures |
| 5 | **eval** | ~2350 | hard (plumbing) | `program → values` | diff stdout vs `=== EVAL ===` |
| 6 | **typecheck** | ~4650 | **very hard** | `program → schemes` | diff vs `=== TYPES ===` |

1. **Desugar** — the natural next step. Pure surface→core rewrites (list
   comprehensions → folds, `do` → `andThen`/`pure`, string interp → concat,
   sections, guards, record puns). Same AST in/out, so it reuses the parser's
   *entire* validation harness. Gotcha: the 8 passes run in a fixed order, and
   the `do`-block lowering is the one fiddly bit.
2. **Resolve** — name binding, scope, and visibility checks; output is a
   diagnostic list plus a name environment (hashtables, not directly dumpable).
   Dense mutable-env plumbing; multi-module import/alias resolution is the hard
   part. Reuses `loader` concepts.
3. **Method_marker** — rewrites interface-method / constrained-fn `EVar`s to
   `EMethodRef`/`EDictApp` (refs left unfilled for typecheck). AST→AST, dumpable.
   The prelude-shadowing name-set logic is the bulk.
4. **Exhaust** — Maranget pattern-matrix for non-exhaustive `match`/guard
   warnings. The algorithm is language-agnostic; the work is a faithful port of
   the matrix operations. Independently testable, so it can slot in any time.
5. **Eval** — the **Stage-1 capstone**: a tree-walk interpreter that makes the
   self-hosted compiler *executable on itself*. Plumbing-heavy (per-frame env
   refs, `VMulti` typeclass dispatch, lazy-thunk forcing, dict-passing
   semantics) but not algorithmically deep. Prerequisite sub-task: port the small
   `dict_pass`. It can be developed against the **reference's** typed +
   dict-passed AST, so it does **not** require typecheck to be ported first.
6. **Typecheck** — the complexity engine, deliberately last: Hindley–Milner
   unification (union-find over mutable cells, occurs-check), interface/impl
   coherence + overlap rules, and the Phase-69/69.x method-routing &
   dictionary-passing elaboration, plus two-pass promotion. Port incrementally
   (literals → lambdas → let-polymorphism → ADTs → interfaces → dict-passing),
   watching the `=== TYPES ===` match grow from a fixture subset outward.

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
