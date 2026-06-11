#!/bin/sh
# test/diff_selfhost_lsp.sh — differential gate for the self-hosted LSP
# (Stage 4 Phase B.10, slices B.10.0 + B.10.1).
#
# Drives selfhost/lsp_main.mdk with hand-framed Content-Length JSON-RPC requests
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
#                           single-diagnostic shape of `check --json`.
#
# Message TEXT and expr-level RANGE are intentionally NOT diffed: the selfhost
# AST is location-stripped (ranges are decl/whole-document granular until the
# ELoc slice), and type-error messages differ from the oracle in unification
# order (the documented selfhost limitation, cf. diff_selfhost_diagnostics.sh).
# The gate asserts the structural parity B.10.1 guarantees: presence, count,
# severity, and source.
#
# Usage: sh test/diff_selfhost_lsp.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
LSP_MAIN="$ROOT/selfhost/lsp_main.mdk"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }

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

# Run the selfhost LSP over a framed stdin stream (built from the JSON messages
# passed as args), capture stdout, and split it into one JSON object per frame.
# Writes the decoded JSON objects (one per line) to $TMP/out.json.
drive_lsp() {
  : > "$TMP/in.bin"
  for msg in "$@"; do frame "$msg" >> "$TMP/in.bin"; done
  perl -e 'alarm 180; exec @ARGV' \
    "$MAIN" run "$LSP_MAIN" "$RT" "$CORE" < "$TMP/in.bin" > "$TMP/out.bin" 2>/dev/null
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
        obj, end = dec.raw_decode(s2)
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
ORACLE_CLEAN="$("$MAIN" check --json "$TMP/clean.mdk" 2>/dev/null)"
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
ORACLE_ERR="$("$MAIN" check --json "$TMP/err.mdk" 2>/dev/null)"
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
# (message text + expr-level range diverge by design — see header.)
ok = (len(sd) == len(od) == 1
      and sd[0]["severity"] == od[0]["severity"] == 1
      and sd[0]["source"] == od[0]["source"] == "medaka"
      and "range" in sd[0] and "message" in sd[0])
sys.exit(0 if ok else 1)
PY
check "didOpen type-error → one Error diagnostic (severity+source == check --json)" "$?"

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

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
