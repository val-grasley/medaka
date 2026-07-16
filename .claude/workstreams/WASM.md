# Workstream: WASM (the WasmGC backend)

**Owns:** `compiler/backend/wasm_emit.mdk`, `compiler/backend/wasm_preamble.mdk`, the wasm
gates, **and the three JS host shims** (`test/wasm/run.js`, `playground/worker.js`,
`playground/compile.mjs`) — ⚠️ this line said **two** until 2026-07-16 and the omitted
third is exactly where #543 landed: `compile.mjs` is the seam that runs the COMPILER
(playground.wasm), it holds its own copy of both shared blocks, and because neither this
line nor `diff_compiler_wasm_shim_parity.sh` counted it, #370's fix updated the two
"known" copies and left it on raw `Number()` + missing `mdk_str_to_float_ok` → LinkError,
playground dead. **Derive the set, never trust the count:**
`grep -rln 'BEGIN SHARED SHIM' test/ playground/` — the
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

> ### 🔁 CLOSING AN ISSUE IS NOT DONE UNTIL THE ROWS ASSERTING IT ARE DRAINED — **in the SAME commit**
>
> **This file and `docs/spec/WASM-SEMANTICS.md` drift, and both times we caught it the cause was the
> same: nobody updated them together.** Caught twice in one session, same shape both times: #369 was FIXED while the contract's
> N4 row still read *"✗ CONFIRMED S0"*, and #381 was CLOSED while its Perf-posture row still read
> *"✗ STATIC"*. Both times this file was right and **the contract — the doc this very paragraph calls
> ground truth — was the stale one.**
>
> **Every `#N` in that table is an encoded claim about N's state**, with no derivation and no expiry —
> **#438** tracks that specifically (⚠️ **#383 does NOT**: it is the adjacent wasm stale-claims sweep,
> but its 8 items never name the law table — I cited it here and was wrong, same shape as the #404 I'd
> just cut two lines earlier). So when you close a wasm issue:
> `grep -rn '#<N>' docs/spec/WASM-SEMANTICS.md test/engine_divergence.txt test/ENGINE-DIVERGENCE.md
> test/CAPABILITY-EXCEPTIONS.txt .claude/workstreams/WASM.md` and drain **all** of it in the closing
> commit. *A bug that is stale in three places is invisible in all three.*
>
> ⚠️ **A derived fix is NOT available today, and the obvious one does not work.** *"A gate could parse
> the `**#N**` refs and fail when a cited issue is CLOSED"* is **false** — the table's markup is not a
> state signal, and its own rows disprove it: **bold is used for CLOSED issues** precisely when a row
> announces a fix (`**#369 FIXED** by #388`, `**#381 FIXED** by #401`), while **open** issues appear
> **unbolded** (`the #349–#352 sibling census`, `shipped (#396)`), and some bold spans wrap prose
> around the number rather than the number itself. Sharpest of all: **`#382` appears bolded once and
> unbolded once IN THE SAME ROW.** A naive gate would flag the two rows this session just FIXED and
> silently skip four open ones. **A gate here would need a consistent machine-readable
> format to exist FIRST** — that is the actual prerequisite work, and nobody has done it. Until then
> this rule is enforced by the grep above and by a reviewer, not by CI.

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

## 🔬 THE CLASS: **a probe whose SKIPPED STEP is invisible in its output** (named 2026-07-16)

**Three instances in ONE day, across BOTH backend workstreams.** That is past coincidence — treat it as
a standing hazard whenever you point a probe at anything:

| # | probe | the step it skipped, invisible in its output | what got published |
|---|---|---|---|
| 1 | ws:emitter's `profile_main` backend stages | **`dceFilter` never ran** — the fixtures' `main` rooted nothing, so a real build prunes all N | *"10 s to emit 16000 functions"* — a path that cannot execute |
| 2 | our wasm `gen_match` timing | **the probe PANICKED** (`gen_match` has no `main`); `2>&1 >/dev/null` swallowed it | a real number, but of work-before-a-panic |
| 3 | our llvm `gen_match` **control** | **the same panic** — so the "discriminating test" compared **two panics** | *"llvm is linear (2.02×)"* — false; llvm is super-linear |

**Every one produced a number that looked like evidence** — plausible magnitude, clean ratios,
reproducible. None of them announced what they had skipped. Note #3 especially: **the control was
broken in the same way as the thing it controlled for**, which is the failure a control exists to
prevent, so it pointed the right way *for the wrong reason* and survived review.

**The bar — the only place in the tree that gets this right** is `compiler/entries/wasm_emit_gaps_main.mdk`
(grep `GAP CENSUS`): it skips DCE **deliberately and says so, in the file**. *Skipping a step is fine.
Skipping it silently is the bug.*

**Three defences, in order of strength:**

1. **Run the step inside the instrument.** ws:emitter's #396 runs `dceFilter` *inside* `profile_main`, at
   the same pipeline point as `llvm_emit_modules_main` — the property is **demonstrated**, not argued.
