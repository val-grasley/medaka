#!/bin/sh
# test/check_self.sh — FAST "is the compiler source type-clean" gate, run
# against the ALREADY-BUILT ./medaka alone. No oracle build, no differential
# compare, no rebuild of ./medaka.
#
# Why this exists (issue #833): `make medaka` deliberately does not gate on
# type errors (the bootstrap emit path builds an ill-typed compiler green —
# see AGENTS.md), and the existing strict gate,
# test/typecheck_compiler_source.sh, needs a separate oracle
# (test/bin/diagnostics_project_main) built and kept fresh after every
# compiler-source edit — during a tight edit-verify loop on e.g. typecheck.mdk,
# rebuilding/refreshing that oracle is the slow part, not the check itself.
# This script answers ONLY "is the compiler source type-clean" by reusing the
# `./medaka check` CLI's OWN exit-code contract (it already exits 1 on any
# ERROR-severity diagnostic anywhere in the loaded project — see
# `checkRoute`/`locatedProjectErrors` in compiler/driver/medaka_cli.mdk) — no
# awk/parsing needed, and nothing to build beyond `./medaka` itself.
#
# Scope (DERIVED from typecheck_compiler_source.sh, not invented): this is the
# first PASS line of that script only — "medaka_cli.mdk closure is
# type-clean" — i.e. `compiler/driver/medaka_cli.mdk` and everything it
# transitively imports (frontend/types/ir/backend/driver/tools: essentially
# the whole compiler). Under the hood, `medaka check` on a multi-module entry
# runs the exact same `analyzeProject` function
# (compiler/driver/diagnostics.mdk) that
# compiler/entries/diagnostics_project_main.mdk (the oracle
# typecheck_compiler_source.sh's first pass drives) also runs — so this is not
# an approximation of that pass, it is the same underlying check reached
# through a different, already-built entry point.
#
# ⚠️ Deliberately NOT covered: typecheck_compiler_source.sh's SECOND pass,
# which separately typechecks every compiler/entries/*.mdk as its own entry
# (issue #472 — those probe files aren't reachable from medaka_cli.mdk's
# import graph). Measured on this box (12 cores): fanning that pass out over
# `./medaka check` at full parallelism (JOBS=8 or JOBS=12, both saturate)
# still takes ~70s wall-clock — it would blow the sub-minute goal this script
# exists to hit. typecheck_compiler_source.sh (full run, with its oracle)
# remains the authority for entries coverage; run it (or `make preflight`)
# before relying on that surface. This script is the fast first-line signal
# for the medaka_cli.mdk closure alone.
#
# Usage: sh test/check_self.sh
# Exit:  0 clean (0 error-severity diagnostics in the medaka_cli.mdk closure);
#        1 a type/resolve error was found (the located diagnostic is printed);
#        2 ./medaka is missing/not executable — build it first: make medaka.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
ENTRY="compiler/driver/medaka_cli.mdk"

[ -x "$MEDAKA" ] || {
  echo "check-self: $MEDAKA not found (or not executable) — build it first: make medaka"
  exit 2
}

# NOTE: run with cwd=$ROOT and pass ENTRY relative, same convention as
# typecheck_compiler_source.sh (module ids are derived from the path string
# passed in, so mixing an absolute entry with the CLI's own root-search would
# risk a mismatch).
out="$(cd "$ROOT" && "$MEDAKA" check "$ENTRY" 2>&1)"
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: compiler source has a type/resolve error (medaka_cli.mdk closure):"
  printf '%s\n' "$out"
  exit 1
fi

echo "PASS: medaka_cli.mdk closure is type-clean (./medaka check, no oracle)."
exit 0
