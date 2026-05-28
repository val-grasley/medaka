# Medaka — Next Steps Plan

This document is the working handoff between sessions. Read it before starting a
new task. Update it when you finish one.

## 1. Current status

The front-end of the Medaka compiler is in place. We have:

| Module          | File                | What it does                                                |
|-----------------|---------------------|-------------------------------------------------------------|
| AST             | `lib/ast.ml`        | Type definitions + a debug-friendly pretty printer          |
| Lexer           | `lib/lexer.mll`     | Indentation-sensitive tokens (INDENT/DEDENT/NEWLINE)        |
| Parser          | `lib/parser.mly`    | Menhir grammar, full language syntax                        |
| Printer         | `lib/printer.ml`    | AST → parseable source (used by round-trip tests)           |
| Resolver        | `lib/resolve.ml`    | Validates that every identifier reference is bound          |
| Type checker    | `lib/typecheck.ml`  | Hindley-Milner with let-polymorphism, ADTs, records, patterns, pipe/compose, effects |

Two debug binaries in `dev/` (not run as part of `dune test`):
- `debug.ml` — quick parse-and-print probe
- `tc_debug.ml` — quick type-check probe

879 tests pass across 15 base test suites:

| Suite             | File                            | Cases | Coverage                                              |
|-------------------|---------------------------------|-------|-------------------------------------------------------|
| Parser            | `test/test_parser.ml`           | 161   | AST shape for each construct                          |
| Round-trip        | `test/test_roundtrip.ml`        | 108   | parse → print → parse yields the same AST             |
| Resolver          | `test/test_resolve.ml`          | 60    | Unbound vars, unknown types/ctors, duplicates, fields |
| Type checker      | `test/test_typecheck.ml`        | 291   | Inferred types, type errors, exhaustiveness warnings  |
| Evaluator         | `test/test_eval.ml`             | 142   | Runtime values, recursion, do-blocks, Ref, errors, escapes, @Name dispatch |
| Run               | `test/test_run.ml`              | 6     | Stdout capture, factorial, ADT match, do-block, Ref, panic |
| REPL              | `test/test_repl.ml`             | 9     | process_item, :load atomicity, rollback, :browse      |
| Loader            | `test/test_loader.ml`           | 27    | Multi-file imports, topo sort, cycle detection, prelude no-op, abstract exports |
| Diagnostics       | `test/test_diagnostics.ml`      | 11    | LSP diagnostic output, multi-file analysis            |
| Formatter         | `test/test_fmt.ml`              | 10    | `medaka fmt` round-trip and --check mode              |
| Project config    | `test/test_project_config.ml`   | 15    | `medaka.toml` parse, workspace root discovery         |
| New command       | `test/test_new_cmd.ml`          | 4     | `medaka new` scaffold                                 |
| Doctests          | `test/test_doctest.ml`          | 15    | doctest extraction and execution                      |
| Snapshots         | `test/test_snapshot.ml`         | 6     | `assert_snapshot` create/compare/update               |
| Coverage          | `test/test_coverage.ml`         | 12    | `--coverage` instrumentation and reporting            |

A **thorough test suite** under `test/thorough/` (not run by default
`dune test`) exercises edge cases across the type checker, evaluator,
feature interactions, and stdlib.  Run with
`dune build @thorough` or invoke `./_build/default/test/thorough/thorough_*.exe`
directly.  Each file is its own alcotest executable; the shared
`Thorough_helpers` library provides `assert_type` / `assert_err` /
`assert_val` / `assert_runtime_err` / `assert_warns` / `assert_stdout`
following the same self-diagnosing pattern as the base suites
(failure messages embed the source).

| Suite          | File                                       | Cases |
|----------------|--------------------------------------------|-------|
| Typecheck      | `test/thorough/thorough_typecheck.ml`      | 107   |
| Evaluator      | `test/thorough/thorough_eval.ml`           | 145   |
| Interactions   | `test/thorough/thorough_interactions.ml`   | 49    |
| Stdlib         | `test/thorough/thorough_stdlib.ml`         | 92    |

393 thorough tests total.  Bugs surfaced and fixed during the
2026-05-26 / 2026-05-27 thorough-testing session are listed in §3
phases 45.5–45.14 — all ✅ DONE.  Phase 45.8's parenthesized-lambda
sub-case is a design limitation (not a TODO) with documented
workarounds inline there.

The source of truth for what the language *is* is `language-design.md`. Read it
before designing new features.

## 2. Working with this codebase — non-obvious things

### 2.1 Build / run commands

OCaml is installed via Homebrew and the toolchain lives in opam switch `5.4.1`.
Every shell command that touches `dune`, `ocaml`, or `menhir` must first
activate the environment:

```sh
eval $(opam env --switch=5.4.1) && dune build
```

A clean rebuild that surfaces grammar-conflict warnings:

```sh
eval $(opam env --switch=5.4.1) && rm -rf _build && dune build 2>&1 | tail -10
```

### 2.2 `dune test` hangs in this environment — run binaries directly

This is the single most important gotcha. `dune test` does not reliably return
when invoked via the harness; the test output appears but the command keeps
spinning. **Always run the test binary directly**, redirecting output to a file
so you can read it deterministically:

```sh
./_build/default/test/test_typecheck.exe --compact > /tmp/tc.out 2>&1
echo "exit=$?"
cat /tmp/tc.out
```

Same pattern for the other suites: `test_parser`, `test_roundtrip`,
`test_resolve`. The `--compact` flag shrinks pass output to dots.

### 2.3 Test failures must be self-diagnosing

`failwith "wrong"` is useless when a test fails because you can't tell what was
actually produced. Every test that asserts AST shape or types should embed both
the input and the actual output in its failure message. See the helpers in
`test/test_typecheck.ml` (`assert_type`, `assert_err`) and
`test/test_resolve.ml` (`assert_ok`, `assert_err`) for the established pattern:
pretty-print the actual result and include the source on failure.

When debugging a specific case, add a probe to `dev/tc_debug.ml` (or
`dev/debug.ml` for parser issues), build, and run that binary instead of
binary-searching through the test suite.

### 2.4 Grammar conflicts are silently resolved

Menhir reports 17 shift/reduce + 27 reduce/reduce conflicts. They are all
resolved in a way that passes the tests, but adding new grammar can change how
they resolve. **After any change to `lib/parser.mly`, check the conflict count
in a clean build** (see 2.1). If it goes up, audit which productions are
involved before declaring victory.

The `--explain` flag is already enabled (`(menhir ... (flags --explain))` in
`lib/dune`); when conflicts appear, `_build/default/lib/parser.conflicts`
explains them.

### 2.5 AST changes ripple

The AST is shared across `parser.mly`, `printer.ml`, `resolve.ml`, and
`typecheck.ml`. Adding a new variant means touching all four. The OCaml
exhaustiveness warning will catch you out at compile time for everything except
`printer.ml`'s `expr_prec` function (which uses a wildcard) — be careful there.

### 2.6 Round-trip tests are a contract

When you change the AST or printer, every existing round-trip test must still
pass. The contract is: `parse src → AST1`, `print AST1 → src'`,
`parse src' → AST2`, `AST1 = AST2` (structural equality via OCaml's `=`). The
printer can produce ugly output as long as it parses back to the same AST.

Structural `=` on `Ast.program` is fine because the AST has no mutable refs.
Don't introduce any without revisiting this contract — `[@@deriving eq]` would
become necessary the moment a field uses `ref` or similar.

### 2.7 OCaml argument evaluation order is unspecified

Bit me already in `pp_mono`. `Printf.sprintf "%s -> %s" (go a) (go b)` evaluated
right-to-left and named tyvars in the wrong order. Fix is always
`let sa = go a in let sb = go b in ...` when ordering matters (e.g., for
side-effecting numbering).

### 2.8 Indentation lexer: emit NEWLINE before each DEDENT

This is already in place but is non-obvious if you go to modify the lexer. When
dedenting N levels in one go, the lexer emits `NEWLINE; DEDENT; NEWLINE; DEDENT; …`
so that every enclosing block sees a NEWLINE terminator before its closing
DEDENT. Breaking this assumption breaks every block construct (match, do, data,
record, interface).

### 2.9 Type checker: declaration order matters

`typecheck.ml`'s `group_fundefs` preserves first-appearance order in source.
Don't switch to `Hashtbl.fold` — its order is unspecified, and we depend on
sequential processing so that earlier definitions are generalized before later
ones use them. If a later def's body references an earlier name, it should see
the generalized scheme.

Mutual recursion still works because all top-level names are pre-bound to
placeholder TVars at level 1 *before* processing begins. The forward reference
unifies with the placeholder; when the forward-referenced def is processed, its
placeholder is already pinned to a concrete shape.

### 2.10 Type checker: levels

The type checker uses Rémy-style level-based generalization. The rule:

- `enter_level` before typing the RHS of a binding
- `exit_level` after
- `generalize` only quantifies vars whose level is **strictly greater** than
  the current level after exit

Every `fresh_var ()` uses the current level. If you forget `enter_level`, vars
end up at the wrong level and either don't generalize when they should, or
escape to outer scopes.

### 2.11 Constructor patterns: `pat` vs `pat_atom`

Match arms, let bindings, and do binds use the full `pat` rule, which allows
unparenthesized constructor application (`Some x => ...`). Function arguments
use the tighter `pat_atom` rule, which requires parens: `unwrap (Some x) = x`.
This is the standard Haskell/OCaml convention — keep it.

### 2.12 Toolchain quirks

- `git commit` should not include `Co-Authored-By` lines (user preference).
- `gh` is fine to use if you need GitHub.
- Don't add emojis to files unless asked.

## 3. Roadmap

Items are ordered by what makes the next session most productive, not strictly
by importance. Each item below is independently achievable in a session-sized
chunk; pick one, do it well, write tests, commit, update this doc.

**For the current arc (stdlib enablement), see §6 — the work after Phase 12
is grouped there because Phases 1–12 are all DONE.**

### Phase 1: Records ✅ DONE

Implemented in commit `83b8a3d`. Field access, record creation, and record
update all type-check correctly, including polymorphic records.

**Key implementation detail.** `register_record` must call `exit_level()` BEFORE
`free_unbound []` so the param TVars (at level 1) satisfy `level > 0` and get
included in `rec_params`. This makes `instantiate_record` create fresh TVars on
each call — without it, all uses of a polymorphic record share the same TVar
refs and spuriously unify.

**What was added:**
- `record_info` type in `typecheck.ml`; `records`/`field_owners` in `env`
- `register_record` and `instantiate_record` helpers
- `ERecordCreate`, `EFieldAccess`, `ERecordUpdate` cases in `infer`
- `UnknownRecord`, `UnknownField`, `MissingField` error variants
- Resolver: `field_owners` map, `UnknownField`, `FieldNotInRecord` errors;
  validates field membership in `ERecordCreate` / `ERecordUpdate`
- 18 new tests (14 typecheck, 4 resolver)

### Phase 2: `do` notation typing ✅ DONE

Implemented in the commit following Phase 1.

**What was added:**
- `EDo` case in `infer` (approach b): per-block monad tyvar `m`; each
  `DoBind(pat, e)` unifies `e` with `TApp(m, inner)` and binds `pat : inner`;
  each `DoExpr e` unifies `e` with `TApp(m, _)` (discards inner); `DoLet`
  introduces a plain let-polymorphic binding inside the block; last statement
  determines the block's result type.
- `pure` in `initial_env` corrected to `forall m a. a -> m a` (was `a -> a`),
  achieved by wrapping fresh-var creation in `enter_level/exit_level` so the
  vars get properly quantified.
- 13 new typecheck tests (10 valid, 3 errors).

**Key design note — parser constraint.** The Menhir grammar has a
shift/reduce conflict for `stmt: pat LARROW ... | expr_no_block newlines`. When
a `DoExpr` stmt starts with an uppercase identifier (`UPPER`), the parser tries
it as a pattern, causing a parse error. Consequence: the last statement of a do
block should not be `Some x`, `Ok x`, etc. — use `pure (...)` instead. This is
a cosmetic restriction, not a fundamental one; fixing it requires a grammar
change (Phase 7 or earlier).

**Limitation.** Without real `Monad` interface instances, the monad tyvar
stays abstract (`'a 'b -> 'a 'b` rather than `Option Int -> Option Int`) unless
a specific constructor like `Some 10` or `Ok x` appears in a `DoBind` and
forces it. Full resolution awaits Phase 4 (interfaces).

### Phase 2.5: Pipe and composition operators ✅ DONE

Added in response to `language-design.md` explicitly specifying `|>`, `>>`, `<<` (see "Pipe and Composition Operators" section). These were absent from the previous roadmap.

**What was added:**
- Lexer tokens: `PIPE_RIGHT` (`|>`), `RCOMPOSE` (`>>`), `LCOMPOSE` (`<<`)
- Parser: two new precedence levels (`expr_pipe` below `expr_compose` below `expr_or`); `|>` is left-associative and lowest; `>>` and `<<` are left-associative and just above `|>`
- Printer: `prec_pipe` and `prec_compose` constants (renumbered existing levels to make room); `binop_prec` extended
- Type checker: `binop_type` cases:
  - `|>` : `a -> (a -> b) -> b`
  - `>>` : `(a -> b) -> (b -> c) -> (a -> c)`
  - `<<` : `(b -> c) -> (a -> b) -> (a -> c)`
- 6 new parser tests, 9 new typecheck tests

### Phase 3: Effect tracking ✅ DONE

**Goal.** Currently `from_ast_type` ignores effect annotations
(`<IO> String` is treated as just `String`). The language wants effects in
signatures and inferred automatically (see `language-design.md` §Effect System).

**Design decisions.**

1. Represent effects as a set of strings (`IO`, `Mut`, `Async`, `Panic`, `Rand`,
   `Time`).
2. Extend function types: `TFun of mono * effect_set * mono` (arg → effects →
   result). Pure functions have empty effect sets.
3. Effects propagate: applying a function adds its effects to the caller's.
4. Top-level functions are pure unless they call something effectful.
5. Annotated effect signatures constrain — code that escapes the declared
   effects is a type error.

**Implementation chose the alternative (separate pass).** `TFun` is unchanged;
effects are tracked in a separate `eff_env : (string, effect_set) Hashtbl.t`
that is populated after HM type checking.

**What was added:**
- `type effect_set = string list` (sorted, dedup)
- `type_error` variants: `ImpureFunction (name, effs)` and `EffectEscape (name, declared, extras)`
- `declared_effects : Ast.ty -> effect_set` — extracts effect annotation from a type sig
- `expr_effects` / `do_stmt_effects` — computes the effects of evaluating an expression
  (direct `EApp(EVar f, ...)` calls contribute `eff_env[f]`; `|>` pipes correctly;
  `>>` / `<<` compositions include effects of both sides; lambda bodies propagate)
- `infer_and_check_effects groups` — builds eff_env in declaration order; checks
  each function against its declared effects (or enforces purity when unannotated)
- Primitives in eff_env: `"print" → ["IO"]`
- 10 new typecheck tests (6 valid, 4 error cases)

**Known limitation.** Higher-order functions that receive effectful callbacks are
not tracked: `bad = runWith print` where `runWith` ignores effects in its
parameter type won't be flagged. Full tracking requires integrating effects into
`TFun` (the original "big call" path), which can be done in a future pass.

### Phase 4.1: Interfaces (typeclasses) ✅ DONE

**Goal.** Type-check `interface` and `impl` declarations; expose interface
methods as polymorphic bindings in the env.

**What was added (commit `b5845ac`).**
- `iface_info` type in `typecheck.ml`; `interfaces` hashtbl in `env`
- `register_interface` — creates fresh tvars per type param, builds method
  schemes with per-call memoization for method-level tvars (fixes HKT like
  `(a -> b) -> f a -> f b`); stores `iface_defaults` for optional methods
- `instantiate_with` — directed instantiation mapping bound IDs to concrete monos
- `check_impl` — validates each impl method body against the instantiated interface
  type; catches `UnknownInterface`, `MissingMethod`, `ExtraMethod`,
  `MethodTypeMismatch`, `ImplArityMismatch`
- `check_program` Phase 1.5: register interfaces, bind method schemes in env
- `check_program` Phase 4.5: validate all DImpl bodies
- `@Name` annotations (parsed as `EVar "@Name"`) type-check as `Unit`
- `resolve.ml`: `iface_methods` table; DImpl checks interface existence and
  method membership; `UnknownInterface` + `MethodNotInInterface` errors
- 15 new typecheck tests (10 valid, 5 error cases); 231 total

**Known limitations (Phase 4.2).**
- No constraint checking at call sites: `eq 1.0 2.0` succeeds even if no
  `Eq Float` impl exists (full constraint solving deferred)
- Superinterface constraints (`of Monoid Int`) stored in AST, not validated
- `@Name` disambiguation doesn't select a specific impl yet
- Named impl names must be lowercase (parser uses `IDENT`; fix in Phase 7)

### Phase 4.2: Interfaces — constraint solving at call sites ✅ DONE

**Goal.** At each method call site, verify that a valid impl exists for the
inferred argument types. Handle the `@Name` disambiguation hint properly.

**What was added (this session).**
- `impl_entry` type in `typecheck.ml`; `method_iface`, `impls`, `method_usages`
  fields added to `env`
- `register_impl` — populates `env.impls` from `DImpl` declarations in Phase 1
- `register_interface` now also populates `env.method_iface` (method → iface map)
- `instantiate_method` — variant of `instantiate` that returns the fresh TVar
  refs corresponding to the interface's type params, so call sites are trackable
- Modified `EVar` in `infer`: method variables use `instantiate_method` and
  record `(method_name, param_var_refs)` in `env.method_usages`
- `EApp` special case: `EApp(f, EVar "@X")` where `@X` starts with `@` silently
  drops the hint argument (no Unit arg consumed), so `eq @EqInt 1 2` type-checks
- `mono_matches` — one-directional structural matching; impl pattern may have
  unbound TVars that act as wildcards (handles `impl Show (Option a)`)
- `check_method_usages` — post-HM pass (Phase 4.6) that walks all recorded
  usages; skips polymorphic / underconstrained calls; raises `NoImplFound` or
  `AmbiguousImpl` otherwise
- `NoImplFound (iface, concrete_args)` and `AmbiguousImpl (iface, concrete_args)`
  error variants with `pp_error` cases
- 10 new tests (6 valid, 4 error); 241 total

**Known limitations.**
- `@Name` hints drop silently (no argument consumed, type unchanged) but do not
  yet *select* a specific impl. Full `@Name` selection deferred until Phase 7
  addresses the parser quirk (impl names forced lowercase via `IDENT`).
- Constraint checking is skipped when a method's scheme doesn't mention all
  interface type params (method doesn't constrain that param). Rare in practice.
- Higher-order callbacks that receive effectful/constrained functions aren't
  tracked (same limitation as Phase 3 effect tracking).

### Phase 5: Position-tracked errors ✅ DONE

**Goal.** Every error message now includes source positions and an Elm-style
snippet showing the relevant line with a caret.

**What was added (commit `86303fa`).**
- `type loc = { file; line; col }` in `ast.ml`
- `ELoc of loc * expr` ghost node — parser injects it at every `expr_atom`
  alternative and every block-expression form in `expr_lam` using `$startpos`
- Mutable `current_loc` ref in `typecheck.ml` and `resolve.ml`; updated in
  the `ELoc` case of `infer` / `check_expr`; carried in the `Type_error`
  exception and `(error * loc option)` accumulator
- `strip_locs_program` in `ast.ml` — used by parser tests and roundtrip tests
  so `ELoc` positions don't break structural AST equality checks
- `bin/main.ml` replaced stub with full pipeline: parse → resolve → typecheck,
  with Elm-style `file:line:col: message\n  |\nN | source\n  | ^` output
- `call_effs` in `typecheck.ml` updated to see through `ELoc` (effects pass)

**Output example.**
```
bad.mdk:1:14: Type mismatch: String vs Int
  |
1 | x = 5 + "hello"
  |               ^
```

All 241 tests still pass.

### Phase 6: Exhaustiveness and usefulness checking ✅ DONE

**Goal.** Warn when a `match` doesn't cover all cases; warn when an arm is
redundant.

**What was added (commit `0671015`).**
- `lib/exhaust.ml` — Maranget's pattern-matrix algorithm (2007): pattern
  desugaring (`PList`/`PCons` → Cons/Nil, `PLit LBool` → True/False,
  `PTuple` → `PCon("__tuple__", ...)`), `specialize_con`, `specialize_lit`,
  `default_matrix`, `useful` recursion, `check_match` public entry point
- `env.type_ctors` — new hashtbl mapping type name → ctor list; seeded for
  Bool/Option/Result/List/`__tuple__`; populated in `register_data`
- `env.warnings` — accumulated warning strings; returned by `check_program`
  as a second element `(bindings, warnings)`; printed to stderr by `bin/main.ml`
- `EMatch` case in `infer` calls `Exhaust.check_match` after arm typing, with
  callbacks for `get_ctors`/`get_arity`/`get_ctor_type` and `col0_type` derived
  from the scrutinee's inferred mono type (tuples map to `"__tuple__"`)
- 19 new typecheck tests (`assert_warns` / `assert_no_warns` helpers)
- **Bonus fix:** builtin constructors (`Some`, `None`, `Ok`, `Err`) were created
  at level 0 in `initial_env` and never properly quantified, causing all uses
  to share the same `TVar ref` and spuriously unify in nested patterns like
  `Some (Some v) | Some None | None`. Fixed by wrapping creation in
  `enter_level`/`exit_level` so vars land at level 1 and get quantified.

### Phase 7: Audit parser conflicts ✅ DONE

**Goal.** Document every conflict so that future grammar changes can't alter
resolutions silently.

**What was found (commit following Phase 6).**

The grammar has 4 S/R states (13 conflicts) and 5 R/R states (20 conflicts).
All default resolutions are correct.  A single block comment was added just
after the `%%` separator in `lib/parser.mly` documenting every conflict state:

| State | Type | Lookahead(s) | Resolution | Rationale |
|-------|------|-------------|------------|-----------|
| 108   | S/R  | LBRACE      | Shift      | `UPPER {…}` is always record creation |
| 134   | S/R  | LBRACKET    | Shift      | Indexing (`e[i]`) binds tighter than application |
| 138   | S/R  | 14 tokens   | Shift      | DoBind tried first; DoExpr starting with UPPER needs parens (known restriction) |
| 160   | S/R  | LBRACKET    | Shift      | Chained indexing `a[i][j]` must keep extending |
| 138/141/143/144/147 | R/R | CONS COMMA ) ] | Reduce expr_atom | expr_atom is earliest rule; DoBind cons-patterns (`x::xs <- list`) are an accepted limitation |

