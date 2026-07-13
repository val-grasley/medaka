# CONSTRUCT-COVERAGE.md — `medaka build` native coverage matrix

**Status:** PARTIAL — actively maintained (last substantive update 2026-07-10). Per its
own Summary: 123+ PASS fixtures; genuine remaining emitter gaps are same-head-tycon
dispatch (C7-native) and overlapping-tuple-impl. The `## Gaps` sections are authoritative
over the per-row matrix when they disagree. Bare `compiler/*.mdk` path citations in this
doc have been corrected to their post-restructure subfolder paths (2026-07-13 doc pass);
`lib/*.ml` citations are historical OCaml-oracle comparisons from before the 2026-06-26
OCaml removal — no live OCaml oracle exists to re-run them against.

Stage 3 #2b. Tested 2026-06-10 against the compiler LLVM backend (`medaka build`).
Each construct was exercised with a minimal `main` program, diffed native vs
`medaka run` (interpreter oracle). Fixture programs live in
`test/construct_fixtures/`; the gate `test/build_construct_coverage.sh` runs all
PASS fixtures.

Convention: native appends `()` for `main : <IO*> Unit`; the comparison strips
that. A result is PASS iff `native_output == oracle_output ++ "\n()"`.

---

## Summary

**123+ PASS fixtures** (gate `build_construct_coverage.sh` is the authoritative PASS list; the per-row matrix below may lag — the **§Gaps** sections are authoritative for each gap's closed/open status). Started 114 PASS / 15 GAP; closed F1·H-a·D1·D2·B1·B2 overnight. **2026-06-18 audit** confirmed additional closures: Gap C all residuals (C1/C2/C3/C4/C5b/C6/C7/C8), Gap H entirely (map+set now PASS in `medaka build`), A1/A4/A5/A8/A9/A11 reclassified as by-design or closed. Genuine remaining emitter gaps: same-head-tycon dispatch (C7-native) + overlapping-tuple-impl. A7 re-classified as a resolve/eval gap. Re-scoped: A2/A3 range patterns = compiler typecheck (`PRng` in `inferPat`), not parser.

---

## Coverage matrix

### Literals

| Construct | Status | Fixture |
|-----------|--------|---------|
| Int literal `42` | PASS | (covered by arithmetic fixtures) |
| Hex literal `0xFF` | PASS | `lit_hex.mdk` |
| Binary literal `0b1010` | PASS | `lit_binary.mdk` |
| Octal literal `0o17` | PASS | `lit_octal.mdk` |
| Underscore separator `1_000_000` | PASS | `lit_underscores.mdk` |
| Float literal `3.14` | PASS | `lit_float.mdk` |
| String literal `"hello"` | PASS | (covered by IO fixtures) |
| Triple-quoted string | PASS | `triple_quoted.mdk` |
| Char literal `'a'` | PASS | (covered by char fixtures) |
| Bool literals `True`/`False` | PASS | `bool_ops.mdk` |
| Unit `()` | PASS | (implicit in all IO fixtures) |
| List literal `[1,2,3]` / `[]` | PASS | (covered by list fixtures) |
| Array literal `[|1,2,3|]` / `[||]` | PASS | `array_index.mdk` |
| Tuple `(1,"hi")` | PASS | `tuple_fst.mdk` |

### String interpolation

| Construct | Status | Fixture |
|-----------|--------|---------|
| Single hole `"hello \{name}!"` | PASS | `str_interp.mdk` |
| Multiple holes `"\{a} and \{b}"` | PASS | `str_interp_multi.mdk` |
| Arbitrary expression `"\{1+2}"` | PASS | `str_interp.mdk` |
| Unicode escape `\u{48}` | PASS | `str_unicode_escape.mdk` |

### Operators and arithmetic

| Construct | Status | Fixture |
|-----------|--------|---------|
| Int arithmetic `+ - * / %` | PASS | (covered by build_cmd.sh `arith`) |
| Unary minus `-(5)` | PASS | `unary_minus.mdk` |
| Boolean `&& \|\| !x` (separate bindings) | PASS | `bool_ops.mdk` |
| Comparison `< > <= >= == !=` | PASS | `comparison_ops.mdk` |
| `debug` on tuple (direct) | PASS (Gap C closed 2026-06-18 audit) | see §Gap C |
| Float arithmetic (let-binding, literal anchored) | PASS | `float_arith.mdk`, `float_compute.mdk` |
| Float arithmetic (named fn, `+` via Num dispatch on Float params) | PASS (Gap C/E closed 2026-06-18 audit) | see §Gap C / §Gap E |
| Float `floatToInt` / `intToFloat` | PASS | `float_to_int.mdk`, `int_to_float.mdk` |
| Cons `::` | PASS | `cons_op.mdk` |
| Append `++` (List and String) | PASS | `list_append.mdk` |
| Pipe `\|>` | PASS | `pipe_op.mdk` |
| Left-to-right compose `>>` | PASS | `compose_left.mdk` |
| Right-to-left compose `<<` | PASS | `compose_right.mdk` |
| Backtick infix `` `f` `` | GAP | see §Gaps below |
| Operator sections `(+5)` `(2*_)` `(+)` | PASS | `section_right.mdk`, `section_left.mdk`, `section_bare.mdk` |
| `?` short-circuit unwrap | PASS | `question_op.mdk` |
| Ord `compare` | PASS | `ord_int.mdk`, `ord_compare.mdk` |

### Ranges

| Construct | Status | Fixture |
|-----------|--------|---------|
| Half-open range `[1..5]` | PASS | `range_half_open.mdk` |
| Inclusive range `[1..=5]` | PASS | `range_inclusive.mdk` |
| Array inclusive range `[|1..=5|]` | GAP | see §Gaps below |
| Array slicing `arr.[i..j]` / `arr.[i..=j]` (result element) | PASS | `array_slice_el.mdk` |
| Array slicing returning Array (debug on Array) | GAP | see §Gaps below |

### Control flow

| Construct | Status | Fixture |
|-----------|--------|---------|
| `if/else` inline and block | PASS | `if_else.mdk` |
| Else-less `if` (side-effect) | PASS | `if_no_else.mdk` |
| `if let` | PASS | `if_let.mdk`, `if_let_else.mdk` |
| `if/else` as expression | PASS | `if_else_expr.mdk` |
| Inline `if` side-effect in block | PASS | (tested inline) |

### Match and patterns

| Construct | Status | Fixture |
|-----------|--------|---------|
| Match literal pattern | PASS | `match_indented.mdk` |
| Match variable pattern | PASS | `match_ctor.mdk` |
| Match wildcard `_` | PASS | `match_indented.mdk` |
| Match tuple pattern `(a,b)` | PASS | `match_tuple_pat.mdk` |
| Match cons `x :: rest` | PASS | `match_cons_pat.mdk` |
| Match explicit list `[1,2,3]` | PASS | `match_explicit_list.mdk` |
| Match constructor `Some x` / `None` | PASS | `match_ctor.mdk` |
| Match as-pattern `ys@(x::_)` (body using ys) | PASS | `match_as_pattern.mdk`, `debug_list_after_as.mdk` |
| Match arm guard `x if x > 0` | PASS | `match_arm_guard.mdk` |
| Match record pattern `Person { name }` | PASS | `match_record_pat.mdk` |
| Match record pattern with rest `{ ... }` | PASS | `record_pat_rest.mdk` |
| Match string literal `"Alice"` | PASS | `match_string_pat.mdk` |
| Match int range pattern `1..9` | TYPECHECK-CLOSED, EMIT-OPEN | typecheck `range_pat.mdk`; see §Gaps A2/A3 |
| Match char range pattern `'a'..='z'` | TYPECHECK-CLOSED, EMIT-OPEN | typecheck `range_pat.mdk`; see §Gaps A2/A3 |
| Match negative literal `-1` | GAP | see §Gaps below |
| Match inline `\|` form (`match x \| p => e \| _ => e`) | GAP | see §Gaps below |
| Refutable match-arm pattern-guard `x if Some y <- f x` | PASS (CLOSED 2026-06-15) | `test/llvm_fixtures/guard_match_*.mdk` |

### `let` / mutation

| Construct | Status | Fixture |
|-----------|--------|---------|
| `let x = e in body` | PASS | `let_in.mdk` |
| `let x : T = e in body` (inline annotated let) | PASS | `let_annot_inline.mdk` |
| `let x : T = e` in block (block annotated let) | GAP | see §Gaps below |
| `let f x = e in body` (let-bound function) | PASS | (tested inline) |
| `let rec f = x => ...` in block | GAP | see §Gaps below |
| `let rec ... with ...` at top-level | PASS | `letgroup_toplevel.mdk` (eval+build) |
| Top-level mutual recursion (separate clauses) | PASS | `toplevel_mutual_rec.mdk` |
| `Ref` cell + `:=` reassignment (`x := x.value * 2`) | PASS | `let_mut_reassign.mdk` (beta: was `let mut`, removed 2026-07-09) |
| `Ref e` create + `:=` write + `.value` read | PASS | `ref_let_mut.mdk` (beta: was `let mut`, removed 2026-07-09) |
| `let Some x = opt else panic` | PASS | `let_else.mdk` |
| `where` clause (indented block form) | PASS | `where_multi_defs.mdk` |
| `where` clause (inline form `f x = e where g = ...`) | GAP | see §Gaps below |

### Lambdas and higher-order functions

| Construct | Status | Fixture |
|-----------|--------|---------|
| Single-param lambda `x => x+1` | PASS | (covered widely) |
| Multi-param lambda `x y => x+y` (as top-level value with sig) | PASS | (tested) |
| Multi-param lambda `x y => x+y` (as local let binding, no sig) | GAP | see §Gaps below |
| Inline application `(x y => x+y) 3 4` | PASS | (tested) |
| Tuple-destructuring lambda `(a,b) => a+b` | PASS | `tuple_pat_lambda.mdk` |
| Constructor-pattern function param | PASS | `ctor_pat_lambda.mdk` |
| Point-free one-arg match `x => match x { … }` (the `function` keyword was removed; this is the replacement idiom) | PASS | `function_keyword.mdk` |
| Partial application | PASS | `partial_apply.mdk` |
| Higher-order function (HOF) | PASS | `hof_multi.mdk` |

### Closures and recursion

| Construct | Status | Fixture |
|-----------|--------|---------|
| Closures capturing locals | PASS | (covered by build_cmd.sh `closure`) |
| Recursive top-level function | PASS | (covered by build_cmd.sh `recur`) |
| Multiple-clause function | PASS | `multi_clause.mdk`, `multi_clause_fn.mdk` |
| Mutual recursion (top-level separate clauses) | PASS | `toplevel_mutual_rec.mdk` |

### Guards

| Construct | Status | Fixture |
|-----------|--------|---------|
| Function-clause guards `\| n < 0 = "neg"` | PASS | `fn_clause_guards.mdk` |
| Function-clause guard with pattern-bind qualifier | PASS | `fn_guard_with_pat.mdk` |
| `otherwise` guard | PASS | `guard_chain_multi.mdk` |
| Multi-guard chain | PASS | `guard_chain_multi.mdk` |
| Match-arm guard `x if x > 0` | PASS | `match_arm_guard.mdk` |

### ADTs

| Construct | Status | Fixture |
|-----------|--------|---------|
| Inline sum `data Shape = Circle Int \| Rect Int Int` | PASS | (build_cmd.sh `adt`) |
| Block-form sum `data Shape \n = Circle Float \n \| Square Float` | PASS | `adt_block_form.mdk` |
| Named-field variant `data Event = Click { x : Int, y : Int }` | PASS | `adt_record_variant.mdk` |
| ADT with Float payload (single) | PASS | `adt_float_ctor.mdk`, `float_two_ctor.mdk` |
| ADT with two Float fields (`Rect Float Float`) — match extracts both | PASS (Gap E closed 2026-06-10, Fix B — field vars typed from ctor's declared field types; verified done 2026-06-22) | `adt_float_ctor_arith.mdk` |
| `deriving (Debug)` | PASS | `deriving_debug.mdk` |
| `deriving (Eq)` | PASS | `deriving_eq.mdk` |
| `deriving (Eq, Ord)` — `<` comparison | PASS (Gap G closed 2026-06-10 — A2 type-directed rewrite; verified done 2026-06-22) | `operator_eq_user_impl.mdk` |
| `deriving (Eq, Ord)` — `compare` | PASS (Gap G closed 2026-06-10 — `deriveOrdData` wired for `data` types; verified done 2026-06-22) | `ord_compare.mdk` |
| Variant functional update `Pt { p \| y = 9 }` | PASS (native); oracle type-errors | `adt_float_ctor.mdk` |

### Records

| Construct | Status | Fixture |
|-----------|--------|---------|
| Record construction | PASS | `record_construct.mdk` |
| Record field access `p.name` | PASS | `record_construct.mdk` |
| Record chain access `o.inner.val` | PASS | `record_chain_access.mdk` |
| Record functional update `{ p \| age = 31 }` | PASS | `record_update.mdk` |
| Record pun shorthand `Person { name, age }` | PASS | `record_pun.mdk` |
| Nested record update `{ p \| addr.city = "Boston" }` | PASS | `record_nested_update.mdk` |
| Record `deriving (Debug)` | PASS (Gap G follow-up closed 2026-06-10; `deriveForRecord` filled for Eq/Ord/Debug/Display) | `record_deriving.mdk` |

### Tuples

| Construct | Status | Fixture |
|-----------|--------|---------|
| Tuple construction `(1, "hi")` | PASS | `tuple_fst.mdk` |
| Tuple pattern match `(a,b)` | PASS | `match_tuple_pat.mdk` |
| `debug` on tuple | PASS (Gap C closed 2026-06-18 audit) | see §Gap C |

### Lists and comprehensions

| Construct | Status | Fixture |
|-----------|--------|---------|
| List `map` | PASS | (build_cmd.sh `list_map`) |
| List `filter` | PASS | `list_filter.mdk` |
| List `length` (via Foldable) | PASS | `foldable_length_list.mdk` |
| List comprehension with generator + filter | PASS | `list_comp_basic.mdk` |
| List comprehension with `let` qualifier | PASS | `list_comp_let.mdk` |
| Multi-generator comprehension (result not debugged as tuple) | PASS | `list_comp_multi_fst.mdk` |
| Multi-generator comprehension with `debug` on tuple result | PASS (Gap C closed 2026-06-18 audit) | see §Gap C |

### Arrays

| Construct | Status | Fixture |
|-----------|--------|---------|
| Array literal `[|1,2,3|]` | PASS | `array_index.mdk` |
| `arr.[i]` indexing | PASS | `array_index.mdk` |
| `arr.[i..j]` slicing (element access on result) | PASS | `array_slice_el.mdk` |
| `debug` on Array slice result | GAP | see §Gaps below |
| `arrayLength` extern | PASS | `array_extern_ops.mdk` |
| `arrayMake` extern | PASS | `array_extern_ops.mdk` |
| `arraySetUnsafe` / `arrayGetUnsafe` | PASS | `array_set_unsafe.mdk` |
| `arrayCopy` | PASS | `array_copy.mdk` |
| `arrayFromList` | PASS | `array_from_list.mdk` |
| `length` via Foldable on Array | GAP | see §Gaps below |
| `Array.make` / `Array.set` (module-qualified) | GAP (not supported in single-file build) | — |

### Strings

| Construct | Status | Fixture |
|-----------|--------|---------|
| `stringLength` | PASS | `str_length.mdk` |
| `stringSlice` | PASS | `str_slice.mdk` |
| `stringToChars` / `stringFromChars` | PASS | `str_to_chars.mdk` |
| `stringIndexOf` | PASS | `str_index_of.mdk` |
| `stringCompare` | PASS | `str_compare.mdk` |
| `stringToFloat` | PASS | (tested) |
| `stringConcat` | PASS | `str_concat_list.mdk` |
| `stringToUpper` / `stringToLower` | PASS | `str_upper_lower.mdk` |
| `charCode` / `charToLower` | PASS | `char_ops.mdk` |
| `charFromCode` | PASS | `char_from_code.mdk` |

### Type system

| Construct | Status | Fixture |
|-----------|--------|---------|
| Type alias `type Name = String` | PASS | `type_alias.mdk` |
| Newtype declaration + constructor (as emitted fn) | GAP | see §Gaps below |
| Type annotation in expression `(e : T)` | PASS | `type_annot_expr.mdk` |
| Annotated `let x : T = e in body` (inline `in` form) | PASS | `let_annot_inline.mdk` |
| Annotated `let x : T = e` in block | GAP | see §Gaps below |
| Effect label declaration `effect KV` | PASS | `effect_decl.mdk` |
| Effect variable in sig `(a -> <IO> b) -> a -> <IO> b` | PASS | `effect_var_sig.mdk` |
| Open effect row `<IO \| e>` return type | GAP | see §Gaps below |

### Interfaces and implementations

| Construct | Status | Fixture |
|-----------|--------|---------|
| `interface Foo a where` with method | PASS | `interface_impl.mdk` |
| `impl Foo T where` | PASS | `interface_impl.mdk` |
| `interface Ord a requires Eq a` (superclass) | PASS | `superclass.mdk` |
| Default method body | PASS | `default_impl_override.mdk` |
| Multi-param interface `interface Conv a b` | PASS | `multi_param_iface.mdk` |
| Named impl `impl Sum of Monoid Int where` | GAP | see §Gaps below |

### Modules

| Construct | Status | Fixture |
|-----------|--------|---------|
| Cross-module import + entry-point build | PASS | (build_cmd.sh `multimodule`) |
| `export fn` | PASS | `export_fn.mdk` |
| `public export data` | PASS | `pub_export_debug.mdk` |
| `import map.*` / stdlib module imports | PASS (Gap H CLOSED 2026-06-18 audit) | `stdlib_list.mdk`, `stdlib_array.mdk`, `stdlib_string.mdk`, `stdlib_io.mdk`, `stdlib_map.mdk`, `stdlib_set.mdk` |

### IO and effects

| Construct | Status | Fixture |
|-----------|--------|---------|
| `putStr` / `putStrLn` | PASS | `put_str.mdk` |
| `println` in `main` directly | PASS | (all IO fixtures) |
| `println` in parameterized `<IO>` named fn (unannotated, generic `Display a`) | PASS (Gap C closed 2026-06-18 audit) | see §Gap C / §Gap F |
| `println` in parameterized `<IO>` named fn (concrete-typed) | PASS | `println_param_fn_typed.mdk` |
| `putStrLn` in parameterized `<IO>` named fn | PASS | (tested) |
| Bare indented IO block (multi-statement `main`) | PASS | `bare_io_block.mdk` |
| `readFile` / `writeFile` | PASS | `io_write_read.mdk` |
| `do`-notation for Option | PASS | `do_option.mdk` |
| `do`-notation for Result (Int) | PASS | `do_result_int.mdk` |
| `do`-notation for Result (Float) | PASS (works with `Result ErrType Float` type order; verified done 2026-06-22: `safeDiv 10.0 2.0` in do-block → `Ok 7.0`) | `do_result_int.mdk` style |
| `do`-notation for IO (multi-statement) | BY DESIGN (see A8) — both compilers reject `do` on IO (`do` requires a monad; use bare indented block for IO sequencing instead) | — |
| `Ref` cell create + `:=` write + `.value` read | PASS | `ref_let_mut.mdk` |

### Misc declarations

| Construct | Status | Fixture |
|-----------|--------|---------|
| `prop` declaration | PASS | `prop_test.mdk` |
| `extern` declaration | PASS | (all runtime extern calls) |
| `@inline` attribute | PASS | `attr_inline.mdk` |
| `@deprecated` / `@must_use` | PASS (parse-only check) | — |

---

## Gaps (actionable follow-up tasks)

### Gap Group A: Selfhost parser / resolve-eval gaps
These constructs either parse correctly in the OCaml reference compiler but produce
errors in `medaka build`, or have been re-classified after the 2026-06-18 audit.

| # | Construct | Error | Repro |
|---|-----------|-------|-------|
| A1 | Match inline `\|` form: `match x \| 0 => "z" \| _ => "o"` | **BY DESIGN** — OCaml reference ALSO rejects this (verified); indentation-based match grammar only. Adding it to compiler would DIVERGE from the oracle. Not a gap. | `let r = match 0 \| 0 => "zero" \| _ => "other"` |
| A2 | Match int range pattern `1..9` | TYPECHECK-CLOSED (2026-06-10); EMIT-OPEN | `match n` / `  1..9 => "digit"` / `  _ => "other"` |
| A3 | Match char range pattern `'a'..='z'` | TYPECHECK-CLOSED (2026-06-10); EMIT-OPEN | `match c` / `  'a'..='z' => True` / `  _ => False` |
| A4 | Match negative literal pattern `-1` | NOT A GAP — ref REJECTS it too | `match n` / `  -1 => "minus"` / `  _ => "other"` |

**Triage (2026-06-10, indentation-form repros — the table's original `\|`-form
repros all hit A1 first, masking the real downstream behavior):**

- **A1** (inline `\|` match) — **NOT a compiler-only gap. The OCaml reference
  parser also REJECTS `match x \| p => e \| _ => e`** (verified: `medaka run`
  → `Parse error`). The reference match grammar is indentation-based only.
  Adding the inline-`\|` form to the compiler parser would make it *accept what
  the reference rejects* — a differential-oracle divergence, not a gap closure.
  Reclassify as design-decision (do not add) unless the reference grammar gains
  it first.

- **A2 / A3** (int / char range patterns `1..9`, `'a'..='z'`) — **TYPECHECK
  CLOSED 2026-06-10; EMIT still OPEN.** The compiler *parser already accepts them*
  (`parsePatAtom` → `intPatRest`/`charPatRest` → `PRng`, parser.mdk:1216-1255).
  **Selfhost typecheck now handles them**: `inferPat` gained a `PRng` arm
  (`inferPatRng`, typecheck.mdk:~1180) mirroring the oracle (`lib/typecheck.ml:1299`):
  both bounds `LInt` → `Int`, both `LChar` → `Char`, anything else → a
  `Type mismatch` error; binds nothing; pattern type = the bound type. Verified
  compiler == oracle on `test/typecheck_fixtures/range_pat.mdk` (`Int -> String`,
  `Char -> Bool`). Selfhost **eval** already handled `PRng` (`bootstrap_eval.sh`'s
  `range_pat_tree.mdk`).
  **EMIT remains a gap** (`medaka build`): two missing pieces in `llvm_emit.mdk`.
  (1) `bindPattern` has no `PRng` arm → falls through to `gapEnv`
  (llvm_emit.mdk:382) and `panic: unsupported pattern in match arm … PRng`.
  (2) More fundamentally, the decision-tree lowering (`core_ir_lower.mdk`)
  canonicalises `PRng` to `PWild` in the matrix (`canonPat`) and routes the arm
  through `CTGuard` (`patNeedsGuard (PRng …) = True`), but the arm's explicit
  `guards` list is **empty** — the range bound lives in the *pattern*, not a
  `CGuard`. `emitGuardedArm` (llvm_emit.mdk:3507) only emits tests for the
  explicit `guards`, so even past the `bindPattern` panic it would emit **no
  range-comparison test** and fire the arm unconditionally (the `50` scrutinee
  would wrongly match `1..9`). Closing emit requires a NEW range-test lowering: a
  `bindPattern` `PRng` no-op arm PLUS synthesizing the comparison
  (`lo <= v && v <= hi` for `..=`, `lo <= v && v < hi` for `..`) as an emitted
  guard test branching to the `CTGuard` fail subtree. That is a genuine emit
  feature (a range-comparison test the emitter does not produce) — deferred,
  STOPPED per task guardrails (not built unattended).
  *Caveat (unchanged):* the compiler parser's range **bounds** reject `MINUS INT`
  (`intBoundFor` only matches `TInt`), so negative range bounds (`-1..1`, which
  the ref accepts via parser.mly:561-566) remain a separate compiler-parser gap.

- **A4** (bare negative literal pattern `-1`) — **NOT A GAP. The OCaml reference
  parser REJECTS bare negative literal patterns in ALL positions** (match arm,
  fn-clause head `f (-1) =`, parenthesized `(-1)`, let-pattern) — verified
  `medaka run` → `Parse error` for each. Reference grammar `pat_atom`
  (parser.mly:549-573) has NO standalone `MINUS INT → PLit` production; `MINUS
  INT` appears in patterns ONLY as a range bound (parser.mly:561-566). Adding a
  bare-negative-literal pattern to `compiler/frontend/parser.mdk` would make compiler
  accept what the reference rejects → diverge from the differential oracle.
  The task premise ("the OCaml reference parser accepts it") does not hold.
  **No compiler change made.**
| A5 | `where` clause inline (at end-of-body-line) | ✅ CLOSED (2026-06-18 audit) — both ref and compiler handle inline `where`; the block form may still differ; by-design | `f x = x where g = 1` |
| A6 | `let rec fib = n => ...` in block (block form) | Both ref and compiler fail; ref: `Parse error` at col 0 | N/A — both parsers reject this |
| A7 | `let rec ... with ...` at top-level | **CLOSED (2026-06-18 — BUILD residual CLOSED).** Resolve/eval was fixed in prior work. Core IR lowering (`funClausesOf` in `core_ir_lower.mdk`) and DCE (`isEmittingDecl` in `dce.mdk`) now handle `DLetGroup` — both unconstrained and constrained `medaka build` work. Fixpoint holds. | `let rec isEven n = ... with isOdd n = ...` |
| A8 | `do` inside a named function body when function has `<IO>` effect type | ✅ CLOSED (2026-06-18 audit) — both compilers reject `do` on IO (IO is not a monad by design; use bare indented blocks); by-design | `printTwo : <IO> Unit \n printTwo = do \n  putStrLn "x"` |
| A9 | Record `deriving (Debug)` (block form, indent) | ✅ CLOSED (2026-06-18 audit) — works in both compilers | `record Point \n  x : Int \n  y : Int \n  deriving (Debug)` |
| A10 | Annotated `let x : T = e` in block (block form) | Both ref and compiler fail; ref: `Parse error` | N/A — both parsers reject this |
| A11 | `@`-pattern in lambda / function param (e.g. `setX v p@(Pt {x,y}) = ...`) | ✅ CLOSED (2026-06-18 audit) — works in both fn params AND lambda | `f p@{x,y} = x` |

**Fix target:** `compiler/frontend/parser.mdk` for A2/A3 emit; A7 CLOSED (see above).

---

### Gap Group B: Emitter missing block statement forms — CLOSED (2026-06-10)
`emitBlock` in `compiler/backend/llvm_emit.mdk` historically only handled `CSLet`(PVar/
PWild/PTuple) and `CSExpr`; missing cases produced `panic: unsupported block
statement (slice 1)`. Both gaps are now closed (EMIT-ONLY, deterministic).

| # | Construct | Status |
|---|-----------|--------|
| B1 | `let mut x = e` + `x = e` reassignment in block | **PASS** (2026-06-10) — `let_mut_reassign.mdk` |
| B2 | `let Some x = opt else panic "..."` (let-else) | **PASS** (2026-06-10) — `let_else.mdk` |

**B1 approach.** `let mut x = e` already lowers to `CSLet True (PVar x) e`, which
the existing irrefutable `CSLet _ (PVar x)` arm handles (the mut flag carries no
emit work). The missing piece was the reassignment statement `CSAssign x e`. It
is lowered EMIT-ONLY by mirroring the tree-walker (`core_ir_eval.cevalBlock
((CSAssign x e)::rest)`): re-evaluate `e` to a fresh SSA value and SHADOW the `x`
binding in the emit env for the rest of the block. Blocks are linear (no back-edge
re-enters the binding), so functional rebinding of an immutable SSA value is
observationally identical to a real mutable slot — no Ref cell or value-model
change needed. Added arms: `emitBlock … ((CSAssign x ex)::rest)` and the tail
`emitBlock … [CSAssign _ ex]` (yields Unit).

**B2 approach.** `let <pat> = e else alt` lowers to `CSLetElse pat e alt`. Mirrors
`core_ir_eval.cBlockLetElse`. For an irrefutable pattern (PVar/PWild/PTuple/PAs)
the else is statically dead → bind + continue like a normal let. For a refutable
constructor pattern (`PCon c args`, `PCons`, non-empty `PList`) → `emitLetElse`
emits a discriminant test (`loadDiscriminant` + `icmp` against `cellTag e c`) and
branches: match → `loadFields` + `bindPattern` + continue the block into a result
slot; miss → emit `alt` (which diverges via `@mdk_panic`/exit). Reuses the exact
primitives the decision-tree switch chain uses; no decision-tree builder needed.

**Location:** `compiler/backend/llvm_emit.mdk` `emitBlock` (new `CSAssign`/`CSLetElse`
arms) + new helpers `emitLetElse` / `bindFieldList` / `letElseHead` /
`irrefutableLet`. The four CStmt-walking analyses (`freeVarsStmts`,
`eagerVarsStmts`, `blockTy`, `scanStmtsRecords`) gained explicit `CSAssign` /
`CSLetElse` arms so their RHS/alt sub-expressions are no longer dropped by a
catch-all (matters for closure free-var capture + DCE reachability).

**Residual:** a let-else with a refutable NON-constructor pattern (e.g. a bare
int literal `let 0 = n else …`) records a contained gap (`letElseHead = None`);
not produced by current `compiler/` source.

---

### Gap C: Arg-tag dispatch on constructorless types (tuples, polymorphic) — MOSTLY CLOSED (2026-06-18 audit)

**Verification (2026-06-18 audit):** C1/C5b (tuple-as-dispatch-tag), nested element dicts (`debug` on `List a`, `List (Int,Int)`, up to 3-level `List(List(List Int))`), lambda-bound constraint (`g = x => debug x`), and unannotated generic `f x = println x`/`debug x`/`display x` — ALL CLOSED, incidentally by the float-soundness arc reworking the emitter dict paths.

**Genuine emitter dispatch residuals (2026-06-18 audit, both reproduced as open):**
- **C7-native same-head dispatch** — `medaka build` fails on two `impl`s of one interface sharing a head tycon with different type args (e.g. `impl Def (MyPair Int Bool)` + `impl Def (MyPair Bool Int)`): `error: emitter failed — no impl of method … (slice 6)`. Interpreter (`run`) is correct. Emitter dispatch is head-tag-keyed; can't disambiguate type args.
- **Overlapping tuple-impl dispatch (both backends)** — with `impl Foo (Int,Int)` AND `impl Foo ((Int,Int),(Int,Int))`, a pair-of-pairs arg dispatches to the `(Int,Int)` impl (wrong) in BOTH `run` and `build`. Most-specific-resolution bug.

Historical table (as of 2026-06-10; statuses updated below):

| # | Construct | Trigger | Status (2026-06-18) |
|---|-----------|---------|---------------------|
| C1 | `debug` on tuple `(1,2)` | `Debug (Int,Int)` impl | ✅ CLOSED |
| C2 | `debug` on any type inside a generic lambda `xs => debug xs` | polymorphic `xs : a` | ✅ CLOSED |
| C3 | Multi-param lambda as local let without type annotation: `let add = x y => x+y` | `Num a` on polymorphic `x` | ✅ CLOSED |
| C4 | Polymorphic constrained fn `double : Num a => a -> a; double x = x+x` at Float | `Num Float` via arg-tag | ✅ CLOSED (→Gap E, `a8b95d7`) |
| C5 | Multi-generator list comprehension `[(x,y) \| ...]` with `debug` on tuple result | `Debug (Int,Int)` | ✅ CLOSED |
| C6 | `length` on Array via Foldable | `Foldable Array` via arg-tag | ✅ CLOSED (requires `import array`) |
| C7 | Array `[|1..=5|]` with `debug` (requires `import array`) | `Debug (Array Int)` | ✅ CLOSED (requires `import array`) |
| C8 | Array slice `arr.[1..3]` with `debug` on result (requires `import array`) | `Debug (Array Int)` | ✅ CLOSED (requires `import array`) |

**Remaining genuine emitter dispatch gap:** same-head-tycon dispatch + overlapping-tuple-impl (see above).

---

### Gap D: Emitter unbound variable for specific constructs

| # | Construct | Status |
|---|-----------|--------|
| D1 | Backtick infix `` a `divide` b `` | **PASS** (2026-06-10) — fixture `backtick_infix.mdk` |
| D2 | Newtype constructor `UserId 42` used as a function | **PASS** (2026-06-10) — fixture `newtype_ctor_fn.mdk` |
| D3 | Named impl `combine @Sum` hint syntax | `unbound variable '@Sum'` |
| D4 | `let rec ... with ...` top-level mutual rec | **CLOSED (2026-06-18)** — `funClausesOf` in `core_ir_lower.mdk` + `isEmittingDecl` in `dce.mdk` now handle `DLetGroup`; both `run` and `build` correct; fixpoint holds. |

**D1 root cause + fix (2026-06-10).** `` a `f` b `` parses to `EInfix "f" a b` and
lowers correctly to `CApp (CApp (CVar "f" AGlobal) a) b`. The bug was NOT in
emit — it was DCE: `marker.collectVars (EInfix _ a b)` dropped the operator name,
so the backtick-referenced function `f` looked unreachable and `dce.dceFilter`
removed its `DFunDef`. The emitter then hit `unbound variable 'f'`. Fix:
`collectVars (EInfix op a b) = op :: …` (`compiler/frontend/marker.mdk`). Built-in operator
symbols (`+`/`==`) never name a `DFunDef`, so the added name is inert for them.

**D2 root cause + fix (2026-06-10).** `core_ir_lower.ctorArities` only scanned
`DData`, so a `DNewtype`'s constructor was absent from the emitter's ctor table
and `UserId 42` resolved to an unbound variable. A newtype is structurally a
single-constructor, single-field data type (the oracle uses `make_ctor con 1`),
so the fix registers it as an arity-1 ctor:
`ctorArities ((DNewtype _ _ _ con _ _)::rest) = (con, 1) :: …`
(`compiler/ir/core_ir_lower.mdk`). EMIT-ONLY — no eval/canonPat/Core-IR shape change.

**Fix target (remaining):** `compiler/backend/llvm_emit.mdk` — D3: impl hints; D4: mutual-rec top-level wiring.

---

### OBS5 — `marker.collectVars` / `declRefs` DCE-reference-walk completeness audit (2026-06-10)

DCE (`dce.dceFilter`) drops any top-level `DFunDef` unreachable from `main` +
impl/interface bodies. Reachability is computed with `marker.collectVars`
(per-expr refs) + `marker.declRefs`/`declBodies` (per-decl bodies). If either
fails to walk a sub-expression or a NAME that can reference a top-level binding,
DCE silently drops a *reachable* function → emitter `unbound variable` crash
(this is exactly how D1 bit us). This audit enumerated every `Expr`, pattern,
and `Decl` form (`compiler/frontend/ast.mdk`) against the walk.

**`collectVars` — Expr forms (all 40 ctors):**

- *Variable references, all walked:* `EVar`, `EMethodRef`, `EDictApp`, and the
  post-elaboration `EVarAt`/`EMethodAt`/`EDictAt` (each carries the name in field
  1 — DCE runs on the elaborated tree, so these are the live forms).
- *Operator-name reference:* `EInfix op …` walks `op` (the **D1 fix** — a backtick
  `` a `f` b `` names plain fn `f`). `EBinOp`/`EUnOp`/`ESection` operators are
  built-in SYMBOLIC operators only — **verified in both parsers** (`section_op`,
  `EUnOp "-"|"!"`, and `EBinOp` is only ever produced for symbolic ops); a symbol
  never names a `DFunDef`, so dropping it is sound. Sections desugar to
  `EBinOp op …` before DCE — same symbolic-only guarantee.
- *Sub-expression recursion, all walked:* `EApp`, `ELam`, `ELet`, `ELetGroup`,
  `EMatch` (+ guards via `armVars`/`guardVars`), `EIf`, `EFieldAccess`,
  `ERecordCreate`/`ERecordUpdate`/`EVariantUpdate` (field-assign exprs; record
  PUNS desugar to `field = EVar field` so the pun name is captured), `EArrayLit`,
  `EListLit`, `ETuple`, `EIndex`, `ERangeList`/`ERangeArray`, `ESlice`, `EBlock`,
  `EDo` (do-binds/guards via `doStmtVars`), `EAnnot`, `EHeadAnnot`, `EListComp`
  (generators/guards/lets via `lcQualVars`), `EQuestion`, `EStringInterp`,
  `EGuards`, `EFunction`, `EAsPat`, `EMapLit`/`ESetLit` (entries — these also
  desugar to `EApp (EVar "fromEntries") …` before DCE, so `fromEntries` is
  captured via `EVar` regardless).
- *Name fields that are NOT DFunDefs (sound to skip — DCE only drops DFunDef):*
  field labels (`EFieldAccess`), constructor/type names (`ERecordCreate`/
  `EVariantUpdate`/`EMapLit`/`ESetLit` head) → reference `DData`/`DRecord`.
- *`ELit`* → wildcard `[]` (literals carry no reference) — correct.

**`declBodies`/`declRefs` — Decl forms:** `DFunDef`, `DImpl` (method bodies),
`DInterface` (default bodies), `DProp`/`DTest`/`DBench` already walked.
**Added (OBS5):** `DAttrib _ d` → `declBodies d`; `DLetGroup _ binds` →
clause bodies. Both were holes in the reference walk.

**Holes found:** none in `collectVars` (the live walk was already complete — D1
and the earlier EVarAt/EMethodAt/EDictAt/EHeadAnnot/EAsPat/EMapLit/ESetLit work
closed them). Two latent holes in `declBodies` (`DAttrib`, `DLetGroup`) — fixed.

**Why no native regression fixture for the two declBodies additions:** both
forms are **not lowered by the native emitter today** — `core_ir_lower.funClausesOf`
emits only *bare* `DFunDef` and skips `DAttrib (DFunDef …)` and top-level
`DLetGroup` (the latter is the already-documented **D4** gap). So a function in
those forms is never emitted whether or not DCE retains it — the `declBodies`
holes are *latent*, not live. The added arms are correct as a reference walk and
**forward-compatible** for when `funClausesOf` learns to lower attributed /
let-group top-level functions; they are **inert for the current corpus** (no
top-level `DAttrib`/`DLetGroup` in `core.mdk` or any imported stdlib module), so
`diff_compiler_mark` stays byte-identical (verified: 144/0) — the marker's own
`droppablePreludeFns` use of `declRefs` sees identical results.

**Gates (all green, 2026-06-10):** `build_cmd` 13/0; `build_construct_coverage`
121/0; `diff_compiler_llvm` 170/0; `_typed` 33/0; `_modules` 6/0;
`diff_compiler_mark` 144/0; `selfcompile_fixpoint` C3a + C3b PASS (the whole
emitter graph still DCEs + reproduces byte-for-byte); `bootstrap_eval` 20/0.

---

### Gap E: Float value corruption / wrong output — **FULLY CLOSED 2026-06-10**

| # | Construct | Oracle | Native | Note |
|---|-----------|--------|--------|------|
| E1 | Named fn `double : Float -> Float; double x = x + x` (no Float literal in body) | `6.28` | `6.28` | **CLOSED 2026-06-10 (Fix C):** signature inference seeds param/return LTy from the DECLARED `DTypeSig` — see Gap E note below |
| E2 | ADT with two Float fields, extracting both: `Rect Float Float; Rect w h => w * h` | `12.` | `12.` | **CLOSED 2026-06-10 (Fix B):** field vars now typed from ctor's DECLARED field types — see Gap E note below |
| E3 | lambda Float param `(y => y + 1.0) 3.0` | `4.` | `4.` | **CLOSED 2026-06-10 (Fix A)** — lambda params typed via `paramUseTy` |

**Fix target:** `compiler/backend/llvm_emit.mdk` — all three closed. Gap E is the LLVM emitter's static `LTy` recovery guessing too weakly; each fix sources a stronger, DECLARED type into inference rather than relying on body-use.

---

### Gap F: `println` in parameterized named function

| # | Construct | Oracle | Native | Note |
|---|-----------|--------|--------|------|
| F1 | `f s = println s; main = f "hello"` (UNANNOTATED — generic `Display a`) | `hello` | SIGSEGV (exit 133) | Two layers. Layer 1 (return-type inference) FIXED 2026-06-10. Layer 2 (dict routing) is a compiler-typecheck/dict_pass gap, NOT an emitter gap — out of EMIT-ONLY scope. |
| F1b | `f : String -> <IO> Unit; f s = println s; main = f "hello"` (CONCRETE-annotated) | `hello` | `hello\n()` PASS | FIXED 2026-06-10 by the return-type-propagation fix (see below). Was `hello\n0` before. Fixture: `println_param_fn_typed.mdk` |

**Layer 1 (return-type inference) — FIXED (Stage 3 #2b layering, construct-gap F1, 2026-06-10).**
`f`'s body lowers to `CApp (CDict "println" routes) [s]` — a constrained-function
occurrence with a `CDict`/`CMethod` head, not a bare `CVar`. `typeOf`'s
application arm in `compiler/backend/llvm_emit.mdk` only handled a `CVar` head (routing to
`callRetTy`) and defaulted every other head — including `CDict`/`CMethod` — to
`LTInt`. So `f`'s inferred return type was `LTInt`, propagating to `main`'s result
LTy and auto-printing `0` instead of `()`. Fix: extend `typeOf`'s app arm with
`CDict fname _ => callRetTy sigs fname` and `CMethod fname _ _ _ => callRetTy sigs
fname`, mirroring the emit path (`emitDictApp`/`emitMethod` both type their result
via `fnRetTy e name`). This makes the CONCRETE-annotated form (F1b) emit
`hello\n()` and the diff/fixpoint gates stay byte-identical.

**Layer 2 (dict routing) — STILL OPEN, NOT an emitter gap.** With `f` left
UNANNOTATED, the typechecker generalizes it to `Display a => a -> <IO> Unit`, so
`f` should receive a leading Display **dict parameter** and forward it (`RDictFwd`)
into the `println` call. The compiler dict-pass does NOT do this: `mdk_f` is
emitted as `mdk_f(i64 %arg0)` (no dict param) and `f`'s body calls
`mdk_println(i64 0, i64 %arg0)` — dict word `0` (`RNone`). `println`'s body is a
Display dict-dispatch switch over its dict arg; dict `0` matches no impl tag and
falls to the `unreachable` terminator → SIGSEGV. The emitter is faithfully
lowering what dict_pass produced; the missing leading dict param + `RDictFwd` route
is upstream in `compiler/types/typecheck.mdk` (dict-passing for a user fn that is generic
over a constraint consumed by a return-position constrained call). This is an
EMIT-ONLY-out-of-scope dispatch fix, deferred.

**Fix target (Layer 2):** `compiler/types/typecheck.mdk` — give a user fn generic over a
constraint used in a return-position constrained call a leading dict parameter and
route the constrained call through `RDictFwd` (not `RNone`).

---

### Gap G: comparison/equality OPERATORS never dispatch to user `Eq`/`Ord` impls — CLOSED (Phase 151, 2026-06-10, A2 type-directed rewrite)

**STATUS: CLOSED for interpreter + compiler eval + native `==`.** Native `<`/`lt` on a
user ADT is deferred behind the pre-existing slice-7 arg-tag-on-primitive emitter gap
(below). The original diagnosis (kept below) was correct about the root cause; the fix
took the **A2** route (type-directed post-typecheck rewrite) rather than the desugar-time
plan, because the primitive-vs-ADT gate can only be decided *after* inference grounds the
operand type.

**The fix (A2):**
1. **AST ref.** `EBinOp` carries a dispatch ref — `lib/ast.ml:155` (`resolved option ref`)
   and `compiler/frontend/ast.mdk:118` (`Ref Route`). `None`/`RNone` for primitives, arithmetic, and
   other operators; sexp/astdump ignore it (byte-identical dumps).
2. **Typecheck stamp (the recursion-avoidance gate).** At a comparison `EBinOp`, once the
   operand type is **ground**, if its head is a **non-primitive** (NOT
   Int/Float/Char/String/Bool) with an Eq/Ord impl, stamp the impl key (RKey):
   `lib/typecheck.ml` `binop_usages` + `check_binop_usages`; `compiler/types/typecheck.mdk`
   `pendingBinopSites` + `resolveBinopSites`. Primitive/ungroundable operands stay
   `None`/`RNone` → the structural-builtin `EBinOp` path (so `impl Eq Int.eq a b = a == b`
   never recurses).
3. **Rewrite pass.** The stamped node becomes a method application via the existing
   Phase-69 dispatch node: `lib/dict_pass.ml` `rewrite_binops` (wired into `Dict_pass.run`
   AND `Eval.eval_modules` — the loader path uses `run_decl` directly, not `run`) →
   `EMethodRef`-based app; `compiler/types/typecheck.mdk` `dictPass`→`rewriteBinopExpr` →
   `EMethodAt`-based app. `<`→`lt a b`, `>`→`gt`, `<=`→`lte`, `>=`→`gte`, `==`→`eq a b`,
   `!=`→`not (eq a b)`. Backends need NO new comparison logic — the rewritten node is an
   ordinary method app they already dispatch (arg-tag selects the impl).

**Verified:** the `Apple < Zebra` rank repro now returns `False` (was `True`) on interpreter
+ compiler; mod-3 `(M 1) == (M 4)` returns `True`; operator == method == oracle on
user-written impls. Primitive-only program IR **byte-identical** pre/post. Native `==` on a
user-impl ADT builds + runs == interpreter (`test/construct_fixtures/operator_eq_user_impl.mdk`).
Tests: `test_run`/`test_eval` operator-dispatch + primitive-unchanged cases; `test_loader`
cross-module operator dispatch (drives `eval_modules`).

**Native `<` deferral.** `medaka build` of a user-ADT `<` panics
`llvm_emit.mdk:…: arg-tag dispatch on impl type that owns no constructors (slice 7)` — the
rewritten `lt` method-app hits the SAME pre-existing slice-7 arg-tag-on-primitive emitter
gap a direct `lt` call does. This is the Gap-C/D3b class; NOT fixed here (out of scope).

**Out of scope (pre-existing) — NOW FIXED 2026-06-10.** A compiler-vs-oracle divergence on
*derived* `Ord` `compare`/`lt` (e.g. `compare Red Blue` = `Gt` compiler vs `Lt` oracle)
existed on `main`, independent of operators. **Root cause:** `compiler/frontend/desugar.mdk`'s
`deriveForData` had no `"Ord"` arm, so derived `Ord` for `data`/record types was silently
dropped → fell back to the inverted primitive ctor-tag `compare`. The generator
`deriveOrdData` already existed and was correct (wired only into `deriveForNewtype`). **Fix:**
added the one missing arm
`deriveForData name params variants "Ord" = Some (applyDeriveParams name params (deriveOrdData name variants))`,
mirroring the OCaml oracle (`lib/desugar.ml:574`). Now `compare Red Blue` = `Lt` and
`Red < Blue` = `True` on compiler == oracle (nullary AND payload, field-lexicographic). The A2
operator rewrite (Gap-G) now routes `<` to the *correct* derived compare. Fixtures:
`test/diff_fixtures/adt_deriving_ord.mdk` (compare-only, untyped-safe; in the eval_run/golden
corpus) + `test/eval_dict_fixtures/adt_deriving_ord.mdk` (adds `<`, typed/dict path). Self-compile
fixpoint untouched — no `compiler/*.mdk` derives `Ord` on a `data` type. **Follow-up CLOSED
2026-06-10:** `deriveForRecord` was a full stub (`deriveForRecord _ _ _ _ = None`) — records
derived NO interfaces. Added `Eq`/`Ord`/`Debug`/`Display`/`Generic` arms via dedicated
field-access generators (`deriveEqRecord`/`deriveOrdRecord`/`deriveShowRecord`/
`deriveGenericRecord`) mirroring `lib/desugar.ml`'s `derive_*_record` family — a record reads
its fields by name through `EFieldAccess` (NOT positional ctor patterns), so records do NOT
reuse the data derivers. `record Point { x:Int, y:Int } deriving (Eq, Ord, Debug)`:
`==`/`compare`/`debug` byte-identical compiler == oracle (incl. typed-path `<` dispatch).
Fixtures `test/diff_fixtures/record_deriving.{mdk,golden}` + `test/eval_dict_fixtures/record_deriving_ord.mdk`.

---

#### Original diagnosis (kept for record) — RE-DIAGNOSED 2026-06-10


**⚠️ Earlier framing here ("Ord default-method dispatch bug; native correct") was
WRONG.** A deeper read-only investigation overturned it. The real bug is far more
fundamental and affects **all three** backends.

**Root cause:** the operators `==` `!=` `<` `>` `<=` `>=` are parsed to an `EBinOp`
AST node that is **never rewritten into a method call** (desugar/marker/typecheck
leave it). So they NEVER dispatch to a user/derived `Eq`/`Ord` impl — each backend
hard-codes a structural built-in that ignores the impl:

| Backend | built-in for ADT `<` | orders by |
|---|---|---|
| `lib/eval.ml:1267-1270` (`eval_arith`, `Stdlib.compare` on `value`) | constructor **NAME** (alphabetical) |
| `compiler/eval/eval.mdk:1143-1146` (`evalArith`→`valueCompare`, `:438`) | constructor **NAME** |
| native: `core_ir_lower.mdk:68` `EBinOp`→`CBinPrim` → `llvm_emit.mdk:1508` `emitIntCmp` | constructor **TAG** (declaration order) |

`==`/`!=` have the identical defect (`eval.ml:1265-1266`, `eval.mdk:1141-1142`).
`typecheck` records the iface usage (`lib/typecheck.ml:2285-2291`) only to *verify an
impl exists* — it never rewrites the node, so eval never calls the impl.

**Both the `Low < High` result AND "native correct" were coincidences.** Proof native
is also wrong (rank order ≠ declaration order): `data Level = Apple | Zebra; impl Ord …
compare = compare (rank a) (rank b)` with `rank Apple=100, rank Zebra=1`. `Apple <
Zebra` should be `False`; **all three return `True`** (tree-walkers: `"Apple"<"Zebra"`;
native: Apple-tag<Zebra-tag). `==` likewise: custom mod-3 `Eq`, `(M 1) == (M 4)` should
be True; operator gives False on all three, while `eq (M 1) (M 4)` (method form) = True.

**What works:** the METHOD forms `lt`/`gt`/`lte`/`gte`/`min`/`max`/`eq` invoked by name
dispatch correctly (the default-method→`compare` dispatch is sound). `Int`/`Float`
operators are fine (structural == numeric). Only the OPERATOR SYNTAX on user `Eq`/`Ord`
ADTs is broken. Masked wherever code uses `compare`/`eq` directly (map/set tree ops).

**Blast radius:** all 6 operators on any user/derived `Eq`/`Ord` ADT whose
semantic order/equality differs from the backend's structural built-in. This is a real
correctness bug in *every* backend, not just an oracle quirk.

**Fix plan (recommended; DEFERRED — needs oversight):** desugar `EBinOp {==,!=,<,>,<=,>=}`
into the corresponding method application (`<`→`lt`, `==`→`eq`, `!=`→`not (eq …)`, …)
in `lib/desugar.ml` + the `compiler/frontend/desugar.mdk` mirror, routing operators through the
existing Phase-69.x dispatch so all three backends agree and call the user impl. The
`eval_arith`/`emitIntCmp` arms for these ops become dead. **Must special-case
primitives** (`Int`/`Float`/`Char`/`String`/`Bool`) onto the fast structural path to
avoid regressing the hot path / infinite recursion (`impl Ord Int.compare` uses `<` on
Int). **Risk: medium-high** — reroutes every comparison in every program; expect large
golden/byte-IR churn → needs full `@thorough` + `bootstrap_*`/`selfcompile_*`
re-baseline. `add-language-feature`-scoped. NOT done autonomously.

Repro: `data Level = Apple | Zebra; impl Ord Level where compare a b = compare (rank a)
(rank b); rank x = match x { Apple => 100; Zebra => 1 }; main = println (debug (Apple <
Zebra))` → should be `False`; all three backends give `True`.


---

### Gap H: Stdlib module imports — ✅ CLOSED (2026-06-18 audit)

**Verification (2026-06-18 audit):** `import map/set/array/list/string` all work in `medaka build`. H-b1 (map `toList` dispatch) and H-b2 (set `Eq` dict threading) were closed by the float-soundness arc / emitter dict-pass rework. All six stdlib modules pass both `medaka run` and `medaka build`.

| Module | medaka run | medaka build | Status |
|--------|-----------|--------------|--------|
| `list`   | PASS | PASS | ✅ |
| `array`  | PASS | PASS | ✅ |
| `string` | PASS | PASS | ✅ |
| `io`     | PASS | PASS | ✅ |
| `map`    | PASS | PASS | ✅ CLOSED (was H-b1) |
| `set`    | PASS | PASS | ✅ CLOSED (was H-b2) |

---

### Gap I: Open effect row return type

| # | Construct | Oracle | Native | Note |
|---|-----------|--------|--------|------|
| I1 | Function returning `<IO \| e> Unit` called from main | `42` | `42\n0` | The open-row function emits an extra `0` (unit value) before the trailing `()` |

**Fix target:** `compiler/backend/llvm_emit.mdk` — open effect row functions should return the same Unit value as closed-row `<IO> Unit` functions.

---

## Fixture directory

All PASS fixtures: `test/construct_fixtures/*.mdk` (115 files)
Gate script: `test/build_construct_coverage.sh`

```
test/construct_fixtures/
  adt_block_form.mdk        adt_float_ctor.mdk       adt_record_variant.mdk
  annotated_let_in.mdk      array_copy.mdk           array_extern_ops.mdk
  array_from_list.mdk       array_index.mdk          array_set_unsafe.mdk
  array_slice_el.mdk        attr_inline.mdk          bare_io_block.mdk
  bool_ops.mdk              char_from_code.mdk       char_ops.mdk
  comparison_ops.mdk        compose_left.mdk         compose_right.mdk
  cons_op.mdk               ctor_pat_lambda.mdk      debug_list_after_as.mdk
  default_impl_override.mdk deriving_debug.mdk       deriving_eq.mdk
  do_option.mdk             do_result_int.mdk        effect_decl.mdk
  effect_var_sig.mdk        export_fn.mdk            float_arith.mdk
  float_compute.mdk         float_to_int.mdk         float_to_int2.mdk
  float_two_ctor.mdk        fn_clause_guards.mdk     fn_guard_with_pat.mdk
  foldable_length_list.mdk  function_keyword.mdk     guard_chain_multi.mdk
  hof_multi.mdk             if_else.mdk              if_else_expr.mdk
  if_let.mdk                if_let_else.mdk          if_no_else.mdk
  int_to_float.mdk          interface_impl.mdk       io_write_read.mdk
  let_annot_inline.mdk      let_in.mdk               list_append.mdk
  list_comp_basic.mdk       list_comp_let.mdk        list_comp_multi_fst.mdk
  list_filter.mdk           lit_binary.mdk           lit_float.mdk
  lit_hex.mdk               lit_octal.mdk            lit_underscores.mdk
  map_option.mdk            match_arm_guard.mdk      match_as_pattern.mdk
  match_cons_pat.mdk        match_ctor.mdk           match_explicit_list.mdk
  match_indented.mdk        match_record_pat.mdk     match_string_pat.mdk
  match_tuple_pat.mdk       multi_clause.mdk         multi_clause_fn.mdk
  multi_param_iface.mdk     ord_compare.mdk          ord_int.mdk
  partial_apply.mdk         pipe_op.mdk              prop_test.mdk
  pub_export_debug.mdk      pure_option.mdk          put_str.mdk
  question_op.mdk           range_half_open.mdk      range_inclusive.mdk
  record_chain_access.mdk   record_construct.mdk     record_nested_update.mdk
  record_pat_rest.mdk       record_pun.mdk           record_update.mdk
  ref_let_mut.mdk           section_bare.mdk         section_left.mdk
  section_right.mdk         str_compare.mdk          str_concat_list.mdk
  str_index_of.mdk          str_interp.mdk           str_interp_multi.mdk
  str_length.mdk            str_slice.mdk            str_to_chars.mdk
  str_unicode_escape.mdk    str_upper_lower.mdk      superclass.mdk
  toplevel_mutual_rec.mdk   triple_quoted.mdk        tuple_fst.mdk
  tuple_pat_lambda.mdk      type_alias.mdk           type_annot_expr.mdk
  unary_minus.mdk           unary_not.mdk            where_multi_defs.mdk
```

### Dict-pass SIGSEGV cluster — ROOT-CAUSED 2026-06-10 (read-only investigation)

Two distinct compiler-only root causes (oracle is correct in both):
- **Cause A (F1-Layer2) — ✅ CLOSED 2026-06-10 (elaborateModules promotion+arity layer):**
  the build path (`elaborateModules`) had no inferred-constraint promotion — an
  unsignatured fn whose body dispatches a method (`f s = println s` / `f s = display s`)
  was never promoted → no leading dict param → `println`/`display` received dict word 0
  → SIGSEGV/silent. **Fix (3 pieces, compiler-only):** (1) `inferMethodAt`'s arg-position
  arm now ALSO records the discriminating-arg mono into `methodSiteFns` (new
  `recordArgSiteFn`), mirroring `recordSite`, so `inferredConstraintIds` discovers an
  arg-position inferred constraint; (2) `elaborateModules` seeds `dictEligibleRef` with
  the USER modules' fn names (gated `argStampEnabled`) and runs a JOINT-flattened
  promotion fixpoint (`discoverPromotedModules`/`discoverPromotedJoint`, mirror of
  `discoverPromoted`) over `runtime ++ core ++ all-modules`, feeding the promoted names
  into the dict-name set and snapshotting their arities into `crossModuleFunConstraintsRef`
  (carried across the per-module `resetState`); (3) the joint bare-name `seedDictAritiesFromSigs`
  was replaced with **per-module importer-scoped arity** (`dictPassModulesScoped`/`scopeArities`,
  mirroring oracle `eval.ml:2104-2164` — scope = own decls ∪ transitive importers ∪ core,
  import edges reconstructed from `DUse`), closing the Phase-134 bare-name conflation.
  **EARLY-CHECKPOINT (var-id seam): CLEAN** — `mdk_f` emits 2 args (leading `$dict_f_0` +
  value), forwards the dict to `mdk_println`, and the call site supplies a real impl-group
  dict word (not 0); joint-discovery vs per-module-stamping arities agreed (no silent
  partial closures). One regression caught + fixed during the work: `discoverPromotedJoint`
  returns seed-GROWN names, so the snapshot must SUBTRACT the seed (else prelude
  `debugListItems`/`displayListItems`/`hashListItems` got re-snapshotted joint arities that
  overrode their per-module sig arity → element-dict arg dropped → `cons_op` SIGSEGV); also
  a `resetState ()` after discovery wipes its scratch inference side-effects. Repro
  `f s = println s; main = f "hello"` → native `hello` == oracle; `f s = display s`, f→g
  promotion chains, multi-type use all native==oracle. Fixture
  `test/llvm_fixtures_modules/promoted_arg_dict/`.
- **Cause B (H-b2 ≡ audit L2) — ✅ CLOSED (one-level, 2026-06-10):** `routeOfMono`
  returned `RKey tag []` — dropped nested element reqs (`Eq a` inside
  `Eq (Box a) requires Eq a`). The real victim was the build/module path:
  `elabModuleStamp` passed an EMPTY implTable into `resolveSites`/`resolveDictApps`,
  so even the recursive builder had nothing. **Fix:** threaded the cumulative
  `implTable` through the whole route chain (`routeOfMono` → `RKey tag
  (implRequiresRoutesRec implTable tag m)`; `routesOfMonos`/`resolveDictApps`/
  `resolveMethodDicts`/`argImplReqRoutes`/`argReqRoute` carry it; `elabModuleStamp`
  binds `stampImplTable` and feeds `resolveSites` + `resolveDictApps`), AND made
  `collectDictSites` scan the `EMethodAt` impl-/method-route lists so `usesImplDict`
  sees a nested arg-position `RDict $dict_<m>_<slot>` and `implDictPassMethods`
  prepends the param. Additive (goldens byte-identical, fixpoint holds). Box repro +
  `import set.{Set}` build native == oracle (`True`, no SIGSEGV). RESIDUAL: two-level+
  nesting still SIGSEGVs (emitter `dictWordOfRoute` materializes only the head tag —
  flat i64 dict word can't carry a nested dict); `map`/Map blocked on a SEPARATE
  arg-tag `toList` gap. Fixtures: `test/construct_fixtures/nested_requires_dict.mdk`,
  `test/eval_dict_fixtures/nested_requires_box.mdk`.
- F1-L2 ≠ H-b2 (upstream promotion vs downstream nested route). D11 (driver coverage) is
  orthogonal. Interpreter masks both via arg-tag fallback; native fails loud.

**UPDATE 2026-06-10 (Fix A attempted → STOPPED; sharper root cause):** `medaka build`
routes through `elaborateModules` (`typecheck.mdk:4574`), NOT `elaborateDict`.
**`elaborateModules` has NO inferred-constraint promotion fixpoint** — no
`discoverAll`/`discoverPromoted`, and it never seeds `dictEligibleRef` (only
`elaborateDict:2248` does). So on the build path an unannotated constrained fn is never
eligible → never promoted → no dict param (Cause A), AND `routeOfMono`'s implTable
(built only in `elaborateDict:2253`) isn't threaded (Cause B). Recording the
arg-position occurrence (Fix A) is a correct PREREQUISITE but inert without an
`elaborateModules` promotion layer. **Both Cause A and Cause B are blocked on the same
structural gap: the build/multi-module path (`elaborateModules`) lacks the dict-promotion
+ implTable machinery the single-file typed path (`elaborateDict`) has** — the audit's
"dual drivers fragile" issue. Closing them needs an `elaborateModules` promotion +
implTable-threading layer with cross-module dict-arity consistency → oversight-scale,
needs @thorough + selfcompile_fixpoint re-baseline. DEFERRED (clean STOP, no partial
merge). (Also: F1 unannotated native = SIGSEGV exit 133, not silent — corrects the F1
note.)

### Gap E (Float corruption) — ROOT-CAUSED 2026-06-10 (read-only investigation)

**ONE shared root cause:** the emitter's static `LTy` recovery (`inferSigs`/`paramUseTy`/
`typeOf`) **never reads declared signatures** and defaults Float-typed bindings to
`LTInt`; `emitArith` (`llvm_emit.mdk:1451-1467`) then selects INTEGER ops (`ashr`+`add`)
on a boxed-Float pointer-word → garbage / SIGSEGV. Value rep + box/unbox/field layout are
SOUND — bug is int-vs-float instruction selection from too-weak inference.
- **E1 — CLOSED 2026-06-10 (Fix C).** `double x = x+x` (`: Float -> Float`): `paramUseTy`
  can't anchor a symmetric binop of bare vars (no Float literal) → param `LTInt` → int
  arith → garbage. **Fix:** `core_ir_lower.declSigTypeNames : List Decl -> List (String,
  (List String, String))` reads each `DTypeSig` (also under `DAttrib`) into fn-name →
  (declared-param-type-head-names, declared-return-type-head-name), e.g. `double` →
  (`["Float"]`, `"Float"`) (`methodArgTys`/new `methodRetTy` split the `TyFun` chain,
  `tyHeadName` takes each head). Each emit driver installs it into
  `llvm_emit.declSigTypesRef` via `installDeclSigTypes` (mirrors `installCtorFieldTypes`).
  Signature inference SEEDS from it: `inferSigs`/`inferPass` look up the binding's declared
  sig by name (`declSigOf`); `inferOneSig`/`inferMultiSig` pass it to `inferParamTysSeed`/
  `inferMultiParamTys` (per-param `seedParamTy` overrides the body-use guess with the
  declared scalar `fieldNameToLTy` when known) and wrap the return in `seedRetTy`. ADDITIVE:
  an unannotated fn (`dsig=None`) or a non-scalar declared head keeps the existing guess, so
  literal-anchored Float fns and Int fns (declared `Int` seeds `LTInt` = default) are
  unchanged. Repro `double : Float -> Float; double x = x + x`, `double 3.14`: oracle `6.28`,
  native was garbage, now `6.28`. Fixture `test/construct_fixtures/float_annot_nolit.mdk`.
  Anchored-Float (`x+1.0`), Int, and unannotated fns verified unaffected. Self-compile
  fixpoint (C3a/C3b) holds byte-for-byte.
- **E2 — CLOSED 2026-06-10 (Fix B).** `Rect w h => w*h`: match-bound field vars
  defaulted `LTInt` (`bindPattern`/`bindFields`) → int-mul on Float pointers → small int
  word → fed to `mdk_impl_Float_debug` → `inttoptr`+`load double` at a bogus addr → SIGSEGV.
  NOT about two fields — arithmetic on a mistyped field var. **Fix:** recover each match-bound
  field's type from the constructor's **DECLARED** field types (not body-use guessing).
  `core_ir_lower.ctorFieldTypeNames : List Decl -> List (String, List String)` builds
  ctor→declared-field-type-head-name (`Rect` → `["Float","Float"]`, both `ConPos`/`ConNamed`
  + `DNewtype`); each emit driver installs it into `llvm_emit.ctorFieldTypesRef` via
  `installCtorFieldTypes` (mirrors `installReturnsSelf`); `bindPattern (PCon c args)` now calls
  `bindFieldsDecl … (ctorFieldTypeNamesOf c)`, and `bindVarTy` types a field PVar/PAs from the
  declared scalar (`fieldNameToLTy`: Float/Bool/Int/Char/String) when known, else falls back
  to `paramUseTy`/`LTInt`. Additive: only known-scalar declared fields change typing; nested
  patterns / unknown / non-scalar fields unchanged. Repro `Rect Float Float; area r = match r
  { Rect w h => w*h }`, `area (Rect 3.0 4.0)`: oracle `12.`, native was SIGSEGV, now `12.`.
  Fixture `test/construct_fixtures/adt_float_ctor_arith.mdk`. Single-Float-field
  (`adt_float_ctor.mdk`), Int-field, and Bool+Float variants verified unaffected. Self-compile
  fixpoint (C3a/C3b) holds byte-for-byte. **(E1 since closed by Fix C — see below.)**
- **E3 — CLOSED 2026-06-10 (Fix A).** lambda Float: lambda params were forced `LTInt`
  UNCONDITIONALLY via `allInt` (`:2873`,`:2977`) — `paramUseTy` never consulted → corruption
  even with a body literal. **Fix:** both lambda-define sites (`emitLamDefine`,
  `emitRecLamDefine`) now type params via `inferParamTys (sigTable e) pats body` instead of
  `allInt pats` — the SAME per-param `paramUseTy` inference named-fn params already use.
  Additive: params `paramUseTy` can't resolve still default `LTInt`; captured vars (typed via
  `cenv`/`loadCaptures`) unchanged. Repro `(y => y + 1.0)` 3.0: oracle `4.`, native was garbage
  (`7.54792489297e+168`), now `4.`. Fixture `test/construct_fixtures/lambda_float_param.mdk`.
  Self-compile fixpoint (C3a/C3b) holds. **(E1 since closed by Fix C — see below.)**
**Fix plan:** ~~Fix A (E3) thread `paramUseTy` into lambda params (replace `allInt`)~~ DONE;
~~Fix B (E2) recover field types from the ctor's DECLARED field types~~ DONE;
~~Fix C (E1) thread declared signatures into `inferSigs` (emitter shouldn't guess told types)~~ DONE.
**Gap E FULLY CLOSED 2026-06-10 (E1+E2+E3).** All emitter-local type-inference fixes; rep
untouched; zero golden churn (existing Float fixtures have literal anchors; the self-compile
fixpoint held byte-for-byte through every fix). Fixtures: `float_annot_nolit.mdk` (E1),
`adt_float_ctor_arith.mdk` (E2), `lambda_float_param.mdk` (E3).

### Gap C — RE-DIAGNOSED 2026-06-10 (shrunk 8→4; mostly folds into the elaborateModules layer)
- **C6/C7/C8 = NOT gaps — now CONFIRMED PASS (fixture added):** the original fixtures
  omitted `import array` (the `Debug (Array a)`/`Foldable Array` impls are in
  `stdlib/array.mdk:446,496`, not `core.mdk`) — the ORACLE failed identically. With
  `import array` (enabled by the H-a stdlib-on-build-path fix), native == oracle.
  Fixture `test/construct_fixtures/stdlib_array_ops.mdk` (debug-on-Array + length-via-
  Foldable + slice) is GREEN native==interpreter. C6/C7/C8 closed.
- **C4 = Gap E, not Gap C: ✅ CLOSED 2026-06-16 (`a8b95d7`).** post the E1/Fix-C declared-sig
  seeding, C4 BUILT but emitted garbage Float — int-vs-float instruction selection was gated on an
  *explicit signature*. The residual was the **unannotated** poly-`Num` case: `isNumPolyParam`
  seeded `LTNum` only when `dsig = Some`, so `dbl x = x + x` (no sig, no literal) at Float defaulted
  to `LTInt` → integer `add` on the Float box → silent garbage on `medaka build`. Exposed (made
  reachable) by feature #11 — bare poly-`Num` fns now typecheck at Float. Fix: seed `LTNum` for any
  unannotated arith-used unanchored param (generalizing the G9 section-lambda special-case) +
  `reservedCtorsOfType` fallback for the List/Option/Result/Ordering Foldable-dispatch sibling
  (`total xs = fold (+) 0 xs` hard-errored "owns no constructors" because built-in `Cons`/`Nil`
  live in `reservedTag`, not `ctorTypeTable`). Fixpoint C3a/C3b held byte-for-byte.
- **Genuine Gap C = 4 sites, 2 mechanisms:**
  - *Mech 1 — no head tycon → RNone → arg-tag panic* ("owns no constructors"):
    `headTyconMono` (`typecheck.mdk:3482`) returns `None` for `TTuple`/`TVar`; arg-tag
    can't inspect a tuple/primitive/typevar (no per-type cell tag). C2/C3-unannotated =
    **Cause A — ✅ CLOSED 2026-06-10** (promotion now gives the poly/unannotated fn its
    dict param; `f s = display s`/`p x = println x` build native==oracle). C1/C5b (bare
    tuple, monomorphic) = **self-contained, OPEN**: needs tuple-as-a-dispatch-tag (give
    `headTyconMono (TTuple _)` a `$tuple` head → RKey route to `mdk_impl_tuple_*`).
  - *Mech 2 — nested element dict dropped (RKey reqs=[]) → SIGSEGV:* C5 (`debug` on
    `List (Int,Int)`), C2-tuple = **Cause B** (`routeOfMono` empty reqs) — one-level CLOSED,
    two-level+ RESIDUAL.
- **Consolidation:** Cause A (+ Gap C C2/C3-unannotated) ✅ CLOSED by the `elaborateModules`
  promotion+arity layer; Cause B one-level CLOSED. Documented Gap-C/promotion RESIDUALS
  (still gap, by design): (1) **`debug`/`display` on a `List a` element** (`g xs = debug xs`,
  `cons_op`-with-element-dict, C5) needs the nested element dict — the Cause-B two-level
  emitter dict-rep limit (flat i64 word can't carry a nested dict); (2) **a constraint that
  lives on an inner lambda bound to a zero-arg value** (`g = (x => debug x)`) — promotion
  targets top-level fn params, not a lambda inside a value binding; dict-passing the lambda
  is a deeper (emitter lambda-dict) layer. Still separate: C1/C5b (tuple-as-tag) + C4 (→Gap E).
  Interpreter masks all via runtime type tags (`eval.mdk:198`).

### IMPLEMENTATION PLAN — elaborateModules dict layer (the cluster-closing fix; oversight-scale)
**STATUS 2026-06-10: piece 1 (Cause B one-level) + piece 2 (Cause A promotion) + piece 3
(per-module arity) ALL LANDED.** Cause A CLOSED; Gap C C2/C3-unannotated CLOSED; Phase-134
bare-name conflation removed. Residuals (by design, documented above): Cause-B two-level
nesting + `debug`-on-`List`-element + lambda-bound-constraint + tuple-as-tag (C1/C5b) + Gap-E
C4. Self-compile fixpoint (C3a/C3b) byte-identical, no re-baseline. Original plan below.

*Correction:* `elaborateModules` (`typecheck.mdk:4576`) ALREADY has an E4/E5/E6 layer that
dict-passes *signatured* constrained fns cross-module. The remaining gap is 3 specific pieces:
1. **Cause B (LANDED 2026-06-10 — one-level CLOSED):** threaded the cumulative
   `implTable` (built at `elabModuleStamp`) into the return-position route chain
   `resolveSites`/`resolveDictApps`→`routesOfMonos`→`routeOfMono` and the arg-position
   `argImplReqRoutes`→`argReqRoute`, with `routeOfMono`'s concrete arm now
   `RKey tag (implRequiresRoutesRec implTable tag m)`. Also extended `collectDictSites`
   to scan the `EMethodAt` impl-/method-route lists so `implDictPassMethods`'
   `usesImplDict` gate prepends the param for an arg-position nested `RDict`. Unblocked
   the Box repro + `import set.{Set}` SIGSEGVs. Self-compile fixpoint (C3a/C3b) +
   every dict/eval/llvm gate green, byte-identical. RESIDUAL: two-level+ nesting needs
   a richer emitter dict rep (flat i64 word can't carry nested dicts); `map`/Map blocked
   on a separate arg-tag `toList` gap.
2. **Cause A + promotion (the bulk):** seed `dictEligibleRef` with USER-module fn names only
   (mirror `elaborateDict:2246`; gate on `argStampEnabled` so oracle drivers stay `[]`); run a
   JOINT-flattened discovery fixpoint (`discoverPromotedModules`, mirror `discoverPromoted:2273`)
   to populate `promotedRef`/`funConstraintsRef`; feed promoted names into `moduleDictNames:4641`.
   Prerequisite: record arg-position method occurrences in `inferMethodAt`'s `Some idx` arm
   (`:1394-96`) into `methodSiteFns` (mirror `recordSite:1420`) — inert alone (why the prior
   Fix-A STOPPED), land WITH promotion.
3. **Per-module arity (land WITH #2 or the Phase-134 bug bites):** replace the JOINT
   `seedDictAritiesFromSigs (core2 ++ all modules)` (`:4629-4651`, bare-name keyed = Phase-134
   conflation) with per-module importer-scoped arity, mirroring oracle `eval.ml:2104-2164`
   (`collect_arities` over own-decls ∪ transitive-importers; reconstruct import edges from `DUse`).
   `mangleUnits` (`llvm_emit_modules_main.mdk:74`) already de-collides PRIVATE names; public
   cross-module constrained names are the residual the importer-scope must cover.
**Highest STOP risk:** the joint-discovery vs per-module-stamping seam — if surviving-unify-var-id
diverges between the two typechecks, routes bind wrong slots → silent partial closures (the Fix-A
STOP class). Instrument eval's `EDictAt`/`EMethodAt` resolution arms (NOT `module_debug`, which
mirrors the joint pass and won't flag it). **Tests:** loader-driven fixtures in
`diff_compiler_llvm_modules.sh` (Cause A/B + Gap C C2/C3/C5/C2-tuple); goldens stay byte-identical
(argStampEnabled OFF firewall); `@thorough` + `selfcompile_fixpoint` re-baseline (long pole).
**Scope:** medium-large; 3 landings (Cause B → promotion+A+arity → assertion). NOT one commit.

