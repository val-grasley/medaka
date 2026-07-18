#!/bin/sh
# IR-GOLDEN gate over an INSTALLING emitter entry (issue #587).
#
# ── WHY THIS GATE EXISTS ──────────────────────────────────────────────────────
# diff_compiler_llvm.sh is our headline IR-golden gate ("220 ok, byte-identical
# IR"), but its entry — compiler/entries/llvm_emit_main.mdk — installs NONE of the
# emitter's seven side-tables (installReturnsSelf/installSelfFnParams/
# installMethodConstraintIfaces/installCtorFieldTypes/installDeclSigTypes/
# installMainIsUnitHint/installMainIsFloatHint are all empty there). So under that
# entry every side-table-fed code path runs in its degenerate state, and ANY change
# to those tables' content or lifecycle is a NO-OP that the 220-fixture gate cannot
# see. Meanwhile the gates that DO install the tables — diff_compiler_llvm_typed.sh
# and diff_compiler_llvm_modules.sh — compare program OUTPUT, not IR, so an IR
# PESSIMIZATION that still computes the right answer is invisible to them BY
# CONSTRUCTION (e.g. a specialized `@mdk_list_append` call degrading to a generic
# `@mdk_append` — same result, worse code). #587 proved this: applying #357's
# reset-the-seven-at-emitProgram change moved emitted IR and STILL passed
# "220 ok / 48 ok / 16 ok" across all three existing gates.
#
# This gate closes that hole: it drives the SAME installing entry the typed OUTPUT
# gate uses (test/bin/llvm_emit_typed_main, from compiler/entries/llvm_emit_typed_main.mdk,
# which installs all seven tables), but compares the EMITTED LLVM IR byte-for-byte
# against committed goldens. A change that moves the IR — including an inert
# pessimization — flips a golden RED here even when the program's output is
# unchanged.
#
# ── CORPUS: the WHOLE typed corpus, on purpose ────────────────────────────────
# Every fixture under test/llvm_fixtures_typed/ gets an IR golden. This is the
# same corpus diff_compiler_llvm_typed.sh drives; adding an .ll.golden sibling
# enrolls no new fixture and changes no other gate's fixture set. The emitted IR is
# fully deterministic (sequential %tN temporaries, deterministic mangled symbol
# names, no target triple — the seed cold-bootstraps x86/arm from one byte stream),
# so a whole-corpus pin has no flake surface and needs no curation. It IS noisier
# than diff_compiler_llvm.sh in the sense the issue warns about — a typed entry's IR
# moves for more reasons — but that noise is exactly the signal: an emitter change
# that moves IR must be BLESSED here in the same commit, the same discipline as the
# snapshot corpora. We deliberately do NOT curate a subset: a curated subset that
# silently drops fixtures re-creates #587's own bug one level up (a gate whose
# window is narrower than its reputation). If a future maintainer must curate, this
# gate MUST print exactly which fixtures it dropped.
#
# ── GOLDEN CAPTURE ────────────────────────────────────────────────────────────
# CAPTURE=1 sh test/diff_compiler_llvm_typed_ir.sh   (re)writes every <name>.ll.golden
# from test/bin/llvm_emit_typed_main. A capture that would write ZERO goldens is a
# FAILURE, not a silent pass (a stale golden's classic ship path). The golden is the
# emitter's exact stdout — no post-processing — so the gate compares precisely what
# the backend emitted.
#
# ── FOUR QUESTIONS (issue #587 / ORCHESTRATING.md) ────────────────────────────
#  1. Where is it skipped? It runs in the `backend` CI shard (globbed by
#     'diff_compiler_llvm*' in .github/workflows/ci.yml) — i.e. it runs on exactly
#     the PRs that touch the emitter/side-tables, which is never a docs-only PR.
#  2. Is the caught bug-class the skip's trigger-class? Yes: it fails iff emitted IR
#     moves, and an emitter/side-table change is precisely what moves emitted IR.
#  3. Seen it fail? Yes — applying #357's reset-the-seven at emitProgram degraded
#     @mdk_list_append -> @mdk_append and this gate named the fixture; reverted.
#  4. Can it no-op? No: N==0 (no fixtures, or no goldens) is a hard FAILURE below.
#
# Usage:  sh test/diff_compiler_llvm_typed_ir.sh
#         CAPTURE=1 sh test/diff_compiler_llvm_typed_ir.sh   # (re)capture goldens
# Exit:   0 every fixture's emitted IR matches its golden; 1 a mismatch / missing
#         golden / zero fixtures; 2 the emit binary is not built.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITBIN="$ROOT/test/bin/llvm_emit_typed_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/llvm_fixtures_typed"

