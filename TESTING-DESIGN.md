# TESTING-DESIGN.md — a coherent testing architecture for Medaka

Status: **partially built**, 2026-07-13. §§1–3 are the diagnosis + research (unchanged).
§4.4 (the differential tier) and the capability gate ARE BUILT and merged on
`testing-arc`. §4.3/§4.6/§4.7 (the snapshot migration) are **not started** — the 79
bash gates are all still there.

---

## 0. AS-BUILT — what actually shipped, and what it found

Suite went from **"78 passed, 0 failed, 1 skipped — fully green"** to **84 passed, 0
failed, 0 skipped**, over a *larger* corpus. The "skip" had **never run once**. The
repo is now public (Apache-2.0) with CI green on `main` — the first automated,
authoritative signal on the default branch in the project's history.

### 0.0 The one-sentence version

> **The recurring bug in this codebase is not in the compiler. It is that
> *"this didn't run"* is indistinguishable from *"this passed."***

It appeared as: a missing oracle exiting 2 = SKIP ≠ FAIL (a fresh clone ran **zero
tests and printed "0 failed"**); a gate `dash` could not even *parse*, "skipped" for
months **while also failing**; `test/ported/`'s 323 assertions run by nothing and
rotted; `$ROOT/compiler/*.mdk` globbing to zero files after the subfolder reorg, so
the compiler's own sources silently left the corpus; a `norm()` erasing floats from
**both sides** of a comparison; a gate matching **no CI shard**; an unreadable
snapshot target rendering as `# CRASH: cannot read fixture` and then *passing forever*;
and the **seed silently stale on `main`** with nothing watching. Every new gate here is
built to fail loudly on *silence*, and every exception list must detect an **accidental
fix** — because a list that only suppresses failures rots, which is how `test/ported/`
died.

### 0.0.1 Six quadratics, found by building the perf gate

Agents kept introducing O(n²) algorithms and nothing was watching. Designing the
detector found six *before a line of it was written*:

| site | |
|---|---|
| `resolve` `contigGo` | a `closed` list **rebuilt per decl** (`acc ++ [x]` in a fold is O(n²) by itself). Stubbing it dropped resolve 114 MB → 3.2 MB — it *was* the stage. |
| `typecheck` × 5 | `reqObligationsFor` re-derived a flatMap over **every decl, per obligation**; `normalize` rebuilt a `TVar` cell just to read its root; three global lists had their **length measured per group**. |
| `exhaust` `groupByName` | quadratic **twice over** — and `check` ran it **twice**. |
| CLI `userSchemeLines` | an `anyList` over every name **per dump line** (~8.5M string builds at 2k fns). |

**`medaka check` on 2,000 top-level fns: 17.6s → 1.3s. Growth 3.88× → 2.12× (linear).**
`typecheck_compiler_source`: 35.7s → 7.6s.

**Every one was the same shape: a `List` scanned / `elem`-checked / rebuilt once per
element.** And the gate that catches them measures **allocation, not wall-clock** — GC
bytes are *deterministic*, so the gate is machine-independent **and** noise-free, which
no timing gate can be on a shared CI runner.

⚠️ **An unprofiled stage is an unprofilable bug.** `checkGuardExhaustiveness` is a
standalone pre-desugar pass, so it was in no stage table and no profiler — which is
*exactly* why a quadratic hid there, and why `medaka check` was 2.3s slower than the
sum of every profiled stage.

### 0.0.2 The friction rule out-earned the tasks

Every agent prompt now demands: *"surface every bug, gap, pain point, workaround,
misleading error — **even if you worked around it**."* Agents are extremely good at
routing around problems and never mentioning them, and everything they route around is
a bug the user hits later. It produced, in one night:

- **`SYNTAX.md` was lying.** It advertised `import … as` aliasing. Reality: `import list
  as L` **parsed, typechecked, and silently no-opped** — the alias was unbound. A feature
  that does nothing and warns about nothing. *That* is why `snap_wasm.mdk` existed:
  `llvm_emit` and `wasm_emit` both export `emitProgram` and there was no way to
  disambiguate. **(FIXED 2026-07-13: aliasing is implemented — `import m as A` and
  `import m.{a as b}` — and `snap_wasm.mdk` is deleted, which was the acceptance test.
  Every form that is NOT supported is now a real parse error, never a silent no-op.)**
