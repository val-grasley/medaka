#!/bin/sh
# capture_goldens.sh — REROOT-PLAN §3a / Phase 1.
#
# Capture OCaml-oracle output into committed `.golden` siblings while the OCaml
# oracle (dev/eval_probe.exe, etc.) is still TRUSTED.  These goldens are the
# OCaml-free reference the re-rooted gates (Phase 2+) will diff the native stage
# against.  This script is the ONLY place the OCaml oracle is invoked at capture
# time; it is run MANUALLY at soak checkpoints, never in the gate loop.
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
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
CORE="$ROOT/stdlib/core.mdk"; LIST="$ROOT/stdlib/list.mdk"; RUNTIME="$ROOT/stdlib/runtime.mdk"
# §2b front-end dev probes (location-free dumps, the OCaml leg of the front-end gates).
ASTDUMP="$ROOT/_build/default/dev/astdump.exe"
LEXTOK="$ROOT/_build/default/dev/lextok.exe"
PRINTPROBE="$ROOT/_build/default/dev/print_probe.exe"
POSDUMP="$ROOT/_build/default/dev/positions_dump.exe"
CMTDUMP="$ROOT/_build/default/dev/comment_dump.exe"
# §2b typecheck/check/diagnostics oracles (location-free dumps).
TCPROBE="$ROOT/_build/default/dev/tc_probe.exe"
TCMODPROBE="$ROOT/_build/default/dev/tc_module_probe.exe"
DIAGDUMP="$ROOT/_build/default/dev/diagdump.exe"

CHECK=0
FILTER=""
case "${1:-}" in
  --check) CHECK=1 ;;
  "") ;;
  *) FILTER="$1" ;;
esac

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }
[ -x "$MAIN" ]  || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

# ── driver table ───────────────────────────────────────────────────────────────
# Implemented as a function dispatch so each oracle's exact argv is explicit and
# auditable (no eval of a template string).  oracle_<tag> <fixture> -> stdout.
# Each oracle_<tag> reproduces, byte-for-byte, the OCaml leg of the gate that
# consumes the resulting `.eval.golden` — same flags, same prepend order.
oracle_eval()         { "$PROBE" "$1"; }                               # eval / core_ir / roundtrip
oracle_eval_prelude() { "$PROBE" --prelude "$1"; }                     # eval_prelude / core_ir_prelude
oracle_eval_list()    { "$PROBE" --prepend "$CORE" "$LIST" "$1"; }     # eval_list / core_ir_list
oracle_run_file()     { "$MAIN" run "$1"; }                            # eval_dict / eval_typed / core_ir_typed
# ── §2b front-end oracles (raw dumps; the gate applies the same `norm` to both
#    the golden and the native output, so capture RAW here). ──
oracle_lextok()          { "$LEXTOK" "$1"; }                           # lex_files corpus token stream
oracle_astdump()         { "$ASTDUMP" "$1"; }                          # parse AST S-expr
oracle_astdump_desugar() { "$ASTDUMP" --desugar "$1"; }               # desugar / desugar_batch
oracle_astdump_mark()    { "$ASTDUMP" --mark "$1"; }                  # mark / mark_batch
oracle_print_probe()     { "$PRINTPROBE" "$1"; }                       # printer reprint
oracle_positions_dump()  { "$POSDUMP" "$1"; }                          # parser position channel
oracle_comment_dump()    { "$CMTDUMP" "$1"; }                          # lexer comment channel
# parse_result : the OCaml oracle only confirms the fixture is a genuine parse
# error and yields its L:C (the self-host leg's location is NOT required to match;
# line agreement is reported, not enforced).  Capture just that L:C string.
oracle_parse_result_lc() {
  "$ASTDUMP" "$1" 2>&1 \
    | sed -n 's/.*Failure("parse error \([0-9]*:[0-9]*\)").*/\1/p' | head -1
}
# ── §2b typecheck / check / diagnostics oracles ──
# tc_probe : bare HM, no prelude → `name : scheme` (or "TYPE ERROR: …").  Sorted,
# matching diff_selfhost_typecheck{,_errors,_panic_errors}.sh's reference leg.
oracle_tc_probe()       { "$TCPROBE" "$1" 2>/dev/null | LC_ALL=C sort; }
# diagdump --analyze : structured per-fixture diagnostics (human message, no loc),
# sorted — the OCaml leg of diff_selfhost_diagnostics.sh.
oracle_diag_analyze()   { "$DIAGDUMP" --analyze "$1" 2>/dev/null | LC_ALL=C sort; }

