#!/bin/sh
# capture_goldens.sh — REROOT-PLAN §3a / Phase 1.
#
# Capture reference output into committed `.golden` siblings.  (Historical note:
# this originally captured the OCaml oracle while it was TRUSTED.  The OCaml
# compiler was REMOVED 2026-06-26 — the goldens are now checked-in NATIVE output,
# re-captured from the native `test/bin/*` stage binaries; there is no external
# oracle to disagree with.)  These goldens are the reference the re-rooted gates
# diff the native stage against.  Run MANUALLY at soak checkpoints, never in the
# gate loop.
#
# PURELY ADDITIVE: writes `.golden` files next to each fixture; touches no gate.
#
# Output is LOCATION-FREE and DETERMINISTIC (eval_probe prints `pp_value` of
# `main`, no source positions), mirroring the existing `.golden`/`.expected`/
# `.sexp` conventions.  Re-running re-derives byte-identical goldens.
#
# DRIVER TABLE.  Each row: <fixture-glob> | <oracle-command-template> | <suffix>.
# %f in the template is the fixture path.  Add rows here as later phases capture
# more surfaces (front-end dumps via gen_golden, construct binary output, …).
# Phase 1 captures the eval_probe VALUE goldens — the largest A cluster (217
# fixtures across 13 gates), here the two no-golden dirs that block them:
#   test/eval_fixtures/*.mdk  (20)   eval engine value oracle
#   test/llvm_fixtures/*.mdk  (180)  the emitted program's runtime stdout, which
#                                    the LLVM gate diffs against eval_probe (the
#                                    value is position-free; the IR is not — see
#                                    MEMORY "Diff gates compare OUTPUT not IR").
#
# Usage:
#   sh test/capture_goldens.sh            capture all rows
#   sh test/capture_goldens.sh eval       capture only rows whose suffix-tag matches
#   sh test/capture_goldens.sh --check    DON'T write; re-derive to a temp and diff
#                                         vs committed goldens (determinism / drift
#                                         check).  Non-zero exit on any mismatch.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# NATIVE Stage-4 oracles (OCaml-free).
MAIN="${MAIN:-$ROOT/medaka}"
CORE="$ROOT/stdlib/core.mdk"; LIST="$ROOT/stdlib/list.mdk"; RUNTIME="$ROOT/stdlib/runtime.mdk"
FMT_NATIVE="$ROOT/test/bin/fmt_main"
PRINTER_NATIVE="$ROOT/test/bin/printer_main"

CHECK=0
FILTER=""
FROZEN_TAG=""
case "${1:-}" in
  --check) CHECK=1 ;;
  --frozen)
    FROZEN_TAG="${2:-}"
    [ -n "$FROZEN_TAG" ] || {
      echo "usage: sh test/capture_goldens.sh --frozen <parse|desugar|mark|fmt|printer|boot_parse|boot_desugar|boot_mark|boot_typecheck|selfproc_legA>"
      exit 2
    }
    ;;
  "") ;;
  *) FILTER="$1" ;;
esac

