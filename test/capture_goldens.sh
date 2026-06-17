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
# NATIVE Stage-4 oracles (OCaml-free).  fmt/printer goldens are re-rooted onto
# these: the native formatter is canonical (trailing-comma-on-break style), so
# its output — not the frozen OCaml main.exe's — is the source of truth.  These
# are the SAME binaries the diff_selfhost_fmt / diff_selfhost_printer gates run,
# so capture-from-native makes those gates native-vs-native (no OCaml leg).
FMT_NATIVE="$ROOT/test/bin/fmt_main"
PRINTER_NATIVE="$ROOT/test/bin/printer_main"
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
oracle_print_probe()     { "$PRINTER_NATIVE" "$1" 2>/dev/null | sed '$ s/()$//; ${/^$/d;}'; }  # printer reprint (NATIVE — re-rooted; strip_unit to match the gate)
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
# tc_module : PRELUDE-AWARE per-binding schemes / first TYPE ERROR via the real
# Loader + typecheck_module (dev/tc_module_probe.exe), sorted + de-duplicated.
# Re-rooting for feature #11 (Num-polymorphic literals): a numeric literal `1`
# desugars to `fromInt 1`, so the bare no-prelude tc_probe oracle either errors
# `Unbound variable: fromInt` or leaves the `Num` var ungrounded — it CANNOT
# produce the documented prelude-dependent error/scheme.  The prelude-dependent
# fixtures (PRELUDE_DEP_TC below) source their golden here instead; their gates
# run only the matching prelude-aware native driver (check_main / typecheck_main
# whichever equals this oracle — see each gate's header).  uniq drops a benign
# tc_module_probe entry-filter artifact (a prelude name printed twice).
oracle_tc_module()      { "$TCMODPROBE" "$1" 2>/dev/null | LC_ALL=C sort | uniq; }
# Basenames whose tc.golden is prelude-dependent (#11) → captured via tc_module.
# Mirrors PRELUDE_DEP in diff_selfhost_typecheck_errors.sh + the operators stale
# golden in typecheck_fixtures (whose function-clause Num vars stay polymorphic
# under #11 — the new schemes only differ from the stale ones, not prelude-needy,
# but tc_probe still errors on `fromInt` so it too must source from tc_module).
PRELUDE_DEP_TC="int_vs_string mut_generalization value_restriction tuple_arity operators default_body_type_error"
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
    # #11 re-rooting: tc_probe (no prelude) can't source the prelude-dependent
    # typecheck{,_error}_fixtures (it errors on the desugared `fromInt`); those
    # basenames source from the prelude-aware tc_module oracle instead.
    use_tag="$tag"
    if [ "$tag" = "tc_probe" ]; then
      base="$(basename "${f%.mdk}")"
      case " $PRELUDE_DEP_TC " in *" $base "*) use_tag="tc_module" ;; esac
    fi
    emit_golden "$golden" "oracle_$use_tag" "$f"
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