# rows: "<glob>::<oracle-tag>::<golden-suffix>"
ROWS="
$ROOT/test/eval_fixtures/*.mdk::eval::eval.golden
$ROOT/test/llvm_fixtures/*.mdk::eval::eval.golden
$ROOT/test/eval_prelude_fixtures/*.mdk::eval_prelude::eval.golden
$ROOT/test/eval_list_fixtures/*.mdk::eval_list::eval.golden
$ROOT/test/eval_dict_fixtures/*.mdk::run_file::eval.golden
$ROOT/test/eval_typed_fixtures/*.mdk::run_file::eval.golden
$ROOT/test/parse_fixtures/*.mdk::print_probe::printer.golden
$ROOT/test/positions_fixtures/*.mdk::positions_dump::positions.golden
$ROOT/test/comment_fixtures/*.mdk::comment_dump::comments.golden
$ROOT/test/typecheck_fixtures/*.mdk::tc_probe::tc.golden
$ROOT/test/typecheck_error_fixtures/*.mdk::tc_probe::tc.golden
$ROOT/test/typecheck_panic_fixtures/*.mdk::tc_probe::tc.golden
$ROOT/test/resolve_fixtures/*.mdk::diag_analyze::analyze.golden
$ROOT/test/exhaust_fixtures/*.mdk::diag_analyze::analyze.golden
$ROOT/test/check_match_fixtures/*.mdk::diag_analyze::analyze.golden
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
  "$@" > "$out" 2>/dev/null || true
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

# ── directory + selfhost-oracle fixtures (not a single-glob/single-arg shape) ──
# These goldens are captured from the EXACT OCaml oracle each gate used (a selfhost
# entry run via main.exe, or `main.exe run <entry>` per fixture dir), so the
# re-rooted gate diffs its native host's stdout against this committed reference.

want() {  # want <tag> : true if no FILTER, or FILTER prefixes the tag/"eval"
  [ -z "$FILTER" ] && return 0
  case "eval" in "$FILTER"*) return 0 ;; esac
  case "$1" in "$FILTER"*) return 0 ;; esac
  return 1
}

# eval_modules / core_ir_modules : golden = `main.exe run <entry>` per dir.
if want eval_modules; then
  total=$((total+1))
  for dir in "$ROOT"/test/eval_modules_fixtures/*/; do
    [ -d "$dir" ] || continue
    entry="$(ls "$dir"main_*.mdk 2>/dev/null | head -1)"
    [ -n "$entry" ] || continue
    emit_golden "${dir%/}/main.eval.golden" "$MAIN" run "$entry"
  done
fi

# eval_typed_modules : golden = `main.exe run <dir>/main.mdk` per dir.
if want eval_typed_modules; then
  total=$((total+1))
  for dir in "$ROOT"/test/eval_typed_modules_fixtures/*/; do
    [ -d "$dir" ] || continue
    entry="$dir/main.mdk"
    [ -f "$entry" ] || continue
    emit_golden "${dir%/}/main.eval.golden" "$MAIN" run "$entry"
  done
fi

# llvm_typed : golden = the program value via the typed Core-IR pp oracle entry.
if want llvm_typed; then
  total=$((total+1))
  for f in "$ROOT"/test/llvm_fixtures_typed/*.mdk; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.eval.golden" \
      "$MAIN" run "$ROOT/selfhost/entries/core_ir_dict_pp_main.mdk" "$RUNTIME" "$f"
  done
fi

# llvm_modules : golden = the program stdout via the typed-modules eval oracle entry
# (empty-core prelude + dir), matching diff_selfhost_llvm_modules.sh's ORACLE leg.
if want llvm_modules; then
  total=$((total+1))
  EMPTY_CORE="$TMP/empty_core.mdk"; : > "$EMPTY_CORE"
  for dir in "$ROOT"/test/llvm_fixtures_modules/*/; do
    [ -d "$dir" ] || continue
    entry="$dir/entry.mdk"
    [ -f "$entry" ] || continue
    emit_golden "${dir%/}/entry.eval.golden" \
      "$MAIN" run "$ROOT/selfhost/entries/eval_typed_modules_main.mdk" \
      "$RUNTIME" "$EMPTY_CORE" "$entry" "${dir%/}"
  done
fi

# ── §2b multi-glob corpus gates (parse / desugar / mark / lex_files) ──────────
# These read a multi-directory corpus that the line-split ROWS loop can't express
# (one row = one glob token), so capture them here with explicit globs.  The gate
# applies its own `norm` (float-text) to BOTH golden and native output, so we
# capture the RAW oracle dump.

