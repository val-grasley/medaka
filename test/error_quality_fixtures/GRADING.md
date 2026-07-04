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

---

## Re-grade (post-Tier-3-framing, base 00ca0bfa)

Re-scored the 8 `typecheck/` fixtures the Tier-3 reservoir touched, against the
same §3 rubric/anchors as every prior pass. All other 52 fixtures are untouched
and keep their post-Tier-4 score (615/60 baseline). Every fixture below was
reproduced on a freshly built binary (`./medaka check` text + `./medaka check
--json`) and matches its captured `.out` golden exactly, so the golden text is
the verified source of truth.

Tier-3 landed as 4 chunks, confirmed on the binary:
1. **Cascade suppression** — the secondary `ambiguous 'Debug a'`/`'Mappable a'`
   error is gone from `too_many_args`, `apply_non_function`,
   `record_wrong_field`, `wrong_arg_type_in_map` (each now emits exactly **one**
   JSON diagnostic, confirmed via `--json`).
2. **"Not a function" reframe** — `apply_non_function` now reads *"This
   expression has type Int, which is not a function, so it cannot be applied to
   an argument."* (`T-NOT-A-FUNCTION`); `too_many_args` now reads *"'inc' takes
   1 argument(s) but is applied to 2."* (also `T-NOT-A-FUNCTION`). Both drop the
   old raw-tyvar `Int vs a -> b` symptom framing.
