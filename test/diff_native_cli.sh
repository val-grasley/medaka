#!/bin/sh
# Differential validation for the NATIVE medaka CLI (Phase C Slice 0+1):
# selfhost/medaka_cli.mdk, native-compiled to ./medaka, must reproduce the OCaml
# reference for the check / fmt / new subcommands it wires.
#
#   check  — native `./medaka check <f>`  ==  OCaml `main.exe run check_main.mdk
#            <rt> <core> <f>`.  (The native CLI's check IS check.runCheck, the
#            same logic check_main.mdk drives; OCaml `main.exe check` prints a
#            different "OK — N bindings" surface and is NOT the oracle here.)
#   fmt    — native `./medaka fmt --stdout <f>`  ==  OCaml `main.exe fmt --stdout <f>`.
#   new    — native `./medaka new <name>` scaffolds the same file tree (contents)
#            as OCaml `main.exe new <name>`.
#   build  — native `./medaka build F -o X && X`  ==  OCaml `main.exe build F -o Y && Y`
#            over llvm_fixtures (the native CLI drives emit→clang with no OCaml in
#            its own logic; the emit step shells out to the emitter, hosted by
#            MEDAKA — set to the native ./medaka run path when available, else the
#            OCaml exe).  Both native binaries' stdout must be byte-identical.
#   run    — native `./medaka run F`  ==  OCaml `main.exe run F` over llvm_fixtures.
#   test   — native `./medaka test F`  ==  OCaml `main.exe test F` over main-less
#            doctest/prop fixtures (a top-level effectful `main` is omitted: the
#            selfhost test path is LAZY-nullary (Phase-125) so it would not run an
#            effectful main, while OCaml `test` does — that divergence is by
#            design, not a regression, so the fixtures carry no effectful main).
#            Exercises prop_runner's constructor block-let through the native
#            emitter (the Slice-3 / emitBlock proof).
#
# The native runtime auto-prints main's Unit value as a trailing "0"; strip it
# (strip_unit) before comparing against the OCaml driver, which does not.
# Every native/OCaml invocation is bounded by `perl -e 'alarm N; exec @ARGV'`
# (macOS has no `timeout`).
#
# Usage:  sh test/diff_native_cli.sh
# Exit:   0 if every fixture matches + the deferred assertion holds, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
MEDAKA="$ROOT/medaka"
CHECK_MAIN="$ROOT/selfhost/check_main.mdk"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$MAIN" ]   || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build first: medaka build selfhost/medaka_cli.mdk -o ./medaka (missing $MEDAKA)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

# Drop the native runtime's trailing Unit auto-print: a lone "0" appended to the
# last line of stdout (no preceding newline from the program's final putStr).
strip_unit() { sed '$ s/0$//'; }

pass=0; fail=0

# ── check: native runCheck == OCaml-interpreted check_main ──────────────────
for f in "$ROOT"/test/diff_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  want="$(bound "$MAIN" run "$CHECK_MAIN" "$RT" "$CORE" "$f" 2>/dev/null | LC_ALL=C sort)"
  got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   check/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL check/%s\n' "$name"
    printf '  want: %s\n  got:  %s\n' "$want" "$got"; fi
done

# ── fmt: native fmt --stdout == OCaml fmt --stdout ──────────────────────────
for f in "$ROOT"/test/fmt_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  want="$(bound "$MAIN" fmt --stdout "$f" 2>/dev/null)"
  got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" fmt --stdout "$f" 2>/dev/null | strip_unit)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   fmt/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL fmt/%s\n' "$name"; fi
done

# ── new: scaffolded file tree (contents) identical ──────────────────────────
# Same project name under separate dirs, so the only legitimate difference
# (the name baked into medaka.toml / README) is eliminated.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/oc" "$TMP/nat"
( cd "$TMP/oc"  && bound "$MAIN" new proj >/dev/null 2>&1 )
( cd "$TMP/nat" && MEDAKA_ROOT="$ROOT" bound "$MEDAKA" new proj >/dev/null 2>&1 )
ocfiles="$(cd "$TMP/oc/proj" 2>/dev/null && find . -type f | LC_ALL=C sort)"
natfiles="$(cd "$TMP/nat/proj" 2>/dev/null && find . -type f | LC_ALL=C sort)"
if [ "$ocfiles" = "$natfiles" ] && [ -n "$ocfiles" ]; then
  new_ok=1
  for rel in $ocfiles; do
    if ! cmp -s "$TMP/oc/proj/$rel" "$TMP/nat/proj/$rel"; then new_ok=0;
      printf '  differ: %s\n' "$rel"; fi
  done
  if [ "$new_ok" = 1 ]; then pass=$((pass+1)); printf 'ok   new/tree\n'
  else fail=$((fail+1)); printf 'FAIL new/tree (file contents differ)\n'; fi
