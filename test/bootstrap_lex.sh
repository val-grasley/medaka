#!/bin/sh
# BOOTSTRAP (B1) — the FIRST native self-compile slice: prove the natively
# compiled self-hosted LEXER stage reproduces the reference lexer over real
# fixtures.  This is the milestone the whole emitter effort drove toward: a REAL
# compiler subcommand (the lexer) compiled natively and validated byte-for-byte
# against the reference token stream.
#
# OCaml-free (REROOT-PLAN §2e).  Both legs are now off the OCaml oracle:
#   reference (the "interpreter stage"): a committed golden per fixture, captured
#     from `main.exe run compiler/entries/lex_main.mdk <fixture>` while OCaml was
#     trusted (test/capture_goldens.sh boot_lex) — frozen as <fixture>.boot_lex.golden.
#   native   : test/bin/lex_main <fixture>  — the lex_main entry native-compiled by
#     `./medaka build` (test/build_oracles.sh), i.e. lex_main's graph emitted to
#     textual LLVM IR -> clang -> link libgc + runtime -> run.  This is exactly the
#     native lexer stage the spike validated; the emit+clang step now lives in the
#     OCaml-free `./medaka build` rather than `main.exe run <emitter>`.
#
# The native runtime AUTO-PRINTS main's value (lex_main's `main : <IO> Unit` -> a
# trailing "()" via mdk_print_unit) which the reference does NOT emit.  We strip
# that trailing "()" from the native output (strip_unit) before the diff — the
# golden is the raw reference token stream.
#
# This gate is now nearly redundant with the # TOKENS section of
# diff_compiler_snapshot_frontend.sh (native lex stage == snapshot over the same
# diff_fixtures corpus); kept distinct per REROOT-PLAN §2e (could fold later).
#
# Usage:  sh test/bootstrap_lex.sh
# Exit:   0 if every fixture's native token stream matches the golden;
#         2 if the oracle binary is missing (run sh test/build_oracles.sh first).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/lex_main"
FIXDIR="$ROOT/test/diff_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN") (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit auto-print; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  golden="${fix%.mdk}.boot_lex.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .boot_lex.golden — run sh test/capture_goldens.sh boot_lex)\n' "$name"; continue
  fi
  ref="$(cat "$golden")"
  self="$("$RUN" "$fix" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s\n' "$name"
    printf '%s' "$ref"  > "$ROOT/.boot_ref.$$"
    printf '%s' "$self" > "$ROOT/.boot_self.$$"
    diff "$ROOT/.boot_ref.$$" "$ROOT/.boot_self.$$" | head -20 | sed 's/^/    /'
    rm -f "$ROOT/.boot_ref.$$" "$ROOT/.boot_self.$$"
  fi
done

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
