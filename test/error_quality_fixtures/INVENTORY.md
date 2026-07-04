# INVENTORY — error-quality corpus baseline

One row per fixture. **Message** is a 1-line excerpt of the current stderr (or
stdout warning) captured in the `.out` golden. **Observation** is a *neutral*
note about the message as-is — NOT a grade. Captured against `./medaka` built
from this branch (base `359c870a`). Exit code in parentheses after the stage.

> ⚠️ See "**Notable / plausible-input problems**" and "**Crashes on plausible
> input**" at the bottom before reading the table.

## lex/ (`medaka check`)

| Fixture | Intended mistake | Message (excerpt) | Observation |
|---|---|---|---|
| `unterminated_string` (1) | forgot closing `"` | `Unterminated string literal` | Clear; **no location/caret** |
| `unterminated_char` (1) | wrote `'a` not `'a'` | `…:2:15: Parse error` | Has location but generic "Parse error"; doesn't name the char literal |
| `unterminated_block_comment` (1) | `{-` never closed | `Unterminated block comment` | Clear; **no location** |
| `bad_escape` (1) | `"\q"` invalid escape | `lexing: empty token` | **Cryptic**: leaks internal "empty token"; no location; doesn't mention the escape |

## parse/ (`medaka check`)

| Fixture | Intended mistake | Message (excerpt) | Observation |
|---|---|---|---|
| `if_missing_then` | `if` with no `then` | `…:2:0: Parse error` | Generic; location points at line start, not the `if` |
| `unclosed_paren` | missing `)` | `…:2:15: Parse error` | Generic; no "unclosed (" hint; points past EOF |
| `trailing_operator` | line ends with `+` | `…:2:0: Parse error` | Generic; no operator/column detail |
| `lambda_missing_arrow` | `inc = x x + 1` (meant `x =>`) | `…:1:6: Unbound variable: x` | **Misleading**: parses as application `x x`, reported as resolve error, not "missing `=>`" |
| `else_let_block` | `else let x = …` newline body | `inline 'let' requires 'in' (e.g. 'else let x = e in body'); …` | **Excellent**: names the rule and shows the fix |
| `missing_comma_list` | `[1 2 3]` | `…:1:23: No impl of Num for (Int -> Int -> Int)` | **Very misleading**: parses `1 2 3` as application, surfaces a Num type error for a missing comma |
| `reserved_word_binding` | `match = 5` | `…:2:0: Parse error` | Generic; doesn't say "match is a keyword" |

## resolve/ (`medaka check`)

| Fixture | Intended mistake | Message (excerpt) | Observation |
|---|---|---|---|
| `unbound_variable` | undefined `total` | `…:1:23: Unbound variable: total` | Clear, located, caret |
| `typo_println` | `printline` for `println` | `…:1:7: Unbound variable: printline` | Clear but **no "did you mean" suggestion** for near-miss typo |
| `typo_local_var` | `cont` for `count` | `…:3:18: Unbound variable: cont` | Same — no suggestion despite an in-scope near-match |
| `unbound_constructor` | `Yellow` not a variant | `…:2:22: Unbound variable: Yellow` | Says "variable" for a **constructor**; no "unknown constructor" wording |
| `unbound_type_in_sig` | `Strng` in a signature | `<unknown location>: Unknown type: Strng` | **No location** ("<unknown location>"); message otherwise clear |
| `unknown_module` | `import collections.HashMap` | `unknown module: collections` | Reasonable; **no location** |
| `import_unknown_name` | `import list.flatten` (no such name) | *(no output)* | ⚠️ **Silent failure**: exit 1 with **empty stderr and stdout** |
| `forgot_import` | used `fromList` w/o import | `…:1:23: Unbound variable: fromList` | Clear, but no "did you forget to import?" hint |

## typecheck/ (`medaka check`)

**Updated (2026-07-04, base `295f263b`):** 6 fixtures below were reframed by
the Batch-B actionable-fix work — see `GRADING.md`'s "post-Batch-B" section
for the full re-score. Rows updated: `apply_non_function`,
`if_branch_mismatch`, `list_heterogeneous`, `cons_type_mismatch`,
`wrong_arg_type_in_map` (help-only hint appended / reframed), and
`arg_order_swapped` (collapsed to one diagnostic + a real machine `fix`).