- The profiler blind spot above.
- `build_oracles --build-one` not `mkdir`-ing `test/bin`, killing fresh worktrees with a
  doubly-misleading error. Two agents lost time to it.
- `run_gates` printing a bare **"63 failed"** on a fresh worktree — correct, but reads as
  catastrophe. Now it says *"NOT a compiler regression; you have no oracles; run this."*

---

### 0.1 (historical) The first landing

| Commit | |
|---|---|
| `e0b7e895` | 2 silent-green harness bugs; `test/ported/` un-orphaned; `make test` |
| `cc1a5fb3` | `/tmp` concurrent-build IR collision |
| `2713ecfc` | capability-coverage gate (§0.2) |
| `d1ac42ae` | tri-engine differential gate (§4.4) |
| `86dfbc84` | `array.mdk` sort naming |
| `e38654b3` | effect-polymorphic `Value` — `medaka run` can do I/O |
| `5a8ceb72` | the gate that never ran (§0.3) |

### 0.1 The thesis held: the gate found bugs on its first run

**§4.4 predicted the three engines would disagree, and they did — 22 fixtures.**

- **The interpreter's RNG/hash diverge from both backends** (15 fixtures).
  `setSeed 42; randomInt 1 6` → **4** under `run`, **2** under `build`. Root cause is
  *not* "unimplemented": `eval.mdk` deliberately installs an LCG, justified in a
  comment for **prop generation** (where any RNG is fine). But `setSeed`/`randomInt`/
  `hash*` are *also user-facing externs* with a byte-identical contract. **A scoped
  shortcut escaped its scope.**
- **5 genuine WasmGC codegen bugs** (7 fixtures) — `charCode` leaks the i31 tag
  (`char_max` → 2228223 = 2·1114111+1); an *unsignatured* float fn traps.
- **`medaka run` could not do I/O at all** — 37 externs declared, implemented in C
  *and* wasm, absent from eval. Even `Array.fill` — pure, no effect row, called by
  `stdlib/array.mdk:282` — panicked under `run` and worked under `build`.
- **6 silently-fabricated constants** (worse than the panics, because silent):
  `wallTimeSec` = hardcoded `1700000000.0`; `monotonicSec` = `1000.0`, so **every
  elapsed measurement under `medaka run` is exactly `0.0`**; `sleepMs` = no-op;
  **`ePutStr`/`ePutStrLn` = discard, so `medaka run` silently eats ALL stderr.**
- **A concurrent-build corruption**, found as collateral damage while *building* the
  harness: `build_cmd.mdk` keyed its scratch IR on the output **basename** in global
  `/tmp`, so two `medaka build … -o out` linked each other's IR. Measured **19/20
  wrong** under contention — and it produced *working binaries that print the wrong
  answer*. AGENTS.md had asserted this path was race-safe since July.

Root cause of the whole family: **`eval.mdk` was written as a value oracle** — it only
ever compared a computed `main` value, so effects were deliberately out of scope. When
the OCaml compiler was deleted (2026-06-26), that oracle was **silently promoted to be
the production `medaka run` engine** and its contract was never re-litigated. Its own
header still says *"eval.mdk runs on the OCaml reference … IO externs are out of
scope."* Both halves are now false.

### 0.2 The gate whose absence caused it

Nothing in `test/` referenced eval's `externBindings`. `test/diff_compiler_capability_matrix.sh`
now builds a 3-column matrix over the 134-extern catalog and fails on **silent
omission**, on **drift**, *and* on **accidental fix**. Current state:

| Engine | Implements | |
|---|---|---|
| LLVM | **131 / 134** | 2 dead, 1 TODO |
| Interpreter | **98 / 134** | 36 BUG + 6 frozen-constant |
| WasmGC | **74 / 134** | 10 permanent (BSD sockets), **45 unported**, 5 other |

