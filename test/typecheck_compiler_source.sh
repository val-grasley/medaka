#!/bin/sh
# test/typecheck_compiler_source.sh — strict-typecheck gate over the COMPILER'S
# OWN SOURCE.
#
# Pain point: `make medaka` + the self-compile fixpoint run the typechecker (for
# route-stamping / dict-passing) but never consult `hadTypeErrors()` — so an
# ill-typed compiler source can build green (only an oracle's `medaka build`/
# `medaka check` would catch it, and nothing runs that over the WHOLE compiler
# today). This gate closes that hole: it runs the project-wide diagnostics
# driver (compiler/entries/diagnostics_project_main.mdk, oracle at
# test/bin/diagnostics_project_main, same one test/diff_compiler_analyze_project.sh
# uses) over `compiler/driver/medaka_cli.mdk` — the real top-level CLI entry,
# whose transitive imports pull in essentially every compiler subsystem
# (frontend/types/ir/backend/driver/tools) in one closure — and FAILS if any
# ERROR-severity diagnostic is reported anywhere in the graph.
#
# WARNING-severity diagnostics (e.g. the internal-only `arrayGetUnsafe` notes,
# non-exhaustive-match warnings) do NOT fail this gate — only `error`/`error@` is
# treated as failing, mirroring the `<severity>:` convention documented in
# compiler/entries/diagnostics_project_main.mdk's own output format.
#
# ⚠️ SLOW ORACLE, NOT SLOW GATE: the compiled oracle runs in ~2-4 minutes (it
# typechecks ~35+ modules with no incremental caching) — seconds-fast relative to
# `medaka run` (the tree-walking interpreter, which never finishes over the whole
# compiler in practice), but slow relative to the other diff_compiler_*.sh gates.
# For that reason it is NOT picked up by run_gates.sh's default
# `diff_compiler_*` glob; it is wired in as an explicit extra gate (see
# run_gates.sh's EXTRA_GATES).
#
# Usage: sh test/typecheck_compiler_source.sh
# Exit:  0 clean (zero error-severity diagnostics); 1 an error-severity
#        diagnostic was found (offending FILE + lines printed); 2 oracle missing
#        (build it first: FORCE=1 JOBS=1 sh test/build_oracles.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/diagnostics_project_main"
# NOTE: paths passed to the oracle must be RELATIVE to $ROOT (module ids are
# derived from these path strings — mixing an absolute entry with relative
# roots, or vice versa, makes the loader miss the module-under-root match and
# error "unknown module"). Run with cwd=$ROOT and pass everything relative.
RT="stdlib/runtime.mdk"
CORE="stdlib/core.mdk"
ENTRY="compiler/driver/medaka_cli.mdk"

[ -x "$SELF" ] || {
  echo "build the oracle first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$SELF") (missing $SELF)"
  exit 2
}

out="$(cd "$ROOT" && "$SELF" "$RT" "$CORE" "$ENTRY" compiler stdlib 2>&1)"
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: diagnostics_project_main exited $status (crash, not a diagnostic) — output:"
  printf '%s\n' "$out"
  exit 1
fi

# Bucket the flat "## FILE <path>" / "<severity>[@line:col]: <message>" stream
# by file, then report only files carrying at least one error-severity line.
errors="$(printf '%s\n' "$out" | awk '
  /^## FILE / { file = $0; next }
  /^error(@|:)/ { print file; print; next }
')"

if [ -n "$errors" ]; then
  echo "FAIL: compiler source has type errors:"
  echo "$errors"
  exit 1
fi

echo "PASS: compiler source is type-clean (0 error-severity diagnostics)."
exit 0