No `%prec` directives were added (all resolutions were already correct;
restructuring would risk new conflicts with no test coverage benefit).
260 tests still pass.

### Phase 8: Driver / CLI ✅ DONE

Implemented as part of Phase 5.  `bin/main.ml` already runs the full
pipeline — parse → resolve → type-check — with Elm-style error output
(file:line:col messages + source snippets).  Nothing left to do here.

### Phase 8.5: Mutation semantics and `Ref` ✅ DONE

**Goal.** Implement the mutability model from `language-design.md` §"Mutability and Passing Values".

**What was added (this session).**
- `DoAssign of ident * expr` variant added to `Ast.do_stmt`; printed as `x = e` in do-blocks
- `lib/parser.mly`: `IDENT EQUAL expr_no_block newlines` rule added to `stmt` before the `DoExpr` catch-all. Introduced 1 new R/R state (state 235 — same class as existing 141/143/144/147, resolved identically: reduce `expr_atom`). Conflict count updated to 4 S/R (13) + 6 R/R (21).
- `module StringSet = Set.Make(String)` and `mut_vars : StringSet.t` field added to `env`; populated when `ELet(true, PVar x, ...)` or `DoLet(true, PVar x, ...)` is processed
- `DoAssign(x, e)` in `type_stmts`: looks up `x`, unifies its type with `e`'s type, raises `ImmutableAssignment x` if `x ∉ env.mut_vars`; does not participate in the monadic `m` constraint; error if it is the last statement in a do-block
- `Ref` constructor in `initial_env`: type `forall a. a -> Ref a` (reuses `TApp(TCon "Ref", a)`)
- `set_ref` in `initial_env`: type `forall a. Ref a -> a -> Unit`, with `["Mut"]` in `eff_env`
- `EFieldAccess(e, "value")` special-cases `TApp(TCon "Ref", inner)` before the record lookup path, returning `inner`
- `ImmutableAssignment of ident` error variant and `pp_error` case
- `"Ref"` added to `primitive_types` and `primitive_values` in `resolve.ml`; `DoAssign` handled in `EDo` fold
- 15 new type checker tests (9 valid, 6 error); 275 tests total

**Design note.** `Ref T` is represented as `TApp(TCon "Ref", T)` — no new `mono` variant needed. The `.value` field reads through `Ref` without consuming a `<Mut>` effect (reads are pure); writes require calling `set_ref` which carries `<Mut>` through the existing effect-propagation pass. `let mut x` binding reassignment is tracked separately from `Ref` — `let mut x = 5` followed by `x = 10` in a do-block is a `DoAssign`, while `Ref` provides explicit shared mutable cells. Value/reference semantics documentation deferred to Phase 9 (eval pass).

### Phase 8.6: Housekeeping pass (before backend) ✅ DONE

Small, independent cleanups completed in one session before starting the
backend.

**What was added (this session).**
- `dev/` directory created; `test/debug.ml` and `test/tc_debug.ml` moved to
  `dev/debug.ml` and `dev/tc_debug.ml` with their own `dev/dune`
  (`executables` stanza). `test/dune` now only contains the `tests` stanza.
  Doc references updated.
- `.editorconfig` added at repo root: 2-space indent for OCaml sources and
  Markdown/YAML/JSON, tabs only for Makefile, LF endings, final newline,
  trim trailing whitespace.
- `lib/ast.ml`: `pp_ty` rewritten as a precedence-aware printer
  (`pp_ty_prec`). `List Int` now prints as `List Int` instead of
  `(List Int)`; arrows only get wrapped when they sit in an
  application argument or arrow-lhs position. Tests unaffected (none
  asserted on the old over-parenthesised form).
- README was already current — no edits needed beyond the layout block
  (moved `debug.ml` / `tc_debug.ml` under a new `dev/` heading).
- Stale test counts in PLAN.md §1 fixed: 260 → 275 total, 128 → 143 for
  the type-checker suite.
- `Eq`-deriving for AST: decided to keep structural `=`. `Ast.program` has
  no mutable refs; `TVar ref` lives in `typecheck.ml`'s `mono`, which
  round-trip tests never compare. Documented under PLAN.md §2.6 so the
  next session doesn't reopen it.

275 tests still pass; conflict count unchanged (4 S/R / 13, 6 R/R / 21).

Not in scope here (tracked in Section 5): polymorphic numeric/comparison
operators, higher-order effect tracking, `@Name` impl selection, cons-pattern
`DoBind`. These are revisited once the stdlib forces real use cases.
(`r.value = e` / `p.field = e` field assignment done in Phase 28; local `let-rec` done in Phase 27.)

### Phase 9: `extern` declarations ✅ DONE

See "Phase 9 onwards: Backend" below for the full write-up.

---

## Phase 9 onwards: Backend

**Overall goal.** Make Medaka programs actually run. Per the design doc, this
is Phase 1 of the project — a tree-walking interpreter over the typed AST.
Don't optimise; the goal is to validate the language design, not raw speed.

**Decisions baked into this roadmap.**
- Effects stay compile-time only. The interpreter does not enforce them at
  runtime; the type checker is the single source of truth.
- Single-file programs only. Cross-file `use` is parsed but rejected by the
  driver; multi-file resolution becomes its own phase later.
- Primitives are exposed via `extern` declarations from day one, not
  hard-coded in `eval.ml`. Establishes the runtime boundary the design doc
  promises (Runtime Primitives & Abstraction Layer).
- Runtime failures (pattern-match failure, division by zero, OOB, etc.) raise
  an OCaml exception that the driver catches and prints as a Medaka `Panic`
  with the source location of the failing expression (`ELoc`).
- Numeric/comparison op polymorphism (`Eq`/`Ord`/`Num` interfaces) is *not* a
  prerequisite. Built-in ops stay Int-only until the stdlib lands.

### Phase 9: `extern` declarations

**Goal.** Promote today's hard-coded primitives (`print`, `pure`, `Ref`,
`set_ref`, `map`, `filter`, `fold`, `pi`, `e`) into first-class `extern`
declarations. Establish the runtime-boundary the design doc calls for, so
later backend changes don't have to chase implicit primitives.

**Scope.**
- `extern name : ty` parses as a new top-level `decl` variant `DExtern`.
- Resolver: an `extern` declaration registers the name in scope just like a
  type-sig; it must not have an accompanying definition.
- Type checker: an extern's declared type becomes its scheme directly (no
  body to infer). Effects from the `<...>` annotation populate `eff_env`.
- A blessed `runtime.mdk` (or equivalent in-OCaml table) replaces the
  hand-rolled entries in `resolve.ml`'s `primitive_values` and
  `typecheck.ml`'s `initial_env`. The two lists become derived data.
- Tests: existing test programs continue to type-check; add a few exercising
  `extern` directly (effect propagation through an extern, unknown extern
  rejected, extern with body rejected).

**Done when.** No primitive value is referenced by string in `resolve.ml` or
`typecheck.ml` outside the runtime registry; all 275+ existing tests pass.

### Phase 10: Tree-walking interpreter (`lib/eval.ml`)

**Goal.** Evaluate any well-typed Medaka expression to a runtime value.
Programs that don't have side effects can be tested by asserting value
equality.

**Scope.**
- `type value` covering: integers, floats, strings, chars, bools, unit,
  closures, constructors (`VCon of ident * value list`), records,
  tuples, lists, arrays, `Ref` cells, primitive function thunks.
- `eval : env -> expr` over the typed AST. Pattern matching, let-binding,
  do-blocks (option/result/IO monad behaviours come from `extern` impls),
  records and field access, `Ref` reads via `.value`.
- Extern dispatch: an in-OCaml table mapping `extern` names → OCaml functions
  on `value`. Initially: `print`, `println`, `pure`, `Ref`, `set_ref`, arith
  helpers if needed beyond built-in ops, plus enough of `map`/`filter`/`fold`
  to satisfy current test programs.