The wasm number was a complete surprise: **the second backend implements barely half
the primitive catalog**, and nobody was tracking it.

### 0.3 The suite was lying, twice

1. **`diff_compiler_lint_multi.sh` had never run — once.** It declares `#!/bin/sh` but
   uses bash process substitution; `run_gates.sh` invokes gates with `sh` (dash); it
   died `Syntax error: "(" unexpected` → **exit 2** → the old runner called that a
   SKIP. It is the "1 skipped" in *"78/0/1 — fully green."* And it wasn't merely idle:
   run it and it **fails** — its golden had rotted (a lint message was reworded) because
   nothing was ever comparing against it.
2. **A fresh clone ran zero tests and printed "0 failed."** `test/bin/` isn't committed;
   a missing oracle exited 2 = SKIP ≠ FAIL.

Both are the same bug — **exit-2-means-skip** — and both are fixed. A non-toolchain
exit-2 is now a FAILURE, and the runner hard-fails if 0 gates passed.

### 0.4 Corrections to this document's own predictions

- **B2 does NOT force a seed re-mint.** Predicted it would; it doesn't. The seed is
  minted from the *emitter's* graph (`llvm_emit_modules_main`), and the emitter does not
  import `eval`. `bootstrap_from_seed` stayed green byte-for-byte.
- **The `<Mut>`-only interpreter was NOT a playground constraint.** The playground
  compiles to wasm and never executes the interpreter. It was oracle inertia (§0.1).
- **Effect-polymorphic `Value` did NOT cascade.** The feared "Scheme vs Unit"
  generalization sharp edge never fired: `typecheck_compiler_source` reports 0 errors,
  fixpoint C3a/C3b byte-identical, 15/15 eval oracle gates green. The oracle now
  instantiates `e := <Mut>` and its purity is a **type-level guarantee**.

---

## Original proposal follows.

---

## 1. Where we are

Measured on `main` @ `c0dce033`:

| | |
|---|---|
| Shell scripts in `test/` | **115** (~10,000 lines) |
| …that share a helper library | **0** |
| `diff_compiler_*.sh` snapshot gates | **79** |
| Probe entry points (`compiler/entries/*.mdk`) | **70** |
| Compiled oracle binaries (`test/bin/*`) | 53, none committed |
| Fixture / golden directories | **69** |
| `strip_unit()` definitions, copy-pasted | **59**, in **9 non-equivalent variants** |
| In-language assertions (`test "…"`) | **327** — of which **323 are orphaned** |
| CI | **none** — no `.github/`, no `make test` |

The suite works. It is also held together by convention, repetition, and tribal
knowledge, and it has faults that compound.

---

## 2. Diagnosis

### 2.1 The gates are snapshot tests wearing a differential costume

`diff_compiler_*.sh` was built to diff the native compiler against a **trusted OCaml
oracle**. That oracle was **deleted on 2026-06-26**. `capture_goldens.sh` says so in
its own header:

> the goldens are now checked-in NATIVE output, re-captured from the native
> `test/bin/*` stage binaries; **there is no external oracle to disagree with**.

So 79 of the ~94 test scripts now do exactly one thing: *run a stage, compare stdout
to a checked-in file*. That is **snapshot (expect) testing** — hand-rolled 79 times,
in bash, under a name that no longer describes it. Everything downstream (the probe
binaries, the oracle build, the capture ritual) is scaffolding for a comparison that
is four lines of code.

Only ~15 scripts are *genuinely* differential or metamorphic, and those are the ones
worth keeping and **growing**: `bootstrap_*.sh`, `selfcompile_*.sh` (IR byte-identity
fixpoint), `fuzz_diff.sh`, `diff_compiler_run_check_agreement.sh`.

### 2.2 The probe-binary layer exists only because the driver is bash

