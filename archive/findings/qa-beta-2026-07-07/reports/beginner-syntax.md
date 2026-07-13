# Beginner-syntax findings (first-hour human-user simulation)

Persona: newcomer from Python/JS/Rust/Haskell typing real first-hour mistakes.
All probes live in `scratchpad/probes/beginner-syntax/`. Binary: `$WT/medaka`
(worktree `virtual-fluttering-meteor`). Every finding reproduced twice.

**Big positive first:** Medaka already has a family of excellent tailored
newbie errors — `def` ("Medaka has no 'def'. Define a function as 'f x = …'"),
`for` loops, `return`→`pure`, `\x -> e`→`x => e`, `::`→`:`, `show`→`debug`,
`true`→`True`, `;` terminators, and the `main () = …` trap now errors loudly
with a great message. The findings below are largely the *gaps* in that family
plus one systemic parse-error-location bug that undermines all of it.

---

## F1: Parse errors inside a declaration body are reported as "unexpected `<decl-name>`" at the declaration HEAD, not at the offending token
- Severity: high
- Class: error-ux
- Launch blocker: yes
- Repro (one of many — see list below):
  ```
  main =
    let type = 5
    println type
  ```
  ```
  $ medaka check reserved_type.mdk
  reserved_type.mdk:1:0: unexpected `main`
    |
  1 | main =
    | ^
  ```
- Expected: an error located at line 2 col 6 (`type`), e.g. "`type` is a
  reserved keyword and cannot be used as a variable name".
- This single failure mode poisons a large fraction of beginner mistakes. All
  of the following produce the identical useless "unexpected `main`/`f` at
  <decl-head>" diagnostic (verified individually):
  - `let x = e in` with body on the **next line** (universal Haskell style; see F4)
  - Python `elif` in a multi-line `if`
  - Python `:` after `if cond` / `else`
  - JS `const x = 5` / `var x = 5` inside a block
  - Rust/Python `x += 1` (no compound assignment)
  - Reserved words as binders: `let type/match/data/import = 5`
  - Rust `match x { ... }` with braces
- If the failing decl is not the first, the error points at that decl's head
  (`second_decl_err.mdk` → `3:0 unexpected \`main\``), so the parser knows
  which decl failed — it just discards the inner failure position.
- Hypothesis: decl-level parser fallback swallows the inner parse error and
  re-reports "unexpected <first token of decl>".

## F2: `"a" + "b"` — `medaka check` rejects it, but `medaka run` executes and dies with an unlocated internal panic
- Severity: high
- Class: run-build-divergence | error-ux
- Launch blocker: yes
- Repro:
  ```
  main = println ("hello " + "world")
  ```
  ```
  $ medaka check str_plus.mdk     # exit 1
  str_plus.mdk:1:16: No impl of Num for String
  $ medaka run str_plus.mdk       # exit 1
  runtime error [E-PANIC]: unknown op '+'
  ```
- Expected: `run` should stop with the same type error `check` prints (it does
  for other type errors, e.g. `Type mismatch: Int vs Option a` — verified).
  Instead the missing-Num-impl error is apparently non-fatal to `run`'s
  typecheck and the interpreter panics with **no file/line** and internal
  jargon ("unknown op '+'"). Same behavior for `1 + "a"` and `True + False`.
  `medaka build` correctly rejects.
- Bonus error-ux gap: `+` on two Strings is the #1 Python/JS habit; the check
  message "No impl of Num for String" never suggests `++` or `"\{x}"`
  interpolation.

## F3: Python-style call `f(1, 2)` yields an opaque tuple-application type error with no hint
- Severity: high
- Class: error-ux
- Launch blocker: yes
- Repro:
  ```
  add x y = x + y
  main = println (add(1, 2))
  ```
  ```
  $ medaka check call_parens_commas.mdk
  call_parens_commas.mdk:2:7: No impl of Display for ((Int, Int) -> (Int, Int))
  ```
  Variant `println add(1, 2)` gives "'println' takes 1 argument(s) but is
  applied to 2." — pointing at println, not the user's real mistake.
