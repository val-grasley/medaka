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

---

## Re-grade (post-fixes, base d2442e6b)

Re-scored against the same §3 rubric, same 0/1/2 anchors, same scoring
conventions (so the delta is meaningful). The current `.out` goldens are the
source of truth; the six highest-impact flips were re-verified on a freshly
built binary. **Corpus size grew from 55 → 60** (five new `typecheck/` fixtures
this session: `missing_constraint_twohop`, `eq_on_function`, `eq_undesugared_adt`,
`lt_on_function`, `lt_undesugared_adt`).

### Headline

- **Overall average: 541 / 60 = 9.02 / 14** — **up from 8.00 (+1.02).**
- **F (Actionable-fix): 0.15 → 0.33** (sum 8 → 20). Still the weakest axis; the
  did-you-mean + missing-constraint + missing-case machinery moved it, but most
  of the corpus still has no `fix`.
- **A (Agent-parseable): 0.58 → 0.65** (sum 32 → 39) — moved *only* because five
  new located `check` diagnostics landed at A=1 and two silent-accepts flipped to
  A=1. **No fixture reaches A=2**: no `code`/`kind`/`fix` exists yet (Tier 4
  un-started), so A stays capped at 1 for errors and 0 for warnings/eval/lex/build.
- **17 fixtures improved** (12 pre-existing + all 5 new scored above the 8.00
  baseline floor), for an aggregate **+45** on the pre-existing set and **+56**
  from the new fixtures. **No regressions.**

### Per-dimension averages (60 fixtures)

| dim | baseline sum | baseline avg | new sum | new avg /2 | Δ |
|---|---|---|---|---|---|
| **F** Actionable-fix | 8 | 0.15 | 20 | **0.33** | +0.18 |
| **A** Agent-parseable | 32 | 0.58 | 39 | **0.65** | +0.07 |
| L Located | 58 | 1.05 | 74 | 1.23 | +0.18 |
| C Correct | 74 | 1.35 | 96 | 1.60 | +0.25 |
| R Root-cause | 71 | 1.29 | 93 | 1.55 | +0.26 |
| X Cascade-free | 98 | 1.78 | 107 | 1.78 | +0.00 |
| J Jargon-free | 99 | 1.80 | 112 | 1.87 | +0.07 |

C and R moved most (the silent/false/wrong-error holes became correct located
diagnostics). F moved from a near-zero base but remains the single weakest axis.

### Per-stage averages

| stage | fixtures | baseline avg | new avg | Δ |
|---|---|---|---|---|
| effect | 3 | 11.00 | 11.00 | — |
| resolve | 8 | 8.88 | **10.13** | +1.25 |
| typecheck | 24 (was 19) | 8.37 | **9.63** | +1.26 |
| parse | 7 | 8.29 | 8.29 | — |
| build | 3 | 5.67 | **8.00** | +2.33 |
| eval | 6 | 6.67 | **8.00** | +1.33 |
| exhaust | 5 | 7.20 | **8.00** | +0.80 |
| lex | 4 | 6.50 | 6.50 | — |

Every baseline low point (build 5.67, eval 6.67, exhaust 7.20) rose to exactly
8.00; lex (6.50) is the only stage untouched this session and is now the weakest.

### Per-fixture delta table (changed fixtures only)

Fixtures not listed here are unchanged from §1 and keep their baseline score.

| fixture | stage | old→new | dims that moved | why |
|---|---|---|---|---|
| missing_constraint | typecheck | 4 → **13** | L 0→2, C 0→2, R 0→2, F 0→2, A 0→1 | was a silent exit-0 accept; now a located diagnostic that **names the exact fix** ("add 'Eq a =>'"), else_let_block-tier |
| missing_instance | typecheck | 4 → **11** | L 0→2, C 0→2, R 0→2, A 0→1 | silent accept → located `No impl of Eq for Color` |
| type_error_at_build | build | 3 → **10** | L 0→2, C 0→2, R 0→2, J 1→2 | `build` now surfaces the real located type error instead of `emitter failed / No such file` (A stays 0 — build emits no JSON, per convention) |
| import_unknown_name | resolve | 2 → **8** | C 0→2, R 0→2, J 0→2 | silent exit 1 → real message (`module 'list' has no exported name 'flatten'`); still `<unknown location>` so L stays 0 |
| explicit_panic | eval | 4 → **8** | C 0→2, R 0→2 | false `unbound identifier: panic` → the user's message (`user not found`); still no location (L 0) |
| let_else_fail | eval | 4 → **8** | C 0→2, R 0→2 | same panic fix via let-else (`empty list`) |
| typo_println | resolve | 11 → **13** | F 0→2 | now `— did you mean 'println'?` |
| typo_local_var | resolve | 11 → **13** | F 0→2 | now `— did you mean 'count'?` |
| nonexhaustive_option | exhaust | 8 → **9** | F 0→1 | now names the missing case `'None'` |
| nonexhaustive_bool | exhaust | 8 → **9** | F 0→1 | names `'False'` |
| nonexhaustive_list | exhaust | 8 → **9** | F 0→1 | names `'[]'` |
| nonexhaustive_custom | exhaust | 8 → **9** | F 0→1 | names `'Triangle _'` |