else
  fail=$((fail+1)); printf 'FAIL new/tree (file lists differ)\n'
  printf '  oc:  %s\n  nat: %s\n' "$ocfiles" "$natfiles"
fi

# ── repl: native ./medaka repl == OCaml main.exe repl ───────────────────────
# Feed the same scripted session used in diff_selfhost_repl.sh and compare
# native vs OCaml byte-for-byte.
REPL_INPUT='x = 42
y = x + 1
[x, y]
badname
x + 1
:type x
:browse
:reset
:browse
:quit
'

repl_probe="$(printf ':quit\n' | MEDAKA_ROOT="$ROOT" bound "$MEDAKA" repl 2>&1)"
case "$repl_probe" in
  *"not yet in native CLI"*) REPL_WIRED=0 ;;
  *) REPL_WIRED=1 ;;
esac

if [ "$REPL_WIRED" = 1 ]; then
  repl_want="$(printf '%s' "$REPL_INPUT" | bound "$MAIN" repl 2>/dev/null)"
  repl_got="$(printf '%s' "$REPL_INPUT" | MEDAKA_ROOT="$ROOT" bound "$MEDAKA" repl 2>/dev/null | strip_unit)"
  if [ "$repl_got" = "$repl_want" ]; then
    pass=$((pass+1)); printf 'ok   repl/session\n'
  else
    fail=$((fail+1)); printf 'FAIL repl/session\n'
    printf '  want: [%s]\n  got:  [%s]\n' "$repl_want" "$repl_got"
  fi
else
  printf 'skip repl/* (native repl not yet wired)\n'
fi

# ── lsp: native ./medaka lsp == interpreted selfhost lsp_main.mdk ────────────
# Mirror diff_selfhost_lsp.sh: feed a canned JSON-RPC exchange (initialize +
# didOpen clean + exit) to BOTH the native `medaka lsp` and the interpreted
# `medaka run selfhost/lsp_main.mdk`, decode the framed responses, and compare
# the initialize capabilities and publishDiagnostics semantically (field order
# may differ; Content-Type header absent in native output).
#
# The OCaml lsp_server is NOT the oracle here — it has different capabilities
# and requires `initialized` before dispatching didOpen.  The interpreted
# selfhost IS the oracle (diff_selfhost_lsp.sh already validates it vs a
# semantic spec; here we just confirm native matches interpreted).

lsp_probe="$(printf '' | MEDAKA_ROOT="$ROOT" bound "$MEDAKA" lsp 2>&1 1>/dev/null)"
case "$lsp_probe" in
  *"not yet in native CLI"*) LSP_WIRED=0 ;;
  *) LSP_WIRED=1 ;;
esac

LSP_MAIN="$ROOT/selfhost/lsp_main.mdk"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

