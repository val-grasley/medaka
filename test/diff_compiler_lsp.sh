#!/bin/sh
# test/diff_compiler_lsp.sh — differential gate for the self-hosted LSP
# (Stage 4 Phase B.10, slices B.10.0 + B.10.1).
#
# Drives compiler/entries/lsp_main.mdk with hand-framed Content-Length JSON-RPC requests
# on stdin and checks the framed JSON responses against the OCaml reference:
#
#   • initialize          — the response is a well-formed JSON-RPC result whose
#                           capabilities advertise textDocumentSync (B.10 only
#                           implements sync+diagnostics; hover/completion/etc.
#                           are later slices and are NOT advertised here, so we
#                           assert the known B.10 shape rather than diffing the
#                           full OCaml capability set, which includes providers
#                           B.10 does not implement).
#   • didOpen (clean)     — publishDiagnostics with an empty diagnostics array,
#                           matching `medaka check --json` (no diagnostics).
#   • didOpen (type err)  — publishDiagnostics carrying one Error diagnostic
#                           (severity 1, source "medaka"), matching the
#                           single-diagnostic shape of `check --json`.  B.10.2b:
#                           the diagnostic now carries an EXPR-LEVEL range from
#                           the ELoc substrate — this gate asserts its START
#                           position matches the OCaml LSP's expr range exactly.
#
# Message TEXT is intentionally NOT diffed (unification order differs from the
# oracle — the documented compiler limitation, cf. diff_compiler_diagnostics.sh).
#
# RANGE (B.10.2b): the start position is asserted to match the OCaml LSP's
# expr-level range exactly.  The END position is an APPROXIMATION: the compiler
# parser derives a token span from token START offsets (`locOfSpan`), so a
# single-token expr yields an empty span (end == start) where OCaml's `$endpos`
# reaches the token's end.  True end positions need token lengths threaded
# through the lexer's layout pass (a cross-cutting lexer change deferred here);
# the start — the position editors anchor a squiggle at — is exact.
#
# Usage: sh test/diff_compiler_lsp.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# OCaml-free: drive the CANONICAL native LSP (the shipped binary, same one Cursor
# uses) and diff vs committed goldens captured from the OCaml `check --json`
# oracle (test/capture_goldens.sh, OCaml trusted at capture time).
MEDAKA="$ROOT/medaka"
GOLD="$ROOT/test/lsp_goldens"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
pass=0; fail=0

# Frame a JSON string as a Content-Length JSON-RPC packet (byte-accurate length).
frame() {
  python3 - "$1" <<'PY'
import sys
b = sys.argv[1].encode("utf-8")
sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b))
sys.stdout.buffer.write(b)
PY
}

# Run the compiler LSP over a framed stdin stream (built from the JSON messages
# passed as args), capture stdout, and split it into one JSON object per frame.
# Writes the decoded JSON objects (one per line) to $TMP/out.json.
drive_lsp() {
  : > "$TMP/in.bin"
  for msg in "$@"; do frame "$msg" >> "$TMP/in.bin"; done
  perl -e 'alarm 180; exec @ARGV' \
    env MEDAKA_ROOT="$ROOT" "$MEDAKA" lsp < "$TMP/in.bin" > "$TMP/out.bin" 2>/dev/null
  python3 - "$TMP/out.bin" > "$TMP/out.json" <<'PY'
import sys, re, json
data = open(sys.argv[1], "rb").read()
# Split into frames on the Content-Length header; emit each body as compact JSON.
parts = re.split(rb"Content-Length: \d+\r\n\r\n", data)
for p in parts:
    p = p.strip()
    if not p:
        continue
    # A frame body is exactly one JSON object; trailing bytes belong to the next
    # frame's header which the split already consumed, so decode greedily.
    dec = json.JSONDecoder()
    idx = 0
    s = p.decode("utf-8")
    while idx < len(s):
        s2 = s[idx:].lstrip()
        if not s2:
            break
        try:
            obj, end = dec.raw_decode(s2)
        except ValueError:
            break
        # Skip non-object tokens (the native CLI prints a trailing Unit `0` after
        # the framed responses; LSP messages are always JSON objects).
        if isinstance(obj, dict):
            print(json.dumps(obj))
        idx += len(s[idx:]) - len(s2) + end
PY
}

