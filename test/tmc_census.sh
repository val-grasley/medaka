#!/usr/bin/env bash
# tmc_census.sh — per-function TMC census across BOTH backends (TMC parity arc).
#
# Emits a pinned corpus through the LLVM and WasmGC emitters and extracts, per
# backend, the set of SOURCE functions that received a TMC (tail-modulo-cons)
# destination-passing transform.  The parity gate (diff_compiler_tmc_parity.sh)
# wraps this helper and FAILS on any set difference; run standalone to inspect.
#
# Extraction is marker-first: both emitters emit a deterministic census marker
# per TMC decision (`; tmc: <fn> <mode>` in .ll / `;; tmc: <fn> <mode>` in .wat).
# When no marker is present in an artifact (older binaries), falls back to IR
# shape (LLVM: defines containing `br label %trmcloop`; wasm: funcs containing
# `$tmcloop`, plus `<root>__disploop` group functions).  Modes:
#   trmc  — self-recursive/impl destination-passing loop (Stage 1 / B-dispatch)
#   group:<root> — member of a dispatch-graph (b') TMC group rooted at <root>
#
# Corpus (must stay emit-able by BOTH backends):
#   • test/stack_fixtures/*.mdk          (prelude-free deep builders)
#   • test/wasm/fixtures/w_trmc_*.mdk    (wasm TMC fixtures, incl. dispatch shape)
#   • test/wasm/fixtures/w_deep_append.mdk (dict-carrying builder + `++`)
#   • compiler/entries/check_main.mdk    (the compiler front-end module graph —
#     the real-world corpus: lexer/layout/parser/typecheck families + prelude impls)
#
# Each fixture is emitted through TWO arms:
#   • the PROBE arm (llvm_emit_main / wasm_emit_main): parse→desugar→lower→emit,
#     NO typecheck, NO prelude — a cheap detection-drift signal, but blind to the
#     dict-param population (no typecheck ⇒ no dictPass ⇒ no `$dict` params);
#   • the SHIPPING arm (medaka_emitter / wasm_emit_modules_main with
#     stdlib/runtime.mdk + stdlib/core.mdk — the exact pair `medaka build` shells
#     out to): the path users take.  Written as <name>.ship.{llvm,wasm}.tmc.
#     An unannotated polymorphic builder carries a `$dict` param ONLY here, which
#     is how TMC once silently declined on every such builder while this census
#     stayed green (compiler/WASM-TMC-GAP-DESIGN.md).
#
# COVERAGE PINS: a fixture may declare `-- EXPECT-TMC: fn1 fn2 …` in its header.
# Every pinned fn must appear (any mode) in BOTH backends' SHIPPING sets, else
# the census fails with a PINFAIL row.  Parity between two sets that both
# dropped a function is vacuous; the pins are the coverage claim.
#
# Usage: sh test/tmc_census.sh [outdir]
#   Writes <item>.{llvm,wasm}.tmc sorted set files + SUMMARY into outdir
#   (default: a mktemp dir, path printed).  Exit 0 unless an EMIT or PIN fails.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITTER="$ROOT/medaka_emitter"
LLVM_ONE="$ROOT/test/bin/llvm_emit_main"
WASM_ONE="$ROOT/test/bin/wasm_emit_main"
WASM_MODS="$ROOT/test/bin/wasm_emit_modules_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

for b in "$EMITTER" "$LLVM_ONE" "$WASM_ONE" "$WASM_MODS"; do
  # These four binaries come from THREE different builders, so the hint lists all three —
  # but the build_oracles one names the TARGETED form (#527): bare build_oracles.sh spawns
  # the xargs -P pool AGENTS.md documents as having killed several agents.
  [ -x "$b" ] || { echo "missing $b — try: make medaka | FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$b") | sh test/wasm/build_wasm_oracle.sh"; exit 2; }
done

OUT="${1:-$(mktemp -d /tmp/tmc_census.XXXXXX)}"
mkdir -p "$OUT"

# extract_ll FILE — one "<fn> <mode>" line per TMC'd source function, sorted.
extract_ll() {
  if grep -q '^; tmc: ' "$1"; then
    sed -n 's/^; tmc: //p' "$1"
  else
    awk '/^define /{fn=$0; sub(/.*@/,"",fn); sub(/\(.*/,"",fn); cur=fn}
         /br label %trmcloop/{print cur " trmc"}
         /gdispexit[0-9]*:/{print cur " group-root"}' "$1"
  fi | sed 's/^mdk_//' | sort -u
}

