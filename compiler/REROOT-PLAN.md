STATUS: COMPLETE — all gates re-rooted off the OCaml oracle 2026-06-13; every correctness gate is OCaml-free.

# REROOT-PLAN — taking the gate suite OFF the OCaml oracle

**Status:** PLAN (read-only analysis, 2026-06-12). Change no gates until reviewed.
**Goal:** every gate runs with NO OCaml — no `_build/default/bin/main.exe`, no
`dev/eval_probe.exe`, no `dev/*_probe.exe`, no `dune build`. OCaml `lib/`+`bin/`
stays FROZEN through a soak and is removed LATER behind a confidence gate
(retirement ≠ removal). This plan makes the gates **OCaml-free first**; it does
NOT delete `lib/`.

**Scope measured:** 83 `test/*.sh`. 82 invoke `main.exe`; 79 invoke `dune build`;
13 invoke `dev/eval_probe.exe`; 6 dev sub-probes (`astdump` ×7, `diagdump` ×8,
`tc_probe` ×4, `tc_module_probe` ×3, `lextok`/`positions_dump`/`print_probe`/
`comment_dump`/`fuzz_gen` ×1). Only 2 are already OCaml-free
(`bootstrap_from_seed.sh`, `build_native_medaka.sh`).

---

## 1. The two OCaml roles, and the single re-root lever for each

Almost every gate uses OCaml in **two independent ways at once**, which must be
re-rooted separately:

- **HOST (category C):** the gate runs a self-hosted compiler stage by feeding
  its entry `.mdk` to the OCaml interpreter — `main.exe run compiler/entries/<X>_main.mdk …args`.
  OCaml here is *merely an interpreter for Medaka source*; it contributes nothing
  to correctness, only execution. **Re-root = compile that entry ONCE to a native
  binary** (`medaka build compiler/entries/<X>_main.mdk -o bin/<X>`) and run the
  binary. `medaka build <entry> -o <out>` already produces a standalone native
  binary (confirmed: `compiler/entries/build_main.mdk` → `compiler/driver/build_cmd.mdk`
  shells the emitter+clang). This is the **bulk of the work and the bulk of the win**:
  re-rooting C removes `main.exe` AND `dune build` from ~80 scripts.

- **ORACLE (categories A/B/D):** the gate compares the stage's output against an
  OCaml-produced reference — `eval_probe.exe` (A), `main.exe build` binary output
  (B), or `main.exe check/fmt/parse/…` / a dev sub-probe (D). **Re-root = replace
  the live OCaml reference with one of the three HYBRID oracles** (§3): captured
  golden, native-interp binary, or fixpoint.

A script that is **C only** (no OCaml oracle, e.g. it diffs two self-hosted
representations, or it is itself the fixpoint) loses ALL OCaml the moment its
entry is compiled. A script that is **C+A** or **C+D** also needs an oracle swap.

### Category legend
| Cat | OCaml use | Re-root lever |
|-----|-----------|---------------|
| **A** | `eval_probe.exe` value oracle | golden capture (Phase 1) + native-interp (Phase 3) |
| **B** | `main.exe build` binary-output oracle | golden the binary's stdout, or native-build vs native-interp |
| **C** | `main.exe run <entry>` HOST | compile entry → native binary |
| **D** | `main.exe`/dev-probe front-end output oracle | golden capture, or native-compiler-probe vs golden |
| **E** | OCaml `test_*.ml`/thorough via dune | OUT OF SCOPE — deleted WITH `lib/`, gates nothing native |
| **F** | already native-only | no change |

---

## 2. Categorized inventory (script → category → re-root approach)

> "C+A" = runs a compiler entry via the OCaml host AND diffs vs eval_probe.
> Fixture counts are `find … -name '*.mdk'`. "Goldens present" = a paired
> `.golden`/`.expected`/`.sexp` already exists (so capture is a no-op or regen).