- Runtime errors raise `Eval_error of string * Ast.loc option`; the
  outermost driver catches and prints them with the source snippet
  (`bin/main.ml`'s existing snippet helper).
- Tests: a new `test_eval.ml` suite that evaluates expressions and asserts
  on resulting `value`s. Tests cover constants, arithmetic, lambdas/closures,
  recursion (factorial, list length), pattern matching across `data`/`record`
  shapes, do-blocks with `Option`/`Result`, `Ref` mutation.

**Done when.** The evaluator can run every existing type-checked test program
to a value and the new `test_eval.ml` suite is green.

**What was added (commit `8d25560`).**
- `lib/eval.ml` — `type value` (14 variants), ref-cell env frames for mutual
  recursion, `match_pat`, `apply`, `eval`, `eval_do`, `eval_binop`,
  `eval_arith`, extern dispatch table, `eval_program`
- `True`/`False` map to `VBool true`/`VBool false`; `PCon("True",[])` /
  `PCon("False",[])` patterns special-cased in `match_pat` to match `VBool`
- do-block monad dispatch: runtime heuristic — inspects the first `DoBind`
  result shape to detect Option / Result / IO; `pure` consults a
  `current_monad` ref. See §5 Known limitations for the holes.
- `test/test_eval.ml` — 41 tests across 14 groups (336 total)

### Phase 11: Driver — running whole programs ✅ DONE

**Goal.** `medaka run file.mdk` actually executes a program.

**What was added.**
- `bin/main.ml` subcommand parsing: `medaka check file.mdk` (parse +
  resolve + typecheck only, prints "OK — N bindings"), `medaka run
  file.mdk` (full pipeline), `medaka file.mdk` (same as run).
- After a successful typecheck, `run` mode calls `Eval.eval_program`; all
  no-arg top-level bindings (including `main`) are evaluated eagerly in
  pass 2, so side effects happen during that call. The driver checks that
  `main` is present in the result and catches `Eval_error` for panic output.
- Runtime panics print `file:line:col: panic: <msg>` plus the source snippet
  using the existing `show_snippet` helper.
- `lib/eval.ml` gains `output_hook : (string -> unit) ref` (defaults to
  `print_string`); `print`/`println` primitives use it. Tests swap it to a
  `Buffer.add_string buf` to capture output without touching real stdout.
- Convention: `main` must be annotated `main : <IO> Unit` (or whatever effects
  it performs). It is subject to the same purity check as any other function.
- `test/test_run.ml` — 6 tests: hello world, factorial (recursion), ADT
  match, multi-print do-block, let-mut reassignment, non-exhaustive match panic.
- `test/dune` updated to include `test_run`.

### Phase 12: REPL ✓ DONE

**Goal.** Match the design doc's Phase 2: an interactive read-eval-print
loop. Forces clean incremental typechecking and evaluation.

**Scope.**
- `medaka repl` subcommand (separate binary or `bin/main.ml` mode).
- Per-line parse/resolve/typecheck/eval, with persistent env carried across
  inputs (vars, type schemes, constructors, interface info, eval bindings).
- Multi-line input handling: re-prompt while the parser reports an
  unexpected EOF (i.e. block not yet closed). Indentation-sensitive lexer
  needs a small driver that knows when input is complete.
- Top-level declarations (`x = ...`, `data ...`, `record ...`, `interface
  ...`, `impl ...`) update the persistent env. Bare expressions print their
  value and inferred type.
- `:type expr`, `:quit`, `:reset` meta-commands. Resist adding more.

**Done when.** The REPL can be used to incrementally develop a small program
end-to-end. No test suite is required initially beyond a smoke test.

---

## 6. Stdlib enablement track (next major arc)

The next goal — explicit from the user — is to get the language to the point
where the **standard library can be developed in Medaka itself**, without
agent assistance, as a stress test of the syntax and semantics.  Three
prerequisites must land before that's pleasant: a working module system, a
REPL that can load files, and a Tree-sitter grammar so editor highlighting
exists while writing those files.  Each phase below is independently
shippable; pick one per session.

### Phase 13: REPL `:load` (and reload) ✅ DONE

**Goal.** Be able to develop interactively against a real `.mdk` file —
edit in your editor, `:load file.mdk` (or `:r`) in the REPL to bring its
top-level definitions into scope.

**What was added (this session).**
- `Typecheck.copy_tc_env : env -> env` — deep-copies all hashtable fields in
  `env`; used for atomic snapshot/restore in `:load`
- `lib/repl.ml` (moved from `bin/repl.ml` into `medaka_lib` so the test suite
  can reach it; `bin/repl.ml` is now a one-line shim)
- `Repl.load_file` — snapshots all env state, parses the file, rejects `use`
  decls, processes declarations via the existing resolve/typecheck/eval pipeline,
  restores on any error
- `Repl.process_item` gains a `user_bindings` parameter and appends newly
  type-checked bindings to it; `:browse`/`:env` sorts and prints that list
- New meta-commands: `:load <path>`, `:reload`/`:r`, `:browse`/`:env`, `:t`
  alias for `:type`
- `test/test_repl.ml` — 9 tests covering process_item, load success,
  rollback on type error, use-decl rejection, missing file, :browse
- `test/dune` updated; `unix` library added for test harness

357 tests pass (342 previously + 9 new REPL + 6 typecheck + 2 parser that
were already passing with updated counts).

---

### Phase 14: Module system v1 — single-namespace cross-file `use` ✓ DONE

**Goal.** The smallest possible working module system: each file is a
module, imports work, privacy is enforced, no nested namespaces yet.  Just
enough to start splitting the eventual stdlib across files.

**Decisions baked in.**
- The compiler driver takes either (a) a single file (today's behavior,
  preserved) or (b) a "root" file plus a project root directory; it walks
  the dependency graph from the root, parsing each transitively-imported
  file.
- A file's module name is its path relative to the project root with `/`
  replaced by `.` and the `.mdk` extension dropped — `src/list/core.mdk`
  becomes module `list.core`.  No `module Foo where` header; the design
  doc explicitly forbids that.
- `pub` is required on every top-level item that should escape the
  module: `pub data`, `pub record`, `pub interface`, `pub impl`,
  `pub fn-def`, `pub extern`.  Type signatures (`f : ...`) implicitly
  inherit the publicness of their matching `f x = ...` def.
- Resolver and typechecker grow a `module_id` parameter; the resolver
  rejects references to private names from other modules.
- No circular dependency detection in this phase — the driver does a topo
  sort and raises `CyclicDependency` if the graph has a cycle.

**Scope.**
- Parser: extend `decl_list` so `pub` can prefix `data_decl`, `record_decl`,
  `iface_decl`, `impl_decl`, `extern_decl`, `type_sig`, `fun_def`.
- AST: every decl variant grows an `is_pub : bool` field (or a single
  `decl_visibility` wrapper).  Adjust printer / round-trip tests.
- `lib/loader.ml` (new): given a root path and a project root, return an
  ordered list of `(module_id, parsed_program)` with cycles rejected and
  `use` decls resolved to canonical module IDs.
- Resolver / typechecker: take a `module_id`; track which names came from
  which module; reject references to private names from outside.
- `use foo.bar` adds `bar` to the importing module's scope as a *value
  binding* whose scheme is the exported scheme from `foo`.  `use foo.{x,
  y}` works the same way; `use foo.*` brings every public name in.
  `use foo as F` binds `F` to the module so `F.x` field-access syntax
  reaches inside.
- `use foo` alone (no selectors, no alias) brings `foo` in qualified-only:
  references must be written `foo.x` and parse as `EFieldAccess (EVar
  "foo", "x")`.  The typechecker special-cases `EFieldAccess` on module
  identifiers to do the right lookup before falling back to the record path.
- Driver: `medaka check src/main.mdk` walks dependencies; `medaka run
  src/main.mdk` runs the resulting program.  Single-file invocation still
  works (no `use` decls allowed).
- Tests: `test/test_loader.ml` (new) covers happy path, cycle detection,
  privacy violation, missing module file, unknown export name.

**Done when.** A `tests/stdlib/list.mdk` defining `pub map` etc. can be
imported by `tests/stdlib/main.mdk` via `use list.{map}` and the resulting
program runs.

---

### Phase 16: Idris-style `export`/`import` module syntax ✅ DONE

**Goal.** Replace the Rust-inspired `pub`/`use` keywords with Idris-style
`export`/`import`, and add support for `export` as a standalone line
preceding a declaration.

**Motivation.** The standalone `export` form reads more naturally for
functional code where type signatures and definitions are separate
declarations:

```
export
toList : BTree a -> List a
toList Leaf = []
toList (Node l v r) = toList l ++ (v :: toList r)
```

Both inline (`export toList : ...`) and standalone (`export\ntoList : ...`)
forms are supported.  Re-exports use `export import path` on one line.

**Key design.**
- `pub` → `export`, `use` → `import`, `pub use` → `export import`
- Parser restructured: each declaration rule factored into an `inner_*`
  variant returning `bool -> decl`; the top-level `decl` rule handles
  `EXPORT newlines inner_decl_body` (standalone), `EXPORT inner_decl_body`
  (inline), and `EXPORT IMPORT path` (re-export).  No new LALR(1) conflicts.
- AST unchanged — the `is_pub : bool` flags remain as-is.
- Tree-sitter grammar updated with a shared `_export_marker` rule covering
  both the standalone and inline forms; `use_decl` renamed to `import_decl`.

**Done when.** All tests pass with the new keywords; `tests/stdlib/` uses
`export`/`import` and runs correctly.

---

### Phase 15: Tree-sitter grammar ✅

**Goal.** Honor the design doc's Phase 1 promise: a tree-sitter grammar
that gives syntax highlighting in editors that support it (VS Code via
`vscode-tree-sitter`, Neovim via `nvim-treesitter`, Helix natively, Zed
natively).  No type info needed — purely syntactic.

**Scope.**
- New top-level `tree-sitter/` directory with a `grammar.js`, generated
  parser, `queries/highlights.scm`, and a minimal `package.json`.
- Grammar mirrors `lib/parser.mly` as closely as is reasonable in
  tree-sitter's GLR variant.  Indentation handling uses an external
  scanner (`src/scanner.c`) — there are well-trodden references (Python,
  Haskell, Nim tree-sitters) to crib from.
- `queries/highlights.scm` distinguishes: keywords, type constructors
  (uppercase idents), value identifiers, operators, comments, strings,
  numbers, effect annotations, the `@ImplName` form.
- `README.md` in `tree-sitter/` documents how to test (`tree-sitter test`,
  `tree-sitter parse`) and how to install for each editor.
- A small corpus of test files exercises every construct so the grammar
  doesn't silently regress as the language grows.

**Done when.** `tree-sitter parse path/to/sample.mdk` succeeds on every
file in `tests/` and the user can install the grammar in their editor and
see syntactic highlighting on Medaka source.  This phase is independently
deliverable and does not block anything else; can be scheduled in parallel
with the other Phase 14/16/17 work if desired.

---

### Phase 16: Collection literal syntax + Char/string upgrades ✅ DONE

**Goal.** Give the stdlib enough surface syntax to define `Map`, `Set`,
`String`, and `Char` cleanly.

**What was added (this session).**
- `EMapLit of ident * (expr * expr) list` and `ESetLit of ident * expr list`
  added to `Ast.expr`; `pp_expr`, `strip_locs_expr` extended accordingly.
- Parser: `kv_or_e` rule (`expr_pipe FAT_ARROW expr_no_block | expr_no_block`);
  new `expr_atom` alternative `UPPER LBRACE separated_nonempty_list(COMMA, kv_or_e) RBRACE`
  that dispatches to `EMapLit`/`ESetLit` based on entry shape.  The UPPER
  name (`"Map"`, `"HashMap"`, `"Set"`, `"HashSet"`, etc.) is stored in the node.
  Conflict count: 3 S/R (12) + 7 R/R (23) — one new S/R (EQUAL lookahead,
  resolved shift→record) and one new R/R state (FAT_ARROW in kv_or_e vs
  lambda, resolved correctly by Menhir's default).  Both documented in
  `parser.mly`'s conflict audit block.
- Printer: `EMapLit`/`ESetLit` print as `Name { k => v, ... }` and
  `Name { e, ... }`; both classified as `prec_atom`.
- Resolver: `check_expr` recurses into kv pairs / element lists.
- Typechecker: `t_map k v = TApp(TApp(TCon "Map", k), v)` and
  `t_set e = TApp(TCon "Set", e)` helpers; `infer` cases unify all keys /
  values / elements to a single type variable; effects pass extended.
- Evaluator: `EMapLit`/`ESetLit` desugar to `VCon("Name.fromList", [VList ...])`;
  real implementation awaits the stdlib Map/Set modules.
- Lexer — Char: `'\'' [^ '\'']+ '\''` captures any UTF-8 byte sequence;
  `LChar` was already `string`.
- Lexer — String escapes: `\r`, `\0`, `\u{XXXX}` (Unicode codepoint via
  `Buffer.add_utf_8_uchar`) added to `read_string`.
- Lexer — Multiline strings: `strip_indent` helper strips common leading
  whitespace from strings that begin with `\n`; applied at string close.
- 24 new tests (14 parser, 3 round-trip, 7 typecheck).  381 total.

---

### Phase 17: Float / Bool / polymorphic ops ✅ DONE

**Goal.** Move arithmetic and comparison off the Int-only built-ins so
that stdlib code defining `Map`, `Float`, `Ord` etc. type-checks.

**What was added (this session).**
- `seed_builtin_interfaces env` in `typecheck.ml` — registers `Num` and
  `Ord` interfaces with synthetic witness methods (`__num__`, `__ord__`)
  and pushes built-in `impl_entry` records for `Int`/`Float` (Num) and
  `Int`/`Float`/`String`/`Char` (Ord).  Called from `check_program`,
  `typecheck_module`, and `make_repl_tc_env`.
- `binop_type` updated: `+`/`-`/`*`/`/` now create a fresh TVar `a`,
  unify both operands with `a`, and record `("__num__", [r])` in
  `env.method_usages` so `check_method_usages` verifies `Num a` exists;
  `<`/`>`/`<=`/`>=` do the same with `__ord__`; `%` stays Int-only.
- `eval_arith` extended with `VFloat` cases for `+`, `-`, `*`, `/`.
- Lexer: `%` token (`MOD`).
- Parser: `expr_mul MOD expr_unary` rule at `expr_mul` precedence.
  Conflict count unchanged: 3 S/R (12) + 7 R/R (23).
- 15 new tests (1 parser, 11 typecheck, 3 eval).  396 total.

**Key design note.** `==`/`!=` are unchanged — `unify tl tr` already
correctly accepts any two values of the same type. Adding an `Eq`
constraint was deferred because it would break list/tuple equality in
existing code until `impl Eq (List a)` etc. are registered.
`double x = x + x` now infers `a -> a` (polymorphic) instead of
`Int -> Int`.  Five existing tests were updated to reflect the new
inferred types.

---

### Phase 18: `runtime.mdk` and structured extern catalog ✅ DONE

**Goal.** Promote `lib/runtime.ml`'s primitive registry to a real
`runtime.mdk` file with `extern` declarations.

**What was added (this session).**
- `stdlib/runtime.mdk` (new) — 14 `extern` declarations (10 existing
  + `readLine`, `readFile`, `writeFile`, `exit`).  This is the
  authoritative source for all primitive type signatures.
- `gen/embed.ml` + `gen/dune` (new) — tiny helper binary that wraps a
  file's content as an OCaml quoted-string literal.
- `lib/dune` — added a dune rule that runs `gen/embed.exe` to generate
  `lib/stdlib_content.ml` (the embedded `runtime.mdk` string) at build
  time; added `stdlib_content` to the `medaka_lib` modules list.
- `lib/runtime.ml` — replaced the hardcoded `entries` list with a call
  to `Parser.program Lexer.token` on `Stdlib_content.runtime_mdk`.
  `names` is derived from parsed entries.  No primitive name appears as
  a string literal in this file; no OCaml `Ast.ty` constructors mirror
  the extern types.
- `lib/eval.ml` — added OCaml implementations for the four new externs
  (`readLine`, `readFile`, `writeFile`, `exit`) in the `primitives`
  dispatch list; added a startup completeness assertion that fails if
  any name from `Runtime.names` lacks an OCaml impl.
- `lib/parser.mly` — `inner_extern_decl` now accepts both `IDENT` and
  `UPPER` names, enabling `extern Ref : ...` (constructor-style externs).
  Conflict count unchanged: 3 S/R (12) + 7 R/R (23).
- `stdlib/README.md` (new) — documents the convention for adding new
  primitives.
- 4 new typecheck tests.  400 tests total.

**Design note — embedded string approach.** Rather than reading a file
at runtime (which requires path resolution for test binaries),
`stdlib/runtime.mdk` is embedded into the library at build time via a
generated `lib/stdlib_content.ml`.  The module dependency order
`Runtime → Parser → Lexer → Ast` has no cycle.  The `Lexer.reset()`
call in every test parser invocation keeps global indent-state clean.

---

### Phase 18.5: `deriving` — automatic interface instances ✅ DONE

**Goal.** Add Haskell-style `deriving (Eq, Show, Ord)` to `data` and `record`
declarations so the compiler generates `impl` nodes automatically.

**What was added.**
- `DData`/`DRecord` gain a `derives: ident list` field (5th tuple element).
  All pattern-match sites in `printer.ml`, `resolve.ml`, `typecheck.ml`,
  `eval.ml`, `repl.ml`, `dev/debug.ml`, and `test/test_parser.ml` updated.
- `lib/lexer.mll`: `DERIVING` keyword.
- `lib/parser.mly`: `deriving_clause` (block form — includes trailing `newlines`)
  and `inline_deriving` (inline form — no surrounding newlines); block data/record
  rules use `DEDENT newlines option(deriving_clause)`; inline data uses
  `option(inline_deriving) newlines`. Conflict count unchanged: 3 S/R (12) /
  7 R/R (23).
- `lib/desugar.ml` (new): `desugar_program` expands `DData`/`DRecord` with
  non-empty `derives` into the original decl (derives cleared) followed by
  generated `DImpl` nodes. Supports `Eq`, `Show`, and `Ord` for both data and
  record types. Generated `Eq` uses tuple pattern-match; `Show` builds strings
  with `++`; `Ord` uses lexicographic field comparison via nested `match`.
- `lib/dune`: `desugar` added to `medaka_lib` modules.
- Pipeline: `desugar_program` called in `bin/main.ml` (both single-file and
  multi-file paths) and in `lib/repl.ml` (`process_item` and `load_file`).
- `++` operator in typecheck.ml widened from `List a -> List a -> List a` to
  `a -> a -> a` so string concatenation in derived `show` type-checks.
- 7 new typecheck tests. 407 tests total.

---

### Phase 19: Begin the standard library

**Goal.** With Phases 13–18 in place you can start implementing the
stdlib in Medaka itself, interactively via the REPL, exactly as the
design doc envisions.  This phase is open-ended; the rough sequence is:

1. `core` module: `Option`, `Result`, the `Eq`/`Ord`/`Num`/`Show`
   interfaces, and instances for built-in types.
2. `list` module: every `Foldable`/`Mappable` operation on `List`.
3. `string` module: split / trim / join / contains / startsWith /
   endsWith / chars / bytes / slice / length (over grapheme clusters).
4. `array` module: random access, `map`/`filter`/`fold` via the same
   interfaces.
5. `map` and `set` modules: persistent tree maps/sets.
6. `mut_array`, `hash_map`, `hash_set`: mutable equivalents.
7. `io` module: `readFile`, `writeFile`, `readLine` wrappers.
8. `json` module: data type + parser + serializer.

Each module added forces a real exercise of the language — expect to
discover holes that turn into new bullets in §5 or new sub-phases.
Don't try to plan modules 4–8 in detail before module 1 is done; the
goalposts will move.

**Done when.** It's the user that decides when to stop. By the end of
the early stdlib work, the language design should feel stable enough to
move on to Phase 20+ (LSP / formatter / package tooling / multi-file
build artifacts).

---

### Phase 20: Constraint syntax in function type signatures ✅ DONE

**Goal.** Allow `f : Eq a => a -> a -> Bool` and `f : (Eq a, Ord b) => a -> b -> Bool` in type annotations and type-sig declarations. Unblocks the stdlib track — `elem`, `sort`, `maximum`, and all other constraint-polymorphic functions can now be expressed.

**What was added.**
- `TyConstrained of (ident * ty list) list * ty` variant added to `Ast.ty`; `pp_ty_prec` prints `Eq a => t` (single) or `(Eq a, Ord b) => t` (multiple)
- Parser: `desugar_constraint` helper in the prologue; `ty: ty_fun FAT_ARROW ty` rule interprets the LHS as a constraint list via semantic action. No new grammar conflicts — conflict count unchanged at 3 S/R (12) / 7 R/R (23)
- Printer: `TyConstrained` case in `print_type`
- Resolver: `check_type` validates constraint iface names against `env.interfaces`
- Typechecker:
  - `from_ast_type` strips `TyConstrained` (inner type only)
  - `from_ast_type_with_constraints` — like `from_ast_type` but extracts constraint entries using a shared TVar table so constraint type-variable names map to the same fresh TVar as in the body type
  - `instantiate_raw` — factored from `instantiate`, returns `(sub, mono)` so call sites can correlate bound IDs to fresh TVars
  - `env.fun_constraints` — per-function registry mapping bound type-var IDs to interface names; populated when a constrained type sig is processed
  - `env.constraint_obligations` — accumulated at `EVar` call sites when a constrained function is used
  - `check_constraint_obligations` — post-HM pass that verifies concrete constraint obligations against the impl registry (skips unbound TVars, correct for polymorphic call sites)
  - Called in all three check paths: `check_program`, `typecheck_module`, `check_repl_decl`
- 20 new tests (4 parser, 2 roundtrip, 2 resolver, 5 typecheck annotation tests + all prior tests still pass). **420 tests total.**

**Known limitations.**
- Constraint inference not implemented. Callers of a constrained function that use it polymorphically must carry their own explicit constraint annotation.
- Interface method members with extra constraints are not yet handled in `iface_member` type signatures.

---

### Phase 23: String interpolation ✅ DONE

**Goal.** `"Hello, \{name}!"` — embed expressions inside string literals. Familiar ergonomic win for formatting, logging, and template generation.

**Syntax chosen.** `\{expr}` — extends the existing `\n`/`\t`/`\u{}` escape model. No new delimiters, no prefix. Unescaped `{` is always literal. Closest precedent: Swift's `\(...)`.

**What was added.**
- `type interp_part = InterpStr of string | InterpExpr of expr` and `EStringInterp of interp_part list` in `lib/ast.ml` (mutual `type ... and ...` with `do_stmt` and `expr`). `pp_expr` and `strip_locs_expr` extended.
- `interp_depth : int ref` and `interp_buf : Buffer.t` globals in `lib/lexer.mll`; `reset()` clears both. New `'\\' '{'` rule in `read_string` emits `INTERP_OPEN` and sets `interp_depth := 1`. New `read_interp_continue` rule (mirrors `read_string` but emits `INTERP_MID`/`INTERP_END`). `{` and `}` rules in the main `read` rule track `interp_depth`; closing `}` at depth 1 calls `read_interp_continue`.
- Three new tokens `INTERP_OPEN/MID/END of string` in `lib/parser.mly`; `interp_string` and `interp_tail` grammar rules; `expr_atom` alternative.
- `EStringInterp` handled in `lib/printer.ml` (`prec_atom`; prints `"text\{expr}text"`), `lib/resolve.ml` (recurses into expression parts), `lib/typecheck.ml` (`infer`: each hole must be `String`; result is `String`; effects pass extended), `lib/eval.ml` (concatenates string parts with evaluated holes).
- 14 new tests (3 parser, 2 roundtrip, 2 resolver, 4 typecheck, 3 eval). **511 tests total.**

**Design note — explicit `show`.** Embedded expressions must be `String`; users write `\{show age}` rather than having the type checker auto-insert `show`. Consistent with Medaka's no-magic philosophy.

**Conflict count.** 5 S/R (14) + 7 R/R (23) — up from 3 S/R (12). The 2 new S/R states involve `AT` (`@`) lookahead in do-block and REPL expression contexts, introduced by as-patterns (`PAs`). Resolutions are identical to the existing class of S/R conflicts (shift wins); documented in `parser.mly`.

---

### Phase 21: List comprehensions ✅ DONE

**Goal.** Haskell-style list comprehensions: `[expr | x <- xs, guard, let p = e]`.

**What was added.**
- `lc_qual` variant added to `Ast.expr` (`LCGen`, `LCGuard`, `LCLet`) and
  `EListComp of expr * lc_qual list` ghost expression node.
- Parser: `lc_qual` rule plus an `expr_atom` alternative
  `LBRACKET expr_no_block PIPE separated_nonempty_list(COMMA, lc_qual) RBRACKET`.
- Desugar (`lib/desugar.ml`): `desugar_list_comp` lowers each comprehension to
  nested `andThen` calls + `if` guards + `let`s, ending in `[body]`.  This
  makes the comprehension work over any `Thenable` (List in practice).
- The earlier compiler-side `filter` extern was removed; `filter` now lives
  in `stdlib/core.mdk` since it composes cleanly with the comprehension
  desugaring.

---

### Phase 22: Semigroup / Monoid in stdlib ✅ DONE

**Goal.** Make the `++` operator dispatch through `Semigroup.append` and
provide `Monoid` for ergonomic identity-element use.

**What was added.**
- `interface Semigroup a` and `interface Monoid a requires Semigroup a` in
  `stdlib/core.mdk`, with built-in impls for `List` and `String`.
- `Builtins.operator_iface` extended to map `++` → `Semigroup.append`; the
  typechecker emits a constraint and dispatches through the impl method.
- `eval_arith`'s `++` case falls back to `apply (lookup "append") l r` when
  the operands aren't `List` / `String`, so the operator works for any
  user-defined `Semigroup` impl.

---

### Stdlib wiring (Steps 1–5) ✅ DONE

**Goal.** Replace compiler-side primitive seeding with type-driven dispatch
through `stdlib/core.mdk`.  Every operator, monad bind, and built-in
constructor now flows through interface methods declared in core.mdk.

**What was added (commits `18129df`, `da06513`, `9e5db2e`, `e4bd5d1`, `03d6634`).**
- **Step 1.** `lib/prelude.ml` parses `stdlib/core.mdk` once and the result
  is prepended to every user program in `check_program`, `typecheck_module`,
  and `eval_program`.  A unique-marker detector (`program_is_core`) skips
  the prepending when the program is core itself.
- **Step 2.** `lib/builtins.ml` central registry: each operator (`+`, `-`,
  `*`, `/`, `<`, `>`, `<=`, `>=`, `++`) maps to `(iface, method)` and the
  typechecker emits a method-usage record so `check_method_usages` validates
  it against `env.impls`.
- **Step 3.** Do-block `<-` dispatches through `Thenable.andThen` (the
  evaluator looks the method up by name in `env`).  The `Thenable` impl
  bodies in `core.mdk` handle short-circuiting per monad.
- **Step 4.** Compiler-side seeding for `Some`/`None`/`Ok`/`Err`/etc. and
  for `Int`/`Float` were retired — the prelude declarations fill those
  schemes via the same registration pipeline as user `data` decls.
- **Step 5.** `pure` and `map` reconciled.  `pure` stays a primitive that
  consults `pure_impls` (populated from `impl Applicative T` bodies) to
  pick the right wrap; `map` is purely an interface method dispatched
  via VMulti.

---

### Phase 24: Left operator sections ✅ DONE

**Goal.** Support `(2 * _)` / `(3 - _)` / `(0 < _)` left sections that desugar
to lambdas, complementing the existing right sections `(+1)`.

**Syntax.** `(e op _)` desugars at parse time to `\x -> e op x`.  The `_`
placeholder makes the form unambiguous in LALR(1): `2 * _` is a complete
expression `EBinOp("*", 2, EVar "_")`, and the semantic action on
`LPAREN expr_no_block RPAREN` converts it to `ELam([PVar "_s"], EBinOp("*", 2, EVar "_s"))`.
MINUS works too: `(3 - _)` = `\x -> 3 - x`.

**Why not `(2*)` Haskell style.** After `LPAREN expr_app .` with a binary
operator lookahead, LALR(1) cannot distinguish a left section from a binary
expression inside parens (requires 2-token lookahead).  The explicit `_`
placeholder is the unambiguous alternative.

**What was added.**
- `lib/parser.mly`: `UNDERSCORE` added as `expr_atom` → `EVar "_"`.
  Semantic action on `LPAREN expr_no_block RPAREN` checks if the inner
  expression is `EBinOp(op, lhs, EVar "_")` (after stripping ELoc wrappers)
  and rewrites to `ELam([PVar "_s"], EBinOp(op, lhs, EVar "_s"))`.
- Conflict count updated to 7 S/R (17) + 8 R/R (27); 4 new S/R states and
  1 new R/R state, all from UNDERSCORE being valid as both `pat_atom` and
  `expr_atom`. All new resolutions are correct (documented in audit block).
- 3 new parser tests, 1 roundtrip test, 5 typecheck tests, 3 eval tests.
  **523 tests total.**

---

### Phase 25: Where clauses ✅ DONE

**Goal.** Allow Haskell-style `where` clauses on top-level `fun_def` and
on `match`-arm bodies, so locally-scoped helpers can sit beneath the main
expression rather than living above it as `let ... in`.

**What was done:**

- Added `ELetGroup of (ident * expr) list * expr` to the AST for mutually-recursive where groups.
- Changed `desugar_where` in `parser.mly` to produce `ELetGroup` instead of nested `ELet`s.
- Added a second `match_arm` alternative supporting `expr_no_block WHERE INDENT where_bindings DEDENT newlines`.
- Added `ELetGroup` evaluation in `eval.ml` using the two-pass forward-reference trick (same as top-level mutual recursion).
- Added `ELetGroup` type-checking in `typecheck.ml` using placeholder + generalize approach.
- Propagated `ELetGroup` through `desugar.ml`, `printer.ml`, `resolve.ml`, and `ast.ml`'s effects pass and strip_locs.
- Added tests: mutual recursion in where blocks, where clause on match arm bodies, polymorphic where helpers, type error detection.

---

### Phase 26: Type aliases and newtypes — coverage gaps ✅ DONE

The syntax is already in place (`type T a = ...`, `newtype UserId = UserId Int
deriving (Eq, Show, Ord)`).  What was added:

- **Recursive type alias detection** — `type Loop = Loop` now raises
  `RecursiveTypeAlias` instead of looping.  `expand_aliases` threads a
  `~seen:StringSet` through its recursion; the error is raised when a cycle
  is detected (both direct and mutual).  2 new typecheck error tests.
- **Newtype `deriving (Num)`** — `DNewtype` is now handled in `desugar.ml`'s
  `expand_decl`.  `derive_num_newtype` generates an `impl Num T` whose method
  bodies use `EBinOp`/`EUnOp`/`EIf` directly, so dispatch works through the
  evaluator's primitive arithmetic path without requiring a `Num Int` closure
  in scope.  2 new eval tests + 1 typecheck test.  Limitation: generated impls
  are correct for `Int`-backed newtypes; `Float`-backed newtypes would need
  float-literal comparisons in `abs`/`signum`.
- **Newtype eta-expansion** — deferred (not blocking; optimisation only relevant
  after a codegen backend exists).
- **579 tests total.**

---

### Phase 27: Where-bound mutual recursion + local `let-rec` ✅ DONE

**Goal.** Make `let f x = ...` implicitly self-recursive so helpers can be
defined locally without a top-level definition.

**What was added.**

- `ELet` widened to `bool * bool * pat * expr * expr`; the second bool is
  `is_fun_def`, set to `true` by the parser when the form has at least one
  explicit argument (`let IDENT pat_atom+ = body`).  Value bindings (`let x =
  expr`) remain non-recursive (`is_fun_def = false`).
- `desugar_where` updated: where-helpers with arguments get `is_fun_def = true`
  so they can call themselves.
- **Typechecker** (`infer`): when `is_fun_def = true` and `pat = PVar x`, the
  RHS is typed with `x` pre-bound to a fresh placeholder TVar (same
  enter/exit-level + unify + generalize pattern as top-level `group_fundefs`).
- **Evaluator**: a mutable `ref VUnit` frame is prepended to the env before
  evaluating the RHS; after the RHS produces a closure, the ref cell is
  updated so all recursive calls see the closure.
- **Resolver**: `ELet (_, true, PVar f, e1, e2)` — `f` is added to scope
  for both `e1` (enabling the self-reference) and `e2`.
- **Printer**: `ELet (_, true, PVar f, ELam ..., e2)` prints as
  `let f x = body in e2` so round-trips are preserved.
- All other ELet match sites updated to accept the new 5-tuple.
- 11 new tests: +3 round-trip, +5 typecheck, +3 eval. **601 tests total.**

**Known gap.** True mutual recursion inside a single `where` block (`f` calls
`g` and `g` calls `f`) still requires an `ELetGroup` AST node (all names
pre-bound before any body is evaluated). Deferred to Phase 25.

---

### Phase 28: Record field assignment `r.field = e` ✅ DONE

**What was added.**
- `DoFieldAssign of ident * ident * expr` variant added to `Ast.do_stmt`;
  `pp_do_stmt` and `strip_locs_do` extended.
- Parser: **replaced** the token-level `IDENT EQUAL expr_no_block newlines`
  (DoAssign) rule with a general `expr_no_block EQUAL expr_no_block newlines`
  rule that dispatches in the semantic action:
  `EVar x → DoAssign`, `EFieldAccess(EVar x, field) → DoFieldAssign`.
  The `IDENT DOT IDENT EQUAL` form cannot be a separate token-level rule in
  LALR(1) (requires 2-token lookahead); parsing through `expr_no_block` is
  the correct solution. Net effect: **−1 S/R state, −1 R/R state** (old
  IDENT-EQUAL R/R state 235 eliminated; no new state added).
  Conflict count now 6 S/R (16) + 7 R/R (26).
- Printer: `print_do_stmt` extended for `DoFieldAssign`.
- Resolver: `EDo` fold extended; checks binding is in scope.
- Type checker:
  - `NotARecord of ident` error variant + `pp_error` case
  - `DoFieldAssign` case in `type_stmts`: checks `mut_vars`; resolves the
    variable's type via `normalize`; for `Ref T` + `"value"` extracts `T`;
    for record types looks up `instantiate_record` + field; unifies with RHS
  - Last-stmt guard: `[DoFieldAssign _]` → error
  - `do_stmt_effects` extended
- Evaluator: `eval_do` extended for `DoFieldAssign` in both singleton and
  non-last positions: `VRef cell` + `"value"` mutates in place; `VRecord`
  rebuilds with field replaced and shadows the binding.
- `lib/desugar.ml` `map_do_stmt` extended for `DoFieldAssign`.
- 13 new tests: 2 parser, 8 typecheck, 3 eval. **587 tests total.**

**Semantics note.** `VRecord` field assignment shadows the binding in the
continuation's env; closures captured before the assignment see the old value.
`VRef .value` assignment mutates the OCaml `ref` cell in place — all readers
see the update immediately.

---

### Phase 29: Higher-order effect tracking via `TFun` ✅ DONE

Effects are now carried in the `TFun` constructor itself:

```ocaml
TFun of mono * effect_set * mono
```

**What was added:**
- `mono.TFun` gained an `effect_set` slot, populated by `from_ast_type`
  from `TyEffect` on the function's return type.  Pure functions get `[]`.
- HM unification ignores the effect slot — passing an effectful function to
  a HOF (e.g. `runWith print`) no longer fails type unification, while
  effects flow through the type naturally via aliases (`p = print`).
- `pp_mono` renders the effect set inline: `String -> <IO> Unit`.
- The post-HM `expr_effects` pass now receives `scheme_env` (the HM result
  schemes) and reads the TFun effect slot for function arguments: when an
  `EApp`'s argument is a named function whose TFun carries effects, those
  effects propagate to the call site.  This catches the previously-missed
  `bad = runWith print` and `p = print; bad = runWith p` cases.
- `expr_effects` also tracks locally-bound names (lambda parameters, let,
  match arms, do-bind) so that a local parameter named `p` is not confused
  with a global function `p`.
- 3 new typecheck tests in the `effects` suite cover the HOF cases.

Still not handled: effect-polymorphic inference for unannotated HOFs (would
require effect variables in `TFun`, not just concrete effect sets).

---

### Phase 30: `@Name` impl selection at runtime ✅ DONE

**What was added.**
- `VNamedImpl of string * value` added to `value` in `lib/eval.ml` —
  wraps a method closure with its declared impl name.
- DImpl handlers in `eval_program` and `eval_repl_decl` tag each method
  value with `VNamedImpl(n, v)` when the impl has `impl_name = Some n`;
  unnamed impls are left unwrapped.
- `apply` (`VMulti` branch) unwraps `VNamedImpl` before applying and
  re-wraps partial-application results to preserve the name across
  multi-argument dispatch.
- `eval` gains two special cases (before the general `EApp`):
  - `EVar hint` where `hint.[0] = '@'` → `VUnit` (matches typechecker's
    Unit inference; prevents unbound-identifier crash for standalone hints).
  - `EApp(f, EVar hint)` / `EApp(f, ELoc(_, EVar hint))` where
    `hint.[0] = '@'` → evaluates `f`, filters VMulti to entries whose
    name matches; error if no named impl found; ignores hint gracefully on
    non-VMulti values.
- Parser: `impl UPPER OF UPPER ...` rule added for uppercase impl names
  (e.g. `impl Multiplicative of Combine Int where`); `AT IDENT` added as
  an `expr_atom` alternative so lowercase `@name` hints also parse.
  Conflict count unchanged: 7 S/R (17) + 8 R/R (27).
- 4 new eval tests (`@Additive`, `@Multiplicative`, standalone `@Foo`,
  `@Unknown` error). **578 tests total.**

**Design note.** No AST changes were needed: the evaluator intercepts the
`EApp(f, EVar "@Name")` shape that the typechecker already silently drops.
The typechecker still treats `@Name` as `Unit`; typecheck-level validation
that the named impl actually exists is deferred to a follow-up phase.

---

### Phase 31: Records — pattern matching and field puns in patterns ✅ DONE

**What was added.**
- `PRec of ident * (ident * pat option) list * bool` variant added to `Ast.pat`
  (field pun = `None`, explicit sub-pattern = `Some p`, `bool` = has `...` rest)
- `pp_pat` in `ast.ml` extended
- Lexer: `ELLIPSIS` token for `"..."` (placed before the single `.` rule)
- Parser: `record_pat_field`, `record_pat_rest`, `record_pat_fields` rules;
  `pat_atom` extended with `UPPER LBRACE record_pat_fields RBRACE`.
  Conflict count: 6 S/R (16) + 8 R/R (34) — one new R/R state from IDENT
  in `record_pat_field` vs `expr_atom` (same class as existing do-block conflicts;
  documented in the audit block).
- Printer: `print_pat` and `print_pat_atom` extended for `PRec`
- Resolver: `check_pat` validates record type name via `env.types` and each
  field name via `env.field_owners`; `pat_bindings` extended
- Type checker: `type_pat` adds `PRec` case reusing `instantiate_record`
  (moved before `type_pat` in source order); field puns introduce a binding of
  the field's type; explicit sub-patterns unify against the field type
- Evaluator: `match_pat` adds `PRec` case matching against `VRecord`
- Exhaustiveness: `desugar` treats `PRec(..., true)` as `PWild` (catch-all)
  and `PRec(name, _, false)` as `PLit (LString "__partial_rec_NAME__")` (open
  literal, so non-exhaustive matches still warn)
- 21 new tests (4 parser, 4 roundtrip, 5 resolver, 5 typecheck, 3 eval). **608 total.**

**Supported syntax.**
```
match p
  Person { name = "Alice", age } => ...  -- explicit field + pun (binds age)
  Person { ... }                 => ...  -- wildcard catch-all
  Person { name, ... }           => ...  -- pun + rest
```

**Known limitation.** Record patterns in DoBind LHS (`Person { name } <- act`)
require parens — `(Person { name }) <- act` — due to the same grammar ambiguity
that affects all UPPER-headed DoBind patterns (documented in Phase 2).

---

### Phase 32: Naming impls and `default impl` ✅ DONE

**What was added (commit `de657e7`).**
- Parser: `impl UPPER of UPPER ...` form added so impl names can be uppercase
  (e.g. `impl Additive of Monoid Int`), consistent with `@Name` which uses
  `AT UPPER`. Lowercase form (`impl ident of UPPER`) preserved for compat.
- `current_impl_hint` global ref in `typecheck.ml` captures the bare name from
  an `@Name` hint at an EApp site and threads it into method_usages as a third
  element `(method, param_vars, hint_opt)`.
- `check_method_usages` updated: when `hint_opt = Some name`, filters matching
  impls to those with `impl_name = Some name`; unknown name raises
  `UnknownImplName`; otherwise the named impl is selected over default
  disambiguation.
- `check_coherence`: new post-registration pass ensuring at most one default
  impl per (iface, type_pattern) pair; raises `MultipleDefaultImpls`. Called in
  `check_program`, `typecheck_module`, and `check_repl_decl`.
- Evaluator: strips `@Name` hints at runtime (`EApp(f, EVar "@X") → eval f`),
  preventing lookup failures; runtime dispatch continues via VMulti default.
- 2 new parser tests, 6 new typecheck tests. **606 tests total.**

**Known limitation.** Runtime dictionary-passing (making `@Name` affect method
calls *inside* a higher-order function like `fold @Multiplicative`) requires a
language-level change and is deferred. `@Name` is fully validated at compile
time; at runtime the VMulti default-dispatch fires regardless of the hint.

---

### Phase 33: Where clauses on interface defaults ✅ DONE

**What was added (this session).**

- **Grammar**: Already supported. `iface_member` (line 637 of `parser.mly`) already used `fun_body`
  which supports `expr_no_block WHERE INDENT bindings DEDENT`. No grammar change needed.
- **Typecheck** (`lib/typecheck.ml`, `register_interface`): Each default method body is now
  type-checked immediately after the method schemes are built. A temporary env that includes all
  interface methods is constructed so defaults can call peer methods. For methods with an inferred
  type (declared as `TyVar "_"` placeholder), the scheme is upgraded to the actual inferred type so
  callers see the real signature (e.g. `a -> String`) instead of a naked TVar.
- **Evaluator** (`lib/eval.ml`):
  - Pass 1 of `eval_program`: `DInterface` case pre-allocates ref cells for default method names.
  - Pass 2 of `eval_program`: `DInterface` case evaluates default method bodies and inserts them
    into `impl_acc` with `score = List.length type_params` (high score = more generic = tried last).
    Concrete impls (score 0) always win; the default fires only when no concrete impl matches.
  - `eval_repl_decl`: mirrors the same `DInterface` logic for the REPL.
- **Tests** (18 new across 6 files):
  - `test_parser.ml`: 1 test — AST shape of an `iface_member` default with a `where` binding.
  - `test_roundtrip.ml`: 1 test — interface default with `where` round-trips correctly.
  - `test_typecheck.ml`: 3 tests — default with `where` type-checks; omitting an overriding impl
    compiles; type error in default's `where` helper is caught at interface declaration.
  - `test_eval.ml`: 2 tests — default method runs when impl omits it; default with `where` helper
    produces correct value.
- **605 tests total** (was 587).

---

### Phase 34: LSP — error reporting (design-doc Phase 3) ✅ DONE

**What was added.**
- `Ast.loc` extended with `end_line` and `end_col` fields so diagnostics
  can highlight full expression ranges rather than a single column.
  `lib/parser.mly`'s `of_pos` helper now takes both `$startpos` and
  `$endpos` at every `ELoc` injection site (29 call sites updated).
- `lib/diagnostics.ml` (new) — runs parse → desugar → resolve → typecheck
  on a source buffer and returns a list of `{severity, loc, message}`
  records instead of exiting on the first error. Resolve errors all
  surface; typecheck stops at the first error per the v1 scope.
- `lib/lsp_server.ml` (new) — LSP server over stdio built on the `lsp`
  and `jsonrpc` opam packages. Handles `initialize`, `shutdown`,
  `textDocument/didOpen/didChange/didClose`; publishes diagnostics on
  every document change. Advertises `textDocumentSync = Full`.
- `lib/dune` — added `lsp` and `jsonrpc` to `libraries`; added the new
  modules to the `modules` list. opam dependencies on `lsp 1.26.0` and
  `jsonrpc 1.26.0` (with transitive `yojson`).
- `bin/main.ml` — `medaka lsp` subcommand wired to `Lsp_server.run`.
- `editors/vscode-medaka/` — `client.js` added (minimal
  `vscode-languageclient` activator spawning `medaka lsp`); `package.json`
  updated to v0.2.0 with `activationEvents`, `main`, and a `medaka.serverPath`
  setting; new `README.md`; `editors/install-vscode.sh` bumped to v0.2.0.
- `dev/lsp_smoke.sh` — out-of-test smoke driver that pipes a synthetic
  `initialize` + `didOpen` + `shutdown` through the binary and asserts
  that an Error-severity diagnostic comes back. Kept out of `dune test`
  per PLAN.md §2.2.
- `test/test_diagnostics.ml` (new) — 7 tests covering clean source,
  parse error, unbound variable, type mismatch, multiple resolve errors
  in one file, `import` rejection, and end-position presence.
- Also fixed a pre-existing build break in
  `lib/typecheck.ml:1445` (`TFun (a, b)` → `TFun (a, _, b)`) — the
  Phase 29 effect-slot change had missed this site.

**655 tests total** (7 new in `test_diagnostics`).

**Known limitations.**
- Typecheck still raises on the first error; accumulating multiple
  typecheck errors per file requires recovery types — deferred.
- No hover, go-to-definition, or completion (design-doc Phase 6).
- The VS Code client requires `npm install` to fetch
  `vscode-languageclient`; this is not run automatically by
  `editors/install-vscode.sh`.

---

### Phase 34.5: LSP — multi-file analysis ✅ DONE

**What was added.**
- `lib/loader.ml` — added `?read:(string -> string option)` to
  `read_file`, `parse_file`, and `load_program`. When `read` returns
  `Some s`, the loader uses that text instead of opening the file from
  disk; this lets the LSP surface unsaved editor buffers without
  touching the parser/resolver/typechecker.  CLI path unaffected
  (default `?read = None`).  `UnknownModule` extended with
  `{ mod_id; importer_file }` so callers know which file's `import`
  references a missing module.
- `lib/diagnostics.ml` — new `analyze_project ~root_file ~project_dir
  ~read` returns `(file_path, diagnostic list) list` covering the
  full import graph. Resolve errors and typecheck errors get bucketed
  by `loc.file`, so a type error in `dep.mdk` is attributed to
  `dep.mdk` even when the user opened `main.mdk`. Empty diagnostic
  lists are seeded for every loaded file so callers can clear stale
  diagnostics. `LoadError`s are converted to diagnostics: a
  `scan_use_loc` helper re-lexes the importer's source to point an
  `Unknown module` diagnostic at the offending `import` keyword.
  The placeholder cross-file warning at the old line 84 is deleted.
- `lib/lsp_server.ml` — `publish_project_diagnostics` replaces the
  per-uri publish path. Maintains `project_roots` (uri → dir, cached
  on first didOpen) and `published_uris` (so files that became clean
  receive an explicit empty publish to clear their squiggles).
  `find_project_root` walks parent directories looking for
  `medaka.toml`, `.git`, or a `core/` directory; falls back to the
  open file's parent dir if no marker is found.
- `bin/main.ml` — pattern match for `UnknownModule` updated to the
  new record shape.
- `test/test_diagnostics.ml` — 5 new multi-file tests: clean project,
  error in dep, unknown module (verifies `scan_use_loc` attribution),
  cyclic dependency, buffer override beats disk. The single-file
  `t_use_decl_warning` test is removed (the warning no longer
  exists).
- `test/test_loader.ml` — one new test for `?read` override.

**678 tests total** (5 new in `test_diagnostics`, 1 new in
`test_loader`, 1 removed).

**Known limitations.**
- One project root per file (no multi-root workspace support; each
  open file infers its own root via the marker walk).
- Re-parses every file in the graph on every keystroke — fine at the
  stdlib's current scale (~10 files) but should grow an AST cache
  before larger projects come online.
- `CyclicDependency` diagnostics report once against the root file
  rather than per-file in the cycle.
- `TextDocumentDidClose` only clears the closed URI; dep diagnostics
  in still-open files remain (which is correct), but a closed root's
  dep diagnostics linger until another root in that project republishes.

---

### Phase 35: Code formatter `medaka fmt` ✅ DONE

Shipped a single-style formatter that wraps the pretty-printer with
comment preservation, file/directory walking, and a round-trip safety
net that re-parses formatted output and aborts the write if the AST
changed.

CLI: `medaka fmt [--check | --stdout | --write] <path>...`
- Default mode rewrites each file in place (atomic via `path.tmp` rename).
- `--check` reports unformatted files and exits 1 (suitable for CI).
- `--stdout` prints to stdout; requires exactly one file.
- Paths may be `.mdk` files or directories (recursed).

Comment preservation: the lexer now records `--` line comments on a
side channel (lib/lexer.mll), and the parser records top-level
declaration positions via a shared `Parser_state` module. The new
`Printer.format_program` interleaves comments at faithful source
positions and preserves single blank-line spacing between declarations.

Known limitation (acceptable for v1): comments that appear *inside* a
declaration body in source are emitted to the gap between that decl and
the next. Comments are line-only (`-- ...`); the language has no block
comments.

---

### Phase 36: `medaka.toml` project config + `medaka new` ✅ DONE

Multi-file projects need a stable project root marker.  A minimal
`medaka.toml` (Cargo-style) at the root, with a `medaka new` command
that scaffolds it, unblocks the multi-file CLI we already support but
have no nice way to invoke (today the loader infers project_dir from
the root file's directory).

Shipped:
- `medaka new <name>` scaffolds `medaka.toml`, `main.mdk`, `.gitignore`,
  and `README.md` in a new directory.
- `medaka.toml` schema: `[package]` table with `name`, `version`,
  `entry` (parsed by a hand-rolled mini-TOML reader in
  `lib/project_config.ml`; no new opam dep).
- CLI: `project_dir` is now found by walking up for `medaka.toml`,
  falling back to the file's directory if none is found.
- `medaka run` / `medaka check` with no file argument resolves `entry`
  from the cwd's `medaka.toml`.
- `lib/lsp_server.ml` now shares the walk-up helper with the CLI.

---

## Cross-language inspiration arc

These phases come from the 2026-05-26 design review that audited Medaka
against OCaml, F#, Rust, Elm, and Clojure for features worth borrowing.
See `language-design.md` for the user-facing description of each. Listed
roughly in order of expected difficulty.

### Phase 37: `?` postfix operator for `Result` and `Option` ✅ DONE

Postfix `?` in a let-binding RHS desugars to a monadic `andThen` call:
`let x = expr ? in rest` becomes `andThen expr (x => rest)`.  Short-
circuit on `Err` / `None` falls out of the existing `Thenable` impls in
the prelude — no new runtime machinery, no exception-based early
return, no return-type tracking in the type checker.

Shipped:
- New AST node `EQuestion of expr` (lib/ast.ml).
- Lexer: `?` → `QUESTION` token.
- Parser: new `expr_question` level between `expr_infix` and `expr_app`
  so `Ok 5 ?` parses as `(Ok 5) ?`, not `Ok (5 ?)`.
- Desugar: `ELet(pat, EQuestion(e1), e2)` → `andThen e1 (pat => e2)`;
  `DoLet(pat, EQuestion(e))` → `DoBind(pat, e)` (indent-based blocks
  parse as do-blocks, so `?` must work in both forms).
- REPL: now desugars `ReplExpr` and `ReplDecl` before resolve, so the
  pipeline matches `bin/main.ml`'s order.
- Resolve: emits a clear `QuestionMisplaced` error for `?` outside a
  `let` RHS — points users at `let x = expr ?` or `<-` in do-blocks.
- Restricted to let-RHS position: `(foo ?) + 1` is rejected.  A
  Rust-style unrestricted `?` (anywhere in an expression) would need
  a CPS transform or an exception mechanism; the restriction is a
  strict subset and covers the common case.
- Tests: 10 new tests across `test_parser.ml`, `test_eval.ml`,
  `test_resolve.ml`.

### Phase 38: `if let` and `let else` ✅ DONE

Two sugars over single-arm pattern match:
- `if let pat = expr then a else b` — bind through `pat`, fall through
  to `b` if it doesn't match. Desugars at parse time to
  `EMatch(expr, [(pat, None, a); (PWild, None, b)])` — no new AST node.
- `let pat = expr else body` in do-blocks — new `DoLetElse of pat * expr * expr`
  do-stmt variant. Scrutinee is a plain value (not monadic); else branch
  executes when the pattern doesn't match.

**What was added.**
- `DoLetElse of pat * expr * expr` added to `Ast.do_stmt`; `pp_do_stmt` and
  `strip_locs_do` extended.
- `parser.mly`: `IF LET pat EQUAL expr_or THEN expr_lam ELSE expr_lam` rule
  in `expr_lam`; `LET pat EQUAL expr_no_block ELSE expr_no_block newlines` rule
  in `stmt`. No new grammar conflicts — 6 S/R + 8 R/R unchanged.
- `printer.ml`, `resolve.ml`, `typecheck.ml` (type_stmts + do_stmt_effects),
  `eval.ml` (eval_do), `desugar.ml` (map_do_stmt) all updated for `DoLetElse`.
- 15 new tests (4 parser, 2 roundtrip, 5 typecheck, 4 eval). **675 tests total.**

**Known limitation.** `let else` does not enforce that the else branch diverges.
A non-diverging else branch typechecks (the rest of the block is silently skipped
at runtime when the pattern fails). Full enforcement requires a `Never` type —
deferred alongside Phase 37's `?` early-return operator.

### Phase 39: Variants with named fields ✅ DONE

Inline record-style payloads on `data` constructors:
```
data Event
  = Click { x : Int, y : Int }
  | KeyPress { key : Char, shift : Bool }
  | Scroll Int
```

Scope:
- Grammar: allow `{ field : Ty, ... }` after a constructor name in
  `data` declarations.
- AST: variant payload becomes a sum (positional list | named record).
- Patterns: `Click { x, y }` with field punning support (Phase 31
  already implemented record-pattern field puns; reuse).
- Exhaustiveness: existing checker treats named-field variants
  identically to positional ones once parsed.

### Phase 40: Range literals ✅ DONE

`1..10` (half-open), `1..=10` (inclusive). All three contexts implemented.

**What was added.**
- Lexer: `DOTDOT` (`..`) and `DOTDOT_EQ` (`..=`) tokens, placed before `DOT`
  after `ELLIPSIS` so longest-match gives `...` → ELLIPSIS, `..=` → DOTDOT_EQ,
  `..` → DOTDOT, `.` → DOT.
- AST: `ERangeList of expr * expr * bool`, `ERangeArray of expr * expr * bool`,
  `ESlice of expr * expr * expr * bool` (bool = inclusive), `PRng of literal * literal * bool`.
- Parser: range rules in `expr_atom` for `[lo..hi]` / `[|lo..=hi|]`; slice rules
  in `expr_postfix` for `e.[lo..hi]`; range pattern rules in `pat_atom` for
  `INT DOTDOT INT` / `CHAR DOTDOT_EQ CHAR` etc.
- Printer, resolver, typechecker, evaluator, exhaustiveness checker, desugarer:
  pass-through or handle all new variants.
- Typechecker: `ERangeList`/`ERangeArray` type as `List Int`/`Array Int`;
  `ESlice` preserves container type (Array, List, or String); `PRng` types as
  `Int` (int range) or `Char` (char range).
- Evaluator: range literals produce `VList`/`VArray` of `VInt`s; slice produces
  sub-array/sub-list/substring; `PRng` in `match_pat` checks bounds.
- Exhaustiveness: `PRng` desugars to `PWild` (conservative open-type treatment).
- Conflict count: 8 S/R (20) + 8 R/R (34) — 2 new S/R states from INT/CHAR
  in pat_atom, both resolved shift (range pattern wins), documented in audit block.
- 33 new tests across parser (8), roundtrip (8), typecheck (7), eval (10).
  **711 tests total.**

**Special-case lowering chosen**: no `Range` type in the runtime; ranges evaluate
directly to `VList`/`VArray`. Slicing works on `Array`, `List`, and `String`.

### Phase 41: Doctests ✅ DONE

Executable examples embedded in doc comments. Lines beginning with
`-- > ` are the input; following non-`> ` lines are the expected
result; a blank line ends the example.

Scope:
- Doc-comment parser: extract `> example` blocks alongside the prose.
- Test runner: register each doctest as a test case; compare the
  evaluated form's `show` output against the expected text.
- `medaka doc`: render examples back into generated HTML/markdown.

### Phase 42: Property testing (`prop` + `Arbitrary`) ⏳ TODO

`prop "name" (x : T) = ...` declares a property quantified over `T`,
generated automatically via an `Arbitrary` interface (derivable).
Shrinking is built in.

Scope:
- Stdlib: `Arbitrary a` interface with `arbitrary : <Rand> a` and
  `shrink : a -> List a`. Derivable for any `data`/`record` whose
  fields are themselves `Arbitrary`.
- Test runner: `prop` declarations run N (configurable) times,
  reporting the smallest shrunk counterexample on failure.
- Built-in `Arbitrary` impls for `Int`, `Float`, `Bool`, `Char`,
  `String`, `List`, `Array`, `Option`, `Result`, tuples.
- Plug into `deriving` machinery already in place from Phase 18.5.

### Phase 42.5: `where`-binding fixes ✅ DONE

**What was added.**
Two latent gaps in `where`-binding handling (uncovered while writing
`find`/`count` in the stdlib) plus the equivalent gap for top-level
multi-clause function definitions:

- **Guards in `where` bindings.** `where_binding` in `lib/parser.mly`
  gained a second production reusing `desugar_guards`:
  `IDENT list(pat_atom) INDENT nonempty_list(guard_arm) DEDENT newlines`.
- **Multi-clause `where` bindings.** `ELetGroup` changed from
  `(ident * expr) list * expr` to
  `(ident * (pat list * expr) list) list * expr`. `desugar_where`
  now groups same-named bindings (first-appearance order). Each
  group becomes a single cell holding a `VMulti` when there are 2+
  clauses, matching the existing impl-method dispatch mechanism.
  Eval (`lib/eval.ml`), typecheck (reusing `clause_to_expr`), resolve,
  printer, and the `map_expr` traversal in desugar were all updated
  for the new shape.
- **Top-level multi-clause function definitions.** Eval's pass-2 over
  `DFunDef`s and the REPL-style incremental path now accumulate per
  name and emit `VMulti` for 2+ clauses, mirroring `impl_acc`. Type
  inference already handled this via `group_fundefs`; only eval was
  silently overwriting cells.
- **Haskell-style newline-before-`where`.** Added a new `fun_body`
  alternative `expr_no_block INDENT WHERE INDENT bindings DEDENT
  newlines DEDENT` (and the analogous form in `match_arm`) so the
  user can write
  ```
  find f = fold g None
      where
          g (acc@Some _) _ = acc
          g None x
              | f x = Some x
              | otherwise = None
  ```
  in addition to the existing `body where ...` same-line form.

**Tests added.** 4 parser, 5 eval — `t_where_guards`,
`t_where_multi_clause`, `t_where_multi_clause_with_guards`,
`t_toplevel_multi_clause`, `t_where_on_new_line`. The drafted `find`
and `count` in `stdlib/core.mdk:181-195` are now the end-to-end
regression.

Parser-conflict accounting unchanged in structure (the new productions
introduce 2 S/R and 1 R/R compared to the previous baseline — within
the LALR(1) noise already tolerated).

**Out of scope.** The pre-existing "Known gap" at the bottom of Phase
26 (true mutual recursion in `where` blocks waiting on `ELetGroup`)
was already resolved when `ELetGroup` was first introduced; this
phase did not revisit it.

### Phase 43: Abstract type exports ✅ DONE

`export data T = ...` exposes only the type name (abstract); `public
export data T = ...` additionally exposes constructors. Same applies
to `record`.

**What was added.**
- `type data_vis = DataPrivate | DataAbstract | DataPublic` in
  `lib/ast.ml`; `DData` and `DRecord` changed from a single `bool`
  to `data_vis` as the first field.
- `"public"` → `PUBLIC` keyword added to `lib/lexer.mll`.
- `lib/parser.mly`: `PUBLIC` token; `inner_decl_body` split into
  `inner_data_or_record` (returns `data_vis -> decl`) and
  `inner_non_data_decl` (returns `bool -> decl`); `decl` rule
  rewritten with `PUBLIC EXPORT` alternatives producing `DataPublic`,
  bare `EXPORT` for data/record producing `DataAbstract`. Conflict
  count unchanged: 8 S/R (20) + 8 R/R (34).
- `lib/printer.ml`: three-way visibility printing — `"public export "`,
  `"export "`, or nothing.
- `lib/resolve.ml` `build_exports`: `DData (DataPublic, ...)` exports
  type + all constructors; `DData (DataAbstract, ...)` exports type
  name only; `DataPrivate` exports nothing.
- `lib/typecheck.ml` `typecheck_module`: `pub_ctors` and `pub_records`
  filtered to `DataPublic` only (abstract types don't expose
  constructors to importers' type env).
- Enforcement: natural — if a constructor isn't in `exp_constructors`,
  it never enters the importing module's env, giving `UnboundVariable`
  on use. No special typechecker changes needed.
- `stdlib/core.mdk`: `Ordering`, `Option`, `Result` changed to
  `public export data` (users must pattern-match their constructors).
- 14 new tests: 5 parser (DataPrivate/DataAbstract/DataPublic shapes
  for data and record), 5 roundtrip (printer output verified), 4
  loader (export table membership and cross-module enforcement).
  **764 tests total.**

**Known limitation.** Error messages say `UnboundVariable "Red"` when
a user tries to use a constructor from an abstractly-exported type.
A future improvement would detect that the type exists but is abstract
and suggest `public export`.

### Phase 44: `function` keyword ✅ DONE

`function` is sugar for a lambda that immediately pattern-matches its
single argument:

```
sign =
  function
    n if n > 0 => 1
    n if n < 0 => -1
    _ => 0
```

desugars at parse time to `ELam([PVar "__fn_arg"], EMatch(EVar "__fn_arg", arms))`.

**What was added.**
- `lib/lexer.mll`: `"function" -> FUNCTION` keyword.
- `lib/parser.mly`: `%token FUNCTION`; new `expr_lam` alternative
  `FUNCTION INDENT nonempty_list(match_arm) DEDENT` that desugars
  inline — no new AST node, no changes to resolver/typechecker/evaluator.
  Conflict count unchanged: 8 S/R (20) + 8 R/R (34).
- 8 new tests (2 parser, 1 roundtrip, 3 typecheck, 2 eval). **758 tests total.**

### Phase 44.5: Method-level interface constraints + type-tagged dispatch ✅ DONE

**Motivation.** Modelling Haskell-style `Foldable.foldMap` ergonomics
required two interlocking features:
1. An interface method may carry extra constraints on locally-quantified
   tyvars beyond the interface's own type parameter (e.g.
   `foldMap : Monoid m => (a -> m) -> t a -> m` inside `Foldable t`).
2. At runtime, a polymorphic body invoking a zero-arg method like
   `empty : Monoid m => m` must eventually resolve to the right impl —
   which the existing eval handled only at do-block boundaries via the
   `pure_impls` / `current_monad_type` mechanism, leaving anything else
   as an unresolved `VMulti` that recursed infinitely under `++`.

**Typechecker changes (`lib/typecheck.ml`).**
- `iface_info` gained `iface_method_constraints : (ident * (ident * int
  list) list) list`, mirroring the shape of `fun_constraints`.
- `register_interface` stops dropping `Ast.TyConstrained` on method
  types. The inner type and per-method constraint args share one
  `method_vars` table so their TVar references coincide; after
  `generalize`, the bound IDs in `iface_method_constraints` line up
  with the method scheme.
- `instantiate_method` now returns the full `(int * mono) sub` alongside
  the result and tracked param refs. The `EVar` method-dispatch branch
  uses the sub to emit `constraint_obligations` for the extra
  method-level constraints. Skip-when-still-polymorphic in
  `check_constraint_obligations` already handles defaults gracefully.
- `register_interface` builds `env_with_methods` from **prior**
  interface methods plus the current one, so a default body can call
  methods from previously-registered interfaces (Foldable's default
  calls `Monoid.append`/`empty`).

**Eval changes (`lib/eval.ml`).**
- New `VTypedImpl of string * value` variant: each impl method is
  tagged with `head_tycon` of its impl's first `type_arg` (e.g.
  `"String"`, `"List"`). Both the program-load and REPL impl paths
  produce the tag, then layer `VNamedImpl` on top if the impl is named.
- New `runtime_type_tag` derives a tag from any value (`VString →
  "String"`, `VCon → ctor_to_type`, etc.).
- `apply` for `VMulti` filters candidates by the arg's runtime tag
  when known; partial-application results re-wrap with their tag so
  subsequent args still route correctly.
- `apply` for `VTypedImpl` is a pass-through that re-wraps any
  partial-application result back into `VTypedImpl(t, …)` — preserving
  the routing tag across each step of a multi-arg call.
- The `++` binop handler, when one operand is a `VMulti` of
  differently-typed candidates and the other has a concrete tag,
  picks the matching candidate before falling into the
  `VList`/`VString` short-circuits. This is the trick that lets
  `acc ++ f x` in `Foldable.foldMap`'s default work when `acc` started
  life as the still-polymorphic `empty`.

**Stdlib (`stdlib/core.mdk`).** `foldMap` moved from a top-level
`(Foldable t, Monoid m) =>` function into a `Foldable` method with a
default `foldMap f = fold (acc => x => acc ++ f x) empty`. Existing
`Foldable` impls don't need to change.

**Tests added.**
- `test/test_typecheck.ml` — 3 new cases under
  "method-level constraints": extra constraint resolves at a concrete
  call site, default body uses the extra constraint, error when no
  impl exists for the constrained arg.
- `test/test_eval.ml` — 2 new cases under "lists": `foldMap` on the
  String monoid and on the List monoid, both exercising the typed
  dispatch end-to-end.

**Known limits.**
- The `++` resolver only grounds `VMulti` when the **other** operand
  has a runtime tag. Two `VMulti` operands meeting in `++` still
  fall through. That's fine for the foldMap default (the mapped value
  always grounds).
- Type-driven dispatch only filters by the **head** TyCon. Impls with
  the same head but different parameters (e.g. `impl Eq (Map k v)` vs
  `impl Eq (Map String v)`) still rely on the existing score-based
  ordering — same as before this phase.

### Phase 45: Nested record update sugar ✅ DONE

`{ p | address.city = "Boston" }` desugars to
`{ p | address = { p.address | city = "Boston" } }`. LHS is a dotted
path; RHS is any expression. One-level only at first; deeper paths
nest the desugaring further.

Scope:
- Parser: dotted paths allowed on the LHS of `=` inside update braces.
- Desugar in the AST builder.
- Decide whether to support multiple field updates with overlapping
  prefixes in one brace (e.g. `{ p | address.city = ..., address.zip = ...}`);
  reject as a non-goal initially — explicit nesting is fine.

### Phase 45.9: User-defined impl conflicts with seeded built-in ✅ DONE

Fixed in this session.  `impl_entry` now carries `impl_seeded : bool`.
In both `check_method_usages` and `check_constraint_obligations`,
after collecting all matching impls, if at least one non-seeded
(user-defined) impl is present, the seeded entries are filtered out
before the final ambiguity check.  Net effect: user impls override
seeded built-ins; the built-in still resolves when no user impl is
in scope.

Concrete fix verified:
```
impl Eq Int where eq a b = a == b
impl Ord Int where
  compare a b = if a < b then Lt else if a > b then Gt else Eq
r = lt 1 2     -- works, no ambiguity
```

…and `r = 1 < 2` (no user impl) still resolves through the seeded
entry as before.

This is a stopgap — the right long-term fix per §5 entry "Eq, Num,
Ord stdlib interfaces disconnected from built-in operator
constraints" (Phase 19) wires `+`/`<`/etc. through the stdlib's
interfaces directly, which makes the seeded impls unnecessary.

Regression tests added under `test/thorough/thorough_typecheck.ml`
in the "interfaces / constraints" group:
`user impl over primitive` and `seeded fallback still works`.

### Phase 45.7: Multi-line if-then-else parsing ✅ DONE

Fixed in this session.  Four new grammar productions added:

1. `IF expr_or THEN expr_lam newlines ELSE expr_lam` — enables
   else-if chains on multiple lines.
2. `IF expr_or THEN INDENT stmts DEDENT newlines ELSE INDENT stmts DEDENT`
   — both branches indented blocks.
3. `IF expr_or THEN INDENT stmts DEDENT newlines ELSE expr_lam`
   — indented THEN, inline ELSE.
4. `IF expr_or THEN expr_lam ELSE INDENT stmts DEDENT`
   — inline THEN, indented ELSE.

No new menhir conflicts.

All six previously-failing forms now parse and evaluate:

```medaka
if n > 0 then 1 else if n < 0 then -1 else 0     -- one line
if n > 0 then 1
else if n < 0 then -1
else 0                                            -- else-if chain
if n > 0 then
  let a = n + 1
  a * 2
else
  0                                               -- multi-stmt then
if cond then
  println "yes"
else
  println "no"                                    -- do-bodies in branches
```

Regression tests under `test/thorough/thorough_eval.ml` group
"multi-line if (Phase 45.7)": both branches indented, only-then,
only-else, multi-stmt then, else-if multi-line, do bodies.

### Phase 45.8: Multi-line match arm bodies ✅ DONE

Fixed in this session.  A new `match_arm` production accepts
`INDENT nonempty_list(stmt) DEDENT newlines` as the body:

```
pat option(guard) FAT_ARROW INDENT nonempty_list(stmt) DEDENT newlines
  { ($1, $2, stmts_to_expr $5) }
```

No new menhir conflicts.  All these now parse and work:

```medaka
match xs
  [] => 0
  (x::_) =>
    let s = x + 1
    s              -- multi-stmt body

match xs
  [] => 0
  (x::_) =>
    if x > 0 then x
    else 0         -- indented if as body

match x
  Some n =>
    match n        -- nested match in arm body
      0 => "zero"
      _ => "non-zero"
  None => "none"
```

Regression tests under `test/thorough/thorough_eval.ml` group
"multi-line match arm (Phase 45.8)".

**Design limitation (not a bug):** parenthesized lambda bodies with
indented stmt sequences don't parse:

```medaka
g = (x =>           -- DOES NOT PARSE
  let a = x + 1
  a)
```

Three constraints conflict: (1) Phase 45.13's lexer change suppresses
INDENT/DEDENT inside `(…)`/`[…]`/`{…}`/`[|…|]` to make multi-line
groupings work; (2) lambda bodies are `expr_lam`, which has no
multi-stmt block form; (3) `do INDENT … DEDENT` is the only way to
delimit a stmt sequence, and INDENT is suppressed inside parens.
Any of these three would have to be relaxed to allow the form above —
all options have non-trivial tradeoffs.

Working alternatives (all parse today):

```medaka
g = (x => let a = x + 1 in a)                 -- inline let-in
g = (x => let a = x + 1 in                    -- let-in with body on
          a)                                  -- next line
g = (x => let a = x + 1 in let b = a*2 in b)  -- chained let-ins

-- Or extract the body to a named function (indented body works
-- there because fun_body has its own indented-stmt rule):
g x =
  let a = x + 1
  a
r = map g xs
```

Regression tests in `thorough_eval` group "paren lambda workarounds
(Phase 45.8 limit)" pin the working alternatives.

### Phase 45.10: List monad in do-blocks ✅ DONE

Fixed in this session.  Two-line change in `lib/eval.ml`:

1. The `DoBind` handler also dispatches via Thenable when the bound
   value is a `VList _` (in addition to the existing `VCon` check),
   provided `monadic_ctors` contains "Cons" (which it does whenever
   `impl Thenable List` is in scope — always, since core.mdk
   provides it).
2. `detect_monad` returns `Some "List"` for `VList _`, so when a
   do-block's first bind is a list, `current_monad_type` is set to
   "List" and the `pure` primitive can look up the List-specific
   pure impl (`pure a = [a]`).

Concretely:

```medaka
r = do
  x <- [1, 2, 3]
  pure (x * 2)
-- previously: runtime error "unknown op '*' for [1,2,3], 2"
-- now: [2, 4, 6]

r = do
  x <- [1, 2]
  y <- [10, 20]
  pure (x + y)
-- [11, 21, 12, 22]   (cartesian product)
```

Regression tests added under `test/thorough/thorough_eval.ml` in the
new "List monad in do" group: simple bind+pure, cross product, empty
list short-circuits, andThen direct still works, list comprehension
equivalent.

PLAN.md §5's known limitation about List monad has been struck
through.

### Phase 45.6: VRecord must carry its type name ✅ DONE

Fixed in this session.  `VRecord of (string * value) list` became
`VRecord of string * (string * value) list`, carrying the declared
type name.  `runtime_type_tag` now returns `Some tn` for record
values, so VMulti dispatch routes method calls on a record to the
correct impl even when other impl candidates match wildcard-style.

Updated all VRecord match sites in `lib/eval.ml`:
- type declaration
- `pp_value` (now prints `Point { x = 3, y = 4 }` rather than just
  `{ x = 3, y = 4 }`)
- `match_pat` for `PRec`
- `EFieldAccess` (both the "value" special-case and the general case)
- `ERecordCreate` (fallthrough to plain VRecord)
- `ERecordUpdate` (preserves the existing record's type name)
- `[DoFieldAssign _]` last-stmt no-op case
- `DoFieldAssign :: rest` general case
- `runtime_type_tag`

Test changes:
- Single existing test (`t_do_build_record` in thorough_interactions)
  updated to use new `VRecord ("P", [...])` constructor.
- New tests proving the fix:
  `t_record_show_with_int_show` (dispatch routes correctly when both
  `impl Show Int` and derived `impl Show Point` are in scope), and
  `t_record_deriving_eq_with_int_eq` (deriving Eq on a record works
  when the field types have Eq impls).
- New `t_interp_with_show_record` test (record value used inside a
  string interpolation hole via show).

All 13 base test binaries pass; all 4 thorough binaries pass.

### Phase 45.5: EDo `has_bind` split ✅ DONE

Found while building the thorough test suite (2026-05-26 night session).
The parser lowers any multi-stmt indented function body to `EDo`
(via `stmts_to_expr`).  The typechecker's old `EDo` handler introduced
a per-block monad tyvar `m` and forced *every* `DoExpr` / `DoBind` RHS
to unify with `m a` — which is correct for monadic `do { x <- m; ... }`
patterns but wrong for two large classes of valid programs that the
existing test suite never exercised end-to-end (eval and typecheck were
tested separately):

1. **Indented function bodies with `let` + pure expr.**
   `f x = (indent) let a = x + 1 (newline) a (dedent)` parses as
   `EDo [DoLet; DoExpr]` and was rejected with `Type mismatch: Int vs a b`
   because `a : Int` couldn't unify with `m a`.

2. **Effectful sequencing with no `<-` bind.**
   `main : <IO> Unit; main = do { println "one"; println "two" }` —
   the bread-and-butter IO pattern — was rejected with
   `Type mismatch: Unit vs a b` because `println` returns `Unit` (the
   `<IO>` effect lives on `TFun`, not the return type), and `Unit`
   couldn't unify with `m a`.

Fix: split EDo into two modes by whether *any* stmt is a `DoBind`.
With a bind, the existing per-block-`m` logic runs unchanged.  Without,
each `DoExpr` is just typed and its result discarded — no `m a`
constraint.  `DoLet` / `DoAssign` / `DoFieldAssign` / `DoLetElse`
handling is shared.  Eval already handled both modes correctly
(`eval_do` sequences stmts directly), so the runtime needed no changes.

Regression tests landed in `test/test_typecheck.ml` under the existing
`"do notation"` suite: `indented body: lets+expr`, `indented body: 1 let`,
`indented toplevel lets`, `indented body: poly let`, `do seq, no bind`,
`indented effectful seq`.  Existing `t_do_single_expr` was updated to
match the new (correct) behavior: `f x = do x` now types as `a -> a`
rather than `a b -> a b`.

---

## Tooling arc (also from the 2026-05-26 review)

### Phase 46: Snapshot tests ✅ DONE

`assert_snapshot "name" value` compares `value` (a `String`) against a stored
reference under `{project_root}/snapshots/name.snap`. `medaka test
--update-snapshots` refreshes snapshots deliberately.

**What was added.**
- `stdlib/runtime.mdk`: `extern assert_snapshot : String -> String -> <IO> Unit`.
- `lib/eval.ml`: `snapshot_dir : string ref` and `snapshot_update : bool ref`
  module-level refs (defaults: `"snapshots"`, `false`). `"assert_snapshot"` in
  the `primitives` dispatch table: sanitizes the name (non-alphanumeric → `_`),
  creates the `snapshots/` directory if absent, creates the snapshot on first
  run, compares on subsequent runs, raises `Eval_error` on mismatch. In
  `--update-snapshots` mode overwrites the file unconditionally.
- `bin/main.ml`: strips `--update-snapshots` from the test-subcommand arg list
  (alongside the existing `--coverage` strip), finds the project root, and sets
  `Eval.snapshot_dir`/`Eval.snapshot_update` before calling `Test_cmd.run` or
  `Prop_runner.run_all`.
- `test/test_snapshot.ml` + `test/dune`: 6 new tests (creates on first run,
  passes on match, fails on mismatch, update mode, name sanitization, doctest
  integration). **795 tests total.**

**Usage example (doctest):**
```medaka
greeting : String
greeting = "hello world"

-- > assert_snapshot "greet" greeting
-- ()
```
First run: `snapshots/greet.snap` is created and the test passes.
Subsequent runs: content is compared.
`medaka test --update-snapshots file.mdk` overwrites on change.

### Phase 47: Coverage via `medaka test --coverage` ✅ DONE

Line-coverage instrumentation as part of the standard toolchain.

- `lib/coverage.ml`: global hit table (`enabled` ref + `hit` hashtable), `record_hit`, `collect_executable` (AST walker over `DFunDef`/`DImpl`/`DInterface`/`DProp`/`DBench`), `pp_report` (per-file summary with uncovered line list).
- `lib/eval.ml` `ELoc` handler: calls `Coverage.record_hit loc.file loc.line`.
- `bin/main.ml` `medaka test` block: strips `--coverage` from argv, calls `Coverage.enable ()`, prints report after all tests via `collect_executable program` + `pp_report`.
- `test/test_coverage.ml`: 12 tests across collect_executable, record_hit, eval integration, and pp_report formatting.

### Phase 48: `medaka bench` ✅ DONE

First-class benchmark target. `bench "name" = expr` declarations
collected and run separately from `test`. Reports throughput and
variance.

### Phase 49: Declaration attributes ✅ Done

Closed set: `@deprecated "msg"`, `@inline`, `@must_use`. Parser-level
only; semantics dispatched to the typechecker (`@deprecated`,
`@must_use`) or the backend (`@inline`). Not user-extensible.

`DAttrib` AST node wraps inner decl; `Ast.inner_decl` strips all layers
for passes that need the bare decl. `register_attrs` populates
`env.deprecated_fns` / `env.must_use_fns` before type inference.
161/108/287/142 tests pass.

### Phase 50: Workspaces in `medaka.toml` ✅ DONE

Cargo-style multi-package workspaces: a root `medaka.toml` declares
`[workspace] members = [...]`, sharing one lockfile and resolving
the dependency graph across the whole tree. Builds on Phase 36.

**What was added.**
- `type workspace = { ws_members : string list }` added to `ProjectConfig.t`;
  `name`/`version`/`entry` made `string option` (required if `[package]` present,
  `None` for workspace-only roots).
- TOML parser extended with array literal support (`["a", "b"]` via
  `parse_array_value`); `toml_value = Str of string | Arr of string list`
  replaces the former `(string * string) list` internal representation.
- `find_workspace_root : string -> string option` — walks up from a file's
  directory stopping at the first `medaka.toml` with a `[workspace]` table.
- `load_workspace_members : string -> (string * t) list` — resolves each
  member path relative to the workspace root and loads its config.
- `Loader.load_program` signature changed to accept `roots : string list`
  instead of a single `project_dir`. All existing call sites pass `[project_dir]`
  (backward compatible). Workspace calls pass one root per member directory.
- `Loader.module_id_of_path` now takes `roots : string list`; tries each root
  as a prefix and uses the first match.
- `AmbiguousModule of { mod_id; found_in }` added to `Loader.load_error` (and
  handled in `diagnostics.ml` and `bin/main.ml`).
- `medaka check` (no args) from a workspace-only root iterates all members,
  runs resolve + typecheck on each with the full member-roots list, and exits 1
  if any member fails.  `medaka run` from a workspace-only root errors helpfully.
- `lib/test_cmd.ml` updated for `entry : string option`.
- 8 new `test_project_config` cases (workspace parse, `find_workspace_root`,
  `load_workspace_members`); 3 new `test_loader` cases (cross-member import,
  ambiguous module, single-root compat). All prior tests still pass.

---

## Implementation & parser gaps (2026-05-27 self-hosting prep)

Items audited during the 2026-05-27 self-hosting discussion.  Each
is either a long-standing implementation gap or a parser/lexer
limitation that should be addressed before (or as part of) the
self-hosting reimplementation.  Many are already mentioned in §5;
this section gives each a phase number so they can be tracked,
prioritized, and closed.

### Phase 51: Effect inference for unannotated functions ✅ DONE

Design doc §Effect System promises automatic propagation: "call an
`<IO>` and `<Rand>` function, your function is inferred as
`<IO, Rand>`."  Previously the typechecker required explicit annotation
— `f x = print x` failed with "Function 'f' has no effect annotation
but performs `<IO>`."

The `TFun.effect_set` slot (Phase 29) and the `infer_and_check_effects`
pass already built up inferred effects in `eff_env` before checking.
The fix was to remove the `ImpureFunction` rejection in the `None`
branch so unannotated functions silently accept their inferred effects.
Annotated functions still enforce `inferred ⊆ declared` via
`EffectEscape`. `ImpureFunction` was removed from `type_error`.

161/108/288/142 tests pass; thorough effects group: 6 tests (3 new).

### Phase 52: Eq/Num/Ord wiring to operators ✅ DONE

Currently `+`/`-`/`*`/`/` dispatch through a synthetic `__num__`
witness, `<`/`>`/`<=`/`>=` through `__ord__`, and `==`/`!=` skip
constraint lookup entirely.  These are seeded in
`seed_builtin_impls` with hardcoded impls for `Int`, `Float`,
`String`, `Char`.  They are *not* connected to the `interface Num`
/ `interface Ord` / `interface Eq` defined in `core.mdk`.

Net effect: `impl Num MyType` doesn't make `+` work on `MyType`;
`deriving (Ord)` generates an impl the `<` operator won't consult.

Phase 45.9 added a stopgap (user impls override seeded fallbacks
for the synthetic interfaces) but the proper fix wires the
operators through the actual stdlib interfaces:
- `+` ↦ `add` method of `Num`
- `<` ↦ `lt` method of `Ord`
- `==` ↦ `eq` method of `Eq`
- Remove `__num__`/`__ord__` synthetic witnesses.
- Remove `seed_builtin_impls`; provide `impl Num Int`, `impl Eq
  Int`, etc. directly in `core.mdk`.

Touches `typecheck.ml` (constraint emission for operators) and
`core.mdk` (provide the missing impls).  Big test impact — most
existing operator usages will start emitting Num/Ord/Eq
constraints.

Related: "do-notation is not wired to `Thenable`" from §5 — `<-`
should desugar to `andThen` calls so the `Thenable` constraint is
actually checked.  Same arc, bundle with this phase.

### Phase 53: Type-annotated AST for do-blocks ✅ DONE

**What was added (commit `96588f0`).**
- `EDo of do_stmt list` → `EDo of string option ref * do_stmt list`.
  The ref carries the resolved monad type name (e.g. `"Option"`,
  `"List"`, `"Result"`); the parser initialises it to `ref None`.
- `typecheck.ml` `infer` for `EDo`: after `type_stmts` completes on a
  monadic do-block, normalises the monad tyvar `m` and writes the head
  TyCon into the ref (`Some tname`).  Polymorphic / unresolved monads
  leave it `None`.
- `eval_do` signature changed to accept `monad_tag : string option`;
  at block entry, seeds `current_monad_type := monad_tag` when `Some`.
  This means `pure` dispatches correctly for any Thenable type before
  the first `DoBind` is evaluated, without the `detect_monad` heuristic.
  `detect_monad` and the VList / VCon dispatch checks are kept as
  fallback for the `None` (still-polymorphic) case.
- Round-trip safety: `strip_locs_expr` resets the tag to `ref None`;
  OCaml's `=` compares ref contents by value, so `ref None = ref None`
  is true and structural equality in test comparisons is preserved.
- All passes updated: `parser.mly`, `printer.ml`, `resolve.ml`,
  `desugar.ml`, `coverage.ml`, `test/test_parser.ml`.
- All 798 base tests and 389 thorough tests pass.

### Phase 54: `<Mut>` inference from `let mut` ✅ DONE

`DoAssign` and `DoFieldAssign` in do-blocks now emit `["Mut"]` in
`do_stmt_effects`, so any function containing `x = e` or `r.field = e`
assignment to a `let mut` binding has `<Mut>` inferred.  Previously only
direct calls to `set_ref` added the effect via `eff_env`.

**What was added:**
- Two-line change in `do_stmt_effects` (`typecheck.ml`): `DoAssign`
  and `DoFieldAssign` now call `effect_union ["Mut"] (go bound e)`.
- Six existing positive tests in `test_typecheck.ml` updated to carry
  explicit `<Mut>` annotations (previously they accidentally passed
  because the mutation was invisible to the effect checker).
- Four new tests in `thorough_typecheck.ml` "effects" suite: error when
  `DoAssign` used without annotation, acceptance when annotated, same
  for `DoFieldAssign`, and combined `<IO, Mut>` annotation.

### Phase 55: `let mut` reassignment outside `do`-blocks ✅ DONE

`let mut x = 0 in body` (inline expression form) is now rejected by
the type-checker with `MutLetOutsideDo`.  `DoLet(true, ...)` inside
do-blocks is unchanged.

**What was added.**
- `MutLetOutsideDo of ident` error variant in `typecheck.ml`;
  `pp_error` message: `"'let mut x' can only be used inside a
  do-block (no syntax to reassign outside one)"`.
- Guard at the top of the `ELet(mut=true, ...)` case in `infer`:
  raises `Type_error(MutLetOutsideDo name, !current_loc)` immediately.
  The parser still emits `ELet(true, ...)` for `let mut … in …`;
  the type-checker is the enforcer.
- 4 new typecheck tests: `err: let mut outside do`,
  `err: let mut inline expr`, `err: let mut with annot`,
  `let mut in do still ok`. **877 tests total (base suites).**

### Phase 55.5: Split `EDo` into `EBlock` + `EDo` ✅ DONE

Phase 45.5 disambiguated monadic vs sequential bodies *inside one node*
by branching on whether any stmt is a `DoBind`.  That worked, but the
single-node approach silently conflated two different concepts: the
language design says do-notation is for monadic abstraction (Option /
Result / Async / user monads), and procedural sequencing of effects is
a separate thing handled by the effect system.  Every multi-stmt
indented body (function body, if/else branch, match arm) lowered to
`EDo`, so a reader had to scan for `<-` to know which mode applied.

Split the node:

- **`EBlock of do_stmt list`** — bare indented blocks.  Allowed:
  `let`, `let mut`, expr stmts, `x = e` reassignment, `x.f = e` field
  assignment, `let else`.  Forbidden: `<-` bind.
- **`EDo of … * do_stmt list`** — monadic, introduced only by the
  `do` keyword.  Allowed: `let` (no `mut`), `<-` binds, expr stmts
  (each must unify to `m a`), `let else`.  Forbidden: `let mut`,
  reassignment, field assignment.

The parser's `stmts_to_expr` helper now produces `EBlock`; only the
explicit `DO INDENT … DEDENT` rule produces `EDo`.  The typechecker's
`EDo` handler no longer dispatches on `has_bind` — it always
introduces a monad tyvar `m` and unifies every expr stmt with `m a`.
`EBlock` runs the sequential path with no monad constraint.

The breaking change is small: any existing code with `<-` inside an
implicit-block branch body (e.g. `if cond then\n  x <- foo\n  pure x`)
now requires `then do\n  x <- foo\n  pure x`.

**Errors added** (all structured, all live in `typecheck.ml`):
- `MutLetInDo` — `let mut` inside a `do` block.
- `BindOutsideDo` — `<-` outside a `do` block.
- `AssignInDo` — `x = e` reassignment inside a `do` block.
- `FieldAssignInDo` — `x.f = e` inside a `do` block.
- `MutLetRequiresBlock` — `let mut` in inline `let … in …` position
  (replaces the old `MutLetOutsideDo` from Phase 55; that name no
  longer fits since `let mut` is now valid in `EBlock`, not in `EDo`).

**Other touched files.** `ast.ml`, `parser.mly`, `printer.ml`,
`desugar.ml`, `eval.ml`, `resolve.ml`, `coverage.ml`,
`test/test_typecheck.ml`, plus `language-design.md` (Do Notation
section rewritten, mutability section noted, Async/Result examples
updated to use `do`).

**Note on Phase 45.5.** That phase introduced the `has_bind` split
inside a single `EDo`.  Phase 55.5 supersedes that mechanism by moving
the distinction up into separate AST nodes — `EDo` now has only one
mode (monadic).  The Phase 45.5 motivating cases (indented function
bodies, effectful `do` sequencing without `<-`) still work: the first
is now `EBlock`, and the second is still allowed in `EDo` because a
`do` block with all expr stmts and no binds is legal (each stmt
unifies to `m a` for the inferred `m`).

**Tests.** Existing typecheck tests for `let mut` / assignment / field
assignment updated to use bare-block form; new error tests
`e_let_mut_in_do`, `e_assign_in_do`, `e_bind_outside_do`,
`e_do_seq_no_bind_now_fails`, and a `t_mixed_block_with_inner_do`
covering the legal mixed case (outer `EBlock` with `let mut`,
inner `EDo` for monadic chaining).  All 787 base-suite tests pass.

### Phase 56: Multi-level nested record updates ✅ DONE

**What was found.** The `desugar_dotted_field` helper added in Phase 45
(`lib/parser.mly` lines 27–37) already handles arbitrarily deep dotted
paths recursively — `{ p | a.b.c = v }` desugars to
`{ p | a = { p.a | b = { p.a.b | c = v } } }` at parse time.  A parser
test (`test_expr_record_update_nested_deep`) already verified the AST
shape; end-to-end typecheck and eval coverage was the only gap.

**What was added.**
- `t_rec_update_multi_level` in `test/test_typecheck.ml` — verifies
  `{ p | address.country.code = "US" }` type-checks to `Person -> Person`
  for a 3-level deep record hierarchy.
- `t_record_update_nested_deep` in `test/test_eval.ml` — builds a
  3-level record (`Person → Address → Country`), updates
  `address.country.code`, and asserts the new value is read back correctly.

**879 tests total** (up from 877).

### Phase 57: `let rec` for value and mutually-recursive bindings ✅ DONE

Added explicit `let rec ... with ...` syntax for value recursion and
mutual recursion, at both the top level and inline.  Reuses the
existing `ELetGroup` machinery for inline forms and adds a new
`DLetGroup` decl for top-level mutual groups.

- `let f x = e` (no `rec`) keeps Phase 27's implicit self-recursion.
- `let x = e` (no `rec`, no args) stays non-recursive.  When the RHS
  references the bound name, the resolver emits a targeted
  `NonRecursiveValueLet` diagnostic suggesting `let rec`.
- `let rec` with a zero-argument clause requires a lambda RHS at
  type-check time (`LetRecNonFunction`).  This is stricter than
  OCaml's "syntactic value" rule because Medaka's strict evaluator
  has no support for cyclic data — `let rec ones = 1 :: ones` would
  silently produce `Cons(1, Unit)` rather than diverge or loop.
- `with` was reclaimed as a binding-group separator (previously
  unused).  `and` was deliberately avoided since it's an existing
  stdlib function for short-circuit-free boolean conjunction.

Inline form is single-line; multi-line mutual recursion uses the
top-level form (the layout-sensitive lexer makes `LET REC ... newlines
WITH ... newlines IN ...` clash with the existing single-line shape
in LALR(1)).

### Phase 58: List comprehension `pat <- xs` should filter ✅ DONE

In Haskell, `[x | Just x <- xs]` silently skips `Nothing` values.
In Medaka today, the same expression panics on the first non-
matching element with "non-exhaustive match" (the `pat => body`
desugars to `andThen xs (pat => body)`, and the lambda's pattern
match failure propagates).

Fix: desugar `pat <- xs` in list comps to a filter step before the
bind, when `pat` is refutable.  Roughly:
`[body | pat <- xs]` for refutable `pat` ↦
  `[body | x <- xs, isMatch pat x, let pat = x]`
…where `isMatch` is generated from `pat`.

Or use `match` inside the lambda with a `Nothing → []` arm.

**Implemented** in `lib/desugar.ml`: added `is_refutable` and updated
`desugar_list_comp` to wrap refutable `LCGen` patterns in an
`EMatch` with a `PWild => []` fallback arm.  Non-refutable patterns
(`PVar`, `PWild`, irrefutable `PTuple`) use the original direct lambda.

### Phase 59: Small parser/lexer gaps ✅ DONE

A grab-bag of small grammar holes closed in one pass:

- **Tuple field access `p.0`, `p.1`** ✅ **Decision: not supported.**
  Use `let (x, y) = p` pattern destructuring.  Adding positional
  access would require a non-trivial lexer change to distinguish
  `.0` from a float literal component; deferred to the self-hosted
  compiler where the lexer is written in Medaka.
- **Triple-quoted string interpolation** ✅ **Fixed** (`lib/lexer.mll`).
  Added `interp_in_triple` flag; `read_triple_string` now emits
  `INTERP_OPEN` on `\{`; `read_interp_triple_continue` handles the
  continuation (terminates on `"""`).  Tests in `test_eval.ml`.
- **DoBind LHS cannot be cons or literal pattern** ✅ **Documented.**
  Known grammar R/R conflict; see `parser.mly` lines 210–232.
  Workaround: bind to a variable and match separately.
- **Last stmt of do-block can't start with an uppercase ctor** ✅
  **Documented.**  S/R conflict; see `parser.mly` lines 196–206.
  Workaround: wrap in `pure (Some x)`.
- **Int literal max** ✅ **Fixed** (`lib/lexer.mll`).  `parse_int`
  helper replaces bare `int_of_string`; emits a clear error naming
  the literal and `max_int = 4611686018427387903`.  Test in
  `test_eval.ml`.
- **`pub` only on `use`** ✅ **Already resolved** (Phase 40 renamed
  `pub` → `export`).  The parser accepts `export` on all declaration
  types (`inner_data_or_record` and `inner_non_data_decl`).
- **`+.` / `-.` / `*.` / `/.` are dead code** ✅ **Already pruned.**
  No such operator strings exist in `eval_arith`; `+`/`-`/`*`/`/`
  dispatch on value type since Phase 17.
- **`(- 1)` is unary minus, not a section** ✅ **Documented.**
  Same as Haskell.  Provide `(subtract 1)` if a section is desired.
- **Negative range patterns with parens** ✅ **Deferred.**  Low
  priority; the parenthesized form `(-1)` needs a separate rule;
  won't fix for the OCaml-hosted compiler.
- **Paren-suppressed `do INDENT … DEDENT`** ✅ **Won't fix** for
  OCaml-hosted compiler.  See Phase 45.8 design limitation.  Could
  be revisited with a stateful lexer in the self-hosted compiler.

### Phase 60: Pre-self-host parser-conflict audit ⏳ TODO

Before reimplementing the parser in Medaka, walk through every
shift/reduce and reduce/reduce conflict in `lib/parser.conflicts`
and confirm Menhir's default resolution is what we actually want.
Each conflict is currently documented in `lib/parser.mly`
headnotes; this is the moment to re-validate, because a hand-
written parser must make each decision explicitly.

Output: a checklist alongside the existing conflict documentation,
mapping each Menhir conflict to its intended behavior, so the
Medaka-hosted parser can reproduce it without surprises.

The 8+8 conflict count itself goes to zero after self-hosting
because a Pratt-style or PEG parser has no "conflicts" — every
disambiguation is an explicit line of code.  Phase 60 ensures
those explicit lines say the right thing.

---

## 4. Smaller cleanups (good warm-up tasks)

See Phase 8.6 above for the consolidated housekeeping list. After the backend
phases land, revisit the limitations in Section 5 — most of them turn into
concrete work once real programs are running through the interpreter.

## 5. Known limitations to keep in mind

These aren't blockers, but a less-careful change could trip over them:

- do-block monad dispatch in `eval.ml` is a runtime heuristic: the monad is
  detected by inspecting the first `DoBind` result's constructor shape. This
  means (a) `pure` in a do-block with no `<-` statements returns the value
  unwrapped (monad context unknown); (b) ~~the List monad is not supported~~
  (FIXED in this session — VList now dispatches via Thenable and detect_monad
  recognizes VList → "List", so do-block list-monad concat-map semantics work);
  (c) higher-order functions that receive do-blocks don't thread monad context.
  The clean fix is a type-annotated AST: after type-checking, tag `EDo` with
  its resolved monad so `eval` doesn't need to guess. Deferred until Phase 11
  or later forces the issue.
- `let mut` binding reassignment (`DoAssign`) is now type-checked in do-blocks,
  but `ELet(true, ...)` in expression context only tracks `mut_vars` — there is
  no syntax for reassigning a `let mut` binding outside a do-block. The `Ref`
  type is fully type-checked; actual mutation happens at runtime (Phase 10 ✅).
- `r.value = expr` field-assignment is supported via `DoFieldAssign` in do-blocks
  (Phase 28 ✅). Multi-level chains (`a.b.c = e`) are not yet supported — only
  single-level `x.field = e` where `x` is a `let mut` binding.
- `let f x = ...` is implicitly self-recursive (Phase 27 ✅). `let x = expr`
  (no arguments) is still non-recursive. `where`-helpers use `ELetGroup` for
  mutual recursion (Phase 25 ✅).
- Primitive values (`pure`, `print`, `map`, …) now live exclusively in
  `lib/runtime.ml` (Phase 9 ✅). Primitive types (`List`, `Option`, …) are
  still hard-coded in `resolve.ml`/`typecheck.ml` until the stdlib lands.
- `EUnOp "-"` only types as `Int -> Int`. Float negation isn't supported.
- `==`/`!=` accept any two values of the same type (already polymorphic via
  `unify tl tr`). An `Eq` constraint is not yet checked — deferred until
  `impl Eq (List a)`, `impl Eq (Option a)` etc. can be registered so
  existing code doesn't break.
- `<`/`>`/`<=`/`>=` now use `Ord` constraint (Phase 17 ✅). Int, Float,
  String, and Char are the registered built-in impls.
- Arithmetic ops (`+`, `-`, `*`, `/`) now use `Num` constraint (Phase 17 ✅).
  Int and Float are the registered built-in impls.
- Effects: `TFun` now carries an `effect_set` slot (Phase 29 ✅); higher-order
  call sites that pass a named effectful function are tracked.  Effect
  inference for unannotated HOFs (effect-polymorphic `map`) still requires
  effect variables, which is not implemented.
- `@Name` impl-disambiguation hints now select a specific impl at runtime
  (Phase 30 ✅) and are validated at compile time (Phase 32 ✅):
  named impls must exist and `@Name` selects among multiple matching impls.
  At runtime the VMulti is filtered by name; full dictionary-passing (for
  higher-order use) is deferred.
- DoBind LHS cannot be a cons (`x::xs <- list`) or literal pattern — grammar
  limitation documented in `parser.mly`.
- The last statement of a do-block cannot start with an uppercase identifier
  (`Some x` etc.) — wrap in `pure (...)`. Same grammar root cause.
- Module system: `use` declarations parse but no cross-file resolution
  exists. Backend roadmap is single-file only; multi-file support is a
  separate later phase.
- Standard library: nothing is implemented in Medaka yet. Once the
  interpreter runs (Phase 10–11) the existing collection types (`List`,
  `Array`, `Map`, etc.) can begin to migrate from compiler-side primitives
  into Medaka source on top of `extern`.

### Additional gaps surfaced during the 2026-05-24 audit

These are not currently scheduled inside any DONE phase; they each map to
a phase in §6 unless noted.

- **`pub` only on `use`.** The parser accepts `pub` exclusively as the
  prefix to a `use` decl (for re-exports). It is not accepted on
  `data` / `record` / `interface` / `impl` / `fun_def` / `extern`. Per the
  design doc, privacy is per-binding with `pub` opt-in — so right now every
  top-level item would be effectively private once a real module system
  exists. Fix scheduled in Phase 14.
- **`use` decls are semantic no-ops.** `Resolve.build_env` adds the
  imported leaf name to `env.values` *and* `env.types` (since it can't
  tell which) but the typechecker has nothing for `DUse` and the evaluator
  also ignores it. Cross-file resolution does not exist; the driver only
  accepts one file. Fix in Phase 14.
- **No qualified module access.** `utils.greet` parses as
  `EFieldAccess (EVar "utils", "greet")` and fails at typecheck because
  `utils` has no record type. The typechecker needs a special case (or
  the resolver needs to rewrite the AST) once modules are real. Phase 14.
- **`runtime.ml` should be `runtime.mdk`.** Design doc §Runtime
  Primitives & Abstraction Layer is explicit: the catalog of externs
  should be Medaka source backed by OCaml implementations, not OCaml
  source that mirrors what an extern decl would say. Phase 18.
- **`<Mut>` not inferred from `let mut` use.** Design says any function
  touching a `let mut` binding picks up `<Mut>`. Today only direct calls
  to extern `set_ref` add it via the `eff_env` path. Phase 29 added the
  TFun effect slot the design relied on; the `let mut` propagation is now
  a smaller follow-on to wire `let mut` references through the new slot.
- **Multiline string indentation stripping.** ✅ Phase 16 done.
- **`Char` accepts multi-byte UTF-8.** ✅ Phase 16 done (byte sequence, not
  validated grapheme cluster; segmentation library deferred to stdlib).
- **`\r`, `\0`, `\u{XXXX}` string escapes.** ✅ Phase 16 done.
- **`Map { ... => ... }` and `Set { ... }` literal syntax.** ✅ Phase 16 done.
  Runtime representation (`Map.fromList`/`Set.fromList`) awaits stdlib.
- **`%` modulo.** ✅ Phase 17 done. Lexer token `MOD`, parser rule, Int-only.
- **`+.` / `-.` / `*.` / `/.` in `eval_arith`.** Now dead code (Phase 17
  made `+`/`-`/`*`/`/` dispatch on value type, so `+.` etc. can never be
  emitted). Harmless; can be pruned in a later housekeeping pass.
- **Tree-sitter grammar absent.** Design doc Phase 1 calls for it in
  parallel with the compiler. Phase 15.
- **CLI surface is minimal.** The design specifies `medaka new`, `build`,
  `run --release`, `check --json`, `test`, `fmt`, `lsp`, `add`, `remove`,
  `update`, `doc` — today only `check`, `run`, `repl` exist. Each is its
  own follow-up phase post-stdlib; not blockers.
- **No `medaka.toml` / `medaka.lock`.** Project config doesn't exist yet
  because single-file is still the contract. Post-Phase 14.
- **REPL: `:load`, `:reload`, `:browse` now implemented.** ✅ Phase 13 done.
- **Record field assignment `p.field = e`.** ✅ Phase 28 done. Single-level
  `x.field = e` in do-blocks for `let mut` records and `Ref .value`.
- **`Eq`, `Num`, and `Ord` stdlib interfaces disconnected from built-in operator constraints.**
  `==`/`!=` unify both sides and return `Bool` with no interface lookup — `deriving (Eq)`
  generates an impl with `eq`/`neq` that is never called by those operators.
  `+`/`-`/`*`/`/` check a synthetic `__num__` witness and `<`/`>`/`<=`/`>=` check
  `__ord__`, both seeded in `seed_builtin_interfaces` with hardcoded impls for
  `Int`/`Float` (Num) and `Int`/`Float`/`String`/`Char` (Ord). These are entirely
  separate from any `interface Num`/`interface Ord` defined in `core.mdk` — the
  typechecker does not connect the two. `core.mdk` does not yet define `Num` at all.
  User-defined `impl Num MyType` or `impl Ord MyType` will not make the operators
  work on `MyType`, and `deriving (Ord)` generates an impl for the user-land `Ord`
  that the `<`/`>` operators will not consult. `deriving (Show)` is unaffected —
  `show` is a plain method call with no operator magic. All three wiring problems
  are resolved together in Phase 19 stdlib/typeclass wiring.
- **`do`-notation is not wired to `Thenable`.** The typechecker handles `do`
  structurally: each `<-` line just unifies its expression against `m a` for a
  fresh `m` typevar. It never looks up or calls `andThen`. This means do-notation
  works on any type that fits `m a` structurally, but `Thenable` in `core.mdk` is
  inert — deleting it would not break anything. To make the interface load-bearing,
  `<-` should desugar to `andThen` calls (Haskell style) so the `Thenable`
  constraint is actually checked. Scheduled with Phase 19 stdlib/typeclass wiring.
- **Constraint syntax in function type signatures.** ✅ Phase 20 done. `f : Eq a => a -> a -> Bool` now parses, round-trips, and type-checks. Constraint obligations are emitted at call sites and verified post-HM. Known limitation: constraint inference is not implemented — callers that use a constrained function polymorphically must also carry the explicit constraint annotation.

### Additional gaps surfaced during the 2026-05-26 audit

- **Triple-quoted strings don't support `\{...}` interpolation.** The
  `read_triple_string` lexer rule has no `\\' '{'` branch, so any `\{expr}`
  inside a `"""..."""` string is emitted as a literal `\{expr}`.  Easy fix:
  extend `read_triple_string` with the same INTERP_OPEN logic
  `read_string` uses.  Scheduled as a small follow-up to Phase 23.
- **Float unary negation rejected by the type checker.** `EUnOp "-"` unifies
  its argument with `t_int`, so `-3.14` is a type error and `let f = -x` for
  `x : Float` is too.  The evaluator already does the right thing on `VFloat`
  values; the fix is to lift the type rule to a `Num a` constraint so
  negation works for any `Num` impl.  Scheduled with Phase 17 follow-ups.
- **Single-file `check core.mdk` formerly produced duplicate-declaration
  errors.** Fixed in the 2026-05-26 audit by detecting `program_is_core`
  (presence of `data Ordering` + `interface Foldable`) and skipping the
  prelude prepend in that case.  Same fix applied to `Resolve.create_env`
  and to `Loader.direct_imports` (which now ignores `import core.{...}`).
- **`EUnOp "!"` panicked at runtime.** The parser emits `EUnOp ("!", _)`
  and the typechecker handles it, but the evaluator only handled
  `EUnOp ("not", _)`.  Fixed in the 2026-05-26 audit.
- **Tree-sitter grammar lives at the project root** (`tree-sitter-medaka/`)
  rather than `tree-sitter/` as the original phase wrote.  README and PLAN
  both reflect the actual path now.

---

## 7. Syntactic sugar gap analysis (vs. Haskell)

Features Haskell has that Medaka currently lacks, split by priority.
This was assembled after reviewing `lib/parser.mly`, `lib/ast.ml`,
`language-design.md`, and the test suite (2026-05-25).

### Must-have

| Feature | Description | Notes |
|---------|-------------|-------|
| **Where clauses** | `f x = body where helper y = …` — local helper definitions at the bottom of a binding | ✅ Phase 25 done. Mutual recursion via `ELetGroup`; `where` supported on function bodies and match-arm bodies. |
| **Type aliases** | `type Name = String`, `type Parser a = String -> Option (a, String)` | No way to name a type synonym today. Needed for readable API signatures in the stdlib. |
| **Newtype declarations** | `newtype UserId = UserId Int` — zero-cost wrapper for type safety | `deriving` infrastructure is already there; relatviely cheap to add. Blocks domain-modelling patterns. |
| **As-patterns** | `f all@(x::xs) = …` — name the whole value and destructure simultaneously | Without this, you have to manually reconstruct the matched value. Comes up constantly in list/tree recursion. |
| **Record field punning** | `{ name }` as shorthand for `{ name = name }` in record creation and patterns | Without it, records with many fields produce very verbose code. |
| **Left operator sections** | `(e op _)` means `\x -> e op x` | ✅ Phase 24 done. Syntax uses `_` placeholder: `map (2 * _) xs`, `filter (0 < _) xs`. Haskell-style `(2*)` not feasible in LALR(1). |
| **Multiline string / heredoc** | Formal `"""…"""` or backslash-newline string continuation | Medaka already strips leading newlines from strings that start with `\n`; formalising a `"""` delimiter would make embedding source/templates much cleaner. |

### Nice-to-have / maybe

| Feature | Description | Notes |
|---------|-------------|-------|
| **Top-level function guards** | Guards directly on equation heads: `classify n \| n < 0 = "neg" \| otherwise = "pos"` | Medaka supports guards inside `match` arms. This form is sugar over `match` but reads more naturally for numeric/boolean logic. |
| **List comprehensions** | `[x*2 \| x <- xs, x > 0]` | Expressible via `map`/`filter`/`concatMap`; nice to have for readability. Not blocking anything. |
| **String interpolation** | `"Hello, \{name}!"` | ✅ Phase 23 done. `\{expr}` syntax; embedded expr must be `String` (use `show` explicitly for other types). |
| **`otherwise` alias** | `otherwise = True` so guard chains have a named catch-all | Trivial to add as a stdlib `extern`-free binding; purely cosmetic. |
| **Constraint syntax in type signatures** | `f : Eq a => a -> a -> Bool` | ✅ Phase 20 done. |
| **Numeric literal extensions** | `0xFF`, `0b1010`, `1_000_000` underscores | ✅ Done. Lexer-only change: hex (`0x`), binary (`0b`), octal (`0o`), and underscore separators in int and float literals. 16 new tests. |
| **Custom symbolic operators** | `(<\|>) = …` user-defined infix symbols | Medaka intentionally restricts operators; backtick infix is the approved escape hatch. Worth revisiting if DSL users push on it. |
| **Tuple sections** | `(,3)` or `(1,)` to partially apply tuple constructors | Niche; explicit lambdas are fine. |
| **Lazy / irrefutable patterns** | `~pat` defers matching | Rarely useful in a strict language; probably not worth the complexity. |

---

## 8. Cross-language sugar / features (vs. OCaml, F#, Rust, Elm, Clojure)

Compiled from the 2026-05-26 design review. Committed entries are
linked to phases above; rejected ones are listed so the rejection
stays intentional.

### Committed (Phase 37–45, 46–50)

| Feature | Source | Phase |
|---------|--------|-------|
| **`?` postfix for `Result`/`Option`** | Rust | Phase 37 |
| **`if let` and `let else`** | Rust, Swift | Phase 38 ✅ |
| **Variants with named fields** | Rust, Swift, OCaml | Phase 39 |
| **Range literals (`1..10`, `1..=10`)** | Rust, Kotlin | Phase 40 |
| **Doctests** | Rust, Elixir | Phase 41 |
| **Property testing + `Arbitrary`** | QuickCheck, Hypothesis | Phase 42 |
| **Abstract type exports (`public export`)** | Idris, Elm, OCaml | Phase 43 |
| **`function` keyword** | OCaml | Phase 44 |
| **Nested record update sugar** | F# `with` precedent | Phase 45 |
| **Snapshot tests** | Jest, insta | Phase 46 |
| **Coverage (`--coverage`)** | Rust, Go | Phase 47 |
| **`medaka bench`** | Rust | Phase 48 |
| **Declaration attributes** | Rust | Phase 49 |
| **Workspaces in `medaka.toml`** | Cargo | Phase 50 |

### Rejected (with reason)

| Feature | Source | Why no |
|---------|--------|--------|
| Labeled / named arguments | OCaml, F#, Swift | Real complexity in call resolution and partial application; records are the chosen idiom for clarity |
| Active patterns | F# | Complicates pattern matching and exhaustiveness; "elegant but theoretical" — the kind of thing the design filter is meant to catch |
| Computation expressions | F# | Generalises `do` into something only library authors understand; too magical |
| Custom literal sigils (`~D"…"`, `~r"…"`) | Clojure, Elixir | Conflicts with "named functions over special syntax" |
| Polymorphic variants | OCaml | Inference complexity; duplicates ADTs without earning it |
| First-class modules / functors | OCaml | Already rejected in `language-design.md` |
| Row polymorphism / extensible records | PureScript, Elm | Significant inference cost; nominal records are deliberate |
| Units of measure | F# | Niche; would need to permeate the `Num` interface |
| Multimethods / value dispatch | Clojure | Conflicts with HM inference; resolution model unclear |
| Macros / reader macros | Lisp family | Conflicts with "one language, no extensions" |
| Lazy sequences (`seq { … }`) | F#, Clojure | Conflicts with strict-by-default evaluation |
| Pin operator `^x` | Elixir | Solves a problem Medaka doesn't have (no implicit rebinding-in-pattern) |
| Custom symbolic operators | ML family | Explicitly rejected — backtick infix is the escape hatch |
| Higher-rank polymorphism | Haskell `RankNTypes` | Damages inference, violates "no extensions" |
