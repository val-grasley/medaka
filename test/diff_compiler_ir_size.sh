#!/bin/sh
# diff_compiler_ir_size.sh — the SIZE gate for emitted LLVM IR (issue #885, epic #880).
#
# ⚠️ WHY THIS EXISTS.
# CI's real bottleneck is clang: `medaka build` is clang-bound (compiler/AGENTS.md), and
# clang's cost tracks the SIZE of the text IR the emitter hands it. The historical bloat
# class — "a 9-line program emitted 32,896 lines of IR, 271/272 functions of it prelude"
# — was fixed by dispatch outlining (#129) and a reusable `prelude.o` (#131). But the
# only thing guarding that win is test/diff_compiler_dispatch_shape.sh, which is a SHAPE
# pin (the prelude bodies stay program-independent); nothing fails if emitted IR per
# program simply REGROWS in size. A regression of outlining / prelude.o / soleImplDirect
# would hand all that clang time back — silently, with every behaviour gate green.
#
# IR line count is DETERMINISTIC (the text IR is produced before clang ever runs, and the
# emitter is deterministic — verified byte-identical across repeated runs), so an ABSOLUTE
# ceiling is legitimate here in a way a wall-clock ceiling never is. This gate is the
# clang-bound analogue of diff_compiler_perf_scaling.sh: that gate is an O(n^2)-in-TIME
# detector and STRUCTURALLY CANNOT see a constant-factor IR blowup; this one can.
#
# TWO ASSERTIONS, both derived from the emitted IR — no golden, nothing to bless:
#
#   A. CEILING. A fixed tiny program emits under a hard line ceiling. Catches a
#      prelude-bloat regression (the whole prelude re-inlining per program), which drives
#      the tiny program's IR back toward the 32,896-line historical figure.
#
#   B. LINEAR SCALING. Emitted IR grows ~LINEARLY with LIVE (post-DCE) program size.
#      Generate a chain of N mutually-referencing decls, all rooted through `main` so DCE
#      keeps every one, at N / 2N / 4N; grade the RATIO of the per-doubling IR DELTAS.
#      Linear => ~2.0, quadratic => ~4.0 (same arithmetic as perf_scaling's alloc ratio).
#      Superlinear IR is the signature of dispatch re-inlining or per-decl emitter bloat.
#
# ⚠️ WHY THE DELTA RATIO, NOT THE RAW lines(2N)/lines(N).
# Every emitted module pays a large FIXED prelude constant — measured ~12,320 IR lines —
# that has nothing to do with N. It DOMINATES at these sizes: the raw whole-file ratio
# lines(2N)/lines(N) reads ~1.09 on a correct compiler, so it is BLIND — a genuine
# per-decl quadratic would hide inside that constant exactly the way perf_scaling.sh
# documents for `medaka check` startup (raw 1.56/2.52/3.63 -> 1.86/2.95/3.88 only once
# the constant is subtracted). The constant CANCELS out of a ratio of DELTAS across
# consecutive doublings: for lines(N) = C + m*N, delta(N->2N) = m*N and delta(2N->4N) =
# m*2N, so their ratio is 2.0 regardless of C; for a quadratic C + m*N^2 it is 4.0. So
# the delta ratio is the constant-free, baseline-subtracted form of "IR scales linearly
# with live program size" — see the MEASURED note by IR_SIZE_N.
#
# MEASURED (this box, deterministic, N=300/600/1200): per-decl IR is a flat 12 lines/decl
# (lines(N) = 12320 + 12*N exactly), so delta(N->2N)=3600, delta(2N->4N)=7200, ratio 2.00.
# The tiny program emits 12,332 lines; the ceiling below is set with ~30% headroom over it.
#
# The probe programs are written into a temp dir, NOT a fixture corpus — a fixture
# directory is a shared corpus and adding to one silently enrols you in gates you never
# named (AGENTS.md). This gate owns its inputs.
#
# Usage:  sh test/diff_compiler_ir_size.sh
#         IR_SIZE_N=400 sh test/diff_compiler_ir_size.sh     # base size for arm B
# Exit:   0 both assertions hold
#         1 an assertion failed (IR regrew past the ceiling, or scaled superlinearly),
#           OR the harness could not measure anything (a build failed / N==0) — never a
#           silent no-op
#         2 native medaka/emitter not built (opt-in skip, same as the other LLVM gates)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }

export MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER"

# ── Tunables ─────────────────────────────────────────────────────────────────
# CEILING for arm A. Current tiny-program IR is 12,332 lines; 16,000 is ~30% headroom.
# This is DELIBERATELY not tight: it exists to catch the 2-3x prelude-bloat class (the
# 32,896-line regression), not to police a handful of lines. If a legitimate prelude
# change lifts the tiny program's IR, re-measure and raise this WITH a comment — do not
# quietly bump it (a ceiling that tracks the value it bounds guards nothing).
CEIL="${IR_SIZE_CEIL:-16000}"

# Base size N for arm B. Sampled at N / 2N / 4N. Growth is deterministic so no floor /
# min-of-K / heap-pin is needed (unlike the TIME arm of perf_scaling) — one build each.
N="${IR_SIZE_N:-300}"

# FAIL threshold for the delta ratio. linear 2.0 | n log n ~2.1 | QUADRATIC 4.0. 3.0
# comfortably admits n log n and comfortably catches n^2 — same value perf_scaling uses.
THRESH="${IR_SIZE_THRESH:-3.0}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdk-irsize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

checked=0   # number of IR measurements taken; 0 at the end is a HARD FAILURE (no no-op).

# ir_lines <fixture> <outbase> — build with --keep-ir and echo the emitted IR line count.
# Any build failure / missing-or-empty .ll is a HARNESS FAILURE (exit 1), never a skip:
# a gate that cannot measure must say so, not certify the property as holding. The kept
# IR lands at <outbase>.ll (the established convention — see diff_compiler_dispatch_shape.sh).
ir_lines() {
  fixture="$1"; out="$2"
  if ! "$MEDAKA" build --keep-ir "$fixture" -o "$out" > "$out.build.log" 2>&1; then
    echo "FAIL: could not build $fixture:" >&2
    cat "$out.build.log" >&2
    exit 1
  fi
  if [ ! -s "$out.ll" ]; then
    echo "FAIL: no IR kept for $fixture (expected $out.ll) — harness bug or --keep-ir regressed." >&2
    exit 1
  fi
  wc -l < "$out.ll" | tr -d ' '
}

# gen_chain <n> <file> — N mutually-referencing top-level functions, each calling the
# previous, with `main` calling the LAST so the WHOLE chain is retained through DCE (the
# xref shape from perf_scaling). This makes N the count of LIVE, post-DCE decls: a `main`
# that reached nothing would let DCE prune the lot and the arm would measure the prelude
# alone. Every fN emits its own body, so IR grows with the live decl count.
gen_chain() {
  n="$1"; f="$2"; : > "$f"
  printf 'g0 : Int -> Int\ng0 x = x + 0\n' >> "$f"
  i=1
  while [ "$i" -lt "$n" ]; do
    prev=$((i - 1))
    printf 'g%s : Int -> Int\ng%s x = g%s x + %s\n' "$i" "$i" "$prev" "$i" >> "$f"
    i=$((i + 1))
  done
  # main calls the HEAD of the chain; f(n-1), not $prev (which stops at n-2 and would
  # strand the last function as one dead decl).
  printf 'main = println (g%s 0)\n' "$((n - 1))" >> "$f"
}

fail=0

# ── Arm A: the tiny-program ceiling ──────────────────────────────────────────
printf 'add : Int -> Int -> Int\nadd x y = x + y\nmain = println (add 2 3)\n' > "$WORK/tiny.mdk"
tiny="$(ir_lines "$WORK/tiny.mdk" "$WORK/tiny")"
checked=$((checked + 1))
case "$tiny" in
  ''|*[!0-9]*) echo "FAIL: tiny-program IR line count is not a number ('$tiny') — harness bug."; exit 1 ;;
