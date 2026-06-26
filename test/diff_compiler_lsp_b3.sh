#!/bin/sh
# test/diff_compiler_lsp_b3.sh — differential gate for the self-hosted LSP
# (Stage 4 Phase B.10, slice B.10.3: formatting / documentSymbol / definition /
# documentHighlight).
#
# Drives BOTH servers with the same hand-framed Content-Length JSON-RPC requests
# and diffs the self-hosted responses against the OCaml reference:
#
#   • initialize          — the four B.10.3 providers are advertised
#                           (documentFormatting/documentSymbol/definition/
#                           documentHighlight) alongside textDocumentSync.
#   • textDocument/formatting     — a single TextEdit whose newText equals the
#                           `medaka fmt` oracle (the OCaml formatter), spanning
#                           the whole document.  When already-formatted, [].
#   • textDocument/documentSymbol — name + SymbolKind + start-line parity per
#                           decl (plus children), vs the OCaml outline.
#   • textDocument/definition     — identifier-at-cursor → defining decl's
#                           start-line + uri, vs OCaml.
#   • textDocument/documentHighlight — identifier occurrence ranges (full
#                           start..end), vs OCaml (textual, so byte-identical).
#
# DECL-vs-EXPR caveat (asserted at decl granularity, like test/test_lsp.ml's
# own fixtures, which check `range.start.line`): the compiler AST is
# location-stripped of COLUMNS and its per-decl END line is the last *content*
# token (parser DeclPos), whereas the OCaml decl `loc.end_line` spans to the
# trailing-blank / next-decl boundary.  So symbol/definition START lines, names,
# kinds, and the highlight FULL range match byte-for-byte; decl END lines do
# NOT (and are not diffed).  The OCaml symbols also carry a `detail` (pp_ty)
# the compiler AST cannot produce — additive, not diffed.
#
# Usage: sh test/diff_compiler_lsp_b3.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# OCaml-free: drive the CANONICAL native LSP and diff vs committed goldens
# captured from the OCaml reference server (test/capture_goldens.sh, trusted at
# capture time).  See test/lsp_goldens/.
MEDAKA="$ROOT/medaka"
GOLD="$ROOT/test/lsp_goldens"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
pass=0; fail=0

frame() {
  python3 - "$1" <<'PY'
import sys
b = sys.argv[1].encode("utf-8")
sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b))
sys.stdout.buffer.write(b)
PY
}

# Build the framed request stream from the message args into $TMP/in.bin.
build_in() {
  > "$TMP/in.bin"
  for msg in "$@"; do frame "$msg" >> "$TMP/in.bin"; done
}

# Run the canonical NATIVE server; decode framed responses to NDJSON in $TMP/self.json.
drive_self() {
  perl -e 'alarm 180; exec @ARGV' \
    env MEDAKA_ROOT="$ROOT" "$MEDAKA" lsp < "$TMP/in.bin" > "$TMP/self.bin" 2>/dev/null
  decode "$TMP/self.bin" > "$TMP/self.json"
}

# OCAML reference responses are committed goldens (captured by capture_goldens.sh
# while OCaml was trusted).  $1 = golden basename under $GOLD.
load_golden() {
  cp "$GOLD/$1" "$TMP/ocaml.json"
}

decode() {
  python3 - "$1" <<'PY'
import sys, re, json, os
data = open(sys.argv[1], "rb").read()
# Split on the Content-Length header line; strip up to the first '{' per chunk.
# Stabilize file:// URIs to a basename so goldens carry no build path; sort keys
# to match the captured goldens' canonicalization.
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

# A valid OCaml InitializeParams requires `capabilities`; the compiler server
# ignores extras, so one stream drives both.
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"processId":null,"rootUri":null}}'
INITED='{"jsonrpc":"2.0","method":"initialized","params":{}}'

# ── capabilities ────────────────────────────────────────────────────────────
build_in "$INIT" '{"jsonrpc":"2.0","method":"exit","params":{}}'
drive_self
python3 - "$TMP/self.json" <<'PY'
import sys, json
objs=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
init=next((o for o in objs if o.get("id")==1), None)
caps=(init or {}).get("result",{}).get("capabilities",{})
ok=(init is not None
    and caps.get("textDocumentSync")==1
    and caps.get("documentFormattingProvider") is True
    and caps.get("documentSymbolProvider") is True
    and caps.get("definitionProvider") is True
    and caps.get("documentHighlightProvider") is True)
sys.exit(0 if ok else 1)
PY
check "initialize advertises the four B.10.3 providers" "$?"

# ── fixture: a file with a record, a data decl, and a function ──────────────
SRC='record Point\n  x : Int\n  y : Int\n\ndata Shape = Circle Int | Square Int\n\narea s = match s\n  Circle r => r * r\n  Square w => w * w\n'
# JSON-string-escaped form (the \n become \\n inside the JSON message).
SRC_JSON='record Point\n  x : Int\n  y : Int\n\ndata Shape = Circle Int | Square Int\n\narea s = match s\n  Circle r => r * r\n  Square w => w * w\n'
printf "$SRC" > "$TMP/sym.mdk"
DIDOPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///s.mdk","languageId":"medaka","version":1,"text":"'"$SRC_JSON"'"}}}'
SYM='{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///s.mdk"}}}'
DEF='{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///s.mdk"},"position":{"line":6,"character":0}}}'
HL='{"jsonrpc":"2.0","id":4,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///s.mdk"},"position":{"line":6,"character":0}}}'
SHUT='{"jsonrpc":"2.0","id":9,"method":"shutdown","params":{}}'
EXIT='{"jsonrpc":"2.0","method":"exit","params":{}}'

