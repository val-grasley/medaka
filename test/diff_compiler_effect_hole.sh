#!/bin/sh
# test/diff_compiler_effect_hole.sh
#
# CLI-LEVEL gate for capability-effects v2 Stage 2b: the INFERRED-HOLE surface
# form `<Net _>` + the known-prefix abstract analysis α.  Companion to
# diff_compiler_effect_param.sh (Stage 2a's concrete rows); like it, this gate
# runs THROUGH the real `check` front-end (so a CLI-only regression the
# raw-Parser unit tests would miss is caught):
#
#   * the native self-host CLI  (./medaka check)
#   * the OCaml-free native single-file host (test/bin/check_main)
#
# OCaml-free (LIB-REMOVAL-DESIGN §6 Stage A): the OCaml reference-CLI leg and the
# OCaml `dev/gen_golden.exe` WS-2 golden-gen are removed.  The native host TYPES
# are cross-checked against the committed (frozen-native) golden baked into
# test/diff_fixtures/effect_param_hole.golden; the reject cases assert the native
# CLI rejects directly (rc != 0 or an error/Effectful diagnostic).
#
# Stage-2b semantics exercised:
#   ACCEPT  effect_param_hole.mdk —
#     extern netGet : String -> <Net _> String   (inferred hole)
#     fetch _ = netGet "a.com/foo"                 (α(first arg) = Known "a.com/foo")
#     fetch : Unit -> <Net "a.com/*"> String       (wildcard ADMITS the α row)
#   REJECT  (inline fixtures, the native CLI must reject):
#     sibling-host  : <Net "a.com/*"> must NOT admit α("a.com.evil.com/x")
#     computed/fn   : α(function-param url) = Unknown ⇒ ⊤ ⇒ not admitted
#
# Prereqs: `make medaka` (native CLI + medaka_emitter),
#          `FORCE=1 sh test/build_oracles.sh` (test/bin/check_main).
#
# Usage:  sh test/diff_compiler_effect_hole.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/test/diff_fixtures/effect_param_hole.mdk"
GOLD="$ROOT/test/diff_fixtures/effect_param_hole.golden"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
NATIVE="$ROOT/medaka"
HOST="$ROOT/test/bin/check_main"

[ -f "$FIX" ]    || { echo "missing fixture $FIX"; exit 2; }
[ -f "$GOLD" ]   || { echo "missing golden $GOLD"; exit 2; }
[ -x "$NATIVE" ] || { echo "build native first: make medaka (missing $NATIVE)"; exit 2; }
[ -x "$HOST" ]   || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$HOST") (missing $HOST)"; exit 2; }

strip_unit() { sed '$ s/0$//; $ s/()$//'; }
has_parse_err() { grep -qiE 'parse error|type error|unbound|unknown' ; }
# Extract the `# TYPES_USER` section (the last section) of a snapshot .md.
tu_section() { awk '/^# TYPES_USER$/{f=1;next} /^# /{f=0} f'; }

