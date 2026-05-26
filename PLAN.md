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

511 tests pass across 7 test suites:

| Suite             | File                            | Cases | Coverage                                              |
|-------------------|---------------------------------|-------|-------------------------------------------------------|
| Parser            | `test/test_parser.ml`           | 92    | AST shape for each construct                          |
| Round-trip        | `test/test_roundtrip.ml`        | 73    | parse → print → parse yields the same AST             |
| Resolver          | `test/test_resolve.ml`          | 55    | Unbound vars, unknown types/ctors, duplicates, fields |
| Type checker      | `test/test_typecheck.ml`        | 208   | Inferred types, type errors, exhaustiveness warnings  |
| Evaluator         | `test/test_eval.ml`             | 64    | Runtime values, recursion, do-blocks, Ref, errors     |
| Run               | `test/test_run.ml`              | 8     | Stdout capture, factorial, ADT match, do-block, Ref, panic |
| REPL              | `test/test_repl.ml`             | 11    | process_item, :load atomicity, rollback, :browse      |

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
- `==`/`!=` accept any two values of the same type (already polymorphic via
  `unify tl tr`). An `Eq` constraint is not yet checked — deferred until
  `impl Eq (List a)`, `impl Eq (Option a)` etc. can be registered so
  existing code doesn't break.
- `<`/`>`/`<=`/`>=` now use `Ord` constraint (Phase 17 ✅). Int, Float,
  String, and Char are the registered built-in impls.
- Arithmetic ops (`+`, `-`, `*`, `/`) now use `Num` constraint (Phase 17 ✅).
  Int and Float are the registered built-in impls.
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
  to extern `set_ref` add it via the `eff_env` path. The merge of effects
  into `TFun` (already noted) is the right place to fix this too.
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
- **Record field assignment `p.field = e`.** Design says mutable records
  support `p.age = 31` directly; today the only form is `{ p | age = 31 }`
  for the immutable update and `set_ref`-via-`Ref` for the mutable cell
  case. Not on the critical path; revisit after stdlib forces the issue.
- **`r.value = e` field-assignment on `Ref`.** Same family as above; use
  `set_ref` for now.
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

---

## 7. Syntactic sugar gap analysis (vs. Haskell)

Features Haskell has that Medaka currently lacks, split by priority.
This was assembled after reviewing `lib/parser.mly`, `lib/ast.ml`,
`language-design.md`, and the test suite (2026-05-25).

### Must-have

| Feature | Description | Notes |
|---------|-------------|-------|
| **Where clauses** | `f x = body where helper y = …` — local helper definitions at the bottom of a binding | Without this, all locals must be chained `let … in`, which can't express mutually-recursive helpers. High-value ergonomic win. |
| **Type aliases** | `type Name = String`, `type Parser a = String -> Option (a, String)` | No way to name a type synonym today. Needed for readable API signatures in the stdlib. |
| **Newtype declarations** | `newtype UserId = UserId Int` — zero-cost wrapper for type safety | `deriving` infrastructure is already there; relatviely cheap to add. Blocks domain-modelling patterns. |
| **As-patterns** | `f all@(x::xs) = …` — name the whole value and destructure simultaneously | Without this, you have to manually reconstruct the matched value. Comes up constantly in list/tree recursion. |
| **Record field punning** | `{ name }` as shorthand for `{ name = name }` in record creation and patterns | Without it, records with many fields produce very verbose code. |
| **Left operator sections** | `(3-)` means `\x -> 3 - x` | Medaka has right sections already. Left sections are common: `map (2*) xs`, `filter (0<) xs`. |
| **Multiline string / heredoc** | Formal `"""…"""` or backslash-newline string continuation | Medaka already strips leading newlines from strings that start with `\n`; formalising a `"""` delimiter would make embedding source/templates much cleaner. |

### Nice-to-have / maybe

| Feature | Description | Notes |
|---------|-------------|-------|
| **Top-level function guards** | Guards directly on equation heads: `classify n \| n < 0 = "neg" \| otherwise = "pos"` | Medaka supports guards inside `match` arms. This form is sugar over `match` but reads more naturally for numeric/boolean logic. |
| **List comprehensions** | `[x*2 \| x <- xs, x > 0]` | Expressible via `map`/`filter`/`concatMap`; nice to have for readability. Not blocking anything. |
| **String interpolation** | `"Hello, \{name}!"` | ✅ Phase 23 done. `\{expr}` syntax; embedded expr must be `String` (use `show` explicitly for other types). |
| **`otherwise` alias** | `otherwise = True` so guard chains have a named catch-all | Trivial to add as a stdlib `extern`-free binding; purely cosmetic. |
| **Constraint syntax in type signatures** | `f : Eq a => a -> a -> Bool` | ✅ Phase 20 done. |
| **Numeric literal extensions** | `0xFF`, `0b1010`, `1_000_000` underscores | `0x` hex and `_` separators are the most practically useful additions. |
| **Custom symbolic operators** | `(<\|>) = …` user-defined infix symbols | Medaka intentionally restricts operators; backtick infix is the approved escape hatch. Worth revisiting if DSL users push on it. |
| **Tuple sections** | `(,3)` or `(1,)` to partially apply tuple constructors | Niche; explicit lambdas are fine. |
| **Lazy / irrefutable patterns** | `~pat` defers matching | Rarely useful in a strict language; probably not worth the complexity. |