esac
if [ "$tiny" -gt "$CEIL" ]; then
  printf 'FAIL (CEILING): the tiny program emitted %s IR lines, over the %s ceiling.\n' "$tiny" "$CEIL"
  printf '  This is the prelude-bloat class (#129/#131): the shared prelude / dispatchers\n'
  printf '  are being re-emitted per program. Inspect with: medaka build --keep-ir <f> -o <o>\n'
  printf '  then read <o>.ll. Do NOT just raise the ceiling — find what regrew.\n'
  fail=$((fail + 1))
else
  printf 'CEILING: tiny program = %s IR lines (ceiling %s) — ok\n' "$tiny" "$CEIL"
fi

# ── Arm B: linear scaling of IR with LIVE program size ───────────────────────
n1="$N"; n2="$((N * 2))"; n3="$((N * 4))"
gen_chain "$n1" "$WORK/b1.mdk"; L1="$(ir_lines "$WORK/b1.mdk" "$WORK/b1")"; checked=$((checked + 1))
gen_chain "$n2" "$WORK/b2.mdk"; L2="$(ir_lines "$WORK/b2.mdk" "$WORK/b2")"; checked=$((checked + 1))
gen_chain "$n3" "$WORK/b3.mdk"; L3="$(ir_lines "$WORK/b3.mdk" "$WORK/b3")"; checked=$((checked + 1))

for v in "$L1" "$L2" "$L3"; do
  case "$v" in ''|*[!0-9]*) echo "FAIL: a scaling IR line count is not a number ('$v') — harness bug."; exit 1 ;; esac
done

d1=$((L2 - L1))   # IR added going N   -> 2N
d2=$((L3 - L2))   # IR added going 2N  -> 4N

# A non-positive first delta means the live decls added no IR — DCE pruned the chain, or
# the generator/root shape broke. Grading a ratio off it would be meaningless: FAIL loudly.
if [ "$d1" -le 0 ]; then
  printf 'FAIL: IR did not grow from N=%s (%s lines) to 2N=%s (%s lines) — the live chain\n' "$n1" "$L1" "$n2" "$L2"
  printf '  is not being emitted (DCE pruned it, or the root/generator shape regressed).\n'
  exit 1
fi

# ratio = d2/d1, graded against THRESH. awk: deterministic inputs, plain float divide.
ratio="$(awk -v a="$d2" -v b="$d1" 'BEGIN { printf "%.2f", a / b }')"
over="$(awk -v r="$ratio" -v t="$THRESH" 'BEGIN { print (r > t) ? 1 : 0 }')"
printf 'SCALING: IR delta N->2N=%s (%s->%s lines), 2N->4N=%s (%s->%s), ratio=%sx (threshold %sx, N=%s)\n' \
  "$d1" "$L1" "$L2" "$d2" "$L2" "$L3" "$ratio" "$THRESH" "$n1"
if [ "$over" -eq 1 ]; then
  printf 'FAIL (SUPERLINEAR): emitted IR grew %sx per doubling of live decls (> %sx).\n' "$ratio" "$THRESH"
  printf '  linear ~2.0x | quadratic ~4.0x. This is dispatch re-inlining or per-decl emitter\n'
  printf '  bloat: each added decl is pulling in IR proportional to the whole program.\n'
  fail=$((fail + 1))
fi

printf -- '---------------------------------------------------------------------\n'
printf 'checked %s IR measurements (tiny + N/2N/4N)\n' "$checked"

# Never exit 0 having measured nothing — the #398/#525 "a check that ran nothing must not
# report green" discipline. checked==0 means every ir_lines call was skipped (impossible
# on a working binary), so it is a HARD FAILURE, not a pass.
if [ "$checked" -eq 0 ]; then
  echo "FAIL: the gate took no IR measurements at all (N==0) — harness bug, not a pass."
  exit 1
fi

if [ "$fail" -gt 0 ]; then
  printf '\n%s assertion(s) failed.\n' "$fail"
  exit 1
fi
printf 'PASS: emitted IR is under the ceiling and scales linearly with live program size.\n'
exit 0