3. **Num-mis-framing → context-aware mismatch** — `if_branch_mismatch` ("if
   branches have different types: Int vs String"), `list_heterogeneous` ("list
   elements have different types: Int vs String"), `cons_type_mismatch` ("cons
   (::) type mismatch: head is Int but the list holds String"),
   `arg_order_swapped` (arg1 now "Type mismatch: Int literal vs String" —
   **both** diagnostics kept, confirmed 2 real JSON diagnostics, not one
   primary + one cascade).
4. `wrong_arg_type_in_map`'s primary message (`Type mismatch: a b vs String`)
   is **unchanged** — only its ambiguity-cascade storm was suppressed (Chunk 1);
   the raw-tyvar leak (`a b`) is untouched, so J stays low there.

**Chunk B intentionally NOT done:** `record_missing_field`'s secondary `No impl
of Debug for Person` is a genuine independent error (constructing the record
with a missing field also makes it un-`debug`-able — a real second fact, not an
artifact of the first), not a cascade suppression candidate. Verified
unchanged on the binary (`--json` still shows both `T-MISSING-FIELD` and
`T-NO-IMPL`); its score stays **11**, untouched.

### Per-fixture delta table

| fixture | old→new | dims that moved | why |
|---|---|---|---|
| too_many_args | 8 → **13** | C 1→2, R 1→2, F 0→1, J 1→2, X 1→2 | reframed to a precise arity message naming both counts (1 vs 2); names *what's* wrong (like `record_missing_field`'s field-naming) so F=1, not the literal fix text, so not F=2; no raw tyvar; cascade gone (single JSON diagnostic) |
| apply_non_function | 8 → **12** | C 1→2, R 1→2, J 1→2, X 1→2 | reframed to "has type Int, which is not a function…"; correct + root-cause + jargon-free; cascade gone. F stays 0 — the message states the *nature* of the error but names no concrete quantity/identifier to act on (unlike too_many_args' counts or record_missing_field's field name) |
| record_wrong_field | 10 → **12** | J 1→2, X 1→2 | message itself (`Field aeg does not belong to record Person`) was already correct/located pre-Tier-3; only the trailing `Debug a`-ambiguity cascade (the source of the J=1 jargon leak) is now suppressed. C/R/F unchanged (still no "did you mean 'age'?") |
| wrong_arg_type_in_map | 6 → **8** | X 0→2 | cascade-only fix: was a 3-diagnostic ambiguity storm, now exactly one diagnostic. Primary message (`a b vs String`) is untouched — C/R/J unchanged (still cryptic, still leaks the raw tyvar `a b`) |
| if_branch_mismatch | 10 → **12** | C 1→2, R 1→2 | reframed from `No impl of Num for String` to "if branches have different types: Int vs String" — names the actual structural shape. J/X were already 2 (no jargon, no cascade pre-existing here) |
| list_heterogeneous | 10 → **12** | C 1→2, R 1→2 | reframed to "list elements have different types: Int vs String" — same structural-shape win as if_branch_mismatch |
| cons_type_mismatch | 10 → **12** | C 1→2, R 1→2 | reframed to "cons (::) type mismatch: head is Int but the list holds String" — names both the operator and which side (head vs list) is wrong |
| arg_order_swapped | 9 → **11** | C 1→2, R 1→2 | arg1's message reframed from a `No impl of Num` cascade-symptom to a real second "Type mismatch: Int literal vs String" diagnostic; both diagnostics are now independently correct and each points exactly at its own swapped argument. X stays 1 (still 2 diagnostics — the pair is legitimate, not a cascade, but the rubric's X dimension scores diagnostic-count/focus, and this fixture still surfaces two separate call-site messages rather than one unified "arguments 1 and 2 are swapped" root-cause statement). F stays 0 — neither message says "swapped" |

Sum for these 8 fixtures: **71 → 92 (+21)**.

### New corpus average

```
615 (post-Tier-4 total) + 21 (Tier-3 delta) = 636
636 / 60 = 10.60
```

**Overall average: 636 / 60 = 10.60 / 14 — up from 10.25 (+0.35).**

### Per-dimension movement (60 fixtures)

Only C, R, F, J, X moved (A and L are untouched by this chunk — every one of
the 8 fixtures already had a real, located, `code`+`kind`+real-span JSON
diagnostic before this session).

| dim | post-Tier-4 sum | post-Tier-4 avg | new sum | new avg /2 | Δ |
|---|---|---|---|---|---|
| C Correct | 98 | 1.63 | **104** | **1.73** | +0.10 |
| R Root-cause | 95 | 1.58 | **101** | **1.68** | +0.10 |
| X Cascade-free | 107 | 1.78 | **112** | **1.87** | +0.09 |
| J Jargon-free | 114 | 1.90 | **117** | **1.95** | +0.05 |
| F Actionable-fix | 20 | 0.33 | **21** | **0.35** | +0.02 |
| A Agent-parseable | 101 | 1.68 | 101 | 1.68 | +0.00 |
| L Located | 80 | 1.33 | 80 | 1.33 | +0.00 |

C and R move the most (exactly as Tier 3 targeted: structural mis-framing was
the biggest remaining C/R drag in the corpus). X gets a modest lift from the
4 cascade-suppression fixtures. F barely moves (+1, from `too_many_args`
alone) — Tier 3 was never aimed at F, and the axis stays the corpus's floor.

### Per-stage average — typecheck

| stage | fixtures | post-Tier-4 avg | new avg | Δ |
|---|---|---|---|---|
| typecheck | 24 | 10.58 (sum 254) | **11.46** (sum 275) | **+0.88** |

`typecheck` overtakes `resolve` (11.12) as the corpus's 2nd-strongest stage,
behind only `effect` (12.00). All other 7 stages are unchanged (this chunk
touched only `typecheck/` fixtures).

### What's still weakest now

**F (Actionable-fix, 0.35/2) is still the single weakest axis in the corpus,
by a wide margin** — Tier 3 was a framing fix (say the *right* thing), not a
suggestion-machinery fix (say *what to do about it*), so it moved F by only
+1 (on `too_many_args`, whose precise arg-count naming crossed the F=1 bar).
The remaining Tier-3 fixtures (`apply_non_function`, `if_branch_mismatch`,
`list_heterogeneous`, `cons_type_mismatch`, `arg_order_swapped`,
`wrong_arg_type_in_map`) all still score F=0: none of them names a concrete
edit (a field name, an argument count, a suggested identifier) the way
`record_missing_field`/`nonexhaustive_*`/`typo_*` do. Closing this needs
per-shape actionable copy (e.g. "swap arguments 1 and 2" for
`arg_order_swapped`, "remove the extra argument" for `too_many_args`), which
is a distinct, not-yet-scoped follow-on.

The **A=0 cluster is unchanged** (8 fixtures, same as post-Tier-4): the 5
`run`-path runtime errors with no structured diagnostic
(`division_by_zero`, `modulo_by_zero`, `list_index_oob`, `explicit_panic`,
`let_else_fail`), the 2 by-design/unimplemented silent accepts
(`ambiguous_return`, `redundant_arm`), and the 1 build-only failure
(`main_takes_unit`) that `check --json` can't see. None of these are
`typecheck/`-reservoir fixtures, so Tier 3 could not and did not touch them.

### Note on Chunk B

Chunk B (making `record_missing_field`'s secondary error a cascade
suppression) was **intentionally not implemented**. Verified on the binary:
constructing `Person { name = "Alice" }` with `age` missing produces both
`T-MISSING-FIELD` (primary) and a genuine, independent `T-NO-IMPL: No impl of
Debug for Person` — the partially-constructed value really doesn't have a
`Debug` instance derivable, which is a real second fact about the program, not
an artifact cascading from the first error. `record_missing_field`'s score is
**unchanged at 12** (its post-Tier-4 value: L2 C2 R2 F1 J2 X1 A2 — it *was*
among the 23-of-24 typecheck fixtures whose A moved 1→2 in the Tier-4 pass,
same as the 8 fixtures graded above; this session leaves it untouched since
Chunk B was not implemented).

---

## Re-grade (post-F-axis-did-you-mean + F3-locations, base 9d6398ad)

**Baseline correction, checked first.** The task brief for this session named
`## Re-grade (post-Tier-4, base 761516e6)` (615/60 = 10.25) as "the last
re-grade." That is stale by one session: `## Re-grade (post-Tier-3-framing,
base 00ca0bfa)` (commit `b421e264`, confirmed an ancestor of `HEAD` via
`git merge-base --is-ancestor`) already advanced the corpus to **636/60 =
10.60** by re-framing 8 `typecheck/` fixtures (cascade suppression + reframed
messages), including `typecheck/record_wrong_field` — one of this session's
four moved fixtures — from 10 to **12** (J 1→2, X 1→2, cascade `Debug a`
diagnostic suppressed). Starting this session's arithmetic from 615 would
silently re-lose that already-landed +2. **This re-grade uses 636/60 = 10.60
as the accurate pre-session baseline** and shows the corrected per-fixture
deltas below (each "old" value is the fixture's true current value in this
file, not its stale post-Tier-4 value).

Every fixture below was reproduced on the freshly built binary (`./medaka
check` text + `./medaka check --json`), confirmed byte-identical to its
captured `.out` golden, before scoring.

### What landed, confirmed on the binary

1. **F3 resolver locations** (`compiler/RESOLVER-DIAG-LOCATION-DESIGN.md`
   Chunk A/B): `R-UNKNOWN-TYPE`/`R-PRIVATE-NAME`/`R-MODULE-LOAD` now carry a
   real `file:L:C:` location instead of `<unknown location>`, both in CLI text
   and `check --json`'s `range`. `unbound_type_in_sig`'s previous **duplicate
   identical diagnostic** (`Unknown type: Strng` emitted twice at the same
   `<unknown location>` — a real bug) is gone; the two diagnostics now shown
   are two *genuinely distinct* source occurrences (the param position `:1:4`
   and the return position `:1:13`), each independently located.
2. **F-axis did-you-mean expansion**: `record_wrong_field` (field name),
   `unbound_type_in_sig` (type name), and three new Haskell-alias fixtures
   (`fmap`→`map`, `Just`/`Nothing`→`Some`/`None`, `Monad`→`Thenable`) all now
   carry a `help` string and a machine-applicable JSON `fix{range,
   replacement}`.

### Per-fixture delta table — the 4 moved fixtures

| fixture | true old → new | dims that moved | why |
|---|---|---|---|
| `typecheck/record_wrong_field` | 12 → **14** | F 0→2 | now `— did you mean 'age'?` + JSON `fix{replacement:"age"}`; single JSON diagnostic (cascade already suppressed pre-session) — reaches the perfect score |
| `resolve/unbound_type_in_sig` | 8 → **13** | L 0→2, F 0→2, A 1→2 | real `file:1:4:`/`file:1:13:` locations (was `<unknown location>` ×2, a literal duplicate-emission bug); `— did you mean 'String'?` + JSON `fix{replacement:"String"}`; real JSON `range` (was `{0,0}`). X held at **1** (conservative: both diagnostics trace to the *same* underlying typo appearing twice in one signature, not two independent mistakes, so not scored as fully cascade-free) |
| `resolve/import_unknown_name` | 9 → **12** | L 0→2, A 1→2 | `file:1:0:` real location (was `<unknown location>`); JSON `range` now real. No `fix` — this is a private-name-access error, not a did-you-mean case, so F stays 0 |
| `resolve/unknown_module` | 9 → **12** | L 0→2, A 1→2 | `file:1:0:` real location + caret (was unlocated); JSON `range` now real. No `fix` (no nearby module name to suggest), F stays 0 |

Sum for these 4: **38 → 51 (+13)**.

### New fixtures — scored fresh

| fixture | stage | L | C | R | F | J | X | A | total | rationale |
|---|---|---|---|---|---|---|---|---|---|---|
| `resolve/haskell_fmap` | resolve | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **14** | `Unbound variable: fmap — did you mean 'map'? ('fmap' is Haskell; Medaka uses 'map')`, located+caret at `:1:16`; JSON `R-UNBOUND` + real range + `fix{replacement:"map"}`; single diagnostic, no compiler-internal jargon |
| `resolve/haskell_monad` | resolve | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **14** | `Unknown type: Monad — did you mean 'Thenable'? (...)`, located at `:1:4`; JSON `R-UNKNOWN-TYPE` + real range + `fix{replacement:"Thenable"}` — this is the newly-landed F3 case (type-alias hints previously lacked a location/fix) |
| `resolve/haskell_just` | resolve | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **14** | Two diagnostics (`Just`→`Some`, `Nothing`→`None`), each located+captioned, each with its own JSON `fix`; scored cascade-free (X=2) because the two are independent facts — two distinct unmatched constructors in one `match`, not one root cause echoing twice |

Sum for these 3: **42**.

### New corpus arithmetic

```
636  (post-Tier-3-framing sum, 60 fixtures — the accurate pre-session baseline)
- 38  (old values of the 4 moved fixtures, already inside 636)
+ 51  (their new values)
= 649
+ 42  (3 new fixtures, added fresh — corpus grows 60 → 63)
= 691

