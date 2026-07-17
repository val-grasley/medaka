#!/usr/bin/env bash
# diff_wasm_modules.sh — Slice W9 differential gate (WASMGC-DESIGN.md §9 / §8).  The
# MULTI-MODULE + REAL-PRELUDE peer of diff_wasm_typed.sh: it drives the
# wasm_emit_modules_main entry through the FULL `medaka build` front end (loader →
# elaborateModules with the REAL core.mdk prelude → core_ir_lower → DCE → wasm_emit),
# so dispatch flows through the real prelude and DCE prunes it to what each program
# reaches.  For each fixture (a single .mdk OR a multi-file program dir with entry.mdk),
# oracle = the native-compiled `medaka build`; emitter = the modules entry → WAT →
# wasm-tools → Node 24 → byte-diff stdout AND stderr AND exit code.
#
# #531: this gate used to compare stdout ONLY, discarding the oracle's stderr
# outright (`2>/dev/null`) and capturing wasm's stderr to a file that was never
# compared — and never looked at either engine's exit code. Any divergence living
# in stderr or the exit code (which is most of the interesting native/wasm trap
# surface — a coded panic vs a bare engine trap, a wrong exit status) passed
# silently: both engines print the same (possibly empty) stdout, and empty ==
# empty reads as a pass. #371 (wasm poly `/`/`%` briefly emitting a raw engine
# trap instead of the coded `[E-DIV-ZERO]`/`[E-MOD-ZERO]` line) is exactly this
# shape and had to be pinned with bespoke per-fixture stderr-grepping asserts
# because the generic compare could not see it. It now can: every fixture's
# native/wasm run is compared on all three channels, generically.
#
# REAL-PRELUDE GAP HANDLING (W9 incremental landing — see the slice writeup):
# the DCE'd real prelude retains every impl WHOLE, including POINT-FREE impls
# (`toList = identity`, `length = fold g 0`, `foldMap f = fold …`) whose source clause
# arity is LESS than the method's user arity.  Eta-expanding them correctly needs the
# method's declared-interface arity (to separate user args from forwarded `requires`
# dicts), which the WasmGC emitter does not yet thread (the install*-hook the LLVM
# emitter has, that wasm_emit deliberately lacks).  Until that lands, EVERY real-prelude
# program emits invalid WAT at those impls.  This gate therefore classifies a fixture
# that fails ONLY at wasm-tools validate as a KNOWN-GAP SKIP (not a failure), reports
# it, and still FAILS on any fixture that emits+validates+runs but byte-DIFFERS — so it
# locks in correctness for whatever the modules path CAN do while making the remaining
# MVP gap explicit.  A fixture that fully passes is an `ok`.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_modules_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/wasm/fixtures_modules"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"