# ── Per-fixture worker (parallel fan-out target); shared state via env ─────────
if [ "${1:-}" = "--one" ]; then
  f="$2"
  name="$(basename "$f")"
  golden="${f%.mdk}.ll.golden"
  raw="$WORKDIR/$name.ll"
  st=0; msg=""
  # Check $EMITBIN's OWN exit status directly (dash has no pipefail; see #443/#632).
  "$EMITBIN" "$RUNTIME" "$f" > "$raw" 2>"$WORKDIR/$name.emit.err"
  emit_rc=$?
  if [ "$emit_rc" -ne 0 ]; then
    msg="$(printf 'FAIL %s (emit)\n%s' "$name" "$(cat "$WORKDIR/$name.emit.err")")"; st=1
  elif [ "${CAPTURE:-0}" = "1" ]; then
    cp "$raw" "$golden"
    msg="captured $name"
  elif [ ! -f "$golden" ]; then
    msg="no golden for $name (run CAPTURE=1 sh test/diff_compiler_llvm_typed_ir.sh)"; st=1
  elif diff -u "$golden" "$raw" > "$WORKDIR/$name.diff" 2>&1; then
    msg="ok   $name"
  else
    msg="$(printf 'FAIL %s (emitted IR differs from golden)\n%s' "$name" "$(cat "$WORKDIR/$name.diff")")"; st=1
  fi
  printf '%s\n' "$msg" > "$RESULTDIR/$name.out"
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

[ -x "$EMITBIN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$EMITBIN") (missing $EMITBIN)"; exit 2; }

WORK="$(mktemp -d)"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

fixtures="$(ls "$FIXDIR"/*.mdk 2>/dev/null)"
n_fixtures=0
if [ -n "$fixtures" ]; then
  n_fixtures="$(printf '%s\n' "$fixtures" | wc -l | tr -d ' ')"
  printf '%s\n' "$fixtures" \
    | EMITBIN="$EMITBIN" RUNTIME="$RUNTIME" WORKDIR="$WORK" RESULTDIR="$RESULTS" CAPTURE="${CAPTURE:-0}" \
      xargs -P "$JOBS" -n 1 -I{} sh "$0" --one {}
fi

# N == 0 MUST be a FAILURE, not a pass (issue #587 Q4): a gate that checked nothing
# must never report green — the whole disease this suite is being hardened against.
if [ "$n_fixtures" -eq 0 ]; then
  echo "FAIL: no fixtures found under $FIXDIR — this gate checked NOTHING, which is a failure, not a pass."
  exit 1
fi

pass=0; fail=0; seen=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  seen=$((seen+1))
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

# Completeness check (issue #637): a worker killed mid-run under xargs -P writes no
# .status file, so it would otherwise vanish from BOTH pass and fail.
if [ "$seen" -ne "$n_fixtures" ]; then
  missing=$((n_fixtures - seen))
  echo "FAIL: $missing of $n_fixtures workers produced no result — a worker died/was killed; this run is INCOMPLETE, not green."
  exit 1
fi

if [ "${CAPTURE:-0}" = "1" ]; then
  # A capture that wrote zero goldens is a stale-golden ship path — refuse it.
  if [ "$pass" -eq 0 ]; then
    echo "FAIL: CAPTURE wrote 0 goldens ($fail failed to emit) — refusing a zero-write capture."
    exit 1
  fi
  printf '\ncaptured %d IR goldens, %d failed to emit\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
else
  printf '\nchecked %d, %d ok, %d failing\n' "$n_fixtures" "$pass" "$fail"
  [ "$fail" -eq 0 ]
fi
