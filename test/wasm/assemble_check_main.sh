#!/usr/bin/env bash
# assemble_check_main.sh — whole-program LINKAGE gate for the WasmGC backend.
#
# The milestone: the front-end compiler entry (lex→parse→resolve→exhaust→typecheck,
# `compiler/entries/check_main.mdk`) emits to WAT through the FULL `medaka build`
# front end (loader → elaborateModules with the real core.mdk prelude → core_ir_lower
# → DCE → wasm_emit) and that WAT must ASSEMBLE: every `$mdk_w_*` function referenced
# (by a closure wrapper / ref.func) must also be DEFINED.
#
# The bug this guards against: the wasm emitter's pre-scan `scanFnValueUses` decides
# which top-level fns get a closure WRAPPER (`$mdk_w_<f>`).  If that scan skips a CExpr
# arm that `emitVarRef` descends into at emit time (CTuple/CRecord/CRecordUpdate/…),
# a fn used as a VALUE inside such an arm gets its `ref.func $mdk_w_<f>` emitted but its
# wrapper never DEFINED → wasm-tools parse fails with "unknown func".  15 such fns
# (frontend_desugar/exhaust/types_typecheck) regressed the front-end entry before the
# fix that made the scan structurally complete.
#
# This gate emits check_main, asserts `wasm-tools parse` + `validate`* succeed, AND
# independently asserts ZERO referenced-but-undefined `$mdk_w_*` funcs.
#
# *NOTE on validate: `parse` succeeding (all funcs defined) is the LINKAGE headline.
# The eta-expansion class (a point-free constrained fn `elem a = fold g False` whose
# under-applied CMethod body underflowed the dispatch call) and the ctor-as-VALUE class
# (`map PVar xs` — an arity>0 ctor passed as a function needs an eta-CLOSURE, not a
# malformed partial struct.new) are both FIXED (wasm_emit etaSaturateFnClause +
# emitCtorEtaClosure).  The decision-tree string-discriminated-arm class is ALSO FIXED:
# a match that discriminates two same-tag ctors by a STRING field (`TCon "Float"` vs
# `TCon "Int"`) lowered the nested literal switch as `if (result (ref eq))`.  When that
# switch sits in a constructor-tower SLOT (not at the outer `$dec` position) the phantom
# `(result (ref eq))` left a value on the stack at the untyped slot `end` → "values
# remaining on stack at end of block" (func 1377, types_typecheck__setNumlitFloatsGo).
# Fix: `emitLitSwitchRef` now emits a NO-RESULT `if` (every decision-tree path is already
# `br`-terminated, so no fall-through value), matching the tail-mode `emitLitSwitchTail`.
# With that fixed the WHOLE front-end now VALIDATES.
# So this gate's hard assertion is PARSE + zero-missing-defs + VALIDATE (validate now
# fatal by default; set REQUIRE_VALIDATE=0 to demote it back to a report).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMITBIN="$ROOT/test/bin/wasm_emit_modules_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
ENTRY="$ROOT/compiler/entries/check_main.mdk"
SELFHOST="$ROOT/compiler"
STDLIB="$ROOT/stdlib"

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping linkage gate"; exit 2; }
[ -x "$EMITBIN" ] || { echo "build the wasm modules emitter: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN)"; exit 2; }

WAT="$(mktemp /tmp/assemble_check_main.XXXXXX.wat)"
WASM="$(mktemp /tmp/assemble_check_main.XXXXXX.wasm)"
trap 'rm -f "$WAT" "$WASM"' EXIT

echo "emitting check_main front-end -> WAT ..."
"$EMITBIN" "$RUNTIME" "$CORE" "$ENTRY" "$SELFHOST" "$STDLIB" > "$WAT" 2>/dev/null
[ -s "$WAT" ] || { echo "FAIL: emitter produced empty WAT"; exit 1; }
echo "  WAT: $(wc -l < "$WAT") lines"

# ── linkage invariant: every referenced $mdk_w_* func is also defined ────────────
DEFS="$(grep -oE '\(func \$mdk_w_[A-Za-z0-9_]+' "$WAT" | sed 's/(func //' | sort -u)"
REFS="$(grep -oE '\$mdk_w_[A-Za-z0-9_]+' "$WAT" | sort -u)"
MISSING="$(comm -13 <(printf '%s\n' "$DEFS") <(printf '%s\n' "$REFS"))"
NMISS="$(printf '%s' "$MISSING" | grep -c . )"
if [ "$NMISS" -ne 0 ]; then
  echo "FAIL: $NMISS referenced \$mdk_w_* funcs are NOT defined:"
  printf '%s\n' "$MISSING" | sed 's/^/    /'
  exit 1
fi
echo "  linkage ok: 0 referenced-but-undefined \$mdk_w_* funcs"

# ── wasm-tools parse: the hard ASSEMBLE assertion ────────────────────────────────
if ! wasm-tools parse "$WAT" -o "$WASM" 2>/tmp/assemble_check_main.parseerr; then
  echo "FAIL: wasm-tools parse rejected the WAT:"
  sed 's/^/    /' /tmp/assemble_check_main.parseerr | head -8
  exit 1
fi
echo "ASSEMBLE_OK"

# ── wasm-tools validate: fatal by default (REQUIRE_VALIDATE=0 demotes to a report) ──
if wasm-tools validate "$WASM" 2>/tmp/assemble_check_main.valerr; then
  echo "VALIDATE_OK"
else
  echo "validate: FAILED — see the error below + the script header for the residual class"
  sed 's/^/    /' /tmp/assemble_check_main.valerr | head -4
  if [ "${REQUIRE_VALIDATE:-1}" = "1" ]; then exit 1; fi
fi
exit 0