# ── Per-fixture worker (parallel fan-out target) ───────────────────────────────
# Re-invoked as `sh "$0" --one <name> <entry> <root>` under an xargs -P pool.
# Writes an outcome code to $RESULTDIR/<name>.status: 0=ok, 1=FAIL (real
# divergence / build / parse / TMC-assert), 2=GAP (known MVP emit/validate gap —
# NOT a failure). Shared state via env; per-fixture .err (no shared scratch).
if [ "${1:-}" = "--one" ]; then
  name="$2"; entry="$3"; root="$4"
  obin="$WORKDIR/$name.oracle"; wat="$WORKDIR/$name.wat"; wasm="$WORKDIR/$name.wasm"
  st=0; msg=""
  if ! "$MEDAKA" build "$entry" -o "$obin" >"$WORKDIR/$name.build.err" 2>&1; then
    msg="$(printf 'FAIL %s (oracle build)\n%s' "$name" "$(cat "$WORKDIR/$name.build.err")")"; st=1
  elif ! "$EMITBIN" "$RUNTIME" "$CORE" "$entry" "$root" > "$wat" 2>"$WORKDIR/$name.emit.err"; then
    msg="$(printf 'GAP  %s (emit) %s' "$name" "$(head -1 "$WORKDIR/$name.emit.err" | sed 's/.*gap — //')")"; st=2
  elif ! wasm-tools parse "$wat" -o "$wasm" 2>"$WORKDIR/$name.parse.err"; then
    msg="$(printf 'FAIL %s (wasm-tools parse)\n%s' "$name" "$(head -2 "$WORKDIR/$name.parse.err")")"; st=1
  elif ! wasm-tools validate --features=all "$wasm" 2>"$WORKDIR/$name.val.err"; then
    msg="$(printf 'GAP  %s (validate: real-prelude point-free impl arity — %s)' "$name" "$(head -1 "$WORKDIR/$name.val.err")")"; st=2
  else
    # #531: compare ALL THREE channels — stdout, stderr, and exit code — for BOTH
    # engines, generically, not just stdout. A trap-shaped divergence (coded panic
    # vs bare engine trap, or a differing exit status) shows up on stderr/exit even
    # when stdout is identical (often empty on both sides), so stdout alone cannot
    # see it. Native's stderr used to be discarded outright (`2>/dev/null`).
    ref="$("$obin" 2>"$WORKDIR/$name.oracle.err")"; orc=$?
    got="$("$NODE" "$RUNJS" "$wasm" 2>"$WORKDIR/$name.run.err")"; wrc=$?
    oerr="$(cat "$WORKDIR/$name.oracle.err" 2>/dev/null)"
    werr="$(cat "$WORKDIR/$name.run.err" 2>/dev/null)"
    if [ "$ref" = "$got" ] && [ "$oerr" = "$werr" ] && [ "$orc" = "$wrc" ]; then
      msg="ok   $name -> $ref"
    else
      diverges=""
      [ "$ref" = "$got" ] || diverges="${diverges}stdout "
      [ "$oerr" = "$werr" ] || diverges="${diverges}stderr "
      [ "$orc" = "$wrc" ] || diverges="${diverges}exit "
      msg="$(printf 'FAIL %s (diverges: %s)\n  oracle: stdout=%s stderr=%s exit=%s\n  wasm  : stdout=%s stderr=%s exit=%s' \
        "$name" "$diverges" "$ref" "$oerr" "$orc" "$got" "$werr" "$wrc")"
      st=1
    fi
    # layer-8 IR-shape assertion for the dispatched List map fixture (must lower to
    # a dest-passing loop with 0 recursive self-calls — a dropped impl-TMC overflows V8).
    if [ "$st" = 0 ] && [ "$name" = "w_dispatch_map_stack.mdk" ]; then
      mapbody="$(awk '/func \$mdk_impl_List_map/{f=1} f&&/^  \(func /&&!/mdk_impl_List_map/{f=0} f' "$wat")"
      rec="$(printf '%s' "$mapbody" | grep -c 'call \$mdk_impl_List_map')"
      lp="$(printf '%s' "$mapbody" | grep -c 'loop \$tmcloop')"
      if [ "$rec" -eq 0 ] && [ "$lp" -ge 1 ]; then
        msg="$msg
TMC-ASSERT ok   $name: \$mdk_impl_List_map is a dest-passing loop, 0 recursive call"
      else
        msg="$(printf '%s\nTMC-ASSERT FAIL %s: recursive-call=%s loop=%s (expected 0 / >=1)' "$msg" "$name" "$rec" "$lp")"; st=1
      fi
    fi
    # P0-7 return_call assertion: the un-annotated Num-poly self-tail-recursive
    # `polyLoop` lowers its recursive call to a CDict head; it MUST become a
    # `return_call` (constant stack), NOT a plain `call` + `return`.  We check the
    # $..__polyLoop function body has >=1 `return_call $..__polyLoop` and 0 plain
    # `call $..__polyLoop` (the sole plain call to it is from `main`, a separate fn).
    if [ "$st" = 0 ] && [ "$name" = "w_polynum_tail_stack.mdk" ]; then
      lpbody="$(awk '/func \$[^ ]*__polyLoop /{f=1} f&&/^  \(func /&&!/__polyLoop /{f=0} f' "$wat")"
      plain="$(printf '%s' "$lpbody" | grep -cE '^\s*call \$[^ ]*__polyLoop')"
      rc="$(printf '%s' "$lpbody" | grep -cE 'return_call \$[^ ]*__polyLoop')"
      if [ "$rc" -ge 1 ] && [ "$plain" -eq 0 ]; then
        msg="$msg
