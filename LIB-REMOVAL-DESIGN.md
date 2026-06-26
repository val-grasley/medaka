# LIB-REMOVAL-DESIGN — retiring the OCaml reference compiler (`lib/`+`bin/`+`gen/`)

Decision-ready removal plan. Native LLVM-backed `medaka` is CANONICAL and OCaml-free;
this doc maps every remaining dependency on the OCaml oracle and stages its deletion.
All evidence is reproduced empirically (file:line), not recited from status docs.

Base verified: `git merge-base --is-ancestor 381ee4e HEAD` → BASE_OK; `git merge main`
already up to date.

---

## 1. THE CRITICAL QUESTION — seed re-mint is NATIVE-READY (NOT OCaml-blocked)

**Verdict: the cold-bootstrap seed can be minted, and the whole native compiler
built, with ZERO OCaml. No prerequisite re-point is required.**

Evidence:
- `test/refresh_seed.sh` (the seed re-mint) mints the seed via the NATIVE emitter:
  - L48: `FORCE_EMITTER_REBUILD=1 sh "$ROOT/test/build_native_medaka.sh"` — warm-rebuilds
    `./medaka_emitter` from current source, OCaml-free (cold-bootstraps from the existing
    gz seed if no emitter binary exists).
  - L74: `"$EMITTER" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" "$STDLIB" > "$TMP"` — the
    NATIVE emitter emits the build driver's own module graph = the seed IR.
  - L62-72: the OCaml oracle (`_build/default/bin/main.exe`) is used ONLY as an OPTIONAL
    cross-check, gated `CHECK_OCAML` (default 1 but `[ -x "$MAIN" ]`-guarded) and explicitly
    "informational only, never required." Header L11-13 states this outright.
- `test/build_native_medaka.sh` and `test/bootstrap_from_seed.sh`: grep for
  `main.exe|dune|lib/|gen/|bin/main|_build` → only `stdlib/runtime.mdk` + `stdlib/core.mdk`
  matches (read-from-disk inputs). No OCaml anywhere.
- `Makefile`: `medaka:` → `sh test/build_native_medaka.sh`; `emitter:`/`bootstrap:` →
  `bootstrap_from_seed.sh`; `seed:` → `refresh_seed.sh`. The ONLY `dune build --root .`
  is the `reference:` target — i.e. building the OCaml oracle itself.
- `test/selfcompile_fixpoint.sh`: header §"OCaml-FREE (REROOT-PLAN Phase 0)" — the C3a/C3b
  fixpoint is bootstrapped from the committed `selfhost/seed/emitter.ll.gz`, no `main.exe`,
  no `dune`. This is the decisive spine gate and is already OCaml-free.

Consequence: **Stage P (re-point seed mint to native) is a NO-OP — already done.** The
optional `CHECK_OCAML` cross-check in `refresh_seed.sh` L60-72 is the only seed-path OCaml
reference and is deleted as cleanup, not as a blocker.

---

## 2. OCaml-oracle gate census

68 `diff_selfhost_*` gates total; the reroot (REROOT-PLAN.md) converted the bulk to
native `test/bin/<entry>` oracles (built by `test/build_oracles.sh` via native `./medaka build`)
comparing against COMMITTED goldens. Verified samples:
- `diff_selfhost_eval_run.sh` L24 `RUN="$ROOT/test/bin/eval_run_main"` (native) + committed `=== EVAL ===` golden.
- `diff_selfhost_typecheck.sh` L9 `RUN="$ROOT/test/bin/typecheck_main"` (native) + committed golden.
- `diff_selfhost_llvm.sh` L28 `EMITBIN="$ROOT/test/bin/llvm_emit_main"` (native) + `.eval.golden`.

The ONLY gates with a LIVE (non-comment) OCaml invocation (`grep -vE '^#'`):

