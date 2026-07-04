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

**Clarified by the workstream owner (2026-07-04) and now reflected in
`ERROR-QUALITY.md` §3:** dimension **A** measures structural machine-
*parseability* only — **A=2 = JSON with stable `code` + `kind` + real span.**
The machine-applicable `fix` is **decoupled** from A and scored under
dimension **F** (Actionable-fix) instead; requiring `fix` in both A and F
would double-count the same field. So the row now reads: **A=0** = no JSON /
JSON missing location; **A=1** = JSON with span but no stable `code`/`kind`;
**A=2** = `code` + `kind` + span. A `fix`-less diagnostic that carries
`code`/`kind`/span is **A=2**, and its lack of a `fix` costs it only on F.

Under this (clarified) reading the 5 newly-JSON'd runtime fixtures all reach
**A=2**: `run --json` emits `code`+`kind`+real range for each. Their absence
of a mechanical `fix` (there is no edit to suggest for "division by zero" or a
user's own `panic` string) is correctly and separately reflected in **F=0**.

**Reconciliation with earlier grades:** prior no-`fix` A=2 grades in this file
— the Haskell-syntax-hints fixtures
(`hs_lambda`/`hs_dollar`/`hs_case_of`/`hs_sig_coloncolon`) and
`runtime_nonexhaustive`'s `check`-path `W-NONEXHAUSTIVE` A=2 — are **consistent
with** the clarified rubric (they all carry `code`+`kind`+span). No deflation
is needed; the earlier "`fix` is a further enhancement, not required for A=2"
convention those sessions used is exactly the now-canonical reading. There is
no open scoring-criterion split on dimension A.

### Per-fixture re-score (6 `eval/` fixtures)

| fixture | dim | old | new | why |
|---|---|---|---|---|
| `division_by_zero` | L | 0 | **2** | `:3:23:` — caret lands on `n`, the zero divisor (verified against fixture source: `println (debug (10 / n))`, col 23 = `n`) |
| | A | 0 | **2** | `run --json` now emits `code:"E-DIV-ZERO"`, `kind:"error"`, real `range` — meets the clarified A=2 bar; `fix`-lessness is scored on F, not A |
| `modulo_by_zero` | L | 0 | **2** | `:3:23:` — caret on `d`, the zero modulus |
| | A | 0 | **2** | same shape: `E-MOD-ZERO`, code+kind+range |
| `list_index_oob` | L | 0 | **2** | `:3:22:` — caret on the `10` index literal itself |
| | A | 0 | **2** | `E-INDEX-OOB`, code+kind+range; message still doesn't name the list's actual length (F stays 0) |
| `explicit_panic` | L | 0 | **2** | `:2:37:` — caret on the panic-message string literal (the exact `panic "user not found"` call site, not a downstream victim like the `main` call site) |
| | A | 0 | **2** | `E-PANIC`, code+kind+range |
| `let_else_fail` | L | 0 | **2** | `:3:42:` — caret on the panic-message string literal in the `else panic "empty list"` clause |
| | A | 0 | **2** | same: `E-PANIC`, code+kind+range |
| `runtime_nonexhaustive` | L | 0 | **2** | `:1:29:` — caret on `7`, the match scrutinee |
| | A | 2 | 2 (unchanged) | already A=2 via the `check --json` `W-NONEXHAUSTIVE` compile-time path; the new `run --json` path emits the same code+kind+range shape, fully consistent with the clarified rubric |

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
| `division_by_zero` | 2 | 2 | 2 | 0 | 2 | 2 | 2 | 8 | **12** |
| `modulo_by_zero` | 2 | 2 | 2 | 0 | 2 | 2 | 2 | 8 | **12** |
| `list_index_oob` | 2 | 2 | 2 | 0 | 2 | 2 | 2 | 8 | **12** |
| `explicit_panic` | 2 | 2 | 2 | 0 | 2 | 2 | 2 | 8 | **12** |
| `let_else_fail` | 2 | 2 | 2 | 0 | 2 | 2 | 2 | 8 | **12** |
| `runtime_nonexhaustive` | 2 | 2 | 2 | 0 | 2 | 2 | 2 | 10 | **12** |

Each of the first 5 gains **+4** (L 0→2, A 0→2); `runtime_nonexhaustive` gains
**+2** (L only, its A was already 2). All six now land at **12/14**, held off a
perfect score only by **F=0** (no mechanical fix for a runtime error).

### Eval-stage arithmetic

```
old eval sum = 8*5 + 10 = 50   (6 fixtures, avg 8.33)
new eval sum = 12*6 = 72        (6 fixtures)
72 / 6 = 12.00
```

**eval: 8.33 → 12.00 (+3.67)** — the largest single-session per-stage gain in
this file's history (previously the lex-stage +4.75 jump was the largest, but
off a smaller stage-avg base). `eval` moves from the corpus's **weakest**
stage to tied with `effect` (12.00), behind only `resolve` (12.91), and now
above `typecheck` (11.54), `parse` (11.00), `exhaust` (9.60), and `build`
(9.33).

### Corpus arithmetic

```
747   (prior corpus sum, 67 fixtures — "post-F5 + line-fix" baseline)
- 50  (old sum of the 6 eval fixtures, already inside 747)
+ 72  (their new sum)
= 769
67 fixtures (unchanged — no fixtures added or removed)

769 / 67 = 11.477... ≈ 11.48
```

**Overall average: 769 / 67 = 11.48 / 14 — up from 11.15 (+0.33).**

### Per-dimension movement (67 fixtures)

Only **L** and **A** move this session (C/R/F/J/X untouched — no fixture
outside the 6 changed on any other axis). Baseline sums for L/A read off the
67-fixture "post-F5 + line-fix" corpus (established by the Haskell-hints
session): L sum 92 (avg 1.37), A sum 110 (avg 1.64).