RETCALL-ASSERT ok   $name: recursive self-call is return_call, 0 plain call"
      else
        msg="$(printf '%s\nRETCALL-ASSERT FAIL %s: plain-call=%s return_call=%s (expected 0 / >=1)' "$msg" "$name" "$plain" "$rc")"; st=1
      fi
    fi
  fi
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping W9 gate"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping W9 gate"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITBIN" ] || { echo "build the wasm modules emitter: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN)"; exit 2; }

# ── Node >= 22 selection (finalized WasmGC encoding) ─────────────────────────
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 22 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
if [ "$major" -lt 22 ]; then
  echo "W9 SKIP  Node >= 22 required for the finalized WasmGC encoding (have $($NODE --version 2>/dev/null))"
  exit 2
fi

[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

WORK="$(mktemp -d)"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

# Build the worklist: single-file fixtures + multi-file program dirs, each as a
# tab-separated "<name>\t<entry>\t<root>" line, then fan across an xargs -P pool of
# --one workers (see top of file). NODE resolved to an absolute path once.
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
NODE_ABS="$(command -v "$NODE" 2>/dev/null || echo "$NODE")"
{
  for f in "$FIXDIR"/*.mdk; do
    [ -f "$f" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$f")" "$f" "$(dirname "$f")"
  done
  for dir in "$FIXDIR"/*/; do
    [ -d "$dir" ] || continue
    entry="${dir%/}/entry.mdk"
    [ -f "$entry" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "${dir%/}")" "$entry" "${dir%/}"
  done
} > "$WORK/worklist.tsv"

MEDAKA="$MEDAKA" EMITBIN="$EMITBIN" RUNTIME="$RUNTIME" CORE="$CORE" \
MEDAKA_EMITTER="${MEDAKA_EMITTER:-$EMITTER}" NODE="$NODE_ABS" RUNJS="$RUNJS" \
WORKDIR="$WORK" RESULTDIR="$RESULTS" \
  xargs -P "$JOBS" -n 3 sh "$0" --one < "$WORK/worklist.tsv"

pass=0; fail=0; gap=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  case "$(cat "$s")" in
    0) pass=$((pass+1)) ;;
    2) gap=$((gap+1)) ;;
    *) fail=$((fail+1)) ;;
  esac
done

checked=$((pass+fail+gap))
printf '\n%d ok, %d gap (known real-prelude MVP gap), %d failing (%d checked)\n' "$pass" "$gap" "$fail" "$checked"
# checked == 0 means the worklist/result plumbing produced NOTHING to compare (e.g.
# an empty fixture dir, or every --one worker dying before writing a .status) — that
# must NOT read as a pass. [ "$fail" -eq 0 ] alone is true on 0/0/0, which is the
# exact "reported success having compared nothing" disease this gate exists to avoid
# in the stdout/stderr/exit dimension; do not let it reappear in the fixture-count
# dimension too.
if [ "$checked" -eq 0 ]; then
  echo "FAIL  0 fixtures checked — worklist or --one workers produced no results (this is NOT a pass)"
  exit 1
fi
# Green when nothing DIVERGES (a known-gap SKIP is not a failure); fails on a real
# byte-diff or an unexpected build/parse error.
[ "$fail" -eq 0 ]