`compiler/entries/*.mdk` (70 files) + `test/bin/*` (53 binaries) + `build_oracles.sh`
(188 lines, ~34s) exist for one reason: **bash cannot call a function, only spawn a
process.** Every stage therefore needs a `main` wrapper compiled to its own
executable. A driver written in Medaka calls the stages directly — this is proven
(§4.3), and it deletes the entire layer as a side effect.

### 2.3 Three ways the suite reports green while testing nothing

All three are live on `main` today.

1. **Stale oracles are invisible.** `build_oracles.sh:150` decides staleness with
   `find "$ROOT/compiler" -name '*.mdk'`. It never looks at `stdlib/` or
   `runtime/medaka_rt.c` — both linked into every oracle. Edit the stdlib and all 79
   gates run **last week's compiler** and pass. (`FORCE=1` is the only escape, which
   is why every doc says "always `FORCE=1`" — a documented workaround for a one-line
   bug.)

2. **An unbuilt suite reports "0 failed".** A gate with no oracle exits 2;
   `run_gates.sh` counts exit-2 as SKIP, and SKIP is not FAIL. `test/bin/` is not
   committed, so in a **fresh clone or worktree** the full suite runs zero tests and
   prints `0 failed`. (Verified: `test/bin/` is empty in this worktree.)

3. **`strip_unit` is 9 different functions.** The two dominant bodies disagree:
   `sed '$ s/()$//; ${/^$/d;}'` strips a trailing `()` off the last line *even when it
   has other content*; `sed '${/^()$/d;}'` only deletes a line that is exactly `()`.
   A golden captured under one and checked under the other silently diverges.
   `capture_goldens.sh --frozen` bakes in a **third**.

Add: `capture_goldens.sh` has decayed to **2 live rows**, ~20 golden families marked
FROZEN with **no documented regeneration path**; `diff_compiler_selfproc.sh` hardcodes
its module list, so a new compiler module is silently dropped from the check.

### 2.4 The in-language suite already exists — and rotted, because nothing runs it

`medaka test` already supports doctests (`-- > expr`, 240 examples), property tests
(`prop "n" (x : Int) = …`, 100 runs, shrinking, 108 props), and unit tests
(`test "n" = <Expectation>`, with `stdlib/test.mdk`).

`test/ported/` holds **323 `test "…"` assertions** — the old OCaml alcotest suites,
faithfully ported. **No gate, Makefile target, or hook runs them.** So they rotted:

```
test_eval_ported.mdk    → 202/202 passed        ✅
test_run_ported.mdk     → E-PANIC: parse error  ❌  (uses `let mut`, removed by P0-5)
test_loader_ported.mdk  → E-PANIC: unsupported node ❌
```

Two-thirds of the Medaka-native suite is dead and nothing noticed.

### 2.5 Doctests are doing a job they shouldn't

Doctests are the *de facto* stdlib test suite. Wrong tier: a doctest's audience is a
**reader**, and coverage-driven doctests degrade docs (edge cases, error paths, and
regression minutiae are noise in an API example). Props and `test "…"` should carry
coverage; doctests should carry *illustration* — and still execute, because a doc
example that lies is worse than no example.

---

## 3. What other compilers do

| Project | Compiler in | Self-hosted | Compiler tests in own language | Bless mechanism |
|---|---|---|---|---|
| **Roc** | Zig (rewritten 2025) | ❌ | n/a (host ≠ target) | **regenerate-all is the default**; CI gate = `git diff --exit-code` |
| **Zig** | Zig | ✅ | ✅ behavior tests | **none for error text — deliberately hand-written** |
| **Rust** | Rust | ✅ | ✅ (but tests are golden-diff) | `./x test --bless` + redundant hand-written `//~ ERROR` |
| **Lean 4** | Lean | ✅ | ✅ `#guard_msgs` | editor code action ("Update `#guard_msgs`") |
| **Idris 2** | Idris | ✅ | ✅ `Test.Golden` shipped as a library | `--interactive` offers to update |
| **GHC** | Haskell | ✅ | ❌ driver is Python | `hadrian/build test -a` |
| **OCaml** | OCaml | ✅ | ❌ file-diff based | `make promote TEST=… \| DIR=…` — **no whole-suite promote, on purpose** |
| **Elm** | Haskell | ✅ | ❌ | **no test suite at all** — deleted 2018, never restored |