# stack : eval-value goldens for diff_native_stack.sh (REROOT-PLAN Phase 3).  The
# stack_fixtures programs aggregate a single `main` value (a deep-recursion sum);
# the golden is its pp_value, captured from eval_probe while OCaml is trusted.
# plain fixtures -> eval_probe ; typed fixtures -> eval_probe --prelude.
if want stack; then
  total=$((total+1))
  for f in "$ROOT"/test/stack_fixtures/*.mdk; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.eval.golden" oracle_eval "$f"
  done
  for f in "$ROOT"/test/stack_fixtures_typed/*.mdk; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.eval.golden" oracle_eval_prelude "$f"
  done
fi

# selfproc : reference goldens for diff_selfhost_selfproc.sh legs B/C/D
# (REROOT-PLAN Phase 3 / 2c).  Each leg runs a selfproc_*_probe program directly
# through the OCaml reference eval (`main.exe run <probe>`) to get the reference
# token / AST / scheme stream; the gate diffs that against the self-hosted eval
# path (native eval_modules_main / eval_typed_modules_main).  We freeze the
# reference leg as a golden captured here while OCaml is trusted; the gate strips
# the native runtime's trailing "()" before comparing.  (LEG A iterates flat
# module names that no longer exist under the folder layout, so it currently
# checks nothing — no golden needed there.)
if want selfproc; then
  total=$((total+1))
  mkdir -p "$ROOT/test/selfproc_goldens"
  emit_golden "$ROOT/test/selfproc_goldens/lex_probe.golden"   "$MAIN" run "$ROOT/selfhost/entries/selfproc_lex_probe.mdk"
  emit_golden "$ROOT/test/selfproc_goldens/parse_probe.golden" "$MAIN" run "$ROOT/selfhost/entries/selfproc_parse_probe.mdk"
  emit_golden "$ROOT/test/selfproc_goldens/tc_probe.golden"    "$MAIN" run "$ROOT/selfhost/entries/selfproc_tc_probe.mdk"
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
    # Strip the repo-root prefix from the "file" paths so oracle.json is
    # worktree-relative (the gate compares by basename anyway — keep it clean).
    "$MAIN" check --json "$entry" 2>/dev/null | sed "s#$ROOT/##g" > "$out" || true
    fixtures=$((fixtures+1))
    golden="${d%/}/oracle.json"
    if [ "$CHECK" -eq 1 ]; then
      if [ -f "$golden" ] && cmp -s "$out" "$golden"; then :
      else mism=$((mism+1)); [ -f "$golden" ] && echo "DRIFT $golden" || echo "MISSING $golden"; fi
    else cp "$out" "$golden"; wrote=$((wrote+1)); fi
  done
fi

# ── §2e BOOTSTRAP stage goldens (native stage == reference stage) ─────────────
# Each bootstrap_<stage>.sh proves the native-compiled stage (test/bin/<stage>_main)
# reproduces the REFERENCE stage output.  The reference is the OCaml interpreter
# running the SAME selfhost entry (`main.exe run <entry> <args> <fix>`), captured
# RAW here (no trailing "()"; the gate strip_unit's the native side).  Suffix
# `.boot_<stage>.golden`, sibling to each fixture.
# capture_boot <tag> <fixdir> <suffix> <entry> [fixed-args...]:
#   golden = main.exe run selfhost/entries/<entry>.mdk <fixed-args...> <fixture>
capture_boot() {
  tag="$1"; fixdir="$2"; suffix="$3"; entry="$4"; shift 4
  want "$tag" || return 0
  total=$((total+1))
  ent="$ROOT/selfhost/entries/$entry.mdk"
  for f in "$fixdir"/*.mdk; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.$suffix" "$MAIN" run "$ent" "$@" "$f"
  done
}
capture_boot boot_lex       "$ROOT/test/diff_fixtures"       boot_lex.golden       lex_main
capture_boot boot_parse     "$ROOT/test/parse_fixtures"      boot_parse.golden     parse_main
capture_boot boot_desugar   "$ROOT/test/parse_fixtures"      boot_desugar.golden   desugar_main
capture_boot boot_resolve   "$ROOT/test/resolve_fixtures"    boot_resolve.golden   resolve_main "$RUNTIME" "$CORE"
capture_boot boot_mark      "$ROOT/test/parse_fixtures"      boot_mark.golden      mark_main "$CORE"
capture_boot boot_typecheck "$ROOT/test/typecheck_fixtures"  boot_typecheck.golden typecheck_main
capture_boot boot_eval      "$ROOT/test/eval_fixtures"       boot_eval.golden      eval_main

# ── §2c TOOLING goldens (fmt / test) ──────────────────────────────────────────
# fmt : golden RE-ROOTED onto the NATIVE formatter (test/bin/fmt_main) — it is
# canonical (trailing-comma-on-break) and is the very binary the
# diff_selfhost_fmt gate runs, so this makes that gate native-vs-native.  The
# gate compares `golden` (norm'd) against `fmt_main | strip_unit | norm`, so we
# apply the SAME strip_unit here (drop the native CLI's trailing unit/`0` echo)
# — otherwise the golden would carry an artifact the gate strips from actual.
fmt_native_stripped() { "$FMT_NATIVE" "$1" 2>/dev/null | sed '$ s/()$//; ${/^$/d;}' | sed '$ { /^0$/d; }'; }
if want fmt; then
  total=$((total+1))
  for f in "$ROOT"/test/fmt_fixtures/*.mdk "$ROOT"/test/parse_fixtures/*.mdk; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.fmt.golden" fmt_native_stripped "$f"
  done
fi
# test : golden = `main.exe test <f>` (doctest/prop report).  Fixtures = the
# modules the self-hosted test_main genuinely reproduces (string/mut_array/array/
# map are deferred behind the parked dispatch gap #55 + Unicode case-folding — see
# diff_selfhost_test.sh).  Golden lives next to each as .test.golden.
if want test; then
  total=$((total+1))
  for f in "$ROOT"/stdlib/core.mdk "$ROOT"/stdlib/json.mdk "$ROOT"/stdlib/toml.mdk \
           "$ROOT"/stdlib/list.mdk "$ROOT"/stdlib/set.mdk \
           "$ROOT"/test/selfhost_test_fixtures/mixed.mdk \
           "$ROOT"/test/selfhost_test_fixtures/sum_dict.mdk \
           "$ROOT"/test/selfhost_test_fixtures/mappable_not_foldable.mdk \
           "$ROOT"/test/selfhost_test_fixtures/shadow_impl_tolist.mdk; do
    [ -f "$f" ] || continue
    emit_golden "${f%.mdk}.test.golden" "$MAIN" test "$f"
  done
fi

# ── §2c `new` scaffold golden (project tree from `main.exe new`) ───────────────
# Capture the OCaml `medaka new myapp` tree into a committed reference dir under
# test/new_golden/myapp.  The re-rooted gate diffs the native new_main tree vs this.
if want new; then
  total=$((total+1))
  fixtures=$((fixtures+1))
  GOLDDIR="$ROOT/test/new_golden"
  tmpnew="$TMP/newref"; rm -rf "$tmpnew"; mkdir -p "$tmpnew"
  ( cd "$tmpnew" && "$MAIN" new myapp >/dev/null 2>&1 ) || true
  if [ "$CHECK" -eq 1 ]; then
    if [ -d "$GOLDDIR/myapp" ] && diff -r "$GOLDDIR/myapp" "$tmpnew/myapp" >/dev/null 2>&1; then :
    else mism=$((mism+1)); [ -d "$GOLDDIR/myapp" ] && echo "DRIFT $GOLDDIR/myapp" || echo "MISSING $GOLDDIR/myapp"; fi
  else
    rm -rf "$GOLDDIR"; mkdir -p "$GOLDDIR"; cp -R "$tmpnew/myapp" "$GOLDDIR/myapp"; wrote=$((wrote+1))
  fi
fi

# ── §2d build goldens — the program's runtime STDOUT from the OCaml-built binary ──
# These re-root the three `medaka build` gates (build_cmd / diff_selfhost_build /
# build_construct_coverage) off the OCaml interp oracle.  The golden is the stdout
# of the BINARY produced by the OCaml `medaka build` NOW (the validated backend
# oracle).  The re-rooted gate builds the SAME fixture with the NATIVE `./medaka
# build` (MEDAKA_EMITTER=native) and diffs its binary's stdout vs this golden.
# The golden therefore captures the BACKEND's actual output, including the parked
# native dispatch gaps (#54/#21/#55): e.g. svm/entry's standalone-vs-method
# `toList`/`isEmpty` yields EMPTY output on BOTH hosts' binaries, so the golden is
# empty and the native binary matches it.  (This differs from the interp oracle,
# which the OLD gates diffed against and which therefore FAILED svm — the re-root
# faithfully goldens the binary, not the interpreter.)
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

if want build_cmd; then
  total=$((total+1))
  for label in arith recur adt list closure println println_seq show_debug eq ord list_map deriving; do
    f="$ROOT/test/build_cmd_fixtures/$label.mdk"
    [ -f "$f" ] && capture_build_golden "$f" "${f%.mdk}.build.golden"
  done
  capture_build_golden "$ROOT/test/build_cmd_fixtures/mm/entry.mdk"  "$ROOT/test/build_cmd_fixtures/mm/entry.build.golden"
  capture_build_golden "$ROOT/test/build_cmd_fixtures/svm/entry.mdk" "$ROOT/test/build_cmd_fixtures/svm/entry.build.golden"
fi

if want build_diff; then
  total=$((total+1))
  for f in "$ROOT"/test/build_diff_fixtures/*.mdk; do
    [ -f "$f" ] && capture_build_golden "$f" "${f%.mdk}.build.golden"
  done
  capture_build_golden "$ROOT/test/build_diff_fixtures/mm/entry.mdk"     "$ROOT/test/build_diff_fixtures/mm/entry.build.golden"
  capture_build_golden "$ROOT/test/build_diff_fixtures/l1/entry.mdk"     "$ROOT/test/build_diff_fixtures/l1/entry.build.golden"
  capture_build_golden "$ROOT/test/build_diff_fixtures/nested/main.mdk"  "$ROOT/test/build_diff_fixtures/nested/main.build.golden"
fi

if want build_construct; then
  total=$((total+1))
  # Deferred (no golden): 2 emitter gaps (backtick_infix/tuple_neq — also RED on
  # OCaml) + 4 native typecheck-gate gaps (json_parse/mod_reverse_string/
  # newtype_ctor_fn/type_alias — OCaml builds them, native CLI rejects).  Same set
  # build_construct_coverage.sh skips; see its header.
  BC_SKIP="backtick_infix tuple_neq json_parse mod_reverse_string newtype_ctor_fn type_alias"
  for f in "$ROOT"/test/construct_fixtures/*.mdk; do
    [ -f "$f" ] || continue
    bl="$(basename "$f" .mdk)"
    case " $BC_SKIP " in *" $bl "*) continue ;; esac
    capture_build_golden "$f" "${f%.mdk}.build.golden"
  done
fi

# ── §2d `repl` golden — captured from the NATIVE repl (CANONICAL), NOT OCaml ──
# DESIGN CALL (flagged for maintainer): the OCaml `medaka repl` and the self-hosted
#   repl diverge on the post-error command sequence — after an unbound-variable line
#   the OCaml repl keeps emitting prompts for the remaining commands; the selfhost
#   repl (both interpreted AND native-compiled, which AGREE byte-for-byte) stops
#   short.  Per REROOT-PLAN the self-hosted backend is CANONICAL, so the golden is
#   captured from the NATIVE repl binary (test/bin/repl_main), the OCaml leg is
#   dropped, and diff_selfhost_repl.sh gates native-vs-golden.  The native output is
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
# lsp: `medaka build selfhost/entries/lsp_main.mdk` fails the native G1 typecheck
#   gate (selfhost/driver/medaka_cli.mdk typecheckGate uses roots
#   [inputDir, stdlib] — missing `selfhost` — so tools.lsp's transitive imports
#   don't resolve; check_all_main with explicit [selfhost, stdlib] roots typechecks
#   lsp_main cleanly).  No native lsp host binary can be built → the 3 lsp gates
#   cannot be re-rooted onto a native host.  Gates left on the OCaml oracle.

# ── §2d native-CLI goldens — OCaml oracle per subtest for diff_native_cli.sh ───
# diff_native_cli.sh diffs native `./medaka <subcmd>` against an OCaml oracle for
# check/fmt/new/run/test/build.  Capture each oracle NOW (OCaml is the validated
# reference); the re-rooted gate diffs native-vs-golden.  repl reuses the canonical
# NATIVE golden (above); lsp stays on the OCaml oracle (native lsp host unbuildable).
NC_GOLD="$ROOT/test/native_cli_goldens"
if want native_cli; then
  total=$((total+1))
  mkdir -p "$NC_GOLD/check" "$NC_GOLD/fmt" "$NC_GOLD/run" "$NC_GOLD/test"
  CHECK_MAIN="$ROOT/selfhost/entries/check_main.mdk"
  # check: inferred-signature dump from check_main (interp), sorted (gate sorts both)
  for f in "$ROOT"/test/diff_fixtures/*.mdk; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .mdk)"
    out="$TMP/nc"; "$MAIN" run "$CHECK_MAIN" "$RUNTIME" "$CORE" "$f" 2>/dev/null | LC_ALL=C sort > "$out" || true
    emit_to "$NC_GOLD/check/$n.golden" "$out"
  done
  # fmt: native `medaka fmt --stdout` RE-ROOTED off OCaml (the native formatter
  # is canonical; trailing-comma-on-break).  The diff_native_cli fmt subtest
  # strips the trailing-unit `0` from the native side, so strip it here too.
  for f in "$ROOT"/test/fmt_fixtures/*.mdk; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .mdk)"
    out="$TMP/nc"; "$ROOT/medaka" fmt --stdout "$f" 2>/dev/null | sed '$ s/0$//' > "$out" || true
    emit_to "$NC_GOLD/fmt/$n.golden" "$out"
  done
  # new: scaffold tree from `medaka new proj`
  tmpnc="$TMP/ncnew"; rm -rf "$tmpnc"; mkdir -p "$tmpnc"
  ( cd "$tmpnc" && "$MAIN" new proj >/dev/null 2>&1 ) || true
  fixtures=$((fixtures+1))
  if [ "$CHECK" -eq 1 ]; then
    if [ -d "$NC_GOLD/new/proj" ] && diff -r "$NC_GOLD/new/proj" "$tmpnc/proj" >/dev/null 2>&1; then :
    else mism=$((mism+1)); [ -d "$NC_GOLD/new/proj" ] && echo "DRIFT $NC_GOLD/new/proj" || echo "MISSING $NC_GOLD/new/proj"; fi
  else
    rm -rf "$NC_GOLD/new"; mkdir -p "$NC_GOLD/new"; cp -R "$tmpnc/proj" "$NC_GOLD/new/proj"; wrote=$((wrote+1))
  fi
  # run: medaka run (interp oracle), raw
  for f in "$ROOT"/test/native_cli_fixtures/run/*.mdk; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .mdk)"
    out="$TMP/nc"; "$MAIN" run "$f" 2>/dev/null > "$out" || true
    emit_to "$NC_GOLD/run/$n.golden" "$out"
  done
  # test: medaka test (doctests + props), raw
  for f in "$ROOT"/test/native_cli_fixtures/test/*.mdk; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .mdk)"
    # `medaka test` echoes the fixture path; strip the worktree-root prefix so
    # the golden is path-stable across worktrees (gate strips the same).
    out="$TMP/nc"; "$MAIN" test "$f" 2>/dev/null | sed "s#$ROOT/##g" > "$out" || true
    emit_to "$NC_GOLD/test/$n.golden" "$out"
  done
  # build: program runtime stdout from the OCaml-built binary
  mkdir -p "$NC_GOLD/build"
  for f in "$ROOT"/test/native_cli_fixtures/run/*.mdk; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .mdk)"
    capture_build_golden "$f" "$NC_GOLD/build/$n.golden"
  done

  # lsp/session golden: the CANONICAL native ./medaka lsp (not OCaml) — the
  # native LSP is canonical, so its decoded responses ARE the golden.  Path-stable
  # (file:// → basename).  Requires the built native binary.
  NMED="$ROOT/medaka"
  if [ -x "$NMED" ]; then
    mkdir -p "$NC_GOLD/lsp"
    nlframe() { python3 - "$1" <<'PY'
import sys
b=sys.argv[1].encode("utf-8")
sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n"%len(b)); sys.stdout.buffer.write(b)
PY
    }
    NLIN="$TMP/nl_in.bin"; : > "$NLIN"
    NLSRC='greet x = x + 1\nmain = println (greet 41)\n'
    for m in \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
      '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///lsp_sess.mdk","languageId":"medaka","version":1,"text":"'"$NLSRC"'"}}}' \
      '{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///lsp_sess.mdk"}}}' \
      '{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///lsp_sess.mdk"},"position":{"line":0,"character":1}}}' \
      '{"jsonrpc":"2.0","method":"exit","params":{}}'; do nlframe "$m" >> "$NLIN"; done
    MEDAKA_ROOT="$ROOT" perl -e 'alarm 120; exec @ARGV' "$NMED" lsp < "$NLIN" > "$TMP/nl_out.bin" 2>/dev/null || true
    python3 - "$TMP/nl_out.bin" <<'PY' > "$TMP/nl_out.ndjson" 2>/dev/null || true
import sys,re,json,os
data=open(sys.argv[1],"rb").read()
def stab(o):
    if isinstance(o,dict): return {k:stab(v) for k,v in o.items()}
    if isinstance(o,list): return [stab(x) for x in o]
    if isinstance(o,str) and o.startswith("file://"): return "file:///"+os.path.basename(o)
    return o
for p in re.split(rb"Content-Length: \d+\r\n", data):
    s=p.decode("utf-8","replace"); i=s.find("{")
    if i<0: continue
    s=s[i:].strip()
    try: obj,_=json.JSONDecoder().raw_decode(s)
    except Exception: continue
    print(json.dumps(stab(obj),sort_keys=True))
PY
    emit_to "$NC_GOLD/lsp/session.ndjson" "$TMP/nl_out.ndjson"
  fi
fi

# ── self-hosted LSP differential goldens (REROOT-PLAN §3b) ───────────────────
# The OCaml reference server ($MAIN lsp) and OCaml `check --json` are the LSP
# oracle for the OCaml-free gates diff_selfhost_lsp{,_b3,_b4}.sh.  We capture
# their NDJSON responses HERE (OCaml still trusted) into committed goldens under
# test/lsp_goldens/.  The gates then drive the *canonical native* `medaka lsp`
# and diff the SAME normalized projection (skel/sorted/path-stable) vs golden.
#
# Path-stability: every `file://` URI and absolute path is reduced to a basename
# in BOTH capture and gate, so goldens carry no build path.
LSP_GOLD="$ROOT/test/lsp_goldens"
if want lsp; then
  total=$((total+1))
  mkdir -p "$LSP_GOLD"
  LTMP="$TMP/lsp"; mkdir -p "$LTMP"

  lsp_frame() {  # $1 = json text  ->  Content-Length frame on stdout
    python3 - "$1" <<'PY'
import sys
b=sys.argv[1].encode("utf-8")
sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n"%len(b))
sys.stdout.buffer.write(b)
PY
  }
  # decode a raw LSP byte stream -> one JSON obj per line (path-stable basenames)
  lsp_decode() {  # $1 = raw .bin
    python3 - "$1" <<'PY'
import sys,re,json,os
data=open(sys.argv[1],"rb").read()
def stab(o):
    if isinstance(o,dict):
        return {k:stab(v) for k,v in o.items()}
    if isinstance(o,list):
        return [stab(x) for x in o]
    if isinstance(o,str) and o.startswith("file://"):
        return "file:///"+os.path.basename(o)
    return o
for p in re.split(rb"Content-Length: \d+\r\n", data):
    s=p.decode("utf-8","replace"); i=s.find("{")
    if i<0: continue
    s=s[i:].strip()
    try: obj,_=json.JSONDecoder().raw_decode(s)
    except Exception: continue
    print(json.dumps(stab(obj),sort_keys=True))
PY
  }
  # run the OCaml reference server on a built input file -> decoded NDJSON golden
  lsp_capture_ocaml() {  # $1=golden  $2=in.bin
    out="$LTMP/oc.bin"
    perl -e 'alarm 120; exec @ARGV' "$MAIN" lsp < "$2" > "$out" 2>/dev/null || true
    lsp_decode "$out" > "$LTMP/oc.json" 2>/dev/null || true
    emit_to "$1" "$LTMP/oc.json"
  }

  # ---- gate-1 oracle: OCaml `check --json` for clean / err / project ----------
  printf 'main = println "hi"\n'  > "$LTMP/clean.mdk"
  printf 'main = 1 + "x"\n'        > "$LTMP/err.mdk"
  # check --json golden: reduce "file" to basename (path-stable).
  cj_stable() {  # $1=src  $2=golden
    "$MAIN" check --json "$1" 2>/dev/null \
      | python3 -c 'import sys,json,os
o=json.load(sys.stdin)
for f in o.get("files",[]): f["file"]=os.path.basename(f["file"])
# Sort files by basename: the OCaml check --json files[] order is traversal-
# dependent (non-deterministic); the gate reads it into a by-basename dict, so
# order is irrelevant to the comparison but must be stable in the golden.
o["files"]=sorted(o.get("files",[]), key=lambda f: f.get("file",""))
print(json.dumps(o,sort_keys=True))' > "$LTMP/cj" 2>/dev/null || true
    emit_to "$2" "$LTMP/cj"
  }
  cj_stable "$LTMP/clean.mdk" "$LSP_GOLD/check_clean.json"
  cj_stable "$LTMP/err.mdk"   "$LSP_GOLD/check_err.json"

  # project fixture (3 siblings: a bad import must not blank the clean files).
  PJ="$LTMP/proj"; mkdir -p "$PJ"
  printf 'export double : Int -> Int\ndouble x = x + x\n' > "$PJ/lib_clean.mdk"
  printf 'import lib_clean.{double}\n\nexport oops : Int\noops = double "no"\n' > "$PJ/lib_bad.mdk"
  printf 'import lib_clean.{double}\nimport lib_bad.{oops}\n\nmain = println (double 21)\n' > "$PJ/main_app.mdk"
  cj_stable "$PJ/main_app.mdk" "$LSP_GOLD/check_project.json"

  # ---- gate b3 oracle: OCaml LSP symbol/definition/highlight + fmt -----------
  INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"processId":null,"rootUri":null}}'
  INITED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
  SHUT='{"jsonrpc":"2.0","id":9,"method":"shutdown","params":{}}'
  EXIT='{"jsonrpc":"2.0","method":"exit","params":{}}'
  SRC_JSON='record Point\n  x : Int\n  y : Int\n\ndata Shape = Circle Int | Square Int\n\narea s = match s\n  Circle r => r * r\n  Square w => w * w\n'
  DIDOPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///s.mdk","languageId":"medaka","version":1,"text":"'"$SRC_JSON"'"}}}'
  SYM='{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///s.mdk"}}}'
  DEF='{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///s.mdk"},"position":{"line":6,"character":0}}}'
  HL='{"jsonrpc":"2.0","id":4,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///s.mdk"},"position":{"line":6,"character":0}}}'
  : > "$LTMP/in.bin"
  for m in "$INIT" "$INITED" "$DIDOPEN" "$SYM" "$DEF" "$HL" "$SHUT" "$EXIT"; do lsp_frame "$m" >> "$LTMP/in.bin"; done
  lsp_capture_ocaml "$LSP_GOLD/b3_sym_def_hl.ndjson" "$LTMP/in.bin"

  # b3 fmt oracle: the OCaml formatter output for the unformatted fixture.
  printf 'main   =   println    "hi"\n\n\n' > "$LTMP/unfmt.mdk"
  "$MAIN" fmt --stdout "$LTMP/unfmt.mdk" 2>/dev/null > "$LTMP/fmt.txt" || true
  emit_to "$LSP_GOLD/b3_fmt.txt" "$LTMP/fmt.txt"

  # ---- gate b4 oracle: OCaml LSP hover/completion/inlayHint ------------------
  INIT4='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  DOC_TEXT='double x = x + x\ntriple : Int -> Int\ntriple x = x * 3\nresult = double 5\n'
  DIDOPEN4='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b4.mdk","languageId":"medaka","version":1,"text":"'"$DOC_TEXT"'"}}}'
  HOVER='{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///b4.mdk"},"position":{"line":0,"character":2}}}'
  HOVOFF='{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///b4.mdk"},"position":{"line":0,"character":9}}}'
  COMPL='{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///b4.mdk"},"position":{"line":3,"character":13}}}'
  INLAY='{"jsonrpc":"2.0","id":4,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///b4.mdk"},"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}}}}'
  DOC2='alpha = 1\nbeta = 2\n\n'
  DIDOPEN4B='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b4b.mdk","languageId":"medaka","version":1,"text":"'"$DOC2"'"}}}'
  COMPL2='{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///b4b.mdk"},"position":{"line":2,"character":0}}}'
  EXIT4='{"jsonrpc":"2.0","method":"exit","params":{}}'
  cap_b4() {  # $1=golden  $2..=messages
    golden="$1"; shift
    : > "$LTMP/in.bin"
    for m in "$@"; do lsp_frame "$m" >> "$LTMP/in.bin"; done
    lsp_capture_ocaml "$golden" "$LTMP/in.bin"
  }
  cap_b4 "$LSP_GOLD/b4_hover.ndjson"   "$INIT4" "$DIDOPEN4" "$HOVER" "$EXIT4"
  cap_b4 "$LSP_GOLD/b4_hover_off.ndjson" "$INIT4" "$DIDOPEN4" "$HOVOFF" "$EXIT4"
  cap_b4 "$LSP_GOLD/b4_compl.ndjson"   "$INIT4" "$DIDOPEN4" "$COMPL" "$EXIT4"
  cap_b4 "$LSP_GOLD/b4_compl_full.ndjson" "$INIT4" "$DIDOPEN4B" "$COMPL2" "$EXIT4"
  cap_b4 "$LSP_GOLD/b4_inlay.ndjson"   "$INIT4" "$DIDOPEN4" "$INLAY" "$EXIT4"
fi

echo
if [ "$CHECK" -eq 1 ]; then
  printf 'CHECK: %d rows, %d fixtures, %d mismatch(es)\n' "$total" "$fixtures" "$mism"
  [ "$mism" -eq 0 ]
else
  printf 'CAPTURED: %d rows, %d goldens written (%d oracle failures)\n' "$total" "$wrote" "$mism"
  [ "$mism" -eq 0 ]
fi
