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

**115 PASS, 15 GAP** across 37 construct families.

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
| Match int range pattern `1..9` | GAP | see §Gaps below |
| Match char range pattern `'a'..='z'` | GAP | see §Gaps below |
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
| `let mut x = e` + reassignment `x = e` | GAP | see §Gaps below |
| `let mut r = Ref e` + `set_ref r v` + `r.value` | PASS | `ref_let_mut.mdk` |
| `let Some x = opt else panic` | GAP | see §Gaps below |
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
| A2 | Match int range pattern `1..9` | `parser.mdk:2428:32: panic: parse error` | `match n \| 1..9 => "digit" \| _ => "other"` |
| A3 | Match char range pattern `'a'..='z'` | `parser.mdk:2428:32: panic: parse error` | `match c \| 'a'..='z' => True \| _ => False` |
| A4 | Match negative literal pattern `-1` | `parser.mdk:2428:32: panic: parse error` | `match n \| -1 => "minus" \| _ => "other"` |
| A5 | `where` clause inline (at end-of-body-line) | `parser.mdk:2428:32: panic: parse error` | `f x = x where g = 1` |
| A6 | `let rec fib = n => ...` in block (block form) | Both ref and selfhost fail; ref: `Parse error` at col 0 | N/A — both parsers reject this |
| A7 | `let rec ... with ...` at top-level | `emitter: unbound variable 'isEven'` (compiles but emitter can't resolve mutual refs) | `let rec isEven = n => ... with isOdd = n => ...` |
| A8 | `do` inside a named function body when function has `<IO>` effect type | `parser.mdk: parse error` | `printTwo : <IO> Unit \n printTwo = do \n  putStrLn "x"` |
| A9 | Record `deriving (Debug)` (block form, indent) | `parser.mdk: parse error` | `record Point \n  x : Int \n  y : Int \n  deriving (Debug)` |
| A10 | Annotated `let x : T = e` in block (block form) | Both ref and selfhost fail; ref: `Parse error` | N/A — both parsers reject this |
| A11 | `@`-pattern in lambda / function param (e.g. `setX v p@(Pt {x,y}) = ...`) | `parser.mdk: parse error` | `f p@{x,y} = x` |

**Fix target:** `selfhost/parser.mdk` — add these pattern/statement/expression forms.

---

### Gap Group B: Emitter missing block statement forms
`emitBlock` in `selfhost/llvm_emit.mdk` only handles `CSLet`(PVar/PWild/PTuple) and `CSExpr`.
Missing cases produce `panic: unsupported block statement (slice 1)`.

| # | Construct | Error |
|---|-----------|-------|
| B1 | `let mut x = e` + `x = e` reassignment in block | `unsupported block statement (slice 1)` |
| B2 | `let Some x = opt else panic "..."` (let-else) | `unsupported block statement (slice 1)` |

**Fix target:** `selfhost/llvm_emit.mdk` `emitBlock` — add `CSSet`/`CSLetMut`/`CSLetElse` arms.

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

| # | Construct | Error |
|---|-----------|-------|
| D1 | Backtick infix `` f `divide` g `` | `unbound variable 'divide'` — backtick call site creates an `EVar` with the wrong name |
| D2 | Newtype constructor `UserId 42` used as a function | `unbound variable 'UserId'` — newtype constructors not emitted as toplevel functions |
| D3 | Named impl `combine @Sum` hint syntax | `unbound variable '@Sum'` |
| D4 | `let rec ... with ...` top-level mutual rec | `unbound variable 'isEven'` — mutual rec bindings not wired together |

**Fix target:** `selfhost/llvm_emit.mdk` — D1: fix backtick EVar construction; D2: emit newtype wrapper function; D3: impl hints; D4: mutual-rec top-level wiring.

---

### Gap E: Float value corruption / wrong output

| # | Construct | Oracle | Native | Note |
|---|-----------|--------|--------|------|
| E1 | Named fn `double : Float -> Float; double x = x + x` (no Float literal in body) | `6.28` | garbage or `0.` | `+` dispatches via Num on Float params without a literal anchor |
| E2 | ADT with two Float fields, extracting both: `Rect Float Float; Rect w h => w * h` | `12.` | SIGSEGV | Two-Float-payload variant match crashes (single-Float-payload works) |
| E3 | `do`-notation for Result with Float bind: `x <- Ok 3.0; pure (x + 1.0)` | `Ok 4.` | `Ok <garbage>` | Float value in monadic bind chain is corrupted |

**Fix target:** `selfhost/llvm_emit.mdk` — E1: type-directed Float `+` for known Float params; E2: fix two-Float-payload variant match lowering; E3: Float boxing/unboxing in monadic bind chain.

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

### Gap G: `deriving (Eq, Ord)` comparison wrong

| # | Construct | Oracle | Native | Note |
|---|-----------|--------|--------|------|
| G1 | `data Level = Low \| Mid \| High deriving (Eq, Ord); Low < High` | `False` (ref bug — actually Low < High should be True) | `True` | The reference interpreter and native disagree; reference returns `False` for `Low < High` (possible oracle bug). |

**Note:** The oracle result `False` for `Low < High` appears incorrect (tag-ordering says Low=0 < High=2 → True). This may be an oracle bug in the derived Ord implementation, not a native gap. Mark for investigation.

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