691 / 63 = 10.968... ≈ 10.97
```

**Overall average: 691 / 63 = 10.97 / 14 — up from 10.60 (+0.37).**

(For reference, applying the task brief's literal instruction — starting from
615 instead of the true 636 — would understate the result: 615 − 30(stale-old
moved values, using the post-Tier-4 figures 10/8/9/9) + 51 + 42 = 678/63 =
10.76. The 10.97 figure above is correct; 10.76 double-loses the already-landed
Tier-3 record_wrong_field delta and should not be used.)

### Per-dimension movement (63 fixtures)

| dim | pre-session sum (60) | pre-session avg | new sum (63) | new avg /2 | Δ |
|---|---|---|---|---|---|
| J Jargon-free | 117 | 1.95 | **123** | **1.95** | +0.00 |
| C Correct | 104 | 1.73 | **110** | **1.75** | +0.02 |
| R Root-cause | 101 | 1.68 | **107** | **1.70** | +0.02 |
| X Cascade-free | 112 | 1.87 | **118** | **1.87** | +0.00 |
| A Agent-parseable | 101 | 1.68 | **110** | **1.75** | +0.07 |
| L Located | 80 | 1.33 | **92** | **1.46** | **+0.13** |
| **F** Actionable-fix | 21 | 0.35 | **31** | **0.49** | **+0.14** |

**F moves the most** (0.35 → 0.49, still the corpus floor by a wide margin,
but the largest single-session F lift since Tier-4): the did-you-mean +
machine-`fix` treatment now covers `record_wrong_field`, `unbound_type_in_sig`,
and all 3 new Haskell-alias fixtures. **L is 2nd** (1.33 → 1.46): the F3
location work closed the three remaining `{0,0}`/`<unknown location>` resolver
holes. A also ticks up (+0.07) purely as a side effect of the same location
fixes (real span is required for A=2).

### Resolve-stage average

The `resolve` stage grows from 8 → 11 fixtures (the 3 new Haskell fixtures are
all `resolve/`). Its 8 pre-existing fixtures were untouched by Tier-3-framing
(that pass only touched `typecheck/`), so their pre-session sum is the
post-Tier-4 value: **89** (avg 11.12: `unbound_variable` 12, `typo_println` 14,
`typo_local_var` 14, `unbound_constructor` 11, `forgot_import` 12,
`unbound_type_in_sig` 8, `unknown_module` 9, `import_unknown_name` 9).

```
89 + 5 (unbound_type_in_sig 8→13) + 3 (import_unknown_name 9→12)
   + 3 (unknown_module 9→12)
