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

# rows: "<glob>::<oracle-tag>::<golden-suffix>"
ROWS="
$ROOT/test/eval_fixtures/*.mdk::eval::eval.golden
$ROOT/test/llvm_fixtures/*.mdk::eval::eval.golden
$ROOT/test/eval_prelude_fixtures/*.mdk::eval_prelude::eval.golden
$ROOT/test/eval_list_fixtures/*.mdk::eval_list::eval.golden
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

echo
if [ "$CHECK" -eq 1 ]; then
  printf 'CHECK: %d rows, %d fixtures, %d mismatch(es)\n' "$total" "$fixtures" "$mism"
  [ "$mism" -eq 0 ]
else
  printf 'CAPTURED: %d rows, %d goldens written (%d oracle failures)\n' "$total" "$wrote" "$mism"
  [ "$mism" -eq 0 ]
fi