### 2a. Eval / Core-IR / LLVM value gates (eval_probe + main.exe host)
| Script | Cat | Fixtures (count) | Goldens present | Entry |
|--------|-----|------------------|-----------------|-------|
| diff_compiler_eval.sh | C+A | eval_fixtures (20) | no | eval_main |
| diff_compiler_eval_list.sh | C+A | eval_list_fixtures (2) | no | eval_prelude_main |
| diff_compiler_eval_list_batch.sh | C+A | eval_list_fixtures (2) | no | eval_list_batch |
| diff_compiler_eval_prelude.sh | C+A | eval_prelude_fixtures (5) | no | eval_prelude_main |
| diff_compiler_eval_prelude_batch.sh | C+A | eval_prelude_fixtures (5) | no | eval_prelude_batch |
| diff_compiler_eval_dict.sh | C+A | eval_dict_fixtures (24) | no | eval_dict_main |
| diff_compiler_eval_dict_batch.sh | C+A | eval_dict_fixtures (24) | no | eval_dict_batch |
| diff_compiler_eval_run.sh | C | diff_fixtures (25) | **yes (.golden)** | eval_run_main |
| diff_compiler_eval_run_batch.sh | C | diff_fixtures (25) | **yes (.golden)** | eval_run_batch |
| diff_compiler_eval_typed.sh | C+A | eval_typed_fixtures (3) | no | eval_typed_main |
| diff_compiler_eval_typed_batch.sh | C+A | eval_typed_fixtures (3) | no | eval_typed_batch |
| diff_compiler_eval_typed_modules.sh | C+A | eval_typed_modules_fixtures (1) | no | eval_typed_modules_main |
| diff_compiler_eval_modules.sh | C | eval_modules_fixtures (4) | no | eval_modules_main |
| diff_compiler_eval_errors.sh | C+D | eval_error_fixtures (9) | **yes (.expected)** | eval_main |
| diff_compiler_core_ir.sh | C+A | eval_fixtures (20) | no | core_ir_main |
| diff_compiler_core_ir_list.sh | C+A | eval_list_fixtures (2) | no | core_ir_prelude_main |
| diff_compiler_core_ir_prelude.sh | C+A | eval_prelude_fixtures (5) | no | core_ir_prelude_main |
| diff_compiler_core_ir_modules.sh | C | eval_modules_fixtures (4) | no | core_ir_modules_main |
| diff_compiler_core_ir_typed.sh | C+A | eval_typed_fixtures (3) | no | core_ir_typed_main |
| diff_compiler_core_ir_run.sh | C | diff_fixtures (25) | **yes (.golden)** | core_ir_run_main |
| diff_compiler_core_ir_roundtrip.sh | C+A | eval_fixtures (20) | no | core_ir_roundtrip_main |
| diff_compiler_core_ir_sexp.sh | C+D | core_ir_sexp_fixtures (20 .sexp) | **yes (.sexp)** | core_ir_dump_main |
| diff_compiler_llvm.sh | C+A | llvm_fixtures (180) | no | llvm_emit_main |
| diff_compiler_llvm_typed.sh | C+A | llvm_fixtures_typed (37) | no | llvm_emit_typed_main |
| diff_compiler_llvm_modules.sh | C | llvm_fixtures_modules (9) | no | llvm_emit_modules_main |

**Approach.** All A's: capture `eval_probe.exe` output per fixture into a golden
(`<name>.eval.golden`) NOW; the gate compares the (native-compiled) entry's output
to the golden. The LLVM gates are subtle: `diff_compiler_llvm.sh` runs the emitter
entry to get IR, clangs it, runs the binary, and diffs the binary's *runtime
output* vs `eval_probe` — so the golden is the **program's stdout**, not the IR
(IR is symbol-renaming-volatile; output is not — see MEMORY "Diff gates compare
OUTPUT not IR"). C-only gates (eval_run, core_ir_run, eval_modules,
core_ir_modules, llvm_modules): no oracle swap — just compile the entry; the
`.golden`-bearing ones already have a frozen reference.