build_in "$INIT" "$INITED" "$DIDOPEN" "$SYM" "$DEF" "$HL" "$SHUT" "$EXIT"
drive_self
load_golden b3_sym_def_hl.ndjson

# documentSymbol: name + kind + start-line parity (recursively, incl children).
python3 - "$TMP/self.json" "$TMP/ocaml.json" <<'PY'
import sys, json
def load(p): return [json.loads(l) for l in open(p) if l.strip()]
def res(objs, i):
    o=next((o for o in objs if o.get("id")==i), None)
    return (o or {}).get("result")
def skel(syms):
    # (name, kind, start_line) tuples with children, ignoring detail + end pos.
    out=[]
    for s in (syms or []):
        st=s["range"]["start"]["line"]
        out.append((s["name"], s["kind"], st, skel(s.get("children"))))
    return out
ss=res(load(sys.argv[1]),2); os=res(load(sys.argv[2]),2)
ok = skel(ss)==skel(os) and skel(ss)!=[]
if not ok:
    sys.stderr.write("self=%s\noracle=%s\n"%(skel(ss),skel(os)))
sys.exit(0 if ok else 1)
PY
check "documentSymbol name+kind+start-line parity (incl. children) vs OCaml" "$?"

# definition: start-line + uri parity (end line differs by decl-vs-expr rule).
python3 - "$TMP/self.json" "$TMP/ocaml.json" <<'PY'
import sys, json
def load(p): return [json.loads(l) for l in open(p) if l.strip()]
def res(objs,i):
    o=next((o for o in objs if o.get("id")==i),None); return (o or {}).get("result")
def loc0(r):
    if not r: return None
    e=r[0]; return (e.get("uri"), e["range"]["start"]["line"])
s=loc0(res(load(sys.argv[1]),3)); o=loc0(res(load(sys.argv[2]),3))
ok=(s==o and s is not None and s[1]==6 and s[0]=="file:///s.mdk")
if not ok: sys.stderr.write("self=%s oracle=%s\n"%(s,o))
sys.exit(0 if ok else 1)
PY
check "definition (uri + start-line) parity vs OCaml; lands on area decl" "$?"

# documentHighlight: textual occurrence ranges match byte-for-byte (no AST).
python3 - "$TMP/self.json" "$TMP/ocaml.json" <<'PY'
import sys, json
def load(p): return [json.loads(l) for l in open(p) if l.strip()]
def res(objs,i):
    o=next((o for o in objs if o.get("id")==i),None); return (o or {}).get("result")
def ranges(r): return sorted((h["range"]["start"]["line"],h["range"]["start"]["character"],
                              h["range"]["end"]["line"],h["range"]["end"]["character"]) for h in (r or []))
s=ranges(res(load(sys.argv[1]),4)); o=ranges(res(load(sys.argv[2]),4))
# `area` occurs once (the decl); both must agree on the full range.
ok=(s==o and s==[(6,0,6,4)])
if not ok: sys.stderr.write("self=%s oracle=%s\n"%(s,o))
sys.exit(0 if ok else 1)
PY
check "documentHighlight full-range parity vs OCaml (textual, byte-identical)" "$?"

# ── formatting: newText equals the `medaka fmt` oracle ──────────────────────
# Unformatted fixture (extra spaces + blank lines that fmt collapses).
USRC='main   =   println    "hi"\n\n\n'
USRC_JSON='main   =   println    \"hi\"\n\n\n'
printf "$USRC" > "$TMP/unfmt.mdk"
ORACLE_FMT="$(cat "$GOLD/b3_fmt.txt")"
FMT='{"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///u.mdk"}}}'
DIDOPEN_U='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///u.mdk","languageId":"medaka","version":1,"text":"'"$USRC_JSON"'"}}}'
build_in "$INIT" "$INITED" "$DIDOPEN_U" "$FMT" "$SHUT" "$EXIT"
drive_self
printf '%s' "$ORACLE_FMT" > "$TMP/oracle_fmt.txt"
python3 - "$TMP/self.json" "$TMP/oracle_fmt.txt" <<'PY'
import sys, json
objs=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
o=next((o for o in objs if o.get("id")==2), None)
edits=(o or {}).get("result")
oracle=open(sys.argv[2]).read()
# The oracle (`medaka fmt`) prints the formatted doc; the LSP returns a single
# whole-document TextEdit carrying the same text.
if not edits:
    sys.exit(1)
nt=edits[0]["newText"]
# `medaka fmt` to stdout is captured without a guaranteed trailing newline via
# $(...) (shell strips trailing newlines), so compare modulo a trailing '\n'.
ok=(len(edits)==1 and nt.rstrip("\n")==oracle.rstrip("\n")
    and edits[0]["range"]["start"]=={"line":0,"character":0})
if not ok: sys.stderr.write("newText=%r oracle=%r\n"%(nt,oracle))
sys.exit(0 if ok else 1)
PY
check "formatting newText == medaka fmt oracle (one whole-doc TextEdit)" "$?"

# already-formatted document → no edits ([]).
FSRC='main = println "hi"\n'
FSRC_JSON='main = println \"hi\"\n'
printf "$FSRC" > "$TMP/fmt2.mdk"
DIDOPEN_F='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///f.mdk","languageId":"medaka","version":1,"text":"'"$FSRC_JSON"'"}}}'
FMT_F='{"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///f.mdk"}}}'
build_in "$INIT" "$INITED" "$DIDOPEN_F" "$FMT_F" "$SHUT" "$EXIT"
drive_self
python3 - "$TMP/self.json" <<'PY'
import sys, json
objs=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
o=next((o for o in objs if o.get("id")==2), None)
sys.exit(0 if (o or {}).get("result")==[] else 1)
PY
check "formatting already-formatted doc → [] (no edits)" "$?"

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