= 100
+ 42 (3 new Haskell fixtures, 14 each)
= 142
142 / 11 = 12.91
```

**resolve: 11.12 → 12.91 (+1.79)** — resolve overtakes `effect` (12.00,
unchanged) as the corpus's **strongest stage**. `typecheck` also ticks up
slightly from `record_wrong_field`'s move: 275 + 2 = 277 / 24 = **11.54** (was
11.46). All other stages (`effect` 12.00, `lex` 11.25, `exhaust` 9.60, `build`
9.33, `parse` 9.29, `eval` 8.33) are untouched this session.

### What's still weakest

- **F (0.49/2) remains the single weakest axis**, even after this session's
  gain — the did-you-mean/F3 work is real but mechanical-suggestion coverage
  is still a minority of the corpus; the Tier-3 typecheck-framing residual
  (`apply_non_function`, `if_branch_mismatch`, `list_heterogeneous`,
  `cons_type_mismatch`, `arg_order_swapped`, `wrong_arg_type_in_map`, all F=0)
  is still the next-largest reservoir, unchanged by this session (it never
  touched `typecheck/` framing, only `record_wrong_field`'s pre-existing
  did-you-mean spot-fix).
- **The A=0 cluster is unchanged (8 fixtures)**: the 5 `run`-path runtime
  errors with no structured diagnostic (`division_by_zero`, `modulo_by_zero`,
  `list_index_oob`, `explicit_panic`, `let_else_fail` — `check --json` emits
  nothing for these since they only fail under `medaka run`), the 2 by-design/
  unimplemented silent accepts (`ambiguous_return`, `redundant_arm`), and the 1
  build-only failure (`main_takes_unit`, `check` never sees it). None of these
  are resolve/F3-reservoir fixtures, so this session could not and did not
  touch them — they remain the corpus's honest floor for both A and F.

## Re-grade (post-F5 + line-fix, base 677ba415)

Base confirmed: `git merge-base --is-ancestor 677ba415 HEAD` → `BASE_OK`. Binary
rebuilt fresh (`make medaka`, cold-start from seed, C3a tolerant-lagging-seed
warning only — not a regression). All four new fixtures reproduced on the
freshly built binary (`./medaka check` text + `./medaka check --json`),
confirmed byte-identical to their captured `.out` goldens, and their reported
`file:L:C:` cross-checked character-by-character against the actual fixture
text (see arithmetic below) — this is the direct verification that the
off-by-one line fix landed correctly on these fixtures.

`hs_syntax_guard_valid` excluded per brief: it is a valid-code FP-guard (proves
the four Haskell hints don't false-positive on legitimate Medaka that merely
resembles Haskell shapes — `f : Int -> List Int` / `1 :: [2, 3]` cons,
`| y :: ys <- x` guard, `debug`/interpolation); `check` exits **0** with no
diagnostic, confirmed on the binary. Not a mistake fixture — not scored, not
counted in any denominator.

### New fixtures — scored fresh (all 4 verified single-diagnostic, real span)

| fixture | code/kind | reported loc | actual token col (0-idx, verified) | L | C | R | F | J | X | A | total | rationale |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `hs_lambda` | `L-HS-LAMBDA` / lex | `:1:21` | `\` is at index 21 (0-idx) of `main = println (map (\x -> x + 1) [1, 2, 3])` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **14** | caret sits exactly on the offending `\`; "Medaka lambdas are written 'x => e' (not '\x -> e')" is a concrete rewrite, true, single diagnostic, no internal jargon |
| `hs_dollar` | `L-HS-DOLLAR` / lex | `:1:15` | `$` is at index 15 of `main = println $ 1 + 2` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **14** | caret on `$` exactly; "apply directly 'f x', parenthesize '(f x)', or pipe with '\|>'" gives three concrete alternatives |
| `hs_case_of` | `P-HS-CASE` / parse | `:1:6` | `c` of `case` is at index 6 of `f x = case x of` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **14** | caret on the start of `case`; "use 'match e' with indented 'pattern => body' arms" names the replacement construct concretely |
| `hs_sig_coloncolon` | `P-HS-SIG` / parse | `:1:2` | first `:` of `::` is at index 2 of `f :: Int -> Int` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **14** | caret on `::`; explains *why* (it's cons, not signature colon) and gives the exact replacement `'f : T'` |

All four: `check --json` diagnostic count verified **= 1** per file (no
cascade → R=2, X=2). Per the task brief's stated criterion for this pass, A=2
= stable `code` + `kind` + real non-`{0,0}` range — all four carry a
per-message stable code (not the generic `P-PARSE`), a `kind`, and a real
`range` matching the verified token column, so A=2 for all four (no `help`/
`fix` JSON field yet — that's a *further* enhancement, not required for A=2
under this pass's criterion). F=2 for all four: each message embeds a
concrete rewritten form or short list of concrete alternatives in prose (the
same bar `else_let_block`, the corpus's prior F=2 exemplar, was held to — a
literal rewrite example, not "check your syntax").

Sum for the 4 new fixtures: **14 × 4 = 56**.

### Corpus arithmetic

```
691   (prior corpus sum, 63 fixtures — base 9d6398ad re-grade)
+  56  (4 new Haskell-syntax fixtures, all 14/14)
= 747
63 + 4 = 67 fixtures

