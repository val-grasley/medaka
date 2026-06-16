#!/bin/sh
# test/diff_selfhost_effect_hole.sh
#
# CLI-LEVEL differential gate for capability-effects v2 Stage 2b: the
# INFERRED-HOLE surface form `<Net _>` + the known-prefix abstract analysis α.
# Companion to diff_selfhost_effect_param.sh (Stage 2a's concrete rows); like it,
# this gate runs THROUGH BOTH real `check` front-ends (so a CLI-only regression
# the raw-Parser unit tests would miss is caught):
#
#   * the OCaml reference CLI   (_build/default/bin/main.exe check)
#   * the native self-host CLI  (./medaka check)
#
# and cross-checks the OCaml-free native single-file host (test/bin/check_main)
# against the OCaml `gen_golden` === TYPES === oracle baked into
# test/diff_fixtures/effect_param_hole.golden.
#
# Stage-2b semantics exercised:
#   ACCEPT  effect_param_hole.mdk —
#     extern netGet : String -> <Net _> String   (inferred hole)
#     fetch _ = netGet "a.com/foo"                 (α(first arg) = Known "a.com/foo")
#     fetch : Unit -> <Net "a.com/*"> String       (wildcard ADMITS the α row)
#   REJECT  (inline fixtures, both CLIs must reject):
#     sibling-host  : <Net "a.com/*"> must NOT admit α("a.com.evil.com/x")
#     computed/fn   : α(function-param url) = Unknown ⇒ ⊤ ⇒ not admitted
#
# Prereqs: `make medaka` (native CLI + medaka_emitter),
#          `FORCE=1 sh test/build_oracles.sh` (test/bin/check_main),
#          `dune build --root .` (OCaml main.exe).
#
# Usage:  sh test/diff_selfhost_effect_hole.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/test/diff_fixtures/effect_param_hole.mdk"
GOLD="$ROOT/test/diff_fixtures/effect_param_hole.golden"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
OCAML="$ROOT/_build/default/bin/main.exe"
NATIVE="$ROOT/medaka"
HOST="$ROOT/test/bin/check_main"

[ -f "$FIX" ]    || { echo "missing fixture $FIX"; exit 2; }
[ -f "$GOLD" ]   || { echo "missing golden $GOLD (gen via dev/gen_golden.exe)"; exit 2; }
[ -x "$OCAML" ]  || { echo "build OCaml CLI first: dune build --root . (missing $OCAML)"; exit 2; }
[ -x "$NATIVE" ] || { echo "build native first: make medaka (missing $NATIVE)"; exit 2; }
[ -x "$HOST" ]   || { echo "build oracles first: FORCE=1 sh test/build_oracles.sh (missing $HOST)"; exit 2; }

strip_unit() { sed '$ s/0$//; $ s/()$//'; }
has_parse_err() { grep -qiE 'parse error|type error|unbound|unknown' ; }

