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

## 🚧 The boundary with ws:emitter — draw it at SEMANTICS vs BACKEND-INTERNAL

**Not at "wasm files" vs "llvm files".** That is the load-bearing rule when the two workstreams run
as parallel sessions, and it falls out of the gates: `diff_compiler_engines` (eval == native == wasm),
`diff_compiler_tmc_parity`, and `diff_compiler_capability_matrix` force the backends to **agree on
every merge**. So a change that moves only ONE backend's OUTPUT turns the engines gate RED ⇒ **any
cross-backend SEMANTICS change is ATOMIC: one PR touching both backends.**

| | |
|---|---|
| **ws:wasm (ours)** | `wasm_emit.mdk` / `wasm_preamble.mdk` internals; the JS host shims (`test/wasm/run.js`, `playground/worker.js`). Bringing wasm into line with **already-decided** native semantics. Wasm-only gaps, quadratics, and identity/tag-collision hardening. These make the gates GREENER and never touch LLVM. |
| **ws:emitter (theirs)** | `llvm_emit.mdk`, `emit_support.mdk`, `private_mangle.mdk`, `trmc_analysis.mdk`, `runtime/medaka_rt.c`, **and the seed**. Cross-backend semantics *still being decided* — the wasm arm folds into THEIR atomic PR. |
| **SHARED — coordinate first** | `core_ir*.mdk` (#353 carries scalar/LTy facts; #382 has a `cexprIsFloat` angle on the same fact). `test/wasm/fixtures/`, `test/engine_divergence.txt`, the differential gates, and `compiler/entries/profile_main.mdk` + `TIME_STAGES` (#359 has one arm per workstream). |

**A wasm change NEVER re-mints the seed** — the seed is the LLVM emitter. Any doc saying otherwise is
wrong. `wasm_emit` is also **outside the fixpoint closure**, which is what makes wasm perf work cheap
to gate.

If you find a cross-backend **divergence** (wasm output ≠ native on a program both accept), **FILE it
and tag ws:emitter on #362 — do not fix the wasm arm solo.** A one-backend fix to a shared semantic is
a half fix (below), and it either opens a divergence or collides with an in-flight semantics PR.
Before entering `wasm_emit.mdk`/`wasm_preamble.mdk`, `gh pr list --state open` and check no ws:emitter
semantics PR is in those files.

---

## ⭐ A new gate must land GREEN — and the perf gate already has the ledger that lets it (2026-07-16)

**A gate cannot land red**: `main` would block the merge queue for every workstream. So how do you land
#359's emit stage while #381's quadratic is still live and measuring **5.3×** against a ~2.0× threshold?

**Two ways, and the second is the one to reach for:**

1. **Fix → gate.** Land the fix first, then the stage lands green trivially.
2. **Gate → fix, with a SELF-DRAINING ledger entry.** `test/diff_compiler_perf_scaling.sh` already has
   this built in and it is the repo's own idiom. Grep it for **`KNOWN_SLOW_TIME`**, **`is_known_time`**,
   and the per-`shape:stage` **`KNOWN_TCEIL_*` / `KNOWN_TFIXED_*`** ceilings. A ledgered stage is graded
   against **its ceiling**, not the clean-tree threshold — so it lands **green on a dirty tree** — and
   fails if the stage gets *worse*. **Crucially it also FAILS when the bug is FIXED** (grep **`PROMOTE`**:
   *"now too FAST to time-gate … Remove `<shape>:<stage>` from KNOWN_SLOW_TIME — the bug is FIXED"*),
   which is what makes it **drain instead of rot**. Proof it drains in service: the `match:typecheck`
   entry went out with **#117**'s 58× union-find fix (that PR's body: *"Both entries then drained"*).

**⇒ #384's "enforcement first" DAG IS executable as written.** Option 2 is strictly better when the fix
is not already in hand: the gate exists *before* the fix, so the fix's own landing is what trips the
PROMOTE detector — **the gate proves the fix rather than the author's prose.** Same for #359's native arm
against #349–#352.

**The worked example is #396** (ws:emitter, **open at time of writing**), and it is the strongest
evidence in this file for grading TIME: wiring `lower`+`emit` into the detector **immediately caught a
live native quadratic** — `xref:emit` at r2 = **3.96** — *while the ALLOC arm read a clean linear
**2.04** and called it "ok"*. It lands **green on a dirty tree** by ledgering `xref:emit` at a ceiling,
without widening `THRESH`. That is the #110/#115 thesis reproduced live: **a pure scan allocates
nothing, so only TIME can see it** — the ALLOC arm was not broken, it was *right and blind*.
Our own #381 replicated it on the wasm arm the same day. **Both were STATIC audit findings until
someone measured them** — a grep-proven census names a *shape*, not a *cost*.

> **How this section got here is the lesson.** It first asserted the DAG was *"not executable"* and that
> *"gate-first only works on an already-clean tree"* — a categorical rule, derived from reading ONE line
> (`TIME_STAGES`) and never reading the `KNOWN_SLOW_TIME` ledger a little further down the same file.
> **An independent reviewer killed it.** That is this repo's #1 lesson (*"reproduce before you trust"*)
> pointed at a **gate** instead of a bug: a static read named a mechanism, not its behavior — the same
> error as filing #381 STATIC and never measuring it. **Read the gate before you claim what it does, and
> never let a plan you like become a rule in a doc without one adversarial pass over it.**
>
> **Coda — this section cited LINE NUMBERS twice, and was wrong twice.** Draft 1 cited
> `TIME_STAGES:453`, copied verbatim from #359's body where it had *already* drifted. Draft 2 "fixed" it
> to `:497` and cited five ranges in the ledger — then **#396 turned up carrying +102/-4 on that same
> file**, moving every one of them, plus an `xref:emit` entry that falsifies draft 2's *"`KNOWN_SLOW_TIME`
> is empty today"* the moment it merges. Both drafts landed inside one session.
>
> **So this section now cites SYMBOLS (`KNOWN_SLOW_TIME`, `is_known_time`, `PROMOTE`), not lines** — they
> are greppable and they survive edits. **A line number is an encoded fact with no derivation and no
> expiry; a symbol name is a query.**
>
> ⚠️ **But do NOT assume a gate is checking them.** `agent-doc-symbols` extracts only **mixed-case**
> tokens and resolves them against **`compiler/*.mdk` + `stdlib/*.mdk` + `runtime/*.c`** — so
> `KNOWN_SLOW_TIME` (all caps), `is_known_time`/`gen_match` (all lower), and anything in `test/*.sh` are
> **all outside its corpus**. None of this section's symbols are gate-checked. `docs-links` checks paths;
> `agent-doc-symbols` checks mixed-case symbols in compiler/stdlib. **A false claim *about behavior*, a
> stale `:NNN` in prose, and a wrong statement about a sibling PR's state are invisible to both.**
> **Prose about behavior is the UNGATED surface — the control there is an adversarial reviewer, not a
> gate.** Three of this section's four defects were caught by a reviewer; zero by CI.

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
- ~~**Float `%` is a rounded f64 formula, not fmod** (#369, S0)~~ — **CLOSED 2026-07-16, fixed by
  #388** (`53f63fbd`), which landed N4 as one cross-engine semantics: `$mdk_float_rem` is now the
  exact libm power-of-two reduction (`wasm_preamble.mdk:1024-1046`) and `$mdk_value_mod`'s Float arm
  routes to it (`:730-734`), so **both** paths this bug named are fixed. Re-verified with 36 probes
  (2 paths × 6 cases × 3 engines): eval == native == wasm, incl. `1.0e17 % 3.0` → `1.0` and
  `1.0e300 % 1.0e-300` (~2000 down-walk iterations, still bit-exact vs C fmod). Pinned by
  `test/wasm/fixtures/polynum_mod_float{,_large,_neg}.mdk`. **Closing as already-fixed is a success —
  the sibling's #345 fix reached the wasm arm because it was landed atomically.**
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
  **⭐ #381 MEASURED 2026-07-16 (was STATIC) — it is WORSE than quadratic (~N^2.4).** Via the
  discriminating test on the perf gate's own `gen_match` shape (grep `gen_match` in
  `test/diff_compiler_perf_scaling.sh`: one data decl with N ctors + one N-arm match),
  min-of-3, `GC_INITIAL_HEAP_SIZE=512M` pinned:

  | N | `wasm_emit_main` | ratio | `llvm_emit_main` | ratio |
  |---|---|---|---|---|
  | 100 | 0.0402 s | 2.58× | 0.0145 s | 1.89× |
  | 200 | 0.2456 s | 6.11× | 0.0164 s | 1.13× |
  | 400 | 1.3019 s | **5.30×** | 0.0332 s | 2.02× |

  Linear ≈ 2.0×/doubling, quadratic ≈ 4.0×. **llvm holds linear; wasm is ~N^2.4 and 39× slower at
  N=400** ⇒ a genuine wasm-only gap, not a corpus artifact. **The audit's perf pass was grep-proven
  but never measured — measuring took ~5 minutes and turned an S3 hypothesis into a verified one with
  a repro.** Do that before spawning any perf fix: a static census names a shape, not a cost.

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