### 3.1 The load-bearing findings

**Roc's snapshot format: one fixture, all stages, in Markdown.** 1,188 files, each
one program with a section per stage — `META`, `SOURCE`, `EXPECTED`, `PROBLEMS`,
`TOKENS`, `PARSE`, `FORMATTED`, `CANONICALIZE`, `TYPES`, `OUTPUT`, `MONO`. A
typecheck change produces a diff **confined to the `# TYPES` sections**. `FORMATTED:
NO CHANGE` asserts formatter idempotence in all 1,188 fixtures for free. Regenerate
with `zig build run-snapshot-tool`; the CI gate is literally
`git diff --exit-code test/snapshots`. **Bless is the default action; git is the
golden store; there is no separate capture step to forget.**

**Rust's rationale for redundant inline annotations** — the most transferable
sentence in the report:

> *"This redundancy helps avoid mistakes since the `.stderr` files are usually
> auto-generated."*

Zig goes further: **no bless at all** for expected error text. You cannot add an
error test without reading and approving the message.

**Two teams removed matchers from expectations, for the same reason.** ppx_expect:
*"Regexp and glob matching … is now deprecated. **This gets in the way of the
'promote' workflow.**"* Dune: *"it breaks the test, diff, and accept cycle … we will
not introduce output matchers."* A golden with a wildcard **cannot be regenerated**.

**Blanket blessing is guarded, everywhere it exists.** GHC's accept fires only on
already-failing tests, refuses `expect_fail` tests, cannot create a new golden.
OCaml's `make promote` **requires** a scope — *"there is no analogue to `make all`."*
Roc regenerates everything, but its safeguard is the `git diff` CI gate. Medaka's
`capture_goldens.sh` has **neither** guard. That is the dangerous quadrant.

**Elm is the cautionary tale, and it is Medaka's tale.** Elm didn't *lack* a suite —
it **deleted** one: commit `e2008b50` (2018), *"Get rid of testing stuff"*, −1,069
lines, wiping a `good/` must-compile corpus, a `bad/` must-fail corpus, QuickCheck
round-trip properties, and regenerable JS goldens blessed with
`ELM_WRITE_NEW_EXPECTED=1`. Never restored; Elm's CI has no `script:` section. The
language most famous for its error messages has **zero automated regression
protection on them**. The lesson: **a golden suite not wired into CI and not cheap to
re-bless will be deleted at the first big rewrite.** `test/ported/` is already
Medaka's first casualty of exactly this.

### 3.2 The anti-circularity principle

Of everything surveyed, only **Zig, Lean 4, and Idris 2** are genuinely self-hosted
*and* run compiler tests in their own language. All three obey one rule:

> **The verdict must be computed outside the compiler under test.** In-language code
> is fine as a *producer of output*; the *comparison* must be done independently.

- **Zig** — `test/cases/compile_errors/*.zig` contain **no assertions at all**; the
  harness runs the compiler and diffs its **stderr text** against a trailing comment.
  `// run` tests bottom out in a **process exit code** observed externally.
- **Lean 4** — `#guard_msgs` *looks* like an in-language assertion, but it emits a
  Lean **message**, captured to `*.produced.out` and compared to `*.expected.out` by
  an **external diff**. Lean produces text; `diff` renders the verdict.
- **Idris 2** — `Test.Golden` is an Idris library, but it only (a) spawns the compiler
  as a **subprocess** and (b) shells to **`git diff --no-index --exit-code`**. Pass/fail
  comes from git's exit code, not from Idris-computed equality.
- **GCC** — the canonical device, and it needs no tests at all: `make bootstrap`
  compares stage2 and stage3 **object files byte-for-byte**.

**Zig's cheapest and most effective device is cross-backend differential testing.**
The same behavior tests run on `selfhosted`, `llvm`, and the `C` backend. For a
codegen bug to hide, it would have to corrupt all three **identically**.

---

## 4. Proposed architecture

