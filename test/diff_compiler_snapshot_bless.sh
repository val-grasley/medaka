#!/bin/sh
# diff_compiler_snapshot_bless.sh — the three locks on `medaka snapshot --bless`.
#
# `--bless` rewrites committed expectations.  That is the single most dangerous verb in a
# golden suite: the person who broke the golden is the person who presses the button, and
# every survey point in TESTING-DESIGN.md §3.1 tells the same story about what happens
# next.  So the button carries three locks, and THIS gate is what keeps them on:
#
#   1. SCOPED        — `--bless` with no targets is REFUSED.  There is no whole-suite
#                      bless (OCaml's rule: promote has a scope, and deliberately no
#                      analogue to `make all`).  Naming what you approve is the only
#                      friction that survives when nobody is watching CI.
#   2. NON-CREATING  — `--bless` on a fixture with no snapshot is REFUSED (GHC's rule:
#                      accept cannot create a golden).  Creating is `--new`'s job, and
#                      ONLY `--new`'s: a stage that could mint its own expectations would
#                      write its own bugs down as correct and the corpus would be worth
#                      nothing.
#   3. NO DIAGNOSTICS — `--bless` REFUSES a fixture whose differing sections include one
#                      carrying compiler diagnostic prose (Zig's rule: it ships no bless
#                      at all for expected error text, and that is *why* its errors are
#                      good).  This repo grades diagnostics against a scored corpus in
#                      compiler/ERROR-QUALITY.md; an auto-blessable diagnostic golden is
#                      actively hostile to that, because it lets a message regress and be
#                      re-blessed without anyone reading it.
#
# A lock that is not tested is a lock that is one refactor from being gone, and each of
# these three fails OPEN — lose one and the suite still runs green while quietly getting
# less able to tell you anything.  Hence a gate of its own.
#
# Hermetic: its own mktemp fixtures and its own --out dir.  It never reads or writes
# test/snapshots/, so it cannot be the thing that breaks the real corpus.
#
# Exit: 0 if every lock holds, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FAMILY="$ROOT/test/diff_compiler_snapshot_frontend.sh"