# extract_wat FILE — same contract for a WAT artifact.
extract_wat() {
  if grep -q '^ *;; tmc: ' "$1"; then
    sed -n 's/^ *;; tmc: //p' "$1"
  else
    { awk '/\(func \$/{fn=$0; sub(/.*\(func \$/,"",fn); sub(/[ )].*/,"",fn); cur=fn}
           /\$tmcloop/{print cur " trmc"}' "$1"
      grep -o '(func \$[A-Za-z0-9_]*__disploop' "$1" \
        | sed 's/(func \$//; s/__disploop//; s/$/ group-root/'; }
  fi | sed 's/^mdk_//' | sort -u
}

fail=0
# extract_pair NAME — both artifacts already emitted to $OUT/NAME.{ll,wat}.
extract_pair() {
  extract_ll "$OUT/$1.ll" > "$OUT/$1.llvm.tmc"
  extract_wat "$OUT/$1.wat" > "$OUT/$1.wasm.tmc"
}

emit_or_fail() { # backend name cmd...
  be="$1"; nm="$2"; shift 2
  ext=ll; [ "$be" = wasm ] && ext=wat
  if ! "$@" > "$OUT/$nm.$ext" 2>"$OUT/$nm.$ext.err"; then
    echo "EMIT-FAIL $be $nm"; head -5 "$OUT/$nm.$ext.err"; fail=1; return 1
  fi
}

# check_pins FIXTURE NAME — enforce the fixture's `-- EXPECT-TMC:` pins against
# the SHIPPING sets.  A pinned fn must appear (any mode; module-prefixed names
# match on the `__<fn>` suffix) in BOTH backends' NAME.ship.*.tmc.
check_pins() {
  fx="$1"; nm="$2"
  pins="$(sed -n 's/^-- EXPECT-TMC: *//p' "$fx")"
  [ -n "$pins" ] || return 0
  for fn in $pins; do
    for be in llvm wasm; do
      if ! grep -Eq "(^|__)$fn " "$OUT/$nm.ship.$be.tmc" 2>/dev/null; then
        echo "PINFAIL $nm: '$fn' missing from the $be SHIPPING TMC set" >> "$OUT/PINFAILS"
        fail=1
      fi
    done
  done
}

# ── single-file corpus (probe arm + shipping arm) ─────────────────────────────
for f in "$ROOT"/test/stack_fixtures/*.mdk "$ROOT"/test/wasm/fixtures/w_trmc_*.mdk \
         "$ROOT"/test/wasm/fixtures/w_deep_append.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .mdk)"
  if emit_or_fail llvm "$name" "$LLVM_ONE" "$f" \
     && emit_or_fail wasm "$name" "$WASM_ONE" "$f"; then
    extract_pair "$name"
  fi
  if emit_or_fail llvm "$name.ship" "$EMITTER" "$RUNTIME" "$CORE" "$f" \
     && emit_or_fail wasm "$name.ship" "$WASM_MODS" "$RUNTIME" "$CORE" "$f"; then
    extract_pair "$name.ship"
    check_pins "$f" "$name"
  fi
done

# ── the compiler front-end module graph (the real-world corpus) ──────────────
GRAPH_ENTRY="$ROOT/compiler/entries/check_main.mdk"
if emit_or_fail llvm check_main "$EMITTER" "$RUNTIME" "$CORE" "$GRAPH_ENTRY" "$ROOT/compiler" "$ROOT/stdlib" \
   && emit_or_fail wasm check_main "$WASM_MODS" "$RUNTIME" "$CORE" "$GRAPH_ENTRY" "$ROOT/compiler" "$ROOT/stdlib"; then
  extract_pair check_main
fi

# ── summary ───────────────────────────────────────────────────────────────────
{
  echo "TMC census — $(ls "$OUT" | grep -c '\.llvm\.tmc$') corpus items — outdir $OUT"
  for l in "$OUT"/*.llvm.tmc; do
    name="$(basename "$l" .llvm.tmc)"; w="$OUT/$name.wasm.tmc"
    nl="$(wc -l < "$l")"; nw="$(wc -l < "$w")"
    if cmp -s "$l" "$w"; then echo "same $name (llvm=$nl wasm=$nw)"
    else
      echo "DIFF $name (llvm=$nl wasm=$nw)"
      diff "$l" "$w" | sed 's/^/    /'
    fi
  done
  [ -f "$OUT/PINFAILS" ] && cat "$OUT/PINFAILS"
} | tee "$OUT/SUMMARY"

exit $fail