pass=0; fail=0
note() { printf '%s %s\n' "$1" "$2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── ACCEPT: the hole fixture must parse + typecheck ───────────────────────────

# 1. Native self-host CLI must ACCEPT (no parse/type error in streamed output).
nat_out="$(MEDAKA_ROOT="$ROOT" "$NATIVE" check "$FIX" 2>&1)"
if ! printf '%s' "$nat_out" | has_parse_err; then
  pass=$((pass+1)); note ok   "native-cli/check accepts the <Net _> hole fixture"
else
  fail=$((fail+1)); note FAIL "native-cli/check emitted an error: $(printf '%s' "$nat_out" | grep -iE 'parse|type|unbound|unknown' | head -1)"
fi

# 2. Native CLI must surface α's result: the extern renders ⊤ as the bare <Net>,
#    and fetch keeps the declared wildcard row (which ADMITS the α-derived row).
if printf '%s' "$nat_out" | grep -qF 'netGet : String -> <Net> String' \
   && printf '%s' "$nat_out" | grep -qF 'fetch : Unit -> <Net "a.com/*"> String'; then
  pass=$((pass+1)); note ok   'native-cli/check infers <Net> hole + the wildcard fetch row'
else
  fail=$((fail+1)); note FAIL 'native-cli/check did not infer the hole/wildcard rows'
fi

# 3. Native single-file host TYPES ⊇ the `# TYPES_USER` snapshot (#81 Stage C2).
#    The frozen golden's === TYPES === section (prelude + user) was EMPTIED by C2
#    as confirmed-redundant: the prelude table is pinned once by
#    diff_compiler_snapshot_prelude.sh, and the user schemes — including the
#    inferred-hole row netGet : String -> <Net> String and the wildcard fetch row —
#    by the `# TYPES_USER` snapshot. Assert every committed user scheme line appears
#    verbatim in the host's TYPES output (subset membership, order-independent).
SNAP="$ROOT/test/snapshots/diff_fixtures_types/effect_param_hole.md"
[ -f "$SNAP" ] || { echo "missing snapshot $SNAP"; exit 2; }
"$HOST" "$RT" "$CORE" "$FIX" 2>/dev/null | strip_unit > "$WORK/self.txt"
miss="$(tu_section < "$SNAP" | grep -Fxv -f "$WORK/self.txt")"
if [ -z "$miss" ]; then
  pass=$((pass+1)); note ok   "native-host TYPES ⊇ # TYPES_USER snapshot (incl. hole/wildcard rows)"
else
  fail=$((fail+1)); note FAIL "native-host TYPES missing # TYPES_USER lines"
  printf '%s\n' "$miss" | sed 's/^/  missing: /'
fi

# ── WS-2: α SCOPE-SEEDING (E3 precision) — outer-body let recovery ────────────
# A4/outer: the capability URL is bound by an OUTER-BODY `let dest = "<literal>"`
# and only THEN passed to the <Net _> extern.  Pre-WS-2 α ran with an empty
# `lets` at the fill site, so `netGet dest` saw `dest` as an unknown EVar → ⊤
# (bare <Net>).  WS-2 seeds α with the enclosing body's let scope, so the
# inferred row carries the recovered literal prefix.  Native-only check: assert
# the native host recovers the precise <Net "a.com/foo"> row (not the bare <Net>).
cat > "$WORK/ws2_outer.mdk" <<'EOF'
effect Net Prefix
extern netGet : String -> <Net _> String
fetch _ =
  let dest = "a.com/foo"
  netGet dest
main : <IO> Unit
main = println "x"
EOF
nat_types="$("$HOST" "$RT" "$CORE" "$WORK/ws2_outer.mdk" 2>/dev/null | strip_unit | LC_ALL=C sort)"
if printf '%s' "$nat_types" | grep -qF 'fetch : a -> <Net "a.com/foo"> String'; then
  pass=$((pass+1)); note ok   'WS-2: outer-let recovers <Net "a.com/foo"> (native-only check)'
else
  fail=$((fail+1)); note FAIL 'WS-2: outer-let row not recovered'
  printf '  --- native ---\n%s\n' "$nat_types" | sed 's/^/  /'
fi

# ── REJECT: delimiter-aware subsumption must reject the unsafe call shapes ─────

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

# WS-2 soundness: an OUTER-BODY let whose RHS is a NON-LITERAL (a parameter) must
# STAY ⊤ even with α scope-seeding — seeding recovers a prefix only when α can
# prove one.  `let dest = url` then `netGet dest` ⇒ α(dest) = α(url) = Unknown.
cat > "$WORK/reject_outer_computed.mdk" <<'EOF'
effect Net Prefix
extern netGet : String -> <Net _> String
fetch : String -> <Net "a.com/*"> String
fetch url =
  let dest = url
  netGet dest
main : <IO> Unit
main = println "x"
EOF

check_rejects() {
  name="$1"; f="$WORK/$name.mdk"
  nat="$(MEDAKA_ROOT="$ROOT" "$NATIVE" check "$f" 2>&1)"; nat_rc=$?
  nat_rej=0
  # Native `check` may exit 0 while streaming a diagnostic, so accept EITHER a
  # non-zero exit OR an error/Effectful capability diagnostic as a rejection.
  { [ "$nat_rc" -ne 0 ] || printf '%s' "$nat" | grep -qiE 'error|Effectful'; } && nat_rej=1
  if [ "$nat_rej" -eq 1 ]; then
    pass=$((pass+1)); note ok   "native-cli REJECTS $name"
  else
    fail=$((fail+1)); note FAIL "$name: native did not reject (rc=$nat_rc)"
    printf '  native: %s\n' "$(printf '%s' "$nat" | grep -iE 'error|Effectful' | head -1)"
  fi
}

check_rejects reject_sibling
check_rejects reject_computed
check_rejects reject_outer_computed

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