check() { # desc, condition (already evaluated to 0/1 via test)
  if [ "$2" = "0" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$1"; fi
}

# ── 1. initialize handshake ─────────────────────────────────────────────────
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" <<'PY'
import sys, json
objs = [json.loads(l) for l in open(sys.argv[0+1]) if l.strip()]
init = next((o for o in objs if o.get("id") == 1), None)
ok = (init is not None
      and init.get("jsonrpc") == "2.0"
      and "result" in init
      and "textDocumentSync" in init["result"]["capabilities"]
      and init["result"]["serverInfo"]["name"] == "medaka-lsp")
sys.exit(0 if ok else 1)
PY
check "initialize → jsonrpc result with textDocumentSync capability" "$?"

# ── 2. didOpen a CLEAN file → empty diagnostics (matches check --json) ───────
CLEAN='main = println "hi"\n'
printf 'main = println "hi"\n' > "$TMP/clean.mdk"
ORACLE_CLEAN="$(cat "$GOLD/check_clean.json")"
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///clean.mdk","text":"main = println \"hi\"\n"}}}' \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" "$ORACLE_CLEAN" <<'PY'
import sys, json
objs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pub = next((o for o in objs if o.get("method") == "textDocument/publishDiagnostics"), None)
oracle = json.loads(sys.argv[2])
oracle_diags = oracle["files"][0]["diagnostics"] if oracle.get("files") else []
ok = (pub is not None
      and pub["params"]["diagnostics"] == []
      and oracle_diags == [])
sys.exit(0 if ok else 1)
PY
check "didOpen clean → publishDiagnostics [] (== check --json)" "$?"

# ── 3. didOpen a TYPE-ERROR file → one Error diagnostic ─────────────────────
printf 'main = 1 + "x"\n' > "$TMP/err.mdk"
ORACLE_ERR="$(cat "$GOLD/check_err.json")"
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///err.mdk","text":"main = 1 + \"x\"\n"}}}' \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" "$ORACLE_ERR" <<'PY'
import sys, json
objs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pub = next((o for o in objs if o.get("method") == "textDocument/publishDiagnostics"), None)
oracle = json.loads(sys.argv[2])
od = oracle["files"][0]["diagnostics"]
if pub is None:
    sys.exit(1)
sd = pub["params"]["diagnostics"]
# Structural parity: same count, same first-diagnostic severity + source.
# (message text diverges by design — unification order — see header.)
struct_ok = (len(sd) == len(od) == 1
      and sd[0]["severity"] == od[0]["severity"] == 1
      and sd[0]["source"] == od[0]["source"] == "medaka"
      and "range" in sd[0] and "message" in sd[0])
# B.10.2b: expr-level RANGE.  The START position must match the OCaml LSP's
# expr-level range exactly (the ELoc substrate captures the same span).  The END
# position is an approximation (token-START-derived span → empty span); we assert
# only that it is well-formed and does not precede the start, and that it is on
# the same line as OCaml's end (documented $endpos gap — see header).
sr, oj = sd[0]["range"], od[0]["range"]
start_ok = (sr["start"] == oj["start"])
end_ok = (sr["end"] == oj["end"])
if not start_ok:
    sys.stderr.write("RANGE START mismatch: self=%s oracle=%s\n" % (sr["start"], oj["start"]))
if not end_ok:
    sys.stderr.write("RANGE END mismatch: self=%s oracle=%s\n" % (sr["end"], oj["end"]))
ok = struct_ok and start_ok and end_ok
sys.exit(0 if ok else 1)
PY
check "didOpen type-error → one Error diagnostic; expr-range START and END == check --json" "$?"

# ── 4. didChange replaces a clean buffer with an error one ──────────────────
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///d.mdk","text":"main = println \"hi\"\n"}}}' \
  '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///d.mdk"},"contentChanges":[{"text":"main = 1 + \"x\"\n"}]}}' \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" <<'PY'
import sys, json
objs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pubs = [o for o in objs if o.get("method") == "textDocument/publishDiagnostics"]
# Two publishes: didOpen (clean → []) then didChange (error → 1 diagnostic).
ok = (len(pubs) == 2
      and pubs[0]["params"]["diagnostics"] == []
      and len(pubs[1]["params"]["diagnostics"]) == 1
      and pubs[1]["params"]["diagnostics"][0]["severity"] == 1)
sys.exit(0 if ok else 1)
PY
check "didChange clean→error → republish with one diagnostic" "$?"

# ── 5. B.10.5: project-wide didOpen → one publish PER graph file ─────────────
# A multi-file project (entry imports a clean sibling + a sibling with a type
# error).  Opening the entry triggers analyzeProject: one publishDiagnostics per
# file in the import graph, the bad file carrying its diagnostic WITHOUT blanking
# the clean files (the "bad import doesn't sink the batch" property).  The entry's
# absolute file:// uri drives project_dir = its directory (the loader root); the
# read override is only needed for the entry (its siblings are read from disk).
PROJ="$TMP/proj"
mkdir -p "$PROJ"
printf 'export double : Int -> Int\ndouble x = x + x\n' > "$PROJ/lib_clean.mdk"
printf 'import lib_clean.{double}\n\nexport oops : Int\noops = double "no"\n' > "$PROJ/lib_bad.mdk"
printf 'import lib_clean.{double}\nimport lib_bad.{oops}\n\nmain = println (double 21)\n' > "$PROJ/main_app.mdk"
ENTRY_TXT="$(python3 -c 'import json,sys;print(json.dumps(open(sys.argv[1]).read()))' "$PROJ/main_app.mdk")"
# Oracle: medaka check --json over the same entry (the real analyze_project).
ORACLE_PROJ="$(cat "$GOLD/check_project.json")"
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://$PROJ/main_app.mdk\",\"text\":$ENTRY_TXT}}}" \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" "$ORACLE_PROJ" <<'PY'
import sys, json, os
objs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pubs = [o for o in objs if o.get("method") == "textDocument/publishDiagnostics"]
# compiler: {basename: [(sev, msg, start)]}
self = {}
for p in pubs:
    base = os.path.basename(p["params"]["uri"])
    self[base] = [(d["severity"], d["message"], (d["range"]["start"]["line"], d["range"]["start"]["character"]))
                  for d in p["params"]["diagnostics"]]
# oracle: same shape from analyze_project's files array
oracle = {}
oj = json.loads(sys.argv[2])
for f in oj["files"]:
    base = os.path.basename(f["file"])
    oracle[base] = [(d["severity"], d["message"], (d["range"]["start"]["line"], d["range"]["start"]["character"]))
                    for d in f["diagnostics"]]
# One publish per graph file; same file set.
if set(self) != set(oracle):
    sys.stderr.write("FILE SET: self=%s oracle=%s\n" % (sorted(self), sorted(oracle)))
    sys.exit(1)
ok = True
for base in oracle:
    o = sorted(oracle[base]); s = sorted(self[base])
    # severity + start must match exactly; message matches here (stable type msg).
    o_key = sorted((sev, st) for (sev, _m, st) in oracle[base])
    s_key = sorted((sev, st) for (sev, _m, st) in self[base])
    if o_key != s_key:
        sys.stderr.write("  %s: (sev,start) mismatch self=%s oracle=%s\n" % (base, s_key, o_key))
        ok = False
# Explicitly: the clean siblings are [], the bad one is non-empty.
if self.get("lib_clean.mdk") != [] or self.get("main_app.mdk") != []:
    sys.stderr.write("clean files not blank: %s\n" % self); ok = False
if not self.get("lib_bad.mdk"):
    sys.stderr.write("bad file blanked: %s\n" % self); ok = False
sys.exit(0 if ok else 1)
PY
check "project didOpen → per-file publishDiagnostics (== check --json; bad import doesn't blank clean files)" "$?"

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