[ -x "$MEDAKA" ] || { echo "build the compiler first: make medaka (missing $MEDAKA)"; exit 2; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/fx" "$W/snap"

fail=0
pass=0

# ok <name> — a lock held.
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

# expect_fail <name> <expected-substring> -- <cmd...>
#   the command must exit non-zero AND say why.  Both halves matter: a lock that refuses
#   with a mystery message is a lock people route around with --no-verify.
expect_fail() {
  name="$1"; want="$2"; shift 3
  out="$("$@" 2>&1)"; st=$?
  if [ "$st" -eq 0 ]; then
    bad "$name — expected a refusal, got exit 0"
    printf '%s\n' "$out" | sed 's/^/        /'
  elif ! printf '%s\n' "$out" | grep -qF "$want"; then
    bad "$name — refused, but the message never said \"$want\""
    printf '%s\n' "$out" | sed 's/^/        /'
  else
    ok "$name"
  fi
}

snap() { "$MEDAKA" snapshot --root "$ROOT" --out "$W/snap" "$@"; }

printf 'f x = x + 1\n' > "$W/fx/ok.mdk"
printf 'f x = = 1\n' > "$W/fx/bad.mdk"      # a parse error: `# PARSE` holds a diagnostic

# ── LOCK 1: scoped ───────────────────────────────────────────────────────────
expect_fail 'lock 1: bare --bless is refused (medaka)' \
  'requires explicit targets' -- \
  "$MEDAKA" snapshot --bless --root "$ROOT" --out "$W/snap"

# ...and at the harness layer too, which is where a human actually types it.  Two
# enforcement points on purpose: the CLI guard is the one a script can't route around,
# the harness guard is the one that produces a message aimed at the person at the keyboard.
expect_fail 'lock 1: bare --bless is refused (family gate)' \
  'no whole-suite bless' -- \
  sh "$FAMILY" --bless

# ── LOCK 2: non-creating ─────────────────────────────────────────────────────
expect_fail 'lock 2: --bless refuses to CREATE a missing snapshot' \
  'never creates one' -- \
  snap --bless --stages PARSE "$W/fx/ok.mdk"

[ -e "$W/snap/ok.md" ] && bad 'lock 2: the refused --bless wrote a snapshot anyway' \
  || ok 'lock 2: nothing was written'

# --new is the ONLY door in.  (And the mode is mandatory: no default action.)
expect_fail 'a mode is mandatory (no default action)' \
  'pass --check' -- \
  snap --stages PARSE "$W/fx/ok.mdk"
expect_fail 'two modes at once is an error, not a precedence rule' \
  'mutually exclusive' -- \
  snap --check --bless --stages PARSE "$W/fx/ok.mdk"

snap --new --stages PARSE "$W/fx/ok.mdk" >/dev/null 2>&1 \
  && [ -f "$W/snap/ok.md" ] && ok '--new creates it' || bad '--new failed to create ok.md'

# ── the happy path: bless an EXISTING, non-diagnostic snapshot ───────────────
snap --check "$W/fx/ok.mdk" >/dev/null 2>&1 && ok '--check passes on a fresh snapshot' \
  || bad '--check failed on a snapshot --new just wrote'

# a bless with nothing to approve must write NOTHING (no mtime churn, no reflow).
before="$(cat "$W/snap/ok.md")"
snap --bless "$W/fx/ok.mdk" >/dev/null 2>&1
[ "$before" = "$(cat "$W/snap/ok.md")" ] && ok '--bless with no diff is a no-op' \
  || bad '--bless rewrote a snapshot that already matched'

# now change the fixture (the `medaka fmt`-reflow case R1 hit on every compiler PR)...
printf 'f x = x + 2\n' > "$W/fx/ok.mdk"
snap --check "$W/fx/ok.mdk" >/dev/null 2>&1 && bad '--check passed a STALE snapshot' \
  || ok '--check catches the stale snapshot'

# ...and bless it.
if snap --bless "$W/fx/ok.mdk" 2>&1 | grep -q '^.*BLESS '; then
  ok '--bless re-cuts an existing snapshot'
else
  bad '--bless did not re-cut the existing snapshot'
fi
snap --check "$W/fx/ok.mdk" >/dev/null 2>&1 && ok 'gate is green after the bless' \
  || bad 'gate still red after the bless'

# ── LOCK 3: diagnostics are never blessable ──────────────────────────────────
snap --new --stages PARSE "$W/fx/bad.mdk" >/dev/null 2>&1

# The runner RECORDS the fact in the file, so a human opening the .md can see why it will
# not bless — and so the refusal also fires from the stored side (a diagnostic that
# DISAPPEARS is as unblessable as one that changes).
grep -q '^diagnostics=PARSE$' "$W/snap/bad.md" \
  && ok "lock 3: the snapshot records 'diagnostics=PARSE' in # META" \
  || bad "lock 3: # META does not record the diagnostic section"

# move the parse error (same shape a reworded message has: the `# PARSE` section differs)
printf '\n\nf x = = 1\n' > "$W/fx/bad.mdk"
snapbefore="$(cat "$W/snap/bad.md")"
expect_fail 'lock 3: --bless REFUSES a differing diagnostic section' \
  'refusing to bless diagnostic section(s) PARSE' -- \
  snap --bless "$W/fx/bad.mdk"

[ "$snapbefore" = "$(cat "$W/snap/bad.md")" ] \
  && ok 'lock 3: the refused --bless wrote nothing' \
  || bad 'lock 3: the refused --bless rewrote the snapshot anyway'

# and the documented escape hatch — rm + --new — still works, because it is a DELIBERATE,
# visible act (it lands in review as a delete+add, not a one-line edit).
rm -f "$W/snap/bad.md"
snap --new --stages PARSE "$W/fx/bad.mdk" >/dev/null 2>&1
grep -q '^parse error at 3:6' "$W/snap/bad.md" \
  && ok 'the rm + --new escape hatch re-cuts the diagnostic' \
  || bad 'rm + --new did not re-cut the diagnostic snapshot'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