# --frozen <tag> : EXPLICITLY regenerate ONE frozen family (see the FROZEN list
# below) by re-running the EXACT `test/bin/<stage>_main` invocation + strip_unit
# that the corresponding diff_compiler_*.sh / bootstrap_*.sh gate uses to produce
# its "actual" side — so the regenerated golden is guaranteed to be what that gate
# compares against. Needs only the stage oracle binaries (`sh test/build_oracles.sh
# --build-one <entry>`, or the full test/build_oracles.sh), NOT $MAIN. Deliberately
# opt-in — a bare `capture_goldens.sh` / `--check` never touches these, so the
# "these families are frozen" default is unchanged; this only fires when a
# developer follows a gate's "no golden ... run sh test/capture_goldens.sh --frozen
# <tag>" hint on purpose.
if [ -n "$FROZEN_TAG" ]; then
  strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }
  BIN="$ROOT/test/bin"
  CORE="$ROOT/stdlib/core.mdk"
  DM_CORPUS="$ROOT/stdlib/*.mdk $ROOT/test/diff_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk $ROOT/compiler/frontend/*.mdk $ROOT/compiler/types/*.mdk $ROOT/compiler/ir/*.mdk $ROOT/compiler/backend/*.mdk $ROOT/compiler/eval/*.mdk $ROOT/compiler/driver/*.mdk $ROOT/compiler/tools/*.mdk $ROOT/compiler/support/*.mdk"

  fwrote=0
  # regen_frozen <run-binary> <golden-suffix> <extra-first-arg-or-""> <globs...>
  regen_frozen() {
    run_bin="$1"; suffix="$2"; extra="$3"; shift 3
    RUN="$BIN/$run_bin"
    [ -x "$RUN" ] || { echo "missing $RUN — run: sh test/build_oracles.sh --build-one $run_bin (or sh test/build_oracles.sh)"; return 2; }
    for glob in "$@"; do
      for f in $glob; do
        [ -f "$f" ] || continue
        golden="${f%.mdk}.$suffix"
        if [ -n "$extra" ]; then
          "$RUN" "$extra" "$f" 2>/dev/null | strip_unit | sed "s#$ROOT/##g" > "$golden"
        else
          "$RUN" "$f" 2>/dev/null | strip_unit | sed "s#$ROOT/##g" > "$golden"
        fi
        fwrote=$((fwrote+1))
      done
    done
  }

  case "$FROZEN_TAG" in
    parse)
      regen_frozen parse_main parse.golden "" \
        "$ROOT/test/parse_fixtures/*.mdk" "$ROOT/test/parse_only_fixtures/*.mdk" ;;
    desugar)
      regen_frozen desugar_main desugar.golden "" $DM_CORPUS ;;
    mark)
      regen_frozen mark_main mark.golden "$CORE" $DM_CORPUS ;;
    fmt)
      regen_frozen fmt_main fmt.golden "" \
        "$ROOT/test/fmt_fixtures/*.mdk" "$ROOT/test/parse_fixtures/*.mdk" ;;
    printer)
      regen_frozen printer_main printer.golden "" "$ROOT/test/parse_fixtures/*.mdk" ;;
    boot_parse)
      regen_frozen parse_main boot_parse.golden "" "$ROOT/test/parse_fixtures/*.mdk" ;;
    boot_desugar)
      regen_frozen desugar_main boot_desugar.golden "" "$ROOT/test/parse_fixtures/*.mdk" ;;
    boot_mark)
      regen_frozen mark_main boot_mark.golden "$CORE" "$ROOT/test/parse_fixtures/*.mdk" ;;
    selfproc_legA)
      # Mirrors LEG A of test/diff_compiler_selfproc.sh EXACTLY: one full-closure
      # check_all_main run over all_modules_entry.mdk, split by `## MODULE <mid>`,
      # one golden per module id (LC_ALL=C sorted, matching the gate's own sort
      # before comparing). No OCaml oracle exists for this leg any more — the
      # native self-hosted front-end's own output IS the reference (like every
      # other FROZEN native-canonical family in this file).
      CHECK_ALL="$BIN/check_all_main"
      [ -x "$CHECK_ALL" ] || { echo "missing $CHECK_ALL — run: sh test/build_oracles.sh --build-one check_all_main"; exit 2; }
      RUNTIME="$ROOT/stdlib/runtime.mdk"
      ENTRY="$ROOT/compiler/entries/all_modules_entry.mdk"
      LEGA_GOLD="$ROOT/test/selfproc_goldens/legA"
      mkdir -p "$LEGA_GOLD"
      ALL="$(mktemp)"
      trap 'rm -f "$ALL"' EXIT
      "$CHECK_ALL" "$RUNTIME" "$CORE" "$ENTRY" "$ROOT/compiler" "$ROOT/stdlib" 2>/dev/null > "$ALL"
      MODULES="frontend.ast frontend.lexer frontend.parser ir.sexp frontend.desugar frontend.marker types.annotate frontend.resolve frontend.exhaust driver.loader types.typecheck eval.eval tools.check"
      for m in $MODULES; do
        awk -v M="$m" '/^## MODULE /{cur=($3==M)?1:0; next} cur{print}' "$ALL" | LC_ALL=C sort > "$LEGA_GOLD/$m.golden"
        fwrote=$((fwrote+1))
      done
      rm -f "$ALL"; trap - EXIT
      ;;
    boot_typecheck)
      regen_frozen typecheck_main boot_typecheck.golden "" "$ROOT/test/typecheck_fixtures/*.mdk" ;;
    *)
      echo "unknown --frozen tag: $FROZEN_TAG (expected parse|desugar|mark|fmt|printer|boot_parse|boot_desugar|boot_mark|boot_typecheck|selfproc_legA)"
      exit 2 ;;
  esac
  status=$?
  [ "$status" -eq 0 ] || exit "$status"
  printf 'CAPTURED (frozen %s): %d goldens written\n' "$FROZEN_TAG" "$fwrote"
  exit 0
