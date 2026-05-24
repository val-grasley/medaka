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

241 tests pass across 4 test suites:

| Suite             | File                            | Cases | Coverage                                              |
|-------------------|---------------------------------|-------|-------------------------------------------------------|
| Parser            | `test/test_parser.ml`           | 48    | AST shape for each construct                          |
| Round-trip        | `test/test_roundtrip.ml`        | 50    | parse → print → parse yields the same AST             |
| Resolver          | `test/test_resolve.ml`          | 34    | Unbound vars, unknown types/ctors, duplicates, fields |
| Type checker      | `test/test_typecheck.ml`        | 109   | Inferred types for valid programs + type-error cases  |

Two debug binaries in `test/` (not run as part of `dune test`):
- `debug.ml` — quick parse-and-print probe
- `tc_debug.ml` — quick type-check probe

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

When debugging a specific case, add a probe to `test/tc_debug.ml` (or
`test/debug.ml` for parser issues), build, and run that binary instead of
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

### Phase 5: Position-tracked errors

**Goal.** Every error message currently lacks source positions. Add line/column
to AST nodes; thread positions through the resolver and type checker.

**Implementation hint.** Wrap every AST node in `{ value : 'a; loc : loc }` or
add a `loc` field to each variant. Menhir auto-provides `$startpos`/`$endpos`
in actions — use those when constructing AST nodes. Update `pp_error` to print
positions. Update `bin/main.ml` to read source lines and show a snippet around
errors (Elm-style — it's a stated design goal).

This is a refactor more than a feature, but pays off forever.

### Phase 6: Exhaustiveness and usefulness checking

**Goal.** Warn when a `match` doesn't cover all cases; warn when an arm is
redundant.

**Algorithm.** Implement the pattern-matrix algorithm from Maranget's "Warnings
for pattern matching" (2007). It's not enormous but takes care to get right.
Add as a pass that runs after type checking (since it needs the data type's
constructor list).

### Phase 7: Audit parser conflicts

**Goal.** Bring the conflict count to zero or document each remaining one.

**Approach.**

1. Build with `-rebuild`, read `_build/default/lib/parser.conflicts`.
2. For each, decide: is the default resolution correct? If yes, document
   inline in `parser.mly` why. If no, restructure.

Some conflicts may be fundamental (e.g., dangling-else style); accept those.
Others may be accidental and removable.

### Phase 8: Driver / CLI

**Goal.** Make `medaka file.mdk` actually do something useful end-to-end:
parse, resolve, type-check, report errors with positions, optionally print
inferred types.

`bin/main.ml` currently only prints parsed declarations. Plug in the resolver
and type checker. Decide on a CLI surface (probably `medaka check file.mdk`,
later `medaka run`, `medaka build`).

### Phase 8.5: Mutation semantics and `Ref`

**Goal.** Implement the mutability model from `language-design.md` §"Mutability and Passing Values":

1. **Type checker — `let mut`:** bind the `mut` flag to the binding's assignability (not its type). Reassigning an immutable binding is a type error.
2. **Type checker — `Ref` type:** add `TRef of mono` to `mono`; add `Ref` as a built-in type constructor. `Ref e` constructs a `Ref T` when `e : T`. Field access `r.value` yields `T`. The type checker must propagate `<Mut>` on any expression that reads/writes through a `Ref`.
3. **Value/reference semantics:** primitives passed to functions are copied (already true in a tree-walking interpreter); `MutArray`/`HashMap`/`HashSet` are heap-allocated references (share identity by default). Document this in the eval pass.
4. **Effect enforcement:** a function that mutates a `Ref` but declares no `<Mut>` effect is a type error (reuse the existing effect-checking infrastructure from Phase 3).

**Order dependency:** do the type-checker pieces (steps 1–2, 4) before the backend (Phase 9) so the interpreter can assume `Ref` is well-typed by the time it evaluates it.

### Phase 9: Backend

**Goal.** Make Medaka programs actually run.

Per design doc, Phase 1 of the project is "interpret directly or transpile to
OCaml". Recommended start: a tree-walking interpreter (`lib/eval.ml`) that
operates on the typed AST. Fast to build, fine for testing the language design.

Don't optimise. Don't add a stdlib until the interpreter works on the existing
test programs.

## 4. Smaller cleanups (good warm-up tasks)

- **Remove debug helper `lib/typecheck.ml` no longer uses.** None right now,
  but keep an eye.
- **Move `tc_debug.ml` and `debug.ml` out of `test/` into a `dev/` directory.**
  They're not tests.
- **Add a `.editorconfig`.** Currently nothing enforces 2-space OCaml
  indentation.
- **Consider an `Eq`-deriving approach for AST equality** instead of OCaml's
  structural `=` — works fine now but will break if we add mutable bits
  (`TVar ref` already in `typecheck.ml`'s `mono`).

## 5. Known limitations to keep in mind

These aren't blockers, but a less-careful change could trip over them:

- `let mut` is parsed and the AST distinguishes it, but the type checker
  ignores the `mut` flag. Mutation is unimplemented. The `Ref` type (explicit
  mutable cell per `language-design.md` §"Mutability and Passing Values") is
  not yet in the AST, type checker, or runtime.
- `let f x = ...` is purely sugar; the parser desugars to nested lambdas at
  parse time. There is no `let-rec` for locals; if you need local recursion,
  use a top-level def.
- The resolver bakes in a list of "primitive values" (`pure`, `print`, `map`,
  …) and "primitive types" (`List`, `Option`, …). When the stdlib lands, those
  lists move out of `resolve.ml` and `typecheck.ml`'s `initial_env`.
- `EUnOp "-"` only types as `Int -> Int`. Float negation isn't supported.
- All comparison ops (`==`, `<`, …) currently force `Int`. They should be
  polymorphic (`forall a. a -> a -> Bool` for `==`, ordered types for `<`).
- Effects: parsed, AST-stored, but ignored by the type checker (see Phase 3).
