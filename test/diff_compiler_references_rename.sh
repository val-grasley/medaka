#!/bin/sh
# test/diff_compiler_references_rename.sh — golden JSON-RPC transcript gate for
# the `medaka_rename` MCP tool (#254 Stage 2: MCP tool + LSP
# `textDocument/rename`, both sharing `tools.lsp.renameResult`, which sits on
# the SAME Stage-0 `compiler/tools/refindex.mdk` index Stage 1's references use).
#
# Feeds a canned newline-delimited JSON-RPC request stream to `./medaka mcp` on
# stdin (same protocol/harness as test/diff_compiler_references_tool.sh — see
# that gate for the wire format), captures stdout, and diffs against a committed
# golden. Its OWN fixture corpus lives under test/references_fixtures/rename/
# (a NEW subdir — never touching test/references_fixtures/query/ or
# .../correctness/, whose goldens belong to other gates; see compiler/AGENTS.md's
# fixture-corpus trap).
#
# WHAT rename.jsonl PROVES (rename/{rdefs,rmain}.mdk)
# ---------------------------------------------------------------------------
# All three requests click inside rename/rmain.mdk. `foo` is a SIGNED top-level
# value in rdefs.mdk (`foo : Int` on one line, `foo = 10` on the next) that
# rmain.mdk imports SELECTIVELY (`import rdefs.{foo}`) — so a COMPLETE rename
# must rewrite the def, the `foo :` SIGNATURE, the `import …{foo}` CLAUSE, and
# every use. #254 Stage 2 extended refindex to index the signature-name and
# import-clause occurrences (previously un-indexed, which would have made a
# selective-import rename break the importing file); this fixture proves the
# emitted edit set now covers them.
#
# Rename TARGETS are PARAMETER-LESS top-level values (`foo`), per issue #913:
# clicking a function name that HAS parameters resolves to the WRONG binder (a
# param's local-binder def Loc collides with the function name's own Loc), so a
# rename target must be parameter-less.
#
#   Q1 (id 2): rename `foo` at rmain.mdk (0-based line 9, col 10 — the first
#     `foo` in `doubled = foo + foo`) to `bar`. Proves a correct, COMPLETE
#     CROSS-FILE `WorkspaceEdit`: 6 edits grouped by uri, sorted (path, then
#     line, then char), each `newText:"bar"`. Hand-verified ranges (0-based
#     line:char):
#       rdefs.mdk  8:7-10  — the `foo :` SIGNATURE name (`export foo : Int`).
#       rdefs.mdk  9:0-3   — the def site `foo = 10` (F6: def ALWAYS included).
#       rdefs.mdk 12:7-10  — `also = foo + 1`, `foo` at chars 7..10.
#       rmain.mdk  6:14-17 — the `import rdefs.{foo}` CLAUSE name.
#       rmain.mdk  9:10-13 — first `foo` in `doubled = foo + foo`.
#       rmain.mdk  9:16-19 — second `foo`.
#     Applying it yields rdefs `foo :`→`bar :`, `foo = 10`→`bar = 10`,
#     `also = bar + 1`, and rmain `import rdefs.{bar}` / `doubled = bar + bar` —
#     a program that STILL COMPILES (sig, import clause, def, and uses all moved
#     together). The Stage-1 references gate proves the same 6 occurrences.
#
#   Q2 (id 3): rename the prelude `not` at rmain.mdk (line 12, col 7 —
#     `flag = not True`) to `whatever`. Proves F3(a) OUT-OF-PROJECT REFUSE:
#     `not` is defined in the core prelude (outside the project root), so
#     `defOf` finds no project def site → structured refusal
#     `{"refused":true,"reason":"cannot rename a symbol defined outside the
#     project"}`, NEVER a wrong/silent edit. `isError` is true.
#
#   Q3 (id 4): rename `foo` (same click as Q1) to `also` — a name that ALREADY
#     exists as a top-level value in rdefs.mdk. Proves F3(b) CAPTURE/COLLISION
#     REFUSE: the coarse `allDefKeys` scan finds a same-namespace binder named
#     `also` → refusal. Over-refusal is acceptable (F3 conservative spirit); a
#     silent capture is not.
#
# All (line, col) pairs were hand-derived from the fixture source by counting
# characters (0-based, LSP-style) — re-derive the same way if the fixtures
# change. To regenerate the golden:
#   CAPTURE=1 sh test/diff_compiler_references_rename.sh
# (diff the result before committing, as with any CAPTURE=1 gate.)
#
# Usage: sh test/diff_compiler_references_rename.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/references_fixtures/rename"

[ -x "$MEDAKA" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

# Fixed cwd = repo root, exactly like diff_compiler_references_tool.sh, so a
# fixture's repo-relative `file` argument resolves the same regardless of where
# this gate was invoked from, and no `medaka.toml` sits above the fixture dir,
# so `findProjectRoot` falls back to the fixture dir itself as the project root.
cd "$ROOT" || { echo "FAIL: cannot cd to $ROOT"; exit 1; }

pass=0; fail=0

for req in "$FIXDIR"/*.jsonl; do
  [ -f "$req" ] || continue
  name="$(basename "$req" .jsonl)"
  golden="$FIXDIR/$name.golden"

  tmpout="$(mktemp)"
  perl -e 'alarm 30; exec @ARGV' "$MEDAKA" mcp < "$req" > "$tmpout" 2>/dev/null
  rc=$?
  self_out="$(cat "$tmpout")"
  rm -f "$tmpout"

  if [ "${CAPTURE:-0}" = "1" ]; then
    printf '%s\n' "$self_out" > "$golden"
    printf 'CAPTURE %s\n' "$golden"
    continue
  fi

  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (missing golden %s)\n' "$name" "$golden"; continue
  fi
  want_out="$(cat "$golden")"

  # Exit code checked too — a tool that emits correct response lines and THEN
  # crashes before EOF must not read as a pass (same as the references gate).
  if [ "$rc" -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %s: medaka mcp exited %d\n' "$name" "$rc"
    printf '  self:   %s\n' "$self_out"
  elif [ "$self_out" = "$want_out" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  self:   %s\n' "$self_out"
    printf '  golden: %s\n' "$want_out"
  fi
done

if [ "${CAPTURE:-0}" = "1" ]; then
  exit 0
fi

echo ""
total=$((pass+fail))
printf 'checked %d fixture(s): %d ok, %d failing\n' "$total" "$pass" "$fail"

# A gate that silently compares zero fixtures must FAIL, not report green.
if [ "$total" -eq 0 ]; then
  echo "FAIL: no fixtures found under $FIXDIR (checked 0 — treating as failure)"
  exit 1
fi

[ "$fail" -eq 0 ]