fi

[ -x "$MAIN" ]  || { echo "build first: make medaka (missing $MAIN)"; exit 2; }

# ── driver table ───────────────────────────────────────────────────────────────
# oracle_<tag> <fixture> -> stdout.
oracle_run_file()    { "$MAIN" run "$1"; }                             # eval_dict / eval_typed / core_ir_typed
oracle_print_probe() { "$PRINTER_NATIVE" "$1" 2>/dev/null | sed '$ s/()$//; ${/^$/d;}'; }  # printer reprint (NATIVE; strip_unit to match the gate)

# FROZEN families (dev/ OCaml probes had no native equivalent; goldens committed as-is):
#   eval / eval_prelude / eval_list (eval_probe.exe)
#   lextok (lextok.exe)
#   parse / desugar / mark (astdump.exe)
#   positions_dump (positions_dump.exe)
#   comment_dump (comment_dump.exe)
#   tc_probe / tc_module / tcmod (tc_probe.exe / tc_module_probe.exe)
#   diag_analyze / resolve / exhaust / check_match (diagdump.exe)
#   parse_result (astdump.exe)
#   stack (eval_probe.exe)
#
# Of these, parse / desugar / mark / fmt / printer (and their boot_parse /
# boot_desugar / boot_mark siblings) now HAVE a native equivalent
# (test/bin/{parse,desugar,mark,fmt,printer}_main, built by test/build_oracles.sh)
# — they stay frozen by DEFAULT (a plain `capture_goldens.sh` run must not churn
# them), but a developer who hits a gate's "no golden ... run sh
# test/capture_goldens.sh --frozen <tag>" hint can regenerate that ONE family on
# purpose via `sh test/capture_goldens.sh --frozen <tag>` (see the FROZEN_TAG
# block below) instead of hand-replicating the gate's capture invocation.