New fixtures (no baseline; scored fresh):

| fixture | stage | L | C | R | F | J | X | A | total | note |
|---|---|---|---|---|---|---|---|---|---|---|
| missing_constraint_twohop | typecheck | 2 | 2 | 2 | 2 | 2 | 1 | 1 | **12** | names the fix ("add 'Greet a =>'"); a second `No impl of Greet` follows at the call site (X=1) |
| eq_on_function | typecheck | 2 | 2 | 2 | 0 | 2 | 2 | 1 | **11** | clean located `No impl of Eq for (Int -> Int)` |
| eq_undesugared_adt | typecheck | 2 | 2 | 2 | 0 | 2 | 2 | 1 | **11** | located `No impl of Eq for Color` |
| lt_on_function | typecheck | 2 | 2 | 2 | 0 | 2 | 2 | 1 | **11** | located `No impl of Ord for (Int -> Int)` |
| lt_undesugared_adt | typecheck | 2 | 2 | 2 | 0 | 2 | 2 | 1 | **11** | located `No impl of Ord for Color` |

**Scoring notes / honesty checks:**
- The four `nonexhaustive_*` fixtures are scored **F=1**, not 2: naming the
  missing constructor is actionable but there is still **no source location**
  (L stays 0 — warning carries the dummy `{0,0}` range → A stays 0) and no
  literal arm text, matching the `record_missing_field` F=1 anchor. A generous
  reading could argue F=2; F=1 is the conservative, baseline-consistent call.
- **`main_takes_unit` did NOT improve** (stays **3**). The B2 build fix only
  covers the type-error path (`type_error_at_build`); the Unit-`main` shape still
  prints `emitter failed / No such file`. B2 landed *partially*.
- **`unbound_constructor` did NOT improve** (stays **10**). M1's did-you-mean
  machinery covers constructors, but `Yellow` has no near-match in scope, so no
  suggestion appears and the wording is still `Unbound variable:` (not
  "constructor"). The constructor-vs-variable wording theme is untouched.
- `unbound_variable` / `forgot_import` are unchanged (11 each): their names have
  no in-scope near-match, so no suggestion fires — correct behavior.
- `redundant_arm` unchanged (**4**): M2 added missing-case naming but **not**
  redundant-arm detection; it still emits no diagnostic (exit 0).

### Remaining worst-offenders (lowest-scoring now) → not-yet-done themes

| fixture | total | stage | theme (not yet done) |
|---|---|---|---|
| bad_escape | 2 | lex | Missing location on lexer errors + internal-state leak (`lexing: empty token`); needs loc + escape-naming |
| main_takes_unit | 3 | build | B2 partial — Unit-`main` still hits `emitter failed`; needs the build typecheck-guard extended to this shape (or the polymorphic-Unit-main gate) |
| redundant_arm | 4 | exhaust | Redundant-arm warning still unimplemented (M2 covered only non-exhaustive naming) |
| ambiguous_return | 4 | typecheck | By-design Num-defaulting accept — **not an error-quality defect** (belongs on the soundness backlog, not this workstream) |
| wrong_arg_type_in_map | 5 | typecheck | Tier-3 leaked raw tyvars (`a b`) + a three-diagnostic ambiguity storm (X) |

(Next band at 6–7: `lambda_missing_arrow` 6 — parse mis-blames unbound `x`
instead of the missing `=>`; `missing_comma_list`/`too_many_args`/
`apply_non_function`/`unbound_type_in_sig` at 7 — Tier-3 Num-mis-framing /
leaked-tyvar / no-location themes.)

**Axis ceiling:** **A remains capped at ≤ 1 corpus-wide** — no fixture carries a
`code`/`kind`/`fix`, and warnings/eval/lex/build still emit no JSON diagnostic.
A will not reach 2 anywhere until the Tier-4 error-codes + JSON `help`/`fix`
machinery lands in `compiler/driver/diagnostics.mdk`.

---

## Re-grade (post-Tier-4, base 761516e6)

