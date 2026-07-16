# Workstream: WASM (the WasmGC backend)

**Owns:** `compiler/backend/wasm_emit.mdk`, `compiler/backend/wasm_preamble.mdk`, the wasm
gates, **and the two JS host shims** (`test/wasm/run.js`, `playground/worker.js`) — the
2026-07-16 conformance audit made the shims first-class: parts of the observable semantics
(float formatting, string→float parsing, exit, the whole IO surface) execute in JS, so a
shim edit is a semantics edit.
**Touches:** `compiler/backend/wasm_emit.mdk`, `test/wasm/`, `playground/`.

```sh
gh issue list --label "ws:wasm" --state open   # the backlog. #384 is the tracking issue + DAG.
```

**The contract:** `docs/spec/EMITTER-SEMANTICS.md` (shared laws — wasm is the peer
refinement) + `docs/spec/WASM-SEMANTICS.md` (the wasm supplement: WP physical-encoding
laws, WH host-boundary laws, the host-import inventory, and the law-by-law conformance
table with issue refs). A ✗ behavior not in that table, `test/engine_divergence.txt`, or
an open issue is an unfiled finding.

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

## State of the ledgers (2026-07-16, post-audit)

- The 2026-07-14 re-verification issues **#60 and #71 are CLOSED** — every surviving
  `wasm:*` row in `test/engine_divergence.txt` passed the discriminating test on the
  shipping CLI. The survivors now have trackers: `char_max`/`char_min` → **#373**;
  `match_str_lit`/`match_char_lit`/`match_str_default` → **#374**; the recursive-let /
  refutable-guard / range-pattern rows → **#379**; `dict_overlap_minspec` → **#324**.
  Fixing any of them self-drains its rows (the gate detects the accidental fix).
- **`CAPABILITY-EXCEPTIONS` wasm rows**: 13 PERMANENT (raw BSD sockets have no WasmGC
  equivalent — *"the honest, by-design gap in the whole matrix"* — plus run-stdout plumbing
  and build fingerprint), ~18 WASM-GAP (perf clocks, file/env residual), 1 TODO. ⚠ The
  2 TRAP-STUB rows (`intMinBound`/`intMaxBound`) are **STALE** — fixed 2026-07-14, and the
  gate hardcodes the trap list so it cannot self-drain → **#383**.
- `test/ENGINE-DIVERGENCE.md` §3.2's seven-bug table is also stale (five dissolved) → **#383**.

**Fixture corpora are SHARED.** `test/wasm/fixtures/` has **four** consumers (`diff_wasm.sh`,
`diff_compiler_engines.sh`, `tmc_census.sh`, and the keys of `test/engine_divergence.txt`). Adding,
moving, or deleting one silently enrols you in gates you never named — `grep -rl '<fixture_dir>' test/`
first, then run **all** of them.

---

## The 2026-07-16 founding audit — what is broken, what was DISPROVED

Three parallel static passes + 26 binary probes at `be6159f3` (method: the discriminating
test, every candidate through native build AND wasm build AND `medaka run`). The DAG is
**#384**; the per-law status lives in `docs/spec/WASM-SEMANTICS.md` §4. Headlines:

- **Int on wasm never truncates to 63 bits** (#368, S0): the boxed-int cell is a raw i64,
  so `intMaxBound + 1` is a positive number no other engine can produce, and i64
  `INT_MIN / (−1)` engine-traps. One box-seam renormalization fixes the class.
- **Float `%` is a rounded f64 formula, not fmod** (#369, S0): `1.0e17 % 3.0` → `0.0`
  (eval+native `1.0`), both inline and poly paths.
- **The host shims diverge from the C oracle**: `stringToFloat` runs on JS Number()
  semantics (`""` → `Some 0.0`; #370, S0); `exit` drops buffered stderr in run.js (#376);
  `playground/worker.js` is missing the write-file import trio → raw LinkError instead of
  the friendly capability error (#375).
- **`charCode charMaxBound` prints 2228223** — the bound CONSTANTS are native tagged
  words, so comparisons against them are silently wrong too (#373, S0).
- **String/char-literal match heads emit an INVALID module** (#374) — the R4 "third
  disposition": only `wasm-tools validate` makes it loud, and it names a func index, not
  a construct. Param-position string matches are fine; the literal-scrutinee shape breaks.
- Identity: `dictTag` is 30-bit djb2 with no collision check (#377); `gname` has
  enumerable injectivity punctures (#378 — land its collision check WITH or BEFORE #324's
  sanitizer, or a loud invalid-id failure becomes silent aliasing).
- Perf: the emitter is `contains`-over-lists per node, like pre-audit native, plus two
  wasm-only shapes — `ctorOrdinal` re-filters the whole ctor table per construction site
  and per `br_table` slot, and `indent` re-maps subtree lines per nesting level (#381,
  #382). NOTHING gates it: `diff_compiler_perf_scaling.sh` has no emit stage (#359), and
  most of these scans allocate nothing, so the arm must grade TIME.

### ⭐ The debunkings are findings too — do NOT re-file these

- **Poly-Num Float arithmetic WORKS on wasm** (`sq x = x*x; sq 2.5` → `6.25`, probe-run
  2026-07-16). The long-standing framing "wasm has NO dict-dispatched arithmetic path"
  (SHARED-FLOAT-RESIDUAL-DESIGN §4) describes the PRE-2026-06-30 state; approach A
  (`8afc613`) added the runtime value-dispatch helpers. Anything citing that framing as
  current is stale.
- **Poly Float `%` on wasm agrees with EVAL** (`1e300 % 3.0` → `0.0` on both); NATIVE is
  the odd engine out there (#345). Wasm did not copy the native trunc-cast bug.
- **The float formatter three-copy law (N9) HOLDS where probed**: `mdk_float_lexeme` vs
  the two JS copies, element-by-element review + a 22-case battery (−0.0, denormals,
  3-digit exponents, 17-digit shortest) — byte-identical. Only the comments are stale
  (`%.12g`; #383, closes #361's wasm item).
- **`intMinBound`/`intMaxBound` work on wasm** (fixed 2026-07-14); the TRAP-STUB rows in
  `test/CAPABILITY-EXCEPTIONS.txt` are stale, and the capability gate HARDCODES that
  trap list instead of deriving it, which is why nothing self-drained (#383).
- **Trap-code parity holds where traps are coded**: E-DIV-ZERO / E-MOD-ZERO /
  E-INDEX-OOB / E-NONEXHAUSTIVE-MATCH byte-match native, stdout flushed first, exit 1.
- **Emission is deterministic** (byte-identical rebuild probe) and **WAT text building is
  NOT quadratic** (prepend + one join — the native pattern).
- **No `fallthroughLabelRef` sibling exists** — wasm threads the fallthrough target in
  the node (`labelFallthrough`), which is WHY wasm never had the refutable-guard
  miscompile. The reference design, per EMITTER-SEMANTICS.
- **The playground does NOT reuse compiler instances across compiles** (fresh
  instantiate per run, module-level Refs reborn) — no stale-Ref-across-programs hazard
  there today. The LATENT cousin: `emitProgram` never resets a handful of install-once
  Refs and there is no disable for the census-mode gap flag; process-per-emit masks it.
- **`$boxint` equality/compare through a poly HOF is by VALUE** (no ref-identity bug).
- **NaN `compare`/`min`/`max` are engine-UNIFORM today** (all three engines: `Eq`,
  `nan`, `nan`, `1.0`, `1.0`) — the N6 interim bar holds there; the live NaN defect is
  the HOF-routed `<=`/`>=` path (#305, native+wasm in lockstep, eval correct).

## Before you measure anything

Read the **`benchmark-emitter`** skill. A binary's *behavior* comes from its source but its *speed*
comes from **the emitter that compiled it**, so you need **two** rebuilds to get a single-generation
binary. One rebuild crosses the arms and makes an optimization look like a regression — a real **2.2×
win once measured as a 2.5× slowdown**.

Same skill covers seed re-mints (`test/refresh_seed.sh` is **not idempotent after a codegen change —
run it TWICE**) and why a **stale seed can SEGFAULT the fixpoint on a perfectly correct change**.
</content>
