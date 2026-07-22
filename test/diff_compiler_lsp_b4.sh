#!/bin/sh
# test/diff_compiler_lsp_b4.sh — differential gate for the self-hosted LSP
# (Stage 4 Phase B.10, slice B.10.4: hover / completion / inlayHint).
#
# Drives BOTH servers with the same hand-framed Content-Length JSON-RPC requests
# and diffs the self-hosted responses against the OCaml reference (medaka lsp):
#
#   • initialize          — hoverProvider / completionProvider / inlayHintProvider
#                           are advertised alongside the B.10.3 providers.
#   • textDocument/hover          — identifier-at-cursor → typecheck env →
#                           a Markdown MarkupContent "```medaka\n<name> : <ty>\n```",
#                           byte-identical to OCaml (ppScheme == pp_scheme).
#   • textDocument/completion     — prefix-before-cursor → env names with that
#                           prefix → CompletionItem[] { label, kind:3, detail }.
#   • textDocument/inlayHint      — one hint per unsignatured top-level value
#                           binding: { position:(line,col-after-name),
#                           label:": <ty>", paddingLeft:true }.
#
# TYPE caveat (mirrors the other gates): ppScheme == pp_scheme, so the rendered
# types are byte-identical here EXCEPT for the documented unification-order
# divergence — these fixtures avoid that surface (single-clause, no instance
# resolution order), so the hover/completion/inlay labels match exactly.  The
# OCaml `initialize` REQUIRES a `capabilities` field in params (it rejects the
# bare `{}` the self-host tolerates), so we send one to both.
#
# Usage: sh test/diff_compiler_lsp_b4.sh
#   CAPTURE=1 sh test/diff_compiler_lsp_b4.sh   — re-mint all 5 b4_*.ndjson
#     goldens from the current native `medaka lsp` (#621).  Each is a raw
#     protocol dump with no independent cross-check, so this is tautological
#     (self vs self) by construction — the same "native canonical,
#     human-reviewed at bless time" precedent already used for
#     b4_compl_full.ndjson (re-minted by hand on 2026-06-27, see below).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# OCaml-free: drive the CANONICAL native LSP and diff vs committed goldens
# captured from the OCaml reference server (test/capture_goldens.sh).
MEDAKA="$ROOT/medaka"
GOLD="$ROOT/test/lsp_goldens"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
pass=0; fail=0
CAPTURE="${CAPTURE:-0}"

frame() {
  python3 - "$1" <<'PY'
import sys
b = sys.argv[1].encode("utf-8")
sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b))
sys.stdout.buffer.write(b)
PY
}

build_in() {
  > "$TMP/in.bin"
  for msg in "$@"; do frame "$msg" >> "$TMP/in.bin"; done
}

drive_self() {
  perl -e 'alarm 180; exec @ARGV' \
    env MEDAKA_ROOT="$ROOT" "$MEDAKA" lsp < "$TMP/in.bin" > "$TMP/self.bin" 2>/dev/null
  decode "$TMP/self.bin" > "$TMP/self.json"
}

# OCAML reference responses are committed goldens (captured by capture_goldens.sh
# while OCaml was trusted).  $1 = golden basename under $GOLD.
# NOTE: b4_compl_full.ndjson (empty-prefix completion = the whole prelude env) was
# RE-CAPTURED from the canonical native `medaka lsp` on 2026-06-27 — the OCaml-era
# snapshot predated prelude growth (Traversable's traverse/sequence, etc.) and OCaml
# is removed, so native is the reference for the full-env set.
load_golden() {
  if [ "$CAPTURE" = 1 ]; then
    cp "$TMP/self.json" "$GOLD/$1"
    printf 'CAPTURE %s\n' "$GOLD/$1" >&2
  fi
  cp "$GOLD/$1" "$TMP/ocaml.json"
}

decode() {
  python3 - "$1" <<'PY'
import sys, re, json, os
data = open(sys.argv[1], "rb").read()
def stab(o):
    if isinstance(o, dict): return {k: stab(v) for k, v in o.items()}
    if isinstance(o, list): return [stab(x) for x in o]
    if isinstance(o, str) and o.startswith("file://"):
        return "file:///" + os.path.basename(o)
    return o
parts = re.split(rb"Content-Length: \d+\r\n", data)
for p in parts:
    s = p.decode("utf-8", "replace")
    i = s.find("{")
    if i < 0:
        continue
    s = s[i:].strip()
    try:
        obj, _ = json.JSONDecoder().raw_decode(s)
    except Exception:
        continue
    print(json.dumps(stab(obj), sort_keys=True))
PY
}