Re-scored against the same §3 rubric, same 0/1/2 anchors, same scoring
conventions. This session grades **dimension A against the new
`./medaka check --json`** output (verified on a freshly built binary for every
one of the 60 fixtures) and re-scores **L for the lexer fixtures** (#19 gave
lexer errors real `file:L:C:` locations; `bad_escape`'s message was rewritten).
All other dimensions keep their post-Tier-1-2 values. Corpus size is unchanged
at **60 fixtures**.

**What Tier 4 changed in the JSON**, confirmed on the binary:
- Every located `check` diagnostic now carries a stable **`code`** (`L-*`/`P-*`/
  `R-*`/`T-*`/`W-*`), a **`kind`**, and a **real `range`**.
- Warnings (exhaustiveness) now carry a **real range + `W-NONEXHAUSTIVE` code**
  instead of the old dummy `{0,0}` — so warnings clear the A=2 bar.
- Did-you-mean diagnostics additionally carry `help` + a machine-applicable
  **`fix` {range, replacement}`** (verified on `typo_println`/`typo_local_var`).

**A anchor applied (§3):** `A=2` = JSON with stable `code` + `kind` + a **real**
(non-`{0,0}`) span, plus a machine `fix` for the mechanical (did-you-mean) cases.
`A=1` = JSON carries `code`/`kind` but the span is still the dummy `{0,0}`.
`A=0` = no JSON diagnostic at all (silent accept, or a `run`-path runtime error
that emits no structured diagnostic, or a `build`-only failure `check` can't see).

### Headline

- **Overall average: 615 / 60 = 10.25 / 14 — up from 9.02 (+1.23).**
- **A (Agent-parseable): 0.65 → 1.68** (sum 39 → 101, **+1.03**) — the headline
  Tier-4 movement, and now the *largest single-session lift* of any dimension in
  the corpus's history. **49 of 60 fixtures now reach A=2** (was **zero**).
- **Lex stage: 6.50 → 11.25 (+4.75)** — the biggest per-stage jump, from #19's
  locations plus the `bad_escape` message rewrite. Lex is no longer the weakest
  stage; **eval (8.33) now is.**
- **No regressions.** Every fixture's total is ≥ its post-Tier-1-2 value.

### A dimension — where the 60 fixtures land now

| A | count | fixtures |
|---|---|---|
| **2** | **49** | all lex (4), all parse (7), 5/8 resolve, 23/24 typecheck, 4/5 exhaust, all effect (3), `runtime_nonexhaustive`, `internal_extern_use`, `type_error_at_build` |
| **1** | **3** | `unbound_type_in_sig`, `unknown_module`, `import_unknown_name` — carry `code`+`kind` but the diagnostic's range is still `{0,0}` |
| **0** | **8** | `ambiguous_return`, `redundant_arm` (silent, no diagnostic); `division_by_zero`, `modulo_by_zero`, `list_index_oob`, `explicit_panic`, `let_else_fail` (`run`-path runtime errors — `check --json` emits nothing); `main_takes_unit` (`build`-only emitter failure `check` can't see) |

### Per-dimension averages (60 fixtures)

| dim | post-T1-2 sum | post-T1-2 avg | new sum | new avg /2 | Δ |
|---|---|---|---|---|---|
| **A** Agent-parseable | 39 | 0.65 | **101** | **1.68** | **+1.03** |
| L Located | 74 | 1.23 | 80 | 1.33 | +0.10 |
| C Correct | 96 | 1.60 | 98 | 1.63 | +0.03 |
| R Root-cause | 93 | 1.55 | 95 | 1.58 | +0.03 |
| J Jargon-free | 112 | 1.87 | 114 | 1.90 | +0.03 |
| X Cascade-free | 107 | 1.78 | 107 | 1.78 | +0.00 |
| **F** Actionable-fix | 20 | 0.33 | 20 | **0.33** | +0.00 |

A is now the story: it leapt from 2nd-weakest to mid-pack. The L/C/R/J nudges
are all from the four lexer fixtures (locations + the `bad_escape` rewrite).
**F (0.33) is now the single weakest axis** — Tier 4 added machine `fix` only to
the did-you-mean class; the rest of the corpus still surfaces no textual fix.

### Per-stage averages

| stage | fixtures | post-T1-2 avg | new avg | Δ |
|---|---|---|---|---|
| effect | 3 | 11.00 | **12.00** | +1.00 |
| resolve | 8 | 10.13 | **11.12** | +0.99 |
| lex | 4 | 6.50 | **11.25** | **+4.75** |
| typecheck | 24 | 9.63 | **10.58** | +0.95 |
| exhaust | 5 | 8.00 | **9.60** | +1.60 |
| build | 3 | 8.00 | **9.33** | +1.33 |
| parse | 7 | 8.29 | **9.29** | +1.00 |
| eval | 6 | 8.00 | **8.33** | +0.33 |

### Lexer fixtures — full re-score (L + A both moved)

| fixture | old→new | dims that moved | why |
|---|---|---|---|
| bad_escape | 2 → **12** | L 0→2, C 0→2, R 0→2, J 0→2, A 0→2 | message rewritten from the internal-leak `lexing: empty token` to a located `:2:20: invalid escape sequence '\q'` (`code L-BAD-ESCAPE`) |
| unterminated_string | 8 → **12** | L 0→2, A 0→2 | now `:3:0: unterminated string literal` (`L-UNTERMINATED-STRING`) |
| unterminated_block_comment | 8 → **12** | L 0→2, A 0→2 | now `:2:0: unterminated block comment` (`L-UNTERMINATED-COMMENT`) |
| unterminated_char | 8 → **9** | A 1→2 | still the generic `:2:15: Parse error` (a *parse*, not lex, error — outside #19's scope, so L stays 1), but the JSON now carries `P-PARSE`+kind+span → A=2 |

### A-only movements (dimension A re-scored corpus-wide)

Every non-lex fixture below moved **only** on A (all other dims held at their
post-Tier-1-2 values):

- **A 1 → 2 (44 fixtures):** all 7 parse; resolve `unbound_variable`,
  `typo_println`, `typo_local_var`, `unbound_constructor`, `forgot_import`;
  every typecheck error fixture except `ambiguous_return` (23 of 24); all 3
  effect. Each now emits `code`+`kind`+real-span. `typo_println`/`typo_local_var`
  additionally carry the machine `fix` (they reach the mechanical-case bar).
  Note: `else_let_block` and `missing_constraint` were already 13 → now **14**
  (perfect), and `typo_println`/`typo_local_var` reach **14** as well.
- **A 0 → 2 (7 fixtures):** the 4 `nonexhaustive_*` warnings (real range +
  `W-NONEXHAUSTIVE`), `runtime_nonexhaustive` (`check --json` surfaces the same
  `W-NONEXHAUSTIVE` warning), `internal_extern_use` (`R-INTERNAL-EXTERN`, real
  span), `type_error_at_build` (`check --json` yields the real `T-NO-IMPL`).
- **A 0 → 1 (3 fixtures):** `unbound_type_in_sig`, `unknown_module`,
  `import_unknown_name` — Tier 4 gave them `code`+`kind`, but the underlying
  resolver diagnostic still has a `{0,0}` range (the located pieces on
  `import_unknown_name` are a downstream `T-UNBOUND`/`Debug`-ambiguity cascade,
  not the primary `R-PRIVATE-NAME` message).

### Remaining worst-offenders (lowest-scoring now)

| fixture | total | stage | why it's still low / what caps A |
|---|---|---|---|
| main_takes_unit | 3 | build | Still `emitter failed / No such file`; `check --json` sees nothing (**A=0**). Needs the build typecheck-guard (or polymorphic-Unit-main gate) extended to this shape |
| ambiguous_return | 4 | typecheck | By-design Num-defaulting silent accept — no diagnostic, so **A=0**. Not an error-quality defect (soundness backlog) |
| redundant_arm | 4 | exhaust | Redundant-arm detection still unimplemented — exit 0, no diagnostic → **A=0** |
| wrong_arg_type_in_map | 6 | typecheck | Tier-3 leaked raw tyvars (`a b vs String`) + a 3-diagnostic ambiguity storm (X=0). A=2, but C/R/J/X untouched |
| lambda_missing_arrow | 7 | parse | Parse mis-blames unbound `x` instead of the missing `=>` (R=0, X=1). A=2 |

The honest **A-ceiling gaps** (why A didn't reach 2 everywhere):

1. **`run`-path runtime errors emit no structured diagnostic** — `division_by_zero`,
   `modulo_by_zero`, `list_index_oob`, `explicit_panic`, `let_else_fail` (5
   eval fixtures, all stuck at total **8**). They surface only as `run`-time
   stderr with no location and no JSON; `check --json` returns `[]`. This is the
   single largest cluster still at A=0 and is the eval stage's whole story
   (`runtime_nonexhaustive` escapes only because its non-exhaustiveness is
   *also* a compile-time warning). Closing it needs a structured runtime-error
   channel, which does not exist.
2. **Silent accepts** (`ambiguous_return`, `redundant_arm`) — no diagnostic at
   all, so nothing for an agent to parse.
3. **`build`-only failure** (`main_takes_unit`) — the error never reaches the
   typecheck/JSON path.
4. **`{0,0}`-range resolver diagnostics** (`unbound_type_in_sig`,
   `unknown_module`, `import_unknown_name`) — have `code`+`kind` but no real
   span, capping them at A=1. A precise `Loc` on these module/type-resolution
   errors would lift all three to A=2 (+3 more A points).

**Axis summary:** A is essentially *done* for the located compile-time corpus
(49/60 at A=2). The residual A gap is structural — it now coincides exactly with
the fixtures that produce **no compile-time diagnostic** (runtime/silent/build),
not with any missing `code`/`kind`/`fix` machinery. **F (0.33) is now the
weakest axis**, and the Tier-3 typecheck-framing themes (Num-mis-framing, leaked
tyvars, ambiguity cascades) remain the next-largest quality reservoir.
