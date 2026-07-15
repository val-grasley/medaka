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
# Phase 1 captured the eval_probe VALUE goldens — the largest A cluster:
#   test/eval_fixtures/*.mdk  (20)   eval engine value oracle
#
# ⚠️ test/llvm_fixtures/*.mdk is NOT a driver-table row and never runs under a bare
# `capture_goldens.sh` — its `.eval.golden`s are the emitted program's RUNTIME
# STDOUT, so regenerating one means emit -> clang -> link -> RUN, not a stage dump.
# (A `test/llvm_fixtures/*.mdk (180)` row was advertised here for months after it was
# deleted in 6869cc8d, so the documented "capture a golden" recipe silently did
# NOTHING for the one corpus you add an emitter fixture to.)  It now has a real,
# supported regenerator — an opt-in FROZEN family:
#
#   sh test/capture_goldens.sh --frozen llvm_eval
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
DICT_BIN="$ROOT/test/bin/eval_dict_main"
TYPED_BIN="$ROOT/test/bin/eval_typed_main"
EVAL_MODULES_BIN="$ROOT/test/bin/eval_modules_main"
REPL_BIN="$ROOT/test/bin/repl_main"

# capture_build_golden <fixture.mdk> <golden path> — mirrors
# test/build_construct_coverage.sh's check() EXACTLY: `medaka build
# --allow-internal <fixture> -o <bin>` under the same MEDAKA_ROOT/
# MEDAKA_EMITTER env, then run <bin> and capture stdout. Defined here (ahead
# of the FROZEN_TAG block below, which calls it and `exit 0`s before reaching
# the rest of this file) rather than down in the §2d comment block where it
# used to live — see that block for the "why" (it was dead code for months).
# CHECK/fixtures/mism/wrote are all defined by the caller before use.
capture_build_golden() {  # $1=fixture .mdk  $2=golden path
  src="$1"; golden="$2"; fixtures=$((fixtures+1))
  bin="$TMP/cb.bin"; out="$TMP/cb.out"
  rm -f "$bin"
  MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}" \
    perl -e 'alarm 180; exec @ARGV' -- "$MAIN" build --allow-internal "$src" -o "$bin" >/dev/null 2>&1 || true
  if [ -x "$bin" ]; then "$bin" > "$out" 2>/dev/null || true; else : > "$out"; fi
  if [ "$CHECK" -eq 1 ]; then
    if [ -f "$golden" ] && cmp -s "$out" "$golden"; then :
    else mism=$((mism+1)); [ -f "$golden" ] && { echo "DRIFT $golden"; diff "$golden" "$out" | head -6 | sed 's/^/    /'; } || echo "MISSING $golden"; fi
  else
    cp "$out" "$golden"; wrote=$((wrote+1))
  fi
}