- **L delta = +12**: all 6 eval fixtures move 0→2 (+2 each × 6 = +12).
  New L sum: 92 + 12 = **104**, new avg 104/67 = **1.55** (+0.18).
- **A delta = +10**: the first 5 fixtures move 0→2 (+2 each × 5 = +10);
  `runtime_nonexhaustive`'s A was already 2 and doesn't move. New A sum:
  110 + 10 = **120**, new avg 120/67 = **1.79** (+0.15).

| dim | old sum | old avg | new sum | new avg | Δ |
|---|---|---|---|---|---|
| L Located | 92 | 1.37 | **104** | **1.55** | +0.18 |
| A Agent-parseable | 110 | 1.64 | **120** | **1.79** | +0.15 |
| C/R/F/J/X | — | — | — | — | +0.00 (unchanged) |

### Remaining floor

- **F (Actionable-fix) is still the corpus's single weakest axis by a wide
  margin** and this session does not move it at all — none of the 6 eval
  fixtures gained a suggested edit; there simply isn't a mechanical one for
  "division by zero" or "index N out of bounds" (a possible future win: name
  the list's actual length in `E-INDEX-OOB`'s message, which would be a real,
  cheap **F 0→1** improvement, though still not a machine `fix`).
- **A now reaches 2 for all 6 eval fixtures** (per the clarified rubric: A=2 =
  code+kind+span, `fix` decoupled to F). The eval cluster is no longer an A
  drag; A's corpus average rose 1.64 → 1.79. The remaining A<2 fixtures are
  the non-eval structural holes (silent accepts + the build-only failure, see
  below), not the runtime-error cluster.
- **The `typecheck/`-framing F=0 reservoir is untouched**
  (`apply_non_function`, `if_branch_mismatch`, `list_heterogeneous`,
  `cons_type_mismatch`, `arg_order_swapped`, `wrong_arg_type_in_map`) — not
  in scope for this session.
- **`main_takes_unit` (build-only, total 3) and the 2 silent accepts**
  (`ambiguous_return`, `redundant_arm`, total 4 each) remain the corpus's
  absolute floor, untouched — none are `eval`/`run`-path runtime errors, so
  this workstream's fix doesn't reach them.

---

## Re-grade (post-Batch-B actionable-fixes, base `295f263b`)

Base confirmed: `git merge-base --is-ancestor 295f263b HEAD` → `BASE_OK`.
Docs-only re-grade — no compiler source touched. Starting point is the prior
corpus state (`769 / 67 = 11.48`, the "post-eval-runtime-JSON" section above).
This session re-scores exactly the **6 `typecheck/` fixtures** that make up
the "Tier-3 typecheck-framing F=0 reservoir" flagged as untouched in every
prior session: `apply_non_function`, `if_branch_mismatch`,
`list_heterogeneous`, `cons_type_mismatch`, `wrong_arg_type_in_map`,
`arg_order_swapped`. All other 61 fixtures are unchanged and keep their
prior scores.

**What changed**, verified against the committed `.out` goldens and spot-checked
on a freshly built binary (`./medaka check` + `./medaka check --json`), byte-
identical to the goldens in both text and JSON shape:

- **Batch A — 4 fixtures gained a help-only hint appended to the primary
  message** (`apply_non_function`, `if_branch_mismatch`, `list_heterogeneous`,
  `cons_type_mismatch`). Each `.out` now ends with ` — <concrete direction>`
  (e.g. `cons_type_mismatch`: `… — the head's type must match the list's
  elements; change the head to String, or use a list of Int.`). Confirmed via
  `--json`: the `help` field is populated, but there is **no `fix`** field —
  the hint names two alternative edits (either side could change), not one
  mechanical location+replacement. This is a concrete-direction hint, not an
  applicable edit: **F 0→1** for all four, no other dim moves (C/R/J/X/A/L
  were already at their post-Tier-3 ceiling for these four).
- **`wrong_arg_type_in_map`** — primary message rewritten from the raw-tyvar
  leak `Type mismatch: a b vs String` to `'map' expects a container (like
  List or Array) here, but got String — pass a List or Array; to work over a
  string's characters, convert it with \`string.toChars\` first.` Verified via
  `--json`: `help` populated, no `fix` field (same "concrete direction, not a
  single mechanical edit" shape as Batch A — two options are offered: pass a
  container, or convert the string first). This is a genuine reframe, not just
  an appended hint, and it lifts four dims: **C 1→2** (states the real
  container-vs-scalar fact instead of an opaque type-application),
  **R 0→2** (points exactly at what's wrong — `map`'s first-arg expectation —
  instead of naming an internal type variable), **J 1→2** (the `a b` leak is
  gone; the message is now built entirely from surface vocabulary), **F 0→1**
  (concrete direction, no machine fix). X and A were already 2 (cascade
  suppressed in the earlier Tier-3 pass; JSON already carried code+kind+span).
- **`arg_order_swapped`** — the prior TWO diagnostics (`Type mismatch: Int vs
  String` at the call site + a second `Type mismatch: Int literal vs String`
  for the transposed argument) collapse to **ONE**: `arguments to 'greet'
  look swapped — try 'greet "Alice" 3'.` Verified via `--json`: exactly one
  diagnostic object, and it now carries a real machine **`fix`**
  (`{"range":{"start":{"line":2,"character":22},"end":{"line":2,"character":31}},"replacement":"\"Alice\" 3"}`)
  that performs the actual swap. This lifts two dims: **X 1→2** (two
  call-site diagnostics collapse to one — the pair was never a cascade
  artifact per the prior grading note, but it *was* two separate messages for
  one root fact, and now it's one), **F 0→2** (a real applicable edit — the
  rubric's F=2 anchor, "an edit an agent could apply verbatim" — not just a
  named direction). C/R were already 2 (both diagnostics were independently
  correct pre-session); A stays 2 — **per the clarified A/F split, the
  machine `fix` is scored under F, not A**, so A does not move a second time
  for the same evidence.

