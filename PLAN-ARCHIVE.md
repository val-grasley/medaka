# Medaka — Plan Archive (Phases 1–97)

> **ARCHIVED 2026-06-02.** This is the historical roadmap covering Phases 1–97,
> retired once nearly everything in it was DONE. It is kept **for reference
> only** — the per-phase implementation notes ("What was added", "Where",
> file/line pointers) are useful when investigating how a feature was built.
> **Do not add new work here.** The forward-looking roadmap lives in
> [`PLAN.md`](./PLAN.md). Section numbers cited elsewhere in the codebase
> (e.g. "PLAN-ARCHIVE.md §2.9", "§5") point into this document.

The original framing follows, unchanged:

---

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
| Evaluator         | `test/test_eval.ml`             | 142   | Runtime values, recursion, do-blocks, Ref, errors, escapes, @Name dispatch, Generic `to_rep` |
| Run               | `test/test_run.ml`              | 6     | Stdout capture, factorial, ADT match, do-block, Ref, panic |
| REPL              | `test/test_repl.ml`             | 11    | process_item, :load atomicity, rollback, :browse, multi-line `where` block collection |
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

`typecheck.ml`'s `group_fundefs` coalesces clauses in first-appearance order,
then `order_groups_by_deps` reorders the groups into **dependency order** so a
group's non-cyclic callees are processed (and generalized) before it. We depend
on this so that when a def's body references another top-level name it sees the
*generalized scheme*, not a still-monomorphic placeholder. Don't switch to
`Hashtbl.fold` for the coalescing — its order is unspecified, and the dependency
reorder needs a deterministic base order.

Mutual recursion still works because all top-level names are pre-bound to
placeholder TVars at level 1 *before* processing begins. A forward reference
unifies with the placeholder; when the forward-referenced def is processed, its
placeholder is already pinned to a concrete shape.

**Why the reorder (not just source order).** A plain forward reference (caller
defined before a callee it does *not* recurse with) shares a live inference var
between the caller's body and the callee's monomorphic placeholder. Once the
caller is generalized and the callee is later unified against its own signature,
that shared var can be re-linked underneath the caller's already-generalized
scheme — silently monomorphizing a polymorphic HOF (`sortBy` pinned to a tuple
element type by an unrelated `sortOn`-style use, surfacing as `(a, b) vs Int` at
a *different* call site). Processing callees first means the caller instantiates
a real scheme and never shares the placeholder. Genuine mutual-recursion cycles
can't be linearized, so `order_groups_by_deps` (Tarjan SCC, dependencies-first)
keeps each cycle's members adjacent in source order — their placeholder-based
handling is unchanged. References are over-approximated (every
`EVar`/`EMethodRef`/`EDictApp` name, ignoring shadowing); a spurious edge only
merges groups into a larger SCC (falling back to the old behavior), never a
wrong type. Regression: `test_typecheck`'s "sig poly HOF not monomorphized by
later use".

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

**Design note — explicit `show` (superseded).** Originally each hole had to be a `String`, so users wrote `\{show age}` rather than have the type checker auto-insert `show`. **Revised:** a hole `\{e}` now desugars (in `lib/desugar.ml`, via `rewrite_sugar`) to `display e`, where `Display` is a dedicated display interface (Debug-vs-`Show` split) defined in `core.mdk`. `Display String`/`Char` do *not* quote; all other instances mirror `show` but recurse with `display`. User types get an instance via `deriving (Display)` (`derive_display_data`/`derive_display_record`; newtypes reuse the data deriver through a synthetic single-field variant in `derive_for_newtype`, giving tagged `Con x` rendering — `deriving (Show)`, `(Eq)`, and `(Ord)` on newtypes were added at the same time, since they share that machinery. `derive_eq_data` now omits its cross-constructor `(_, _) -> False` fallback for single-constructor types, where the same-constructor arm is already exhaustive — otherwise newtypes and single-variant `data` would warn redundant-arm). The lowering flows through the marker + dict-passing like any interface method, so the old `typecheck.ml`/`eval.ml` `EStringInterp` arms are now dead on the typed path (kept as a fallback; `resolve.ml`/`printer.ml` still use the node pre-desugar). A hole whose type has no `Display` instance is a type error — no silent fallback.

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

### Phase 42: Property testing (`prop` + `Arbitrary`) ✅ DONE (core + generators); interface-unification residual → Phase 101 (re-marked 2026-06-02)

`prop "name" (x : T) = ...` declares a property quantified over `T`,
generated automatically via an `Arbitrary` interface (derivable).
Shrinking is built in.

**Status (verified 2026-06-02): substantially implemented; the header was
stale.** The pipeline is all there:
- `PROP` lexer token, `DProp` AST node, parser rule — `prop` declarations parse.
- `Arbitrary a` interface in `core.mdk` (`arbitrary : Unit -> <Rand> a`,
  `shrink : a -> List a` with a default), plus built-in impls for `Int`,
  `Bool`, `Float`, `Char`, `String` and the `arbitraryList`/`arbitraryString`
  helpers.
- `deriving (Arbitrary)` — `lib/desugar.ml` `derive_arbitrary_data` /
  `derive_arbitrary_record` synthesise impls; eval registers `impl Arbitrary T`
  into `Eval.arbitrary_registry` so `prop_runner` can find them.
- `lib/prop_runner.ml` — random generation (`gen_for_type`), greedy shrinking
  (`shrink_loop`/`shrink_value`), up to 100 runs, prints the smallest shrunk
  counterexample. Wired into `medaka test` via `Prop_runner.run_all` in
  `bin/main.ml`. `prop` declarations are exercised in `stdlib/core.mdk` and
  `stdlib/list.mdk`.

**Generators completed (2026-06-02, structural-native approach):**
- `prop_runner.gen_for_type` now also generates **`Array a`** and **tuples**
  (`TyTuple`), with matching shrinking in `shrink_value` (halve an array; vary
  one tuple component at a time).
- **Parametric user types** (`Tree Int`, records, newtypes) generate
  *structurally*: `run_all` builds a `tydef` map from the program's
  `DData`/`DRecord`/`DNewtype` declarations, and `gen_for_type` peels the
  `TyApp` spine, binds the type's parameters to the concrete arguments
  (`subst_ty`), and recurses over each field's type. So `Tree Int` produces
  `Int` leaves and `Tree String` strings — no dictionary threading needed,
  because the runner does the type-argument substitution itself. Nullary user
  types with a hand-written impl still fall back to `arbitrary_registry`; an
  unbound type variable now fails with a clear message instead of
  mis-generating. All changes are self-contained in `lib/prop_runner.ml`.

**Residual → Phase 101 (the principled unification):**
- Generation/shrinking are still native OCaml in `gen_for_type`/`shrink_value`,
  so the `Arbitrary` interface's `arbitrary`/`shrink` methods aren't *called* by
  the runner for built-in or structurally-generated types. Driving everything
  through the Medaka-level interface (so a hand-written `arbitrary`/`shrink`
  wins, and element dictionaries flow into parametric instances via the
  dict-passed pipeline) is deferred — it intersects the Phase 83/84
  return-position dispatch residuals. Tracked as Phase 101 in PLAN.md.

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

### Phase 59.5: Top-level binding order shouldn't matter ✅ DONE

Today the evaluator processes top-level decls in source order, and a
value binding (no params) is evaluated **eagerly** the moment its
`DFunDef` is reached — see `eval.ml:1095-1102`.  If the RHS references
an interface method whose impl appears later in the file, the method
is still bound to its Pass-1 `VUnit` placeholder, and evaluation fails
with `applied non-function: ()`.

Concrete example (surfaced while landing operator sections):
`sum = fold (+) 0` placed before `impl Foldable List` in
`stdlib/core.mdk` parses and type-checks fine, but panics at load
time.  Multi-clause function bindings dodge the issue because
`pats ≠ []` → eval builds a `VClosure` instead of forcing the body,
so the lookup is deferred until call time.  Point-free value
bindings have no such escape hatch.

This is brittle: refactoring core/stdlib or a user library can
silently reorder a binding past an impl it depends on, and the
typechecker won't catch it.

Proposed fix (pick one when this is picked up):

- **Lazy value bindings.**  In Pass 2, instead of `eval env body`
  for `DFunDef (_, _, [], body)`, install a thunk in the cell that
  forces on first read.  Smallest change; matches how `let rec`
  groups already defer.
- **Dependency sort.**  Topologically sort top-level decls by
  free-variable dependency before Pass 2 (with cycle-detection
  pointing at the offending decl).  More invasive but gives clearer
  errors and naturally orders mutually-recursive groups.

Either way: add a regression test that `x = f 0` followed by an
`impl` that defines `f` (in that order, at the top level) evaluates
correctly, and that a genuine forward reference to a non-existent
name still produces a clear error rather than a generic
`applied non-function: ()`.

### Phase 59.6: Multi-variable lambdas `x y => body` ✅ DONE

Haskell writes multi-param lambdas as `\x y -> body`, desugared to
`\x -> \y -> body`.  Medaka today only accepts a single pattern on
the LHS of `=>`: the grammar is
`expr_pipe FAT_ARROW expr_lam { ELam ([expr_to_pat $1], $3) }`
(`parser.mly:598`), and `expr_to_pat` rejects `x y` because the head
of an application must be an uppercase constructor (`parser.mly:75-85`).
So `add = x y => x + y` errors with `Invalid lambda parameter pattern`,
and users must write `x => y => x + y`.

This is a small ergonomic gap.  Top-level and `let`-bound function
clauses already accept multi-arg patterns (`f x y = …`), so the
asymmetry is mostly surprise.

Sketch of the fix:

- Extend the lambda production so the LHS is `nonempty_list(expr_atom)`
  (or a dedicated `lam_pats` non-terminal), then map each atom through
  `expr_to_pat` and build `ELam (pats, body)`.  The evaluator and
  typechecker already handle multi-pat `ELam`, so no downstream changes.
- Watch the `expr_to_pat` head-of-application logic: today a single
  `EApp (Ctor, arg)` LHS encodes constructor destructuring like
  `(Some x) => …`.  The new rule has to keep `Some x => …` working
  (still one pattern, a constructor application) while making
  `x y => …` two patterns.  Easiest disambiguation: if every atom
  on the LHS would parse to a `PVar`/`PWild`/literal/tuple/list, treat
  them as separate pattern args; otherwise fall back to the
  single-pattern expr-to-pat path that handles `Some x`, `Ok x y`, etc.
  An explicit rule on `expr_atom+` is cleaner than the current
  expression-then-reinterpret approach and worth doing while we're here.
- Update the printer to emit multi-pat lambdas as `x y => …` so the
  formatter round-trip stays canonical.
- Tests: parser, typecheck, eval, and `fmt` round-trip for
  `x y => x + y`, `f a b c => …`, and constructor-pattern parity
  (`(Some x) => x`, `(Ok x y) => x` still work).

### Phase 60: Pre-self-host parser-conflict audit ✅ DONE

**Done (2026-05-31).** Re-ran `menhir --explain` against the current grammar
and walked every conflict, confirming each default resolution is the intended
behaviour and that the historical audit notes were still accurate in *outcome*
(state ids had drifted; the resolutions had not).  The result is a fresh
validation table appended to the conflict-audit block in `lib/parser.mly`
(after the per-phase notes), mapping every conflict to:
- the competing reduce-vs-shift (or reduce-vs-reduce) productions,
- the intended winner, and
- a one-line rule the eventual hand-written parser should encode.

Findings:
- The count grew from the documented 8/8 to **9 S/R states (23 conflicts) +
  9 R/R states (35 conflicts)**; the header line in `parser.mly` was corrected.
- `menhir --explain` emits witness derivations for 14 of the 18 states
  (8 S/R + 6 R/R); the other 4 are additional members of families already
  covered (do-block bare-atom ambiguity, range-literal-in-pattern, `_` as
  pat/expr) and resolve identically — documented as such.
- Every do-block bare-atom R/R resolves to the *expression* reading (verified
  empirically with `dev/debug.exe`: `()`, `[]`, and bare literals in stmt
  position all parse as `DoExpr`), so the only practical limitation is that a
  cons/literal/record-pun/UPPER DoBind LHS must be parenthesised — the
  long-standing accepted restriction.

For the hand-written parser the rules reduce to: S/R → "prefer the longer
form"; R/R → "in statement/element position an ambiguous bare atom is an
expression; pattern-only DoBind LHSs must be parenthesised."  The 9+9 conflict
count goes to zero after self-hosting (a Pratt/PEG parser has no conflicts —
each disambiguation is an explicit line); this audit ensures those lines say
the right thing.

---

### Phase 61: Structural deriving — `deriving (Generic)` ✅ DONE

**Goal.** GHC-Generics-style structural deriving. Instead of hard-coding each
new deriver into the compiler, library authors can `deriving (Generic)` on any
`data`/`record`/`newtype` to get `to_rep : a -> Rep`, a uniform reflection of
the value into a flat tagged tree. They then write *one* function over `Rep`
(serializer, hasher, pretty-printer, …) and obtain their typeclass for every
deriving type — no type-level machinery (no associated types, no compile-time
evaluation).

**What was added.**

- **`stdlib/core.mdk`** — a new "Generic" section defining:
  - `data Rep = RCon String (List Rep) | RRecord String (List RField) | RInt Int
    | RFloat Float | RString String | RBool Bool | RChar Char | RUnit` — the
    flat tagged representation, carrying constructor/type names (for
    Show/JSON) plus primitive leaves.
  - `record RField = { fld_name : String, fld_rep : Rep }` — **the first record
    ever defined in the prelude** (this flushed out two latent prelude-record
    infrastructure gaps, see below).
  - `interface Generic a where to_rep : a -> Rep; from_rep : Rep -> a` with a
    `panic` **default** for `from_rep`, plus base impls for
    `Int`/`Float`/`String`/`Bool`/`Char`/`Unit`.
- **`lib/desugar.ml`** — three generators mirroring the existing derivers:
  `derive_generic_data` (one match arm per constructor → `RCon name [to_rep
  field…]`), `derive_generic_record` (→ `RRecord typename [RField {fld_name;
  fld_rep = to_rep r.f}…]`), `derive_generic_newtype` (→ `RCon con [to_rep a]`).
  Wired into `derive_for_data`/`derive_for_record`/`derive_for_newtype`. No
  parser/lexer/printer changes — `deriving (Generic)` already parses and
  round-trips (no derive-name allowlist exists anywhere).
- **Prelude-record infrastructure fixes** (latent bugs, triggered by `RField`):
  - `lib/resolve.ml`: the resolver seeded prelude types/ctors/interfaces/values
    but **not record field owners**, so generated `ERecordCreate ("RField", …)`
    failed with "Unknown field: fld_name". Added `prelude_field_owners` and
    seeding into the `with_prelude` env.
  - `lib/typecheck.ml`: `register_record`'s field-collision check was
    non-idempotent — the multi-file path prepends the prelude per-module *and*
    seeds from exports, double-registering `RField` → spurious "Field name
    collision". Now fires only when the owner actually differs.
- **`test/test_eval.ml`** — 5 tests: `to_rep` on positional/nullary `data`,
  on a `record`, on a `newtype`, plus an end-to-end `ToJson` loop (define a
  `ToJson` interface + recursive `rep_to_json : Rep -> String`, derive `Generic`
  on a data type and a record, `impl ToJson T where to_json x = rep_to_json
  (to_rep x)`) proving "derive once, write one generic function, get the
  typeclass for free".

**Scope shipped: the consumer direction (`to_rep`) only.**

**Limitations / next steps (future phases):**

- **`from_rep` is a stub.** `from_rep : Rep -> a` is *return-type
  polymorphic* — the runtime's `VMulti` dispatch keys on argument runtime type
  tags, and a return-type-only method gets empty dispatch positions (same
  limitation as `fromInt`/`pure`, see `eval.ml`). So `from_rep` is declared in
  the interface with a `panic` default to future-proof the signature, but no
  real bodies are generated. Real `from_rep` deriving is blocked on
  return-type-directed dispatch (e.g. a dictionary-passing or
  type-application mechanism).
- **Named-field *data* constructors are reflected positionally.** A
  `ConNamed` payload on a `data` constructor currently emits `RCon name
  [reps…]` (field names dropped), consistent with how `deriving (Eq/Show)`
  treat them. Emitting `RRecord` for named-field data constructors (preserving
  field names) is a future enhancement; `record` types already get `RRecord`.
- **Numeric leaves can't be rendered by `Rep` consumers yet.** The end-to-end
  `ToJson` example uses `String`/`Bool` fields because the prelude still has no
  `Show Int`/`intToString` extern (see the note at `core.mdk`'s `Show` section).
  Once that extern lands, generic numeric serialization works without changes
  to this feature.
- **Parameterized container types** beyond what call-site constraint checking
  already covers are not specially handled.

---

## Typechecker & interface hardening arc (agent-pickup tasks)

These phases came out of a 2026-05-30 audit of `lib/typecheck.ml` and the
interface/typeclass pipeline (`typecheck.ml` + `resolve.ml` + `eval.ml` +
`desugar.ml`). The user is building the stdlib by hand and keeps hitting
typechecker and interface bugs; the goal of this arc is to iron those out
*ahead* of the stdlib work so the manual stdlib effort is pleasant.

Each item is independently pickable, has concrete code pointers, and is
sized for one session. They are ordered by how much pain they remove from
the stdlib track, not strictly by severity. Line numbers are approximate
(2026-05-30) — grep the named function if they've drifted. **Verify the bug
still reproduces before fixing** (write the failing test first); some may be
partially addressed by the time an agent picks them up.

### Phase 62: Instance/constraint errors point at the wrong source line ✅ DONE

**Goal.** Make `No impl of Eq for C` / `Ambiguous impl` / unsatisfied-constraint
errors point at the *call site*, not a random stdlib line.

**Why it matters now.** This is the single biggest day-to-day annoyance for
stdlib authoring. `method_usages` and `constraint_obligations` carry no
location, so `check_method_usages` / `check_constraint_obligations` (the
post-HM passes) call `fail`, which reads the global `!current_loc` ref — by
then it points at the last declaration processed (often a prop in
`core.mdk`). Every instance error blames the prelude.

**Where.** `lib/typecheck.ml`: `method_usages` tuple type (~:384),
`constraint_obligations` (~:387), the record sites (~:793, :802, :813, :1364),
and the consumers `check_method_usages` (~:1908) / `check_constraint_obligations`
(~:1963). `fail` is :123.

**Scope.** Add a `Ast.loc option` field to both accumulator tuples, captured
from `!current_loc` at record time; thread it into the `fail` call (or a
`fail_at loc e` helper) in the two post-HM passes. Add tests asserting the
reported `loc` matches the offending expression, not the prelude.

**Done when.** A program with a missing impl reports the user's call-site
line; all existing tests pass.

**Follow-up nit (surfaced while doing 62).** The pre-existing
`e_constraint_ambiguous` fixture (`test/test_typecheck.ml`) reuses the
interface name `Monoid`, which collides with the prelude's `Monoid`. So its
`assert_err` passes on a *duplicate-interface* error, not the ambiguity it
claims to test. Phase 62 added a separate, clean `e_loc_ambiguous` fixture
(fresh interface name `Pick`) that genuinely exercises `AmbiguousImpl`, but the
old fixture should be renamed to a unique interface so it tests what it says.

### Phase 63: `deriving` is broken for parametric types ✅ DONE

**Goal.** `data Box a = Box a deriving (Eq)` and `record Pair a b = { ... }
deriving (Eq, Show, Ord)` generate *correct* impls.

**Why it matters now.** The stdlib is full of parametric types
(`Option`, `Result`, tree maps, etc.). Today `deriving` drops the type
params: `desugar.ml` calls `derive_for_data name variants` without `params`,
and every derive helper hardcodes `type_args = [TyCon type_name]` and
`requires = []`. So `deriving (Eq)` on `Box a` emits `impl Eq Box` (nullary
con, no `requires Eq a`), and `eq (Box 1) (Box 1)` fails to typecheck with
`expected type Box but got Box a` — reported at a stdlib line (see Phase 62).
**Main's `deriving (Generic)` (Phase 61, merged 2026-05-30) replicates this
exact bug**: `derive_generic_{data,record,newtype}` also hardcode
`type_args = [TyCon type_name]` / `requires = []`, so `deriving (Generic)`
on a parametric type produces a malformed `impl Generic Box`. Fix all derivers
at once.

**Where.** `lib/desugar.ml`: the `DData`/`DRecord`/newtype derive expansion
(~:397-410) and the helpers (`derive_for_data`, `derive_for_record`,
`derive_for_newtype`, and the per-iface builders incl. the new
`derive_generic_*`, ~:63-327) that hardcode `type_args`/`requires`.

**Scope.** Thread `params` through. Emit `type_args = [TyApp (TyCon name,
TyVar p…)]` (the type applied to its params) and
`requires = [(iface, [p]) for each param p]` so the generated impl reads
`impl Eq (Box a) requires Eq a`. Cover every deriver — Eq/Show/Ord/Arbitrary
**and Generic**. Test each on a parametric `data` and a parametric `record`.

**Done when.** Deriving on a parametric type produces a usable instance and
round-trips through the existing derive tests.

**Done (2026-05-30).** Fixed *centrally* in the three dispatchers
(`derive_for_data`/`derive_for_record`/`derive_for_newtype`) rather than in all
14 per-iface builders: a new `apply_derive_params type_name params` helper
rewrites the freshly-built `DImpl`'s `type_args` (to `applied_head` — the type
left-folded over its params into nested `TyApp`, matching `parser.mly`) and
`requires` (to `[(iface_name, [TyVar p]) for each p]`, reusing the impl's own
`iface_name`). `params` is threaded from `expand_decl`. Non-parametric behaviour
is byte-identical (`params = []` ⇒ `TyCon name`, `requires = []`). Covers
Eq/Show/Ord/Arbitrary/Generic (and Num on newtypes). Tests in
`test_typecheck.ml` (parametric data Eq/Show/Ord + record) and `test_eval.ml`
(parametric Eq dispatch, parametric Generic `to_rep`, parametric record Show).

