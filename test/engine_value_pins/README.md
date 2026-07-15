# test/engine_value_pins/ — absolute value pins for `diff_compiler_engines.sh`

**Status:** ACTIVE

## Why this exists (issue #86)

`diff_compiler_engines.sh` only asserts that eval == native == wasm — that the
three engines *agree*. A bug where all three engines agree and are all wrong
is invisible to a pure differential gate by construction. This is not
theoretical: issue #50 was exactly this shape (a user's own function silently
ignored; `run == build`, both wrong the same way, for months). SHADOW-SEMANTICS
S7 *guarantees* path agreement, so a wrong-but-unanimous answer can never be
caught by cross-engine comparison alone.

This directory adds a second, orthogonal, **falsifiable absolute** assertion
on top of the differential one: for a fixture with a pin file here, every
engine that ran must equal a literal, hand-verified expected value — not
merely equal each other.

## Format

One file per pinned fixture: `test/engine_value_pins/<corpus>/<name>.pin`,
where `<corpus>/<name>` is exactly the gate's own key namespace (`llvm/`,
`llvmT/`, `wasm/`, `wasmT/` — see `diff_compiler_engines.sh`'s `--one` worker,
the `case "$f" in ... key=...` block). The corpus prefix is load-bearing there
for the same reason it's load-bearing here: 18 basenames collide across the
four corpora as *different* fixtures.

A `.pin` file's content is the **exact expected stdout, byte-for-byte**
(including trailing newline if the golden has one — verify with `od -c`, not
by eye). Only pin a value you've independently hand-verified — do not mint a
pin by copying a `.eval.golden` unread; that file was captured from a
(possibly wrong) engine, which is the exact circularity this gate elsewhere
goes out of its way to avoid (see the gate's own header comment on
`diff_compiler_llvm.sh`'s golden-file circularity).

## Incremental — a missing `.pin` is not a failure

Only ~4 of the ~404 corpus fixtures are pinned today. A fixture with no `.pin`
file is simply not checked by this layer (the cross-engine differential still
covers it as before). This is deliberate: the pin corpus grows fixture by
fixture, same as the TMC `-- EXPECT-TMC:` coverage pins (#44) it's modeled
after.

## ⚠️ Seed pins ONLY on CLEAN fixtures — the ledger-interaction gap

**Only pin a fixture that has NO row in `test/engine_divergence.txt`** (i.e.
all three engines currently agree on it). This sidesteps a real design gap:

If a fixture is *ledgered* as a known cross-engine divergence (e.g.
`rng_int_big`, whose wasm arm is known-bad per the ledger), a naive per-arm
pin check would compare the pin against every arm that `ran` — including the
arm the ledger already documents as wrong — and go red on an already-known,
already-tracked failure. That's not a new bug; it's the pin mechanism
tripping over a fact the ledger already states.

**This is NOT implemented.** Pinning a ledgered-divergent fixture would need
the pin check to accept "matches the pin on every arm EXCEPT the one(s) the
ledger already marks as diverging" — i.e. the pin logic would need to consult
`test/engine_divergence.txt` per-arm, not just per-fixture. Until that lands,
keep the seed corpus restricted to clean (unledgered) fixtures, where "does
every arm that ran match the pin" and "is this fixture correct" are the same
question.

## The four seed pins

All four are `test/llvm_fixtures/` fixtures, hand-verified against their own
source (not just copied from `.eval.golden`):

- `llvm/adt_imm_mixed.pin` = `42\n` — `describe Empty + describe (Full 42)` =
  `0 + 42` = `42` (see the fixture's own header: nullary-immediate vs boxed-ctor
  match discrimination).
- `llvm/arr_get.pin` = `20\n` — `arrayGetUnsafe 1 [| 10, 20, 30 |]` = the
  element at index 1 = `20`.
- `llvm/bool_false.pin` = `False\n` — `(3 >= 4) && (1 == 1)`: `3 >= 4` is
  `False`, so `&&` short-circuits to `False`.
- `llvm/char_code.pin` = `65\n` — `charCode 'A'` = ASCII code point of `'A'` =
  `65`.