### 4.1 Two layers, and an honest boundary

You cannot test a self-hosted compiler entirely in its own language. The trust anchor
is the **bootstrap**, not the test language.

```
┌─ Layer 0 — TRUST ANCHOR (shell/make; irreducible, ~5 scripts) ──────────────┐
│  cold bootstrap from compiler/seed/emitter.ll.gz                            │
│  self-compile fixpoint (C3a/C3b: IR byte-identity across generations)       │
│  seed currency (make bootstrap)                                             │
│  → "is this binary trustworthy?"  Cannot be written in Medaka without       │
│    circularity. KEEP IN SHELL. Not duct tape — the foundation.              │
└────────────────────────────────────────────────────────────────────────────┘
┌─ Layer 1 — CORRECTNESS (Medaka produces; an external comparator judges) ────┐
│  snapshot · differential · unit · property · doctest                        │
└────────────────────────────────────────────────────────────────────────────┘
```

The target is **~5 shell scripts, not 0** — and being explicit about *why those 5* is
what makes the rest legitimately deletable.

Medaka already has the strongest safeguard (`selfcompile_fixpoint.sh`). One cheap
addition brings it level with Zig: the seed (`emitter.ll.gz`) is already
target-triple-free and cold-bootstraps identically on x86 and arm — **document a
third-party reproduction step** and it has the same property Zig's `zig1.wasm` has.

### 4.2 Correction to the obvious design: Medaka must not judge its own verdict

The natural first instinct — and the one my own proof-of-concept took — is:

```medaka
test "parses a function decl" = expectEqual 1 (nDecls "add x y = x + y")   -- ⚠️
```

This works, and it is what `test/ported/` does. But `expectEqual` is a
**Medaka-computed `==`, inside the compiler under test, deciding its own pass/fail**.
That is the exact pattern §3.2 warns against.

The fix is not to abandon in-language tests — it is to **make the verdict external**:

| | Produces output | Renders verdict |
|---|---|---|
| **Snapshot tier** | Medaka (stage → text) | external `diff` vs committed file |
| **Diagnostic tier** | Medaka (`check --json`) | external annotation matcher |
| **Differential tier** | Medaka (3 engines) | external comparison of the 3 outputs |
| **Unit / property tier** | Medaka (`test`/`prop`) | **process exit code** + cross-engine agreement (§4.4) |

The unit tier keeps `expectEqual` — Zig's behavior tests use `try expectEqual` too —
but it is **never the only thing standing between a miscompile and a green run**,
because the same assertions run on all three engines (§4.4). A miscompile has to
corrupt the interpreter, the native backend, and wasm *identically* to hide.

### 4.3 The snapshot tier — one fixture, all stages (steal Roc)

Adopt Roc's format. Replace the 69 fixture/golden dirs and their per-stage `.golden`
fan-out with **one Markdown file per program, carrying a section per stage**:

```markdown
# META
type=snippet
description=guard clause lowering
# SOURCE
f x | x > 0 = 1
f x = 0
# TOKENS
…
# PARSE
…
# DESUGAR
…
# TYPES
f : Int -> Int
# EVAL
1
# LLVM
…
```

This structurally kills three documented footguns at once:

- **the golden-add footgun** — *"adding ONE fixture regenerates whole corpus (~412
  diffs)"* (memory). Now one fixture = one file.
- **the shared-corpus footgun** — *"`test/eval_modules_fixtures/` is globbed by TWO
  gates"* (AGENTS.md); P0-9 shipped "green" because only one of them was run. Now
  there is one file and one runner; a stage can't be silently skipped.
- **the recapture ritual** — HANDOFF records that a front-end change spans *"~8
  families with distinct capture paths … `diff_fixtures` TYPES need a surgical
  splice."* Now a desugar change diffs only the `# DESUGAR` sections.

Regeneration is the **default action**, and the CI gate is Roc's:

```sh
medaka test --snapshots      # regenerate all
git diff --exit-code test/snapshots   # ← the gate
```

