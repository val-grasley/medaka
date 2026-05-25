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

342 tests pass across 6 test suites:

| Suite             | File                            | Cases | Coverage                                              |
|-------------------|---------------------------------|-------|-------------------------------------------------------|
| Parser            | `test/test_parser.ml`           | 53    | AST shape for each construct                          |
| Round-trip        | `test/test_roundtrip.ml`        | 54    | parse → print → parse yields the same AST             |
| Resolver          | `test/test_resolve.ml`          | 40    | Unbound vars, unknown types/ctors, duplicates, fields |
| Type checker      | `test/test_typecheck.ml`        | 148   | Inferred types, type errors, exhaustiveness warnings  |
| Evaluator         | `test/test_eval.ml`             | 41    | Runtime values, recursion, do-blocks, Ref, errors     |
| Run               | `test/test_run.ml`              | 6     | Stdout capture, factorial, ADT match, do-block, Ref, panic |

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

Menhir reports ~13 shift/reduce + ~20 reduce/reduce conflicts. They are all
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
`DoBind`, `r.value = e` field assignment, local recursion. These are revisited
once the stdlib forces real use cases.

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
- A blessed `runtime.med` (or equivalent in-OCaml table) replaces the
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
- `main` is exempt from the effect-purity check in `typecheck.ml` (it is the
  program's entry point and is expected to call IO-effectful functions).
- `test/test_run.ml` — 6 tests: hello world, factorial (recursion), ADT
  match, multi-print do-block, let-mut reassignment, non-exhaustive match panic.
- `test/dune` updated to include `test_run`.

### Phase 12: REPL ⬅ NEXT

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

## 4. Smaller cleanups (good warm-up tasks)

See Phase 8.6 above for the consolidated housekeeping list. After the backend
phases land, revisit the limitations in Section 5 — most of them turn into
concrete work once real programs are running through the interpreter.

## 5. Known limitations to keep in mind

These aren't blockers, but a less-careful change could trip over them:

- do-block monad dispatch in `eval.ml` is a runtime heuristic: the monad is
  detected by inspecting the first `DoBind` result's constructor shape. This
  means (a) `pure` in a do-block with no `<-` statements returns the value
  unwrapped (monad context unknown); (b) the List monad is not supported; (c)
  higher-order functions that receive do-blocks don't thread monad context. The
  clean fix is a type-annotated AST: after type-checking, tag `EDo` with its
  resolved monad so `eval` doesn't need to guess. Deferred until Phase 11 or
  later forces the issue.
- `let mut` binding reassignment (`DoAssign`) is now type-checked in do-blocks,
  but `ELet(true, ...)` in expression context only tracks `mut_vars` — there is
  no syntax for reassigning a `let mut` binding outside a do-block. The `Ref`
  type is fully type-checked; actual mutation happens at runtime (Phase 10 ✅).
- `r.value = expr` field-assignment syntax for `Ref` is not yet supported.
  Use `set_ref r expr` instead.
- `let f x = ...` is purely sugar; the parser desugars to nested lambdas at
  parse time. There is no `let-rec` for locals; if you need local recursion,
  use a top-level def.
- Primitive values (`pure`, `print`, `map`, …) now live exclusively in
  `lib/runtime.ml` (Phase 9 ✅). Primitive types (`List`, `Option`, …) are
  still hard-coded in `resolve.ml`/`typecheck.ml` until the stdlib lands.
- `EUnOp "-"` only types as `Int -> Int`. Float negation isn't supported.
- All comparison ops (`==`, `<`, …) currently force `Int`. They should be
  polymorphic (`forall a. a -> a -> Bool` for `==`, ordered types for `<`)
  via `Eq`/`Ord` interfaces — deferred until interface instance resolution
  has real use cases (post-Phase 11).
- Arithmetic ops (`+`, `-`, `*`, `/`) likewise force `Int`. Will become
  `Num`-interface-dispatched in the same pass.
- Effects: tracked in a separate `eff_env`, not in `TFun`. Higher-order
  callbacks that *receive* an effectful function aren't tracked (Phase 3
  limitation). Real fix requires merging effects into `TFun`.
- `@Name` impl-disambiguation hints parse and type-check but do not actually
  select a specific impl at runtime; ambiguous impls are still rejected at
  check time. Selection is deferred to a post-backend pass.
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