### 2b. Front-end gates (parse / resolve / typecheck / check — main.exe + dev probes)
| Script | Cat | Fixtures (count) | Goldens present | Entry |
|--------|-----|------------------|-----------------|-------|
| diff_compiler_lexer.sh | C+D | diff_fixtures (25) | **yes (.golden TOKENS)** | lex_main |
| diff_compiler_lex_files.sh | C+D | compiler+stdlib corpus (~10) | no | lex_main |
| diff_compiler_parse.sh | C+D | parse_fixtures (26) | no | parse_main |
| diff_compiler_parse_result.sh | C+D | parse_error_fixtures (8) | **yes (.expected)** | parse_result_main |
| diff_compiler_parse_errors.sh | C+D | parse_error_fixtures (8) | **yes (.expected)** | parse_main |
| diff_compiler_positions.sh | C+D | positions_fixtures (6) | no | positions_main |
| diff_compiler_desugar.sh | C+D | stdlib+diff+parse+compiler corpus | no | desugar_main |
| diff_compiler_desugar_batch.sh | C+D | same corpus | no | desugar_batch |
| diff_compiler_resolve.sh | C+D | resolve_fixtures (14) | **yes (.expected)** | resolve_main |
| diff_compiler_resolve_batch.sh | C+D | resolve_fixtures (14) | **yes (.expected)** | resolve_batch |
| diff_compiler_resolve_modules.sh | C+D | resolve_module_fixtures (20) | **yes (.expected)** | resolve_modules_main |
| diff_compiler_mark.sh | C+D | stdlib+diff+parse+compiler corpus | no | mark_main |
| diff_compiler_mark_batch.sh | C+D | same corpus | no | mark_batch |
| diff_compiler_typecheck.sh | C+D | typecheck_fixtures (12) | no | typecheck_main |
| diff_compiler_typecheck_errors.sh | C+D | typecheck_error_fixtures (19) | no | typecheck_main + check_main |
| diff_compiler_typecheck_golden.sh | C+D | diff_fixtures (25) | **yes (.golden TYPES)** | typecheck_main |
| diff_compiler_typecheck_golden_batch.sh | C+D | diff_fixtures (25) | **yes (.golden TYPES)** | typecheck_golden_batch |
| diff_compiler_typecheck_panic_errors.sh | C+D | typecheck_panic_fixtures (6) | no | typecheck_main |
| diff_compiler_check.sh | C+D | diff_fixtures (25)+resolve (14)+import_error | partial (.golden/.expected) | check_main |
| diff_compiler_check_batch.sh | C+D | diff_fixtures (25)+resolve (14) | partial | check_batch |
| diff_compiler_check_modules.sh | C+D | compiler modules (~14)+check_module_fixtures | **yes (.expected)** | check_modules_main |
| diff_compiler_check_modules_batch.sh | C+D | compiler modules (~14) | no (corpus must-pass) | check_all_main |
| diff_compiler_check_match.sh | C+D | check_match_fixtures (11) | **yes (.expected)** | check_match_main |
| diff_compiler_exhaust.sh | C+D | exhaust_fixtures (5) | **yes (.expected)** | exhaust_main |

**Approach.** Every D here compares against a deterministic, **location-free**
textual dump (the dev probes were built to be location-free precisely so they
diff against self-hosted output). Capture each probe's dump as a golden. The
self-hosted probes already exist as entries — so the long-run gate is
**native-compiler-probe output == golden**, with the golden captured from the
OCaml dev-probe while it is still trusted. Many already have goldens; the
no-golden corpus gates (`desugar`/`mark` over the stdlib+compiler corpus,
`parse`, `typecheck`, `positions`, `lex_files`) need capture.