CHECK=0
FILTER=""
FROZEN_TAG=""
case "${1:-}" in
  --check) CHECK=1 ;;
  --frozen)
    FROZEN_TAG="${2:-}"
    [ -n "$FROZEN_TAG" ] || {
      echo "usage: sh test/capture_goldens.sh --frozen <fmt|printer|boot_typecheck|selfproc_legA|llvm_eval|build_construct>"
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

  # parse / desugar / mark / boot_parse / boot_desugar / boot_mark: GONE.  That whole
  # family migrated to test/diff_compiler_snapshot_frontend.sh — one `.md` per fixture,
  # regenerated by `medaka snapshot`, which never re-blesses an existing snapshot.
  case "$FROZEN_TAG" in
    fmt)
      regen_frozen fmt_main fmt.golden "" \
        "$ROOT/test/fmt_fixtures/*.mdk" "$ROOT/test/parse_fixtures/*.mdk" ;;
    printer)
      regen_frozen printer_main printer.golden "" "$ROOT/test/parse_fixtures/*.mdk" ;;
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
    llvm_eval)
      # test/llvm_fixtures/*.eval.golden — the emitted program's RUNTIME STDOUT.
      #
      # Unlike every other frozen family this is not a stage dump, so regen_frozen
      # cannot express it: the golden only exists after emit -> clang -> link -> RUN.
      # This block mirrors test/diff_compiler_llvm.sh's `--one` worker EXACTLY (same
      # emit binary, same trailing-`()` strip, same GC detection, same link line), so
      # a regenerated golden is BY CONSTRUCTION the "actual" side that gate compares
      # against — there is no second implementation to drift.
      #
      # CONTRACT (why this renders Bools as True/False).  The probe is PRELUDE-FREE,
      # so a bare value main (`main = 3 >= 4`) has no `println` in scope and the
      # composite-main auto-print wrap (compiler/driver/main_autoprint.mdk) cannot
      # fire; the emitter's own scalar auto-print (emitPrint) calls the C runtime's
      # mdk_print_bool instead.  That function now renders the CONSTRUCTOR names
      # `True`/`False` — Medaka's `impl Display Bool` — so the probe's stdout equals
      # what a real `medaka build` of the same fixture prints (which goes through
      # `println`/`display`).  It used to print OCaml's lowercase `string_of_bool`,
      # which pinned this corpus to a rendering NO shipping binary could produce.
      LEMIT="$BIN/llvm_emit_main"
      [ -x "$LEMIT" ] || { echo "missing $LEMIT — run: sh test/build_oracles.sh --build-one llvm_emit_main"; exit 2; }
      LCC="${CC:-clang}"
      command -v "$LCC" >/dev/null 2>&1 || { echo "no C compiler ($LCC) on PATH"; exit 2; }
      if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
        LGC_CFLAGS="$(pkg-config --cflags bdw-gc)"; LGC_LIBS="$(pkg-config --libs bdw-gc)"
      elif LGC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$LGC_PREFIX" ] && [ -f "$LGC_PREFIX/include/gc.h" ]; then
        LGC_CFLAGS="-I$LGC_PREFIX/include"; LGC_LIBS="-L$LGC_PREFIX/lib -lgc"
      elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$LCC" -x c - -lgc -o /dev/null 2>/dev/null; then
        LGC_CFLAGS=""; LGC_LIBS="-lgc"
      else
        echo "libgc (bdw-gc) not found — cannot regenerate llvm_eval goldens"; exit 2
      fi
      LW="$(mktemp -d)"
      trap 'rm -rf "$LW"' EXIT
      LRT="$LW/medaka_rt.o"
      "$LCC" $LGC_CFLAGS -c "$ROOT/runtime/medaka_rt.c" -o "$LRT" 2>/dev/null || LRT="$ROOT/runtime/medaka_rt.c"
      lfail=0
      for f in "$ROOT"/test/llvm_fixtures/*.mdk; do
        [ -f "$f" ] || continue
        n="$(basename "$f" .mdk)"
        if ! "$LEMIT" "$f" 2>/dev/null | perl -0pe 's/\(\)\s*\z//' > "$LW/$n.ll"; then
          echo "  FAIL $n (emit)"; lfail=$((lfail+1)); continue
        fi
        if ! "$LCC" $LGC_CFLAGS "$LW/$n.ll" "$LRT" $LGC_LIBS -lm -o "$LW/$n.bin" 2>/dev/null; then
          echo "  FAIL $n (clang)"; lfail=$((lfail+1)); continue
        fi
        # The fixture's own exit status is part of its behaviour (abort_*/panic
        # fixtures exit non-zero AFTER printing); capture stdout regardless.
        "$LW/$n.bin" > "${f%.mdk}.eval.golden" 2>/dev/null
        fwrote=$((fwrote+1))
      done
      rm -rf "$LW"; trap - EXIT
      # A regenerator that silently writes 0 goldens is how a stale golden ships.
      [ "$fwrote" -gt 0 ] || { echo "wrote 0 goldens — no fixtures found under test/llvm_fixtures/"; exit 2; }
      [ "$lfail" -eq 0 ] || { echo "$lfail fixture(s) failed to emit/compile — goldens NOT written for those"; exit 1; }
      ;;
    build_construct)
      # test/construct_fixtures/*.build.golden — see capture_build_golden
      # (defined near the top of this file) for the producer contract.
      # Skips the SAME 5 known native-CLI-gap fixtures that
      # build_construct_coverage.sh's own SKIP list skips (kept in sync
      # manually — that file is out of scope to edit from here); those 5
      # have no golden and the gate never checks them, so capturing one
      # would be dead weight the gate never reads.
      [ -x "$MAIN" ] || { echo "missing $MAIN — run: make medaka"; exit 2; }
      BC_SKIP=" tuple_neq json_parse mod_reverse_string newtype_ctor_fn type_alias "
      fixtures=0; mism=0; wrote=0
      TMP="$(mktemp -d)"
      trap 'rm -rf "$TMP"' EXIT
      for f in "$ROOT"/test/construct_fixtures/*.mdk; do
        [ -f "$f" ] || continue
        label="$(basename "$f" .mdk)"
        case "$BC_SKIP" in *" $label "*) continue ;; esac
        capture_build_golden "$f" "${f%.mdk}.build.golden"
      done
      rm -rf "$TMP"; trap - EXIT
      fwrote="$wrote"
      [ "$fwrote" -gt 0 ] || { echo "wrote 0 goldens — no fixtures found under test/construct_fixtures/"; exit 2; }
      ;;
    *)
      echo "unknown --frozen tag: $FROZEN_TAG (expected fmt|printer|boot_typecheck|selfproc_legA|llvm_eval|build_construct)"
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
#
# ⚠️ eval_dict / eval_typed do NOT use `medaka run` as their oracle. `medaka run`
# gates on a STRICTER/DIFFERENT check than the probes it's supposed to stand in
# for (e.g. it rejects `test/eval_dict_fixtures/inferred_chain.mdk` with
# "Ambiguous instance for `Semigroup`" — a program the dict-passing probe
# resolves and diff_compiler_eval_dict.sh runs green, 26/26). A `medaka run`
# oracle silently regenerated a "drifted" golden that was never wrong — the
# committed golden was right, `medaka run` was the wrong reference. Mirror the
# gate's REAL producer exactly (test/bin/eval_dict_main / eval_typed_main with
# the same $RUNTIME/$CORE args and the same strip_unit), so a regenerated
# golden is BY CONSTRUCTION the gate's "actual" side — same model as the
# `--frozen llvm_eval` row below.
oracle_eval_dict() {
  [ -x "$DICT_BIN" ] || { echo "missing $DICT_BIN — run: sh test/build_oracles.sh --build-one eval_dict_main" >&2; return 2; }
  "$DICT_BIN" "$RUNTIME" "$CORE" "$1" 2>/dev/null | sed '${/^()$/d;}'
}
oracle_eval_typed() {
  [ -x "$TYPED_BIN" ] || { echo "missing $TYPED_BIN — run: sh test/build_oracles.sh --build-one eval_typed_main" >&2; return 2; }
  "$TYPED_BIN" "$RUNTIME" "$CORE" "$1" 2>/dev/null | sed '${/^()$/d;}'
}
# (`oracle_print_probe`/`FMT_NATIVE`/`PRINTER_NATIVE` used to live here — 100%
# dead code, called from nowhere: fmt/printer regeneration goes through the
# `regen_frozen` helper in the `--frozen` block above against
# test/bin/{fmt,printer}_main directly. Removed rather than left to rot further.)

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
# Of these, fmt / printer now HAVE a native equivalent
# (test/bin/{fmt,printer}_main, built by test/build_oracles.sh)
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
$ROOT/test/eval_dict_fixtures/*.mdk::eval_dict::eval.golden
$ROOT/test/eval_typed_fixtures/*.mdk::eval_typed::eval.golden
"

want() {  # want <tag> : true if no FILTER, or FILTER prefixes the tag/"eval"
  [ -z "$FILTER" ] && return 0
  case "eval" in "$FILTER"*) return 0 ;; esac
  case "$1" in "$FILTER"*) return 0 ;; esac
  return 1
}

# ── PREFLIGHT: a missing test/bin/* probe must NEVER look like a golden drift ──
#
# This mirrors test/run_gates.sh's stale-oracle refusal (same principle, same
# reason it exists): "I could not run this" and "the answer was wrong" are
# different failures and this tool must never conflate them. Before this
# preflight existed, a missing probe made `oracle_eval_dict`/`oracle_eval_typed`
# print "missing <bin> — run: ..." to STDERR, which `emit_golden` immediately
# discards (`"$@" 2>/dev/null`) — so the warning vanished, the probe's empty
# stdout got compared (or, in capture mode, WRITTEN) as if it were real output,
# and `--check` reported a wall of "DRIFT" for every fixture in that row. Worse:
# a plain (non-`--check`) capture run with the probe missing SILENTLY OVERWROTE
# every golden in that row with empty content and printed "0 oracle failures" —
# a real golden-corruption bug, not just a misleading message.
#
# So: determine which test/bin/* binaries THIS invocation actually needs
# (honoring $FILTER with the exact same row/tag selection the loops below use),
# check them ALL before touching a single golden, and if any are missing or
# non-executable, name them, print the exact fix, and exit — zero comparisons
# happened, so this is not a mismatch and must not be counted as one.
missing_bins=""
add_missing() {  # add_missing <binary-basename> (deduped)
  case " $missing_bins " in
    *" $1 "*) ;;
    *) missing_bins="$missing_bins $1" ;;
  esac
}
for row in $ROWS; do
  [ -n "$row" ] || continue
  glob="${row%%::*}"; rest="${row#*::}"
  tag="${rest%%::*}"; suffix="${rest#*::}"
  if [ -n "$FILTER" ]; then
    case "$suffix" in "$FILTER"*) ;; *) case "$tag" in "$FILTER"*) ;; *) continue ;; esac ;; esac
  fi
  case "$tag" in
    eval_dict)  [ -x "$DICT_BIN" ]  || add_missing eval_dict_main ;;
    eval_typed) [ -x "$TYPED_BIN" ] || add_missing eval_typed_main ;;
  esac
done
if want eval_modules; then
  [ -x "$EVAL_MODULES_BIN" ] || add_missing eval_modules_main
fi
if want repl; then
  [ -x "$REPL_BIN" ] || add_missing repl_main
fi

if [ -n "$missing_bins" ]; then
  echo "════════════════════════════════════════════════════════════════════"
  echo "MISSING ORACLE BINARIES — REFUSING TO RUN."
  echo
  echo "  Required by this invocation but not built (or not executable):"
  for b in $missing_bins; do echo "    test/bin/$b"; done
  echo
  echo "A missing probe is NOT a golden drift and this run made ZERO"
  echo "comparisons — do not read anything below this line as one."
  echo "(Comparing — or worse, in capture mode, WRITING — a missing binary's"
  echo "empty output against a committed golden looks exactly like a real"
  echo "regression, or silently corrupts the golden.)"
  echo
  echo "  Build them:"
  for b in $missing_bins; do
    echo "    FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $b"
  done
  echo "════════════════════════════════════════════════════════════════════"
  exit 2
fi

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
# (`want()` used to be defined here; moved up next to the PREFLIGHT block above —
# that block needs it too, and `want()` doesn't depend on anything defined between
# the two locations.)

# eval_modules : golden = the SAME native loader-driven probe
# diff_compiler_eval_modules.sh diffs against (test/bin/eval_modules_main),
# invoked identically ($CORE $entry $dir + strip_unit), so a regenerated
# golden is BY CONSTRUCTION the gate's "actual" side.
#
# Previously used `medaka run <entry>` as a stand-in (same risk class as the
# eval_dict/eval_typed rows above: `medaka run` runs a typecheck GATE the raw
# probe doesn't, so agreement isn't guaranteed). It happened not to diverge
# on this corpus — verified byte-identical on all 6 fixtures before this
# change — but the probe is the actual gate producer, so use it directly
# rather than relying on that agreement continuing to hold by luck.
oracle_eval_modules_dir() { "$EVAL_MODULES_BIN" "$1" "$2" "$3" 2>/dev/null | sed '${/^()$/d;}'; }
if want eval_modules; then
  total=$((total+1))
  if [ -x "$EVAL_MODULES_BIN" ]; then
    for dir in "$ROOT"/test/eval_modules_fixtures/*/; do
      [ -d "$dir" ] || continue
      entry="$(ls "$dir"main_*.mdk 2>/dev/null | head -1)"
      [ -n "$entry" ] || continue
      emit_golden "${dir%/}/main.eval.golden" oracle_eval_modules_dir "$CORE" "$entry" "${dir%/}"
    done
  else
    mism=$((mism+1))
    echo "missing $EVAL_MODULES_BIN — run: sh test/build_oracles.sh --build-one eval_modules_main"
  fi
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