| Fixture | Intended mistake | Message (excerpt) | Observation |
|---|---|---|---|
| `type_mismatch_int_string` | pass String to Int fn | `…:3:34: Type mismatch: Int vs String` | Clear, located, caret |
| `arg_order_swapped` | swapped args | `…:3:22: arguments to 'greet' look swapped — try 'greet "Alice" 3'.` | **Fixed**: one diagnostic (was two), names the swap, and `--json` carries a real machine `fix` performing the transposition |
| `too_few_args` | `add 1 + 10` (forgot arg) | `…:3:31: No impl of Num for (Int -> Int)` | **Cryptic**: the "forgot an arg" is reported as a Num-instance failure on a function type |
| `too_many_args` | `inc 1 2` | `…:3:29: 'inc' takes 1 argument(s) but is applied to 2.` | Reframed (Tier-3): names the actual counts, no raw tyvar |
| `float_where_int` | `factorial 3.5` | `…:3:33: Type mismatch: Int vs Float` | Clear |
| `if_branch_mismatch` | `then "pos" else 0` | `…:2:38: if branches have different types: Int vs String — both branches must have the same type; change the else branch to Int, or the then branch to String.` | Reframed (Tier-3) + help hint appended this session: names the actual structural shape and offers two concrete directions |
| `list_heterogeneous` | `[1,2,"three",4]` | `…:1:38: list elements have different types: Int vs String — all elements must have the same type; convert the String element, or make the list hold String.` | Reframed + help hint: names the structural shape, offers two concrete directions |
| `annotation_mismatch` | `x : Int = "…"` | `…:2:15: Type mismatch: Int vs String` | Clear |
| `apply_non_function` | call an Int | `…:3:20: This expression has type Int, which is not a function, so it cannot be applied to an argument. — 'n' is a value, not a function; remove the argument, or call a function here.` | Reframed (Tier-3) + help hint appended this session: no more raw `a -> b`, names the "not a function" fact and a concrete direction |
| `cons_type_mismatch` | `1 :: ["a","b"]` | `…:1:23: cons (::) type mismatch: head is Int but the list holds String — the head's type must match the list's elements; change the head to String, or use a list of Int.` | Reframed + help hint: names the operator and which side (head vs list) is wrong |
| `return_type_mismatch` | body String, sig Int | `…:2:15: Type mismatch: String vs Int` | Clear |
| `record_missing_field` | omit `age` | `…:4:23: Missing field age in construction of record Person` | **Excellent**: names field + record |
| `record_wrong_field` | `p.aeg` typo | `…:6:17: Field aeg does not belong to record Person` | **Excellent**: names field + record; no suggestion |
| `missing_instance` | `Red == Green`, no `deriving Eq` | *(no output)* | ⚠️ **Accepts it** (exit 0): `==` works with no declared instance (structural fallback) |
| `missing_constraint` | body uses `==`, sig lacks `Eq a =>` | *(no output)* | ⚠️ **Accepts it** (exit 0): signature missing the constraint is not rejected |
| `ambiguous_return` | `length []` | *(no output)* | Accepts (exit 0): defaulting resolves it; not actually ambiguous here |
| `tuple_arity_mismatch` | pass 2-tuple to 3-tuple fn | `…:3:32: Type mismatch: (Int, Int, Int) vs (a, b)` | Clear-ish; shows the shapes |
| `wrong_arg_type_in_map` | `map f "hello"` | `…:1:46: 'map' expects a container (like List or Array) here, but got String — pass a List or Array; to work over a string's characters, convert it with \`string.toChars\` first.` | **Fixed**: no more raw `a b` tyvar leak; names `map`'s actual expectation and offers two concrete directions |
| `bool_where_int` | `5 + True` | `…:1:27: No impl of Num for Bool` | Reasonable; Num-instance framing |

## exhaust/ (`medaka check`)

| Fixture | Intended mistake | Message (excerpt) | Observation |
|---|---|---|---|
| `nonexhaustive_option` | match only `Some` | `Warning: non-exhaustive match — some values may not be covered` | ⚠️ **Warning only, exit 0, on stdout**; **doesn't name the missing pattern** (`None`) or a location |
| `nonexhaustive_bool` | match only `True` | *(same warning)* | Same — no missing case named |
| `nonexhaustive_list` | match only `x::rest` | *(same warning)* | Same — doesn't say `[]` uncovered |
| `nonexhaustive_custom` | miss `Triangle` | *(same warning)* | Same — doesn't name the missing constructor |
| `redundant_arm` | wildcard before literal | *(no output)* | ⚠️ **No redundancy/unreachable-arm warning at all** (exit 0) |

## effect/ (`medaka check`)

| Fixture | Intended mistake | Message (excerpt) | Observation |
|---|---|---|---|
| `io_not_annotated` | `<IO>` missing from sig | `…:2:20: Effectful value used where <> is allowed, but it performs <IO>` | Clear and located; good |
| `effect_missing_in_row` | `<Stdout>` but does `<IO>` | `…:2:21: Effectful value used where <Stdout> is allowed, but it performs <IO>` | Clear; names both rows |
| `pure_fn_does_io` | println in a pure fn | `…:4:6: Effectful value used where <> is allowed, but it performs <IO>` | Clear |

## eval/ (`medaka run`)

