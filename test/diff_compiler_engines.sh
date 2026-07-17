#!/usr/bin/env bash
# diff_compiler_engines.sh — the THREE-ENGINE differential gate (docs/ops/TESTING-DESIGN.md §4.4).
#
# Medaka owns three independent implementations of its own semantics:
#
#   eval    the tree-walking interpreter   compiler/eval/eval.mdk         (`medaka run`)
#   native  the LLVM backend               compiler/backend/llvm_emit.mdk (`medaka build`)
#   wasm    the WasmGC backend             compiler/backend/wasm_emit.mdk
#
# …and, before this gate, no program in the tree was ever compared across all three.
# The one two-way check that existed (diff_compiler_llvm.sh) diffs the native
# binary's stdout against a `<fixture>.eval.golden` FILE — a frozen capture of the
# interpreter, taken from the OCaml interpreter that was deleted 2026-06-26.  So a
# bug that got captured became the *expected* answer for the backend too.  This gate
# removes that circularity: it runs all three engines LIVE on the same source and
# diffs them against EACH OTHER.  No golden file mediates anything.
#
#   for each fixture f:   eval(f) == native(f) == wasm(f)
#
# Corpus: the UNION of ALL FOUR emitter corpora —
#
#   test/llvm_fixtures/        (201)   untyped, prelude-free
#   test/llvm_fixtures_typed/   (45)   real prelude, TYPECHECKS
#   test/wasm/fixtures/        (149)   untyped, prelude-free
#   test/wasm/fixtures_typed/    (9)   real prelude, TYPECHECKS
#                              ────
#                               404
#
# Before this gate the two backends were validated on essentially disjoint corpora
# (5 basenames in common) — which is exactly why 7 of the 22 known divergences are
# wasm bugs on fixtures only the LLVM corpus ever had.
#
# ⚠️ The two TYPED corpora could not be here until 2026-07-14, and the reason is the
# whole point of that day's change (see "Arms" below).  The gate is a THREE-WAY
# differential, so a fixture must run on ALL THREE arms to be in the corpus at all —
# the corpus is therefore capped by the WEAKEST arm.  The wasm arm used to be the
# prelude-free probe `test/bin/wasm_emit_main` (parse → desugar → annotate → lower →
# emit: NO TYPECHECK, NO PRELUDE), so no fixture that needs the prelude could join,
# and the gate STRUCTURALLY COULD NOT EXPRESS A TYPE-DIRECTED BUG.  It could not have
# caught the record-update miscompile (#38).  Moving the wasm arm onto the shipping
# CLI raised the ceiling; the typed corpora walked in.
#
# ── Three tiers ───────────────────────────────────────────────────────────────
#   T1  eval == native   over every fixture both engines can run   (no golden)
#   T2  native == wasm   over every fixture both engines can run
#   T3  all three agree                                            (headline)
#
# ── The known-failure ledger (test/engine_divergence.txt) ─────────────────────
# The 22 real divergences and the engine-unavailability cases are NOT skipped.  Each
# is an EXPLICIT ledger entry asserting the CURRENT (wrong) behaviour — rustc's
# `tests/crashes` model.  The gate fails BOTH ways:
#
#   * an un-ledgered disagreement            → FAIL (regression)
#   * a ledgered entry that starts PASSING   → FAIL ("promote it: delete the line")
#
# That second property is the whole point, and a plain skip-list cannot do it.  A
# silent skip is how this suite already lies to itself (docs/ops/TESTING-DESIGN.md §2.3).
# The per-entry diagnosis lives in test/ENGINE-DIVERGENCE.md.
#
# ── The auto-print contract (why there is an `eval_autoprint_main` probe) ──────
# Nearly every fixture in both corpora is a bare VALUE main (`main = 1 + 2`).
# `medaka build` rewrites that to `main = println <e>` (driver/main_autoprint.mdk)
# and the WasmGC emitter mirrors the same auto-print — but `medaka run` REFUSES a
# value main by design ("'main' must be a value of type Unit").  That is a CLI/UX
# decision, not a semantic difference, so using `medaka run` verbatim would report
# every fixture as a spurious three-way disagreement.  The interpreter arm is
# therefore compiler/entries/eval_autoprint_main.mdk = `medaka run`'s exact
# load→elaborate→evalModules path PLUS the same auto-print wrap.  Nothing else about
# the eval path differs from `medaka run`'s.
#
# ── Arms ──────────────────────────────────────────────────────────────────────
#   eval    test/bin/eval_autoprint_main <runtime> <core> <f> <dir(f)> <stdlib>
#   native  medaka build              --allow-internal <f> -o <UNIQUE>.bin && <UNIQUE>.bin
#   wasm    medaka build --target wasm --allow-internal <f> -o <UNIQUE>.wasm && node run.js
#
# ⚠️ ALL THREE ARMS ARE NOW THE COMPILER USERS ACTUALLY RUN.  Until 2026-07-14 the wasm
# arm shelled the probe `test/bin/wasm_emit_main`, whose entry (compiler/entries/
# wasm_emit_main.mdk) runs parse → desugar → annotate → lower → emit — NO TYPECHECK and
# NO PRELUDE.  That is a DIFFERENT COMPILER from `medaka build --target wasm`, and the
# consequences were not academic:
#
#   * `println` is an unbound variable on that path, and `.[i]` desugars to the `Index`
#     INTERFACE METHOD, which only resolves on a path that typechecks.  So the probe
#     rejected perfectly good programs, and its error message —
#         "wasm_emit gap — ref-mode: unbound variable 'index'"
#     — READS LIKE A BACKEND DEFECT.  Four fixtures (w7_array_*) were filed and ledgered
#     as `wasm:emitter-gap` on the strength of that wording.  They were never wasm bugs:
#     under `medaka build --target wasm` all four build and agree with native exactly.
#     TWELVE more ledger rows (char_lit, num_pi, num_e, num_int_min/max, uni_to_lower/
#     upper, abort_exit*, where_local_rec, where_sibling_ref, char_unicode) fell the same
#     way when the arm moved.  A gate that tests a configuration users never run will
#     keep filing its own artifacts as compiler bugs.
#     ⚠️ T-22 (2026-07-14, later the same day): the "wasm_emit gap — " prefix quoted above
#     is now GONE from wasm_emit.mdk's unbound-name panic — it asserted a category (backend
#     coverage gap) the emitter cannot verify, which is exactly what laundered these 16
#     fixtures into the ledger in the first place.  The panic now reads e.g. `unbound
#     variable 'index' (not a local, global value, constructor, or known function) [in
#     ...]` — an observation, not a conclusion.  See compiler/ERROR-QUALITY.md.
#
#   * and, per the corpus note above, it capped the corpus at the prelude-free fixtures.
#
# The wasm CLI path needs a COMPILED wasm emitter (MEDAKA_WASM_EMITTER = test/bin/
# wasm_emit_modules_main, built by test/wasm/build_wasm_oracle.sh), exactly as the LLVM
# path needs MEDAKA_EMITTER.  `medaka build --target wasm` runs wasm-tools parse+validate
# itself (build_cmd.mdk:wasmAssemble), so this gate no longer shells wasm-tools directly —
# but wasm-tools must still be on PATH for the CLI to find.
#
# ⚠️ The native arm's `-o` basename MUST be unique per fixture.  build_cmd.mdk derives
# its scratch IR path from the output BASENAME, not the full path
# (`/tmp/medaka_build_<baseOf outPath>.ll`), so N concurrent builds that all write
# `-o <somedir>/bin` fight over `/tmp/medaka_build_bin.ll` and silently produce each
# other's programs.  This gate hit exactly that: a stable-looking 20-vs-8 "backend
# disagreement" that was really one worker's IR linked into another's binary.  The
# unique-basename workaround below stays correct even once build_cmd is fixed.
#
# ── Exit ──────────────────────────────────────────────────────────────────────
#   0  every fixture matches its expected signature (clean, or ledgered-as-known)
#   1  a regression, or a ledgered known-failure that now passes (promote it)
#   2  ONLY for a genuine toolchain absence, worded to match run_gates.sh's
#      LEGIT_SKIP_RE.  A missing test/bin/* oracle exits 2 with a deliberately
#      NON-matching message, so run_gates reclassifies it as FAIL* (phantom skip) —
#      an unbuilt oracle means zero comparisons ran: infra rot, not a skip.
#   The gate never exits 0 having compared nothing (see the ZERO-COMPARISON checks).
#
# Usage:  bash test/diff_compiler_engines.sh
#         JOBS=8 bash test/diff_compiler_engines.sh
#         VERBOSE=1 bash test/diff_compiler_engines.sh    # every fixture's signature
#         CAPTURE=1 bash test/diff_compiler_engines.sh    # rewrite the ledger (review the diff!)
#
# run_gates.sh invokes every gate as `sh <gate>`, and /bin/sh is dash on Debian.  This
# gate needs bash (`${key//\//__}` substitution, `IFS=$'\t' read`), so re-exec under
# bash when we were not started by it.  Without this the gate dies with "Bad
# substitution" and exit 2 — which run_gates would (correctly) call a phantom skip.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EVALBIN="$ROOT/test/bin/eval_autoprint_main"
# The COMPILED wasm emitter the `medaka build --target wasm` CLI path shells out to
# (build_cmd.mdk reads it from $MEDAKA_WASM_EMITTER).  This is the real-prelude modules
# entry — NOT the prelude-free `wasm_emit_main` probe this gate used before 2026-07-14.
WASMBIN="${MEDAKA_WASM_EMITTER:-$ROOT/test/bin/wasm_emit_modules_main}"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
STDLIB="$ROOT/stdlib"
RUNJS="$ROOT/test/wasm/run.js"
LEDGER="$ROOT/test/engine_divergence.txt"
# ── Absolute value pins (issue #86) ────────────────────────────────────────────
# The differential above only proves the three engines AGREE — a bug where all
# three agree and are all WRONG is invisible to it by construction (SHADOW-
# SEMANTICS S7 guarantees path agreement, so a unanimous-but-wrong answer can
# never surface as a cross-engine disagreement; this is exactly how #50 hid for
# months). test/engine_value_pins/<key>.pin, when present, pins the literal
# expected stdout for that fixture — an assertion independent of any engine.
# See test/engine_value_pins/README.md for format, the incremental-corpus
# rationale, and the deferred ledger-interaction gap (pins are seeded ONLY on
# fixtures with no row in $LEDGER).
PINDIR="$ROOT/test/engine_value_pins"
TIMEOUT="${TIMEOUT:-60}"