### 2c. Tooling gates (fmt / lsp / repl / new / test / diagnostics / build)
| Script | Cat | Fixtures | Goldens | Entry |
|--------|-----|----------|---------|-------|
| diff_compiler_fmt.sh | C+D | fmt_fixtures (11)+parse_fixtures (26) | **yes (.expected)** | fmt_main |
| diff_compiler_printer.sh | C+D | parse_fixtures (26) | partial | printer_main |
| diff_compiler_comments.sh | C+D | comment_fixtures (8) | no | lex_comments_main |
| diff_compiler_lsp.sh | C+D | generated | no | lsp_main |
| diff_compiler_lsp_b3.sh | C+D | generated | no | lsp_main |
| diff_compiler_lsp_b4.sh | C+D | generated | no | lsp_main |
| diff_compiler_repl.sh | C | generated | no | repl_main |
| diff_compiler_new.sh | C+D | generated tree | no | new_main |
| diff_compiler_test.sh | C+D | stdlib + compiler_test_fixtures (1) | no | test_main |
| diff_compiler_diagnostics.sh | C+D | resolve+exhaust+check_match+diff (subset) | no | diagnostics_main |
| diff_compiler_analyze_project.sh | C+D | analyze_project_fixtures (4) | no | diagnostics_project_main |
| diff_compiler_selfproc.sh | C+A | compiler modules | no | check_all/eval_modules/selfproc_* |

**Approach.** Same golden-capture as 2b. `new`/`repl`/`lsp` produce structured
text (project tree listing, REPL transcript, LSP JSON) — capture as goldens.
`new` golden must be path/tmp-normalized at capture (strip the mktemp prefix).

### 2d. Native / build / construct-coverage gates
| Script | Cat | Fixtures | Goldens | Entry / note |
|--------|-----|----------|---------|------|
| diff_compiler_build.sh | B+C | diff+fmt programs | no | build_main; diffs compiler-built binary vs `main.exe build` binary vs interp |
| diff_native_cli.sh | C+F | diff+fmt + generated | no | runs subcommands through `./medaka` AND `main.exe run` entries |
| diff_native_stack.sh | A | stack_fixtures (4)+stack_fixtures_typed (3) | no | eval_probe value oracle |
| build_cmd.sh | B | construct_fixtures (149) | no | `main.exe build` binary-output oracle |
| build_construct_coverage.sh | B | construct_fixtures (149) | no | `main.exe build` coverage |

**Approach.** B gates: today they compare the OCaml-built binary's stdout against
the native-built binary's stdout (or interp). Re-root = drop the OCaml-built
binary; oracle becomes **native-build binary stdout == golden** (captured from the
OCaml binary now) AND/OR **== native-interp** (§3). `construct_fixtures` (149,
no golden) is the single largest capture surface here.

### 2e. Bootstrap stage gates (native stage == reference)
| Script | Cat | Fixtures | Note |
|--------|-----|----------|------|
| bootstrap_lex.sh | C | diff_fixtures (25) | native lexer stage == reference lexer |
| bootstrap_parse.sh | C | parse_fixtures (26) | |
| bootstrap_desugar.sh | C | parse_fixtures | |
| bootstrap_resolve.sh | C | resolve_fixtures (14) | |
| bootstrap_mark.sh | C | parse_fixtures | |
| bootstrap_typecheck.sh | C | typecheck_fixtures (12) | |
| bootstrap_eval.sh | C | eval_fixtures (20) | |
| bootstrap_from_seed.sh | **F** | gz seed | already OCaml-free |

These prove "native stage == interpreted stage" by running the SAME entry via
`main.exe run` (interp) and via the native binary, diffing. Re-root: the
interpreted leg's reference becomes a **golden captured from `main.exe run <entry>`**
now (or, better, the native-interp binary in §3). Once native==golden these are
nearly redundant with the diff_compiler gates and could fold into them.

### 2f. Self-compile / fixpoint / seed (the emitter compiling itself)
| Script | Cat | Note |
|--------|-----|------|
| selfcompile_emit.sh | **C** | uses `$MAIN run` to build the INTERPRETED oracle emitter `emitA` |
| selfcompile_lex.sh | **C** | same — `$MAIN` produces the interpreted reference IR |
| selfcompile_fixpoint.sh | **C** | **NOT pure-F** — `$MAIN run <driver>` produces `INTERP.ll`, the C3a oracle AND the source for `emitA` |
| selfcompile_build_fixpoint.sh | **C** | same shape |
| refresh_seed.sh | **F** | uses `./medaka_emitter` only |
| build_native_medaka.sh | **F** | warm path native-only; cold path bootstraps from gz seed |