**Normalize the actual output; never put a wildcard in the expectation** (§3.1).
Medaka's "goldens never bake an absolute path" is currently a *convention* — make it
a **normalization pass**.

### 4.4 The differential tier — the biggest win available, and it is nearly free

**Medaka owns three implementations of its own semantics** — the `eval.mdk`
interpreter, the LLVM native backend, and the WasmGC backend — **and no program in the
tree is ever compared across all three.** Measured:

| | |
|---|---|
| `test/llvm_fixtures/` | 195 `.mdk` |
| `test/wasm/fixtures/` | 151 `.mdk` |
| **fixtures in common** | **5** |

The two backends are validated on **essentially disjoint corpora**. And the one
two-way check that does exist is not a live differential: `diff_compiler_llvm.sh`
diffs native output against `<fixture>.eval.golden` — **a golden captured from eval**.
So a bug in the interpreter that gets captured becomes the *expected answer* for the
native backend too. The comparison is mediated by a frozen file rather than by running
both engines, which is precisely the circularity §3.2 warns about, one level down.

Meanwhile the memory index lists **seven distinct `run ≠ build` bugs** — poly-Unit
autoprint, string/list index slice, partial-method closure, comparison-operator dict,
return-position dispatch, type-lost float, nested closure capture. Every one is a
disagreement between two engines that already exist. Every one was found by luck.

The gate is one line:

```
for each fixture:  eval(f) == native(f) == wasm(f)   →  else FAIL
```