run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # portable timeout (no coreutils on mac)

# ── Per-fixture worker ────────────────────────────────────────────────────────
# Writes $RESULTDIR/<slug>.sig :  <key> \t <signature> \t <t1> \t <t2> \t <t3>
# signature = "<en>:<nw>:<ew>:<eval>:<native>:<wasm>" — the three PAIRWISE verdicts
# (eq | ne | na) followed by the three arm availabilities (ran | na).  Clean =
# "eq:eq:eq:ran:ran:ran".  Plus <slug>.detail (the three outputs + why an arm is n/a).
if [ "${1:-}" = "--one" ]; then
  f="$2"
  # Key by CORPUS + basename.  18 basenames collide across the four corpora as
  # DIFFERENT files (adt_option, fn_factorial, fn_gcd, fn_tailsum, global_chain,
  # ctor_pap_arity across the two untyped ones; arr_get, str_lit, uni_to_upper, …
  # between llvm_fixtures and its typed sibling; record_update_shared_field between
  # the two typed ones), so a bare basename would silently alias them.
  # NOTE the typed patterns must be tested FIRST: */llvm_fixtures/* does not match
  # llvm_fixtures_typed (the glob needs a literal /llvm_fixtures/), but relying on
  # that is a trap for the next person to add a corpus — be explicit.
  case "$f" in
    */llvm_fixtures_typed/*) key="llvmT/$(basename "$f" .mdk)" ;;
    */wasm/fixtures_typed/*) key="wasmT/$(basename "$f" .mdk)" ;;
    */llvm_fixtures/*)       key="llvm/$(basename "$f" .mdk)"  ;;
    */wasm/fixtures/*)       key="wasm/$(basename "$f" .mdk)"  ;;
    *)                       key="other/$(basename "$f" .mdk)" ;;
  esac
  slug="${key//\//__}"
  W="$WORKDIR/$slug"; mkdir -p "$W"
  : >"$W/eval.out"; : >"$W/native.out"; : >"$W/wasm.out"
  : >"$W/eval.err"; : >"$W/native.err"; : >"$W/wasm.err"

  # -- eval -------------------------------------------------------------------
  # `ran` unless the interpreter raised its own runtime error.  Today ANY internal
  # E-* (E-PANIC / E-STACK-OVERFLOW / E-INDEX-OOB) means the interpreter could not
  # carry the program to completion — it has no `exit` primitive, so a nonzero exit
  # is never a program-level exit.  Each such fixture is ledgered with its reason.
  eva=ran
  run_t "$TIMEOUT" "$EVALBIN" "$RUNTIME" "$CORE" "$f" "$(dirname "$f")" "$STDLIB" \
    >"$W/eval.out" 2>"$W/eval.err" || true
  grep -q 'runtime error \[E-' "$W/eval.err" && eva=na

  # -- native -----------------------------------------------------------------
  # `ran` = a program was produced and executed, whatever its exit code (the abort_*
  # fixtures legitimately exit nonzero with their stdout already flushed).
  nat=ran
  if ! run_t "$TIMEOUT" "$MEDAKA" build --allow-internal "$f" -o "$W/$slug.bin" \
        >"$W/native.err" 2>&1; then
    nat=na
  else
    run_t "$TIMEOUT" "$W/$slug.bin" >"$W/native.out" 2>>"$W/native.err" || true
  fi

  # -- wasm -------------------------------------------------------------------
  # THE SHIPPING CLI, exactly as the native arm above — same compiler, same front end,
  # same typecheck; only `--target wasm` differs.  `medaka build --target wasm` emits
  # the WAT (via MEDAKA_WASM_EMITTER) and runs wasm-tools parse+validate itself, so a
  # nonzero exit covers ALL of: front-end rejection, emitter gap, unassemblable WAT,
  # and a module that fails GC validation.  `na` = no module was produced.
  #
  # A module that validates but TRAPS at run counts as `ran` (empty stdout): a trap is
  # a real disagreement with the other engines, not an unavailability.
  #
  # The unique `-o` basename matters here for the same reason it does on the native arm
  # (see the warning above) — and `$slug` is already corpus-qualified, so the four
  # corpora's 18 colliding basenames cannot collide in scratch either.
  wsm=ran
  if [ "$WASM_OK" != 1 ]; then
    wsm=off
  elif ! run_t "$TIMEOUT" "$MEDAKA" build --target wasm --allow-internal "$f" \
        -o "$W/$slug.wasm" >"$W/wasm.err" 2>&1; then
    wsm=na
  else
    run_t "$TIMEOUT" "$NODE" "$RUNJS" "$W/$slug.wasm" >"$W/wasm.out" 2>>"$W/wasm.err" || true
  fi

  # -- compare ----------------------------------------------------------------
  # The signature carries all THREE pairwise verdicts, not one collapsed "agree"
  # flag.  That matters: a collapsed flag cannot distinguish "eval disagrees with
  # native" from "only wasm disagrees", so when the wasm arm is unavailable the gate
  # could not soundly decide what to still enforce — and would either drop T1
  # silently or fire spurious regressions.  Six independently-maskable fields fix it.
  #
  #   <en>:<nw>:<ew>:<e>:<n>:<w>     pair ∈ eq | ne | na     arm ∈ ran | na
  #
  # A clean fixture is  eq:eq:eq:ran:ran:ran  (the default for anything un-ledgered).
  pair() {  # pair <armA> <armB> <fileA> <fileB>
    if [ "$1" != ran ] || [ "$2" != ran ]; then echo na
    elif cmp -s "$3" "$4"; then echo eq
    else echo ne; fi
  }
  en=$(pair "$eva" "$nat" "$W/eval.out"   "$W/native.out")
  nw=$(pair "$nat" "$wsm" "$W/native.out" "$W/wasm.out")
  ew=$(pair "$eva" "$wsm" "$W/eval.out"   "$W/wasm.out")

  # tier verdicts (pass/fail/na) for the tallies
  case "$en" in eq) t1=pass ;; ne) t1=fail ;; *) t1=na ;; esac
  case "$nw" in eq) t2=pass ;; ne) t2=fail ;; *) t2=na ;; esac
  t3=na
  if [ "$en" != na ] && [ "$nw" != na ] && [ "$ew" != na ]; then
    t3=pass
    [ "$en" = eq ] && [ "$nw" = eq ] && [ "$ew" = eq ] || t3=fail
  fi

  # -- absolute value pin (issue #86) ------------------------------------------
  # pin_v = "-"        no test/engine_value_pins/$key.pin for this fixture (the
  #                    overwhelming common case today — incremental corpus)
  #         "ok"       a .pin exists and every arm that `ran` matches it exactly
  #         "WRONG:<arms>"  a .pin exists and at least one arm that `ran`
  #                    does NOT match it (comma-joined list of the wrong arms)
  # An arm that did not `ran` is simply not checked — it degrades out, same as
  # the cross-engine pairs above degrade to `na` when an arm is unavailable.
  pin_v="-"
  pinfile="$PINDIR/$key.pin"
  if [ -f "$pinfile" ]; then
    pin_v=ok; wrong=""
    [ "$eva" = ran ] && { cmp -s "$pinfile" "$W/eval.out"   || wrong="${wrong}eval,"; }
    [ "$nat" = ran ] && { cmp -s "$pinfile" "$W/native.out" || wrong="${wrong}native,"; }
    [ "$wsm" = ran ] && { cmp -s "$pinfile" "$W/wasm.out"   || wrong="${wrong}wasm,"; }
    [ -n "$wrong" ] && pin_v="WRONG:${wrong%,}"
  fi

  printf '%s\t%s:%s:%s:%s:%s:%s\t%s\t%s\t%s\t%s\n' \
    "$key" "$en" "$nw" "$ew" "$eva" "$nat" "$wsm" "$t1" "$t2" "$t3" "$pin_v" > "$RESULTDIR/$slug.sig"

  {
    printf '  eval   [%-3s] %s\n' "$eva" "$(head -c 200 "$W/eval.out"   | tr '\n' '|')"
    printf '  native [%-3s] %s\n' "$nat" "$(head -c 200 "$W/native.out" | tr '\n' '|')"
    printf '  wasm   [%-3s] %s\n' "$wsm" "$(head -c 200 "$W/wasm.out"   | tr '\n' '|')"
    [ "$eva" = na ] && printf '  eval-why:   %s\n' "$(grep -m1 'runtime error' "$W/eval.err")"
    [ "$nat" = na ] && printf '  native-why: %s\n' "$(head -1 "$W/native.err")"
    # The CLI's wasm failure is a 2-3 line report (`error: <what>` then the tool's own
    # stderr), and the SECOND line is the diagnosis — so print the head, not the tail.
    [ "$wsm" = na ] && printf '  wasm-why:   %s\n' "$(head -3 "$W/wasm.err" | tr '\n' ' ')"
    [ "$pin_v" != - ] && printf '  pin        [%s] %s\n' "$pin_v" "$(head -c 200 "$pinfile" 2>/dev/null | tr '\n' '|')"
  } > "$RESULTDIR/$slug.detail"

  [ -n "${VERBOSE:-}" ] && printf '%-34s %s\n' "$key" "$agree:$eva:$nat:$wsm"
  rm -rf "$W"
  exit 0
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
# Genuine toolchain absence → exit 2, worded to MATCH run_gates.sh's LEGIT_SKIP_RE.
command -v clang >/dev/null 2>&1 || { echo "no C compiler (clang) on PATH — skipping the engine gate"; exit 2; }

# A missing oracle is NOT a legitimate skip: the gate would compare nothing.  Exit 2
# with a message that deliberately does NOT match LEGIT_SKIP_RE, so run_gates.sh
# reclassifies it as FAIL* (phantom skip: oracle/binary not built).
[ -x "$MEDAKA" ]  || { echo "the native compiler was never built (missing $MEDAKA) — run: make medaka"; exit 2; }
[ -x "$EVALBIN" ] || { echo "the eval oracle was never built (missing $EVALBIN) — run: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$EVALBIN")"; exit 2; }

# The wasm arm DEGRADES rather than skipping: with no wasm-tools / Node 24 we still
# run T1 (eval == native), the tier that removes the golden circularity.  Skipping
# the whole gate over an optional third arm would silently drop 300+ live two-engine
# comparisons — the exact failure mode docs/ops/TESTING-DESIGN.md §2.3 indicts.
WASM_OK=1; WASM_OFF_WHY=""
NODE="${NODE:-node}"
if ! [ -x "$WASMBIN" ]; then
  WASM_OK=0; WASM_OFF_WHY="test/bin/wasm_emit_modules_main not built (sh test/wasm/build_wasm_oracle.sh)"
elif ! command -v wasm-tools >/dev/null 2>&1; then
  WASM_OK=0; WASM_OFF_WHY="wasm-tools not on PATH"
else
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [ "$major" -lt 24 ]; then
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
    major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  fi
  if [ "$major" -lt 24 ]; then
    WASM_OK=0; WASM_OFF_WHY="Node >= 24 required for finalized WasmGC (have $($NODE --version 2>/dev/null))"
  else
    NODE="$(command -v "$NODE")"
  fi
fi

# ── MEDAKA_REQUIRE_WASM — the degradation is right for a dev box, WRONG for CI ──
#
# Default-off, so a dev box with no wasm toolchain keeps the honest, announced
# degradation above (T1 still gates fully).  CI's `engines` shard sets it to 1: there
# the toolchain is GUARANTEED, so an unavailable wasm arm means the WIRING broke, and
# a wiring break must never again be reported as a green two-engine run (#597).
#
# ⚠️ `exit 1`, NOT `exit 2`.  run_gates.sh:47 carries
#     LEGIT_SKIP_RE='no C compiler|libgc \(bdw-gc\)|not on PATH'
# and this gate's own reason string is "wasm-tools not on PATH" — which MATCHES that
# regex.  An exit 2 would therefore be reclassified at run_gates.sh:101 as a
# LEGITIMATE skip and the shard would stay GREEN — reintroducing the exact silence
# this flag exists to abolish.  exit 1 is an unconditional FAIL.  Verified by hand:
#     echo 'wasm-tools not on PATH' | grep -qE 'no C compiler|libgc \(bdw-gc\)|not on PATH'  -> match
if [ "${MEDAKA_REQUIRE_WASM:-0}" = 1 ] && [ "$WASM_OK" != 1 ]; then
  echo "MEDAKA_REQUIRE_WASM=1 but the wasm arm is unavailable: $WASM_OFF_WHY" >&2
  echo "  the engines shard guarantees wasm-tools + Node 24 + test/bin/wasm_emit_modules_main;" >&2
  echo "  if this fired in CI the toolchain wiring regressed — see .github/workflows/ci.yml (engines shard)." >&2
  exit 1
fi

[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"
# `medaka build --target wasm` reads the compiled wasm emitter from here (build_cmd.mdk);
# without it the CLI falls back to `medaka run`ning the emitter entry, which cannot
# resolve the `args` extern.  Exactly the MEDAKA_EMITTER contract, one target over.
[ "$WASM_OK" = 1 ] && export MEDAKA_WASM_EMITTER="$WASMBIN"

WORK="$(mktemp -d)"; RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

# CI FAST PATH: precompile runtime/medaka_rt.c ONCE for the whole gate run, then
# point every per-fixture `medaka build` at it via MEDAKA_RT_OBJ. Otherwise each
# of the ~300 native builds recompiles the byte-identical runtime from scratch
# (~0.6s of clang each). The COMPILER produces the object (`--emit-rt-obj`) with
# exactly the flags its own link uses, so it can't drift; the inline-vs-prebuilt
# binary is proven byte-identical by test/diff_compiler_rt_obj.sh. Best-effort:
# if the precompile fails we simply don't export it and every build falls back to
# the (unchanged) inline compile. medaka_rt.c can't change mid-run, so a single
# object built at startup has no staleness surface.
RTOBJ="$WORK/medaka_rt.o"
if MEDAKA_ROOT="$ROOT" "$MEDAKA" build --emit-rt-obj "$RTOBJ" >/dev/null 2>&1 && [ -f "$RTOBJ" ]; then
  export MEDAKA_RT_OBJ="$RTOBJ"
fi

# CI FAST PATH #2 (issue #118): the same trick one level up, and a much bigger win.
# The PRELUDE is 88% of a small program's emitted IR (270 of 281 defines on a
# nine-line fixture), and clang -O2 re-optimises all of it on every one of these
# ~346 builds. Precompile it ONCE and point every build at it via
# MEDAKA_PRELUDE_OBJ; each build then only compiles its own code plus its
# per-program `@mdk_disp_*` dispatchers. Same discipline as the runtime object
# above: the COMPILER emits it (`--emit-prelude-obj`) with exactly the flags its own
# link uses, so they cannot drift; stdlib/core.mdk can't change mid-run, so a single
# object built at startup has no staleness surface; and it is best-effort — if the
# precompile fails we don't export it and every build falls back to the (unchanged)
# inline path. The two link paths are proven to produce identically-behaving programs
# by test/diff_compiler_prelude_obj.sh.
#
# This gate running ON the fast path is deliberate, and is the strongest validation
# it gets: 346 fixtures × 3 engines, every native arm built against the shared
# prelude.o, differentially compared against eval and wasm. A prelude.o that baked in
# anything program-specific cannot survive that.
PRELUDEOBJ="$WORK/prelude.o"
if MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="${MEDAKA_EMITTER:-}" \
     "$MEDAKA" build --emit-prelude-obj "$PRELUDEOBJ" >/dev/null 2>&1 && [ -f "$PRELUDEOBJ" ]; then
  export MEDAKA_PRELUDE_OBJ="$PRELUDEOBJ"
fi

# All FOUR emitter corpora — the two untyped (prelude-free) and, since the wasm arm
# moved onto the shipping CLI, the two TYPED ones as well.  See the header.
CORPUS="$(ls "$ROOT"/test/llvm_fixtures/*.mdk \
             "$ROOT"/test/llvm_fixtures_typed/*.mdk \
             "$ROOT"/test/wasm/fixtures/*.mdk \
             "$ROOT"/test/wasm/fixtures_typed/*.mdk 2>/dev/null)"
[ -n "$CORPUS" ] || { echo "the fixture corpus is empty — the gate compared nothing"; exit 2; }

# Fan-out. NOTE this gate deliberately does NOT honour run_gates.sh's INNER_JOBS
# (which it exports to every gate as $JOBS, default 3). Every other gate is a
# cheap text diff; this one shells out to clang + node once per fixture across a
# ~346-fixture corpus, so it is the suite's long pole by an order of magnitude
# (~295s vs ~32s for all the others combined). Throttling it to 3 would make the
# whole suite wait on it. Because it dominates, the other gates have all finished
# within the first ~30s and it then runs essentially alone — so a wider pool costs
# nothing in contention. Override with ENGINE_JOBS (e.g. ENGINE_JOBS=2 on a shared
# or loaded box). Measured on 12 cores: JOBS=3 ~5min, 4 ~3.7min, 6 ~2.5min.
NCPU="$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
JOBS="${ENGINE_JOBS:-$(( NCPU / 2 ))}"
[ "${JOBS:-0}" -ge 2 ] 2>/dev/null || JOBS=2
printf '%s\n' "$CORPUS" \
  | MEDAKA="$MEDAKA" EVALBIN="$EVALBIN" WASMBIN="$WASMBIN" RUNTIME="$RUNTIME" CORE="$CORE" \
    STDLIB="$STDLIB" RUNJS="$RUNJS" NODE="$NODE" TIMEOUT="$TIMEOUT" VERBOSE="${VERBOSE:-}" \
    WASM_OK="$WASM_OK" MEDAKA_EMITTER="${MEDAKA_EMITTER:-}" \
    MEDAKA_WASM_EMITTER="${MEDAKA_WASM_EMITTER:-}" \
    MEDAKA_RT_OBJ="${MEDAKA_RT_OBJ:-}" \
    MEDAKA_PRELUDE_OBJ="${MEDAKA_PRELUDE_OBJ:-}" \
    WORKDIR="$WORK" RESULTDIR="$RESULTS" \
    xargs -P "$JOBS" -n 1 -I{} bash "$0" --one {}

cat "$RESULTS"/*.sig 2>/dev/null | sort > "$WORK/all.tsv"
compared=$(wc -l < "$WORK/all.tsv" | tr -d ' ')
[ "$compared" -gt 0 ] || { echo "ZERO-COMPARISON: not one fixture produced a result — the gate did not run"; exit 2; }

# ── CAPTURE: rewrite the ledger from the observed signatures ──────────────────
# Emits a line only for a fixture that is NOT clean.  The category+reason text is
# carried over from the existing ledger where the key survives; a NEW divergence gets
# a literal TODO a human must fill in, so a fresh bug can never slip in wearing a
# plausible-looking excuse it inherited from its neighbours.
if [ -n "${CAPTURE:-}" ]; then
  {
    sed -n '1,/^# Regenerate with CAPTURE=1/p' "$LEDGER" 2>/dev/null
    echo
    while IFS=$'\t' read -r key sig _t1 _t2 _t3; do
      [ "$sig" = "eq:eq:eq:ran:ran:ran" ] && continue
      old="$(awk -v k="$key" '$1==k { for (i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"") }' "$LEDGER" 2>/dev/null | head -1)"
      [ -n "$old" ] || old="TODO TODO-diagnose-this-new-divergence"
      printf '%-34s %-26s %s\n' "$key" "$sig" "$old"
    done < "$WORK/all.tsv"
  } > "$LEDGER.new"
  mv "$LEDGER.new" "$LEDGER"
  echo "captured $LEDGER — REVIEW THE DIFF, and replace any TODO with a real diagnosis"
fi

# ── Compare each fixture's signature against the ledger ───────────────────────
# expected(key) = the ledger's signature, else "agree:ran:ran:ran" (i.e. clean).
regress=0; promote=0; clean=0; known=0; unverified=0; pinfail=0
CLEAN="eq:eq:eq:ran:ran:ran"
[ "$WASM_OK" = 1 ] || CLEAN="eq:-:-:ran:ran:-"
: >"$WORK/regress.txt"; : >"$WORK/promote.txt"; : >"$WORK/pinfail.txt"

while IFS=$'\t' read -r key sig t1 t2 t3 pin_v; do
  exp="$(awk -v k="$key" '$1==k {print $2}' "$LEDGER" 2>/dev/null | head -1)"
  led=1; [ -n "$exp" ] || { exp="eq:eq:eq:ran:ran:ran"; led=0; }

  # wasm arm off → blank the three wasm-dependent fields (nw, ew, w) on BOTH sides.
  # The eval-vs-native verdict (en) and both arms survive, so T1 still gates FULLY
  # and soundly — no silent drop, no spurious regression.
  if [ "$WASM_OK" != 1 ]; then
    sig="$(echo "$sig" | awk -F: '{print $1":-:-:"$4":"$5":-"}')"
    exp="$(echo "$exp" | awk -F: '{print $1":-:-:"$4":"$5":-"}')"
    unverified=$((unverified+1))
  fi

  if [ "$sig" = "$exp" ]; then
    if [ "$led" = 1 ]; then known=$((known+1)); else clean=$((clean+1)); fi
  elif [ "$led" = 1 ] && [ "$sig" = "$CLEAN" ]; then
    promote=$((promote+1))
    printf 'PROMOTE  %s\n  ledger asserts: %s\n  actual now:     %s   ← it PASSES\n  → delete its line from test/engine_divergence.txt (and note the fix in test/ENGINE-DIVERGENCE.md)\n\n' \
      "$key" "$exp" "$sig" >> "$WORK/promote.txt"
  else
    regress=$((regress+1))
    { printf 'REGRESS  %s\n  expected: %s\n  actual:   %s\n' "$key" "$exp" "$sig"
      cat "$RESULTS/${key//\//__}.detail" 2>/dev/null
      echo; } >> "$WORK/regress.txt"
  fi

  # -- absolute value pin (issue #86) ------------------------------------------
  # Independent of the agree/disagree signature above: a PINFAIL fires even when
  # sig==exp==eq:eq:eq (all engines agreeing but disagreeing with the pin is
  # exactly what a pin exists to catch — the whole point per #86).
  case "$pin_v" in
    WRONG:*)
      pinfail=$((pinfail+1))
      { printf 'PINFAIL  %s\n  pin file: test/engine_value_pins/%s.pin\n  expected: %s\n  wrong on: %s\n' \
          "$key" "$key" "$(cat "$PINDIR/$key.pin" 2>/dev/null | tr '\n' '|')" "${pin_v#WRONG:}"
        cat "$RESULTS/${key//\//__}.detail" 2>/dev/null
        echo; } >> "$WORK/pinfail.txt"
      ;;
  esac
done < "$WORK/all.tsv"

tier() { awk -F'\t' -v c="$1" -v v="$2" '$c==v' "$WORK/all.tsv" | wc -l | tr -d ' '; }
t1p=$(tier 3 pass); t1f=$(tier 3 fail); t1n=$(tier 3 na)
t2p=$(tier 4 pass); t2f=$(tier 4 fail); t2n=$(tier 4 na)
t3p=$(tier 5 pass); t3f=$(tier 5 fail); t3n=$(tier 5 na)

echo
echo "══════════════════════════════════════════════════════════════════════"
echo " 3-ENGINE DIFFERENTIAL — $compared fixtures (llvm ∪ llvm_typed ∪ wasm ∪ wasm_typed)"
echo "══════════════════════════════════════════════════════════════════════"
printf ' T1  eval   == native   %4d agree  %3d differ  %3d n/a\n' "$t1p" "$t1f" "$t1n"
if [ "$WASM_OK" = 1 ]; then
  printf ' T2  native == wasm     %4d agree  %3d differ  %3d n/a\n' "$t2p" "$t2f" "$t2n"
  printf ' T3  all three agree    %4d agree  %3d differ  %3d n/a\n' "$t3p" "$t3f" "$t3n"
else
  printf ' T2  native == wasm     NOT RUN — %s\n' "$WASM_OFF_WHY"
  printf ' T3  all three agree    NOT RUN — wasm arm unavailable (T1 still gates)\n'
fi
echo "──────────────────────────────────────────────────────────────────────"
printf ' clean                  %4d\n' "$clean"
printf ' known (ledgered)       %4d   test/engine_divergence.txt\n' "$known"
printf ' REGRESSIONS            %4d\n' "$regress"
printf ' PROMOTIONS (now pass)  %4d\n' "$promote"
printf ' PINFAIL (value pins)   %4d   test/engine_value_pins/\n' "$pinfail"
echo "══════════════════════════════════════════════════════════════════════"

[ "$regress" -gt 0 ] && { echo; cat "$WORK/regress.txt"; }
if [ "$promote" -gt 0 ]; then
  echo
  cat "$WORK/promote.txt"
  echo "A known-failure entry started PASSING.  That is good news and a HARD FAIL:"
  echo "the ledger must be promoted, or the fix will silently rot back later."
fi
if [ "$pinfail" -gt 0 ]; then
  echo
  cat "$WORK/pinfail.txt"
  echo "An absolute value pin does not match live output — ALL THREE ENGINES MAY"
  echo "STILL AGREE (a cross-engine PASS does not imply a PINFAIL here is spurious):"
  echo "that unanimous-but-wrong shape is exactly what test/engine_value_pins/ exists"
  echo "to catch.  Fix the engine(s), or if the pin itself was wrong, fix the pin —"
  echo "either way, HARD FAIL."
fi

# Never report success having compared nothing.
if [ "$t1p" -eq 0 ] && [ "$t2p" -eq 0 ]; then
  echo "ZERO-COMPARISON: no tier made a single passing comparison — the gate did not run"
  exit 1
fi

# ── The same lie, one level down (#597) ───────────────────────────────────────
# An empty corpus satisfies every check above vacuously: zero fixtures means zero
# REGRESS, zero PROMOTE, zero PINFAIL — a green report about nothing.
if [ "$compared" -eq 0 ]; then
  echo "ZERO-CORPUS: not a single fixture was enumerated — the gate compared nothing" >&2
  exit 1
fi

# And under REQUIRE_WASM, WASM_OK=1 only proves the TOOLCHAIN is present, not that the
# wasm arm ever ran over a fixture.  A corpus-selection bug that fed T2 zero fixtures
# would otherwise report a green "T2 native == wasm  0 agree  0 differ" — the wiring
# check passing while the comparison it guards never happened.
if [ "${MEDAKA_REQUIRE_WASM:-0}" = 1 ] && [ "$((t2p + t2f))" -eq 0 ]; then
  echo "MEDAKA_REQUIRE_WASM=1 and the wasm toolchain is present, but T2 (native == wasm)" >&2
  echo "  ran over ZERO fixtures ($t2p agree / $t2f differ / $t2n n/a of $compared) — a" >&2
  echo "  corpus-selection bug, not a green run." >&2
  exit 1
fi

[ "$regress" -eq 0 ] && [ "$promote" -eq 0 ] && [ "$pinfail" -eq 0 ]
