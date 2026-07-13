#!/bin/sh
# Differential validation for the self-hosted eval stage: RUNTIME ERROR messages.
#
# Each fixture in test/eval_error_fixtures/ is a program that type-checks but
# fails at evaluation time.  A committed <name>.expected golden holds the
# normalized error message text (no location, no "panic:" prefix).
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/eval_main vs the committed
# <name>.expected golden (the OCaml main.exe oracle that originally derived these
# messages is no longer run live — the golden is frozen).
#
# Per fixture, two checks:
#   B. Self-hosted must exit non-zero on the bad input.
#   C. Self-hosted message must equal the golden.
#
# Normalization: the native binary prints the bare message to stderr; a defensive
# ".*panic: " strip handles any runtime that prefixes it.
#
# Usage:  sh test/diff_compiler_eval_errors.sh
# Exit:   0 if every fixture passes, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Prelude-bearing eval entry: index sugar (`.[i]`) desugars to a prelude `index`
# method call (F2a retired the built-in EIndex path), so the OOB fixtures need
# stdlib/core.mdk prepended to reach the `Index` impls that raise E-INDEX-OOB.
# The other (prelude-free) fixtures produce byte-identical messages with core
# prepended, so one prelude-bearing entry covers the whole corpus.
RUN="$ROOT/test/bin/eval_prelude_main"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_error_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Extract the message from the native binary's stderr (first message-bearing line),
# stripping any "…: panic: " or "error: " prefix a runtime might add.
norm_msg() {
  grep -E "panic:|^error:|." | head -1 | sed -E 's/.*panic: //; s/^error: //'
}

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "${f%.mdk}")"
  golden_file="${f%.mdk}.expected"
  golden="$(cat "$golden_file" | tr -d '\n')"

  ok=1; reason=""

  # B. Self-hosted must exit non-zero
  "$RUN" "$CORE" "$f" >/dev/null 2>&1
  exit_code=$?
  [ "$exit_code" -ne 0 ] || { ok=0; reason="compiler exited 0 (should error)"; }

  # C. Self-hosted message must match golden
  if [ "$ok" -eq 1 ]; then
    self_out="$("$RUN" "$CORE" "$f" 2>&1 >/dev/null | norm_msg)"
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