if [ "$LSP_WIRED" = 1 ]; then
  lsp_frame() { python3 -c "
import sys
b = sys.argv[1].encode('utf-8')
sys.stdout.buffer.write(b'Content-Length: %d\r\n\r\n' % len(b))
sys.stdout.buffer.write(b)
" "$1"; }

  lsp_decode() { python3 - "$1" <<'PY'
import sys, re, json
data = open(sys.argv[1], "rb").read()
# Strip optional Content-Type header line between Content-Length and body
parts = re.split(rb"Content-Length: \d+\r\n(?:Content-Type:[^\r\n]*\r\n)?\r\n", data)
for p in parts:
    p = p.strip()
    if not p: continue
    dec = json.JSONDecoder(); idx = 0; s = p.decode("utf-8", errors="replace")
    while idx < len(s):
        s2 = s[idx:].lstrip()
        if not s2: break
        try:
            obj, end = dec.raw_decode(s2)
            print(json.dumps(obj))
            idx += len(s[idx:]) - len(s2) + end
        except Exception:
            break
PY
}

  LSP_TMP="$(mktemp -d)"
  trap 'rm -rf "$LSP_TMP"' EXIT

  INIT_MSG='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  OPEN_MSG='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///clean.mdk","text":"main = println \"hi\"\n"}}}'
  EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":{}}'

  > "$LSP_TMP/req.bin"
  lsp_frame "$INIT_MSG" >> "$LSP_TMP/req.bin"
  lsp_frame "$OPEN_MSG"  >> "$LSP_TMP/req.bin"
  lsp_frame "$EXIT_MSG"  >> "$LSP_TMP/req.bin"

  # Oracle: interpreted selfhost lsp_main.mdk
  bound "$MAIN" run "$LSP_MAIN" "$RT" "$CORE" < "$LSP_TMP/req.bin" > "$LSP_TMP/interp.bin" 2>/dev/null || true
  # Native: ./medaka lsp
  MEDAKA_ROOT="$ROOT" bound "$MEDAKA" lsp < "$LSP_TMP/req.bin" > "$LSP_TMP/nat.bin" 2>/dev/null || true

  lsp_decode "$LSP_TMP/interp.bin" > "$LSP_TMP/interp.json" 2>/dev/null || true
  lsp_decode "$LSP_TMP/nat.bin"    > "$LSP_TMP/nat.json"    2>/dev/null || true

  # Compare: initialize capabilities (same key set + serverInfo), publishDiagnostics (empty)
  python3 - "$LSP_TMP/interp.json" "$LSP_TMP/nat.json" <<'PY'
import sys, json
interp = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
nat    = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
def find(msgs, **kw):
    for m in msgs:
        if all(m.get(k)==v for k,v in kw.items()): return m
    return None
i_init = find(interp, id=1)
n_init = find(nat,    id=1)
ok_init = (i_init is not None and n_init is not None
           and "result" in i_init and "result" in n_init
           and set(i_init["result"].get("capabilities",{}).keys()) ==
               set(n_init["result"].get("capabilities",{}).keys())
           and i_init["result"].get("serverInfo",{}).get("name") == "medaka-lsp"
           and n_init["result"].get("serverInfo",{}).get("name") == "medaka-lsp")
i_pub = find(interp, method="textDocument/publishDiagnostics")
n_pub = find(nat,    method="textDocument/publishDiagnostics")
ok_pub = (i_pub is not None and n_pub is not None
          and i_pub["params"]["diagnostics"] == n_pub["params"]["diagnostics"] == [])
if not ok_init:
    sys.stderr.write("init mismatch: interp=%s nat=%s\n" % (i_init, n_init))
if not ok_pub:
    sys.stderr.write("pub mismatch: interp=%s nat=%s\n" % (i_pub, n_pub))
sys.exit(0 if (ok_init and ok_pub) else 1)
PY
  lsp_rc=$?
  if [ "$lsp_rc" = 0 ]; then
    pass=$((pass+1)); printf 'ok   lsp/session\n'
  else
    fail=$((fail+1)); printf 'FAIL lsp/session\n'
  fi
else
  printf 'skip lsp/* (native lsp not yet wired)\n'
fi

# ── run: native ./medaka run F == OCaml main.exe run F ──────────────────────
# A handful of representative runnable fixtures.  The native CLI's `run` routes
# eval.mdk's load→typecheck→eval (eval_typed_modules_main path), forcing main;
# its captured output is NOT auto-print-suffixed (evalModulesOutput returns the
# string), so strip the trailing native-CLI Unit "0" only.
# ── inline IO fixtures (printed output, so the oracle is meaningful) ─────────
# Value-`main` llvm_fixtures auto-print only under the native runtime, not under
# `medaka run`; to compare run/build honestly we use programs whose `main` is an
# IO action emitting via putStrLn (identical surface on every path).
SRC="$TMP/src"; mkdir -p "$SRC"
cat > "$SRC/hello.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn "hello, medaka"
EOF
cat > "$SRC/arith.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (intToString (2 + 3 * 4 - (10 / 3) + (17 % 5) + (0 - 7) / 2))
EOF
cat > "$SRC/recur.mdk" <<'EOF'
fact : Int -> Int
fact n = if n <= 1 then 1 else n * fact (n - 1)
main : <IO> Unit
main = putStrLn (intToString (fact 6))
EOF
cat > "$SRC/adt.mdk" <<'EOF'
data Shape = Circle Int | Rect Int Int
area : Shape -> Int
area s = match s
  Circle r => r * r * 3
  Rect w h => w * h
main : <IO> Unit
main = putStrLn (intToString (area (Circle 4) + area (Rect 3 5)))
EOF
cat > "$SRC/listsum.mdk" <<'EOF'
data IntList = Nil | Cons Int IntList
sumL : IntList -> Int
sumL xs = match xs
  Nil => 0
  Cons h t => h + sumL t
main : <IO> Unit
main = putStrLn (intToString (sumL (Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil))))))
EOF
cat > "$SRC/strcat.mdk" <<'EOF'
main : <IO> Unit
main = putStrLn (stringConcat ["a", "b", stringConcat ["c", "d"]])
EOF
RUN_FIXTURES="hello arith recur adt listsum strcat"