This is Zig's anti-circularity device (`backend=selfhosted,llvm` + the C backend over
the *same* behavior tests). It is the correct structural answer to Medaka's worst bug
class, it needs no new corpus (§4.3's `SOURCE` blocks) and no new runner, and — unlike
everything else in this document — **it finds bugs that are currently invisible.**

**This is the highest-priority item in the redesign, and it does not depend on any of
the rest of it.** Do it first, even if nothing else here happens.

### 4.5 The diagnostic tier — hand-written inline annotations, no bless

For error tests, put the expectation **in the fixture**, keyed on the stable
diagnostic `code` that `DIAGNOSTIC-CODES-DESIGN.md` already guarantees, and check it
against `check --json`:

```medaka
foo = bar   -- ~ ERROR R-101 unbound name `bar`
```

**Deliberately not blessable** (Zig's rule). Medaka maintains `ERROR-QUALITY.md` with
a graded corpus and an explicit copy standard — an auto-blessed diagnostic golden is
*actively hostile* to that goal, because it lets a message regress and be re-blessed
without anyone reading it. The assertion is on `code` + `range` (stable); the prose
can change freely.

### 4.6 A must-fail suite — make the gap census executable

Steal rustc's `tests/crashes`: tests that assert the **current wrong behavior**, whose
purpose is to detect *accidental fixes*. Medaka's residual gaps live in prose today —
`EMITTER-GAPS.md`'s refutable-`CGBind` `gapU`, the `-0.0` interp/native divergence, the
`1e12` scientific-notation gap. Turn each into a fixture tagged `known-bug`. The prose
census becomes executable, and it tells you the day a gap closes.

### 4.7 `--promote` for the inline tiers (steal OCaml)

OCaml's `expect` mode needs **zero dedicated promotion machinery**: its `run-expect`
action just rebinds two variables — the **source file** plays *reference*, a
regenerated copy plays *output* — and the generic file-diff-and-promote action does
the rest. Applied here:

```
medaka test --promote   → writes foo.mdk.corrected with actual outputs substituted
                          into the doctest blocks; diff; copy on promote
```

And compose it with §4.4: **promote from the interpreter, then assert the native build
produces byte-identical doctest output.**

### 4.8 Tiers, and what each is for

| Tier | Construct | Carries coverage? |
|---|---|---|
| **Differential** | 3-engine agreement (§4.4) | **yes — and finds new bugs** |
| **Snapshot** | Roc-style per-stage sections | yes — mechanical |
| **Unit** | `test "n" = <Expectation>` | **yes — primary** |
| **Property** | `prop "n" (x : T) = <Bool>` | **yes — primary** |
| **Diagnostic** | inline `-- ~ ERROR CODE` | yes — hand-written |
| **Must-fail** | `known-bug` fixtures | catches accidental fixes |
| **Doctest** | `-- > expr` | **no — documentation only** |

The doctest demotion is a policy change, not a code change: keep running them, stop
growing them, migrate their coverage into `test`/`prop`.

### 4.9 Missing plumbing

- `medaka test` takes **one file**. It needs the directory/`medaka.toml` walk that
  **`medaka lint` already has** — borrow it.
- Add `make test`. There is none.
- Add CI. There is **no `.github/` at all**.
- **Fuzz corpus = snapshot corpus.** Roc's `--fuzz-corpus` dumps every fixture's
  `SOURCE` as fuzzer seeds. `fuzz_diff.sh` already exists; point it at the corpus.

---

## 5. What this deletes

| Deleted | Replaced by |
|---|---|
| 79 × `diff_compiler_*.sh` | one snapshot runner |
| 70 × `compiler/entries/*.mdk` | direct in-process imports |
| `test/bin/` + `build_oracles.sh` | — (nothing to build) |
| `capture_goldens.sh` + 3 × `CAPTURE=1` dialects | `medaka test --snapshots` + `git diff` |
| 59 × `strip_unit()` | — (no shell pipe, nothing to strip) |
| `run_gates.sh` | `medaka test` |

Net: **~115 shell scripts → ~5**; ~10,000 lines of bash become a few hundred lines of
Medaka that are typechecked, formatted, linted, and dogfooded like the rest of the tree.

---

## 6. Migration — strangler fig

**Phase 0 — stop the bleeding (hours).** Wire `test/ported/` into a gate; fix the two
rotted files; add `make test`; add CI running the *existing* suite. Fix
`build_oracles.sh` staleness to scan `stdlib/` + `runtime/`. Make `run_gates.sh` FAIL
(not SKIP) when `test/bin/` is empty.

**Phase 1 — the review gate, BEFORE the bless button.** CI runs the suite then
`git diff --exit-code`. This is what makes regeneration safe; a frictionless `--bless`
without it turns every golden into a rubber stamp (§3.1). **Do not invert these.**

**Phase 2 — the tri-engine differential gate (§4.4).** Highest value, independent of
everything else, uses only what exists. Do this before the big migration — it is the
part that finds bugs.

**Phase 3 — harness core.** Snapshot combinator + normalization pass + `--promote`;
`medaka test` gains project discovery (port from `lint`).

**Phase 4 — prove it on one family.** Migrate parse/desugar. Run **old and new side by
side** and require byte-identical results before deleting the old gate. This is the
acceptance test for the design.

**Phase 5 — migrate the rest, deleting as you go.** Each migrated gate deletes its
script, its entry, and its oracle.

**Phase 6 — re-tier the doctests.** Move stdlib coverage into `test`/`prop`; trim
doctests to illustration. Enforce with a lint rule.

---

## 7. Risks, and what I'd push back on

- **"No shell scripts" is the wrong goal.** The bootstrap and fixpoint gates *must*
  stay outside Medaka — they are what makes the Medaka-run tests trustworthy. Chasing
  zero would destroy the trust anchor. Target ~5, and say why.
- **Don't let Medaka judge its own verdict** (§4.2). This is the subtle one, and the
  obvious design gets it wrong.
- **In-process trades isolation for speed.** No catchable panics means one bad fixture
  takes down the runner. Needs an `--isolate` fallback re-running a failing suite one
  fixture per process via `runCommand` (which already exists).
- **Don't delete doctests, demote them.** They are currently the only stdlib safety
  net; the replacement tier must exist *first*.
- **Migrating bash→Medaka is a maintainability project, not a correctness one.** The
  snapshot tier will be cleaner, faster, and honest about what it is — but it will not
  find one new bug. If the goal is better *bug-finding*, the levers are §4.4
  (tri-engine differential) and more props/fuzzing. **§4.4 is the one item here that
  pays for itself in bugs**, and it does not depend on any of the rest.
