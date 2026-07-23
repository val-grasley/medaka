#!/bin/sh
# test/diff_compiler_references_tool.sh — golden JSON-RPC transcript gate for
# the `medaka_references` MCP tool (#254 Stage 1: MCP tool + LSP
# `textDocument/references`, both sharing `tools.lsp.referencesResult`, which
# in turn sits on Stage 0's `compiler/tools/refindex.mdk` index).
#
# Feeds a canned newline-delimited JSON-RPC request stream to `./medaka mcp`
# on stdin (same protocol/harness shape as test/diff_compiler_mcp.sh — see
# that gate for the wire format), captures stdout, and diffs it against a
# committed golden.
#
# FIXTURE-DIR LOOP (same extensibility idiom as diff_compiler_mcp.sh): each
# fixture is a pair under test/references_fixtures/query/:
#   <name>.jsonl   — the request stream (one JSON-RPC message per line)
#   <name>.golden  — the exact expected stdout
# A NEW subdir, never touching test/references_fixtures/correctness/ (that
# corpus belongs to diff_compiler_references_correctness.sh's Stage-0 dump —
# a shared-corpus edit there would perturb ITS golden instead of adding one
# here; see compiler/AGENTS.md's fixture-corpus trap).
#
# WHAT THE cross_file.jsonl FIXTURE PROVES (query/{defs,main,other,reexport}.mdk)
# ---------------------------------------------------------------------------
# All three queries click inside query/main.mdk — the loader walks DOWN from
# the clicked file's own imports, so main.mdk (which imports defs/reexport/
# other) is the query entry that pulls every fixture file into ONE project
# graph; clicking inside a leaf module like defs.mdk would only load that
# leaf (loadProgramFilesLocatedCached follows import edges, not reverse-deps).
#
#   Q1 (id 2): click on `helper` in main.mdk's `usesDirect = helper 3 + shared`
#     (line 15 0-based, col 13) — includeDeclaration defaults true. Proves
#     CROSS-FILE (defs.mdk's own internal use), ALIAS IMPORT (`D.helper` on
#     line 18), and RE-EXPORT CHAIN (`rHelper`, imported from `reexport.mdk`,
#     whose own `export import defs.{helper}` re-exports defs' true origin —
#     line 21) all collapse onto the SAME BinderKey as the def in defs.mdk.
#     Expect 5 locations: defs.mdk def (6:0-6 1-based) + defs.mdk use
#     (12:25-31) + main.mdk uses at 16:13-19 (the click site) and 22:15-22
#     (rHelper — a plain EVar, so its own precise ELoc span). The 5th, for
#     `D.helper` (main.mdk line 19), is a hand-verified SURPRISE: refindex's
#     alias-qualified-field-access walk (`walkFieldAccess`'s alias branch,
#     compiler/tools/refindex.mdk) records the reference at whatever `curLoc`
#     was last set by an ENCLOSING atom's `ELoc` — neither `EApp` nor
#     `EFieldAccess` refresh it — so for a body that's `D.helper 4` with no
#     other located atom ahead of it, that's still the WHOLE DECL's own name
#     Loc from `walkDeclBody`'s initial `loc`, i.e. `usesAlias` itself
#     (19:0-9, NOT a span touching "D.helper" at all). The BinderKey is still
#     exactly right (this use groups under the SAME key as every other
#     `helper` hit below) — only the reported RANGE is imprecise for this one
#     shape. Verified against `compiler/tools/refindex.mdk`'s source, not
#     guessed; NOT a bug in this stage's wiring (refindex.mdk is Stage 0's
#     substrate, out of this stage's scope) — flagged as a residual in the
#     handoff report.
#
#   Q2 (id 3): click on the LOCAL `shared` inside `topG`'s body (line 12
#     0-based, col 2 — `  shared + shared`), includeDeclaration=false. Proves
#     SHADOWING: `let shared = x + 1` in `topG` mints a DISTINCT `local`
#     BinderKey from the imported top-level `defs.shared`, so this query
#     returns ONLY the 2 in-function uses (main.mdk 1-based line 13, cols
#     2-8 and 11-17) — never defs.mdk's `shared`, never `usesDirect`'s
#     top-level use on line 16.
#
#   Q3 (id 4): click on the top-level `shared` in `usesDirect` (SAME line as
#     Q1, col 24), includeDeclaration=true. Proves SAME-NAME-IN-TWO-MODULES
#     non-contamination: `other.mdk` defines its OWN `shared` (loaded into
#     the SAME project graph via main's `import other as O`) — a regression
#     that keyed by spelling instead of (module, namespace, name) would pull
#     other.mdk's 2 `shared` occurrences into this result. Expect exactly 3
#     locations: defs.mdk def (9:0-6) + defs.mdk use (12:16-22) + main.mdk's
#     own use (16:24-30, the click site) — other.mdk's `shared` and topG's
#     LOCAL `shared` (Q2) are BOTH absent.
#
# All (line, col) pairs above were hand-derived from the fixture source with
# a Python regex scan (word-boundary `\b(helper|shared|rHelper)\b`), not
# guessed — re-derive with the same scan if the fixtures ever change:
#   python3 -c "$(cat <<'PY'
# import re
# for fn in ('defs.mdk','main.mdk','other.mdk'):
#     for i,l in enumerate(open(fn),1):
#         for m in re.finditer(r'\b(helper|shared|rHelper)\b', l.rstrip()):
#             print(fn, i, m.start(), m.end(), m.group())
# PY
# )"
#
# To regenerate the golden: CAPTURE=1 sh test/diff_compiler_references_tool.sh
#
# Usage: sh test/diff_compiler_references_tool.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/references_fixtures/query"

[ -x "$MEDAKA" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

# Fixed cwd = repo root, exactly like diff_compiler_mcp.sh, so a fixture's
# repo-relative `file` argument (e.g. test/references_fixtures/query/main.mdk)
# resolves the same way regardless of where this gate was invoked from, and
# no `medaka.toml` sits above the fixture dir, so `findProjectRoot` falls
# back to the fixture dir itself as the project root (same as the Stage-0
# correctness gate's `roots=[FIXDIR]`).
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

  # Exit code checked too (not just output match) — a tool that emits correct
  # response lines and THEN crashes before EOF must not read as a pass (same
  # rationale as diff_compiler_mcp.sh).
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