# parse + desugar + mark : MIGRATED OUT.  The .parse/.desugar/.mark goldens (and their
# .boot_* twins) are gone; the family lives in test/snapshots/ as one `.md` per fixture,
# checked by test/diff_compiler_snapshot_frontend.sh and regenerated by `medaka snapshot`
# (which never overwrites an existing snapshot — there is no bless).

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

# capture_boot : FROZEN — all stage_main entries (lex_main, parse_main,
# resolve_main, typecheck_main, eval_main) call args() (native-only extern);
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
# build_cmd / build_diff committed *.build.golden files require the current
# native binary (stale worktree binary produces different output).  Re-capture
# after Phase 3 rebuild.
#
# build_construct is now WIRED UP as an opt-in `--frozen build_construct` tag
# (see the FROZEN_TAG block near the top of this file; `capture_build_golden`
# is defined up there too, alongside the other oracle helpers, so it's
# available when the FROZEN_TAG block runs — that block executes and `exit 0`s
# before reaching this point in the file) — it used to be dead code:
# `capture_build_golden` was defined but never called from anywhere in this
# script, and `test/build_construct_coverage.sh`'s own header told developers
# to run `sh test/capture_goldens.sh build_construct` to regenerate a missing
# golden — a tag/invocation that did not exist. Fixed here rather than there:
# mirroring `build_construct_coverage.sh` is out of scope for this file to
# edit, but this file owns the regenerator, so the fix belongs here. It is
# `--frozen`-gated, not a bare-`want` default row, because it is 144
# `medaka build` + clang link/run invocations — the same "must not churn a
# plain run" reasoning fmt/printer/llvm_eval are already gated on.

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
# A run that examined/wrote NOTHING must never look like a pass. This is how an
# unknown corpus/tag name (falling into the bare `*) FILTER="$1"` arm above,
# which becomes a suffix-prefix filter that matches zero rows) used to silently
# "bless" zero goldens and still exit 0 — you'd believe you captured a corpus
# when the run touched nothing. Read the count back, always: a filtered run
# prints WHY it matched nothing; an unfiltered run with zero output is just as
# wrong and gets the same refusal.
if [ "$CHECK" -eq 1 ]; then
  if [ "$fixtures" -eq 0 ]; then
    if [ -n "$FILTER" ]; then
      echo "ERROR: filter '$FILTER' matched ZERO fixtures — 0 checked, this is NOT a pass." >&2
    else
      echo "ERROR: 0 fixtures checked — this run examined nothing, this is NOT a pass." >&2
    fi
    echo "(Filters match a ROWS suffix/tag by PREFIX — see the ROWS table and want() near the top of this file.)" >&2
    exit 2
  fi
  printf 'CHECK: %d rows, %d fixtures, %d mismatch(es)\n' "$total" "$fixtures" "$mism"
  [ "$mism" -eq 0 ]
else
  if [ "$wrote" -eq 0 ]; then
    if [ -n "$FILTER" ]; then
      echo "ERROR: filter '$FILTER' matched ZERO fixtures — 0 goldens written, this is NOT a bless." >&2
    else
      echo "ERROR: 0 goldens written — this run blessed nothing, this is NOT a bless." >&2
    fi
    echo "(Filters match a ROWS suffix/tag by PREFIX — see the ROWS table and want() near the top of this file.)" >&2
    exit 2
  fi
  printf 'CAPTURED: %d rows, blessed %d goldens (%d oracle failures)\n' "$total" "$wrote" "$mism"
  [ "$mism" -eq 0 ]
fi