# rows: "<glob>::<oracle-tag>::<golden-suffix>"
# FROZEN families omitted (eval/eval_prelude/eval_list/positions_dump/comment_dump/
# tc_probe/diag_analyze — OCaml dev/ probes, no native equivalent;
# fmt/print_probe — require test/bin/fmt_main + printer_main which need a fresh
# native build; eval_typed_modules/build_*/test/new/native_cli — require an
# up-to-date native binary to reproduce committed goldens).
ROWS="
$ROOT/test/eval_dict_fixtures/*.mdk::run_file::eval.golden
$ROOT/test/eval_typed_fixtures/*.mdk::run_file::eval.golden
"

total=0 wrote=0 mism=0 fixtures=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# emit_golden <golden-path> <cmd...> : run cmd (stderr/exit ignored, mirroring the
# gates), then write/check its stdout against <golden-path>.  Honours $FILTER via
# the caller (callers gate themselves on the suffix tag).  Updates fixtures/wrote/mism.
emit_golden() {
  golden="$1"; shift
  fixtures=$((fixtures+1))
  out="$TMP/out"
  # Strip the repo-root prefix: no golden should bake the absolute build path
  # (some subcommands, e.g. `test`, echo the fixture path) — keep goldens
  # worktree-relative and stable. Gates that echo paths strip the same.
  "$@" 2>/dev/null | sed "s#$ROOT/##g" > "$out" || true
  if [ "$CHECK" -eq 1 ]; then
    if [ -f "$golden" ] && cmp -s "$out" "$golden"; then :
    else
      mism=$((mism+1))
      if [ ! -f "$golden" ]; then echo "MISSING  $golden"
      else echo "DRIFT    $golden"; diff "$golden" "$out" | head -6 | sed 's/^/    /'; fi
    fi
  else
    cp "$out" "$golden"; wrote=$((wrote+1))
  fi
}

# emit_to <golden> <precomputed-out-file>: like emit_golden but the output was
# already produced into $2 (used where the oracle needs post-processing, e.g. sort).
emit_to() {
  golden="$1"; src="$2"; fixtures=$((fixtures+1))
  if [ "$CHECK" -eq 1 ]; then
    if [ -f "$golden" ] && cmp -s "$src" "$golden"; then :
    else
      mism=$((mism+1))
      if [ ! -f "$golden" ]; then echo "MISSING  $golden"
      else echo "DRIFT    $golden"; diff "$golden" "$src" | head -6 | sed 's/^/    /'; fi
    fi
  else
    mkdir -p "$(dirname "$golden")"; cp "$src" "$golden"; wrote=$((wrote+1))
  fi
}

for row in $ROWS; do
  [ -n "$row" ] || continue
  glob="${row%%::*}"; rest="${row#*::}"
  tag="${rest%%::*}"; suffix="${rest#*::}"
  # suffix-tag filter (match against the suffix's leading word, e.g. "eval")
  if [ -n "$FILTER" ]; then
    case "$suffix" in "$FILTER"*) ;; *) case "$tag" in "$FILTER"*) ;; *) continue ;; esac ;; esac
  fi
  total=$((total+1))
  for f in $glob; do
    [ -f "$f" ] || continue
    golden="${f%.mdk}.$suffix"
    # Mirror the gates exactly: the oracle PRODUCT is stdout; stderr is discarded
    # and the exit code is ignored (the gates use `$("$PROBE" "$f" 2>/dev/null)`).
    # This is load-bearing for the abort/panic fixtures (e.g. llvm_fixtures/
    # abort_exit_nonzero, abort_panic): they exit non-zero with EMPTY stdout, and
    # the gate compares that empty stdout against the native binary's empty stdout.
    # So the correct golden is an empty file, NOT a skip.
    emit_golden "$golden" "oracle_$tag" "$f"
  done
done

# ── directory + compiler-oracle fixtures (not a single-glob/single-arg shape) ──
# These goldens are captured from the EXACT OCaml oracle each gate used (a compiler
# entry run via main.exe, or `main.exe run <entry>` per fixture dir), so the
# re-rooted gate diffs its native host's stdout against this committed reference.

want() {  # want <tag> : true if no FILTER, or FILTER prefixes the tag/"eval"
  [ -z "$FILTER" ] && return 0
  case "eval" in "$FILTER"*) return 0 ;; esac
  case "$1" in "$FILTER"*) return 0 ;; esac
  return 1
}

# eval_modules : golden = native `./medaka run <entry>` per dir.
# (Fixture files are plain Medaka programs — no compiler args() dependency —
#  so the native interpreter produces byte-identical output to the OCaml oracle.)
if want eval_modules; then
  total=$((total+1))
  for dir in "$ROOT"/test/eval_modules_fixtures/*/; do
    [ -d "$dir" ] || continue
    entry="$(ls "$dir"main_*.mdk 2>/dev/null | head -1)"
    [ -n "$entry" ] || continue
    emit_golden "${dir%/}/main.eval.golden" "$MAIN" run "$entry"
  done
fi

# eval_typed_modules : FROZEN — committed goldens require the current native binary;
# the worktree binary may be stale relative to the June 26 default-method
# specialization changes (commit 265b0a2).  Re-capture after Phase 3 rebuild.

# print_probe : FROZEN — requires test/bin/printer_main (built by build_oracles.sh
# after a full native rebuild in Phase 3).  Committed .printer.golden are the reference.

# stack : FROZEN (native canonical; eval_probe.exe had no native equivalent —
# LIB-REMOVAL-DESIGN §6 Stage B/D).  Committed goldens are the reference.


# selfproc : FROZEN — selfproc_*_probe.mdk entries call args() (native-only extern);
# `./medaka run` (interpreter) returns empty output → cannot recapture.
# Committed selfproc_goldens/*.golden files are the reference for diff_compiler_selfproc.sh.