### Phase 64: Superinterface (`requires`) constraints are never enforced ✅ DONE

**Goal.** `impl Ord C` without a corresponding `impl Eq C` is rejected when
`interface Ord a requires Eq a`.

**Outcome.** `iface_info` gained an `iface_supers : (ident * int list) list`
field (super iface + its arg positions into the interface's params).
`register_interface` now takes `super` and stores it; all three `DInterface`
call sites pass it through. A new post-pass `check_superinterface_obligations`
(beside `check_constraint_obligations`, sharing a `matching_impls` helper)
walks every registered impl and, for each *direct* super, substitutes the
impl's concrete head monos positionally and requires a matching impl — emitting
`MissingSuperImpl`. Transitivity falls out from checking direct supers only
(the presence of `impl B T` already implies B's own super check ran).
Non-concrete impl heads are deferred like the other passes; that deferral is
exactly what makes generic `Ord a => … eq …` bodies sound — the deferred
`Eq a` obligation is entailed by the enforced `Ord` impl at the concrete call
site (no constraint-solver change). The stdlib already pairs every `Ord`/`Eq`
and `Monoid`/`Semigroup` impl, so it loads unchanged.

**Why it matters now.** The stdlib interface hierarchy
(`Ord`→`Eq`, `Monoid`→`Semigroup`, etc.) is meaningless if superclass
obligations aren't checked: programs that should fail typecheck, and a generic
`Ord a => …` body that calls `eq` is only saved by laziness, not soundness.

**Where.** `lib/typecheck.ml`: `register_interface` (~:1651) is called with
`(iface_name, type_params, methods)` — the `super` field is dropped at all
three call sites (~:2243, :2430, :2615). (Resolver validation of the `super`
interface *names* was since added — see Phase 67.)

**Scope.** Thread `super` into `register_interface` and store it on
`iface_info`. When an `impl I T` is registered/checked, require that an impl
exists for each `(SuperI, T)` in `I`'s superinterface list (recursively).
Decide and document the entailment story for generic bodies (`Ord a => …`
should make `Eq a` available). Tests: missing-superclass-impl is an error;
present one passes.

**Done when.** Superclass obligations are enforced at impl sites; the stdlib's
`Ord`/`Eq` split is real.

### Phase 65: Impl-level `requires` constraints are never discharged ✅ DONE

**Goal.** Selecting `impl Eq (Box a) requires Eq a` for `Box T` verifies that
`Eq T` actually holds.

**Outcome.** `register_impl` now threads one shared TVar table through both the
impl head and its `requires` clause (via a new `?tbl` param on `from_ast_type`),
so the `a` in `impl_type_mono` and the `a` in `impl_requires` are the *same*
TVar — the prerequisite for correlating them. Two helpers next to
`matching_impls`: `impl_head_subst` (matches a ground concrete head against the
impl pattern, returning an id-keyed substitution, modeled on `impls_overlap`)
and a non-destructive `subst_apply`. A recursive `check_entry_requires`
substitutes the head TVars into each `requires` entry and, for ground results,
requires a `matching_impls` hit — recursing into the chosen sub-impl's own
`requires` (so `Eq (List (List Int))` → `Eq (List Int)` → `Eq Int`; terminates
because each step structurally shrinks). Non-ground requirements are deferred
exactly like the other passes. The check is folded *into* the two selection
passes (`check_method_usages` via a `commit` wrapper around `resolved_to`, and
`check_constraint_obligations`), so it runs at every typecheck entry point with
no new wiring. Failures raise the new descriptive `MissingImplRequirement`
(mirroring Phase 64's `MissingSuperImpl`) at the call-site `loc` (Phase 62). The
shared `is_concrete` was hoisted to one top-level definition. The stdlib's
`Eq (List a)`/`Eq (Option a)`/`Eq (Result e a)`/`Eq (Array a)` load unchanged.

**Where.** `lib/typecheck.ml`: `from_ast_type` (`?tbl`), `register_impl`,
`impl_head_subst` / `subst_apply` / `check_entry_requires` (beside
`matching_impls`), `check_method_usages`, `check_constraint_obligations`,
`MissingImplRequirement` variant + `pp_error`.

**Tests.** `test/test_typecheck.ml` "impl requires obligations (Phase 65)":
unsatisfiable requirement rejected at the call site (`assert_err_at`); the
`Box (Int -> Int)` repro is now a clean type error instead of runtime
`Out of memory`; satisfiable (`Box Int`) and nested structural
(`Eq [[Int]]`) accepted; a transitive `Eq (Box [Int -> Int])` gap is caught
through the recursive descent.

**Done when.** Constrained impls only resolve when their `requires` hold; the
`Box (Int -> Int)` repro is a clean type error. ✅

### Phase 66: Value restriction — stop over-generalizing non-value `let` bindings ✅ DONE

**Goal.** Don't assign a polymorphic scheme to a `let x = <effectful/non-value>`
binding. Classic ML soundness fix.

**Why it matters now.** With `Ref`/`<Mut>` in the language, generalizing a
non-value RHS is unsound: `let r = newRef []` would get
`forall a. Ref (List a)`, letting one cell be used at two types. The stdlib's
mutable structures (`mut_array`, `hash_map`) will exercise exactly this.

**Where.** `lib/typecheck.ml`: `ELet` `PVar` path generalizes unconditionally
(~:870); same unconditional generalization in `DoLet`
(`EBlock` ~:1078, `EDo` ~:1194) and `ELetGroup` (~:880). The author already
applied a "value-restriction-like" guard to the *non-`PVar`* pattern case
(~:875) — the dangerous `PVar`-of-non-value case is the one missing it.

**Scope.** Add an `is_nonexpansive`/`is_value` predicate (lambda, literal,
constructor application of values, var) and generalize only when it holds
(or never generalize a syntactically-non-value RHS). Keep the existing
self-recursive lambda path. Tests: `let r = newRef []` does not generalize;
`let id = \x => x` still does.

**Done when.** The polymorphic-reference unsoundness is closed; existing
let-polymorphism tests still pass.

**What was done.** Added `is_nonexpansive` (value iff literal/var/lambda, or
tuple/list-literal of values; `ELoc`/`EAnnot` transparent), plus
`lower_to_current` + `gen_restricted` helpers in `lib/typecheck.ml` (after
`monotype`). Replaced unconditional `generalize` at all four inner sites — `ELet`
`PVar`, `DoLet` in `EBlock` and `EDo`, and per-binding in `ELetGroup` — and at
the **top-level** non-letrec path in `process_letrec_group` (gated on the
binding's clauses; `let rec` members are always functions). The self-recursive
lambda path and the existing non-`PVar` guard are untouched.

Two deviations from the original write-up: (1) the top-level path was included
(the real stdlib motivation — top-level `mut_array`/`hash_map`), beyond the
inner-only "Where" list. (2) `Ref` is a *constructor* (`extern Ref : a -> Ref a`),
not a `newRef` function, so — like SML/OCaml's `ref` — **all applications
(including constructor applications) are treated as expansive**; the
"constructor application of values" carve-out would have reopened the `Ref []`
hole. No regression: every constructor-application binding in the suite has a
concrete type, so generalizing it was already a no-op. Tests in
`test/test_typecheck.ml` ("value restriction (Phase 66)"): `r = Ref []` used at
two element types is rejected (top-level + in-block paths), `empty = []` stays
polymorphic.

### Phase 67: Resolver validates `requires` / `super` interface names ✅ DONE

**Goal.** `impl Eq (Box a) requires Bogus a` and `interface Foo a requires
Bogus a` are rejected with `UnknownInterface`.

**Outcome.** The `DImpl` resolve case now destructures `requires` and iterates
it, emitting `UnknownInterface` for any constraint-interface name not in
`env.interfaces` and walking each constraint's type args through `check_type`
(so unknown types in a constraint are caught too, matching the `TyConstrained`
path). The `DInterface` case likewise destructures `super` and validates each
superinterface name. Reused the existing `UnknownInterface` constructor + `emit`
helper — no new error types, no `build_env` change, no typechecker change. Tests
added in `test/test_resolve.ml` under "requires / super constraints": unknown
iface in `impl … requires` and `interface … requires` are errors; known ifaces
in both positions resolve clean. The stdlib (`core.mdk`'s real `requires`/`super`
clauses) still resolves, typechecks, and evals unchanged.

**Why it mattered.** Cheap correctness win; typos in constraint lists previously
passed silently.

### Phase 68: Overlap / coherence checking for impls ✅ DONE

**Goal.** Reject incoherent instance sets at *declaration* time, including
partial overlaps like `impl Eq (List Int)` vs `impl Eq (List a)`.

**Why it matters now.** Stdlib will define many instances; today overlaps are
only detected lazily (and inconsistently) when a concrete call site happens to
exercise them, and runtime "first terminal wins" silently picks one. The
existing `check_coherence` only runs for `default impl`s and its own comment
says it misses partial overlap.

**Where.** `lib/typecheck.ml`: `impls_overlap` + `check_coherence` (~:1866),
`mono_matches` (call-site matcher, ~:1900).

**Done so far (conservative policy).** `check_coherence` now does a
unification-based pairwise overlap check (`impls_overlap`: two impls overlap iff
their head-type lists unify under one substitution, treating all TVars as
wildcards). Policy is deliberately conservative — overlap is an error only when
*unresolvable*: two overlapping `default` impls (`MultipleDefaultImpls`), or two
overlapping **anonymous, non-default** impls (`OverlappingImpls`). Overlap is
*allowed* when exactly one side is `default` (blessed specialization) or either
side is **named** (`@Name` disambiguates — preserves Phase 32). Seeded (prelude)
impls are excluded so user overrides (Phase 45.9) and multi-module duplicates
don't false-positive. Tests in `test/test_typecheck.ml` group "impl coherence
(Phase 68)".

**Done (2026-05-30, now that Phase 69 dispatch landed).**
- **Most-specific-wins** — `subsumes` / `strictly_more_specific` (one-directional
  head matching in `typecheck.ml`, sibling of `impls_overlap`) order overlapping
  impls by specificity. `check_coherence` now *allows* an overlapping anonymous
  pair when one head is a strict specialization of the other (`List Int` ⊏
  `List a`); only equal duplicates and incomparable partial overlaps
  (`Conv Int a` vs `Conv a Bool`) remain `OverlappingImpls` errors.
  `check_method_usages` commits the unique most-specific matching impl at each
  concrete call site (precedence `@Name` > most-specific > `default`-fallback),
  and Phase 69's `EMethodRef` key dispatch honors that choice end to end. Tests:
  `t_overlap_specialization_ok`, `t_overlap_picks_specific` (asserts the
  resolved key), `e_overlapping_incomparable`.
- **Source locations on the error** — `DImpl` gained an `impl_loc` (the parser
  fills it via `of_pos`; desugar-synthesized impls use `None`), threaded onto
  `impl_entry`; `check_coherence` reports via `fail_at (coherence_loc e1 e2)`.
  Test: `e_coherence_has_loc` (`assert_err_at`).

**Done (orphan-instance check).** An impl declared in a module that owns neither
the interface nor any head type is an orphan, reported via a new `OrphanImpl`
`type_error`. The supposed blocker — "no type→defining-module map" — was
sidestepped: the check needs only *local* knowledge plus the names exported by
*imported user modules*, since the impl is checked in the module that declares
it ("in the interface's module" ⟺ "interface declared locally", likewise for
head types). `check_orphans` (`typecheck.ml`, sibling of `check_coherence`,
called only from `typecheck_module`) flags an *anonymous* impl iff its interface
is non-local **and** no head-type constructor is local **and** the interface or
a head type originates from an imported user module. The prelude (`core`) is
never a known-module (the loader skips it), so prelude/runtime names (e.g.
`Eq`/`Array`) never count as "imported" — `stdlib/array.mdk`'s `impl Eq (Array a)`
and single-file prelude overrides (`impl Show Int`) stay in scope. Imported type
names are carried on a new `module_type_exports.te_types` field (built from
`user_prog`, so the prelude prepend doesn't leak in; prelude *interface* names
that do leak into `te_interfaces` are filtered out explicitly). Named impls
(`@Name`) are exempt — an explicit opt-in escape hatch, consistent with Phase
68's overlap leniency. Tests in `test/test_typecheck.ml` group "impl coherence
(Phase 68)" use a new in-memory `check_modules` helper:
`e_orphan_impl_rejected`, `e_orphan_core_iface_remote_type`,
`t_orphan_local_type_ok`, `t_orphan_local_iface_ok`, `t_orphan_named_exempt`,
`t_orphan_prelude_override_ok`.

**Done when.** Overlapping impls are reported at declaration *with a source
line*; resolution is order-independent — the checker commits the most-specific
impl and eval honors it; orphan impls are rejected at declaration time. *(Done.)*

### Phase 69: Type-directed / return-position dispatch (dictionary passing) ✅ DONE (69.x-a..e all done)

**Status.** Phase 69 (elaboration at concrete sites) landed: the five-part
design below is implemented (`EMethodRef` node in `ast.ml`, marker pass in
`lib/method_marker.ml`, canonical `impl_key` shared by `typecheck.ml`'s
`register_impl` and `eval.ml`'s `DImpl` registration, in-place ref fill in
`check_method_usages`, key-directed selection in eval). Return-position and
multi-param repros route correctly end-to-end — see `test/test_run.ml`
(`t_return_position_dispatch`, `t_multiparam_dispatch`) and the key-agreement
tests in `test/test_typecheck.ml` ("impl-key dispatch (Phase 69)"). The marker
is wired into single-file `check`/`run`, multi-module, and the repl. **Phase
69.x dictionary passing is complete through 69.x-e**: the
`pure`/`current_monad_type` workaround is retired (69.x-c/d), and method-level
interface-method constraints (`foldMap`'s `Monoid m`) now route by dictionary
too (69.x-e) — see carve-out below.

**Known gaps / follow-ups (not regressions; pre-existing, surfaced during 69):**
- **Doctests are not type-directed.** The doctest runner has no typecheck phase,
  so the marker pass cannot fill `EMethodRef` cells there; doctests that rely on
  return-position/multi-param dispatch fall back to arg-tag "first impl wins".
  Deliberately skipped for Phase 69 (decided with the user). Fix requires
  running mark + typecheck before doctest eval, or threading resolved keys some
  other way. Tracked under Phase 70.
- **Repl multi-impl dispatch ✅ FIXED (2026-05-30).** Symptom: defining several
  `impl`s of one interface in the repl made typed calls like `(decode 1 : String)`
  fail to check interactively (worked in whole-file mode). The hypothesized cause
  (typecheck overwriting the method's polymorphic scheme with an impl monotype)
  was wrong — `check_repl_decl` handles the whole block correctly. **Real root
  cause:** the repl's line-by-line input collector (`ends_indented` in
  `lib/repl.ml`) committed a `where`-header too early. `interface Decode a where`
  and `impl Decode String where` each parse as a *complete* zero-method
  declaration (marker-interface grammar `parser.mly`:953, empty-impl-body
  `parser.mly`:1018), so the indented body lines below them were parsed as
  *separate* top-level decls — turning `decode n = …` into a standalone monotype
  `DFunDef` that shadowed the (empty) interface. Fix: keep collecting when the
  last non-empty line ends with the `where` keyword (a layout-block opener),
  flushed by a blank line like other indented blocks. Regression tests in
  `test/test_repl.ml` ("multi-line blocks").

**Goal.** Methods discriminated by their *result* type (`fromInt : Int -> a`,
`pure`, `empty`, `minBound`, **`from_rep : Rep -> a`**) and multi-parameter
interfaces dispatch to the impl the typechecker actually chose.

**Why it matters now.** This is the deepest interface hole and the one most
likely to produce *silently wrong stdlib results*. Runtime `VMulti` dispatch
filters only on the *argument's* `runtime_type_tag`; when the discriminating
type is in the result (or is a non-first interface param), the **first** impl
always wins. Audit repros: `(fromInt 3 : Float)` yields an `Int` value;
`Convert Int String` vs `Convert Int Bool` picks the wrong one. The
`pure_impls` special-case in `eval.ml` is a point workaround for exactly this.
**Main's Phase 61 (`deriving (Generic)`) is now blocked on this**: its
`from_rep : Rep -> a` ships as a `panic` stub because, in that phase's own
words, real `from_rep` deriving is "blocked on return-type-directed dispatch
(dictionary-passing or type-application)." Completing this phase unblocks the
*decode* direction of Generic (parsers, deserializers), not just `to_rep`.

**Where.** `lib/eval.ml`: `VMulti` apply / dispatch (~:333-395),
`dispatch_positions_of` (~:234-251), `pure_impls` (~:271),
`impl_type_tag`/`runtime_type_tag` (~:1337). The fix needs the call site's
*resolved* impl from the typechecker.

**Scope (decided).** Split in two. **Phase 69 = elaboration** (type-annotated
AST): handles every call site where the discriminating type is *concrete at the
site* — all audit repros (`(fromInt 3 : Float)`, `Convert Int String`) and
Generic *decode* (`from_rep` at a concrete target). **Phase 69.x = dictionary
passing** (carved out below): genuine value-level polymorphic propagation.

**Pipeline note.** `check`/`run` desugar *before* typecheck (`bin/main.ml`:131
/197/399), so by typecheck time the tree already contains derived `impl` bodies
and comprehension expansions — elaboration over the typechecked tree therefore
also covers synthesized `from_rep`/`to_rep` sites. Argument-position dispatch
already works via `runtime_type_tag` on the argument; the hole is strictly
*result-position* and *non-first multi-param* dispatch.

**Phase 69 design — elaborated AST via embedded refs (decided).** Five parts.

1. **Node — `EMethodRef of resolved option ref * ident`** (new `expr`
   constructor, `ast.ml`). Transparent like `ELoc`; created only by the marker
   pass (part 2), so its blast radius is just `typecheck.ml` + `eval.ml` (plus a
   one-line passthrough in `pp_expr`/`strip_locs_expr` for safety) — printer,
   `fmt`, `resolve`, `desugar`, `coverage`, `exhaust` never see it. `resolved`
   is the canonical impl key (part 3). The mutable ref is the EDo precedent
   (`EDo`'s `string option ref`, `ast.ml`:91) generalized: parser can't identify
   method names, so a marker pass installs the ref instead.
2. **Marker pass — install refs after resolve, before typecheck.** Walks each
   (already desugared + resolved) program and rewrites every interface-method
   name occurrence `EVar m` → `EMethodRef (ref None, m)`, using the union of
   interface-method names (global per `resolve.ml`; available from resolve
   exports across all modules). One rebuild, *before* the typecheck/eval fork.
3. **Impl key — canonical string** `iface | pp_ty(type_args) | name`. Computed
   from the **AST `type_args`** at `register_impl` and stored on a new
   `impl_entry.impl_key` field; eval computes the identical string from the same
   `type_args` at `DImpl` registration and tags the `VMulti` candidate with it
   (extend `VTypedImpl` to carry the key). One shared AST-based printer, so the
   two sides agree. Disambiguates multi-param (`Convert Int String` vs
   `Convert Int Bool`), nested specialization (`List Int` vs `List a` — so
   most-specific-wins becomes routable), `@Name`, and overlaps. The few AST-less
   hardcoded `impl_entry` stubs (`typecheck.ml`:1936, operator constraints only)
   synthesize an equivalent key from `impl_type_mono` (flat ground types only —
   spellings trivially agree); eval never dispatches on them, so a mismatch can
   only fall back, never mis-route. `impl Num Int`/`Num Float` are *real* impls
   in `core.mdk` (:194/:204), so `fromInt` needs no seeded special-casing.
4. **Fill refs in place — no return-threading.** `check_method_usages`
   (`typecheck.ml`:1963) already resolves the unique matching `impl_entry`
   (seeded/override/`@Name` dedup included); we retain that choice and write its
   `impl_key` into the call site's ref. Because every eval-bearing caller already
   shares the *post-marker* tree with typecheck (single-file `root_program`
   :412/:419; multi-module same `modules` progs :489/:508; `run` mode :141/:149;
   doctest; repl per-batch) and typecheck doesn't deep-copy exprs, in-place
   mutation is visible to eval with **no change to `check_program` /
   `typecheck_module` return types**. LSP (`lsp_server.ml`:473…) and diagnostics
   only typecheck, never eval → untouched. Each eval-bearing site just runs the
   marker before the fork.
5. **Eval honors the key.** At an `EMethodRef` whose ref is `Some key`, select
   the matching `VTypedImpl`/`VNamedImpl` out of the `VMulti` up front by key
   (`eval.ml`:333), instead of inferring a tag from an argument value. No
   synthetic-tag hack; `None` refs (genuinely polymorphic 69.x sites) fall back
   to the current arg-tag path.

**Unblocks.** Phase 68 most-specific-wins becomes sound once eval honors the
checker's choice — document that policy and the resolution semantics in
`language-design.md` when 69 lands.

**Phase 69.x — dictionary passing (carved out).** Thread dictionaries
through constrained functions so *polymorphic* code (`Num a => … a` helpers,
generic `pure`) resolves return-position methods at runtime instead of relying
on a concrete call site.

**69.x-a/b ✅ DONE (2026-05-30).** The dictionary-passing mechanism for
*user code* (single-file, multi-module, and repl). Design — a lightweight
**key-as-dictionary** scheme that reuses Phase 69's `impl_key` + eval's
`select_impl_by_key`, so a dictionary is just the canonical impl-key string
(`VDict of string`), never a record of method closures:
- **`EDictApp of res_route list option ref * ident`** (`ast.ml`) — the dual of
  `EMethodRef`, installed by the marker pass on every occurrence of a
  user-defined constrained function, filled in place by typecheck, and applied
  by eval as leading dictionary arguments. `resolved` now carries a
  `res_route = RKey of string | RDict of ident` (concrete impl key vs. a
  synthetic dict-param name to read at runtime). `Ast.dict_param_name`.
- **Marker** (`method_marker.ml`) wraps user constrained-fn references
  (constrained set from `DTypeSig … =>`); prelude stays unmarked.
- **Typecheck** records per-occurrence `dict_app_usages`; `resolve_dict_apps`
  fills each route (concrete → `RKey`, enclosing-constraint var → `RDict` via
  `find_enclosing_dict`); `check_method_usages` stamps `RDict` for polymorphic
  in-body method refs. `fun_constraints` is threaded across modules via a new
  `te_fun_constraints` export.
- **`dict_pass.ml`** (new, post-typecheck) prepends one `$dict_<fn>_<slot>`
  parameter per constraint to each constrained function's definition; arity is
  read off the filled `EDictApp` routes (whole-program) or `fun_constraints`
  (repl). Eval: `EMethodRef`/`RDict` reads the dict param, `EDictApp` applies
  the resolved `VDict`s. Tests: `test_run` (`t_dict_polymorphic_helper`,
  `t_dict_transitive`), `test_typecheck` (`t_dict_routes_helper`),
  `test_repl` (cross-input), `test_loader` (cross-module).

**69.x-c/d ✅ DONE (2026-05-31, commit `600d5c1`).** Retired the
`pure_impls` + `current_monad_type` workaround (and the EDo monad tag): `pure`
is now an ordinary Applicative VMulti method routed through the dictionary /
elaboration machinery. Landed in four steps — (1) the **`RHeadKey`** route
(`ast.ml`/`typecheck.ml`/`eval.ml`) for return-position calls whose
discriminating type is head-concrete but args-free (`pure x : Result e a`, every
do-block `pure`); (2) **per-super dict params** so a constrained function's slot
list is expanded with the direct superinterfaces of each declared constraint
(`when`/`unless`, `Thenable m =>` calling Applicative's `pure`, thread an honest
Applicative dict); (3) **marking + dict-passing the prelude** (`marked_prelude`;
typed drivers build `marked_prelude @ user`, `Dict_pass.run`, eval
`~prelude:false`); (4) deleting the workaround in both batch and repl paths.

**69.x-e ✅ DONE (2026-05-31).** Method-level interface-method constraints —
the `Monoid m` on `foldMap : Monoid m => (a -> m) -> t a -> m` — now route by
dictionary, where 69.x-c left them on arg-tag fallback. Mechanism, mirroring
`fun_constraints`:
- **`resolved.res_method_dicts : res_route list`** (`ast.ml`) on each
  `EMethodRef` — the method's own method-level-constraint dicts, applied by eval
  as leading args to the method binding (alongside its arg-tag `t`-dispatch).
- **Typecheck** records per-method method-level constraints (super-expanded via
  the shared `expand_supers`) in `env.method_constraints`, keyed by method name;
  the default-body inference maps them through its instantiation into
  `env.method_dict_routes` so `find_enclosing_dict` routes the body's inner
  `empty` ref to `$dict_foldMap_0`. `resolve_method_dicts` (sibling of
  `resolve_dict_apps`, sharing `resolve_one_route`) stamps each call site's
  `res_method_dicts` (concrete → `RKey`, enclosing-constraint var → `RDict`).
  Threaded across modules via `te_method_constraints`.
- **`dict_pass.ml`** prepends `$dict_<method>_<slot>` params to `DInterface`
  default bodies and `DImpl` method clauses; arity from filled `res_method_dicts`
  (whole-program) or `method_constraints` (repl).
- **Eval** applies `res_method_dicts` at `EMethodRef`; explicit-impl dispatch
  positions shift right by the leading dict-param count so the discriminating
  value arg still tag-dispatches. (`++`, an operator, stays on arg-tag against
  the now-concrete accumulator, so only the zero-arg `empty` needs a dict.)
  Tests: `test_run` (`t_foldmap_method_dict_concrete`, `..._polymorphic`,
  `..._explicit_impl_offset`), `test_typecheck` (`t_foldmap_method_dict_routes`),
  `test_loader` (cross-module). The untyped path keeps `res_method_dicts = []`,
  preserving the arg-tag fallback (`test_eval` `t_foldmap_*`).

**Done when.** *(69)* Result-typed and multi-param method calls at concrete
sites run the impl the type checker chose; the `fromInt`/`Convert` repros are
correct and Generic decode works. ✅ *(69.x-a/b)* Polymorphic call sites in user
code resolve via dictionaries. ✅ *(69.x-c/d)* `pure_impls`/`current_monad_type`
gone; prelude monadic functions route via dictionaries. ✅ *(69.x-e)*
method-level interface-method constraints (`foldMap`'s `Monoid m`) route via
dictionaries at both concrete and polymorphic call sites. ✅

### Phase 70: Smaller typechecker correctness & diagnostics fixes ✅ DONE

A grab-bag of self-contained fixes, each ~an hour, each with its own test.
All ✅ DONE (2026-05-31). Most in `lib/typecheck.ml`; the doctest item is in
`lib/doctest.ml`. New tests live in `test/test_typecheck.ml`'s "diagnostics
(Phase 70)" group (plus eval cases for Float `%` / negation and a
`test_doctest` return-position-dispatch case).

- ✅ **`ESlice` swallows errors and corrupts state.** The
  `try unify … with _ -> try unify … with _ -> …` cascade caught *all*
  exceptions and re-unified against a partially-mutated `te`. Fixed by
  branching on the *normalized* container type (`String` / `Array _` / `List _`
  / a TVar default to Array / else one clean mismatch) — one non-failing unify
  per branch, no destructive trial. The not-yet-grounded case still defaults to
  Array, as before.
- ✅ **Constructor-pattern arity is unchecked; `ArityMismatch` was dead code.**
  `PCon` now counts the arrow spine of the instantiated constructor type and
  raises `ArityMismatch` on a wrong-arity pattern (a function-typed payload
  still counts as arity 1).
- ✅ **Unknown type vars in `data`/`record` payloads silently became fresh
  vars.** `data Box a = Box b` is now rejected with the new `UnboundTypeVar`
  in both `register_data` and `register_record` (the resolver ignores `TyVar`,
  so typecheck is the enforcement point).
- ✅ **Type-alias arity mismatch fell through silently.** `expand_aliases`
  now raises the new `TypeAliasArity` for both a wrong-arg-count `TyApp` spine
  and a bare parametric alias used with zero args.
- ✅ **`EAnnot` didn't skolemize.** After unifying, every type variable named
  in the annotation must remain a *distinct unbound* variable; otherwise the
  expression is less polymorphic than claimed (`(intId : a -> a)` for
  intId : Int -> Int is now rejected via `AnnotationTooGeneral`). This is the
  skolemize-and-escape-check realized by variable identity, no rank-N machinery.
- ✅ **`pp_mono` used a separate name table per side of a mismatch.** Factored
  into `pp_mono_in` over a shared naming context; `pp_mono_pair` / `pp_monos` /
  `pp_monos_pair` render the two-type and arg-list error messages so distinct
  vars never collide on one letter.
- ✅ **Float unary negation and `%` were Int-only.** `EUnOp "-"` records a
  `Num.negate` usage and `%` records a `Num` usage, so both work on Int, Float,
  and any user `Num` impl. `eval_arith` gained a Float `%` case (`Float.rem`);
  negation already handled `VFloat`.
- ✅ **Doctests skip typecheck, so Phase 69 dispatch doesn't reach them.**
  `Doctest.run_file` now runs `Method_marker.mark_with_prelude` →
  `Typecheck.check_program` (fills each `EMethodRef` impl-key ref in place) →
  `Dict_pass.run` before `Eval.eval_program`, mirroring the run-mode pipeline.
  On a typecheck failure it falls back to the original untyped eval, so a
  doctest's own type error doesn't mask its result.  Return-position /
  multi-param dispatch now resolves in doctests (test: `test_doctest`
  "return-position dispatch" — `(decode 1 : Bool)` dispatches to the `Bool`
  impl instead of "first impl wins").
  (`lib/doctest.ml` / the doctest driver in `bin/main.ml`). The doctest runner
  parses + evals example snippets without a typecheck phase, so the Phase 69
  marker pass has nothing to fill `EMethodRef` cells against and return-position
  / multi-param method calls in doctests fall back to arg-tag "first impl wins".
  Run mark + `check_program` before doctest eval (mirror `capture_run_typed` in
  `test/test_run.ml`) so doctests share the typed dispatch path. Deliberately
  deferred when Phase 69 landed.

### Phase 71: Typechecker robustness — no `assert false` / raw `Not_found` / leaked levels ✅ DONE

**Done (2026-05-31).** All `assert false` in `lib/typecheck.ml` are gone:
- A new `InternalError of string` `type_error` (+ `pp_error` case: "Internal
  type-checker error: … (this is a compiler bug — please report it)").
- The `Link _ -> assert false` invariant guards in `unify` / `instantiate_raw`
  / `instantiate_with` / `instantiate_method` / `instantiate_record` and the
  `interface param` extraction now `fail (InternalError …)`.  `pp_mono`'s guard
  returns the placeholder `"_"` instead — it runs while *formatting* an error
  and must never raise.
- The desugar-elimination guards (`EListComp` / `EGuards` / `EFunction` /
  `ESection` / `EQuestion`) in both `infer` and the effects pass now
  `fail (InternalError "… reached typecheck — desugar pass was not run")`.
- The empty-`do`/empty-block `[] -> assert false` and the
  `fresh_var did not yield a TVar` guards likewise became `InternalError`.

Cross-module `Hashtbl.find` that could raise raw `Not_found` is guarded:
`EFieldAccess` / `ERecordUpdate` fall back to `UnknownRecord`; the
method-dispatch interface lookup falls back to `UnknownInterface`;
`check_method_usages`' `n_iface_params` degrades to `0` (skips that usage)
rather than crashing the REPL.  The stray `field_owners`→`List.assoc` guard now
raises `UnknownField` instead of `assert false`.

Level bracketing: `check_repl_decl` resets `current_level := 0` at each input
boundary (`check_program` / `typecheck_module` already do via `reset_state`), so
a type error that fails *between* an `enter_level`/`exit_level` pair in one input
can't carry a leaked level into the next.  (Note: a uniform leak is *relative*
and self-corrects per input, so it doesn't actually corrupt generalization — but
the reset restores the absolute "top-level names pre-bound at level 1" invariant
the codebase documents in §2.9, cheap insurance.)

Tests: `test_typecheck` "robustness (Phase 71)" — a non-desugared list
comprehension yields a catchable `InternalError`, not `Assert_failure`;
`test_repl` "robustness (Phase 71)" — the session recovers from a prior type
error and a later polymorphic `id` still generalizes.

---

**Original goal.** A bug elsewhere surfaces as a Medaka diagnostic, not an opaque
"Internal error" or a wedged REPL.

**Why it matters now.** During heavy stdlib editing these landmines turn small
mistakes into confusing crashes — especially in the REPL, which reuses
typechecker state across inputs.

**Where.** `lib/typecheck.ml`: `assert false` in `unify`/`pp`/etc. (~:175,
212, 235, 254, 289, 626); unguarded `Hashtbl.find env.interfaces` and friends
(~:789, :1291, :1307, :1910) that can raise raw `Not_found`; the many
hand-balanced `enter_level ()` / `exit_level ()` pairs — an early `fail`
between them permanently increments `current_level`, corrupting generalization
for everything after (the REPL deliberately does not `reset_state`, ~:2569).

**Scope.** Replace `assert false` invariant-violation paths with a proper
`InternalError`/diagnostic carrying context. Guard the `Hashtbl.find`s that can
miss across module boundaries. Make level bracketing exception-safe (a
`with_level` combinator that restores `current_level` in a `finally`, or reset
levels at each REPL input). Tests: a forced internal inconsistency yields a
diagnostic; a type error mid-`register_*` doesn't corrupt the next REPL input.

**Done when.** No `assert false` on the error path; REPL state survives a type
error without leaking levels.

### Phase 72: Field-name reuse across record types (receiver-type-directed resolution) ✅ DONE (2026-05-31)

**Goal.** Allow two record types to declare the same field name, and resolve
field access (`p.name`) by the record type inferred for the receiver.

**Scope decision (settled 2026-05-31).** Go with the **interim** option:
receiver-type-directed field resolution, **not** full row polymorphism. Row
variables (`\r => r.x` over "any record with field `x`") are explicitly
declined — they add a structural abstraction axis that competes with
interfaces and fracture the language into two idioms for the same job. See
*Field-name reuse and the decision against row polymorphism* under Product
Types in `language-design.md`, and the *Explicitly Out of Scope* list. This
realizes intent already stated in the design doc ("Fields are namespaced to
the type — no global namespace pollution"), which the current global
`field_owners` collision behavior violates. The decision is not a one-way
door: row variables can be layered onto `mono` later if a concrete need that
interfaces cannot meet ever appears.

**Why it matters now.** The stdlib will define many records; today a field name
may be declared by only one record type — `Field name collision: 'name' is
already declared by another type` is a hard error — and field access resolves
purely by global field name via `env.field_owners`. This forces awkward unique
field naming across the whole stdlib. (Main's Phase 61 commit only made the
collision check *idempotent* — re-registering the *same* record across the
multi-file prelude path no longer fires — and seeded prelude `field_owners` in
`resolve.ml`. A genuine cross-type collision is still a hard error, so the
limitation this phase targets is unchanged.)

**What landed.** `field_owners` (in both `typecheck.ml` and `resolve.ml`)
became a **multimap** (field → every owning record), populated with
`Hashtbl.add` via a dedup-on-insert `add_field_owner` helper and read with
`Hashtbl.find_all`. Both `Field name collision` errors (`register_record`,
`register_data` ConNamed) are gone. `EFieldAccess`/`ERecordUpdate` resolve by
the receiver's head type constructor when known (`head_tycon_mono`); when the
receiver is still an unbound type variable they fall back to the field's
candidate owners — a single owner drives inference (backward-compatible), and
multiple owners raise the new `AmbiguousField` type error (rendered Elm-style,
naming candidates and suggesting an annotation). `resolve.ml`'s three
field-validation sites (`PRec`, `ERecordCreate`, `ERecordUpdate`) became
multimap-aware; the update site relaxed to existence-only (the cross-field
consistency check moved to typecheck, where the receiver type is known). Eval
was unchanged (it looks fields up directly on the `VRecord` value).

**Known limitation (deferred to Phase 73).** A shared field needs the
receiver's type known *at the access site*: construction-pinning
(`(Point { … }).x`) and receiver annotations (`(p : Point).x`) work, but a
top-level signature (`f : Point -> Int; f p = p.x`) does **not** disambiguate —
signatures unify against the body *after* it is inferred, so the parameter type
isn't available at the field access. Single-owner fields are unaffected
(inference still resolves them). See Phase 73.

**Done when.** ✅ Two records sharing a field name coexist; field access picks
the right one by the receiver's inferred type; the collision errors are gone;
ambiguous shared-field access reports `AmbiguousField`. Full row polymorphism
remains out of scope. Tests: `test_typecheck` (shared-field success +
ambiguity + cross-record update), `test_resolve` (shared-field create/pattern,
relaxed update).

---

### Phase 73: Signature-driven parameter typing (bidirectional checking for signed defs) ✅ DONE (2026-05-31)

**Goal.** When a top-level definition carries a type signature, push the
signature's argument types into the function's parameter patterns *before*
inferring the body, so the parameters' types are known inside the body. Makes
`f : Point -> Int; f p = p.x` resolve a shared field by the signature alone
(today only construction-pinning or a `(p : Point).x` annotation works — Phase
72 limitation).

**Why.** Beyond the shared-field case, this is the generally-expected behavior
of a type signature (a checking-mode / bidirectional pass). It improves error
locality and lets annotations on the signature flow to the body.

**Where.** `lib/typecheck.ml` `process_letrec_group` (~:1868): currently
`unify placeholder sig_t` runs, then each clause is inferred as a bare lambda
(`clause_to_expr`, ~:979) whose parameter vars are fresh and only unify with
the placeholder's domain *after* the body. Decompose `sig_t` into argument
types and bind each clause's parameter pattern to the corresponding argument
type in the env before inferring the body. Handle multi-clause functions,
guards, partial application, and effect annotations on the arrow; preserve the
value restriction (Phase 66) and constraint extraction. Treat as
`add-language-feature` (delicate inference path), not a small `harden`.

**What landed.** `process_letrec_group` (`typecheck.ml`) now peels the declared
signature into per-parameter argument types and **pre-unifies** them onto the
clause's parameter patterns *before* inferring the body — replacing the bare
`infer (clause_to_expr clause)` path for signed clauses only. The change is
purely additive: the existing final `unify placeholder t` imposes the same
equalities, so the solution is unchanged; the param types are merely available
*during* body inference. Peeling stops at `min(arity, n_params)`, so signatures
that return a function (`add : Int -> Int -> Int; add x = y => …`) push only the
covered domains and the lambda body supplies the rest; a signature with fewer
arrows than params pushes nothing and the mismatch still surfaces at the final
unify. Constraint extraction, the value restriction (Phase 66), and level
bracketing are untouched (the new work sits inside the existing
`enter_level`/`exit_level` pair and reuses `sig_t`'s vars). Beyond shared
fields, any type-directed expression now sees the declared param type — e.g.
`f : List Int -> List Int; f xs = xs.[1..3]` resolves `ESlice` to `List` instead
of the Array default.

**Done when.** ✅ A signed definition type-checks its body against the declared
parameter types; `f : Point -> Int; f p = p.x` resolves a shared field; no
regression in `test_typecheck`/`@thorough` (polymorphic + constrained signatures
and the value restriction all still pass). Tests: `test_typecheck` (sig
disambiguates shared field Int/Float, sig drives slice container, constrained
sig, polymorphic identity, partial-peel returns-function, body-field mismatch).

---

### Phase 74: `Show`-based doctest rendering ✅ DONE (2026-05-31)

**Done.** Doctests now render a result through the user-facing `Show` typeclass
instead of the interpreter-internal `Eval.pp_value`, matching GHCi/`doctest`
(one rendering contract). `Doctest.run_file` wraps each example *that has an
expected line* as `show (<expr>)` (smoke examples stay raw); `pp_value (VString)
= s` then extracts the rendered text. To make `Show` real:

- Leaf-formatter externs `intToString`/`floatToString`/`showStringLit`/
  `showCharLit` (`stdlib/runtime.mdk` + `lib/eval.ml`), exposing the same OCaml
  formatting `pp_value` uses. `String`/`Char` render *quoted + escaped*
  (round-trippable; `show` intentionally differs from `println`), Int/Float/Bool
  match `pp_value`.
- Base `Show` impls: `Int`/`Float`/`Bool` (`True`/`False`)/`Unit`/`List`/
  `Option`/`Result` in `core.mdk`, `String`/`Char` in `string.mdk`; the tuple
  impls went live. `Show Bool` renders `True`/`False` (constructor names), so the
  Bool doctests updated `true`/`false` → `True`/`False`.
- **Tuple method dispatch fix** (`lib/eval.ml`): `runtime_type_tag` and both
  `head_tycon` helpers had no tuple case, so methods on tuples fell to arg-tag
  "first impl wins". `Eq`/`Ord` tuples only *looked* right (their `Int` impl
  bodies use the builtin structural `==`); `Show` exposed it (`intToString` on a
  tuple). Both sides now tag tuples `__tuple__`, matching the typechecker.

**Follow-ups (deferred):**
- **Unify `println`/`print`/REPL onto `Show`** (the remaining half of "one
  rendering path"). Needs a `Show a =>` constraint on the print builtins —
  breaking (every printed value needs a `Show` instance), so deferred.
- **Recursive constrained functions drop their dictionary on the self-call.**
  ✅ FIXED (2026-05-31). A top-level `Show a => List a -> String` (or any
  `C a => …`) that called itself recursively mis-dispatched: the self-call
  resolved to an empty dict route instead of forwarding the enclosing dict param,
  so the recursive call got the wrong arity/dict and returned a partial
  application (`Eq`-constrained recursion → non-Bool; `Show` → stack overflow).
  Two root causes in `lib/typecheck.ml`'s `process_letrec_group`: (1) a group's
  own `fun_constraints` entries were registered only *after* the bodies were
  inferred, so a self/mutual-recursive constrained occurrence saw no entry and
  recorded no dict route at all (`r` stayed `None` → eval applied zero dicts) —
  fixed by a Pass A that pre-registers each member's constraints before any body
  is inferred (the post-inference pass stays authoritative, clearing the
  pre-registration if the constraint var doesn't generalize); (2) the recursive
  callee is the group's *monomorphic* placeholder, so `instantiate_raw` yields an
  empty substitution and the constraint var ids couldn't be mapped to a type —
  fixed by `find_tvar_in_mono`, which recovers the enclosing function's own live
  tyvar by id from the occurrence's type so `find_enclosing_dict` routes the
  self-call to that function's dict (`RDict`). Regression tests:
  `test/test_eval.ml` "recursion" group (`rec Eq-constraint`,
  `rec Show-constraint`, `rec mutual constraint`).
  - **`Show (List a)` simplified to a top-level `showListItems` helper**, once
    the doctest-harness duplication below was fixed.
- **Doctest harness no longer prepends the prelude to the prelude.** ✅ FIXED
  (2026-05-31). `medaka test stdlib/core.mdk` ran the file *and* prepended the
  prelude — which is that same file — duplicating every top-level decl. With the
  `Show (List a)` element join as a top-level constrained helper, the duplicate
  made `show` on a list element resolve to an ambiguous `VMulti`, sending `++`
  into the `append` method (`xs ++ ys`) → infinite loop. `Typecheck.check_program`
  already skipped its internal prelude prepend for core via `program_is_core`;
  `lib/doctest.ml` now mirrors that on the eval side (skip
  `marked_prelude @ …` and the raw-prelude fallback prepend when
  `program_is_core base_decls`). Smoke test: `test/test_doctest.ml`
  "prelude self-doctest no dup".
- **`showsPrec`-style precedence** for `deriving (Show)` and `Show
  Option`/`Result`: nested constructors render ambiguously (`Some (Some 1)` →
  `Some Some 1`). No doctest nests constructors, so non-blocking.

### Phase 75: String/Char primitive kernel + `string.mdk` stdlib 🟡 KERNEL DONE; string.mdk drafted (awaiting user review)

**Goal.** Give strings the same treatment arrays got (Module 4): a tiny
host-backed kernel that holds under self-hosting, with the whole of
`STDLIB.md` Module 3 written in Medaka on top. Design locked 2026-05-31 —
see **STDLIB.md Module 3** for the authoritative extern list and rationale.
Decisions: **codepoint** granularity (UTF-8 backed, `Char` = one scalar
value); **minimal bridge to `Array Char` + a few codepoint-aware perf
externs**; **host-backed full Unicode** for classification/case folding.

**Dependency boundary (verified).** OCaml 5.4 stdlib already provides UTF-8
decode/encode (`String.get_utf_8_uchar`, `Buffer.add_utf_8_uchar`, `Uchar`),
so the bridge + perf + parse externs need **no new dependency**. Only the 7
Unicode classification/case externs need a Unicode database — `uucp` (not
currently installed). This isolates the dependency: everything else lands
dependency-free.

Skill: **add-primitive** for the externs (steps 1–4); **add-language-feature**
for the `s[lo..hi]` codepoint-slice change (step 5, threads eval + the slice
desugar/eval path).

**Ordered implementation steps:**

1. ✅ **DONE (2026-05-31).** **Bridge + Char↔codepoint + perf + parse externs** (no new dep). Add to
   `stdlib/runtime.mdk` and impl in `lib/eval.ml`'s `primitives` table:
   - `stringToChars`/`stringFromChars` — decode/encode over `VArray`/`VChar`.
     `VChar` is a UTF-8 `string`; decode each `Uchar` to a one-codepoint `VChar`.
   - `charCode` (`String.get_utf_8_uchar … |> Uchar.to_int`),
     `charFromCode` (`Uchar.is_valid` guard → `VCon "Some"`/`"None"`, encode via
     `Buffer.add_utf_8_uchar`).
   - `stringLength` (single-pass codepoint count, no array alloc),
     `stringSlice` (codepoint `[lo,hi)`, clamping — walk the UTF-8 boundaries),
     `stringConcat : List String -> String` (fold a `Buffer`),
     `stringCompare` (raw `String.compare` → `Ordering` con; UTF-8 byte order
     == codepoint order).
   - `stringToFloat` (`float_of_string_opt` → `Option`).
   Effect annotations: all pure (no `<…>`). Mirror the array-kernel section
   layout in `runtime.mdk`.

2. ✅ **DONE (2026-05-31).** **Unicode externs via `uucp`** — installed `uucp
   17.0.0`, added to `(libraries …)` in `lib/dune`. Implemented
   `charIsAlpha`/`charIsSpace`/`charIsUpper`/`charIsLower`/`charIsPunct`/
   `charToUpper`/`charToLower` in `eval.ml` (decode `VChar`→`Uchar`, query
   `Uucp.Alpha`/`Uucp.White`/`Uucp.Case`/`Uucp.Gc`). `charToUpper`/`charToLower`
   are `Char -> Char`, identity where `Uucp.Case.Map` expands 1→N. **Added two
   externs beyond the original plan:** `stringToUpper`/`stringToLower :
   String -> String` do the full-fidelity expansion (`Straße → STRASSE`),
   because `Char -> Char` can't — so `String.toUpper` wraps these, not
   `map charToUpper`. Helpers `char_uchar`/`uchar_to_string`/`utf8_case_fold`
   in `eval.ml`. Tests: `test/test_run.ml` "string unicode".

3. ✅ **DONE (2026-05-31, draft — awaiting user review).** **`stdlib/string.mdk`**
   — wrote the Module 3 surface in Medaka over the kernel. 144 bindings,
   **45/45 doctests pass**.
   - **Perf posture (per user: practical > pure).** Internals favour what the
     machine likes over `List Char`: tier 1 — operate on the String directly
     (`startsWith`/`endsWith` = `stringSlice` + `==`; `take`/`drop`/`slice`/
     `concat`/`join`/`repeat` via the string externs); tier 2 — decode once to
     `Array Char`, scan by **index** with O(1) `arrayGetUnsafe`, then carve out
     `stringSlice`s or rebuild via `stringFromChars` (`indexOf` substring scan
     → `contains`/`split`/`replace*` derive from it; `trim*`/`words` find
     boundary *indices* then slice, no rebuild; `reverse` via `arrayMakeWith`;
     `capitalize` = first char + slice; `toInt` index-scan). No internal
     `List Char`. Codepoint-correctness verified on multibyte (`→`/`λ`/`é`).
   - **`toChars : String -> Array Char`** (was `List Char`) — returns the native
     array; list is opt-in via `Array.toList`. `fromChars : List Char -> String`
     kept (permissive consumer form).
   - ✅ **`stringIndexOf` kernel extern added** (host byte search → codepoint
     index; UTF-8 self-synchronizing ⇒ byte search is codepoint-correct).
     `indexOf` wraps it and `contains`/`split`/`replace*` derive from `indexOf`,
     so all are host-speed (the `Array Char` scan helpers were removed).
     `eval.ml` helpers `byte_search`/`utf8_cp_at_byte`. Test: `test_run.ml`
     "string indexOf".
   - Naming decisions made (flagged for review):
   - `toUpper`/`toLower` are the **String** versions (wrap `stringToUpper`/
     `stringToLower`); Char-level case mapping is the externs `charToUpper`/
     `charToLower` directly (can't have two `toUpper` in one module).
   - **Omitted** `length`/`isEmpty` (clash with `Foldable` methods — use
     `stringLength`/`s == ""`), `fromInt`/`fromFloat` (clash with `Num.fromInt`
     — use the globals `intToString`/`floatToString`), `count`/`lastIndexOf`
     (`count` clashes with the core standalone). All are open for the user to
     rename/re-add.
   - `Eq`/`Ord`/`Semigroup`/`Monoid`/`Show` for String/Char already live in
     `core.mdk` — **not** redefined here (would conflict).

4. ✅ **DONE (2026-05-31).** `import string.{…}` resolves via sibling-root module
   lookup (same as `list`/`array`); no embed change (string is a normal imported
   file, not prepended). Verified with an import smoke test.

5. ✅ **DONE (2026-05-31).** **Codepoint-consistent bracket slice.** `ESlice`
   on `VString` used byte-based `String.sub`, splitting multibyte chars. Now
   bounds-checks against the codepoint count and cuts on codepoint boundaries
   (`utf8_length`/`utf8_byte_offset`), keeping panic-on-OOB to match the array
   bracket. Syntax is dot-bracket `s.[lo..hi]` (OCaml-style). Test:
   `test/test_run.ml` "string bracket slice".
   - **`s.[i]` single-codepoint index deferred.** `EIndex` only unifies its
     receiver with `Array a` in `typecheck.ml` (strings are rejected at
     typecheck, so there's no eval inconsistency to fix — it's a *new feature*,
     not a bug). Adding `String -> Int -> Char` indexing needs a type-directed
     `EIndex` branch like `ESlice` already has; tracked as the open sub-decision
     below.

6. ✅ **DONE (2026-05-31).** **Tests.** `test/test_run.ml` gained the kernel
   smoke ("string kernel"), the codepoint-vs-byte regression on multibyte
   `"héllo→"` ("string codepoint"), the Unicode/ß-expansion case ("string
   unicode"), and the codepoint bracket-slice ("string bracket slice").
   `stdlib/string.mdk` carries 45 doctests (`medaka test stdlib/string.mdk`).
   All 15 suites pass.

**Open sub-decisions:**
- ✅ `uucp` dependency (step 2) — resolved: installed.
- `stringToInt` left as Medaka (`digitToInt` fold in `string.mdk`'s `toInt`);
  promote to extern only if parsing robustness/perf demands it.
- `s.[i]` single-codepoint indexing — currently unsupported (typecheck rejects
  strings in `EIndex`). If wanted: add a type-directed `EIndex` branch
  (`String -> Int -> Char`) backed by a codepoint get (or `stringSlice i (i+1)`
  at the Medaka level). Deferred; not blocking string.mdk. → Phase 77.

**Deferred decision — Char/String module split + prelude name collisions (next session).**
`string.mdk` omits `length`/`isEmpty`/`count` and uses `charToUpper` (not a Char
`toUpper`) to dodge name clashes. Investigated whether splitting into
`char.mdk` + `string.mdk` would help — it mostly doesn't:
- The only *Char-vs-String* clash is `toUpper`/`toLower`; splitting fixes that
  one (and both become usable via qualified access, `char.toUpper` /
  `string.toUpper`, which Medaka already supports).
- `length`/`isEmpty`/`count`/`map`/`filter` clash with the **prelude**, which is
  prepended to *every* module — splitting changes nothing for these. Tested:
  defining a standalone `length` errors *inside* `core.mdk:798`, `count` inside
  `core.mdk:520` (core re-resolves its own internal use to the new binding).
  `fromInt : Int -> String` *does* typecheck (core doesn't use it internally),
  so the original draft was over-conservative omitting it.
- Real root cause: Medaka's prelude is **prepended source**, so its names are
  unconditionally in scope and **unshadowable** (unlike Haskell, where
  `Data.Text.length` shadows `Prelude.length`). The genuine lever is letting a
  module shadow prelude names — which would also let `array.mdk` reclaim
  `length`/`isEmpty`/`toList`. (The root cause turned out NOT to be the resolver
  but downstream name-keyed coalescing + a global method-name set; see Phase 78.)
- Options on the table: (a) split for organization only; (b) fix prelude
  shadowing; (c) keep as-is; (d) both. Undecided. Option (b) is now tracked as →
  Phase 78 (split into 78a plain-function / 78b interface-method).

**Follow-up (separate bug, surfaced while writing `string.mdk`):**
- **A string literal that *starts* with a newline collapses to part-of/empty.**
  `lib/lexer.mll`'s `strip_indent` (multiline-string dedent) fires on *any*
  `STRING` whose first byte is `\n`, so the literal `"\n"` lexes to `""` and a
  lone-newline string is unwritable. `string.mdk` works around it by building
  the separator from `charFromCode 10` (`nl` helper). Candidate fix: only apply
  `strip_indent` to triple-quoted strings (or never collapse a 1-char `"\n"`).
  → Phase 76.

---

## Outstanding non-stdlib gaps (2026-06-01 PLAN.md review)

These were surfaced by a sweep of §5 and the audit subsections: everything
that is genuine outstanding work, *not* the standard library and *not* blocked
by it. (The stdlib-coupled residue once parked under "Phase 19 stdlib/typeclass
wiring" has mostly landed: `==`/`!=` `Eq` checking and `Num`/`Ord` operator
wiring to `core.mdk` interfaces are **done** via Phase 52 — corrected
2026-06-02. The one survivor is the `do`→`Thenable` desugar, still excluded
here.) Each is independently shippable; pick one per session.

### Phase 76: Lexer string-literal fixes ✅ DONE

Two string bugs were scheduled here; on investigation only one was still real:

- **Triple-quoted strings drop `\{…}` interpolation.** — **Was already fixed in
  Phase 59** (`0609b51`): `read_triple_string` + `read_interp_triple_continue`
  already emit `INTERP_OPEN`/`INTERP_MID`/`INTERP_END` like the single-quoted
  rules. The eval side was even covered (`t_interp_triple_basic/_two_holes`);
  the only gap was *parser* coverage. Phase 76 added the missing parser tests
  (`test_interp_triple`, `test_interp_triple_two_holes`).
- **A literal that starts with `\n` collapses.** — **Fixed.** Root cause:
  `strip_indent` (multiline dedent) keyed on the first byte being `\n`, which
  conflated an *escaped* `\n` with a *raw* source newline, so `"\n"` lexed to
  `""` and `"\n  foo"` dedented to `"foo"`. Naively skipping dedent for
  single-quoted strings is wrong — single-quoted *raw-newline* multiline
  literals are a real feature (`test_string_multiline`). Fix: a
  `string_raw_leading_nl` flag, set only when the literal's first content char
  comes from a **raw** source newline (the catch-all in `read_string` / the
  `'\n'` rule in `read_triple_string`), reset at every opening quote; dedent
  fires only when the flag is set. Applied symmetrically to single- and
  triple-quoted close rules (so `"""\nfoo"""` with an *escaped* leading newline
  no longer dedents either). Eval tests added: `t_lone_newline`,
  `t_leading_newline_indent`.

`stdlib/string.mdk`'s `nl = charToStr (unwrapChar (charFromCode 10))` workaround
(plus its now-orphaned `unwrapChar` helper) was simplified to `nl = "\n"` once
the lexer fix landed.

Scope: `lib/lexer.mll` + parser/eval tests. No grammar/AST change.
Skill: **add-language-feature** (lexer-local).

### Phase 77: `s.[i]` single-codepoint string indexing ✅ DONE (2026-06-01)

`s.[lo..hi]` codepoint slicing worked (Phase 75 step 5) but `s.[i]`
single-codepoint indexing did not — `EIndex` only unified its receiver with
`Array a` in `typecheck.ml`, so strings were rejected at typecheck (no eval
inconsistency; a missing feature, not a bug).

Done: rewrote the `EIndex` typecheck arm (`lib/typecheck.ml`) to be
type-directed on the normalized receiver head, paralleling the `ESlice` branch —
`String -> Char`, `Array a -> a`, `List a -> a`, `TVar` defaults to Array. Added
a `VString` arm to the `EIndex` eval match (`lib/eval.ml`) backed by an inline
codepoint get (`utf8_length`/`utf8_byte_offset`, returning the one-codepoint
`VChar`), panic-on-OOB to match the array bracket.

Also closed a **pre-existing gap**: `EIndex` eval already handled `VList`, but
the old typecheck arm unconditionally unified the receiver with `Array a`, so
`xs.[i]` on a `List` was rejected at typecheck despite working in eval. The
type-directed rewrite adds the `List a -> a` branch, so list indexing now
typechecks consistently.

Tests: `test/test_run.ml` ("string bracket index", "string bracket index oob"),
`test/test_typecheck.ml` ("index array/list/string"). Skill:
**add-language-feature** (threaded typecheck + eval; parser/resolve/desugar/
printer unchanged — `s.[i]` already parsed to `EIndex`).

### Phase 78: Prelude name shadowing ✅ DONE (78a + 78b; 78c won't-do)

The prelude (`core.mdk`) is **prepended source** (re-elaborated and concatenated
ahead of every user program), so its names (`length`, `isEmpty`, `count`, `map`,
`filter`, `toList`, …) are unshadowable — defining a standalone one in a module
errors *inside* `core.mdk`. This blocks several stdlib naming compromises
(`array.mdk`/`string.mdk` can't reclaim natural names; see Phase 75's deferred
decision).

**Root cause is NOT the resolver** (the original framing was wrong). `resolve.ml`
preserves the AST and silently `Hashtbl.replace`s on a top-level collision
(`add_or_skip`) — it neither errors nor renames, and needs no change. The
breakage is downstream, in two distinct modes:

- **(A) plain function** (`count`, `core.mdk:573`): `group_fundefs`
  (`typecheck.ml`) coalesces single-clause `DFunDef`s **by name** into one merged
  multi-clause function, and `eval.ml`'s `fundef_acc` does the same — so a user
  `count` and the prelude `count` merge, the bodies unify-fail against one
  signature, and the error is reported inside `core.mdk` (prelude clause first).
  Root cause: name-keyed coalescing with no prelude-vs-user origin.
- **(B) interface method** (`length`/`isEmpty`/`toList` are Foldable methods,
  `core.mdk:476-478`; `map` Functor; `filter`): `method_marker` builds its
  method-name set from `[Prelude.program; prog]` and unconditionally rewrites
  every `length x` → `EMethodRef`, so the user can't reference their own
  definition; compounded by the env double-binding (placeholder vs method scheme)
  and the same coalescing. Root cause: a global, prelude-inclusive method-name
  set capturing the name before any shadowing notion exists.

The prelude is concatenated at 5+ chokepoints that must stay consistent
(`check_program`, `typecheck_module`, `check_repl_decl`, `eval_program`,
`make_repl_eval_state`, doctest). The motivating `array.mdk` goal
(`length`/`isEmpty`/`toList`) is the **(B)** case.

**Mechanism (both sub-phases):** origin-tagging + shadow-aware marking — *not*
alpha-renaming methods (renaming a method name breaks dispatch coherence:
`iface_methods`/`impl_key`/`EMethodRef` payloads/`check_coherence` all key on the
original name). Shadow-aware marking skips `EMethodRef`/`EDictApp` for any name
the user shadows; origin-aware coalescing keeps user and prelude clauses
separate; the specific names the prelude calls internally keep a prelude-internal
binding so core's own references still resolve.

Skill: **add-language-feature** (threads `method_marker` → `typecheck` → `eval`
plus the prepend drivers; shadowing is a name-resolution rule, not a typechecker
correctness bug). `harden-typechecker` is a secondary lens for 78b's
env-binding precedence inside `typecheck.ml`.

#### Phase 78a: Plain-function shadowing ✅ DONE

Stepping stone; ships standalone. A user top-level `DFunDef`/`DLetGroup` name may
shadow a prelude **plain function** (the `count` case). Does not touch dispatch.

Mechanism: **drop-on-shadow**, in `method_marker.ml`. `prelude_for prog` returns
`marked_prelude` with the plain functions `prog` shadows (and their type sigs)
removed — via `List.filter`, so surviving decls keep object identity and the
in-place `EMethodRef`/`EDictApp` refs typecheck fills stay shared with eval.
Dropping is restricted to `droppable_prelude_fns`: standalone prelude `DFunDef`s,
not interface methods, **not referenced by any other prelude declaration** (a
name the prelude uses internally is left in place — shadowing it still hits the
old coalescing path rather than silently rebinding the prelude's use; e.g.
`identity`, used by `toList = identity`, is not droppable). `mark_with_prelude`
also drops a shadowed name from the constrained-fn set unless the user
re-declared it constrained, so the user's reference stays a bare `EVar`.

Wired at the single-file driver chokepoints only: `check_program`
(`typecheck.ml`), the paired eval prepends in `bin/main.ml` (run/prop/bench),
`doctest.ml`, and the `test_run` typed helper. **Multi-module** (`typecheck_module`
+ combined eval) and the **REPL** still use the full prelude — multi-module
shadowing was investigated and dropped (see 78c: `array.mdk` already gets these
names via interface impls, so it has no consumer).

Diagnostic: shadowing a **non**-droppable name (one the prelude uses internally)
still coalesces the user clause with the prelude's. A *compatible* merge keeps
type-checking unchanged (no behavior change); an *incompatible* one previously
errored with a confusing `core.mdk`-located type mismatch. `check_program` now
wraps `check_program_impl` and, when the program shadows such a name and the run
errors at a prelude location, re-raises `CannotShadowPrelude` (`typecheck.ml`)
pointing at the user's own definition — "rename your definition." This is
post-hoc (no name reservation), so it never rejects a program that previously
type-checked.

Tests: `test_run` `prelude fn shadow`, `test_typecheck` `user fn shadows prelude
plain fn`. Done: a single file defining a standalone `count` type-checks and runs
with the module's `count`; an untouched prelude method (`length`) still resolves.

#### Phase 78b: Interface-method shadowing (single-file) ✅ DONE

Single-file method shadowing; the multi-module `array.mdk` unblocker is split out
to 78c. A user top-level binding may shadow a prelude **interface method**
(`length`/`isEmpty`/`toList`, `map`, `filter`) — even with a type the method
could never have (`length : Int -> Int`).

The blocker: the EVar infer branch routes any name in `env.method_iface` through
dispatch regardless of `EMethodRef` marking (`typecheck.ml`), so a bare user
`length` is still treated as the method. Shadow-aware marking alone can't fix it
— the name is globally a method.

Mechanism (**user-side rename**, the dual of 78a): `Method_marker.shadow_rename`
renames the user's shadowing binding (and its in-module refs) to an internal name
`length#shadow` (`#` can't occur in a source ident). The renamed name isn't in
`method_iface`, so it type-checks and evals as an ordinary function, while the
prelude's method + impls + internal uses are untouched. No dispatch/eval changes.
Restricted to **safe** names — a shadowed method name never also bound by a local
pattern anywhere (so a plain substitution can't capture); an unsafe one is left
alone and falls through to the `CannotShadowPrelude` diagnostic (now extended to
method names). Applied in `mark_with_prelude` (for the eval-bound program) and,
idempotently, in `check_program` (so LSP/diagnostics, which skip marking, stay
consistent). `check_program` strips the sentinel from returned env keys
(`strip_shadow`), so the binding is reported under its original name.

Tests: `test_run` `prelude method shadow` (user `length` wins; `isEmpty`/`toList`
still dispatch for List/Option), `test_typecheck` `user fn shadows prelude
method`. Limitations: single-file only (multi-module investigated and dropped —
see 78c); shadowing a method name that is also locally rebound is rejected with
the diagnostic rather than renamed.

#### Phase 78c: Multi-module method shadowing 🚫 WON'T DO (investigated 2026-06-01)

Investigated and dropped — the motivating need is already met without it.

- **`array.mdk` doesn't need standalone shadowing.** It already provides
  `length`/`isEmpty`/`toList` via `impl Foldable Array` (and `map` via
  `impl Mappable Array`), with an O(1) `length arr = arrayLength arr`
  ([array.mdk:83-85](stdlib/array.mdk) documents this as deliberate). The
  interface-impl mechanism is the idiomatic solution; `length someArray` already
  works. So 78c's stated goal is already achieved.
- **`string.mdk` can't use that route** (`String : *`, but `Foldable` needs
  `* -> *`), so it uses the global `stringLength` / `s == ""`
  ([string.mdk:32-34](stdlib/string.mdk)). That is the only genuinely unsolved
  case — and standalone shadowing doesn't safely solve it either: **exporting** a
  bare `length : String -> Int` would shadow `Foldable.length` in every importer
  (so `length [1,2,3]` on a List would type-error). The only safe benefit is
  internal cosmetics (string.mdk's own body writing `length` over `stringLength`).
- **Cost vs benefit.** Extending the 78b user-side rename to the multi-module
  path (per-module `shadow_rename` in `bin/main.ml`'s mark step +
  `typecheck_module` + combined eval) also needs a **module-unique** sentinel —
  the flat combined-eval namespace ([bin/main.ml:546](bin/main.ml)) would
  otherwise collide two modules' `name#shadow` bindings. ~40-60 lines of intricate
  plumbing for a cosmetic gain with no safe export path.
- **The real user-facing fix is stdlib design, not a compiler feature**: make
  `length` a separate `Sized`/`HasLength` interface (`length : a -> Int`, `a : *`)
  implemented for String/Array/List, instead of a `Foldable` method — sidestepping
  shadowing entirely. That belongs to the stdlib author, not this phase.

Phase 78 ships as **78a** (plain-function shadowing) + **78b** (single-file
interface-method shadowing). Reopen 78c only if a future module has a genuine,
non-cosmetic need that interface impls can't serve.

### Phase 79: Effect-polymorphic higher-order functions ✅ DONE

Full effect inference via **open effect rows** (a label set + optional tail
variable). `map (x => println x) xs` now infers `<IO>`; pure callbacks stay
pure; an annotated-pure HOF with an effectful callback reports `EffectEscape`.

Shipped in sub-phases:
- **79a** — `effrow` representation (replaces `effect_set = string list` in
  `TFun`; `scheme` gains an effvar-id list); zero behaviour change.
- **79b** — `<IO | e>` row-bar surface syntax (parser/AST/printer/`from_ast_type`
  with a shared `~etbl`).
- **79c** — effect-row unification (`unify_row`: open/open link via a shared
  tail, open/closed absorb) + effvars threaded through occurs/level/generalize/
  instantiate (`free_effvars`, `subst_row`); inference arrows become open.
- **79d** — ambient effect threading in `infer` (`cur_effect`: application
  performs the called arrow's effect; a lambda/clause's body effect becomes its
  arrow's latent effect). Effect polymorphism falls out for user-defined HOFs
  with bodies.
- **79d-stdlib / 79f** — `<e>` annotations on the HOF signatures in
  `core.mdk`/`list.mdk`/`array.mdk` (interface methods carry no body at the call
  site, so they need the explicit callback→result link; internal `*Go` helpers
  too, since a closed helper arrow kills the effect mid-chain).
- **79e** — retired the post-HM effects pass; escape checking now happens inline
  at each binding's boundary (compare inferred body effects vs `declared_effects`
  of the signature). `let mut`/field reassignment performs `<Mut>` in `infer`.

**Grammar fix landed here:** an effect annotation now wraps the full following
application (`ty_app`, not a single `ty_atom`), so `<e> List b` means
`<e> (List b)`. Previously a multi-atom return after `<…>` silently dropped the
effect — a latent footgun in the pre-existing `<IO>` grammar too.

**Known limitations:** the single-tail row can't express the union of two
distinct effect variables, so a 2-callback combinator (`compose`/`pipe`) shares
one `e` and under-reports a *mix* of differing concrete callback effects.
Ambient unification is an over-approximation at control-flow joins (sound for
"may-perform"). `ap`/`mapErr` left unannotated (edge cases).

### Phase 80: Multi-level field assignment `a.b.c = e` ✅ DONE

`DoFieldAssign` now carries a field **path** (`ident * ident list * expr`) and
supports multi-level chains `a.b.c = e`, not just single-level `x.field = e`
(Phase 28). The base must still be a bare `let mut` variable; only the path
deepens.

Shipped across the pipeline:
- **Parser** — a `flatten_field_path` helper turns the `EFieldAccess` chain on
  the LHS into `(base_var, [f1; …; fn])`; grammar productions unchanged (still
  `expr EQUAL expr`), so the conflict count holds.
- **Typecheck** — the per-level field-type lookup (`Ref .value` + record-field
  resolution) is extracted into `field_type_of` and `List.fold_left` over the
  path; the leaf type unifies with the RHS. `<Mut>` is performed as before, so
  multi-level assignment still propagates the effect to callers.
- **Eval** — a shared recursive `update_path` walks the chain: records rebuild
  copy-on-update, a `Ref .value` step mutates the cell in place (shared
  identity, so surrounding records need no re-shadow). Non-final statements
  shadow the base var with the rebuilt top; a final-statement assignment runs
  the walk for its side effects (in-place `Ref` mutations persist) and discards
  the rebuilt record. Wired into both `eval_block` and `eval_do`.

Tree-sitter needed no change — `field_access` is already recursive on its
object, so the LHS depth was never constrained. Skill: **add-language-feature**.

### Phase 81: DoBind pattern & final-statement grammar limitations ✅ DONE

The two originally-listed restrictions (cons/literal DoBind LHS rejected;
a do-block's last statement couldn't start with an uppercase constructor) were
already resolved by a pre-Phase-81 fix that moved the do-block `stmt` LHS to the
expression-first form (`expr_no_block LARROW …` + `expr_to_pat`), so the
`LARROW` lookahead alone decides bind-vs-expression. Phase 81 closed it out:

- **Finished the expr-first conversion** for the two other pattern-or-expression
  positions — the list-comprehension `lc_qual` generator and the `guard_qual`
  bind — which removed the entire `pat_atom`-vs-`expr_atom` reduce/reduce family.
  Conflict count dropped from 8 S/R + 6 R/R to **2 S/R + 1 R/R** (the three
  intended record-literal / wildcard-lambda / Map-KV conflicts).
- **As-patterns in expression-LHS binding positions** (do-binds, lambda params):
  added a whitespace-sensitive `@` — adjacent `x@p` lexes as a new `AS_AT`
  as-pattern operator, spaced `fn @Impl` stays the impl-hint `AT`, so the two
  no longer collide. `expr_aspat` + `EAsPat` (lowered to `PAs` by `expr_to_pat`;
  rejected by resolve elsewhere). Fixed a latent bug where `xs@rest => body` was
  silently misparsed as a two-arg lambda.
- Rewrote the stale `parser.mly` conflict audit; regression tests in
  `test_parser`/`test_roundtrip`/`test_eval`.

Residual (documented, not a regression): `_` after an operator in a binding LHS
parses as a left section, not a wildcard (`(x :: _) <- m` — use a named tail);
inherent to the expression-first parse and shared by all binding LHSs.

### Phase 82: CLI surface completion ⏳ TODO (partial)

The design spec lists `new build run check test fmt lsp doc add remove update`;
today `check / run / test / repl / lsp / fmt / new` exist. Non-stdlib,
non-package-manager gaps:

- `medaka run --release` — ✅ flag plumbing. Accepted and parsed; currently a
  transparent alias for `run` (no optimizer yet).
- `medaka check --json` — ✅ machine-readable diagnostics, reusing the LSP
  diagnostic shape via `Lsp_server.diagnostics_to_json`. Routes through
  `Diagnostics.analyze` so every diagnostic is reported (not exit-on-first).
  Output: `{"file": …, "diagnostics": [ <LSP Diagnostic> … ]}` on stdout; exit
  1 iff any `Error`-severity diagnostic. **Single-file only** — `analyze` does
  not invoke the multi-file loader (see §5); multi-file `--json` is a follow-up.
- `medaka build` — ⏳ TODO. Split out: "typecheck + cache" has no honest
  implementation yet — there is no artifact cache or AST/typed-IR serialization
  format in the tree. Needs its own design before it's more than an alias of
  `check`.
- `medaka doc` — ⏳ TODO. Split out: doc comments are not attached to AST nodes
  (a parallel `Lexer.take_comments()` stream matched by position, like
  `doctest.ml`), and there is no pretty-printer for a typechecker `scheme`.
  Needs a comment→decl matcher + signature renderer + an output-format decision.

(`add`/`remove`/`update` need a package manager — out of scope until one
exists.) Skill: none specific; `--json`/`--release` landed in `bin/main.ml` +
`lib/lsp_server.ml`.

### Phase 83: Constraint inference for constrained functions ✅ DONE

Phase 20 added constraint *syntax* and call-site obligation checking, but not
constraint **inference**: a caller that used a constrained function
polymorphically had to re-annotate the constraint itself (e.g. a wrapper over
`eq` had to carry `Eq a =>` explicitly or it lost the constraint silently —
`myEq x y = eq x y` type-checked but `myEq Blob Blob` slipped past the checker).

Done in `lib/typecheck.ml`, all in `process_letrec_group`:

- **Harvest.** Snapshot `constraint_obligations` *and* `method_usages` around the
  Pass-B body inference; the entries added are the constraints the bodies impose
  (a direct method call like `eq` lands in `method_usages` carrying the interface
  + its instantiated param vars; a call to another constrained function lands in
  `constraint_obligations`).
- **Attribute.** After `gen_restricted`, an obligation/usage whose discriminating
  var lands in the binding's generalized `bound_ids` is polymorphic in that
  scheme; concrete ones are left to the post-HM obligation pass.
- **Unsignatured binding** → register the inferred constraints (super-expanded)
  in a **new** `env.inferred_constraints` table.  The EVar call-site recorder
  consults it so a polymorphic wrapper's missing-impl error fires and propagates
  transitively.  It is **deliberately invisible to `find_enclosing_dict` /
  `dict_pass`**: the marker runs before inference and never wraps these calls in
  `EDictApp`, so routing an inner method to a `$dict_<fn>_<slot>` param that
  dict_pass never creates would crash at eval.  Inner methods in such bodies
  dispatch by runtime arg tag instead — correct for argument-dispatched wrappers
  (the realistic case).  Exported/imported across modules alongside
  `te_fun_constraints` for obligation-checking only.
- **Signatured binding with an insufficient context** → a new
  `UnsatisfiedConstraint` `type_error`: the body's required constraints must be
  entailed by the declared set (incl. superinterfaces via `expand_supers`), else
  reject at the offending call site (`fail_at`).  (A prelude-name collision in a
  test — redefining `identity : a -> a` — surfaced this correctly and was fixed
  by renaming the test fixture.)

Tests: `test/test_typecheck.ml` "constraint inference (Phase 83)" (propagation,
transitivity, concrete-ok, concrete-pins-no-constraint, insufficient-signature,
superinterface-entailment) and `test/test_eval.ml` "inferred wrapper true/false"
(runtime arg-tag dispatch end-to-end).

**Residual / deferred follow-up:** full runtime dict-threading *into* an inferred
body (so it works in return-position / higher-order dispatch) would require
re-running the marker after typecheck against the final constraint tables — a
pipeline restructure touching the single-file / multi-module / REPL drivers.
Likewise self-/mutually-recursive *unsignatured* wrappers under-infer their own
recursive-call routing (Pass A only pre-registers from explicit signatures).
Both are deferred, mirroring the Phase 69.x → 74 layering.

### Phase 84: Monad dispatch for polymorphic do-blocks ✅ DONE (single-file)

A do-block in a function **polymorphic over its monad** mis-dispatched its
return-position `pure`. Repro (used to panic at `core.mdk:401`, the List `pure`):

```
f m = do
  x <- m
  pure x
main = match f (Some 5)
  Some v => println "ok"
  None => println "none"
```

**The bug was narrower than first described.** The PLAN's `detect_monad` /
`current_monad_type` eval machinery is stale (removed in Phase 69.x-c;
`eval.ml`'s `EDo` arm ignores the tag). Two findings drove the fix:

- **Bind already worked.** `x <- m` dispatches through the `andThen` VMulti by the
  *runtime value* of `m` (`eval_do`), so `Some 5` picks Option's bind without any
  dictionary. Only return-position `pure` was broken.
- **`pure` had no route.** The do-block typecheck models the monad structurally
  and emits no constraint, but the `pure x` `EMethodRef` already records an
  Applicative usage on `m`; for an unsignatured `f` Phase 83 harvests that into
  `inferred_constraints` — the table **deliberately invisible** to
  `find_enclosing_dict` / `dict_pass` / the marker. So `pure`'s route stayed
  `None` and eval fell back to arg-tag "first impl wins" → List.

**Fix — two-pass elaboration (`lib/elaborate.ml`):** the marker runs *before*
typecheck and only wraps `=>`-signatured functions in `EDictApp`, so making an
*inferred* constraint dict-routable needs a second pass. `Elaborate.elaborate`:
mark → typecheck (discovers promotable names) → if any, re-mark the original tree
with those names treated as constrained → re-typecheck so their inferred
constraints register in `fun_constraints` (route-bearing) → `dict_pass` → eval.
When nothing is promotable (the common case) the second pass is skipped.

- `typecheck.ml`: new `promoted` env field; `check_program_promoting`
  (`?promoted` in, discovery set out); `check_program` is now a single-pass
  wrapper (unchanged for LSP/diagnostics). `process_letrec_group`'s no-sig branch
  registers a promoted name's inferred constraints in `fun_constraints`. The
  discovery set is filtered to **non-recursive user bindings whose inferred
  constraints include `Applicative`** — three guards, each against a concrete
  hazard (prelude-helper arity mismatch; arg-dispatched wrappers that don't need
  it; recursive wrappers whose self-call would be unrouted — Pass A pre-registers
  only signatured fns).
- `method_marker.ml`: `mark_with_prelude ~promoted` unions the promoted names
  into the constrained set.
- Drivers: single-file `run`/`test`/`bench` (`bin/main.ml`) and the test helpers
  (`test_eval` `run_typed`, `test_run` `capture_run_typed`) route through
  `Elaborate`.

Result: the unsignatured polymorphic-monad do-block now dispatches by the
caller's monad — at **parity with the signatured `Applicative m =>` version**.
Verified for Option, List, transitive wrappers (`g x = f x`), and the same `f`
used at two monads in one program; concrete do-blocks and signatured monads are
unchanged. Tests: `test_eval` "do polymorphic monad (Phase 84)" (6 cases),
`test_run` "poly-monad do-block (Phase 84)". Skill: **add-language-feature**.

**Known limitations (deferred):**
- **`Result e` with a free `e`** (`f (Ok 5)`) still mis-dispatches `pure` — but
  the **signatured version fails identically**, so this is a pre-existing
  dict-resolution gap for multi-param type ctors with a free param, orthogonal to
  Phase 84, not a regression.
- **No-bind do-block** (`do { pure x }`): the monad is groundable only from
  surrounding type context; when the context pins it (e.g. a `match` on the
  result) it works, otherwise it falls back to arg-tag as before.
- **Self-/mutually-recursive** unsignatured monad wrappers are excluded from
  promotion (would hit a dict-arity mismatch); they stay on arg-tag dispatch.
- **REPL and multi-module** drivers are not yet on the two-pass path → Phase 87 /
  Phase 88 below.

### Phase 85: `_` after an operator in a binding LHS is a section, not a wildcard ✅ DONE

Every binding LHS (do-bind, lambda param, list-comp/guard generator) is parsed
as an expression and converted by `expr_to_pat` (`parser.mly`). In expression
context `_` is the operator-section placeholder, so `(x :: _) <- m` parses as the
section `SecLeft(x, "::")` and `expr_to_pat` rejects it ("Invalid lambda
parameter pattern"). Pattern positions proper (function params, match arms) are
unaffected — they use the `pat` grammar. Repro:

```
g m = do
  (x :: _) <- m   -- fails; `(x :: rest)` works
  pure x
```

Resolution: `expr_to_pat` (`parser.mly`) now maps `ESection (SecLeft (a, "::"))`
back to `PCons (expr_to_pat a, PWild)`. `SecLeft` is only ever built when the
source RHS was `_`, so recovering the discarded wildcard is unambiguous; cons is
the only binary operator that forms a pattern, so other-operator sections
(`(x + _)`) and `SecRight`/`SecBare` keep erroring as before. No grammar
productions changed (header-only edit), so the conflict count stays at 3.
Value-position sections are unaffected (`test_roundtrip`/`test_expr_left_section*`
green). Tests: `test_parser.ml` (`do bind cons wild tail`/`both`, `lambda cons
wild param`) and `test_eval.ml` (`cons wild do bind`, List monad).

### Phase 86: `@Impl` hints reported unbound by resolve ✅ DONE

`medaka check` flagged a valid impl-disambiguation hint as unbound even though the
named impl is registered, so any program using `@Impl` hints got false-positive
diagnostics. The hint resolves correctly at eval time (the `@Name impl selection`
eval tests pass); only resolve's reference check was wrong. Repro:

```
interface Combine a where
  combine : a -> a -> a
impl Additive of Combine Int where
  combine x y = x + y
r = combine @Additive 3 4   -- check: "Unbound variable: @Additive"
```

Fix: `check_expr`'s `EVar` case in `resolve.ml` now accepts any `@`-prefixed
name as a dispatch hint rather than looking it up in the value scope. Unknown
hint names are still rejected — by typecheck's existing `UnknownImplName`
(Phase 32), which carries the interface and concrete type args, so resolve
doesn't duplicate that check or let a typo reach runtime. Covers both
application-argument (`combine @Additive 3 4`) and standalone (`r = @Foo`) forms
through the single `EVar` path. Landed in `lib/resolve.ml`; regression cases in
`test/test_resolve.ml` (`v_at_impl_hint`, `v_at_hint_standalone`).

### Phase 87: Phase 84 two-pass elaboration in the REPL ✅ DONE

Phase 84 fixed polymorphic-monad do-block `pure` dispatch for the single-file
drivers via `Elaborate.elaborate` (mark → typecheck → re-mark `~promoted` →
re-typecheck → dict_pass). The **REPL** was still single-pass, so a polymorphic
monad wrapper defined interactively mis-dispatched its `pure` (arg-tag fallback):
`f m = do { x <- m; pure x }` then `f (Some 5)` rendered `[5]` (List) instead of
`Some 5`.

**Fix.** `lib/repl.ml` `process_item`'s `ReplDecl` branch now mirrors
`Elaborate.elaborate`: snapshot the tc env (`copy_tc_env`), mark+`check_repl_decl`
(pass 1) to discover promotable names, and if any qualify, restore the snapshot,
re-mark the input with those names treated as constrained, and
`check_repl_decl ~promoted` (pass 2) — so their inferred `Applicative` lands in
`fun_constraints` and `dict_pass` threads a dictionary into the body.  When
nothing is promotable (the common case) pass 1 stands, so non-monadic inputs pay
a single pass.  The marker is now a `mark_item extra` closure so pass 2 can
expand the constrained set; the `ReplExpr` branch marks once (a bare expression
introduces no binding to promote — names were promoted when first defined).

- `lib/typecheck.ml`: extracted the Phase 84 promotable-name filter into a
  shared `promotable_from env user_prog` (now used by both `check_program_impl`
  and the REPL); `check_repl_decl` gained `?promoted`, which it installs into
  `env.promoted` after clearing the prior input's set (env persists across REPL
  inputs).
- Regression: `test_repl`'s "two-pass elaboration (Phase 87) / poly-monad pure
  dispatch" — `f (Some 5)` → `Some 5` and `f [1,2,3]` → `[1, 2, 3]` from one
  session; fails `[5]` without the fix.  All base suites green; no new
  `@thorough` failures.

### Phase 88: Phase 84 two-pass elaboration across modules ✅ DONE

Same gap as Phase 87 for the **multi-module** driver: each module was marked once
against the union of constrained signatures and type-checked via
`Typecheck.typecheck_module` with no promotion pass — so a polymorphic-monad
do-block wrapper (`h m = do { x <- m; pure x }`) defined in the main module of a
multi-module program mis-dispatched `pure` (`h (Some 5)` rendered `[5]`).

**Fix.** `bin/main.ml`'s multi-module path now runs the module loop twice via a
factored `typecheck_all ~constrained ?promoted` (mirroring `Elaborate.elaborate`
and the REPL).  Pass 1 marks against the static constrained signatures and
type-checks all modules, collecting promotable names across modules; if any
qualify, it re-marks every module with those names treated as constrained and
re-type-checks with them `~promoted`, so their inferred `Applicative` lands in
`fun_constraints` and `dict_pass` threads a dictionary in.  Nothing promotable ⇒
one pass.

- `lib/typecheck.ml`: `typecheck_module` gained `?promoted` (installed into
  `env.promoted`) and `?promoted_out` (filled via the shared `promotable_from`),
  keeping its 3-tuple return so the other callers (diagnostics, test_loader,
  test_typecheck) are unchanged.  Cross-module promoted constraints flow through
  the existing `te_fun_constraints` export (built from `fun_constraints`), so an
  exported wrapper promoted on pass 2 is route-bearing in importers too.
- Regression: `test_loader`'s "two-pass elaboration (Phase 88) / cross-module
  poly-monad pure dispatch".  All base suites green; no new `@thorough` failures.

**Out of scope (filed as Phase 95).** A do-block wrapper that uses `pure` and is
defined in an *imported* (non-main) module fails to *type-check* with a spurious
`core.mdk: 'flatMap' uses interface Mappable …` — a pre-existing multi-module
super-entailment bug that blocks the promotion machinery before it can run.  The
main-module case (above) is unaffected and is what Phase 88 fixes.

### Gaps surfaced during the 2026-06-01 stdlib completion (Modules 1–4)

All reproduced on the post-merge binary before filing (see notes). Phases 89–93.

### Phase 89: Point-free constraint-polymorphic dispatched defs mis-resolve under multiple impls ✅ DONE

A **point-free** definition of a `(Foldable t, …) => …` function whose body is a
partial application of a dispatched method — e.g. `maximum = fold step None` —
type-errored `Type mismatch: List vs Array` (or `List vs Option`, etc.) as soon
as it was **used at two different `Foldable` containers in one program**. The
eta-*expanded* `maximum xs = fold step None xs` worked. The original PLAN repro
(array import) was a red herring — the trigger is *two uses at different
containers*, not the array import (a single use at either container always
worked).

**Root cause (narrower than first described).** Not a dispatch/CAF-ordering
problem at all: it was the **value restriction**.  `maximum = fold step None` is
a zero-arg binding whose RHS is an *application* (expansive), so
`process_letrec_group` set `is_val = false` and value-restricted it to a
*monomorphic* scheme — **even though it carried an explicit polymorphic
signature**.  The first use pinned `t`/`a`; the second use at a different
container then failed to unify.  Notably eval already coped: the inner `fold`
VMulti dispatches by the runtime container value (arg tag), so it was purely a
typechecker over-monomorphization.

**Fix (`lib/typecheck.ml`, `process_letrec_group`).** Relax the value
restriction for a *signed* binding whose declared type is a **function** (arrow):
generalize it per its signature.  Sound because (a) a closure is immutable, so
sharing its type vars across uses is safe, and (b) `generalize` still respects
Rémy levels, so a *captured* monomorphic cell's var (at the base level) is never
over-quantified.  The **arrow guard preserves the classic protection** — a
non-function expansive binding like `r : Ref (List a); r = Ref []` keeps the
value restriction and stays monomorphic (the polymorphic-reference hole stays
closed).  Such a relaxed binding routes its constraints through
`inferred_constraints`, **not** `fun_constraints` (a new `relaxed` flag): the
marker never wrapped its body's `fold` in an `EDictApp`, so dict-routing would
crash at eval with an unbound `$dict_<fn>_<slot>`; instead its inner methods
dispatch by arg tag and its callers still get obligation checking — exactly the
Phase 83 `inferred_constraints` rationale.  No `eval.ml` change was needed.

**Stdlib payoff.** `maximum`/`minimum` in `core.mdk` are now written point-free
(`maximum = fold step None where …`); the eta-expanded workaround is gone.
Doctests for both on List **and** Array (`minimum (fromList …)`) pass.

Tests: `test/test_typecheck.ml` "point-free constrained defs (Phase 89)"
(generalizes per sig; dual-container use at List + Option; non-function binding
stays value-restricted) and `test/test_eval.ml` "point-free constrained dispatch
(Phase 89)" (runtime dispatch on List, Option, and both-in-one-program). All
base suites green; no new `@thorough` failures.

**Known limitation.** The relaxation is gated on the binding's type being a
function (arrow).  A point-free constrained *non-function* constant
(`myEmpty : Monoid a => a; myEmpty = empty`) stays monomorphic — that needs
return-position dispatch (Phase 93's `minBound`/`pure` family), which is a
separate mechanism.

### Phase 90: Per-use instantiation of a signed recursive HO function leaks (decorate-sort-undecorate monomorphises `sortBy`) ✅ DONE

A recursive higher-order function **with an explicit polymorphic signature** got
monomorphised by one downstream use, breaking its other uses: a
decorate–sort–undecorate `sortOn` forced the shared
`sortBy : (a -> a -> <e> Ordering) -> List a -> <e> List a` to tuples, so an
unrelated `sortBy (x y => compare y x) [3,1,2]` then failed
`Type mismatch: (a, b) vs Int`.

**The genuine (stdlib) case was already fixed** by commit `59a57b7`
("process top-level groups in dependency order", PLAN §2.9): `order_groups_by_deps`
(Tarjan SCC, dependencies-first) processes a signed HOF's non-cyclic callees
*before* it, so the HOF instantiates a real generalized scheme instead of sharing
a live placeholder var that a later tuple-typed use re-links. `stdlib/list.mdk`'s
`sortOn` is back to the once-per-element decorate form and its doctests pass on
List **and** Array; the regression is `test_typecheck`'s "sig poly HOF not
monomorphized by later use".

**Residual found and fixed this session.** The same monomorphization still
reproduced when the recursive HOF reached its callee through **backtick infix**
(`sortBy cmp (x::rest) = cmp x x `seq2` (x :: sortBy cmp rest)`).  `EInfix`
carries its callee as the operator *string*, not an `EVar` — and `infer` looks it
up as an ordinary value (`lookup_var env op`) — but `order_groups_by_deps`'s
dependency collector only matched `EVar`/`EMethodRef`/`EDictApp`, so it **missed
the `sortBy → seq2` edge**, mis-ordered the SCCs, and the placeholder-sharing
monomorphization returned.  Fix (`lib/typecheck.ml`, `order_groups_by_deps`): add
`EInfix (op, _, _)` to the collected reference forms.  Regression:
`test_typecheck`'s "sig poly HOF: backtick callee dependency".  All base suites
green; no new `@thorough` failures.

**Note (latent, not fixed):** `EInfix` is also invisible to `method_marker` and
records no `dict_app_usages`/`method_usages`, so a *constrained* function or
interface method invoked via backtick infix is neither dict-routed nor
obligation-checked.  No stdlib code hits this today; filed as **Phase 94**.

### Phase 91: Guard semantics — fall-through ✅ DONE; compile-time exhaustiveness + inline form ⏳ TODO

Three related guard gaps, all observed writing `list.mdk`:

1. **Fall-through to the next equation — ✅ DONE (Haskell semantics, user-chosen).**
   When a function clause's guards all fail, dispatch now falls through to the
   next *pattern* clause instead of panicking `Non-exhaustive guards`.
   `tk n _ | n <= 0 = []` followed by `tk _ [] = …` / `tk n (x::xs) = …` now
   does the right thing on `tk 9 [1,2]`.

   **Implementation.** A desugared guard chain used to end in
   `panic "Non-exhaustive guards"`; it now ends in `__fallthrough__ ()` — a new
   internal extern (`stdlib/runtime.mdk` + `lib/eval.ml`) that raises
   `Impl_no_match`, the *same* signal a failed pattern raises.  A multi-clause
   function is a `VMulti` whose `apply` already catches `Impl_no_match` and tries
   the next candidate, so guard exhaustion in one clause transparently falls
   through to the next; a single exhausted clause surfaces as a
   non-exhaustive-match runtime error at the boundary (matching Haskell).  No
   change to the `VMulti` dispatch itself.  Lands in `lib/desugar.ml`
   (`guards_to_core` terminator) + `stdlib/runtime.mdk` + `lib/eval.ml`.
   Regressions: `test_eval` "guard fall-through (take/base/classify)" and
   `test_run` "guard fall-through / guard exhausted error (Phase 91)".  All base
   suites green; no new `@thorough` failures.

2. **…detect non-exhaustive guards at compile time** (`exhaust.ml` handles
   pattern matrices but not guard coverage) — today it's a runtime error. ⏳ TODO.
3. **No inline guard form**: `f n _ | n <= 0 = []` is a parse error; guards must
   be on indented continuation lines. ⏳ TODO (`lib/parser.mly`/`lib/lexer.mll`).

Remaining (2) + (3) land in `lib/exhaust.ml` (coverage warning — note guards can
be arbitrary `Bool` so only `| otherwise`/literal-`True` coverage is decidable;
a conservative "guards may not be exhaustive" warning is the realistic target)
and `lib/parser.mly`/`lib/lexer.mll` (inline form — re-measure parser conflicts).
Skill: **add-language-feature**.

### Phase 92: Doctest harness can't reach cross-module instances — String/Char ✅ DONE; general case ✅ DONE

`medaka test <file>` builds its combined program from the **core prelude + that
file only**, so an instance defined in a *sibling* stdlib module was invisible.
`Show String`/`Show Char` lived in `string.mdk`, so any doctest (in any file)
whose result is a `String`/`Char` failed `No impl of Show for String/Char` → and
because the harness is all-or-nothing, *every* example then errored.

**Fix (String/Char — the common case).** `Show String` and `Show Char` moved
from `string.mdk` into the **core prelude** (`core.mdk`), alongside the other
primitive `Show` impls (`Int`/`Float`/`Bool`/`Unit`/`List`/…).  They depend only
on the `showStringLit`/`showCharLit` externs, so the move is dependency-clean,
and String/Char are as fundamental as Int — they belong in the prelude.  Now a
String/Char-result doctest resolves with no import, in stdlib files **and**
arbitrary user files (the prelude is embedded, so it works even outside the
stdlib dir).  `string.mdk` keeps a pointer comment.  Regressions:
`test_doctest`'s "String/Char result resolves (Phase 92)"; all stdlib doctests
(string 49/49, etc.) and base suites green.

**Why not the general "load the full stdlib" fix.** The harness type-checks via
`check_program` (single-file), which flattens everything into one module.
`list.mdk` and `array.mdk` deliberately reuse top-level names (`find`, `map`,
…) that only coexist because they live in *separate* modules — flattening them
merges the clashing names (e.g. `group_fundefs` coalesces two unrelated `find`s
into one multi-clause function), corrupting dispatch.  So a genuine
"any sibling instance reachable" fix (e.g. a `core` doctest that `show`s an
`Array`, whose `Show Array` is in `array.mdk`) needs the doctest harness to run
the **multi-module** typecheck path (`typecheck_module` chain) instead of
`check_program` — a `lib/doctest.ml` rewrite.

**Fix (general case).** `lib/doctest.ml`'s `run_file` now branches: a file with
`import`/`use` declarations goes through `run_file_multi`, which mirrors the
multi-file path of `medaka run`/`check` (`bin/main.ml`) — `Loader.load_program`
the dependency graph, inject the synthetic `__dt_i__` bindings into the **root**
module (the file under test), then resolve → mark → two-pass `typecheck_module`
each module *separately* (so the `find`/`map` name-merge hazard never arises),
then `Dict_pass.run (marked_prelude @ concat modules)` and eval.  A doctest sees
exactly what its module imports.  Two guards keep this honest:
- `run_file_multi` returns `None` (caller falls back to the single-file path)
  when the loader resolved **no real sibling** — i.e. every import was the
  implicit prelude `core`, which `is_prelude_module` filters.  This is what keeps
  `string.mdk` (which redefines the prelude standalone `count`) green: the
  single-file path's `prelude_for` shadow-drops the redefined name, whereas this
  path's full `marked_prelude` would coalesce the two `count`s and fail
  (`core.mdk:627 String vs a -> b`).
- on a multi-module typecheck failure every example reports the type error
  (`build_details` with an `Error` env) rather than degrading to arg-tag eval.

**Non-goal (intentional).** A *reverse* dependency — a `core`/prelude doctest
reaching a downstream module (`Show Array` in `array.mdk`) — is unsupported: the
prelude reaching into a module that imports it is a layering inversion, and the
import graph is the source of truth.  Regressions: `test_doctest`'s "cross-module
instance (Phase 92)" / "cross-module tc failure honest (Phase 92)" (a temp-dir
fixture: a root importing a sibling that exports a smart constructor + `Show`
impl); all stdlib doctests and base suites stay green.

### Phase 93: `Bounded Int` / `Bounded Char` impls (+ bound externs) ✅ DONE

Deferred from the stdlib completion: the `Bounded` interface exists but `Int`/
`Char` have no impls, because `minBound`/`maxBound` are **return-type-polymorphic
nullary constants** (like `pure`/`empty`) needing native bound values, and `Int`'s
bounds are platform-dependent (63-bit OCaml `int`). Scope: add `intMinBound`/
`intMaxBound` externs (`runtime.mdk` + `eval.ml`, via **add-primitive**); define
`impl Bounded Int` and `impl Bounded Char` (Char via `charFromCode` over
`0`..`0x10FFFF`) in `core.mdk` (via **extend-stdlib**). Update STDLIB.md.

**UNBLOCKED (2026-06-02):** Phase 96 fixed nullary return-position dispatch, so
the bound constants now resolve at known types — a local `impl Bounded Bool where
minBound = False; maxBound = True` then `lo : Bool = minBound` / `hi : Bool =
maxBound` evaluate correctly.  Phase 93 can now proceed.

**Resolution (2026-06-02).**  With dispatch already fixed in Phase 96, this was
purely additive — no typecheck/eval change.  Added four nullary-constant externs
(the `pi`/`e` precedent, *not* `VPrim`): `intMinBound`/`intMaxBound` = OCaml
`min_int`/`max_int` (63-bit platform limits), `charMinBound`/`charMaxBound` =
U+0000 / U+10FFFF as UTF-8 (built like `charFromCode`) — in `runtime.mdk` +
`eval.ml`.  Then `export impl Bounded Int`/`Bounded Char` in `core.mdk` simply
forward to those externs (dedicated Char externs chosen over `charFromCode` +
`fromOption`, so no `Option`-unwrap and no throwaway default Char).  Char literals
were *not* an option: the lexer stores char-literal bytes verbatim and doesn't
decode `\u{…}`, so U+0 / U+10FFFF can't be written in source.  Doctests assert
via `charCode (… : Char)` (Int result — Show Char isn't reachable in core) and a
relational `(minBound : Int) < (maxBound : Int)` (platform-stable).  Regressions:
`test_run`'s "nullary Bounded Int/Char (stdlib, Phase 93)" — the *stdlib* impls
(no local impl) dispatched by an annotated result type, via `assert_output_typed`
(typed pipeline required for return-position dispatch).  STDLIB.md gaps closed.
All base suites green.  Skills: **add-primitive** (externs) + **extend-stdlib**
(impls).

### Phase 94: Backtick infix bypasses dict-routing and obligation checking ✅ DONE

Surfaced while fixing the Phase 90 backtick-infix residual.  `a `f` b` parses to
`EInfix (f, a, b)`, which `infer` types via `instantiate (lookup_var env op)` —
an ordinary value lookup that records **no** `dict_app_usages` / `method_usages`
and emits no constraint obligation.  `method_marker` also has no `EInfix` case, so
it never rewrites the operator to an `EMethodRef`/`EDictApp`.  Consequences when
the operator is a *constrained* function or an *interface method*:
1. **No dict routing** — a `Foo a => …` function used as `` x `f` y `` is not
   wrapped in `EDictApp`, so `dict_pass` threads no dictionary; at eval it falls
   back to arg-tag dispatch (often fine for argument-dispatched ops, wrong for
   return-position ones).
2. **No obligation checking** — `` x `eq` y `` at a type with no `Eq` impl is not
   flagged (the prefix `eq x y` correctly is).
No current stdlib code invokes a constrained fn / method via backtick, so this was
latent.

**Fix (marker-only).**  `mark_node` (`lib/method_marker.ml`) now lowers a
method/constrained backtick operator into the prefix application of the marked
reference: `EInfix (op, l, r)` → `EApp (EApp (EMethodRef/EDictApp (ref None, op),
l), r)` (method precedence mirrors the `EVar` arms; `EInfix` is the *only*
producer of backtick infix, so symbolic `EBinOp` operators are untouched).  This
reuses the entire prefix-method machinery: `infer`'s `EMethodRef`/`EDictApp` arms
stash the ref and delegate to the shared `EVar` logic (records
`method_usages`/`dict_app_usages`, emits obligations); `dict_pass` routes the
`EDictApp`; eval reads the stamped `res_route` for return-position dispatch.  No
eval change, no new typecheck node logic.

This **subsumes** PLAN's originally-suggested second part (mirroring the recorder
in `infer`'s bare `EInfix` arm): obligations now flow through the `EVar`
delegation.  We deliberately left the bare `EInfix` arm untouched — every
production driver (`Elaborate.elaborate`, the multi-module path, the doctest
harness) marks before typecheck, so only the bare unit-test `check_program` skips
the marker, and emitting obligations there would be redundant *and* touch the
delicate constraint/instantiation code for no production gain.

Lands in `lib/method_marker.ml` (the two `EInfix` arms) only.  Regressions:
`test_typecheck`'s "backtick return-position key (Phase 94)" (an EMethodRef route
is stamped via backtick — impossible before, when there was no EMethodRef) and
"err: backtick method no impl (Phase 94)" (obligation fires, via the marked
driver); `test_eval`'s "backtick method eval" and "backtick return-position" (a
two-Bool-arg method only the result annotation can dispatch — unreachable by the
old arg-tag `EInfix` path).  All base suites green; no new `@thorough` failures.
Skill: **add-language-feature** (marker + typecheck + eval).

### Phase 95: `pure` in an imported module's do-block breaks `flatMap` super-entailment ✅ DONE

Surfaced while doing Phase 88.  A do-block wrapper that uses `pure` and is defined
in a **non-main (imported) module** failed to type-check with a spurious error
blaming the prelude:
`core.mdk: 'flatMap' uses interface Mappable on a polymorphic value but its type
signature does not require it`.  Minimal repro: `dep.mdk` containing
`export\nf m = do\n  x <- m\n  pure x`, imported by any `main.mdk` (even if `f`
is never used) → error.

**Root cause — a name-collision / scope bug, NOT super-entailment.**  The original
"likely `expand_supers` under-expansion / shared-var leak" guess was wrong (verified
on the binary).  `infer`'s `EVar` branch looks up the callee name in the global
`env.method_iface` / `fun_constraints` / `inferred_constraints` hashtables **by
bare name, ignoring local shadowing**.  The prelude defines
`flatMap f ma = andThen ma f` — its *parameters* are named `f` and `ma`.  When an
imported module exports a top-level binding also named `f` whose inferred
constraints include `Mappable` (via `pure`→Applicative, then `expand_supers`'
Applicative→Mappable), the parameter occurrence `f` in flatMap's body matched
`inferred_constraints["f"]` and recorded a phantom `Mappable` obligation on the
parameter's own tyvar.  That var is in flatMap's generalized `bound_ids`, so it
landed in flatMap's `body_cs`; flatMap's declared `Thenable m =>` closure doesn't
entail `Mappable`, so the Phase-83 `UnsatisfiedConstraint` check rejected it.
Renaming the import to avoid flatMap's parameter names (`f`/`ma`) made the error
vanish — and naming it `ma` moved the error to the `ma` position, confirming the
parameter-collision mechanism.

**Why multi-module-only / imported-only.**  `typecheck_module` seeds
`env.inferred_constraints` from imported `te_inferred_constraints` *before* any
letrec group (including the prepended prelude's `flatMap`) is processed, so the
colliding name is already present when flatMap is checked.  In the single-file
path (`check_program_impl`, no imports) and the *main*-module case, the wrapper's
`inferred_constraints` entry is registered only while processing the user's own
group, which runs **after** the prelude groups — so flatMap is checked before the
collision exists.  This matches the observed asymmetry exactly.  (The trigger is
the wrapper's *inferred constraint set*, not the do-block: `f x = pure x` repro'd
too; an explicit signature on the wrapper avoided it by routing through
`fun_constraints` whose foreign tyvar-id happened not to collide.)

**Fix (`lib/typecheck.ml`).**  Make the three `EVar` constraint-table lookups
scope-aware.  Added an env field `locals : StringSet.t`, populated only by
*body-local* binders inside `infer` (lambda / `let` / `letrec` group / do-`let` /
do-bind / pattern arms, plus `process_letrec_group`'s signatured-with-params clause
binding) via `mark_locals` / `extend_locals` helpers; gated the `method_iface`,
`fun_constraints`, and `inferred_constraints` lookups on `not (StringSet.mem x
env.locals)`.  Locals never have legitimate entries in those tables (only
`process_letrec_group` populates them, only for top-level groups), so the gate
removes only spurious behavior — recursive top-level calls are unaffected (the
top-level name is not a local binder).  This **unblocks the cross-module
exported-wrapper case of Phase 88**: an imported `f m = do { x <- m; pure x }` now
type-checks and dispatches `pure` by the caller's monad (`f (Some 5)` → `Some 5`,
`f [1,2,3]` → `[1,2,3]`).

Regression: `test_loader`'s "local-shadow constraint attribution (Phase 95) /
imported poly-monad wrapper" (asserts no spurious type error + correct cross-module
`pure` dispatch).  All base suites green; no new `@thorough` failures.
Skill: **harden-typechecker**.

### Phase 96: Nullary return-position method dispatch is broken at known types ✅ DONE

Surfaced verifying Phase 93.  A **zero-argument** interface method dispatched by
its *result* type (`empty : Monoid a => a`, `minBound`/`maxBound : Bounded a => a`)
does not resolve even when the type is fully known — it is left as an unresolved
`VMulti` and panics `no matching impl for dispatch` (or stack-overflows when fed
into another method, e.g. `append empty [1,2]`).  Reproduced on every shape:

```
e : List Int
e = empty                       -- panic: no matching impl for dispatch
main = println (show (empty : List Int))   -- same, even with an inline annotation

data Wrap = Wrap Int
impl Semigroup Wrap where append (Wrap a) (Wrap b) = Wrap (a + b)
impl Monoid Wrap where empty = Wrap 0
e : Wrap
e = empty                       -- e stays a VMulti; `unwrap e` → non-exhaustive match
```

The Phase 69 marker rewrites the bare method `EVar` to `EMethodRef`, and
`check_method_usages` *should* stamp an `RKey impl_key` route once the result
type is concrete (param_vars length matches `n_iface_params`, `is_concrete`) —
yet at eval the `EMethodRef`'s route is effectively absent (the `VMulti` is never
narrowed by `select_impl_by_key`).  Unlike `pure : a -> m a` (Phase 84), which has
an argument and dispatches via the do-block / `RHeadKey`/dict route, these have
**no argument and a bare-`a` result**, so the head-key and arg-tag paths never
engage.  The fix is to make a nullary return-position method's `EMethodRef`
route stamp + apply by its resolved result type — a focused but high-blast-radius
change to the method-dispatch machinery (`lib/typecheck.ml` `check_method_usages`
route resolution + `lib/eval.ml` `EMethodRef`), since it is shared by *every*
interface method.  This also subsumes the Phase 84 residual "`pure` in a do-block
with no `<-`".  Add `test_eval`/`test_run` regressions (`empty` at a known type;
a custom Monoid/Bounded constant).  Skill: **harden-typechecker** (spills into
eval dispatch — verify both paths).  Unblocks Phase 93.

**Resolution (2026-06-02): the hypothesis above was wrong — the typechecker was
fine all along.**  Instrumenting `check_method_usages` showed it *does* stamp the
correct route: for `e : List Int = empty`, `param_vars = [List Int]`, `is_concrete`,
and it commits `RKey "Monoid|(List a)|"` — which exactly matches an eval candidate
key.  The bug was purely in **eval** (`lib/eval.ml` `EMethodRef`):
`select_impl_by_key` narrows the `VMulti` to the chosen impl but deliberately
*keeps* its `VTypedImpl`/`VNamedImpl` dispatch wrapper ("so partial application
still works").  For an argument-bearing method that's fine — `apply`'s
`unwrap_tags` strips it on application.  But a **nullary** method is a value,
never applied, so the wrapper leaked into the program: `show`/`append`
re-dispatched on it and panicked, `unwrap` couldn't pattern-match it (`match_pat`
doesn't see through the wrapper).  Fix: in the `EMethodRef` arm, after route
narrowing, strip the dispatch wrapper iff its payload is a *terminal* value (not
a `VClosure`/`VPrim`/`VMulti`/`VThunk` still awaiting application) — a ~10-line
eval-only change.  No typecheck change was needed.  Regressions in
`test_run.ml` (`nullary empty stdlib/custom Monoid`, `nullary minBound/maxBound`)
and `test_eval.ml` (`nullary empty value/custom`); `foldMap` (RDict) and
`decode`/`pure` (RHeadKey) paths unchanged.

### Phase 97: Ordinary-function backtick infix under-accounts effects ✅ DONE

Noticed while doing Phase 94.  `infer`'s bare `EInfix` arm (`lib/typecheck.ml`)
types `a `f` b` as
`unify tf (TFun (tl, open_row (), TFun (tr, open_row (), result)))` — it opens the
two effect rows but, unlike the `EApp` path, **never calls
`perform_effect cur_effect eff`** on them.  So a latent effect carried by the
backtick operator's function type is not propagated into the enclosing effect
context: `` a `f` b `` can type pure where the equivalent `f a b` correctly
requires the effect.

Phase 94 made this **moot for methods / constrained functions** — the marker now
lowers those backtick operators to `EApp (EApp (EMethodRef/EDictApp, l), r)`,
which goes through the effect-performing `EApp` arm.  But an **ordinary** function
used infix stays an `EInfix` node and keeps the leaky arm.  No stdlib code relies
on a backtick-infix effectful ordinary function today, so this is latent.

Fix: thread the two operator-application effect rows through
`perform_effect cur_effect` in the `EInfix` arm, mirroring `EApp` (`lib/typecheck.ml`).
Mind the two whole-program entry points share the `infer` arm, so the one change
covers both.  Add a `test_typecheck` regression: a backtick call to an effectful
ordinary function must require the effect (and the pure form must be rejected),
at parity with the prefix `f a b`.  Skill: **harden-typechecker**.

**Resolution (2026-06-02).**  The `EInfix` arm now binds both
operator-application effect rows (`eff1`, `eff2`) and calls
`perform_effect cur_effect` on each before returning — `` a `f` b `` is `f a b`,
so each curried arrow's latent effect is performed in the current context, exactly
as the nested `EApp` path does.  Three `test_typecheck` regressions
(`e_eff_escape_backtick`, `e_eff_escape_prefix_parity`, `t_eff_backtick_infer`)
pin: an annotated-pure caller using an effectful ordinary fn infix is rejected, at
parity with the prefix form, and an unannotated backtick caller infers `<IO>`.

---

### Phase 98: make `do` load-bearing on `Thenable` ✅ DONE

`do`-notation was **structurally duck-typed**: the `EDo` handler
(`lib/typecheck.ml`) invented a fresh monad tyvar `m`, unified every statement
against `m a`, and **never consulted the `Thenable` interface** — so a `do`
block over a type with no `Thenable` impl type-checked, then either fell through
to direct pattern-matching at eval or misbehaved.  `Thenable` was *inert at the
type level but load-bearing at runtime* (`eval.ml`'s `monadic_ctors` is built
from its impls).  The design question (wire vs. delete) was resolved (with the
user) as **wire via a typecheck constraint** — the minimal option; `Thenable`
stays (it anchors `Mappable → Applicative → Thenable` and feeds `monadic_ctors`),
and eval is untouched.

**Resolution (2026-06-02).**  The `EDo` arm now emits a single constraint
obligation — `("Thenable", [m], loc)` onto `env.constraint_obligations` —
**but only when the block contains at least one `DoBind`**.  Rationale: `<-` *is*
`andThen`, and eval only routes `DoBind` through the `andThen` VMulti — a bare /
`pure`-only / sequencing-only block uses no `andThen` and needs only
`Applicative`, so constraining it to `Thenable` would over-reject (e.g.
`do pure 5` over an Applicative-but-not-Thenable type stays legal).  The
obligation rides the existing post-HM `check_constraint_obligations` pipeline:
concrete `m` with no impl → `NoImplFound (Thenable, …)` (+ transitive
`check_entry_requires` on the impl's `requires Applicative`); polymorphic /
ungrounded `m` is concrete-gated and skipped, so the Phase 83/84 dispatch
residuals don't regress.  No new `type_error` constructor; eval, desugar, and
the runtime bind dispatch are unchanged.  The one arm is shared by both
whole-program entry points (all three `check_constraint_obligations` call sites
discharge it).  Tests: `test_typecheck` gains `e_do_bind_requires_thenable`
(bind over a non-Thenable ADT → "Thenable" error), `t_do_bind_custom_thenable`
(a user `Mappable`/`Applicative`/`Thenable Box` binds and checks — proving the
gate is interface-driven, not a hardcoded monad list), and
`t_do_pure_only_no_thenable` (the refinement: a `pure`-only `do` over an
Applicative-not-Thenable type still checks); `test_eval` gains
`t_do_custom_thenable` (the `Box` stack evaluates end-to-end).  The existing
`t_poly_monad_signatured` was tightened from `Applicative m =>` to the now-honest
`Thenable m =>`.  Skill: **add-language-feature**.

---

### Phase 100: `import m.{T(..)}` bulk-constructor import ✅ DONE

Haskell-style shorthand for "the type and all its exported constructors", so a
`public export data T = A | B` could be imported with `import m.{T(..)}` instead
of listing each constructor (`import m.{T, A, B}`). Previously a **parse error** —
the `{…}` group accepted only bare names. Pure convenience sugar; explicit
listing still works unchanged.

**Resolution (2026-06-02).** `T(..)` is lowered at name-bind time in
`resolve.ml`, so nothing downstream (typecheck/eval) sees the sugar. The change:

- **Parser** (`lib/parser.mly`): a new `import_member` rule (`import_ident` →
  `(name, false)`; `UPPER LPAREN DOTDOT RPAREN` → `(name, true)`) replaces the
  bare `import_ident` inside the `UseGroup` production. `import_ident` itself
  (shared by the dotted `import_qual` path) is untouched. **No new tokens** — all
  four already exist. Parser conflict count unchanged at **3** (the new
  productions are reachable only after `DOT_LBRACE`).
- **AST** (`lib/ast.ml`): `UseGroup`'s member list went from `ident list` to
  `(ident * bool) list`, the bool marking the `(..)` form.
- **Resolve** (`lib/resolve.ml`): added `exp_type_ctors : (ident, ident list)
  Hashtbl.t` to `module_exports` (populated for `DData DataPublic` and public
  `DNewtype`), plus a shared `expand_member` helper. `T(..)` → `T :: ctors` when
  the type's constructors are public; on an **abstractly-exported** type
  (`export data T` — type public, ctors not) it reports the new
  `NoExportedConstructors` error (decided with the user — error, not silent) and
  recovers by importing just `T`. The helper is used by both the import path
  (`imported_names`) and the `export import` re-export path; the single-file stub
  and typecheck's scheme filter just take `fst` (no exports in scope).
- **Printer** (`lib/printer.ml`): renders `(name, true)` as `name(..)`; `fmt`
  inherits it. Eval and the loader are untouched.

Note the non-exhaustive-match warning on a cross-module `match` over all of an
imported type's constructors is **pre-existing** cross-module exhaustiveness
behavior (identical with explicit listing), unrelated to this phase. Tests:
`test_parser` (`group ctors T(..)`, `group mixed`), `test_roundtrip` (both forms
round-trip), `test_loader` (`import T(..)` brings ctors into scope; abstract
`T(..)` → `NoExportedConstructors`; `export import T(..)` re-exports type + ctors).
Skill: **add-language-feature**.

---

### Phase 102: plain multi-clause exhaustiveness ✅ DONE

`Exhaust.check_match` ran only on `EMatch`.  A plain multi-clause function
(`f Nil = ..` with no `Cons` clause) never becomes an `EMatch` — `group_fundefs`
coalesces same-named `DFunDef`s into a clause list and `process_letrec_group`
infers **each clause as its own lambda**, packaged as a `VMulti` at eval — so an
uncovered case surfaced only at runtime as `Impl_no_match` ("non-exhaustive
match"), never at compile time.  The Phase 91(2) guard lint
(`check_guard_exhaustiveness`) deliberately scoped this out: it targets *guarded*
fall-through and uses a **data-decl-only oracle** (`build_oracle`) that can't see
closed prelude types (`Option`/`Result`/`Ordering`).

**Resolution (2026-06-02).**  The Maranget `useful` engine already handled
multi-parameter coverage via `check_group`'s `__tuple__` reduction (wrap a
clause's whole parameter list as one synthetic tuple column; sub-column types
fall out of `infer_col0_type`/`get_ctor_type` from the patterns themselves).  The
only missing pieces were a type-aware oracle and an ungated entry point:

- `lib/exhaust.ml` — new public `check_clauses ~get_ctors ~get_arity
  ~get_ctor_type ~warnings ~loc ~arity clause_pats`: wraps each clause's params
  as a `__tuple__` column and warns "non-exhaustive clauses — some inputs are not
  matched" when an all-wildcard input is still useful.  No guard filtering
  (guards are desugared away by typecheck time, so every clause pattern counts as
  covering its shape — guard fall-through stays Phase 91(2)'s job); `arity = 0`
  value bindings are skipped.
- `lib/typecheck.ml` — extracted the `EMatch` branch's inline constructor oracle
  into a shared `exhaust_oracle env ~tuple_arity` (backed by
  `env.type_ctors`/`env.ctors`, so prelude types are enumerable), reused by both
  `EMatch` and the new check.  The check runs from the **end of
  `process_letrec_group`** (after `exit_level ()`, purely read-only, never
  `fail`s — so it can't leak the level bracket), which covers
  `check_program_impl`, `typecheck_module`, *and* the REPL at one site.
- `lib/typecheck.ml` — seeded `Unit → ["Unit"]` into `env.type_ctors` (it sat
  alongside `Bool`/`List` but had been overlooked).  Without it a single
  `f () = ..` clause read as an open type and false-positived; the lone prelude
  warning (`arbitraryString`) was exactly this, not a genuine partial.  No
  genuine stdlib partials surfaced, so no stdlib edits were needed.

A multi-clause function's warning points at its first clause body.  Known
interaction: a guarded-and-pattern-incomplete group (`f (Just x) | g = ..`, no
`Nothing`) draws both the Phase 91(2) "guards may not be exhaustive" and the
Phase 102 "non-exhaustive clauses" warnings — both correct (it is partial two
ways); accepted rather than deduped.  Ten `test_typecheck` cases under
"multi-clause exhaustiveness (Phase 102)" pin list/ADT/Option/multi-arg
partials-vs-totals, the ordinary-variable-params no-warn case, catch-all, and the
Unit-clause no-warn case.  Skill: **harden-typechecker**.

---

## 4. Smaller cleanups (good warm-up tasks)

See Phase 8.6 above for the consolidated housekeeping list. After the backend
phases land, revisit the limitations in Section 5 — most of them turn into
concrete work once real programs are running through the interpreter.

Standing cleanups (small, low-risk):
- ~~**Prune dead `+.` / `-.` / `*.` / `/.` arithmetic cases** in `eval.ml`'s
  `eval_arith`.~~ ✅ Already done (verified 2026-06-02): `eval_arith`
  (`lib/eval.ml:995`) has no `+.`/`-.`/`*.`/`/.` cases — arithmetic is a single
  type-dispatched path. Nothing left to prune.

## 5. Known limitations to keep in mind

These aren't blockers, but a less-careful change could trip over them:

- do-block dispatch in `eval.ml`: **bind** routes through the `andThen` VMulti by
  the bound value's runtime constructor (`eval_do`), and **`pure`** (return
  position) routes by its `EMethodRef` route stamped at typecheck. For a
  *concrete* monad `pure` gets `RHeadKey`; for a *polymorphic* monad in an
  unsignatured wrapper Phase 84 ✅ promotes the inferred `Applicative` to a
  dict-routable constraint (two-pass elaboration, `lib/elaborate.ml`) so `pure`
  routes by the caller's monad — at parity with the signatured `Applicative m =>`
  form. Residuals (see Phase 84): `pure` in a do-block with **no `<-`** is
  groundable only from surrounding type context; `Result e` with a free `e`
  mis-dispatches even when signatured (a separate multi-param dict-resolution
  gap); recursive unsignatured wrappers stay on arg-tag; the **REPL** and
  **multi-module** drivers are not yet on the two-pass path → Phase 87 / 88.
- `let mut` binding reassignment (`DoAssign`) is now type-checked in do-blocks,
  but `ELet(true, ...)` in expression context only tracks `mut_vars` — there is
  no syntax for reassigning a `let mut` binding outside a do-block. The `Ref`
  type is fully type-checked; actual mutation happens at runtime (Phase 10 ✅).
- `r.value = expr` field-assignment is supported via `DoFieldAssign` in do-blocks
  (Phase 28 ✅). Multi-level chains (`a.b.c = e`) are supported too (Phase 80 ✅):
  `DoFieldAssign` carries a field path and `update_path` rebuilds/mutates the
  nested structure. The base must still be a `let mut` binding.
- `let f x = ...` is implicitly self-recursive (Phase 27 ✅). `let x = expr`
  (no arguments) is still non-recursive. `where`-helpers use `ELetGroup` for
  mutual recursion (Phase 25 ✅).
- Primitive values (`pure`, `print`, `map`, …) now live exclusively in
  `lib/runtime.ml` (Phase 9 ✅). Primitive types (`List`, `Option`, …) are
  still hard-coded in `resolve.ml`/`typecheck.ml` until the stdlib lands.
- ~~`EUnOp "-"` only types as `Int -> Int`. Float negation isn't supported.~~
  ✅ Phase 70: unary `-` (and `%`) now carry a `Num a` constraint, so they
  work on Int, Float, and any user `Num` impl.  (Caveat: `%` on an exotic
  `Num` impl whose values aren't `VInt`/`VFloat` type-checks but has no
  `eval_arith` case — it would panic at runtime, same shape as other ops.)
- `==`/`!=` accept any two values of the same type (already polymorphic via
  `unify tl tr`). An `Eq` constraint is not yet checked — deferred until
  `impl Eq (List a)`, `impl Eq (Option a)` etc. can be registered so
  existing code doesn't break.
- `<`/`>`/`<=`/`>=` now use `Ord` constraint (Phase 17 ✅). Int, Float,
  String, and Char are the registered built-in impls.
- Arithmetic ops (`+`, `-`, `*`, `/`) now use `Num` constraint (Phase 17 ✅).
  Int and Float are the registered built-in impls.
- Effects: `TFun` carries an **effect row** (`effrow` = label set + optional
  tail effvar, Phase 79 ✅, replacing Phase 29's flat `effect_set`).  Effect
  polymorphism is fully inferred via open rows + ambient threading: a user HOF's
  callback effect flows to its result, and the annotated stdlib HOFs
  (`map`/`filter`/`fold`/…) propagate too.  Escape checking is inline at the
  binding boundary (Phase 79e retired the post-HM pass).
- `@Name` impl-disambiguation hints now select a specific impl at runtime
  (Phase 30 ✅) and are validated at compile time (Phase 32 ✅):
  named impls must exist and `@Name` selects among multiple matching impls.
  At runtime the VMulti is filtered by name; full dictionary-passing (for
  higher-order use) is deferred.
- A binding LHS (do-bind, lambda param, list-comp/guard generator) is parsed as
  an expression and converted via `expr_to_pat`, so cons/literal/ctor/as-pattern
  LHSs all work and a do-block's last statement may start with an uppercase
  constructor (Phase 81 ✅). The one-time edge where `_` after an operator in
  such a LHS was a left section, not a wildcard (`(x :: _) <- m`), is now
  recovered by `expr_to_pat` (Phase 85 ✅).
- ~~`@Impl` disambiguation hints are reported as unbound by resolve (`medaka check`
  false-positives), though they resolve at eval time.~~ ✅ Phase 86: resolve now
  accepts `@`-prefixed hints; typecheck's `UnknownImplName` still validates them.
- Module system: `use` declarations parse but no cross-file resolution
  exists. Backend roadmap is single-file only; multi-file support is a
  separate later phase.
- `medaka check --json` (Phase 82) runs `Diagnostics.analyze`, which is
  single-file — it does not invoke the multi-file `Loader`. A file with `use`
  decls is analysed as a single unit, so cross-module names may resolve-error
  in the JSON output. Multi-file `--json` is a follow-up.
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
  emitted). Harmless; can be pruned in a later housekeeping pass. → §4.
- **Tree-sitter grammar absent.** Design doc Phase 1 calls for it in
  parallel with the compiler. Phase 15.
- **CLI surface is minimal.** The design specifies `medaka new`, `build`,
  `run --release`, `check --json`, `test`, `fmt`, `lsp`, `add`, `remove`,
  `update`, `doc` — `check`, `run`, `test`, `repl`, `lsp`, `fmt`, `new` exist.
  `build` / `run --release` / `check --json` / `doc` → Phase 82; `add` /
  `remove` / `update` await a package manager.
- **No `medaka.toml` / `medaka.lock`.** Project config doesn't exist yet
  because single-file is still the contract. Post-Phase 14.
- **REPL: `:load`, `:reload`, `:browse` now implemented.** ✅ Phase 13 done.
- **Record field assignment `p.field = e`.** ✅ Phase 28 done. Single-level
  `x.field = e` in do-blocks for `let mut` records and `Ref .value`.
- ~~**`Eq`, `Num`, and `Ord` stdlib interfaces disconnected from built-in operator constraints.**~~
  ✅ **RESOLVED by Phase 52 (this bullet was stale — corrected 2026-06-02).**
  `core.mdk` now defines `interface Eq` (line 50), `interface Ord requires Eq`
  (line 138), and `interface Num requires Eq` (line 369), and
  `lib/builtins.ml` maps every operator to its interface method: `+`→`Num.add`,
  `-`→`Num.sub`, `*`→`Num.mul`, `/`→`Num.div`, `<`→`Ord.lt` (and `>`/`<=`/`>=`),
  `==`/`!=`→`Eq.eq`. The synthetic `__num__`/`__ord__` witnesses are gone; the
  operators emit real `Num`/`Ord`/`Eq` constraints and consult user
  `impl`s / `deriving`. The old problem statement is preserved in Phase 52's
  body for history, but the work is done.
  *(Remaining sub-item — `do`-notation wiring to `Thenable` — is tracked
  separately just below.)*
- **`do`-notation is not wired to `Thenable`.** The typechecker handles `do`
  structurally: each `<-` line just unifies its expression against `m a` for a
  fresh `m` typevar. It never looks up or calls `andThen`. This means do-notation
  works on any type that fits `m a` structurally, but `Thenable` in `core.mdk` is
  inert — deleting it would not break anything. To make the interface load-bearing,
  `<-` should desugar to `andThen` calls (Haskell style) so the `Thenable`
  constraint is actually checked. Scheduled with Phase 19 stdlib/typeclass wiring.
- **Constraint syntax in function type signatures.** ✅ Phase 20 done. `f : Eq a => a -> a -> Bool` now parses, round-trips, and type-checks. Constraint obligations are emitted at call sites and verified post-HM. Constraint *inference* (✅ Phase 83): an unsignatured binding now infers the constraints its body requires (e.g. `myEq x y = eq x y` acquires `Eq a` automatically and `myEq Blob Blob` is rejected), and an explicit signature whose context is insufficient for its body is rejected with `UnsatisfiedConstraint`. Inferred constraints drive call-site obligation checking only; runtime dictionary-threading *into* an inferred body still uses arg-tag dispatch (correct for argument-dispatched wrappers) — full threading is a deferred follow-up requiring a post-typecheck marker re-run.

### Additional gaps surfaced during the 2026-05-26 audit

- **Triple-quoted strings don't support `\{...}` interpolation.** The
  `read_triple_string` lexer rule has no `\\' '{'` branch, so any `\{expr}`
  inside a `"""..."""` string is emitted as a literal `\{expr}`.  Easy fix:
  extend `read_triple_string` with the same INTERP_OPEN logic
  `read_string` uses.  Scheduled as a small follow-up to Phase 23. → Phase 76.
- **Float unary negation rejected by the type checker.** ✅ Phase 70 (done).
  `EUnOp "-"` now records a `Num.negate` usage instead of unifying with
  `t_int`, so `-3.14` and `let f = -x` for `x : Float` type-check; the
  evaluator already handled `VFloat`.
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
| **Type aliases** | `type Name = String`, `type Parser a = String -> Option (a, String)` | ✅ Phase 26 done. `DTypeAlias`, `expand_aliases`, recursive-alias detection. |
| **Newtype declarations** | `newtype UserId = UserId Int` — zero-cost wrapper for type safety | ✅ Phase 26 done. `DNewtype` + `deriving` incl. `derive_num_newtype`. |
| **As-patterns** | `f all@(x::xs) = …` — name the whole value and destructure simultaneously | ✅ Done (`AS_AT` token + `expr_to_pat`); also works in binding-LHS positions (Phase 85). |
| **Record field punning** | `{ name }` as shorthand for `{ name = name }` in record creation and patterns | ✅ Done. Construction puns in the parser (`record_field_expr`); pattern puns via Phase 31. |
| **Left operator sections** | `(e op _)` means `\x -> e op x` | ✅ Phase 24 done. Syntax uses `_` placeholder: `map (2 * _) xs`, `filter (0 < _) xs`. Haskell-style `(2*)` not feasible in LALR(1). |
| **Multiline string / heredoc** | Formal `"""…"""` or backslash-newline string continuation | ✅ Triple-quoted `"""…"""` exists (`read_triple_string` lexer rule) with indentation stripping (Phase 16). Residual: `\{…}` interpolation inside `"""` is not yet supported → Phase 76. |

### Nice-to-have / maybe

| Feature | Description | Notes |
|---------|-------------|-------|
| **Top-level function guards** | Guards directly on equation heads: `classify n \| n < 0 = "neg" \| otherwise = "pos"` | ✅ Done. Supported on function clauses, `where`-bindings, and `match` arms. Sugar over `match`/`if` but reads more naturally for numeric/boolean logic. |
| **Pattern guards** | Comma-separated guard qualifiers, each a boolean test or a pattern bind `pat <- expr`: `filterMap f (x::xs) \| Some y <- f x = y::… \| None <- f x = …` | ✅ Done. Available in function/`where` guards and `match`-arm guards (`pat if q1, q2 => …`). A bind that fails to match falls through to the next arm; earlier binds scope over later qualifiers and the body. |
| **List comprehensions** | `[x*2 \| x <- xs, x > 0]` | Expressible via `map`/`filter`/`concatMap`; nice to have for readability. Not blocking anything. |
| **String interpolation** | `"Hello, \{name}!"` | ✅ Phase 23 done. `\{expr}` syntax; each hole desugars to `display expr` (auto, no explicit `show`) — needs a `Display` instance, `deriving (Display)` for user types. `Display String`/`Char` are unquoted. |
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

---

## 9. Roadmap review — 2026-06-02

A full pass over this document against the current binary. Two kinds of finding:
**(A) stale markers corrected in place** this session, and **(B) the genuinely
open work**, consolidated so the next session can pick from one list.

### A. Stale markers corrected this session

- **Phase 42 (property testing)** was marked ⏳ TODO but is **substantially
  implemented** — `prop` keyword, `Arbitrary` interface + built-in impls,
  `deriving (Arbitrary)`, and `lib/prop_runner.ml` (generation + shrinking)
  wired into `medaka test`. Re-marked ✅ DONE (core) with the residual generator
  gaps noted in the phase body.
- **§5 "Eq/Num/Ord disconnected from operators"** claimed `core.mdk` "does not
  define Num at all" — false. Phase 52 wired `+`→`Num.add`, `<`→`Ord.lt`,
  `==`→`Eq.eq` via `lib/builtins.ml`, and `core.mdk` defines all three
  interfaces. Bullet struck through; the "Outstanding non-stdlib gaps" preamble
  and Phase 52's header both reconciled.
- **§4 dead `+.`/`-.`/`*.`/`/.` pruning** — already done; `eval_arith` has no
  such cases. Marked resolved.
- **§7 must-have sugar table** still listed Type aliases, Newtypes, As-patterns,
  Record punning, and multiline strings as undone — all are implemented
  (Phases 26 / AS_AT / 31 / `read_triple_string`). Marked ✅.
- **§1 test counts are stale.** The header says "879 tests across 15 base
  suites"; the tree has grown well past that (the per-suite table also no longer
  sums to the stated totals). Treat the specific numbers as indicative only;
  re-derive from a green run before quoting them anywhere load-bearing.

### B. Genuinely open work (verified outstanding)

**Compiler / language:**
- **`do`→`Thenable` desugar.** The last survivor of the Phase 52 arc. `<-` is
  still handled *structurally* in typecheck (unify against `m a` for a fresh
  `m`); the `Thenable` interface is inert at the type level (eval already routes
  bind through the `andThen` VMulti). Wiring `<-` to a checked `andThen`
  constraint is the open piece. → fold into a small "Phase 52b".
- **Phase 91 (guards), items 2 & 3.** (2) No compile-time non-exhaustive-guard
  detection — runtime error only; realistic target is a conservative
  "guards may not be exhaustive" warning in `exhaust.ml`. (3) No inline guard
  form (`f n | n <= 0 = []` on one line is a parse error). Fall-through (item 1)
  is done.
- **Phase 42 residual generators.** No `Arbitrary` generation for `Array a` or
  tuples; parametric user types (`TyApp (TyCon custom, _)`) aren't routed through
  `arbitrary_registry`; built-in generation bypasses the Medaka-level
  `arbitrary`/`shrink` methods.
- **Phase 83 / 84 residuals (deferred, layered like 69.x→74).** Runtime dict
  threading *into* an inferred constrained body (currently arg-tag dispatch);
  self-/mutually-recursive *unsignatured* wrappers under-infer recursive-call
  routing; `pure` in a do-block with no `<-` groundable only from context;
  `Result e` with a free `e` mis-dispatches even when signatured (multi-param
  dict-resolution gap).

**CLI (Phase 82):**
- **`medaka build`** — no artifact cache / typed-IR serialization exists; needs
  its own design before it is more than an alias of `check`.
- **`medaka doc`** — doc comments aren't attached to AST nodes, and there's no
  signature renderer for a typechecker `scheme`. Needs comment→decl matcher +
  renderer + output-format decision.
- **`medaka check --json` multi-file** — currently single-file (`analyze` doesn't
  invoke the `Loader`); cross-module names can resolve-error in JSON output.

**Stdlib enablement track (Phase 19, user-owned):**
- Modules 5–8 from Phase 19's sequence are unstarted: `map`/`set` (persistent
  trees), `mut_array`/`hash_map`/`hash_set`, `io` (`readFile`/`writeFile`/
  `readLine`), `json`. These are deliberately user-written (see the stdlib
  division-of-labor convention) — listed here for completeness, not as agent work.
- **`stdlib/string.mdk`** is drafted and passing its 45 doctests but flagged
  *awaiting user review* (Phase 75 step 3); naming/omission decisions
  (`length`/`isEmpty`/`count`, `toUpper` vs `charToUpper`) are open for the user.

**Package-manager-blocked (out of scope until one exists):**
- `medaka add` / `remove` / `update`; `medaka.lock`.

### Won't-do (kept intentional)
- Phase 78c (multi-module method shadowing) — investigated and dropped; the
  motivating need is met by interface impls. The real lever, if ever needed,
  is a `Sized`/`HasLength` interface, which is stdlib design, not a compiler
  feature.
