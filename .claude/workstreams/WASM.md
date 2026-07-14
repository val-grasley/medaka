# Workstream: WASM (the WasmGC backend)

**Owns:** `compiler/backend/wasm_emit.mdk` and the wasm gates.
**Touches:** `compiler/backend/wasm_emit.mdk`, `test/wasm/`.

```sh
gh issue list --label "ws:wasm" --state open
```

**The playground runs on this backend, and the playground is the 0.1.0 front door.** A stranger's first
Medaka program goes through `wasm_emit`. That is what makes this workstream a release concern and not
a side quest.

Needs **node ≥ 24** for the wasm gates; `sh test/wasm/build_wasm_oracle.sh` builds the oracle.

---

## ⚠️ A ONE-BACKEND FIX IS A HALF FIX

The rule was paid for (#59). A partially-applied-constructor miscompile was fixed in the LLVM emitter
and **not** in the WasmGC one. The self-checking script reported FIXED, the library's workaround was
reverted on the strength of it — and only the **wasm tandem gate** caught that the library no longer
emitted to wasm.

**If a soundness fix touches `llvm_emit.mdk`, you own the wasm arm too.** Do not hand it to a second
orchestrator, and do not trust a verifier that checks one backend.

The inverse trap is just as real: **a parity gate cannot detect a bug where both backends are equally
wrong.** The TMC dict-veto lived in a *shared* predicate, so both backends declined identically and the
census was a green, honest `12/12 same`. **Parity was gated; coverage never was.**

---

## ⚠️ The emitter must not assert a category it cannot know

`wasm_emit` used to prefix every unbound name with **"gap —"**, asserting *backend coverage gap*. But
an unbound name can simply mean the program never typechecked — `index` is an interface method that
only resolves on a typechecked path. **17 ledgered "wasm bugs" were never bugs**, and the false
category propagated into ledgers, docs, and agent prompts, where each copy read like corroboration.

**The discriminating test — run it before you write a `wasm:emitter-gap` row:**

```sh
./test/bin/llvm_emit_main <fixture>    # does the OTHER backend manage it?
./test/bin/wasm_emit_main  <fixture>
# BOTH fail the same way -> NOT a backend gap (a prelude-free-corpus fact). Do NOT write the row.
# ONLY wasm fails         -> a genuine wasm gap.
```

**A ledger is only as good as the category you write in it.**

---

## State of the ledgers (2026-07-14)

- **7 rows are confirmed `wasm:codegen-bug` on the SHIPPING CLI** — i31 tag leaks in `charCode`,
  instantiate traps on `Int` bounds, `illegal cast` on type-lost Floats. Real bugs on the path users
  run → **#60**.
- **34 rows are categorised `wasm:emitter-gap` but were NOT re-confirmed against the shipping CLI** →
  **#71**. The 4 RED `diff_wasm` rows are the same story: `test/CI-COVERAGE-EXCEPTIONS.txt:49` admits
  the gate *"still shells that same prelude-free probe today and has NOT been moved onto the shipping
  CLI"* — the **identical probe that already dissolved 16 other rows.** Start there.
- **60 `CAPABILITY-EXCEPTIONS` wasm rows**: 12 PERMANENT (raw BSD sockets have no WasmGC equivalent —
  *"the honest, by-design gap in the whole matrix"*), 2 TRAP-STUB (`intMinBound`/`intMaxBound` lower to
  `unreachable`), 45 WASM-GAP (23 libm math, 4 bitwise, 4 perf, 14 file/env).

**Fixture corpora are SHARED.** `test/wasm/fixtures/` has **four** consumers (`diff_wasm.sh`,
`diff_compiler_engines.sh`, `tmc_census.sh`, and the keys of `test/engine_divergence.txt`). Adding,
moving, or deleting one silently enrols you in gates you never named — `grep -rl '<fixture_dir>' test/`
first, then run **all** of them.

---

## Before you measure anything

Read the **`benchmark-emitter`** skill. A binary's *behavior* comes from its source but its *speed*
comes from **the emitter that compiled it**, so you need **two** rebuilds to get a single-generation
binary. One rebuild crosses the arms and makes an optimization look like a regression — a real **2.2×
win once measured as a 2.5× slowdown**.

Same skill covers seed re-mints (`test/refresh_seed.sh` is **not idempotent after a codegen change —
run it TWICE**) and why a **stale seed can SEGFAULT the fixpoint on a perfectly correct change**.
</content>
