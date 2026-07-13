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
#   • compiler/entries/check_main.mdk    (the compiler front-end module graph —
#     the real-world corpus: lexer/layout/parser/typecheck families + prelude impls)
#
# Usage: sh test/tmc_census.sh [outdir]
#   Writes <item>.{llvm,wasm}.tmc sorted set files + SUMMARY into outdir
#   (default: a mktemp dir, path printed).  Exit 0 unless an EMIT fails.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITTER="$ROOT/medaka_emitter"
LLVM_ONE="$ROOT/test/bin/llvm_emit_main"
WASM_ONE="$ROOT/test/bin/wasm_emit_main"
WASM_MODS="$ROOT/test/bin/wasm_emit_modules_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

for b in "$EMITTER" "$LLVM_ONE" "$WASM_ONE" "$WASM_MODS"; do
  [ -x "$b" ] || { echo "missing $b (make medaka; sh test/build_oracles.sh; sh test/wasm/build_wasm_oracle.sh)"; exit 2; }
done

OUT="${1:-$(mktemp -d /tmp/tmc_census.XXXXXX)}"
mkdir -p "$OUT"

# extract_ll FILE — one "<fn> <mode>" line per TMC'd source function, sorted.
extract_ll() {
  if grep -q '^; tmc: ' "$1"; then
    sed -n 's/^; tmc: //p' "$1"
  else
    awk '/^define /{fn=$0; sub(/.*@/,"",fn); sub(/\(.*/,"",fn); cur=fn}
         /br label %trmcloop/{print cur " trmc"}' "$1"
  fi | sed 's/^mdk_//' | sort -u
}

# extract_wat FILE — same contract for a WAT artifact.
extract_wat() {
  if grep -q '^;; tmc: ' "$1"; then
    sed -n 's/^;; tmc: //p' "$1"
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

# ── prelude-free single-file corpus ──────────────────────────────────────────
for f in "$ROOT"/test/stack_fixtures/*.mdk "$ROOT"/test/wasm/fixtures/w_trmc_*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .mdk)"
  emit_or_fail llvm "$name" "$LLVM_ONE" "$f" || continue
  emit_or_fail wasm "$name" "$WASM_ONE" "$f" || continue
  extract_pair "$name"
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
} | tee "$OUT/SUMMARY"

exit $fail