check() {
  if [ "$2" = "0" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$1"; fi
}

# The shared fixture (== test/test_lsp.ml's completion/inlay fixtures, merged):
#   line 0: double x = x + x       (unsignatured value binding)
#   line 1: triple : Int -> Int    (explicit signature)
#   line 2: triple x = x * 3
#   line 3: result = double 5
#   line 4: export quad x = x * 4   (unsignatured, `export`-prefixed — NOTE
#     `public` alone is a DData-only modifier, `afterPublicFor` fatals on
#     anything else, so a value binding can only be `export`-prefixed, not
#     `public export`). #331/PR #856 review: every prior fixture here was
#     col-0-only, so it could not discriminate `inlayNamePos`'s real
#     name-Loc end column (11 — "export " is 7 chars, "quad" is 4 more) from
#     the `columnAfterName` heuristic it superseded, which would have scanned
#     the leading identifier run from char 0 and landed after "export"
#     (col 6) — the WRONG position. Hand-verified: 'export quad x = x * 4'.find('quad') == 7.
DOC_TEXT='double x = x + x\ntriple : Int -> Int\ntriple x = x * 3\nresult = double 5\nexport quad x = x * 4\n'
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
DIDOPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b4.mdk","languageId":"medaka","version":1,"text":"'"$DOC_TEXT"'"}}}'
EXIT='{"jsonrpc":"2.0","method":"exit","params":{}}'

# ── initialize: the three B.10.4 providers are advertised ───────────────────
build_in "$INIT" "$EXIT"
drive_self
python3 - "$TMP/self.json" <<'PY'
import sys, json
objs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
init = next((o for o in objs if o.get("id") == 1), None)
caps = (init or {}).get("result", {}).get("capabilities", {})
ok = (init is not None
      and caps.get("hoverProvider") is True
      and "completionProvider" in caps
      and caps.get("inlayHintProvider") is True)
sys.exit(0 if ok else 1)
PY
check "initialize advertises hover/completion/inlayHint" "$?"

# ── hover: identifier-at-cursor → markdown name:type, byte-identical ────────
HOVER='{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///b4.mdk"},"position":{"line":0,"character":2}}}'
build_in "$INIT" "$DIDOPEN" "$HOVER" "$EXIT"
drive_self; load_golden b4_hover.ndjson
python3 - "$TMP/self.json" "$TMP/ocaml.json" <<'PY'
import sys, json
def res(fn, i):
    for l in open(fn):
        if not l.strip(): continue
        o = json.loads(l)
        if o.get("id") == i: return o.get("result")
    return None
s = res(sys.argv[1], 2); o = res(sys.argv[2], 2)
# Both produce a Markdown MarkupContent; compare the contents object exactly.
ok = (s is not None and o is not None
      and s.get("contents") == o.get("contents")
      and s["contents"]["kind"] == "markdown"
      and "double" in s["contents"]["value"])
sys.exit(0 if ok else 1)
PY
check "hover double → markdown 'double : <ty>' == OCaml" "$?"

# ── hover off an identifier → null on both ─────────────────────────────────
HOVOFF='{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///b4.mdk"},"position":{"line":0,"character":9}}}'
build_in "$INIT" "$DIDOPEN" "$HOVOFF" "$EXIT"
drive_self; load_golden b4_hover_off.ndjson
python3 - "$TMP/self.json" "$TMP/ocaml.json" <<'PY'
import sys, json
def res(fn, i):
    for l in open(fn):
        if not l.strip(): continue
        o = json.loads(l)
        if o.get("id") == i: return o.get("result")
    return "MISSING"
s = res(sys.argv[1], 2); o = res(sys.argv[2], 2)
# col 9 of "double x = x + x" sits on '=' (off any identifier) → null both.
sys.exit(0 if (s is None and o is None) else 1)
PY
check "hover off-identifier → null == OCaml" "$?"

# ── completion: prefix-before-cursor filters env, == OCaml candidate set ────
# Line 3 "result = double 5": col 13 = after "result = doub" (prefix "doub").
COMPL='{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///b4.mdk"},"position":{"line":3,"character":13}}}'
build_in "$INIT" "$DIDOPEN" "$COMPL" "$EXIT"
drive_self; load_golden b4_compl.ndjson
python3 - "$TMP/self.json" "$TMP/ocaml.json" <<'PY'
import sys, json
def res(fn, i):
    for l in open(fn):
        if not l.strip(): continue
        o = json.loads(l)
        if o.get("id") == i: return o.get("result")
    return None
def items(r):
    if r is None: return None
    if isinstance(r, dict): r = r.get("items", [])
    return r
s = items(res(sys.argv[1], 3)); o = items(res(sys.argv[2], 3))
if s is None or o is None: sys.exit(1)
# Same candidate set, kinds, and details (label+kind+detail tuples).  Compare
# as a SET — the prefix filters to a small set here, but env-traversal order
# differs from OCaml (the documented divergence), so order is not asserted.
def norm(xs): return [(i.get("label"), i.get("kind"), i.get("detail")) for i in xs]
ss, oo = norm(s), norm(o)
ok = (sorted(ss) == sorted(oo)
      and any(l == "double" for (l, _, _) in ss)
      and all(l.startswith("doub") for (l, _, _) in ss))
sys.exit(0 if ok else 1)
PY
check "completion prefix 'doub' → label/kind/detail set == OCaml" "$?"

# ── completion: empty prefix → full env, self ⊇ {alpha,beta}, == OCaml set ──
DOC2='alpha = 1\nbeta = 2\n\n'
DIDOPEN2='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b4b.mdk","languageId":"medaka","version":1,"text":"'"$DOC2"'"}}}'
COMPL2='{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///b4b.mdk"},"position":{"line":2,"character":0}}}'
build_in "$INIT" "$DIDOPEN2" "$COMPL2" "$EXIT"
drive_self; load_golden b4_compl_full.ndjson
python3 - "$TMP/self.json" "$TMP/ocaml.json" <<'PY'
import sys, json
def res(fn, i):
    for l in open(fn):
        if not l.strip(): continue
        o = json.loads(l)
        if o.get("id") == i: return o.get("result")
    return None
def items(r):
    if r is None: return None
    if isinstance(r, dict): r = r.get("items", [])
    return r
s = items(res(sys.argv[1], 3)); o = items(res(sys.argv[2], 3))
if s is None or o is None: sys.exit(1)
def norm(xs): return [(i.get("label"), i.get("kind"), i.get("detail")) for i in xs]
ss, oo = norm(s), norm(o)
slabels = [l for (l, _, _) in ss]
# Empty-prefix returns the whole typecheck env: the candidate SET (labels, kinds,
# details) matches byte-for-byte, but the ORDER differs — the self-host env
# traversal order vs OCaml's assoc-list order is the documented divergence (same
# class as the unification-order caveat the sibling gates assert-around).  So
# compare as a set here, not as an ordered list.
ok = (sorted(ss) == sorted(oo) and "alpha" in slabels and "beta" in slabels)
sys.exit(0 if ok else 1)
PY
check "completion empty prefix → full env == OCaml (incl alpha,beta)" "$?"

# ── inlayHint: unsignatured top-level bindings get a ': <ty>' hint, == OCaml ─
INLAY='{"jsonrpc":"2.0","id":4,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///b4.mdk"},"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}}}}'
build_in "$INIT" "$DIDOPEN" "$INLAY" "$EXIT"
drive_self; load_golden b4_inlay.ndjson
python3 - "$TMP/self.json" "$TMP/ocaml.json" <<'PY'
import sys, json
def res(fn, i):
    for l in open(fn):
        if not l.strip(): continue
        o = json.loads(l)
        if o.get("id") == i: return o.get("result")
    return None
s = res(sys.argv[1], 4); o = res(sys.argv[2], 4)
if not isinstance(s, list) or not isinstance(o, list): sys.exit(1)
def norm(xs):
    return sorted([(h["position"]["line"], h["position"]["character"],
                    h["label"], h.get("paddingLeft")) for h in xs])
ss, oo = norm(s), norm(o)
# `triple` (line 1/2) has an explicit signature → no hint; double/result do.
hinted_lines = {l for (l, _, _, _) in ss}
# line 4 ("export quad x = x * 4") must hint at character 11 — the REAL
# end-of-name column ("export " is 7 chars + "quad" is 4 more) — not 6, which
# is where the superseded columnAfterName heuristic would have landed (it
# scans the leading identifier run from char 0, so it would stop right after
# "export"). This is the discriminating assertion #331/PR #856's review
# asked for: every OTHER fixture here is col-0-only and can't tell
# inlayNamePos apart from the heuristic it replaced.
quad_hints = [(l, c) for (l, c, lbl, _) in ss if l == 4]
ok = (ss == oo
      and 0 in hinted_lines        # double
      and 1 not in hinted_lines    # triple : Int -> Int (signature line)
      and 2 not in hinted_lines    # triple x = x * 3 (already-signatured name)
      and quad_hints == [(4, 11)])  # export quad — real name-end column
sys.exit(0 if ok else 1)
PY
check "inlayHint unsignatured-only, pos+label == OCaml" "$?"

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