2. **Ship a FALSIFIABILITY CONTROL.** #396's: same fixture, dead root (`main = println 1`) vs live root —
   **0.024 s vs 0.677 s, 28×**. Without one, a fixture "fix" is unfalsifiable, which is the same defect as
   a gate that cannot fail. **This is what separates a fixed measurement from a differently-broken one.**
3. **Assert the probe COMPLETED** — exit 0, expected marker present (`[perf] total`), output **non-empty**.
   Never trust a timing that may have run past a panic. ⚠️ And a byte-diff over **empty** captures is a
   green that proves nothing: #401's first WAT capture had **38 silently-empty** files that would have
   diffed "identical".

**Corollary — the unit of a claim, again.** *"Does the fixture survive DCE?"* is a **per-FIXTURE**
question, not per-probe: `xref` puts the cost in N *unreferenced* decls (DCE prunes all N ⇒ dead
measurement) while `gen_match` concentrates it in ONE function `main` roots (DCE **must** keep it).
Same disease as *"a plural noun is a claim about a SET"* and *"a one-backend fix is a half fix"*: the
general claim was the wrong unit.

---

## ⭐ A new gate must land GREEN — and the perf gate already has the ledger that lets it (2026-07-16)

**A gate cannot land red**: `main` would block the merge queue for every workstream. So how do you land
#359's emit stage while a quadratic it grades is **still live** — as #381's was, measuring **cubic**
against a ~2.0× threshold — without turning `main` red for everyone?

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
- Perf: the emitter is `contains`-over-lists per node, like pre-audit native, plus two shapes
  the audit called **wasm-only** — `ctorOrdinal` re-filters the whole ctor table per construction
  site and per `br_table` slot, and `indent` re-maps subtree lines per nesting level (#381, #382).
  ⚠️ **"wasm-only" was HALF WRONG** (measured, below): `ctorOrdinal`'s scan is **shared with
  `llvm_emit`**; only the *slot × branch nesting* that turns it cubic is wasm's. Gating: the
  **native** emit arm shipped in #396; **the wasm arm of #359 is still open**, so wasm emit remains
  ungated — and the arm must grade **TIME**, since most of these scans allocate nothing (#396's
  own headline: a live quadratic at TIME r2 = 3.96 while the ALLOC arm read a clean linear 2.04
  and called it "ok" — the arm was not broken, it was *right and blind*).
  **⭐ #381 MEASURED, then RE-measured twice — FIXED by #401 (`5d82fa48`). The measurement history is
  the more useful artifact; read it before you measure anything here.**

  Final numbers — **both backends, the perf gate's own `gen_match` shape made DCE-REACHABLE
  (`main = println (toInt C0)`), through the `*_emit_modules_main` probes (which run `dceFilter`,
  i.e. the REAL build path)**, min-of-3, `GC_INITIAL_HEAP_SIZE=512M` pinned, baseline-subtracted,
  load < 1.5:

  | N | llvm net | ratio | wasm net (pre-#401) | ratio |
  |---|---|---|---|---|
  | 200 | 0.0272 s | — | 0.1434 s | — |
  | 400 | 0.0617 s | **2.27×** | 1.1348 s | **7.91×** |
  | 800 | 0.1769 s | **2.87×** | 9.4797 s | **8.35×** |

  linear ≈ 2.0 · quadratic ≈ 4.0 · **cubic ≈ 8.0**. **wasm was CUBIC** (53× llvm at N=800); #401
  took it to **1.90× (linear)** — a 53× win at N=400 — with byte-identical WAT across 200 fixtures.

  **The mechanism, and the part that generalizes:**

  | backend | cost | why |
  |---|---|---|
  | **llvm** | scan O(C) × per-construction-site O(N) = **O(N×C)** → quadratic | `llvm_emit`'s own `ctorOrdinal` has **the same whole-table scan** |
  | **wasm** | same scan × per-**(slot, branch)** nesting O(N×B) = **O(N×B×C)** → cubic | wasm nests slots × branches; llvm does not |

  ⇒ **the scan is SHARED; only the extra nesting factor was wasm's.** #381's original "no llvm twin"
  framing was WRONG — llvm has a *quadratic* twin (ws:emitter measured native `match:emit` at
  **3.71/3.73** over N=1000→4000 — filed with its numbers as **#408**, spun out of #396). #401's memo pattern is a plausible lead for #349–#352 —
  and it was **taken from `llvm_emit`'s `ctorMapRef`/`installCtorMap` in the first place.**

  ### 🔬 Three measurement traps, each of which produced a confidently WRONG published number

  1. **The audit filed it STATIC** (grep-proven, never run). Measuring took ~5 minutes and turned an
     S3 hypothesis into a verified issue. **A grep-proven census names a SHAPE, not a COST.**
  2. **`gen_match` has NO `main`, so the probe PANICS** — and `2>&1 >/dev/null` swallows it, so you
     time work-done-before-a-panic. Worse: reuse that repro for a WAT byte-diff and you get
     **empty-vs-empty = a false "identical"** (#401 hit 38 silently-empty captures). ⚠️ **The
     "discriminating test" above compared llvm vs wasm on the UNROOTED fixture — i.e. two panics —
     and the published "llvm is linear (2.02×)" came from that.** It pointed the right way for the
     wrong reason. **Root the fixture; assert exit 0 and non-empty output.**
  3. **A probe that skips `dceFilter` may time emission a real build never performs.** `wasm_emit_main`
     runs **no DCE**; `wasm_emit_modules_main` does. But **"does it survive DCE?" is a per-FIXTURE
     question, not a per-probe one**: `xref` puts the cost in N *unreferenced* decls (DCE prunes all
     N ⇒ dead measurement), while `gen_match` concentrates it in ONE function `main` roots (DCE
     *must* keep it — proven: the WAT contains `func $dm400__toInt`, 4.29 MB, 79 `br_table`s).
     Best practice, from ws:emitter (#396): run `dceFilter` **inside** the profiler, and ship a
     **dead-vs-rooted falsifiability control** (they measured **28×**) — without one, a fixture
     change is unfalsifiable.

  **And: a scaling ratio is NOT a constant.** Our llvm reading climbed 2.27 → 2.87 over N=200→800;
  ws:emitter's read 3.71 at N=1000→4000. Same curve, different N. **Quoting a ratio without its N
  band is an under-specified claim** — both workstreams did it on the same day.

### ⭐ The debunkings are findings too — do NOT re-file these

- **Poly-Num Float arithmetic WORKS on wasm** (`sq x = x*x; sq 2.5` → `6.25`, probe-run
  2026-07-16). The long-standing framing "wasm has NO dict-dispatched arithmetic path"
  (SHARED-FLOAT-RESIDUAL-DESIGN §4) describes the PRE-2026-06-30 state; approach A
  (`8afc613`) added the runtime value-dispatch helpers. Anything citing that framing as
  current is stale.
- **Poly Float `%` on wasm agrees with EVAL** (`1e300 % 3.0` → `0.0` on both); NATIVE is
  the odd engine out there (#345). Wasm did not copy the native trunc-cast bug.
- ~~**The float formatter three-copy law (N9) HOLDS where probed**: `mdk_float_lexeme` vs
  the two JS copies … Only the comments are stale (`%.12g`)~~ — ⚠️ **THIS ENTRY WAS WRONG,
  and its own name says why: the law is THREE-copy and the probe checked TWO** (`run.js`,
  `worker.js`). The third, `playground/compile.mjs`, was still running the pre-#361 `%.12g`
  formatter *in code* (`toExponential(11)`, i.e. 12 significant digits) — so "only the
  comments are stale" was false of the copy nobody looked at, and the playground's emitted
  float literals were truncated. Found + fixed 2026-07-16 (#543); all three are now byte-
  identical and `diff_compiler_wasm_shim_parity.sh` covers the full set.
  **A disproof inherits the scope of its probe.** This entry read as a probe-run fact (the
  ledger's own bar) and was — for a SUBSET it never named. *"VERIFY THE SET, NOT A SAMPLE"*
  failing inside the ledger that teaches it.
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
  `nan`, `nan`, `1.0`, `1.0`, probe-run) — the N6 interim bar holds there. The HOF-routed
  `<=`/`>=` NaN defect (#305) is **FIXED** by #484 (`849e0d4b`).

  For N6's **current** status (`compare`/`min`/`max`/`sort` at NaN → totalOrder, #360) read
  **`WASM-SEMANTICS`'s N6 row — do not restate it here.** This entry used to, and it went stale
  the day it was written. Two prior fix PRs (**#388**, **#401**) did not keep that row in sync
  unprompted and it needed manual sweeps (#390, #409) — **no workstream ledger has a drain rule
  that reaches it (#488)**, so the fix is to keep ONE copy, not to bet on which is current.

  > **Rule of thumb for this ledger:** record what was **DISPROVED** (probe-run facts, which don't
  > expire) and **commit SHAs** (immutable on protected `main`). Avoid restating an **open** issue's
  > status — it expires the moment someone finishes the work. A **closed** issue's resolution is
  > usually safe but not guaranteed: **#315** was closed and **reopened 17 minutes later** ("*it is
  > NOT fixed*").

## Before you measure anything

Read the **`benchmark-emitter`** skill. A binary's *behavior* comes from its source but its *speed*
comes from **the emitter that compiled it**, so you need **two** rebuilds to get a single-generation
binary. One rebuild crosses the arms and makes an optimization look like a regression — a real **2.2×
win once measured as a 2.5× slowdown**.

Same skill covers seed re-mints (`test/refresh_seed.sh` is **not idempotent after a codegen change —
run it TWICE**) and why a **stale seed can SEGFAULT the fixpoint on a perfectly correct change**.
</content>
