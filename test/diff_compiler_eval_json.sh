#!/bin/sh
# Differential validation for `medaka run --json` (RUNTIME-DIAGNOSTIC-CHANNEL-
# DESIGN.md Fork C, Stage 4): each of the 6 error_quality_fixtures/eval/*.mdk
# fixtures must emit a JSON diagnostic envelope through the SAME
# `driver.diagnostics.cjAllToJson` serializer `medaka check --json` uses —
# {"files":[{"file":...,"diagnostics":[{code,kind,message,range,severity,
# source}]}]} — byte-identical in shape, just carrying the runtime E-* code.
#
# This drives the freshly-built ./medaka CLI directly (the --json flag lives in
# medaka_cli.mdk, not in any test/bin/* probe oracle), mirroring how
# test/error_quality_fixtures/capture.sh already drives ./medaka for the plain-
# text goldens. Path-stability: absolute "$ROOT/" prefixes are stripped to
# "ROOT/" (same convention as capture.sh) so goldens are relocatable.
#
# Usage:
#   sh test/diff_compiler_eval_json.sh          # compare against goldens
#   CAPTURE=1 sh test/diff_compiler_eval_json.sh # (re)capture goldens
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/medaka"
DIR="$ROOT/test/error_quality_fixtures/eval"

[ -x "$BIN" ] || { echo "build first: make medaka (missing $BIN)"; exit 2; }
. "$ROOT/test/lib_stale_warning.sh"

strip_paths() { sed "s|$ROOT/|ROOT/|g"; }

capture_mode="${CAPTURE:-0}"
pass=0; fail=0

for f in "$DIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "${f%.mdk}")"
  rel="test/error_quality_fixtures/eval/$(basename "$f")"
  golden="$DIR/$name.json.out"

  # `panic` (the noreturn C-abort `runtimePanic` hands the JSON string to)
  # writes to STDERR, not stdout — redirect stderr into the pipe and discard
  # stdout, which is always empty on this path.
  actual="$(cd "$ROOT" && "$BIN" run --json "$rel" 2>&1 1>/dev/null | strip_paths)"

  if [ "$capture_mode" = "1" ]; then
    printf '%s\n' "$actual" > "$golden"
    printf 'captured %s\n' "$name"
  else
    if [ ! -f "$golden" ]; then
      fail=$((fail + 1)); printf 'FAIL %s (missing golden %s)\n' "$name" "$golden"
      continue
    fi
    golden_out="$(cat "$golden")"
    cls="$(mdk_classify_diff "$actual" "$golden_out")"
    case "$cls" in
      MATCH) pass=$((pass + 1)); printf 'ok   %s\n' "$name" ;;
      STALE_ONLY) fail=$((fail + 1)); mdk_stale_fail_line "$name" ;;
      *)
        fail=$((fail + 1)); printf 'FAIL %s\n' "$name"
        [ "$cls" = "STALE_PLUS_DIFF" ] && mdk_stale_note
        printf '  actual: %s\n' "$actual"
        printf '  golden: %s\n' "$golden_out"
        ;;
    esac
  fi
done

if [ "$capture_mode" = "1" ]; then
  exit 0
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