747 / 67 = 11.1492... ≈ 11.15
```

**Overall average: 747 / 67 = 11.15 / 14 — up from 10.97 (+0.18).**
(`hs_syntax_guard_valid` is not in either the numerator or the denominator —
it is a valid-code guard fixture, exit 0, nothing to grade.)

### Off-by-one line fix — effect on the pre-existing corpus

The line-number fix (parse/lex located errors previously reported `line+1`)
changes the committed `.out` goldens for the pre-existing `lex/` and `parse/`
fixtures (their reported line shifts down by one to the true line), but does
**not** change any of their scores in this file: they were already graded as
"located" (L=1 or L=2, per fixture) under the old — technically off-by-one —
line number, and the fix makes that same L grade **honest** rather than
lucky. Spot-checked on the rebuilt binary: all 4 `lex/` fixtures
(`bad_escape`, `unterminated_block_comment`, `unterminated_char`,
`unterminated_string`) reproduce byte-identical to their current `.out`
goldens, confirming the corrected line numbers are now committed and correct.

### Parse-stage average

```
65   (prior parse-stage sum, 7 fixtures, avg 9.29)
+ 56  (4 new fixtures, all 14/14)
= 121
7 + 4 = 11 fixtures
121 / 11 = 11.00
```

**parse: 9.29 → 11.00 (+1.71)** — parse overtakes `typecheck` (11.54) is
close but stays just under it; parse is now the corpus's **2nd-strongest
stage** (behind `resolve` 12.91), a sharp jump from being tied for weakest
alongside `eval`/`build` last session. **F** moves the most within parse: sum
2 → 10 (avg 0.29 → 0.91, driven entirely by the 4 new fixtures — none of the
7 pre-existing generic parse fixtures gained a fix this session). **A** holds
at its ceiling (avg 2.00 → 2.00, unchanged: the pre-existing 7 were already
at A=2 from the earlier code+kind session, and all 4 new fixtures land at
A=2 too).

### Remaining weakest

The corpus-wide **F axis remains the floor** even after this session's parse
jump (this session only added 4 fixtures with F=2; it did not touch the
larger `typecheck/`-framing F=0 reservoir — `apply_non_function`,
`if_branch_mismatch`, `list_heterogeneous`, `cons_type_mismatch`,
`arg_order_swapped`, `wrong_arg_type_in_map` — all still F=0). The **A=0
cluster of 8 `run`-path/build-only fixtures is unchanged** (unaffected by
parse/lex work): `division_by_zero`, `modulo_by_zero`, `list_index_oob`,
`explicit_panic`, `let_else_fail`, `ambiguous_return`, `redundant_arm`,
`main_takes_unit`.

---

## Re-grade (post-eval-runtime-JSON, base `37e7ab0d1`)

Base confirmed: `git merge-base --is-ancestor 37e7ab0d1 HEAD` → `BASE_OK`.
Read-only re-grade — no compiler source touched, only this file +
`INVENTORY.md`. The prior corpus state (`747 / 67 = 11.15`, the "post-F5 +
line-fix" section above) is the starting point.

**What changed:** `medaka run` runtime errors are no longer naked strings.
Text now reads `file:L:C: runtime error [E-*]: <message>`; `medaka run --json`
emits the SAME envelope shape as `check --json` — one diagnostic object per
file with `code`, `kind`, a real (non-`{0,0}`) `range`, `message`,
`severity: 1`, `source: "medaka"`. No `fix` field — there is no mechanical
edit for "division by zero" or a user's own `panic` string. Verified against
the committed `.out`/`.json.out` goldens for all 6 `eval/` fixtures (shown
above in the task brief and re-read from the checked-in goldens; not
re-executed here since the goldens are the authoritative source of truth per
the task brief, and this is a docs-only re-grade).

### Reading of the rubric: what does A=2 require?

§3's row for **A** is explicit: **0** = no JSON or JSON missing location;
**1** = JSON with span but no code/kind/fix; **2** = JSON with stable `code`,
`kind`, span, **and machine `fix`**. Taken strictly, a diagnostic that has
`code`+`kind`+real `range` but **no `fix`** does not meet the literal text of
either row — it exceeds row 1 (it does carry `code`/`kind`) but falls short of
row 2 (no `fix`). Since the dimension is 0/1/2 with no half-points, the
correct honest score for "code+kind+span, no fix" is **A=1**, not A=2: the
`fix` clause in row 2 is not decorative, it's the field that makes the
diagnostic *machine-applicable* rather than merely *machine-readable*, and
runtime errors here (a divide-by-zero, an OOB index, a user's own `panic`
string) have no mechanical edit to offer — there is nothing to fill a `fix`
field with, so A is genuinely capped at 1 for this whole cluster.

**Flagging a pre-existing corpus inconsistency, not resolving it:** earlier
sessions in this same file (the Haskell-syntax-hints pass, and the original
Tier-4 pass for warnings/`unbound_type_in_sig`-style diagnostics) explicitly
adopted a *looser* criterion — "A=2 = `code`+`kind`+real range, `fix` is a
further enhancement" — and scored several no-`fix` fixtures at A=2 under it
(e.g. `hs_lambda`/`hs_dollar`/`hs_case_of`/`hs_sig_coloncolon`, and
`runtime_nonexhaustive`'s A=2 via the `check`-path `W-NONEXHAUSTIVE` warning,
which also carries no `fix`). This session does **not** retroactively
re-score those — that's out of scope for a targeted eval-cluster re-grade —
but applies the **strict** reading (fix required for A=2) to the 5 fixtures
being newly graded here, per the task's explicit instruction to score
honestly rather than inflate. The corpus therefore has a real, currently
unreconciled scoring-criterion split on dimension A; see "remaining floor"
below.

### Per-fixture re-score (6 `eval/` fixtures)

| fixture | dim | old | new | why |
|---|---|---|---|---|
| `division_by_zero` | L | 0 | **2** | `:3:23:` — caret lands on `n`, the zero divisor (verified against fixture source: `println (debug (10 / n))`, col 23 = `n`) |
| | A | 0 | **1** | `run --json` now emits `code:"E-DIV-ZERO"`, `kind:"error"`, real `range`; no `fix` (nothing mechanical to suggest) |
| `modulo_by_zero` | L | 0 | **2** | `:3:23:` — caret on `d`, the zero modulus |
| | A | 0 | **1** | same shape: `E-MOD-ZERO`, code+kind+range, no `fix` |
| `list_index_oob` | L | 0 | **2** | `:3:22:` — caret on the `10` index literal itself |
| | A | 0 | **1** | `E-INDEX-OOB`, code+kind+range, no `fix`; message still doesn't name the list's actual length (F stays 0) |
| `explicit_panic` | L | 0 | **2** | `:2:37:` — caret on the panic-message string literal (the exact `panic "user not found"` call site, not a downstream victim like the `main` call site) |
| | A | 0 | **1** | `E-PANIC`, code+kind+range, no `fix` (a user's own panic string has no mechanical edit) |
| `let_else_fail` | L | 0 | **2** | `:3:42:` — caret on the panic-message string literal in the `else panic "empty list"` clause |
| | A | 0 | **1** | same: `E-PANIC`, code+kind+range, no `fix` |
| `runtime_nonexhaustive` | L | 0 | **2** | `:1:29:` — caret on `7`, the match scrutinee |
| | A | 2 | 2 (unchanged) | already reached A=2 pre-existing via the `check --json` `W-NONEXHAUSTIVE` compile-time path (a *different*, looser-criterion score this session doesn't re-litigate — see above); the new `run --json` path emits the same no-`fix` shape as the other 5, consistent with, not a regression from, its existing grade |

**C, R, J, X unchanged for all 6** — the diagnosis, root-cause framing,
vocabulary, and single-diagnostic-per-cause property were already correct
(C/R were fixed to 2 in the earlier `panic`-unbound-at-run fix for
`explicit_panic`/`let_else_fail`; the other 4 were already C=2/R=2). **F
unchanged at 0 for all 6** — the message *text* is byte-identical to before
apart from the new `file:L:C: runtime error [E-CODE]:` prefix; no fixture
gained a suggested edit.

### New per-fixture totals

| fixture | L | C | R | F | J | X | A | old total | new total |
|---|---|---|---|---|---|---|---|---|---|
| `division_by_zero` | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 8 | **11** |
| `modulo_by_zero` | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 8 | **11** |
| `list_index_oob` | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 8 | **11** |
| `explicit_panic` | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 8 | **11** |
| `let_else_fail` | 2 | 2 | 2 | 0 | 2 | 2 | 1 | 8 | **11** |
| `runtime_nonexhaustive` | 2 | 2 | 2 | 0 | 2 | 2 | 2 | 10 | **12** |

Each of the first 5 gains **+3** (L 0→2, A 0→1); `runtime_nonexhaustive` gains
**+2** (L only, its A was already 2).

### Eval-stage arithmetic

```
old eval sum = 8*5 + 10 = 50   (6 fixtures, avg 8.33)
new eval sum = 11*5 + 12 = 67  (6 fixtures)
67 / 6 = 11.1666... ≈ 11.17
```

**eval: 8.33 → 11.17 (+2.83)** — the largest single-session per-stage gain in
this file's history (previously the lex-stage +4.75 jump was the largest, but
off a smaller stage-avg base). `eval` moves from the corpus's **weakest**
stage to solidly mid-pack, still below `resolve` (12.91), `effect` (12.00),
`typecheck` (11.54), `parse` (11.00), but now above `exhaust` (9.60) and
`build` (9.33).

### Corpus arithmetic

```
747   (prior corpus sum, 67 fixtures — "post-F5 + line-fix" baseline)
- 50  (old sum of the 6 eval fixtures, already inside 747)
+ 67  (their new sum)
= 764
67 fixtures (unchanged — no fixtures added or removed)