- Expected: this is *the* most frequent newcomer move. When a function of
  arity ≥2 is applied to a single tuple whose arity matches, the checker
  should hint: "did you mean `add 1 2`? Function application is
  juxtaposition; `(1, 2)` is a tuple." A partially-applied-function-in-Display
  message is undecipherable to the target user.

## F4: The standard Haskell `let x = e in` + body-on-next-line layout is rejected with zero explanation
- Severity: medium (would be high if not intentional per LAYOUT-SEMANTICS)
- Class: error-ux | doc-mismatch (soft)
- Launch blocker: no
- Repro:
  ```
  main =
    let name = "world" in
    println name
  ```
  ```
  $ medaka check let_in_split.mdk
  let_in_split.mdk:1:0: unexpected `main`
  ```
  One-liner `let name = "world" in println name` works; block-style `let` with
  no `in` also works.
- Expected: LAYOUT-SEMANTICS says own-line-`in` rejection is intentional, but
  a Haskeller hits this in minute one and gets F1's useless message. Needs a
  targeted diagnostic: "`in` cannot end a line / lead a line — put the body on
  the same line, or drop `in` and use block-let."

## F5: `#` and `//` comments get raw "unexpected character" errors with no pointer to `--`
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  # this is a comment
  main = println "hi"
  ```
  ```
  $ medaka check py_hash_comment.mdk
  py_hash_comment.mdk:1:0: unexpected character '#'
  ```
  Likewise `// a comment` → `1:0: unexpected `/``.
- Expected: "Comments are written `-- …` (or `{- … -}`)". `#` at column 0 of
  line 1 and `//` at line start are unambiguous comment attempts. This is the
  cheapest possible win given the `def`/`for` hint machinery already exists.

## F6: Missing tailored hints for `elif`, Python `lambda`, and `and`/`or` (family gaps)
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro (three separate probes):
  - `f x = if x > 0 then "pos" elif x < 0 then "neg" else "zero"` →
    `1:37: unexpected \`then\`` (points at the *second* `then`, not `elif`;
    no "use `else if`" — which works, verified).
  - `main = println (map (lambda x: x + 1) [1, 2, 3])` →
    `1:15: unexpected \`(\`` — points at the paren before `map`, wrong token,
    no hint. Contrast: `\x -> x` gets a perfect tailored message.
  - `f x = x > 0 and x < 10` → cascade of 3 misleading type errors ("No impl
    of Ord for Bool", "Type mismatch: Int literal vs Bool", "No impl of Num
    for ((Bool -> Bool -> Bool) -> a -> a)") because `and` parses as
    application. No "use `&&`/`||`" hint. (`not` actually works — it's a
    prelude function.)
- Expected: same treatment `def`/`for`/`return`/`\`/`::`/`show` already get.

## F7: Redefining a prelude type reports "Duplicate type" with NO location and no mention of the prelude
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  data Option a = None | Some a
  main = println (Some 1)
  ```
  ```
  $ medaka check hs_redefine_option.mdk
  <unknown location>: Duplicate type: Option
  <unknown location>: Duplicate constructor: None
  <unknown location>: Duplicate constructor: Some
  ```
  JSON range is the `{0,0}` dummy (`R-DUPLICATE-DEF`).
- Expected: located at the `data` decl, and worded "collides with the prelude
  type `Option`" — "Duplicate" implies the user defined it twice, which they
  didn't. (Defining `data Maybe a = Nothing | Just a` works fine — positive.)

## F8: Mixed tabs+spaces silently mis-nest layout, surfacing as unrelated type errors
- Severity: medium
- Class: error-ux | silent-wrong
- Launch blocker: no
- Repro (file uses 2 spaces on line 2, TAB+space on line 3):
  ```
  main =
    println "a"
  <TAB> println "b"
  ```
  ```
  $ medaka check tabs_mixed.mdk
  tabs_mixed.mdk:3:2: 'println' takes 1 argument(s) but is applied to 2.
  tabs_mixed.mdk:3:2: Ambiguous instance for `Display`. ...
  ```
- Expected: a lexer diagnostic about inconsistent tab/space indentation (or a
  defined tab-width rule). Currently the tab line is silently treated as a
  continuation, producing type errors about println's arity. (All-tab
  indentation works consistently — fine.)