> **Correction to the task's premise:** `selfcompile_fixpoint.sh` is NOT already
> native-only. It bootstraps `emitA` from `$MAIN run <driver>` (the interpreted
> emission), which is both the C3a oracle and `emitA`'s source. To make it
> OCaml-free, `emitA` must be bootstrapped from the **native emitter / gz seed**
> instead of the interpreter (exactly what `build_native_medaka.sh` cold-path
> already does via `bootstrap_from_seed.sh`). This is a small, mechanical swap
> (replace the `$MAIN run` line with the seed-bootstrapped `./medaka_emitter`),
> but it changes the meaning: C3a stops being "native == interpreter" and
> becomes "native == native-from-seed", i.e. pure self-consistency. That is
> acceptable and is the whole point of the fixpoint, but note it explicitly.

### 2g. Out-of-scope / auxiliary
| Script | Cat | Note |
|--------|-----|------|
| fuzz_diff.sh | C+D | fuzzer; oracle = `main.exe run eval_dict_main` vs native. Re-root last; needs the native-interp binary (§3) — fuzzer has no fixed fixtures to golden |
| bench.sh | C+B | performance, not correctness — runs `main.exe` to measure speedup baseline. Keep an OCaml-baseline column through soak; native-only after `lib/` removal (baseline becomes "native-from-seed") |
| profile_compiler.sh | C | profiling harness; same as bench |
| dev/*_probe.ml (E) | E | OCaml unit/probe code — deleted WITH `lib/`, gates nothing native |

---

## 3. Hybrid oracle infrastructure

### 3a. Golden capture (Phase 1 — the foundation)
**Surface to capture** (no golden today): eval-value goldens for ~200 fixtures
(eval/eval_list/eval_prelude/eval_dict/eval_typed/llvm/llvm_typed via
`eval_probe`), front-end dumps for the no-golden corpus gates (parse 26,
typecheck 12+19+6, positions 6, desugar/mark corpus, lex_files ~10, comments 8),
construct binary-output goldens (149), tooling goldens (fmt partial, new, lsp,
test, diagnostics, analyze_project). **Already captured** (regen-in-place):
diff_fixtures `.golden` (25, multi-section TOKENS/AST/TYPES/EVAL via
`dev/gen_golden.ml`), error `.expected` (~50 across parse/resolve/check_match/
exhaust/eval_error/resolve_module), core_ir `.sexp` (20).

**Where goldens live:** next to each fixture, suffixed by the oracle stage, e.g.
`eval_fixtures/adt_nested.eval.golden`, `llvm_fixtures/<n>.run.golden`,
`construct_fixtures/<n>.run.golden`. This mirrors the existing `.golden`/
`.expected`/`.sexp` convention. Multi-section goldens (`dev/gen_golden.ml`
already emits `=== TOKENS/AST/TYPES/EVAL ===`) let one file serve lexer +
parse + typecheck + eval gates — prefer extending `gen_golden.ml`'s section set
over scattering one file per stage.

**Capture script** (`test/capture_goldens.sh`, NEW, runs while OCaml is trusted):
for each fixture dir, run the matching OCaml oracle (`eval_probe.exe`,
`gen_golden.exe`, or the relevant dev probe / `main.exe build`+run) and write the
golden. One driver table maps `fixture_dir → oracle command → golden suffix`.
This is the ONLY place the OCaml oracle is invoked at capture time; it is run
manually at checkpoints, not in the gate loop.

**Regenerate story.**
- **During soak (OCaml present):** `test/capture_goldens.sh` regenerates from the
  OCaml oracle. This is the trustworthy regen path — use it for any intended
  behaviour change until `lib/` removal.
- **After `lib/` removal:** regen from the **native-interp binary** (§3b). **Self-
  reference caveat:** once the native compiler IS the oracle, a regen cannot
  catch a regression the native compiler itself introduced — it would happily
  bless wrong output. Mitigation: (1) goldens are committed, so a *diff* in the
  golden during regen is a reviewable signal; (2) the fixpoint gate (§3c) is
  independent of goldens and catches emitter self-inconsistency; (3) keep the gz
  seed as a frozen second native reference — regen from seed-native AND
  HEAD-native and diff. The soak exists precisely to build confidence that
  native==OCaml on the whole golden set BEFORE OCaml goes away.

### 3b. Native-interp oracle (Phase 3 — the live cross-check)
**Feasible — the entries already exist.** `compiler/eval/eval.mdk` is driven by
`compiler/entries/eval_main.mdk` (reads a file, `evalMain (desugar (parse src))`,
prints `pp_value`). Compiling it standalone is one command:
`medaka build compiler/entries/eval_main.mdk -o test/bin/eval_oracle`. The
resulting native binary takes a fixture path and prints the same `pp_value`
`eval_probe.exe` prints — a **live native replacement for `eval_probe`**. No new
entry needed; `eval_main.mdk`, `eval_prelude_main.mdk`, `eval_typed_main.mdk`,
`check_main.mdk`, `typecheck_main.mdk`, `parse_main.mdk`, etc. each already wrap
their stage with file-reading `main` plumbing and are build-targets as-is.

**What it needs:** (1) a `test/bin/` of pre-compiled stage oracles, built once per
suite run by a `test/build_oracles.sh` that loops the needed entries through
`medaka build`; (2) the gates reference `test/bin/<stage>_oracle` instead of
`main.exe run <entry>`. Because compiling C-entries to native is ALSO the
category-C re-root, **§3b and the C re-root are the same build step** — building
`test/bin/eval_main` serves both as the unit-under-test (native stage) and, for a
*different* stage's gate, as the oracle. The native-interp oracle is strongest
where a golden is awkward (fuzzer, generated inputs): `fuzz_diff.sh` diffs the
native-compiled program vs the native-interp binary over random inputs, no fixed
golden required.

**Caveat:** native-interp and native-compiled share the same front-end source, so
they cannot catch a front-end bug they agree on — that is what the golden layer
(captured from independent OCaml) covers during soak, and the fixpoint covers for
the emitter. Layer all three; don't rely on any one.

### 3c. Fixpoint (Phase 0 — already native, once §2f swap lands)
`selfcompile_fixpoint.sh` / `selfcompile_build_fixpoint.sh` with the §2f
`$MAIN`→seed swap become pure native self-consistency gates (IR1==INTERP-from-
seed, IR1==IR2). No fixtures, no OCaml. These plus `bootstrap_from_seed.sh` and
`refresh_seed.sh` are the OCaml-free backbone.

---

## 4. Phased implementation order

**Phase 0 — fixpoint OCaml-free (lowest risk, highest symbolic value).**
Swap `$MAIN run <driver>` → seed-bootstrapped `./medaka_emitter` in
`selfcompile_fixpoint.sh`, `selfcompile_build_fixpoint.sh`, `selfcompile_emit.sh`,
`selfcompile_lex.sh` (the cold-path bootstrap in `build_native_medaka.sh` is the
template). Outcome: the entire self-compile/fixpoint family runs with no OCaml.
No goldens needed.

**Phase 1 — golden capture infra + capture the no-golden surface.**
Write `test/capture_goldens.sh` (extends `dev/gen_golden.ml`; adds eval-value
and construct-binary-output capture). Capture the ~200 eval/llvm value goldens
and the no-golden front-end/tooling goldens while OCaml is trusted. Commit the
goldens. This blocks every A/D re-root, so it is the critical-path infra item.
**Recommended phase-1 FIRST MOVE: build `test/capture_goldens.sh` and capture
the `eval_probe` value goldens for `eval_fixtures` (20) + `llvm_fixtures` (180)** —
that single capture unblocks the 13 eval_probe gates (the largest A cluster,
217 fixtures) and is purely additive (writes new `.golden`, touches no gate).

**Phase 2 — re-root the C+golden gates (front-end + eval).**
Build `test/build_oracles.sh` (loops the stage entries through `medaka build`
into `test/bin/`). Re-point each gate: replace `main.exe run <entry>` with
`test/bin/<entry>`, and replace the OCaml oracle leg with the Phase-1 golden.
Do the already-goldened gates first (diff_fixtures family, error gates,
core_ir_sexp, fmt, resolve, check_match, exhaust — ~15 gates flip with zero new
capture), then the freshly-captured ones.

**Phase 3 — native-interp oracle for generated/fuzz inputs.**
Stand up the native-interp binaries (subset of `test/bin/` already built in
Phase 2). Re-root `fuzz_diff.sh`, `diff_native_stack.sh`, and any gate where a
fixed golden is awkward, to diff native-compiled vs native-interp.

**Phase 4 — B gates (build / construct coverage) + tooling.**
Capture construct-binary goldens (149) and re-root `build_cmd.sh`,
`build_construct_coverage.sh`, `diff_compiler_build.sh` to native-build-vs-golden
(and/or native-interp). Re-root `lsp`/`new`/`repl`/`test`/`diagnostics`/
`analyze_project` against captured goldens.

**Phase 5 — bench/profile baseline + cleanup.**
Keep an OCaml baseline column in `bench.sh`/`profile_compiler.sh` through soak;
flip to native-from-seed baseline at `lib/` removal. Fold the now-redundant
`bootstrap_*` stage gates into the diff_compiler gates if desired.

**Ordering rationale:** Phase 0 is free and removes OCaml from the most load-
bearing gates immediately. Phase 1 is pure capture (additive, reversible, no gate
touched) and unblocks everything else, so it runs in parallel with Phase 0.
Phases 2–4 are mechanical per-gate edits gated only on the build-oracles step.

---

## 5. Blockers — gates that genuinely need the live OCaml oracle until removal

None are *hard* blockers to OCaml-free gates, but these are the items whose
**confidence** gates `lib/` *removal* (not the re-rooting):

1. **Golden trustworthiness = the soak itself.** Once a golden is captured from
   OCaml and the gate compares native-vs-golden, the gate is OCaml-free — but the
   golden's *correctness* rests on OCaml having been right. The `lib/`-removal
   gate is: "native output has matched every captured golden across N days of dev,
   AND a re-capture-from-native produces byte-identical goldens." Until that
   holds, KEEP `lib/` frozen and re-runnable so a suspicious golden can be
   re-derived from the independent OCaml oracle.

2. **Front-end self-reference gap.** After removal, native-interp and native-
   compiled share the front-end, and goldens were captured from OCaml. A
   front-end bug introduced *after* the last OCaml-trusted capture cannot be
   caught by regen (it would bless itself). Mitigation owned by the soak: re-
   capture goldens from OCaml at the LAST checkpoint before removal, and never
   regen-from-native a golden without a human diff review. This is the single
   reason `lib/` must outlive the gate re-rooting.

3. **`selfcompile_fixpoint.sh` semantic shift (§2f).** The `$MAIN`→seed swap
   changes C3a from "native == interpreter" to "native == native-from-seed." That
   loses the cross-implementation check at the emitter level. Compensate by
   running the OCaml-oracle'd version ONCE per checkpoint during soak (manual,
   not in the gate loop) to confirm native still matches the interpreter before
   committing to seed-only fixpoint.

4. **`bench.sh` baseline.** The "~59× vs OCaml interpreter" headline number needs
   `main.exe` to exist. Not a correctness gate; the number is recomputed against
   the seed-native baseline post-removal. No blocker, just a reporting change.

**Net:** the gates can ALL be made OCaml-free in Phases 0–4 without removing
`lib/`. `lib/` stays as the soak-period golden re-derivation oracle and is removed
only after the confidence gate in blocker #1 is met.