**Updated (2026-07-04, base `37e7ab0d1`):** `medaka run` runtime errors are now
**located + coded**: `file:L:C: runtime error [E-*]: <message>`, and
`medaka run --json` emits the same envelope as `check --json`
(`code`/`kind`/`range`/`message`/`severity`/`source`, no `fix`). All 6 rows
below reflect the new output; the `panic`-unbound-at-`run` bug noted
previously is long fixed (the user's own panic message now surfaces as
`[E-PANIC]`).

| Fixture | Intended mistake | Message (excerpt) | Observation |
|---|---|---|---|
| `division_by_zero` | `10 / 0` | `:3:23: runtime error [E-DIV-ZERO]: division by zero` | Located (caret on the zero divisor); JSON has `code`/`kind`/`range`, no `fix` |
| `modulo_by_zero` | `17 % 0` | `:3:23: runtime error [E-MOD-ZERO]: modulo by zero` | Located (caret on the zero modulus); JSON same shape, no `fix` |
| `list_index_oob` | `xs.[10]` | `:3:22: runtime error [E-INDEX-OOB]: index 10 out of bounds` | Located (caret on the `10` index literal); no list length in message; JSON no `fix` |
| `runtime_nonexhaustive` | match with no arm | `:1:29: runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match` | Located (caret on the scrutinee); no missing-arm value named; JSON no `fix` |
| `explicit_panic` | `panic "user not found"` | `:2:37: runtime error [E-PANIC]: user not found` | Located (caret on the panic message literal); user's message correctly surfaces; JSON no `fix` |
| `let_else_fail` | let-else with `panic` else | `:3:42: runtime error [E-PANIC]: empty list` | Located (caret on the panic message literal) via idiomatic let-else; JSON no `fix` |

## build/ (`medaka build`)

| Fixture | Intended mistake | Message (excerpt) | Observation |
|---|---|---|---|
| `internal_extern_use` | `arrayGetUnsafe` outside stdlib | `'arrayGetUnsafe' is an internal-only primitive … (pass --allow-internal to override)` | Clear + actionable; **location is `:1:0`** (line 0), not the use site |
| `type_error_at_build` | `"x" + 1` | `error: emitter failed compiling … / No such file or directory` | ⚠️ **build does not surface the type error** `check` gives ("No impl of Num for String"); confusing emitter/file error instead |
| `main_takes_unit` | `main () = …` | `error: emitter failed compiling … / No such file or directory` | ⚠️ Confusing "emitter failed / No such file" for a common `main` shape (silent no-op under `run`) |

---

## Notable / plausible-input problems (top observations)

1. **`build/type_error_at_build`** — a plain type error (`"x" + 1`) under
   `medaka build` prints `emitter failed compiling … / No such file or
   directory` instead of the clean `No impl of Num for String` that `check`
   produces. `build` appears to skip the type-error guard and fail downstream.
2. ~~**`eval/explicit_panic` + `eval/let_else_fail`** — `panic` unbound at
   `run`~~ — **fixed**: both now report `[E-PANIC]: <the user's own message>`,
   located at the panic-message literal.
3. **`resolve/import_unknown_name`** — `import list.flatten` (name doesn't
   exist) exits 1 with **completely empty output** — a silent failure.
4. **`parse/missing_comma_list`** — `[1 2 3]` is parsed as function application
   and reported as `No impl of Num for (Int -> Int -> Int)`; nothing points at
   the missing comma.
5. **`exhaust/*`** — non-exhaustive match is a **stdout warning with exit 0**
   that never **names the missing pattern** or a source location; a real user
   easily misses it. `redundant_arm` produces **no diagnostic at all**.
6. **`typecheck` Num-framing** — ~~several structural mistakes (heterogeneous
   list, cons mismatch, if-branch mismatch, forgotten argument) surface as
   `No impl of Num for …` rather than describing the actual shape problem~~ —
   **fixed for `if_branch_mismatch`/`list_heterogeneous`/`cons_type_mismatch`/
   `too_many_args`/`apply_non_function`** (Tier-3 reframe, plus a help-only
   fix hint appended 2026-07-04 to the first four); `too_few_args` still
   surfaces as `No impl of Num for (Int -> Int)` — not yet reframed.
7. **`lex/bad_escape`** — an invalid string escape yields `lexing: empty token`,
   leaking an internal lexer state name with no location.
8. **Missing "did-you-mean"** — resolve typos (`printline`, `cont`) get no
   suggestion despite near matches in scope; several diagnostics
   (`unbound_type_in_sig`, lexer errors) still carry **no source location**
   (runtime/`eval` errors were fixed 2026-07-04 — see the `eval/` section
   above).

## ⚠️ Crashes on plausible input

**None found.** No fixture produced a segfault, uncaught host-language
exception, or assertion failure. The closest to a hard fault is the
`build/*` "emitter failed compiling … / No such file or directory" pair
(problem #1/#2 above) — these are misleading/degraded diagnostics, not crashes.