pass=0; fail=0
note() { printf '%s %s\n' "$1" "$2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── ACCEPT: the hole fixture must parse + typecheck on BOTH CLIs ───────────────

# 1. OCaml reference CLI must ACCEPT (exit 0, no parse/type error).
oc_out="$("$OCAML" check "$FIX" 2>&1)"; oc_rc=$?
if [ "$oc_rc" -eq 0 ] && ! printf '%s' "$oc_out" | has_parse_err; then
  pass=$((pass+1)); note ok   "ocaml-cli/check accepts the <Net _> hole fixture"
else
  fail=$((fail+1)); note FAIL "ocaml-cli/check (rc=$oc_rc): $oc_out"
fi

# 2. Native self-host CLI must ACCEPT (no parse/type error in streamed output).
nat_out="$(MEDAKA_ROOT="$ROOT" "$NATIVE" check "$FIX" 2>&1)"
if ! printf '%s' "$nat_out" | has_parse_err; then
  pass=$((pass+1)); note ok   "native-cli/check accepts the <Net _> hole fixture"
else
  fail=$((fail+1)); note FAIL "native-cli/check emitted an error: $(printf '%s' "$nat_out" | grep -iE 'parse|type|unbound|unknown' | head -1)"
fi

# 3. Native CLI must surface α's result: the extern renders ⊤ as the bare <Net>,
#    and fetch keeps the declared wildcard row (which ADMITS the α-derived row).
if printf '%s' "$nat_out" | grep -qF 'netGet : String -> <Net> String' \
   && printf '%s' "$nat_out" | grep -qF 'fetch : Unit -> <Net "a.com/*"> String'; then
  pass=$((pass+1)); note ok   'native-cli/check infers <Net> hole + the wildcard fetch row'
else
  fail=$((fail+1)); note FAIL 'native-cli/check did not infer the hole/wildcard rows'
fi

# 4. DIFFERENTIAL: native single-file host TYPES == OCaml gen_golden TYPES.
self="$("$HOST" "$RT" "$CORE" "$FIX" 2>/dev/null | strip_unit | LC_ALL=C sort)"
want="$(sed -n '/=== TYPES ===/,/=== EVAL ===/p' "$GOLD" | sed '1d;$d' | LC_ALL=C sort)"
if [ "$self" = "$want" ]; then
  pass=$((pass+1)); note ok   "native-host TYPES == OCaml oracle (differential)"
else
  fail=$((fail+1)); note FAIL "native-host TYPES != OCaml oracle"
  printf '%s\n' "$want" > "$WORK/want.txt"
  printf '%s\n' "$self" > "$WORK/self.txt"
  diff "$WORK/want.txt" "$WORK/self.txt" | head -12 | sed 's/^/  /'
fi

# ── REJECT: delimiter-aware subsumption must reject both unsafe call shapes,
#            and BOTH CLIs must agree on the rejection. ──────────────────────────

# reject_sibling: α("a.com.evil.com/x") = Known, but <Net "a.com/*"> must NOT
# admit a sibling host (the '/' delimiter guards against prefix-as-substring).
cat > "$WORK/reject_sibling.mdk" <<'EOF'
effect Net Prefix
extern netGet : String -> <Net _> String
fetch : Unit -> <Net "a.com/*"> String
fetch _ = netGet "a.com.evil.com/x"
main : <IO> Unit
main = println "x"
EOF

# reject_computed: the URL is a function parameter ⇒ α = Unknown ⇒ ⊤ (<Net>),
# which the bounded <Net "a.com/*"> must NOT admit (the no-exfiltration rule).
cat > "$WORK/reject_computed.mdk" <<'EOF'
effect Net Prefix
extern netGet : String -> <Net _> String
fetch : String -> <Net "a.com/*"> String
fetch url = netGet url
main : <IO> Unit
main = println "x"
EOF

check_rejects() {
  name="$1"; f="$WORK/$name.mdk"
  oc="$("$OCAML" check "$f" 2>&1)"; ocrc=$?
  nat="$(MEDAKA_ROOT="$ROOT" "$NATIVE" check "$f" 2>&1)"
  oc_rej=0; nat_rej=0
  { [ "$ocrc" -ne 0 ] || printf '%s' "$oc" | grep -qiE 'error'; } && oc_rej=1
  printf '%s' "$nat" | grep -qiE 'error' && nat_rej=1
  if [ "$oc_rej" -eq 1 ] && [ "$nat_rej" -eq 1 ]; then
    pass=$((pass+1)); note ok   "both CLIs REJECT $name"
  else
    fail=$((fail+1)); note FAIL "$name: ocaml_rejected=$oc_rej native_rejected=$nat_rej"
    printf '  ocaml: %s\n' "$(printf '%s' "$oc"  | grep -iE 'error' | head -1)"
    printf '  native: %s\n' "$(printf '%s' "$nat" | grep -iE 'error' | head -1)"
  fi
}

check_rejects reject_sibling
check_rejects reject_computed

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