# ── §2b multi-glob corpus gates (parse / desugar / mark / lex_files) ──────────
# These read a multi-directory corpus that the line-split ROWS loop can't express
# (one row = one glob token), so capture them here with explicit globs.  The gate
# applies its own `norm` (float-text) to BOTH golden and native output, so we
# capture the RAW oracle dump.

# parse : FROZEN (native canonical; astdump.exe had no native equivalent —
# LIB-REMOVAL-DESIGN §6 Stage B/D).  Committed .parse.golden files are the reference.

# desugar + mark : FROZEN (native canonical; astdump.exe --desugar/--mark had no
# native equivalent).  Committed .desugar.golden/.mark.golden files are the reference.
DM_CORPUS="$ROOT/stdlib/*.mdk $ROOT/test/diff_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk $ROOT/compiler/frontend/*.mdk $ROOT/compiler/types/*.mdk $ROOT/compiler/ir/*.mdk $ROOT/compiler/backend/*.mdk $ROOT/compiler/eval/*.mdk $ROOT/compiler/driver/*.mdk $ROOT/compiler/tools/*.mdk $ROOT/compiler/support/*.mdk"

# parse_result : FROZEN (native canonical; astdump.exe had no native equivalent).
# Committed .parse_result_oracle files are the reference.

# lex_files : FROZEN (native canonical; lextok.exe had no native equivalent).
# Committed .lextok.golden files are the reference.

# check_modules / tcmod : FROZEN (native canonical; tc_module_probe.exe had no
# native equivalent).  Committed oracle.tcmod files are the reference.

# analyze_project fixtures : FROZEN — native `./medaka check --json` produces a
# different file-traversal order than the OCaml oracle; committed oracle.json files
# were captured from the OCaml oracle.  diff_compiler_analyze_project.sh compares
# by basename (ordering-insensitive), so the existing goldens remain valid.
# Re-root by running `./medaka check --json` with sorted output if goldens need refresh.

# capture_boot : FROZEN — all stage_main entries (lex_main, parse_main, desugar_main,
# resolve_main, mark_main, typecheck_main, eval_main) call args() (native-only extern);
# `./medaka run` (interpreter) returns empty output → cannot recapture via interpreter.
# Committed .boot_*.golden files (captured from the NATIVE binary) are the reference
# for bootstrap_*.sh gates.  Re-mint by running the compiled stage binaries directly.

# ── §2c TOOLING goldens (fmt / test) ──────────────────────────────────────────
# fmt : FROZEN — requires test/bin/fmt_main (built by build_oracles.sh after a
# full native rebuild).  Missing binary produces empty output → would clobber
# committed .fmt.golden files.  Re-capture after Phase 3 rebuild + build_oracles.sh.
# test : FROZEN — `medaka test` output depends on the current native binary; the
# worktree binary may be stale.  Re-capture after Phase 3 rebuild.
# new  : FROZEN — scaffold tree from `medaka new` depends on current binary.
#        Re-capture after Phase 3 rebuild.

# ── §2d build goldens : FROZEN ──────────────────────────────────────────────────
# build_cmd / build_diff / build_construct committed *.build.golden files require
# the current native binary (stale worktree binary produces different output).
# Re-capture after Phase 3 rebuild.  The capture_build_golden function is kept for
# use by the native_cli build subsection below.
capture_build_golden() {  # $1=fixture .mdk  $2=golden path
  src="$1"; golden="$2"; fixtures=$((fixtures+1))
  bin="$TMP/cb.bin"; out="$TMP/cb.out"
  rm -f "$bin"
  perl -e 'alarm 180; exec @ARGV' -- "$MAIN" build "$src" -o "$bin" >/dev/null 2>&1 || true
  if [ -x "$bin" ]; then "$bin" > "$out" 2>/dev/null || true; else : > "$out"; fi
  if [ "$CHECK" -eq 1 ]; then
    if [ -f "$golden" ] && cmp -s "$out" "$golden"; then :
    else mism=$((mism+1)); [ -f "$golden" ] && { echo "DRIFT $golden"; diff "$golden" "$out" | head -6 | sed 's/^/    /'; } || echo "MISSING $golden"; fi
  else
    cp "$out" "$golden"; wrote=$((wrote+1))
  fi
}