# Is native `run` wired yet?  (Slice-2 lands build first, then run.)  Probe once;
# when deferred, skip run cases and host the build emit with the OCaml exe.
run_probe="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$SRC/hello.mdk" 2>&1)"
case "$run_probe" in
  *"not yet in native CLI"*) RUN_WIRED=0 ;;
  *) RUN_WIRED=1 ;;
esac

if [ "$RUN_WIRED" = 1 ]; then
  for base in $RUN_FIXTURES; do
    f="$SRC/$base.mdk"
    want="$(bound "$MAIN" run "$f" 2>/dev/null)"
    got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$f" 2>/dev/null | strip_unit)"
    if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   run/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL run/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done
else
  printf 'skip run/* (native run not yet wired)\n'
fi

# ── test: native ./medaka test F == OCaml main.exe test F ────────────────────
# Main-less doctest/prop fixtures (see header): an effectful top-level main is
# omitted so the lazy-nullary selfhost path and the eager OCaml path agree.  The
# prop fixture drives prop_runner (its constructor block-let `let PropParam x ty
# = …` is the emitBlock arm closed in Slice 3 — the end-to-end native proof).
TSRC="$TMP/tsrc"; mkdir -p "$TSRC"
cat > "$TSRC/doc.mdk" <<'EOF'
-- > double 3
-- 6
double : Int -> Int
double x = x * 2
EOF
cat > "$TSRC/prop.mdk" <<'EOF'
-- > triple 2
-- 6
triple : Int -> Int
triple x = x * 3

prop "triple is add-thrice" (x : Int) = triple x == x + x + x
EOF
cat > "$TSRC/nodoc.mdk" <<'EOF'
inc : Int -> Int
inc x = x + 1
EOF
TEST_FIXTURES="doc prop nodoc"

test_probe="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$TSRC/doc.mdk" 2>&1)"
case "$test_probe" in
  *"not yet in native CLI"*) TEST_WIRED=0 ;;
  *) TEST_WIRED=1 ;;
esac

if [ "$TEST_WIRED" = 1 ]; then
  for base in $TEST_FIXTURES; do
    f="$TSRC/$base.mdk"
    want="$(bound "$MAIN" test "$f" 2>/dev/null)"
    got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$f" 2>/dev/null | strip_unit)"
    if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   test/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL test/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done
else
  printf 'skip test/* (native test not yet wired)\n'
fi

# ── build: native ./medaka build F == OCaml main.exe build F (binary stdout) ─
# The native CLI drives emit→clang with no OCaml in ITS logic.  The emit step
# shells out to the emitter; host it with the native ./medaka run path (MEDAKA),
# closing the OCaml-free loop once `run` is wired.  Compare both built binaries'
# stdout (the native runtime auto-print is identical on both, so no strip needed).
# Skip the whole build block if no clang / libgc (opt-in, like build_cmd.sh).
build_skip=0
command -v "${CC:-clang}" >/dev/null 2>&1 || build_skip=1
if [ "$build_skip" = 0 ]; then
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
  elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
  elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "${CC:-clang}" -x c - -lgc -o /dev/null 2>/dev/null; then :
  else build_skip=1; fi
fi
if [ "$build_skip" = 1 ]; then
  printf 'skip build/* (no clang or libgc)\n'
else
  BUILD_FIXTURES="$RUN_FIXTURES"
  if [ -n "${MEDAKA_EMITTER:-}" ] && [ -x "${MEDAKA_EMITTER}" ]; then
    EMIT_ENV="MEDAKA_EMITTER=$MEDAKA_EMITTER"; emit_label="native-emitter (OCaml-free)"
  else
    EMIT_ENV="MEDAKA=$MAIN"; emit_label="ocaml-emit (native CLI drives emit→clang)"
  fi
  printf 'note build emit host: %s\n' "$emit_label"
  for base in $BUILD_FIXTURES; do
    f="$SRC/$base.mdk"
    # OCaml-built binary (oracle).
    bound "$MAIN" build "$f" -o "$TMP/oc_$base" >/dev/null 2>&1
    want="$("$TMP/oc_$base" 2>/dev/null)"
    # Native-CLI-built binary; emit hosted by native ./medaka run (OCaml-free).
    ( export MEDAKA_ROOT="$ROOT"; eval "export $EMIT_ENV"; bound "$MEDAKA" build "$f" -o "$TMP/nat_$base" ) >/dev/null 2>&1
    got="$("$TMP/nat_$base" 2>/dev/null)"
    if [ -x "$TMP/nat_$base" ] && [ "$got" = "$want" ]; then
      pass=$((pass+1)); printf 'ok   build/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL build/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