| Gate | OCaml use (file:line) | Class | Fate on removal |
|------|----------------------|-------|-----------------|
| `diff_selfhost_check_json.sh` | L25/L45 `$ORACLE check --json` | **(b) live-oracle, NO golden** | DIES wholesale — coverage LOST unless re-rooted to native golden first |
| `diff_selfhost_check_policy.sh` | L24/L43 `$ORACLE check-policy` | **(b) live-oracle, NO golden** (L14 "No committed goldens") | DIES wholesale — coverage LOST |
| `diff_selfhost_doc.sh` | L28/L44 `$ORACLE doc` | **(b) live-oracle, NO golden** (L17 "No committed goldens") | DIES wholesale — coverage LOST |
| `diff_selfhost_effect_hole.sh` | L36/L58/L172 `$OCAML check` | **(b) but ALSO native HOST + committed golden** (L41/L44) | OCaml LEG dies; native+golden legs SURVIVE — surgical edit, not delete |
| `diff_selfhost_effect_param.sh` | L34/L51 `$OCAML check` | same as above | OCaml leg dies; native+golden survive |
| `diff_native_cli.sh` | L255-267 `$ORACLE check` for `error/*` carat | **(b) live-oracle leg, already skip-guarded** (`if [ -x "$ORACLE" ]`) | error/* leg auto-skips; rest of gate is native-vs-golden, survives |
| `test/capture_goldens.sh` | L37 `MAIN=…main.exe`; L228/245/255/269/302-303 `$MAIN run`; L36-55 OCaml `dev/*.exe` probes | **golden PROVENANCE tool** | Re-capture path dies; committed goldens (which already == native output) remain. Needs re-point to native to stay regenerable |
| `test/bench.sh` | L37 fallback only (`[ -x medaka ]` prefers native) | (a) native-first | survives; dead OCaml fallback removed |
| `test/profile_selfhost.sh` | L33 `MAIN=…main.exe` | perf profiling tool | non-gate; re-point or drop |
| `test/refresh_seed.sh` | L62-72 optional `CHECK_OCAML` cross-check | seed cross-check | delete the optional leg (see §1) |

**(c) OCaml-only unit/thorough suites** (all die with `medaka_lib`, all reference it in dune):
- `test/dune` L2-3: 18 suites (`test_parser … test_doc`) `(libraries medaka_lib alcotest …)`.
- `test/thorough/dune`: 7 `thorough_*` suites (`medaka_lib` ref count 2).
- `dev/dune`: 14 OCaml dev probes (`debug tc_debug … positions_dump`) `(libraries medaka_lib unix)` —
  several still consumed by `capture_goldens.sh` (L36-55) and `diff_selfhost_effect_hole.sh` L113
  (`dev/gen_golden.exe`) to GENERATE goldens.

No CI/workflow config exists (`.github` absent), so there is no pipeline file to update —
gates are run manually / by the orchestrator.

---

## 3. Build-graph impact

`dune build --root .` today builds: `gen/embed.exe` → generates `lib/stdlib_content.ml`
+ `lib/prelude_content.ml` → `medaka_lib` (`lib/dune`) → `bin/main.exe` (`bin/dune`) →
`dev/*` probes (`dev/dune`) → `test/*` + `test/thorough/*` suites. **Every one of the 6
dune files transitively depends on `medaka_lib`** (`grep -rl medaka_lib --include=dune`:
test/dune, test/thorough/dune, bin/dune, lib/dune, dev/dune; gen/dune is medaka_lib's
generator). The native build (`make medaka` / `build_native_medaka.sh` / `bootstrap_from_seed.sh`)
touches NONE of dune/lib — confirmed in §1.

Therefore: deleting `lib/`+`bin/`+`gen/`+`dev/` and the OCaml `test` suites leaves dune
with **nothing to build**. `dune-project` (`(lang dune 3.0)`/menhir) can be deleted outright,
or kept as an empty shell. There is no non-OCaml artifact under `test/`/`dev/` that dune
must still produce — the surviving gates are all `.sh` driving native binaries + committed
goldens, which never invoke dune.

---

## 4. `gen/embed.ml` + `stdlib_content.ml` — dies with the OCaml compiler

`gen/embed.ml` embeds `stdlib/runtime.mdk`+`core.mdk` into `lib/stdlib_content.ml`/
`prelude_content.ml` (`lib/dune` L1-19), consumed ONLY by `medaka_lib` (it is in the
library `(modules …)` list). Verified nothing native reads it:
`grep -rln 'stdlib_content|prelude_content' selfhost/ runtime/` → **0 hits**. The native
compiler reads `stdlib/*.mdk` from disk directly. embed/stdlib_content are pure OCaml-compiler
machinery and die cleanly with `lib/`.

---

## 5. Other references / doc updates required

- `selfhost/` source: only doc-comment mentions of the old path
  (`selfhost/tools/test_cmd.mdk` L10, `selfhost/entries/test_main.mdk` L8 — "Mirrors
  `main.exe test`"). No live invocation. Cosmetic comment updates, non-blocking.
- Docs heavily describing the `lib/` pipeline (need rewrite, NOT rewritten here):
  - `AGENTS.md` — the entire "Pipeline — where each stage lives" table, "Support files",
    "Build & test" (`dune build`, suite list, `@thorough`, dev probes), and most Gotchas
    are `lib/`-rooted; the "frozen oracle" framing throughout must flip to "removed".
  - `README.md` — build/test/CLI usage references `dune` + suites.
  - `Makefile` — delete the `reference:` target + the two-compiler header comment.
  - `PLAN.md` / `PLAN-ARCHIVE.md` / various `*-DESIGN.md` — historical `lib/eval.ml` etc.
    references; leave archival, update only forward-looking PLAN.md.
  - `selfhost/REROOT-PLAN.md` §5 blocker #3 (the "run OCaml-oracle'd fixpoint once per soak
    checkpoint" compensating control) becomes void — note it as retired.

---

## 6. Staged removal plan (ascending risk, each independently gateable)

The decisive spine gate after EVERY stage: `sh test/selfcompile_fixpoint.sh` (C3a+C3b,
OCaml-free) AND a cold `make clean && make emitter` (`bootstrap_from_seed.sh`) + `make medaka`.
If those pass, native canonicity is intact.

- **Stage P — seed re-point: ALREADY DONE (no work).** §1 proves the seed mint + cold
  bootstrap + fixpoint are native. Only cleanup: drop the optional `CHECK_OCAML` leg in
  `refresh_seed.sh` L60-72. Not a blocker, not a prerequisite.

- **Stage A — preserve-or-drop the live-oracle-only gates (DO BEFORE deletion).** This is
  the only stage with potential coverage LOSS. For `diff_selfhost_check_json/check_policy/doc`
  (no goldens, native-vs-live-OCaml only): EITHER (A1) re-root each to a committed golden
  captured from native `./medaka` (preserves json/policy/doc differential coverage), OR (A2)
  accept the loss (native is canonical; a one-time native capture + commit is cheap and
  recommended). For `effect_hole`/`effect_param`: surgically delete the `$OCAML` leg, keep the
  native-host + committed-golden legs. Gate: each edited `.sh` still exits 0 against native.

- **Stage B — re-point golden regeneration to native.** `capture_goldens.sh` and the OCaml
  `dev/*` probes it calls must be re-pointed to native equivalents (`test/bin/*` from
  `build_oracles.sh`, or `./medaka run <entry>`) so goldens stay regenerable. The committed
  goldens already equal native output (the rerooted gates pass today), so re-capture is
  byte-stable. Gate: `capture_goldens.sh` (native) reproduces the committed goldens unchanged.
  NOTE: probes lacking a native `test/bin` equivalent (e.g. lextok/astdump/positions_dump/
  comment_dump/tc_probe/diagdump) must get one in `build_oracles.sh`, OR their goldens are
  declared frozen. This is the largest discretionary work item — see Fork F3.

- **Stage C — delete orphaned OCaml-oracle gate remnants + perf fallbacks.** Remove
  `diff_selfhost_check_json/check_policy/doc` (if not re-rooted in A1), the `error/*` ORACLE
  leg of `diff_native_cli.sh`, and the OCaml fallback in `bench.sh`/`profile_selfhost.sh`.
  Gate: full native gate sweep green; no `.sh` references `main.exe`/`dune` (audit grep == 0).

- **Stage D — delete the OCaml compiler + dune graph.** Delete `lib/`, `bin/`, `gen/`,
  `dev/`, `test/test_*.ml` (18), `test/thorough/`, `bin/dune`, `gen/dune`, `lib/dune`,
  `dev/dune`, the `(library …)`/suite stanzas, and `dune-project` (nothing remains for dune
  to build). Delete `gen_golden.exe` use in `effect_hole.sh` L113 (replace golden-gen with
  the native capture from Stage B, or freeze). Gate: cold bootstrap + `selfcompile_fixpoint.sh`
  + the full native `.sh` gate sweep, all green with `lib/`/`bin/`/`gen/` absent.

- **Stage E — docs.** Rewrite AGENTS.md/README.md/Makefile per §5; flip "frozen oracle /
  retirement ≠ removal" framing to "removed". No gate (doc-only).

Ordering constraint: **A and B (coverage/golden preservation) MUST precede C/D.** P is
already satisfied. C/D/E are low-risk once A/B land.

---

## 7. Forks needing a human decision

- **F1 — Coverage of the 3 golden-less OCaml gates (`check_json`, `check_policy`, `doc`).**
  They compare native ONLY against live OCaml (no committed golden), so removal silently
  drops differential coverage of native `check --json` / `check-policy` / `doc` output.
  DECIDE: (A1) capture native goldens for these 3 and re-root before deleting OCaml
  (preserves coverage; ~modest work), vs (A2) accept the loss (native is canonical). RECOMMEND A1
  for `--json`/`check-policy` (machine-consumed, regression-prone), A2 acceptable for `doc`.

- **F2 — `lib/` in history vs a tagged frozen commit.** Per the project's
  "retirement ≠ removal" memory, the team treated `lib/` as a reference artifact. DECIDE:
  tag a final `oracle-frozen` commit (or annotate) BEFORE the Stage-D deletion so the OCaml
  oracle is trivially recoverable, vs rely on plain git history. RECOMMEND tag.

- **F3 — How aggressively to preserve `capture_goldens.sh` regenerability (Stage B scope).**
  Several OCaml `dev/*` probes (lextok/astdump/positions_dump/comment_dump/tc_probe/diagdump)
  have no native `test/bin` oracle yet. DECIDE: build native oracle entries for all of them
  (full regenerability, more work), vs declare those specific goldens frozen-as-committed
  (cheaper, but a future format change can't re-bless them). The gates themselves pass either
  way — this is purely about future maintainability.

- **F4 — `dune-project` removal.** Deleting it removes the last dune entry point entirely.
  Confirm no external tooling (editor integration, scripts) keys off `dune-project` existence.
  Low risk (no CI), but a conscious "this repo no longer builds anything with dune" call.

- **F5 (NON-blocker, stated for completeness).** The seed-mint path is NATIVE — there is NO
  OCaml-blocked cold-bootstrap. The STOP guardrail does not trigger.