# ── §2d `repl` golden — captured from the NATIVE repl (CANONICAL), NOT OCaml ──
# DESIGN CALL (flagged for maintainer): the OCaml `medaka repl` and the self-hosted
#   repl diverge on the post-error command sequence — after an unbound-variable line
#   the OCaml repl keeps emitting prompts for the remaining commands; the compiler
#   repl (both interpreted AND native-compiled, which AGREE byte-for-byte) stops
#   short.  Per REROOT-PLAN the self-hosted backend is CANONICAL, so the golden is
#   captured from the NATIVE repl binary (test/bin/repl_main), the OCaml leg is
#   dropped, and diff_compiler_repl.sh gates native-vs-golden.  The native output is
#   DETERMINISTIC across runs (the :browse sort bug was fixed in cc49e60).
if want repl; then
  total=$((total+1)); fixtures=$((fixtures+1))
  REPL_BIN="$ROOT/test/bin/repl_main"
  REPL_IN="$ROOT/test/repl_fixtures/session.in"
  golden="$ROOT/test/repl_fixtures/session.golden"
  out="$TMP/repl_out"
  if [ -x "$REPL_BIN" ] && [ -f "$REPL_IN" ]; then
    perl -e 'alarm 120; exec @ARGV' -- "$REPL_BIN" "$RUNTIME" "$CORE" \
      < "$REPL_IN" > "$out" 2>/dev/null || true
    if [ "$CHECK" -eq 1 ]; then
      if [ -f "$golden" ] && cmp -s "$out" "$golden"; then :
      else mism=$((mism+1)); [ -f "$golden" ] && { echo "DRIFT $golden"; diff "$golden" "$out" | head -6 | sed 's/^/    /'; } || echo "MISSING $golden"; fi
    else
      cp "$out" "$golden"; wrote=$((wrote+1))
    fi
  else
    mism=$((mism+1)); echo "SKIP repl golden — missing $REPL_BIN (run sh test/build_oracles.sh) or $REPL_IN"
  fi
fi

# ── §2c `lsp` goldens — SKIPPED (REROOT-PLAN STOP guardrail) ──────────────────
# lsp: `medaka build compiler/entries/lsp_main.mdk` fails the native G1 typecheck
#   gate (compiler/driver/medaka_cli.mdk typecheckGate uses roots
#   [inputDir, stdlib] — missing `compiler` — so tools.lsp's transitive imports
#   don't resolve; check_all_main with explicit [compiler, stdlib] roots typechecks
#   lsp_main cleanly).  No native lsp host binary can be built → the 3 lsp gates
#   cannot be re-rooted onto a native host.  Gates left on the OCaml oracle.

# ── §2d native-CLI goldens : FROZEN ────────────────────────────────────────────
# native_cli_goldens/ (check/fmt/run/test/build/lsp) were captured by earlier
# capture runs.  Re-capture after Phase 3 rebuild to refresh all subsections:
#   check/  — FROZEN: check_main.mdk calls args() (native-only extern)
#   fmt/    — FROZEN: requires current native binary
#   run/    — FROZEN: requires current native binary
#   test/   — FROZEN: requires current native binary
#   build/  — FROZEN: requires current native binary
#   lsp/    — FROZEN: requires current native lsp session output

# ── self-hosted LSP differential goldens : FROZEN ────────────────────────────
# lsp_goldens/ were captured from the OCaml reference server + `check --json`.
# The native `./medaka lsp` is canonical but re-capture requires a live LSP
# session; committed goldens in test/lsp_goldens/ remain valid for
# diff_compiler_lsp{,_b3,_b4}.sh gates (OCaml-free; they drive native lsp vs
# these committed goldens).  Re-mint by running `sh test/capture_goldens.sh lsp`
# with an up-to-date native binary if LSP responses change.

echo
if [ "$CHECK" -eq 1 ]; then
  printf 'CHECK: %d rows, %d fixtures, %d mismatch(es)\n' "$total" "$fixtures" "$mism"
  [ "$mism" -eq 0 ]
else
  printf 'CAPTURED: %d rows, %d goldens written (%d oracle failures)\n' "$total" "$wrote" "$mism"
  [ "$mism" -eq 0 ]
fi
