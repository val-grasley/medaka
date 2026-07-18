# test/engine_fixtures/ — the prelude-bearing, ENGINES-ONLY fixture corpus

**Status:** ACTIVE

## Why this corpus exists (issue #530, arc #711)

`diff_compiler_engines.sh` runs the **3-engine differential**: `eval == native ==
wasm` on the same program, diffed **against each other** — *"No golden file mediates
anything"* (that gate's header). Its corpus was the union of the four EMITTER
corpora (`llvm_fixtures{,_typed}`, `wasm/fixtures{,_typed}`). Every one of those four
is **also** consumed by a **prelude-FREE probe gate** — `diff_compiler_llvm_typed.sh`
and `diff_compiler_llvm_typed_ir.sh` drive `test/bin/llvm_emit_typed_main` over
`runtime.mdk` **only** (no prelude, scalar mains); `diff_compiler_prelude_obj.sh`,
`diff_wasm*.sh`, etc. read the others the same bare way.

**A fixture corpus is the unit of enrollment.** So a *prelude-bearing* program (one
that reaches an `impl` in `stdlib/core.mdk`, e.g. `impl Ord Float`) cannot be added
to any of those four: it would redden the probe gate that shares the directory. That
is the shared-corpus trap in its load-bearing form — and it is exactly why the
**Float totalOrder wasm arm** (#360/#530) was verified but could not be gate-pinned.

`test/engine_fixtures/` breaks the deadlock: it is wired into
`diff_compiler_engines.sh`'s `CORPUS` union **and consumed by nothing prelude-free**.
A fixture here runs through all three shipping engines with the **full prelude**, and
nothing bare ever reads it.

## What lives here

Prelude-bearing programs whose value depends on the real prelude and that agree
across `eval`/`native`/`wasm`. The seed fixture is `float_totalorder.mdk` (#360
IEEE-754 totalOrder laws). This is the template home the #707/#710 promotion arc
fills with the interpreter-only fixtures it lifts up to the backends.

## How the corpus is wired (do not re-derive — read it here)

`test/diff_compiler_engines.sh`, two edits, nothing else:

1. **key namespace** — the `--one` worker's `case "$f" in` block gets an
   `*/engine_fixtures/*) key="engine/$(basename …)" ;;` arm, placed FIRST. The
   `engine/` prefix keeps basenames from aliasing the other corpora and is the pin
   namespace below.
2. **CORPUS union** — `"$ROOT"/test/engine_fixtures/*.mdk` is appended to the `ls`
   that builds `CORPUS`.

No CI change is needed: the `engines` shard selects the gate by name
(`pattern: 'diff_compiler_engines'` in `.github/workflows/ci.yml`), and this is the
same gate — its corpus simply grew. `diff_compiler_ci_shard_coverage.sh` (gates →
shards) and `diff_compiler_fixture_corpus_coverage.sh` (corpora → gates) both stay
green: no new gate script, and this directory has a live consumer.

## Adding a fixture (the template)

1. Write `test/engine_fixtures/<name>.mdk`. Prefer a **bare VALUE `main`** (e.g.
   `main = [ … ]`); all three engines auto-print it identically (the gate's
   auto-print contract). A `main` that is already `println …` also works.
2. **Platform-independence is mandatory.** The gate builds on x86 AND arm from one
   corpus; never bake a value that differs by target (a NaN's sign bit does — state
   laws relative to an observed `nanLow`, as the seed does).
3. Verify it agrees across all three engines:
   ```sh
   sh test/diff_compiler_engines.sh --one test/engine_fixtures/<name>.mdk   # VERBOSE=1 to print the signature
   ```
   A clean fixture's signature is `eq:eq:eq:ran:ran:ran`.
4. **(Recommended) pin the output value.** Add
   `test/engine_value_pins/engine/<name>.pin` holding the program's **exact stdout,
   byte-for-byte** (`od -c` to verify the trailing newline). This is the ONLY pinned
   artifact allowed here — it is the observable OUTPUT, not a prelude artifact, so it
   moves only on a real semantic change, never on an inert prelude edit. See
   `test/engine_value_pins/README.md` (⚠️ pin only a fixture with NO row in
   `test/engine_divergence.txt`).
5. Run the whole gate once (`MEDAKA_REQUIRE_WASM=1 sh test/diff_compiler_engines.sh`)
   and confirm `checked N` grew by one.

## What must NEVER be added here

No `.golden`, no snapshot, no signature capture — nothing that captures
prelude-derived TEXT and has to be re-blessed on a prelude edit. This corpus exists
precisely to stay on the **live differential + optional output-value pin** side of
that line. If a fixture seems to need a prelude-capturing golden, it does not belong
here. Do not wire this directory into `diff_compiler_llvm_typed*`, `prelude_obj`,
`rt_obj`, or any `diff_wasm*` gate — that would re-impose the prelude-free constraint
this corpus exists to escape.