764 / 67 = 11.402... ≈ 11.40
```

**Overall average: 764 / 67 = 11.40 / 14 — up from 11.15 (+0.25).**

### Per-dimension movement (67 fixtures)

Only **L** and **A** move this session (C/R/F/J/X untouched — no fixture
outside the 6 changed on any other axis). Baseline sums for L/A read off the
67-fixture "post-F5 + line-fix" corpus (established by the Haskell-hints
session): L sum 92 (avg 1.37), A sum 110 (avg 1.64).

- **L delta = +12**: all 6 eval fixtures move 0→2 (+2 each × 6 = +12).
  New L sum: 92 + 12 = **104**, new avg 104/67 = **1.55** (+0.18).
- **A delta = +5**: only the first 5 fixtures move 0→1 (+1 each × 5 = +5);
  `runtime_nonexhaustive`'s A was already 2 (via the `check`-path warning) and
  doesn't move. New A sum: 110 + 5 = **115**, new avg 115/67 = **1.72**
  (+0.07).

| dim | old sum | old avg | new sum | new avg | Δ |
|---|---|---|---|---|---|
| L Located | 92 | 1.37 | **104** | **1.55** | +0.18 |
| A Agent-parseable | 110 | 1.64 | **115** | **1.72** | +0.07 |
| C/R/F/J/X | — | — | — | — | +0.00 (unchanged) |

### Remaining floor

- **F (Actionable-fix) is still the corpus's single weakest axis by a wide
  margin** and this session does not move it at all — none of the 6 eval
  fixtures gained a suggested edit; there simply isn't a mechanical one for
  "division by zero" or "index N out of bounds" (a possible future win: name
  the list's actual length in `E-INDEX-OOB`'s message, which would be a real,
  cheap **F 0→1** improvement, though still not a machine `fix`).
- **A is now honestly capped at 1, not 2, for 5 of the 6 eval fixtures** —
  and will stay there until either (a) a `fix` is invented for a class of
  runtime error that doesn't obviously have one, or (b) the corpus's A=2
  criterion is formally revisited corpus-wide to match the strict rubric text
  (which would also pull down the Haskell-hints fixtures and
  `runtime_nonexhaustive`'s check-path score, a larger and out-of-scope
  change this session declines to make unilaterally).
- **The `typecheck/`-framing F=0 reservoir is untouched**
  (`apply_non_function`, `if_branch_mismatch`, `list_heterogeneous`,
  `cons_type_mismatch`, `arg_order_swapped`, `wrong_arg_type_in_map`) — not
  in scope for this session.
- **`main_takes_unit` (build-only, total 3) and the 2 silent accepts**
  (`ambiguous_return`, `redundant_arm`, total 4 each) remain the corpus's
  absolute floor, untouched — none are `eval`/`run`-path runtime errors, so
  this workstream's fix doesn't reach them.
