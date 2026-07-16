#!/bin/sh
# Differential validation for the self-hosted parser/lexer *rejection* path.
#
# Each fixture in test/parse_error_fixtures/ is a deliberately malformed .mdk
# program with a committed <name>.expected golden (the normalized error message).
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/parse_main vs the committed
# <name>.expected golden (the OCaml astdump oracle that originally derived these
# messages is no longer run live — the golden is frozen).
#
# Per fixture, two checks:
#   B. Self-hosted rejection — the native parse_main must exit non-zero.
#   C. Self-hosted message — the native panic message must equal the golden.
#
# Normalization: the native binary prints the bare error message to stderr; a
# defensive ".*panic: " strip handles any runtime that prefixes it.
#
# Usage:  sh test/diff_compiler_parse_errors.sh
# Exit:   0 if every fixture passes, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/parse_main"
FIXDIR="$ROOT/test/parse_error_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN") (missing $RUN)"; exit 2; }

# Extract the error message from the native binary's stderr (first message-bearing
# line), stripping any "…: panic: " prefix a runtime might add — including the
# coded "runtime error [E-PANIC]: " banner mdk_panic now prepends to a raw panic
# (RUNTIME-TRAP-UNIFY): the probe verifies the parser/lexer MESSAGE, not the
# runtime's framing (the user-facing CLI path renders located parse errors via
# ppParseError, unaffected).
norm_self() {
  grep -E "panic:|." | head -1 | sed 's/.*panic: //; s/^runtime error \[E-PANIC\]: //'
}

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "${f%.mdk}")"
  golden_file="${f%.mdk}.expected"
  golden="$(cat "$golden_file" | tr -d '\n')"

  ok=1; reason=""

  # B. Self-hosted must exit non-zero
  "$RUN" "$f" >/dev/null 2>&1
  exit_code=$?
  [ "$exit_code" -ne 0 ] || { ok=0; reason="compiler exited 0 (should reject)"; }

  # C. Self-hosted message must match golden
  if [ "$ok" -eq 1 ]; then
    self_out="$("$RUN" "$f" 2>&1 >/dev/null | norm_self)"
    [ "$self_out" = "$golden" ] || { ok=0; reason="compiler: got \"$self_out\" want \"$golden\""; }
  fi

  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL %s (%s)\n' "$name" "$reason"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