### Per-fixture re-score

| fixture | dim | old | new | why |
|---|---|---|---|---|
| `apply_non_function` | F | 0 | **1** | help hint appended: "'n' is a value, not a function; remove the argument, or call a function here." Concrete direction, no machine `fix` |
| `if_branch_mismatch` | F | 0 | **1** | help hint: "change the else branch to Int, or the then branch to String." |
| `list_heterogeneous` | F | 0 | **1** | help hint: "convert the String element, or make the list hold String." |
| `cons_type_mismatch` | F | 0 | **1** | help hint: "change the head to String, or use a list of Int." |
| `wrong_arg_type_in_map` | C | 1 | **2** | reframed from raw-tyvar symptom to the real container-vs-scalar fact |
| `wrong_arg_type_in_map` | R | 0 | **2** | now names exactly what's wrong (`map` expects a container) instead of an internal type variable |
| `wrong_arg_type_in_map` | J | 1 | **2** | `a b` tyvar leak is gone; all surface vocabulary |
| `wrong_arg_type_in_map` | F | 0 | **1** | help hint: two concrete directions (pass a container, or `string.toChars` first), no mechanical fix |
| `arg_order_swapped` | X | 1 | **2** | two call-site diagnostics collapse to one unified "arguments look swapped" message |
| `arg_order_swapped` | F | 0 | **2** | real machine `fix` performing the swap — an applicable edit, not just a direction |

### New per-fixture totals

| fixture | L | C | R | F | J | X | A | old total | new total |
|---|---|---|---|---|---|---|---|---|---|
| `apply_non_function` | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 12 | **13** |
| `if_branch_mismatch` | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 12 | **13** |
| `list_heterogeneous` | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 12 | **13** |
| `cons_type_mismatch` | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 12 | **13** |
| `wrong_arg_type_in_map` | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 8 | **13** |
| `arg_order_swapped` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 11 | **14** |

`arg_order_swapped` is now the corpus's newest **perfect 14/14** fixture (a
real machine fix plus a single, correct, jargon-free, located diagnostic).
The other five all reach 13, held off perfect only by **F=1** (a help-only
hint, not a mechanical edit — genuinely correct: none of the four Batch-A
messages, nor `wrong_arg_type_in_map`'s, name a *single* unambiguous edit;
each offers two valid alternative fixes, which is why F stops at 1 and not 2
per the rubric's own anchor text).

### Arithmetic

```
old sum (6 fixtures) = 12+12+12+12+8+11 = 67
new sum (6 fixtures) = 13+13+13+13+13+14 = 79
delta = +12
```

Per-dimension delta, cross-checked against the per-fixture table above:
- F: +1 (apply_non_function) +1 (if_branch_mismatch) +1 (list_heterogeneous)
  +1 (cons_type_mismatch) +1 (wrong_arg_type_in_map) +2 (arg_order_swapped)
  = **+7**
- C: +1 (wrong_arg_type_in_map only) = **+1**
- R: +2 (wrong_arg_type_in_map only) = **+2**
- J: +1 (wrong_arg_type_in_map only) = **+1**
- X: +1 (arg_order_swapped only) = **+1**
- L, A: unchanged (+0 each)

Sum of dimension deltas: 7+1+2+1+1 = **12** — matches the fixture-sum delta
exactly (sanity check passes).

### Typecheck-stage average

```
prior typecheck sum = 277 (24 fixtures, avg 11.54 — "post-F-axis" baseline,
                            unmoved by the intervening parse/lex/eval sessions)
new typecheck sum = 277 + 12 = 289
289 / 24 = 12.0417 ≈ 12.04
```

**typecheck: 11.54 → 12.04 (+0.50)** — typecheck moves up but stays
**2nd-strongest**, behind `resolve` (12.91), and now edges just past
`effect`/`eval` (both 12.00). All other 7 stages are unchanged (this session
touched only these 6 `typecheck/` fixtures).

### Corpus arithmetic

```
769  (prior corpus sum, 67 fixtures — "post-eval-runtime-JSON" baseline)
- 67 (old sum of the 6 typecheck fixtures, already inside 769)
+ 79 (their new sum)
= 781
67 fixtures (unchanged — no fixtures added or removed)

781 / 67 = 11.6567... ≈ 11.66
```

**Overall average: 781 / 67 = 11.66 / 14 — up from 11.48 (+0.18).**

### Per-dimension movement (67 fixtures)

Prior full-corpus sums (reconstructed from the "post-eval-runtime-JSON"
session's stated deltas over the "post-F-axis" 63-fixture sums, plus the +4
Haskell fixtures at 14/14 each): L=112, C=118, R=115, F=39, J=131, X=126,
A=128 (sum check: 112+118+115+39+131+126+128 = 769, matches).

| dim | old sum | old avg | new sum | new avg | Δ |
|---|---|---|---|---|---|
| F Actionable-fix | 39 | 0.58 | **46** | **0.69** | **+0.10** |
| R Root-cause | 115 | 1.72 | **117** | **1.75** | +0.03 |
| C Correct | 118 | 1.76 | **119** | **1.78** | +0.01 |
| J Jargon-free | 131 | 1.96 | **132** | **1.97** | +0.01 |
| X Cascade-free | 126 | 1.88 | **127** | **1.90** | +0.01 |
| L Located | 112 | 1.67 | 112 | 1.67 | +0.00 |
| A Agent-parseable | 128 | 1.91 | 128 | 1.91 | +0.00 |

**F moves the most** — still the corpus's weakest axis by a wide margin
(0.69/2), but this session's the second-largest single-session F lift in the
file's history (after the post-F-axis session's +0.14), and the first time a
whole `typecheck/`-framing reservoir session has moved F at all (Tier-3
explicitly did not — see its "What's still weakest" note above).