# parse : astdump AST S-expr over parse_fixtures + parse_only_fixtures.
if want parse; then
  total=$((total+1))
  for f in "$ROOT"/test/parse_fixtures/*.mdk "$ROOT"/test/parse_only_fixtures/*.mdk; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.parse.golden" oracle_astdump "$f"
  done
fi

# desugar + mark : the SAME stdlib + diff + parse + selfhost corpus; the batch and
# non-batch variants share these goldens.  diagdump --desugar / --mark dumps.
DM_CORPUS="$ROOT/stdlib/*.mdk $ROOT/test/diff_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk $ROOT/selfhost/*.mdk"
if want desugar; then
  total=$((total+1))
  for f in $DM_CORPUS; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.desugar.golden" oracle_astdump_desugar "$f"
  done
fi
if want mark; then
  total=$((total+1))
  for f in $DM_CORPUS; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.mark.golden" oracle_astdump_mark "$f"
  done
fi

# parse_result : capture the OCaml oracle's `L:C` per parser-error fixture (the
# self-host parseResult leg is validated live for no-panic + structured output;
# only the oracle's located-error confirmation is frozen here).
if want parse_result; then
  total=$((total+1))
  for name in bad_second_decl dangling_plus leading_rparen question_leftover; do
    f="$ROOT/test/parse_error_fixtures/$name.mdk"
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.parse_result_oracle" oracle_parse_result_lc "$f"
  done
fi

# lex_files : lextok token stream over the lexer source + the importable stdlib.
if want lextok; then
  total=$((total+1))
  LF_FILES="$ROOT/selfhost/frontend/lexer.mdk"
  for m in core list array string map set io hash_map hash_set mut_array json test; do
    LF_FILES="$LF_FILES $ROOT/stdlib/$m.mdk"
  done
  for f in $LF_FILES; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.lextok.golden" oracle_lextok "$f"
  done
fi

# check_modules fixtures : the entry's per-binding schemes via tc_module_probe
# (the OCaml leg of diff_selfhost_check_modules.sh's fixture check).  Each fixture
# dir already ships an `expected` golden == this probe's sorted output; capture it
# fresh here as `<dir>/oracle.tcmod` so the re-rooted gate compares the native
# host against a committed reference rather than re-running the OCaml probe live.
if want tcmod; then
  total=$((total+1))
  for d in "$ROOT"/test/check_module_fixtures/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/entry" ] || continue
    entry="${d%/}/$(cat "$d/entry")"
    [ -f "$entry" ] || continue
    out="$TMP/tcmod"
    "$TCMODPROBE" "$entry" "${d%/}" 2>/dev/null | LC_ALL=C sort > "$out" || true
    fixtures=$((fixtures+1))
    golden="${d%/}/oracle.tcmod"
    if [ "$CHECK" -eq 1 ]; then
      if [ -f "$golden" ] && cmp -s "$out" "$golden"; then :
      else mism=$((mism+1)); [ -f "$golden" ] && echo "DRIFT $golden" || echo "MISSING $golden"; fi
    else cp "$out" "$golden"; wrote=$((wrote+1)); fi
  done
fi

# analyze_project fixtures : the OCaml `medaka check --json <entry>` per-file
# diagnostics bucket (diff_selfhost_analyze_project.sh's oracle).  Captured as
# committed JSON so the re-rooted gate diffs the native diagnostics_project_main
# text against this frozen bucket instead of running main.exe check --json live.
if want analyze_project; then
  total=$((total+1))
  for d in "$ROOT"/test/analyze_project_fixtures/*/; do
    [ -d "$d" ] || continue
    name="$(basename "${d%/}")"
    entry="$(ls "$d"root_*.mdk "$d"main_*.mdk 2>/dev/null | head -1)"
    [ -n "$entry" ] || continue
    out="$TMP/aproj"
    "$MAIN" check --json "$entry" 2>/dev/null > "$out" || true
    fixtures=$((fixtures+1))
    golden="${d%/}/oracle.json"
    if [ "$CHECK" -eq 1 ]; then
      if [ -f "$golden" ] && cmp -s "$out" "$golden"; then :
      else mism=$((mism+1)); [ -f "$golden" ] && echo "DRIFT $golden" || echo "MISSING $golden"; fi
    else cp "$out" "$golden"; wrote=$((wrote+1)); fi
  done
fi

echo
if [ "$CHECK" -eq 1 ]; then
  printf 'CHECK: %d rows, %d fixtures, %d mismatch(es)\n' "$total" "$fixtures" "$mism"
  [ "$mism" -eq 0 ]
else
  printf 'CAPTURED: %d rows, %d goldens written (%d oracle failures)\n' "$total" "$wrote" "$mism"
  [ "$mism" -eq 0 ]
fi
