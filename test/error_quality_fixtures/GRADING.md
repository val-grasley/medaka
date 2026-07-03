# GRADING — error-quality corpus scored against the rubric

Every one of the 55 fixtures in this directory, scored against the 7-dimension
rubric in `compiler/ERROR-QUALITY.md` §3. Each dimension is **0 / 1 / 2**
(max **14**): **L** Located, **C** Correct, **R** Points-at-root-cause,
**F** Actionable-fix, **J** Jargon-free, **X** Cascade-free, **A** Agent-parseable.

The captured `.out` goldens are the source of truth for the message text (they
are the current binary's output; base `3fc7c947`/main). Scores apply the §3
anchors uniformly; `A` is scored structurally from the documented JSON facts
(no `code`/`kind`/`fix` on any diagnostic → **A ≤ 1** everywhere; warnings carry
a dummy `{0,0}` range and eval/lex/build errors emit no JSON diagnostic → **A = 0**).

Scoring conventions used (for reproducibility):
- **Raw-panic / silent-exit / wrong-error** (no useful positioned diagnostic) caps L=0,C=0 per §3.
- **Silent accept (exit 0, no output)** is treated as an absent diagnostic: L=C=R=F=A=0, with J/X vacuously 2. Three of these (`missing_instance`, `missing_constraint`, `ambiguous_return`) are arguably *by-design* accepts (structural fallback / Num-defaulting) — flagged below and **excluded from the fix hit-list**.
- **Generic `Parse error`** (correct but contentless): C=1, R=1 (true symptom, no expectation named).
- **`A`**: any `check` diagnostic with a real span = 1; lexer-no-loc / eval-runtime / `build` / warnings / silent = 0. No fixture reaches A=2 (no `code`/`kind`/`fix` exists).

---

## 1. Per-fixture scores

| fixture | stage | L | C | R | F | J | X | A | total | rationale |
|---|---|---|---|---|---|---|---|---|---|---|
| unterminated_string | lex | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Correct + clear, but no location/caret, no fix, no JSON |
| unterminated_block_comment | lex | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Same: correct message, no location at all |
| unterminated_char | lex | 1 | 1 | 1 | 0 | 2 | 2 | 1 | 8 | Right line but generic `Parse error`; never names the char literal |
| bad_escape | lex | 0 | 0 | 0 | 0 | 0 | 2 | 0 | 2 | `lexing: empty token` leaks internal state, no loc, doesn't mention the escape |
| if_missing_then | parse | 1 | 1 | 1 | 0 | 2 | 2 | 1 | 8 | Generic `Parse error` at line-start, not the `if` |
| unclosed_paren | parse | 1 | 1 | 1 | 0 | 2 | 2 | 1 | 8 | Generic; points past EOF; no "unclosed (" hint |
| trailing_operator | parse | 1 | 1 | 1 | 0 | 2 | 2 | 1 | 8 | Generic; no operator/column detail |
| reserved_word_binding | parse | 1 | 1 | 1 | 0 | 2 | 2 | 1 | 8 | Generic; doesn't say `match` is a keyword |
| lambda_missing_arrow | parse | 1 | 1 | 0 | 0 | 2 | 1 | 1 | 6 | Misparse → two `Unbound variable: x`; blames a victim, not the missing `=>` |
| missing_comma_list | parse | 1 | 1 | 0 | 0 | 2 | 2 | 1 | 7 | `[1 2 3]` misread as application → `No impl of Num`; nothing at the missing comma |
| else_let_block | parse | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 13 | **Best in corpus**: names the rule and shows the exact fix |
| unbound_variable | resolve | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 11 | Located + caret + clear; only missing a `help`/JSON code |
| typo_println | resolve | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 11 | Clear + located, but no "did you mean `println`?" for the near-miss |
| typo_local_var | resolve | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 11 | Same — no suggestion despite an in-scope near-match |
| unbound_constructor | resolve | 2 | 1 | 2 | 0 | 2 | 2 | 1 | 10 | Says "variable" for a **constructor** (mild mis-framing); no "unknown constructor" |
| unbound_type_in_sig | resolve | 0 | 2 | 2 | 0 | 2 | 1 | 0 | 7 | `<unknown location>`, and the message is emitted **twice** |
| unknown_module | resolve | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Correct + clear, but no location |
| import_unknown_name | resolve | 0 | 0 | 0 | 0 | 0 | 2 | 0 | 2 | **Silent failure**: exit 1 with empty stderr/stdout |
| forgot_import | resolve | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 11 | Clear + located; no "did you forget to import?" hint |
| type_mismatch_int_string | typecheck | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 11 | Clear + located + caret |
| arg_order_swapped | typecheck | 2 | 1 | 1 | 0 | 2 | 1 | 1 | 8 | No "arguments swapped" hint; emits a second `No impl of Num` cascade |
| too_few_args | typecheck | 2 | 1 | 1 | 0 | 2 | 2 | 1 | 9 | Forgotten arg surfaces as `No impl of Num for (Int -> Int)` (symptom) |
| too_many_args | typecheck | 2 | 1 | 1 | 0 | 1 | 1 | 1 | 7 | `Int vs a -> b` (raw tyvar) + `Debug a` ambiguity cascade; no "too many args" |
| float_where_int | typecheck | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 11 | Clear `Int vs Float`, located |
| if_branch_mismatch | typecheck | 2 | 1 | 1 | 0 | 2 | 2 | 1 | 9 | Branch mismatch framed as `No impl of Num for String`, not "branches differ" |
| list_heterogeneous | typecheck | 2 | 1 | 1 | 0 | 2 | 2 | 1 | 9 | Located at the String, but framed as Num failure, not "elements differ" |
| annotation_mismatch | typecheck | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 11 | Clear `Int vs String`, located |
| apply_non_function | typecheck | 2 | 1 | 1 | 0 | 1 | 1 | 1 | 7 | `Int vs a -> b` (symptom + raw tyvar); no "not a function"; Debug cascade |
| cons_type_mismatch | typecheck | 2 | 1 | 1 | 0 | 2 | 2 | 1 | 9 | `1 :: ["a","b"]` framed as Num-for-String, not element/list mismatch |
| return_type_mismatch | typecheck | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 11 | Clear `String vs Int`, located |
| record_missing_field | typecheck | 2 | 2 | 2 | 1 | 2 | 1 | 1 | 11 | Excellent primary (names field + record); a `Debug` cascade follows |
| record_wrong_field | typecheck | 2 | 2 | 2 | 0 | 1 | 1 | 1 | 9 | Names field + record well; no "did you mean `age`?"; `Debug a` cascade |
| missing_instance | typecheck | 0 | 0 | 0 | 0 | 2 | 2 | 0 | 4 | Exit 0, no output — **accepts by design** (structural `==` fallback) |
| missing_constraint | typecheck | 0 | 0 | 0 | 0 | 2 | 2 | 0 | 4 | Exit 0, no output — accepts sig missing `Eq a =>` (arguably a soundness gap) |
| ambiguous_return | typecheck | 0 | 0 | 0 | 0 | 2 | 2 | 0 | 4 | Exit 0, no output — **by design** (defaulting resolves `length []`) |
| tuple_arity_mismatch | typecheck | 2 | 2 | 1 | 0 | 1 | 2 | 1 | 9 | Shows the shapes but leaks raw tyvars `(a, b)`; never says "arity" |
| wrong_arg_type_in_map | typecheck | 2 | 1 | 0 | 0 | 1 | 0 | 1 | 5 | `a b vs String` cryptic; **three-diagnostic storm** (2 ambiguity cascades) |
| bool_where_int | typecheck | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 11 | `5 + True` → `No impl of Num for Bool` is a fair root; located |
| nonexhaustive_option | exhaust | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Correct but no location, doesn't name missing `None`; warning `{0,0}` range |
| nonexhaustive_bool | exhaust | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Same — doesn't name `False` |
| nonexhaustive_list | exhaust | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Same — doesn't say `[]` uncovered |
| nonexhaustive_custom | exhaust | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Same — doesn't name the missing constructor |
| redundant_arm | exhaust | 0 | 0 | 0 | 0 | 2 | 2 | 0 | 4 | **No diagnostic at all** (exit 0) for the unreachable arm |
| io_not_annotated | effect | 2 | 2 | 2 | 1 | 2 | 1 | 1 | 11 | Clear + located; fix implied (annotate `<IO>`); two-diagnostic pair |
| effect_missing_in_row | effect | 2 | 2 | 2 | 1 | 2 | 1 | 1 | 11 | Names both rows; fix implied; two-diagnostic pair |
| pure_fn_does_io | effect | 2 | 2 | 2 | 1 | 2 | 1 | 1 | 11 | Clear + located; fix implied; two-diagnostic pair |
| division_by_zero | eval | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Correct, but no source location |
| modulo_by_zero | eval | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Correct, but no source location |
| list_index_oob | eval | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Names the index; no location, no list length |
| runtime_nonexhaustive | eval | 0 | 2 | 2 | 0 | 2 | 2 | 0 | 8 | Correct-ish; no value / location |
| explicit_panic | eval | 0 | 0 | 0 | 0 | 2 | 2 | 0 | 4 | **False diagnosis**: `unbound identifier: panic` (panic is a valid extern); user's message lost |
| let_else_fail | eval | 0 | 0 | 0 | 0 | 2 | 2 | 0 | 4 | Same `panic`-unbound-at-run bug via idiomatic let-else |
| internal_extern_use | build | 1 | 2 | 2 | 2 | 2 | 2 | 0 | 11 | Clear + actionable (`pass --allow-internal`); loc is placeholder `:1:0` |
| type_error_at_build | build | 0 | 0 | 0 | 0 | 1 | 2 | 0 | 3 | **Wrong error**: `emitter failed / No such file`, not the real type error |
| main_takes_unit | build | 0 | 0 | 0 | 0 | 1 | 2 | 0 | 3 | Same misleading `emitter failed / No such file` for a common `main` shape |

---

## 2. Summary statistics

**Overall average: 440 / 55 = 8.00 / 14.**

### Per-stage average

| stage | fixtures | avg / 14 |
|---|---|---|
| effect | 3 | **11.00** (strongest) |
| resolve | 8 | 8.88 |
| typecheck | 19 | 8.37 |
| parse | 7 | 8.29 |
| exhaust | 5 | 7.20 |
| eval | 6 | 6.67 |
| lex | 4 | 6.50 |
| build | 3 | **5.67** (weakest) |

### Score distribution (total / 14)

| total | count | fixtures |
|---|---|---|
| 2 | 2 | bad_escape, import_unknown_name |
| 3 | 2 | type_error_at_build, main_takes_unit |
| 4 | 6 | missing_instance\*, missing_constraint\*, ambiguous_return\*, redundant_arm, explicit_panic, let_else_fail |
| 5 | 1 | wrong_arg_type_in_map |
| 6 | 1 | lambda_missing_arrow |
| 7 | 4 | missing_comma_list, unbound_type_in_sig, too_many_args, apply_non_function |
| 8 | 17 | (lex/parse generics, eval runtime, exhaust warnings, arg_order_swapped, unknown_module) |
| 9 | 6 | too_few_args, if_branch_mismatch, list_heterogeneous, cons_type_mismatch, record_wrong_field, tuple_arity_mismatch |
| 10 | 1 | unbound_constructor |
| 11 | 14 | (clean typed/resolve/effect + internal_extern_use) |
| 13 | 1 | else_let_block |

**16 of 55 fixtures fall below the 8/14 target floor.** No fixture reaches
**A=2** — the corpus-wide ceiling until `code`/`kind`/`fix` land.

### Per-dimension average — reveals the systematically weakest axes

| dim | sum | avg / 2 | note |
|---|---|---|---|
| **F** Actionable-fix | 8 | **0.15** | **weakest** — no suggestion machinery exists; only `else_let_block`, `internal_extern_use`, effect trio, `record_missing_field` score anything |
| **A** Agent-parseable | 32 | **0.58** | 2nd weakest — no `code`/`kind`/`fix`; capped at 1 for errors, 0 for warnings/eval/lex/build |
| L Located | 58 | 1.05 | lexer/eval/build/exhaust all lack locations |
| R Root-cause | 71 | 1.29 | dragged by Num-mis-framing + build/eval false errors |
| C Correct | 74 | 1.35 | dragged by the same symptom-framing + silent/false diagnostics |
| X Cascade-free | 98 | 1.78 | mostly clean; `debug`-ambiguity cascades on typed errors |
| J Jargon-free | 99 | **1.80** (strongest) | leaks only on raw tyvars (`a`, `a -> b`, `a b`) and `lexing: empty token` |

The doc predicted F and A would be systematically weakest — **confirmed**, with
F the single worst (0.15/2). J and X are already near-target.

---

## 3. Worst offenders (lowest ~12)

| fixture | total | dominant failing dimension(s) |
|---|---|---|
| bad_escape | 2 | L, C, R, A — internal-leak message, no loc, no diagnosis of the escape |
| import_unknown_name | 2 | everything — **silent exit 1**, no message |
| type_error_at_build | 3 | L, C, R — `build` emits the wrong (emitter/file) error |
| main_takes_unit | 3 | L, C, R — same wrong `emitter failed` error |
| explicit_panic | 4 | C, R — **false** `unbound identifier: panic`; L (no loc) |
| let_else_fail | 4 | C, R — same `panic`-at-run bug |
| redundant_arm | 4 | L, C, R, F — **no diagnostic emitted** |
| wrong_arg_type_in_map | 5 | X (3-error storm), R, J (`a b`) |
| lambda_missing_arrow | 6 | R — blames unbound `x`, not the missing `=>` |
| missing_comma_list | 7 | R, C — Num error for a missing comma |
| too_many_args | 7 | R, C, J, X — `Int vs a -> b` symptom + cascade |
| apply_non_function | 7 | R, C, J, X — `Int vs a -> b` symptom + cascade |

(`missing_instance`/`missing_constraint`/`ambiguous_return`, each 4, are
by-design/known-gap *accepts* — see §4, not counted as error-quality defects.)

---

## 4. Prioritized fix hit-list

Themes clustered from the low scores, mapped to concrete fix areas. Lift is the
estimated **total-score gain summed across the affected fixtures** if the theme
is fixed. The orchestrator's four tiers are cross-checked at the end.

### T1 — Functional bugs (wrong / missing / silent error). 5 fixtures, ~+37.

| bug | fixtures | now→target | lift | fix lands in |
|---|---|---|---|---|
| `panic` unbound at `run` (false `unbound identifier: panic`) | explicit_panic, let_else_fail | 4→~10 | **+12** | `compiler/eval/eval.mdk` — bind the `panic` extern in the eval driver so the user's message surfaces |
| `build` skips the type-error guard → `emitter failed / No such file` | type_error_at_build, main_takes_unit | 3→~11 | **+16** | `compiler/driver/build_cmd.mdk` — run the typecheck guard and surface `check`'s diagnostics before invoking the emitter |
| `import list.flatten` silent exit 1 | import_unknown_name | 2→~11 | **+9** | `compiler/driver/loader.mdk` / `compiler/frontend/resolve.mdk` — push a `Diag` for an unknown imported name (mirror `unknown module`) |

These are the deepest holes (totals 2–4) and each is a discrete, high-lift fix.
**Confirms Tier 1 exactly.**

### T2 — Missing content: suggestions, locations, missing-case witness. ~18 fixtures, ~+50.

| theme | fixtures | lift | fix lands in |
|---|---|---|---|
| Nearest-name "did you mean" (edit-distance over in-scope names) | typo_println, typo_local_var, unbound_variable, forgot_import (+ `unbound_constructor` wording "variable"→"constructor") | ~+11 (F 0→2 on 5; C +1) | `compiler/frontend/resolve.mdk` |
| Exhaustiveness: name the missing constructor + attach a location; add a redundant-arm warning | nonexhaustive_option/bool/list/custom, redundant_arm | ~+22 (L 0→2 & F 0→2 on 4; redundant 4→~10) | `compiler/frontend/exhaust.mdk` (witness already computed internally) |
| Attach locations to loc-less diagnostics | lexer trio, eval runtime ×4, unbound_type_in_sig, unknown_module | ~+18 (L 0→2 each) | `compiler/frontend/lexer.mdk`, `compiler/eval/eval.mdk`, `compiler/frontend/resolve.mdk` |
| Rewrite `bad_escape` message (drop `lexing: empty token`, name the escape + loc) | bad_escape | ~+6 | `compiler/frontend/lexer.mdk` |

**Confirms Tier 2.** The exhaustiveness witness is the highest-value single item
here — the checker already knows the missing constructor; only surfacing is missing.

### T3 — Typecheck framing: Num-mis-framing + leaked raw tyvars. ~10 fixtures, ~+16.

| theme | fixtures | lift | fix lands in |
|---|---|---|---|
| Structural mismatch mis-framed as `No impl of Num for X` | too_few_args, if_branch_mismatch, list_heterogeneous, cons_type_mismatch, arg_order_swapped, missing_comma_list | ~+12 (C/R +1–2 each) | `compiler/types/typecheck.mdk` — detect the structural shape (if-branch / list-element / cons / arity) before falling back to the `Num`-constraint message |
| Leaked raw tyvars (`a`, `a -> b`, `a b`, `(a, b)`) reach the user | too_many_args, apply_non_function, wrong_arg_type_in_map, tuple_arity_mismatch | ~+4 (J +1 each) | `compiler/types/typecheck.mdk` type pretty-printer — normalize/name display tyvars; add "too many/few arguments" wording |

**Confirms Tier 3.** Note `bool_where_int` (Bool-not-Num) is a *correct* Num
framing and scores well — the fix must target the structural cases, not all
`No impl of Num`.

### T4 — Structural / machine contract (dims F & A, corpus-wide). All 55, largest aggregate.

| theme | scope | lift | fix lands in |
|---|---|---|---|
| Add stable `code` + `kind` to every `Diag` | all 32 error fixtures at A=1 → A=2 | **~+32** (A +1 each) | `compiler/driver/diagnostics.mdk` (extend `Diag` ADT + JSON) |
| Add `help` / `fix` JSON fields (machine-applicable edit) | pairs with T2 suggestions | folds into T2 F-lift | `compiler/driver/diagnostics.mdk` + producers |
| Fix warning JSON `range` (currently dummy `{0,0}`) | exhaust ×4 (+ any warning) | ~+8 (A 0→up-to-2) | `compiler/driver/diagnostics.mdk` — thread the real `Loc` into the warning `range` |

**Confirms Tier 4** and matches the per-dimension data: **F (0.15) and A (0.58)
are the two weakest axes**, exactly the missing `help`/`fix` and `code`/`kind`
machinery. The `code`+`kind` addition in `diagnostics.mdk` is the single
highest-aggregate-lift change (touches one file, lifts A across the whole corpus).

### Tier cross-check verdict

- **Tier 1 — confirmed** (all three bugs are the corpus's deepest holes; 5 fixtures, ~+37).
- **Tier 2 — confirmed** (did-you-mean, exhaustiveness witness, missing locations, constructor wording).
- **Tier 3 — confirmed**, with one refinement: the Num-mis-framing fix must be **structural-shape-gated** — `bool_where_int` shows a legitimately-correct `No impl of Num` that should be left alone.
- **Tier 4 — confirmed** and is validated by the per-dimension averages: F and A are systematically weakest, and `code`/`kind`/`help`/`fix`/warning-range all land in `compiler/driver/diagnostics.mdk`.

**One data-driven addition to the orchestrator's tiers:** the three exit-0
accepts (`missing_instance`, `missing_constraint`, `ambiguous_return`) are *not*
error-quality defects — `ambiguous_return` (Num-defaulting) and `missing_instance`
(structural `==` fallback) are decided language behavior; only `missing_constraint`
(a signature missing its `Eq a =>` constraint going unrejected) is a genuine
latent soundness gap and belongs on a **typechecker-soundness** backlog, not the
error-quality workstream.
