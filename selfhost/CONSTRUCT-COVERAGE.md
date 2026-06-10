# CONSTRUCT-COVERAGE.md — `medaka build` native coverage matrix

Stage 3 #2b. Tested 2026-06-10 against the selfhost LLVM backend (`medaka build`).
Each construct was exercised with a minimal `main` program, diffed native vs
`medaka run` (interpreter oracle). Fixture programs live in
`test/construct_fixtures/`; the gate `test/build_construct_coverage.sh` runs all
PASS fixtures.

Convention: native appends `()` for `main : <IO*> Unit`; the comparison strips
that. A result is PASS iff `native_output == oracle_output ++ "\n()"`.

---

## Summary

**123 PASS fixtures** (gate `build_construct_coverage.sh` is the authoritative PASS list; the per-row matrix below may lag — the **§Gaps** sections are authoritative for each gap's closed/open status). Started 114 PASS / 15 GAP; closed F1·H-a·D1·D2·B1·B2 overnight. Confirmed NOT gaps: A1 (inline `|` match — ref rejects too), A4 (negative literal pattern — ref rejects too). Re-scoped: A2/A3 range patterns = selfhost typecheck (`PRng` in `inferPat`), not parser.

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
| `debug` on tuple (direct) | GAP | see §Gaps below |
| Float arithmetic (let-binding, literal anchored) | PASS | `float_arith.mdk`, `float_compute.mdk` |
| Float arithmetic (named fn, `+` via Num dispatch on Float params) | GAP | see §Gaps below |
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
| Refutable match-arm pattern-guard `x if Some y <- f x` | GAP | see §Gaps below |

### `let` / mutation

| Construct | Status | Fixture |
|-----------|--------|---------|
| `let x = e in body` | PASS | `let_in.mdk` |
| `let x : T = e in body` (inline annotated let) | PASS | `let_annot_inline.mdk` |
| `let x : T = e` in block (block annotated let) | GAP | see §Gaps below |
| `let f x = e in body` (let-bound function) | PASS | (tested inline) |
| `let rec f = x => ...` in block | GAP | see §Gaps below |
| `let rec ... with ...` at top-level | GAP | see §Gaps below |
| Top-level mutual recursion (separate clauses) | PASS | `toplevel_mutual_rec.mdk` |
| `let mut x = e` + reassignment `x = e` | PASS | `let_mut_reassign.mdk` |
| `let mut r = Ref e` + `set_ref r v` + `r.value` | PASS | `ref_let_mut.mdk` |
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
| `function` keyword point-free match | PASS | `function_keyword.mdk` |
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
| ADT with two Float fields (`Rect Float Float`) — match extracts both | GAP | see §Gaps below |
| `deriving (Debug)` | PASS | `deriving_debug.mdk` |
| `deriving (Eq)` | PASS | `deriving_eq.mdk` |
| `deriving (Eq, Ord)` — `<` comparison | GAP | see §Gaps below |
| `deriving (Eq, Ord)` — `compare` | GAP | see §Gaps below |
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
| Record `deriving (Debug)` | GAP | see §Gaps below |

### Tuples

| Construct | Status | Fixture |
|-----------|--------|---------|
| Tuple construction `(1, "hi")` | PASS | `tuple_fst.mdk` |
| Tuple pattern match `(a,b)` | PASS | `match_tuple_pat.mdk` |
| `debug` on tuple | GAP | see §Gaps below |

### Lists and comprehensions

| Construct | Status | Fixture |
|-----------|--------|---------|
| List `map` | PASS | (build_cmd.sh `list_map`) |
| List `filter` | PASS | `list_filter.mdk` |
| List `length` (via Foldable) | PASS | `foldable_length_list.mdk` |
| List comprehension with generator + filter | PASS | `list_comp_basic.mdk` |
| List comprehension with `let` qualifier | PASS | `list_comp_let.mdk` |
| Multi-generator comprehension (result not debugged as tuple) | PASS | `list_comp_multi_fst.mdk` |
| Multi-generator comprehension with `debug` on tuple result | GAP | see §Gaps below |

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
| `import map.*` / stdlib module imports | GAP-H (path fixed; `map`/`set` hit emitter gap) | `stdlib_list.mdk`, `stdlib_array.mdk`, `stdlib_string.mdk`, `stdlib_io.mdk` |

### IO and effects

| Construct | Status | Fixture |
|-----------|--------|---------|
| `putStr` / `putStrLn` | PASS | `put_str.mdk` |
| `println` in `main` directly | PASS | (all IO fixtures) |
| `println` in parameterized `<IO>` named fn (unannotated, generic `Display a`) | GAP | see §Gap F (Layer 2 dict routing) |
| `println` in parameterized `<IO>` named fn (concrete-typed) | PASS | `println_param_fn_typed.mdk` |
| `putStrLn` in parameterized `<IO>` named fn | PASS | (tested) |
| Bare indented IO block (multi-statement `main`) | PASS | `bare_io_block.mdk` |
| `readFile` / `writeFile` | PASS | `io_write_read.mdk` |
| `do`-notation for Option | PASS | `do_option.mdk` |
| `do`-notation for Result (Int) | PASS | `do_result_int.mdk` |
| `do`-notation for Result (Float) | GAP | see §Gaps below |
| `do`-notation for IO (multi-statement) | GAP | see §Gaps below |
| `Ref` cell create + `set_ref` + `.value` read | PASS | `ref_let_mut.mdk` |

### Misc declarations

| Construct | Status | Fixture |
|-----------|--------|---------|
| `prop` declaration | PASS | `prop_test.mdk` |
| `extern` declaration | PASS | (all runtime extern calls) |
| `@inline` attribute | PASS | `attr_inline.mdk` |
| `@deprecated` / `@must_use` | PASS (parse-only check) | — |

---

## Gaps (actionable follow-up tasks)

### Gap Group A: Selfhost parser gaps
These constructs parse correctly in the OCaml reference compiler but produce
`selfhost/parser.mdk: panic: parse error` in `medaka build`.

| # | Construct | Error | Repro |
|---|-----------|-------|-------|
| A1 | Match inline `\|` form: `match x \| 0 => "z" \| _ => "o"` | `parser.mdk:2428:32: panic: parse error` | `let r = match 0 \| 0 => "zero" \| _ => "other"` |
| A2 | Match int range pattern `1..9` | TYPECHECK-CLOSED (2026-06-10); EMIT-OPEN | `match n` / `  1..9 => "digit"` / `  _ => "other"` |
| A3 | Match char range pattern `'a'..='z'` | TYPECHECK-CLOSED (2026-06-10); EMIT-OPEN | `match c` / `  'a'..='z' => True` / `  _ => False` |
| A4 | Match negative literal pattern `-1` | NOT A GAP — ref REJECTS it too | `match n` / `  -1 => "minus"` / `  _ => "other"` |

**Triage (2026-06-10, indentation-form repros — the table's original `\|`-form
repros all hit A1 first, masking the real downstream behavior):**

- **A1** (inline `\|` match) — **NOT a selfhost-only gap. The OCaml reference
  parser also REJECTS `match x \| p => e \| _ => e`** (verified: `medaka run`
  → `Parse error`). The reference match grammar is indentation-based only.
  Adding the inline-`\|` form to the selfhost parser would make it *accept what
  the reference rejects* — a differential-oracle divergence, not a gap closure.
  Reclassify as design-decision (do not add) unless the reference grammar gains
  it first.

- **A2 / A3** (int / char range patterns `1..9`, `'a'..='z'`) — **TYPECHECK
  CLOSED 2026-06-10; EMIT still OPEN.** The selfhost *parser already accepts them*
  (`parsePatAtom` → `intPatRest`/`charPatRest` → `PRng`, parser.mdk:1216-1255).
  **Selfhost typecheck now handles them**: `inferPat` gained a `PRng` arm
  (`inferPatRng`, typecheck.mdk:~1180) mirroring the oracle (`lib/typecheck.ml:1299`):
  both bounds `LInt` → `Int`, both `LChar` → `Char`, anything else → a
  `Type mismatch` error; binds nothing; pattern type = the bound type. Verified
  selfhost == oracle on `test/typecheck_fixtures/range_pat.mdk` (`Int -> String`,
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
  *Caveat (unchanged):* the selfhost parser's range **bounds** reject `MINUS INT`
  (`intBoundFor` only matches `TInt`), so negative range bounds (`-1..1`, which
  the ref accepts via parser.mly:561-566) remain a separate selfhost-parser gap.

- **A4** (bare negative literal pattern `-1`) — **NOT A GAP. The OCaml reference
  parser REJECTS bare negative literal patterns in ALL positions** (match arm,
  fn-clause head `f (-1) =`, parenthesized `(-1)`, let-pattern) — verified
  `medaka run` → `Parse error` for each. Reference grammar `pat_atom`
  (parser.mly:549-573) has NO standalone `MINUS INT → PLit` production; `MINUS
  INT` appears in patterns ONLY as a range bound (parser.mly:561-566). Adding a
  bare-negative-literal pattern to `selfhost/parser.mdk` would make selfhost
  accept what the reference rejects → diverge from the differential oracle.
  The task premise ("the OCaml reference parser accepts it") does not hold.
  **No selfhost change made.**
| A5 | `where` clause inline (at end-of-body-line) | `parser.mdk:2428:32: panic: parse error` | `f x = x where g = 1` |
| A6 | `let rec fib = n => ...` in block (block form) | Both ref and selfhost fail; ref: `Parse error` at col 0 | N/A — both parsers reject this |
| A7 | `let rec ... with ...` at top-level | `emitter: unbound variable 'isEven'` (compiles but emitter can't resolve mutual refs) | `let rec isEven = n => ... with isOdd = n => ...` |
| A8 | `do` inside a named function body when function has `<IO>` effect type | `parser.mdk: parse error` | `printTwo : <IO> Unit \n printTwo = do \n  putStrLn "x"` |
| A9 | Record `deriving (Debug)` (block form, indent) | `parser.mdk: parse error` | `record Point \n  x : Int \n  y : Int \n  deriving (Debug)` |
| A10 | Annotated `let x : T = e` in block (block form) | Both ref and selfhost fail; ref: `Parse error` | N/A — both parsers reject this |
| A11 | `@`-pattern in lambda / function param (e.g. `setX v p@(Pt {x,y}) = ...`) | `parser.mdk: parse error` | `f p@{x,y} = x` |

**Fix target:** `selfhost/parser.mdk` — add these pattern/statement/expression forms.

---

### Gap Group B: Emitter missing block statement forms — CLOSED (2026-06-10)
`emitBlock` in `selfhost/llvm_emit.mdk` historically only handled `CSLet`(PVar/
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

**Location:** `selfhost/llvm_emit.mdk` `emitBlock` (new `CSAssign`/`CSLetElse`
arms) + new helpers `emitLetElse` / `bindFieldList` / `letElseHead` /
`irrefutableLet`. The four CStmt-walking analyses (`freeVarsStmts`,
`eagerVarsStmts`, `blockTy`, `scanStmtsRecords`) gained explicit `CSAssign` /
`CSLetElse` arms so their RHS/alt sub-expressions are no longer dropped by a
catch-all (matters for closure free-var capture + DCE reachability).

**Residual:** a let-else with a refutable NON-constructor pattern (e.g. a bare
int literal `let 0 = n else …`) records a contained gap (`letElseHead = None`);
not produced by current `selfhost/` source.

---

### Gap C: Arg-tag dispatch on constructorless types (tuples, polymorphic)
Dispatch via interface method when receiver is a tuple or polymorphic type variable
(which has no ADT constructors) panics with
`arg-tag dispatch on impl type that owns no constructors (slice 7: primitive receiver carries no cell tag)`.

| # | Construct | Trigger | Error |
|---|-----------|---------|-------|
| C1 | `debug` on tuple `(1,2)` | `Debug (Int,Int)` impl | arg-tag dispatch |
| C2 | `debug` on any type inside a generic lambda `xs => debug xs` | polymorphic `xs : a` | arg-tag dispatch |
| C3 | Multi-param lambda as local let without type annotation: `let add = x y => x+y` | `Num a` on polymorphic `x` | arg-tag dispatch |
| C4 | Polymorphic constrained fn `double : Num a => a -> a; double x = x+x` at Float | `Num Float` via arg-tag | arg-tag dispatch |
| C5 | Multi-generator list comprehension `[(x,y) \| ...]` with `debug` on tuple result | `Debug (Int,Int)` | arg-tag dispatch |
| C6 | `length` on Array via Foldable | `Foldable Array` via arg-tag | arg-tag dispatch |
| C7 | Array `[|1..=5|]` with `debug` | `Debug (Array Int)` | `no impl of method 'debug' for type 'Array'` |
| C8 | Array slice `arr.[1..3]` with `debug` on result | `Debug (Array Int)` | `no impl of method 'debug' for type 'Array'` |

**Fix target:** `selfhost/llvm_emit.mdk` — implement direct-dispatch fallback for primitive types (Int, Float, Bool, Char, Tuple, Array) in the arg-tag dispatch path so that `Debug`/`Num`/`Foldable` method calls on known primitive receivers don't attempt tag-based dispatch.

---

### Gap D: Emitter unbound variable for specific constructs

| # | Construct | Status |
|---|-----------|--------|
| D1 | Backtick infix `` a `divide` b `` | **PASS** (2026-06-10) — fixture `backtick_infix.mdk` |
| D2 | Newtype constructor `UserId 42` used as a function | **PASS** (2026-06-10) — fixture `newtype_ctor_fn.mdk` |
| D3 | Named impl `combine @Sum` hint syntax | `unbound variable '@Sum'` |
| D4 | `let rec ... with ...` top-level mutual rec | `unbound variable 'isEven'` — mutual rec bindings not wired together |

**D1 root cause + fix (2026-06-10).** `` a `f` b `` parses to `EInfix "f" a b` and
lowers correctly to `CApp (CApp (CVar "f" AGlobal) a) b`. The bug was NOT in
emit — it was DCE: `marker.collectVars (EInfix _ a b)` dropped the operator name,
so the backtick-referenced function `f` looked unreachable and `dce.dceFilter`
removed its `DFunDef`. The emitter then hit `unbound variable 'f'`. Fix:
`collectVars (EInfix op a b) = op :: …` (`selfhost/marker.mdk`). Built-in operator
symbols (`+`/`==`) never name a `DFunDef`, so the added name is inert for them.

**D2 root cause + fix (2026-06-10).** `core_ir_lower.ctorArities` only scanned
`DData`, so a `DNewtype`'s constructor was absent from the emitter's ctor table
and `UserId 42` resolved to an unbound variable. A newtype is structurally a
single-constructor, single-field data type (the oracle uses `make_ctor con 1`),
so the fix registers it as an arity-1 ctor:
`ctorArities ((DNewtype _ _ _ con _ _)::rest) = (con, 1) :: …`
(`selfhost/core_ir_lower.mdk`). EMIT-ONLY — no eval/canonPat/Core-IR shape change.

**Fix target (remaining):** `selfhost/llvm_emit.mdk` — D3: impl hints; D4: mutual-rec top-level wiring.

---

### OBS5 — `marker.collectVars` / `declRefs` DCE-reference-walk completeness audit (2026-06-10)

DCE (`dce.dceFilter`) drops any top-level `DFunDef` unreachable from `main` +
impl/interface bodies. Reachability is computed with `marker.collectVars`
(per-expr refs) + `marker.declRefs`/`declBodies` (per-decl bodies). If either
fails to walk a sub-expression or a NAME that can reference a top-level binding,
DCE silently drops a *reachable* function → emitter `unbound variable` crash
(this is exactly how D1 bit us). This audit enumerated every `Expr`, pattern,
and `Decl` form (`selfhost/ast.mdk`) against the walk.

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
`diff_selfhost_mark` stays byte-identical (verified: 144/0) — the marker's own
`droppablePreludeFns` use of `declRefs` sees identical results.

**Gates (all green, 2026-06-10):** `build_cmd` 13/0; `build_construct_coverage`
121/0; `diff_selfhost_llvm` 170/0; `_typed` 33/0; `_modules` 6/0;
`diff_selfhost_mark` 144/0; `selfcompile_fixpoint` C3a + C3b PASS (the whole
emitter graph still DCEs + reproduces byte-for-byte); `bootstrap_eval` 20/0.

---

### Gap E: Float value corruption / wrong output

| # | Construct | Oracle | Native | Note |
|---|-----------|--------|--------|------|
| E1 | Named fn `double : Float -> Float; double x = x + x` (no Float literal in body) | `6.28` | garbage or `0.` | `+` dispatches via Num on Float params without a literal anchor — **OPEN** |
| E2 | ADT with two Float fields, extracting both: `Rect Float Float; Rect w h => w * h` | `12.` | `12.` | **CLOSED 2026-06-10 (Fix B):** field vars now typed from ctor's DECLARED field types — see Gap E note below |
| E3 | lambda Float param `(y => y + 1.0) 3.0` | `4.` | `4.` | **CLOSED 2026-06-10 (Fix A)** — lambda params typed via `paramUseTy` |

**Fix target:** `selfhost/llvm_emit.mdk` — E1 (OPEN): thread declared signatures into `inferSigs` so a told Float param isn't guessed `LTInt`; E2/E3 closed.

---

### Gap F: `println` in parameterized named function

| # | Construct | Oracle | Native | Note |
|---|-----------|--------|--------|------|
| F1 | `f s = println s; main = f "hello"` (UNANNOTATED — generic `Display a`) | `hello` | SIGSEGV (exit 133) | Two layers. Layer 1 (return-type inference) FIXED 2026-06-10. Layer 2 (dict routing) is a selfhost-typecheck/dict_pass gap, NOT an emitter gap — out of EMIT-ONLY scope. |
| F1b | `f : String -> <IO> Unit; f s = println s; main = f "hello"` (CONCRETE-annotated) | `hello` | `hello\n()` PASS | FIXED 2026-06-10 by the return-type-propagation fix (see below). Was `hello\n0` before. Fixture: `println_param_fn_typed.mdk` |

**Layer 1 (return-type inference) — FIXED (Stage 3 #2b layering, construct-gap F1, 2026-06-10).**
`f`'s body lowers to `CApp (CDict "println" routes) [s]` — a constrained-function
occurrence with a `CDict`/`CMethod` head, not a bare `CVar`. `typeOf`'s
application arm in `selfhost/llvm_emit.mdk` only handled a `CVar` head (routing to
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
into the `println` call. The selfhost dict-pass does NOT do this: `mdk_f` is
emitted as `mdk_f(i64 %arg0)` (no dict param) and `f`'s body calls
`mdk_println(i64 0, i64 %arg0)` — dict word `0` (`RNone`). `println`'s body is a
Display dict-dispatch switch over its dict arg; dict `0` matches no impl tag and
falls to the `unreachable` terminator → SIGSEGV. The emitter is faithfully
lowering what dict_pass produced; the missing leading dict param + `RDictFwd` route
is upstream in `selfhost/typecheck.mdk` (dict-passing for a user fn that is generic
over a constraint consumed by a return-position constrained call). This is an
EMIT-ONLY-out-of-scope dispatch fix, deferred.

**Fix target (Layer 2):** `selfhost/typecheck.mdk` — give a user fn generic over a
constraint used in a return-position constrained call a leading dict parameter and
route the constrained call through `RDictFwd` (not `RNone`).

---

### Gap G: comparison/equality OPERATORS never dispatch to user `Eq`/`Ord` impls — ALL THREE backends wrong — RE-DIAGNOSED 2026-06-10

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
| `selfhost/eval.mdk:1143-1146` (`evalArith`→`valueCompare`, `:438`) | constructor **NAME** |
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
in `lib/desugar.ml` + the `selfhost/desugar.mdk` mirror, routing operators through the
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

### Gap H: Stdlib module imports — path + emitter gaps

**H-a CLOSED** (`lib/build_cmd.ml` + `bin/main.ml`): `stdlib/` is now added as a
trailing root for both `medaka run` (multi-file loader) and `medaka build` (emitter
subprocess). User `input_dir` comes first so user-side modules shadow stdlib names.
`medaka run` / `medaka build` for a single-file program can now resolve `import list.{…}`,
`import array.{…}`, `import string.{…}`, `import io.{…}`, etc.

**H-b OPEN** (emitter gaps): `map.mdk` and `set.mdk` hit emitter gaps even after the
path fix — they build and run fine under `medaka run` (interpreter) but fail at `medaka build`:

| # | Module | Error (medaka build) | Root cause |
|---|--------|----------------------|------------|
| H-b1 | `map` | `llvm_emit.mdk:375: panic: no impl of method 'toList' for type 'Map'` | `impl Foldable (Map k v)` uses `toList` dispatch the emitter can't resolve for Map |
| H-b2 | `set` | `llvm_emit.mdk:386: panic: unbound dict witness '$dict_eq_0' in emit env` | Constrained `Eq` dict not threaded to Set comparison sites |

**Path fix results per module:**

| Module | medaka run | medaka build | Fixture |
|--------|-----------|--------------|---------|
| `list`   | PASS | PASS | `stdlib_list.mdk` |
| `array`  | PASS | PASS | `stdlib_array.mdk` |
| `string` | PASS | PASS | `stdlib_string.mdk` |
| `io`     | PASS | PASS | `stdlib_io.mdk` |
| `map`    | PASS | GAP (H-b1 emitter) | — |
| `set`    | PASS | GAP (H-b2 emitter) | — |

**Fix target for H-b:** emitter dict-threading for constrained impls over `Map`/`Set` types.
Not touched here (emitter change, out of scope for this patch).

---

### Gap I: Open effect row return type

| # | Construct | Oracle | Native | Note |
|---|-----------|--------|--------|------|
| I1 | Function returning `<IO \| e> Unit` called from main | `42` | `42\n0` | The open-row function emits an extra `0` (unit value) before the trailing `()` |

**Fix target:** `selfhost/llvm_emit.mdk` — open effect row functions should return the same Unit value as closed-row `<IO> Unit` functions.

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

Two distinct selfhost-only root causes (oracle is correct in both):
- **Cause A (F1-Layer2):** `typecheck.mdk` `inferMethodAt` arg-position arm (`:1393-96`,
  `recordArgStamp`) records nothing into `methodSiteFns`; only the return-position arm
  (`recordSite`, `:1416-21`) does. So an inferred constraint from an arg-position method
  call (`println s`) never reaches `inferredConstraintIds` → fn never promoted → no dict
  param → dict word 0/`RNone`. Oracle (`lib/typecheck.ml:1504`) records ALL occurrences.
  **Fix A:** record arg-position monos in the arg arm too. Selfhost-only, low-med risk.
- **Cause B (H-b2 ≡ audit L2):** `routeOfMono` (`:3121-26`) returns `RKey tag []` — drops
  nested element reqs (`Eq (List a)` inside `Eq (Box a) requires Eq a`) → `$dict_eq_0`
  unbound in emit env → panic. Oracle recurses (`impl_requires_routes_rec`). **Fix B:**
  thread `implTable` into `routeOfMono` + call the existing `implRequiresRoutesRec`
  (`:3093-98`); same for arg/req route sites. Selfhost-only, medium risk (routing
  fragility) — needs @thorough + selfcompile_fixpoint re-baseline. Unblocks set/map builds.
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
- **E1** `double x = x+x`: `paramUseTy` can't anchor a symmetric binop of bare vars (no
  Float literal) → param `LTInt` → int arith → garbage. (`x+1.0` works — literal anchors.)
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
  fixpoint (C3a/C3b) holds byte-for-byte. **E1 remains open.**
- **E3 — CLOSED 2026-06-10 (Fix A).** lambda Float: lambda params were forced `LTInt`
  UNCONDITIONALLY via `allInt` (`:2873`,`:2977`) — `paramUseTy` never consulted → corruption
  even with a body literal. **Fix:** both lambda-define sites (`emitLamDefine`,
  `emitRecLamDefine`) now type params via `inferParamTys (sigTable e) pats body` instead of
  `allInt pats` — the SAME per-param `paramUseTy` inference named-fn params already use.
  Additive: params `paramUseTy` can't resolve still default `LTInt`; captured vars (typed via
  `cenv`/`loadCaptures`) unchanged. Repro `(y => y + 1.0)` 3.0: oracle `4.`, native was garbage
  (`7.54792489297e+168`), now `4.`. Fixture `test/construct_fixtures/lambda_float_param.mdk`.
  Self-compile fixpoint (C3a/C3b) holds. **E1 remains open.**
**Fix plan:** ~~Fix A (E3) thread `paramUseTy` into lambda params (replace `allInt`)~~ DONE;
~~Fix B (E2) recover field types from the ctor's DECLARED field types~~ DONE;
Fix C (E1, OPEN) thread declared signatures into `inferSigs` (emitter shouldn't guess told types).
All emitter-local type-inference fixes; rep untouched; low golden churn (existing Float
fixtures have literal anchors). Needs new fixtures (literal-free/field/lambda Float) + fixpoint.