## F9: `medaka run nonexistent.mdk` says "unknown module: nonexistent"
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  $ medaka run nope.mdk
  unknown module: nope
  ```
- Expected: "file not found: nope.mdk". "unknown module" is loader-internal
  vocabulary; the very first command a user runs with a typo'd path should
  speak in files.

## F10: UTF-8 BOM at file start → "unexpected character '<invisible>'"
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro: `printf '\xef\xbb\xbfmain = println "hi"' > bom2.mdk`
  ```
  $ medaka check bom2.mdk
  bom2.mdk:1:0: unexpected character '﻿'      <- that quoted char is U+FEFF, invisible
  ```
- Expected: skip a leading BOM (what most tools do), or say "byte-order mark
  (BOM) at start of file — save the file without a BOM". As shipped, the user
  sees an error quoting a character they cannot see, on a line that looks
  identical to a working file. Windows-editor users will hit this. (CRLF line
  endings work fine — positive.)

## F11: `xs[0]` indexing parses as application; error blames `println`, never suggests `xs.[0]`
- Severity: medium
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  main =
    let xs = [1, 2, 3]
    println xs[0]
  ```
  ```
  $ medaka check index_list.mdk
  index_list.mdk:3:13: 'println' takes 1 argument(s) but is applied to 2.
  ```
  Parenthesized `println (xs[0])` still type-errors (application of a List to
  a List) with no hint.
- Expected: indexing is `xs.[0]` (SYNTAX.md). A `expr[expr]` juxtaposition
  where the head is not a function is a high-confidence "did you mean
  `xs.[0]`" site for JS/Python users.

## F12: JS method-call `xs.map f` → "Field 'map' does not belong to record '<unknown>'"
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  main =
    let xs = [1, 2, 3]
    println (xs.map (x => x + 1))
  ```
  ```
  $ medaka check js_method.mdk
  js_method.mdk:3:11: Field 'map' does not belong to record '<unknown>'
  ```
- Expected: no `<unknown>` placeholder leaking; ideally "Medaka has no method
  call syntax — write `map f xs` (or `xs |> map f`)".

## F13: No "did you mean" for the classic cross-language names: `len`, `null`, `console`
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: `println (len [1,2,3])` → "Unbound variable: len" (no `length`
  suggestion — presumably outside the edit-distance window); `println null` →
  "Unbound variable: null" (no `None` hint); `console.log "hi"` → "Unbound
  variable: console" (no `println` hint).
- Expected: these three (plus `nil`, `printf`) deserve hardcoded hints in the
  same table as `show`/`return`/`true` (which all have great hints — verified).

## F14: `===` and `println!` errors are located but hint-free
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro: `f x = x === 5` → `1:8: unexpected \`==\`` (no "Medaka uses `==`");
  `main = println!("hi")` → `1:14: unexpected \`!\`` (no "no `!` — `println`
  is a normal function"; note `!` is Medaka's unary not, making this genuinely
  confusable).
- Expected: one-line hints; locations are already correct.

## F15: Capitalized function definition `Double x = …` → bare "unexpected `Double`"
- Severity: low
- Class: error-ux
- Launch blocker: no
- Repro:
  ```
  Double x = x + x
  main = println (Double 2)
  ```
  ```
  $ medaka check upper_fn.mdk
  upper_fn.mdk:1:0: unexpected `Double`
  ```
- Expected: "function and value names must start lowercase; capitalized names
  are constructors/types". Location is right; the rule is never named.