### Remaining floor (honest)

- **F (0.69/2) is still the single weakest axis in the corpus**, even after
  this session's targeted push. The 5 non-`arg_order_swapped` fixtures here
  land at F=1 (a genuine ceiling, not an oversight): each offers **two**
  structurally valid alternative edits ("change the head to String, *or* use
  a list of Int") rather than one unambiguous mechanical fix, so none crosses
  the F=2 bar honestly. Closing that gap further would need the diagnostic to
  pick one canonical direction (e.g. always suggest coercing the *later*/
  *minority* element) and emit it as a machine `fix` — a real design
  decision, not a docs change, and out of scope here.
- **The absolute floor is untouched by this session**: `main_takes_unit`
  (build-only, total 3) and the 2 silent accepts (`ambiguous_return`,
  `redundant_arm`, total 4 each) remain the corpus's lowest-scoring fixtures.
  None of the three are `typecheck/`-framing fixtures — `main_takes_unit` is a
  `build`-only emitter failure, `ambiguous_return`/`redundant_arm` emit no
  diagnostic at all — so this session's fixes, scoped entirely to existing
  `check`-path type-mismatch messages, structurally cannot reach them.
- **`wrong_arg_type_in_map` and `arg_order_swapped`** were, before this
  session, respectively the corpus's and the `typecheck` stage's own local
  minima among non-silent/non-build fixtures (8 and 11). Both are now firmly
  mid/high-pack (13, 14) — this was the targeted fix, and it landed cleanly.
- **A remains capped at 2, never higher** — reconfirms the clarified rubric
  reading is being applied consistently: `arg_order_swapped`'s new machine
  `fix` is real evidence of quality, but it is credited entirely to F, so A
  does not inflate a second time off the same JSON field.

---

## Re-grade (post-actionable-fix-hints-sweep, base `7900bfc`)

Base confirmed: `git merge-base --is-ancestor 7900bfc HEAD` → `BASE_OK`.
Docs-only re-grade — no compiler source touched. Starting point is the prior
corpus state (`781 / 67 = 11.66`, the "post-Batch-B actionable-fixes" section
above). Corpus fixture count re-verified directly (not assumed): `find
test/error_quality_fixtures -maxdepth 2 -name '*.mdk' | wc -l` = 68, minus
`parse/hs_syntax_guard_valid` (a valid-code guard fixture, exit 0, not
scored/counted — same exclusion as every prior session) = **67**, unchanged
from the prior session's denominator.

This session re-scores **9 fixtures** that gained a new `— <hint>` suffix on
their primary message: the 4 `exhaust/nonexhaustive_*`, `eval/eval/
runtime_nonexhaustive` (checked, unaffected — see below), `typecheck/
missing_instance`, `typecheck/eq_undesugared_adt`, `typecheck/
lt_undesugared_adt`, and `resolve/unknown_module`. All other 58 fixtures are
unchanged and keep their prior scores. `typecheck/eq_on_function` and
`typecheck/lt_on_function` were checked and confirmed **unaffected** — their
`.out` goldens are byte-identical to before (function types can't `deriving`,
so the hint machinery doesn't fire there), matching the task brief.

**What changed**, verified against the committed `.out`/`.json.out` goldens
and spot-checked on a freshly built binary (`./medaka check` + `./medaka
check --json`), byte-identical to the goldens in both text and JSON shape:

1. **Non-exhaustive-match witness edit** (`exhaust/nonexhaustive_{option,
   bool,list,custom}`) — the warning now appends the exact uncovered arm as a
   literal, ready-to-paste edit: `… missing case: 'None' — add a 'None => …'
   arm, or a '_' wildcard arm to catch the rest.` Confirmed via `--json`
   (`warning_nonexhaustive.check_json.golden`): a new `help` field carries the
   same suffix; still **no** `fix` field (there's no single source *span* to
   replace — the edit is "insert a new arm", not "replace this text"). Per
   the task brief's explicit anchor ("witness-based edit... justifies F=2")
   this crosses the F=2 bar: it names the *exact* arm to add, not just a
   direction, matching the precedent set by `else_let_block`/`hs_lambda` (F=2
   granted on a literal rewrite embedded in prose, no JSON `fix` required).
   `eval/runtime_nonexhaustive` was explicitly checked (its `.out` is
   `runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match`, byte-
   identical to its prior golden) — it did **not** gain the witness hint (the
   runtime path doesn't have the compile-time exhaustiveness checker's arm
   inventory available at the panic site), so it is graded as-is: **no
   change**, stays at its current **12**.
2. **Missing-impl hint** (`typecheck/missing_instance`,
   `typecheck/eq_undesugared_adt`, `typecheck/lt_undesugared_adt`) — each
   `No impl of <Class> for <Type>` now appends ` — add 'deriving <Class>' to
   the '<Type>' type, or write an 'impl <Class> <Type>'.` Confirmed via
   `--json` (`no_impl.check_json.golden`): a new `help` field, no `fix` (two
   valid alternative edits — derive or hand-write an impl — not one
   mechanical replacement). This is a **concrete direction**, not a single
   applicable edit (mirrors the `arg_order_swapped`-adjacent Batch-A anchor:
   two valid alternatives caps F at 1, not 2): **F 0→1** for all three.
   `typecheck/eq_on_function`/`lt_on_function` (the function-type variant of
   this same no-impl path) were spot-checked and are **unchanged** — deriving
   doesn't apply to a function type, so no hint fires there, consistent with
   the task brief's carve-out.
3. **Unknown-module direction** (`resolve/unknown_module`) — now appends
   ` — available modules: array, async, …, validation` (the full sorted list
   of importable module names). This is a concrete direction (an agent or
   user can grep the list for the intended name) but **not** a single
   applicable edit or near-typo suggestion (`collections` has no near-match
   in the list — unlike the did-you-mean cases that reach F=2): **F 0→1**.

### Per-fixture re-score

| fixture | dim | old | new | why |
|---|---|---|---|---|
| `nonexhaustive_option` | F | 1 | **2** | now embeds the literal missing arm `'None => …'` — a ready-to-paste edit, not just a named case |
| `nonexhaustive_bool` | F | 1 | **2** | embeds `'False => …'` |
| `nonexhaustive_list` | F | 1 | **2** | embeds `'[] => …'` |
| `nonexhaustive_custom` | F | 1 | **2** | embeds `'Triangle _ => …'` |
| `missing_instance` | F | 0 | **1** | concrete direction ("add 'deriving Eq'... or write an 'impl Eq Color'") — two valid alternatives, not one mechanical edit, so F stops at 1 |
| `eq_undesugared_adt` | F | 0 | **1** | same shape, `deriving Eq`/`impl Eq Color` |
| `lt_undesugared_adt` | F | 0 | **1** | same shape, `deriving Ord`/`impl Ord Color` |
| `unknown_module` | F | 0 | **1** | concrete direction (module list to search), no near-typo match to name a single replacement |

No other dimension moved for any of these 8 — L/C/R/J/X/A were already at
their post-Batch-B ceiling (all 8 already had a real, located, single,
correct, jargon-free, `code`+`kind`+span JSON diagnostic; only the message
text grew a suffix and a `help` field, which is exactly what dimension F
measures).

### New per-fixture totals

| fixture | L | C | R | F | J | X | A | old total | new total |
|---|---|---|---|---|---|---|---|---|---|
| `nonexhaustive_option` | 0 | 2 | 2 | 2 | 2 | 2 | 2 | 11 | **12** |
| `nonexhaustive_bool` | 0 | 2 | 2 | 2 | 2 | 2 | 2 | 11 | **12** |
| `nonexhaustive_list` | 0 | 2 | 2 | 2 | 2 | 2 | 2 | 11 | **12** |
| `nonexhaustive_custom` | 0 | 2 | 2 | 2 | 2 | 2 | 2 | 11 | **12** |
| `missing_instance` | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 12 | **13** |
| `eq_undesugared_adt` | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 12 | **13** |
| `lt_undesugared_adt` | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 12 | **13** |
| `unknown_module` | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 12 | **13** |

`runtime_nonexhaustive` (eval, unaffected): stays **12** (unchanged).

### Arithmetic

```
old sum (8 fixtures) = 11+11+11+11+12+12+12+12 = 92
new sum (8 fixtures) = 12+12+12+12+13+13+13+13 = 100
delta = +8
```

Per-dimension delta: **F: +8** (4×+1 nonexhaustive, 4×+1 missing-impl/module)
— every other dimension: +0. Sanity check: sum of deltas (8) matches the
fixture-sum delta (8) exactly.

### Corpus arithmetic

```
781   (prior corpus sum, 67 fixtures — "post-Batch-B" baseline)
- 92  (old sum of the 8 changed fixtures, already inside 781)
+ 100 (their new sum)
= 789
67 fixtures (unchanged — no fixtures added or removed this session)

789 / 67 = 11.7761... ≈ 11.78
```

**Overall average: 789 / 67 = 11.78 / 14 — up from 11.66 (+0.12).**

### Per-stage averages

```
exhaust: prior sum 48 (5 fixtures, avg 9.60) + 4 (the 4 nonexhaustive, +1 each)
         = 52 / 5 = 10.40                                    (+0.80)
typecheck: prior sum 289 (24 fixtures, avg 12.04) + 3 (missing_instance,
         eq_undesugared_adt, lt_undesugared_adt, +1 each)
         = 292 / 24 = 12.1667 ≈ 12.17                          (+0.13)
resolve: prior sum 142 (11 fixtures, avg 12.91 — unchanged since the
         "F-axis" session; no later session touched resolve/) + 1
         (unknown_module 12→13) = 143 / 11 = 13.00              (+0.09)
eval: unchanged, sum 72 / 6 = 12.00                              (+0.00)
```

| stage | fixtures | prior avg | new avg | Δ |
|---|---|---|---|---|
| effect | 3 | 12.00 | 12.00 | — |
| **resolve** | 11 | 12.91 | **13.00** | +0.09 |
| lex | 4 | 11.25 | 11.25 | — |
| **typecheck** | 24 | 12.04 | **12.17** | +0.13 |
| **exhaust** | 5 | 9.60 | **10.40** | +0.80 |
| build | 3 | 9.33 | 9.33 | — |
| parse | 11 | 11.00 | 11.00 | — |
| eval | 6 | 12.00 | 12.00 | — |

`resolve` remains the corpus's strongest stage; `exhaust` gets this session's
largest per-stage jump (+0.80) but, at 10.40, is still below the 11-ish
mid-pack band — its F-axis gain (witness-edit F=2) is real but exhaust's `L`
dimension is still stuck at 0 for all 4 nonexhaustive fixtures (the warning
still carries no *displayed* source location in the CLI text, even though its
JSON `range` is real — the L dimension per this file's convention grades the
human-readable message, which still lacks a `file:L:C:` prefix).

### Per-dimension movement (67 fixtures)

Only **F** moves this session — every other dimension is untouched (no
fixture's location, correctness, root-cause framing, jargon, cascade count,
or JSON code/kind/span changed; only the message text grew a hint suffix,
which is exactly what F measures).

```
prior F sum (67 fixtures, post-Batch-B) = 46, avg 0.69
new F sum = 46 + 8 = 54
54 / 67 = 0.806 ≈ 0.81
```

| dim | prior sum | prior avg | new sum | new avg /2 | Δ |
|---|---|---|---|---|---|
| **F** Actionable-fix | 46 | 0.69 | **54** | **0.81** | **+0.12** |
| L Located | 112 | 1.67 | 112 | 1.67 | +0.00 |
| C Correct | 119 | 1.78 | 119 | 1.78 | +0.00 |
| R Root-cause | 117 | 1.75 | 117 | 1.75 | +0.00 |
| J Jargon-free | 132 | 1.97 | 132 | 1.97 | +0.00 |
| X Cascade-free | 127 | 1.90 | 127 | 1.90 | +0.00 |
| A Agent-parseable | 128 | 1.91 | 128 | 1.91 | +0.00 |

### Honest remaining floor

- **F (0.81/2) is still the single weakest axis in the corpus by a wide
  margin.** This session moved it the most of any dimension (as it has every
  session since Tier-4), but 4 of the 8 moved fixtures land only at **F=1**
  (a genuine ceiling: `missing_instance`/`eq_undesugared_adt`/
  `lt_undesugared_adt`/`unknown_module` each offer **two** valid alternatives
  — derive-or-hand-write-an-impl, or "pick a name from this list" — not one
  unambiguous mechanical edit, so none crosses F=2 honestly). Only the 4
  nonexhaustive fixtures reach F=2, because a missing-arm witness names one
  exact, unambiguous insertion.
- **The Tier-3-framing F=1 residual is untouched by this session**
  (`apply_non_function`, `if_branch_mismatch`, `list_heterogeneous`,
  `cons_type_mismatch`, `wrong_arg_type_in_map`, all still F=1 from
  Batch-B — two-alternative help hints, same ceiling as this session's
  missing-impl/unknown-module fixtures).
- **The absolute floor is unchanged**: `main_takes_unit` (build-only,
  total 3) and the 2 silent accepts (`ambiguous_return`, `redundant_arm`,
  total 4 each) remain the corpus's lowest-scoring fixtures — none of the
  three are affected by this sweep (missing-impl/no-impl hints only fire on a
  real diagnostic, and these three emit none).
- **`bad_escape` (12) and the generic-`Parse error` fixtures (8 each,
  `if_missing_then`/`unclosed_paren`/`trailing_operator`/
  `reserved_word_binding`) remain F=0**, untouched by every hint-adding
  session so far — they're outside this sweep's scope (lex/generic-parse, not
  exhaust/typecheck-no-impl/resolve-module).
- **Exhaust's `L` dimension (0/2, all 4 nonexhaustive fixtures)** is the
  stage's own remaining floor: the warning text still carries no
  `file:L:C:` prefix in the human-readable `.out`, even though the JSON
  `range` is real (scored under A, not L, per this file's location-vs-JSON
  split) — a genuine next lever for the exhaust stage specifically.

## Session: non-exhaustive-match warnings gain `file:L:C:` + caret (2026-07-04)

`compiler/driver/medaka_cli.mdk` now prints the non-exhaustive-match warning
with a real `file:L:C:` prefix and a source-line caret, same shape as an
error, e.g.:

```
test/error_quality_fixtures/exhaust/nonexhaustive_option.mdk:3:12: non-exhaustive match of 'Option' — missing case: 'None' — add a 'None => …' arm, or a '_' wildcard arm to catch the rest.
  |
3 |   Some x => x
  |             ^
```

(was the loc-free `Warning: non-exhaustive match of 'Option' — …`). Verified
against all 4 committed `.out` goldens
(`test/error_quality_fixtures/exhaust/nonexhaustive_{option,bool,list,custom}.out`)
— each now carries the located, captioned prefix. Nothing else in the message
changed: same missing-case name, same embedded-arm hint, same exit code (0).

### Per-fixture re-score

| fixture | dim | old | new | why |
|---|---|---|---|---|
| `nonexhaustive_option` | L | 0 | **2** | real `file:L:C:` prefix + caret on the scrutinee's last arm, `:3:12:` |
| `nonexhaustive_bool` | L | 0 | **2** | `:3:14:` |
| `nonexhaustive_list` | L | 0 | **2** | `:3:15:` |
| `nonexhaustive_custom` | L | 0 | **2** | `:5:14:` |

No other dimension moves for any of the 4: C/R/F/J/X/A were already at
ceiling (2 each) from the prior actionable-fix session — only the human text
grew a location prefix + caret, which is exactly what L measures. Confirmed
by reading all 4 `.out` files directly; `redundant_arm` (still no diagnostic
at all, exit 0) and `runtime_nonexhaustive` (eval path, unaffected — its
`.out` is byte-identical, still `file:L:C: runtime error [E-NONEXHAUSTIVE-MATCH]:
non-exhaustive match`, already located from an earlier session) do not move.

### New per-fixture totals

| fixture | L | C | R | F | J | X | A | old total | new total |
|---|---|---|---|---|---|---|---|---|---|
| `nonexhaustive_option` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 12 | **14** |
| `nonexhaustive_bool` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 12 | **14** |
| `nonexhaustive_list` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 12 | **14** |
| `nonexhaustive_custom` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 12 | **14** |

All 4 are now **perfect 14/14** fixtures. `redundant_arm` stays **4**;
`runtime_nonexhaustive` stays **12** (both unaffected).

### Arithmetic

```
old sum (4 fixtures) = 12+12+12+12 = 48
new sum (4 fixtures) = 14+14+14+14 = 56
delta = +8   (4 fixtures × +2, L-dimension only)
```

### Stage arithmetic (exhaust)

```
prior exhaust sum = 52 (5 fixtures: 4×12 nonexhaustive + 1×4 redundant_arm), avg 10.40
new exhaust sum    = 52 + 8 = 60 (4×14 + 1×4)
60 / 5 = 12.00                                                  (+1.60)
```

| stage | fixtures | prior avg | new avg | Δ |
|---|---|---|---|---|
| **exhaust** | 5 | 10.40 | **12.00** | **+1.60** |

`exhaust` moves from the corpus's weakest stage to tied with `effect`
(12.00) — the largest single-session per-stage jump recorded in this file to
date, entirely from closing the last open dimension (L) on 4 already-strong
fixtures.

### Corpus arithmetic

```
789   (prior corpus sum, 67 fixtures)
+  8  (4 nonexhaustive fixtures, +2 each — L only)
= 797
67 fixtures (unchanged — no fixtures added or removed this session)

797 / 67 = 11.9004... ≈ 11.90
```

**Overall average: 797 / 67 = 11.90 / 14 — up from 11.78 (+0.12).**

### Per-dimension movement (67 fixtures)

Only **L** moves this session.

```
prior L sum = 112, avg 1.67
new L sum   = 112 + 8 = 120
120 / 67 = 1.791 ≈ 1.79                                          (+0.12)
```

| dim | prior sum | prior avg | new sum | new avg | Δ |
|---|---|---|---|---|---|
| **L** Located | 112 | 1.67 | **120** | **1.79** | **+0.12** |
| C Correct | 119 | 1.78 | 119 | 1.78 | +0.00 |
| R Root-cause | 117 | 1.75 | 117 | 1.75 | +0.00 |
| F Actionable-fix | 54 | 0.81 | 54 | 0.81 | +0.00 |
| J Jargon-free | 132 | 1.97 | 132 | 1.97 | +0.00 |
| X Cascade-free | 127 | 1.90 | 127 | 1.90 | +0.00 |
| A Agent-parseable | 128 | 1.91 | 128 | 1.91 | +0.00 |

### Honest remaining floor

- **F (0.81/2) remains the single weakest axis in the corpus by a wide
  margin**, untouched by this session — this was a pure-location fix, not an
  actionable-fix change. The Tier-3-framing F=1 residual and the
  two-alternative-hint F=1 fixtures (`missing_instance`,
  `eq_undesugared_adt`, `lt_undesugared_adt`, `unknown_module`,
  `apply_non_function`, `if_branch_mismatch`, `list_heterogeneous`,
  `cons_type_mismatch`, `wrong_arg_type_in_map`) are all unchanged.
- **The absolute floor is unchanged**: `main_takes_unit` (build-only, total
  3) and the 2 silent accepts (`ambiguous_return`, total 4; `redundant_arm`,
  total 4, exhaust stage) remain the corpus's lowest-scoring fixtures — none
  of the three emit any diagnostic for this session's located-warning fix to
  touch.
- **`redundant_arm` is now `exhaust`'s own floor** (was tied with the other 4
  at 8 pre-Batch-B; now the other 4 are 14/14 and `redundant_arm` alone drags
  the stage average down from a hypothetical 14.00 to 12.00) — unreachable-arm
  detection is still wholly unimplemented (exit 0, no diagnostic).
- **No non-exhaustive-match diagnostic is unlocated anymore.** Before this
  session, `runtime_nonexhaustive` (the `medaka run` / eval-path error) was
  already located (`L=2`, fixed in an earlier session) while the 4
  `check`-path warnings were not; this session closes that last gap, so
  every non-exhaustive-match diagnostic in the corpus — compile-time warning
  or runtime error — now carries a real `file:L:C:` prefix and caret. There
  is no "lone unlocated non-exhaustive case" left; the honest remaining gap
  for non-exhaustive-match is purely on the **F** axis for
  `runtime_nonexhaustive` (F=0 — the runtime error doesn't name the missing
  arm the way the compile-time warning now does) and on **detection** for
  `redundant_arm` (no diagnostic at all).

## Re-grade: `redundant_arm` gains a diagnostic (`W-UNREACHABLE-ARM`, 2026-07-04)

`compiler/frontend/exhaust.mdk` + `compiler/types/typecheck.mdk` now detect an
unreachable match arm and emit a located, coded warning. Verified against the
committed golden `test/error_quality_fixtures/exhaust/redundant_arm.out` and a
fresh `medaka check --json` run on this branch:

```
test/error_quality_fixtures/exhaust/redundant_arm.mdk:4:12: unreachable match arm — this pattern is already covered by an earlier arm
  |
4 |   0 => "zero"
  |             ^
```
```json
{"code":"W-UNREACHABLE-ARM","kind":"warning","message":"unreachable match arm — this pattern is already covered by an earlier arm","range":{"end":{"character":13,"line":3},"start":{"character":12,"line":3}},"severity":2,"source":"medaka"}
```

(was: exit 0, completely silent — no diagnostic at all, scored **4** as a
silent accept.)

### Per-dimension re-score

| dim | old | new | why |
|---|---|---|---|
| **L** Located | 0 | **2** | real `file:L:C:` prefix (`:4:12:`) + source-line caret on the redundant `0` pattern |
| **C** Correct | 0 | **2** | correctly identifies the exact redundant arm and its exact location — no false positive, no missed cascade |
| **R** Root-cause | 0 | **2** | names the actual mechanism ("this pattern is already covered by an earlier arm"), not just "there's a problem here" |
| **F** Actionable-fix | 0 | **1** | states the redundancy relationship, which points clearly at *what's wrong* (this arm can never fire), but stops short of a concrete suggested edit — no "remove this arm" / "move it above the wildcard" text and no machine `fix` in JSON. Same tier as the corpus's other implied-but-not-spelled-out fixes; short of the `nonexhaustive_*` fixtures' F=2, which embed a literal ready-to-paste arm |
| **J** Jargon-free | 2 | 2 | unchanged — plain English, no internal terms, no raw tyvar |
| **X** Cascade-free | 2 | 2 | unchanged — exactly one diagnostic, no follow-on storm |
| **A** Agent-parseable | 0 | **2** | JSON carries a stable `code` (`W-UNREACHABLE-ARM`), `kind` (`warning`), and a real span (`{3,12}-{3,13}`, not the old dummy `{0,0}`) — meets the rubric's A=2 bar (§3: "JSON with stable `code`, `kind`, and span") |

**New total: 4 → 13 / 14** (+9). `redundant_arm` moves from the corpus's
weakest exhaust fixture (tied-worst silent accept) to just one point off a
perfect score — matching the shape of the `nonexhaustive_*` fixtures' prior
jump, minus the one point F stops short of.

### Stage arithmetic (exhaust)

```
prior exhaust sum = 60 (4×14 nonexhaustive + 1×4 redundant_arm), avg 12.00
new exhaust sum    = 60 - 4 + 13 = 69 (4×14 + 1×13)
69 / 5 = 13.80                                                  (+1.80)
```

| stage | fixtures | prior avg | new avg | Δ |
|---|---|---|---|---|
| **exhaust** | 5 | 12.00 | **13.80** | **+1.80** |

`exhaust` is now the strongest stage in the corpus (previously `effect` at
12.00) and sits **near ceiling**: 4 of 5 fixtures are a perfect 14/14, and the
5th (`redundant_arm`) is 13/14 — the whole stage is now one missing
actionable-fix hint away from a perfect 14.00 average. Detection is no longer
the exhaust stage's gap; the sole residual is F-axis polish on one fixture.

### Corpus arithmetic

```
806   (new corpus sum)
=  797 (prior corpus sum, 67 fixtures)
  -  4 (redundant_arm's old score, removed)
  + 13 (redundant_arm's new score, added)
= 806
67 fixtures (unchanged — no fixtures added or removed this session)

806 / 67 = 12.0299... ≈ 12.03
```

**Overall average: 806 / 67 = 12.03 / 14 — up from 11.90 (+0.13).**

### Per-dimension movement (67 fixtures)

L, C, R, F, A all move (the 5 dims `redundant_arm` gained points on); J and X
are unchanged (already at ceiling for this fixture).

```
L: 120 + 2 = 122   → 122/67 = 1.8209 ≈ 1.82   (+0.03)
C: 119 + 2 = 121   → 121/67 = 1.8060 ≈ 1.81   (+0.03)
R: 117 + 2 = 119   → 119/67 = 1.7761 ≈ 1.78   (+0.03)
F:  54 + 1 =  55   →  55/67 = 0.8209 ≈ 0.82   (+0.01)
A: 128 + 2 = 130   → 130/67 = 1.9403 ≈ 1.94   (+0.03)
```

| dim | prior sum | prior avg | new sum | new avg | Δ |
|---|---|---|---|---|---|
| L Located | 120 | 1.79 | **122** | **1.82** | **+0.03** |
| C Correct | 119 | 1.78 | **121** | **1.81** | **+0.03** |
| R Root-cause | 117 | 1.75 | **119** | **1.78** | **+0.03** |
| **F** Actionable-fix | 54 | 0.81 | **55** | **0.82** | **+0.01** |
| J Jargon-free | 132 | 1.97 | 132 | 1.97 | +0.00 |
| X Cascade-free | 127 | 1.90 | 127 | 1.90 | +0.00 |
| **A** Agent-parseable | 128 | 1.91 | **130** | **1.94** | **+0.03** |

(Sum check: 122+121+119+55+132+127+130 = 806, matching the corpus sum above.)

### Honest remaining floor

- **F (0.82/2) remains the single weakest axis in the corpus by a wide
  margin.** This session moves it only marginally (+0.01, one fixture by one
  point) — `redundant_arm` lands at the same "names the problem, doesn't
  spell out the edit" tier as most of the corpus's other F=1 fixtures
  (`missing_instance`, `eq_undesugared_adt`, `lt_undesugared_adt`,
  `unknown_module`, the Tier-3-framing typecheck fixtures), not at the F=2
  ceiling the `nonexhaustive_*` fixtures reach by embedding a literal
  ready-to-paste arm. A future session could close this by having the
  warning suggest "remove this arm" (or a machine `fix` deleting the line) —
  the same treatment the `nonexhaustive_*` fixtures got for the *missing*-arm
  case, applied to the *extra*-arm case.
- **The absolute floor moves**: `redundant_arm` is **no longer** one of the
  corpus's silent accepts — it now scores 13/14, well above the historical
  4/14 floor. The absolute floor is now just **`main_takes_unit`**
  (build-only emitter failure, total 3) and **`ambiguous_return`** (typecheck,
  silent accept, total 4) — one fixture fewer than before this session.
- **`exhaust` is now at/near ceiling** (13.80/14, strongest stage in the
  corpus): 4/5 fixtures are a perfect 14/14, and the 5th is 13/14. The only
  lever left for this stage is the F-axis polish on `redundant_arm` noted
  above — there is no more missing-location, missing-code, or
  missing-detection gap anywhere in `exhaust/`.
- **`ambiguous_return` is now the corpus's lone typecheck-stage silent
  accept** at the historical floor (was tied with `redundant_arm`); it remains
  arguably by-design (Num-defaulting resolves `length []` without genuine
  ambiguity) and stays outside the fix hit-list per the scoring conventions
  at the top of this file.
- Every other observation from the prior session (Tier-3-framing F=1
  residual, `bad_escape`/generic-`Parse error` F=0 fixtures untouched, the
  `main_takes_unit`/build-only floor) is unaffected by this fixture-scoped
  change.