## F16: JS template literal `${x}` inside a string is silently inert
- Severity: low
- Class: silent-wrong (footgun, arguably WAI)
- Launch blocker: no
- Repro:
  ```
  main = println "hello ${name}"
  ```
  ```
  $ medaka run template_only.mdk
  hello ${name}
  ```
- Expected: works as literal text by design (interpolation is `\{}`), but a JS
  user gets no signal at all — even with `name` unbound it runs. A lint
  ("string contains `${…}` — Medaka interpolation is `\{…}`") would catch it.
  Same applies to Python `f"{x}"` — though that one at least parse-errors
  (via F1, unhelpfully).

## F17: Non-ASCII identifiers rejected without naming the rule
- Severity: low
- Class: error-ux | missing-feature
- Launch blocker: no
- Repro: `café = 42` → `1:3: unexpected character 'é'`; `π = 3.14159` →
  `1:0: unexpected character 'π'`.
- Expected: at minimum "identifiers are ASCII (a-z, A-Z, 0-9, _)". ASCII-only
  is a defensible choice; the unexplained mid-identifier split location
  (`caf` parsed, then 'é' rejected) reads like a compiler bug to a user.

---

## Positive surprises worth regression fixtures (worked, possibly uncovered)

- `print("hi")` and single-arg `f(x)` calls work (parens around one arg are
  just grouping) — happy accident that softens the Python landing.
- **JS arrow lambdas `x => x + 1` are literally Medaka syntax** — `map (x => x + 1) [1,2,3]` works.
- `putStrLn` and `print` both exist alongside `println` (Haskell/Python landing).
- `not x` is a prelude function (Python's `not` just works).
- `x == None` works (`None` is the Option constructor).
- `else if` chains work (the `elif` fix exists; F6 asks the error to say so).
- Haskell-style `where` blocks (both placements) work.
- `data Maybe a = Nothing | Just a` (user-defined Haskell vocabulary) works.
- Nested block comments `{- outer {- inner -} -}` work.
- `f -1` parses as `f (-1)` (application to a negative literal), NOT `f - 1`
  — friendlier than Haskell; worth pinning with a fixture so it never flips.
- CRLF line endings, all-tab indentation, trailing whitespace, 2000-term
  lines: all fine.
- Empty file / comment-only file / missing `main`: clean `E-NO-MAIN` runtime
  error with a stable code.
- `main() = …` (no space) now errors loudly with an excellent message (the
  historical silent no-op appears fixed — worth a fixture).

## Suggested regression fixtures

1. `run_vs_check_num_string.mdk` — `"a" + "b"`: assert `run` and `check` both
   fail with the SAME located type error (F2).
2. `parse_error_location.mdk` — `let type = 5` inside `main`: assert the
   diagnostic range is on line 2 at `type`, not decl head (F1).
3. `tuple_call_hint.mdk` — `add(1, 2)`: assert hint text once F3 ships.
4. `bom_start.mdk` — BOM-prefixed hello-world: assert it compiles (or the BOM
   is named in the error) (F10).
5. `mixed_tabs.mdk` — tab/space mix: assert a layout diagnostic, not an arity
   type error (F8).
6. `prelude_type_collision.mdk` — `data Option…`: assert located,
   prelude-naming diagnostic (F7).
7. Positive pins: `arrow_lambda.mdk` (`x => x+1` in map), `neg_literal_app.mdk`
   (`f -1` ≡ `f (-1)`), `nested_block_comment.mdk`, `crlf_hello.mdk`,
   `else_if_chain.mdk`, `print_parens_single_arg.mdk`, `putstrln_alias.mdk`,
   `main_nospace_error.mdk` (loud `main () =` error), `where_both_forms.mdk`.
8. Hint-table pins for the EXISTING great errors (`def`, `for`, `return`,
   `\x ->`, `::`, `show`, `true`, `;`) so wording/location never regress.
