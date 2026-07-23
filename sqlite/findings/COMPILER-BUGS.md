# Compiler + tooling bugs surfaced by the SQLite dogfood (2026-07-13)

> ## ⚠️ DO NOT TRUST THIS LIST — RUN THE SCRIPT
>
> ```sh
> MEDAKA_ROOT=$PWD bash sqlite/findings/verify_compiler_bugs.sh
> ```
>
> Bug lists in this repo **go stale faster than anyone updates them** — that is ORCHESTRATING.md's
> #1 lesson, and it has burned people repeatedly. A compiler orchestrator was actively fixing some
> of these *while this file was being written*, so items here may already be closed.
>
> The script re-runs every ✅ VERIFIED item below against whatever `./medaka` you point it at and
> prints **OPEN** or **FIXED** for each. It is a status report, not a gate (always exits 0).
> **When something reports FIXED: mark it closed here, and move its repro into a real regression
> fixture so it stays closed.**
>
> ⚠️ **Statuses are PER-ROW — do not trust a hard count here, it has rotted repeatedly** (this
> snapshot line itself went from "10 open, 1 fixed" to "7 open, 4 fixed" and was stale again within
> days). Read each **Bn** heading directly for CLOSED vs open. As of a 2026-07-23 re-verification
> against current `main`: **B6, B7 and B10 are now also CLOSED** (see their entries below) — they
> were still marked open as of the 2026-07-14 snapshot. **B2, B3 and B4 had all been fixed earlier**
> and nobody had noticed at the time — including BOTH of the "silent build miscompile" P0s that
> `PLAN.md` was still advertising as open. This is the reason this warning exists. The two
> **MUT** workaround rows were reverted 2026-07-15 (#140 btree gather, #141 recordenc encoder).
>
> **The backlog now lives in GitHub Issues** (`gh issue list --label "S0: silent wrongness"`), because
> an issue self-drains and a markdown row does not. This file stays as the *repro corpus* and the
> workaround map — but the open/closed truth is the script, and the tracking is the tracker.
>
> ⚠️ **B1 is a cautionary tale about "fixed".** `main`'s `ced6342d` fixed the partially-applied-
> constructor miscompile **in the LLVM emitter and NOT in the WasmGC one.** The script said FIXED, I
> reverted the workaround — and the **wasm tandem gate caught it**: the library no longer emitted to
> wasm. The workaround is restored, retagged `B1w`, and the script now checks **both backends**.
> **A one-backend fix is a half fix. Always check both.**

Consolidated from the per-agent findings files in this directory. **Every item marked ✅ VERIFIED
was reproduced by the orchestrator on the binary**, independently of the agent that reported it —
several agent-supplied root causes and repro conditions were incomplete or wrong, and one of the
orchestrator's own "verified facts" was later disproved by an agent. Items marked 🟡 REPORTED are
agent claims that have **not** been independently re-checked; treat them as leads, not facts.

Repros live beside this file (`repro_*`), and the ✅ VERIFIED ones are all encoded in the script.
None of these came from reading `compiler/` — they all came from trying to build something real.

---

## Workarounds the library is currently paying for

Every workaround site carries a greppable marker:

```sh
grep -rn "WORKAROUND(" sqlite/lib/          # and verify_compiler_bugs.sh prints them too
```

**When a bug flips to FIXED, revert its sites** — otherwise the library keeps paying for a bug that
no longer exists, which is how workarounds quietly become permanent architecture.

| bug | site | what to do when it closes |
|-----|------|---------------------------|
| **B1w** | `sqlite/lib/sqlparse.mdk` (×2) | ⚠️ **STILL NEEDED — for WasmGC only.** `main`'s `ced6342d` fixed this in the LLVM emitter; the **WasmGC emitter still fails to emit** a partially-applied constructor. Revert the eta-expansions only when B1 is fixed in **both** backends. |
| **B2** | `sqlite/lib/aggregate.mdk` | ⭐ **B2 IS NOW CLOSED — this revert is OWED.** `AggQuery`'s fields are `aq`-prefixed (`aqFrom`/`aqWhere`/`aqGroupCols`/`aqAggs`/`aqHaving`) **solely** to avoid colliding with `Select`'s `from`/`where_`/`groupBy`/`having`. Rename back to the natural names. ⚠️ **In progress:** a sibling PR is reverting this `aq`-prefix workaround in `aggregate.mdk` now that B2 is confirmed closed — no code touched here, this is a status note only. |
| ~~**B5**~~ | `sqlite/lib/select.mdk`, `sqlite/lib/recordfmt.mdk` | ✅ **CLOSED (#316, 2026-07-16).** Root cause was prelude asymmetry — `Eq (Array a)` lived in `array.mdk` while `Debug/Display/Index (Array a)` were in the prelude, so `deriving (Eq)` over an `Array` field check-passed but native-build-failed. Fixed by moving `Eq (Array a)` into `stdlib/core.mdk`. The hand-written `Eq` on `Literal`/`Cell` and their `-- lint-disable-next-line rule-hand-rolled-derivable` were reverted to `deriving (Debug, Eq)` in the same PR. (`verify_compiler_bugs.sh` reports FIXED.) |
| ~~**MUT**~~ | `sqlite/lib/btree.mdk` | ✅ **REVERTED (#140).** The overflow gather now allocates the payload buffer once (`array.make`) and blits each region into place (`array.blit`) — O(bytes), one copy per payload byte. The pure `slice`+`concat` O(chunks × bytes) dodge is gone; no `<Mut>` (removed 2026-07-14) and no `--allow-internal` (uses the safe `array` wrappers, not the raw externs). |
| ~~**MUT**~~ | `sqlite/lib/recordenc.mdk` | ✅ **REVERTED (#141).** `beSintBytes` now delegates to stdlib `bytebuilder.emitBeSint` (`newBuilder`/`emitBeSint`/`buildArray`); the hand-rolled two's-complement duplicate and its `beUnsignedNBytes`/`beUnsignedNGo` helpers are deleted. `<Mut>` removal (2026-07-14) mooted the signature concern. |

## The theme worth reading first

**Six of these are `check` / `run` / `build` disagreements, and three are *silent*.** The pattern
that produces them: **every doctest in this repo runs under the interpreter.** So a bug that exists
only in compiled code is invisible to the entire test suite. The SQL expression parser shipped with
32/32 green doctests while *every arithmetic operator in its grammar* was silently broken in the
native binary (B1). That is a gap in the testing strategy, not just a set of bugs — a differential
`run` vs `build` gate over the existing doctest corpus would have caught B1, B5, B6 and B8 for free.

---

## P0 — `medaka fmt --write` DESTROYS SOURCE CODE

### B10 — ✅✅ **CLOSED (fixed by issue #51, re-verified 2026-07-23)**. `fmt --write` on a float
literal ≥ 1e15 still writes scientific notation (`9e+15`), but the lexer now reads that back
correctly — `main = println 9000000000000000.0` → `fmt --write` → `main = println 9e+15` →
`check`/`run` both round-trip to `9e+15`. No longer a destructive operation. Left here as the
worked example below (historical repro + root cause).

#### (historical) `fmt` rewrites a float literal ≥ 1e15 into a form the lexer cannot read

    big : Float
    big = 9000000000000000.0     -- valid: checks, runs, prints 9e+15

    $ medaka fmt --write big.mdk
    $ cat big.mdk
    big = 9e+15                  -- fmt wrote this

    $ medaka check big.mdk
    big.mdk:2:6: No impl of Num for (Float -> Float)

The **printer emits scientific notation** (via `floatToString`) while the **lexer rejects every
exponent form** (`1e-05`, `9e15`, `9e+15`, `1.5e10` — all rejected; `9e+15` lexes as an
*application*, hence the surreal `Num for (Float -> Float)`). The two halves of the round trip
disagree, and `fmt --write` is what forces them to meet.

**Why this is P0 rather than a curiosity:** `medaka fmt --check` runs in the **pre-commit hook** on
every staged `.mdk`. So the hook rejects your unformatted file, you run `fmt --write` as instructed,
and it silently destroys the file.

**Blast radius (measured):** the threshold is **1e15**. `1700000000.0` (which really does appear, in
`compiler/eval/eval.mdk:1809`) is *below* it, and `fmt` is a no-op there — so **the tree is not
currently corrupted**. This is latent, not active: it detonates the first time anyone writes a large
float literal. Related to the known-open "scientific notation rejected" gap, which turns out to be
not merely an input limitation but a **source-corruption vector**.

**AGENTS.md is wrong** where it says *"`medaka fmt` is safe (0 corruptions / 0 non-idempotent
repo-wide) and idempotent"*. That claim was established by a soak over the existing tree, which
happens to contain no literal above the threshold — it is a statement about the corpus, not the tool.

---

## P0 — SILENT WRONG ANSWERS in `medaka build` (exit 0, no diagnostic)

### B1 — ✅✅ **CLOSED (fixed on `main`, `ced6342d`: "an under-applied data constructor built a
malformed cell")**. Workarounds in `sqlparse.mdk` reverted to point-free; re-verified under native
`build` (round-trip 62/62, precedence 12/12, oracles 22/0). Left here as the worked example of the
report → fix → auto-detect → revert lifecycle.

#### (historical) a partially-applied **data constructor** miscompiles
`check` ✓ · `run` ✓ correct · **native binary prints the WRONG answer, exit 0.**

Repro: `repro_pap_ctor_miscompile.mdk` (~20 lines, no stdlib, no sqlite). One file, one build:

| form | `run` | `build` |
|---|---|---|
| partially-applied **function** — `apply2 (mkBin OAdd) …` | `add 1 2` | `add 1 2` ✅ |
| constructor wrapped in a lambda — `apply2 (l r => Bin OAdd l r) …` | `add 1 2` | `add 1 2` ✅ |
| partially-applied **constructor** — `apply2 (Bin OAdd) …` | `add 1 2` | **`OTHER`** ❌ |

So it is constructors specifically; eta-expanding is a sound workaround (`sqlparse.mdk` does this
for `EArith`). Probably a residual of the 2026-07-02 PAP arc (`mdk_apply` / wrapped-PAP). Deserves
an `llvm_fixtures` regression.

### B2 — ✅✅ **CLOSED** (verified FIXED by the script on `e34e2b46`, 2026-07-14)

**Root cause, for the record:** `CRecordUpdate` carried **no receiver type name** (its sibling
`CVariantUpdate` does), so both emitters guessed from the bare field label, **first-match-wins**.
Silent on LLVM, `illegal cast` on wasm.

⚠️ **The workaround is still in the tree.** `sqlite/lib/aggregate.mdk:140` still prefixes `AggQuery`'s
fields with `aq` (`aqFrom`/`aqWhere`/`aqGroupCols`/`aqAggs`/`aqHaving`) **solely** to dodge this bug.
**Rename them back to the natural names** — otherwise the library keeps paying for a bug that no
longer exists, which is how workarounds quietly become permanent architecture.

#### (historical) cross-module record **update** writes the wrong slot
`check` ✓ · `run` ✓ correct · **native binary silently returns the wrong value.**

Repro: `repro_record_update_slot/`. Two record types in **different modules** sharing a field name
at **different positional indices**, plus record-update syntax `{ r | f = v }`:

    run   -> [7] [3]     (correct)
    build -> [7] []      (the update wrote the OTHER record's slot)

All four conditions are required (verified by removing each in turn): different modules · shared
field name · different slot index · a record *update*. Construction, field access and record
*patterns* are all fine — **only update miscompiles.** When the colliding field types are
incompatible it degrades into an unlocated `E-NONEXHAUSTIVE-MATCH` instead of a wrong answer.

Field access and patterns evidently resolve via the receiver's type; update does not. Same family
as the "flat frame keyed by bare name is last-write-wins" hazards in AGENTS.md, and related to the
Phase-72 `field_owners` work. **This cost one agent most of its session** — it presents as "my
brand-new code is broken", appears only in the built binary, and the crash names nothing.

---

## P1 — `check` accepts, `build` rejects (loud, but a broken promise)

### B5 ✅ VERIFIED — `deriving (Eq)` on a type with an `Array` field cannot be built
    data Blob = Blob (Array Int) deriving (Eq)

`check` ✓ · `run` ✓ (prints `True`) · `build` ✗:

    error: emitter failed compiling …
    runtime error [E-PANIC]: no impl of method 'eq' for type 'Array' (slice 6)

There is no `Eq (Array a)` impl, and `deriving` never checks that its field types actually have the
class. Two fixes are possible and they are not the same: give `Array` an `Eq` impl, or make
`deriving` reject at `check` time. **Pick deliberately.**

### B5a ✅ VERIFIED — and `medaka lint` recommends the unbuildable program
`rule-hand-rolled-derivable` fires on the hand-written `impl Eq Literal` that exists *precisely* to
work around B5, and advises replacing it with `deriving (Eq)` — which then cannot be built. The
rule is blind to whether the field types have the class. (Silenced in `select.mdk` with a
`-- lint-disable-next-line`.) A linter that confidently recommends a non-compiling program is worse
than no linter for that rule.

---

## P1 — `run` diverges from `build` / from `check`

### B3 — ✅✅ **CLOSED** (verified FIXED by the script on `e34e2b46`, 2026-07-14)

**Root cause, for the record:** `checkImplObligations` runs only when `implInferEnabled` is OFF;
`elaborateModules` set it ON **unconditionally**. A plain type mismatch DID gate — *which is why
probing with one showed correct behaviour, and is why this was once declared not-reproducible.*

**The lesson outlived the bug:** both obvious observables were blind at once — the **exit code is 1
either way**, *and* `run` discarded stdout on panic (B4), so a `println` probe returned nothing whether
the program executed or not. **Assert on the DIAGNOSTIC.**

#### (historical) multi-module `run` does not gate on TYPE errors
Repro + full write-up: `repro_multimodule_run_typecheck_gap/`. `run` **executes the ill-typed
program** and dies on an unrelated panic.

One program, three diagnoses: `check` → correct + located; `run` → `E-PANIC: intToString: not an
Int` (unlocated, unrelated); `build` → a third message leaking an internal slice number.

**Three ways to fail to reproduce it** (the compiler orchestrator hit all of this):
1. must be **multi-module** — single-file `run` gates correctly (a control is included);
2. must be a **typecheck** error — *resolve* errors ARE gated;
3. **the exit code is 1 either way.** `run` still exits nonzero — just for the wrong reason. Any
   test shaped "does `run` reject this?" answers **yes**. Invisible to exit-code testing.

Suspected: the loader's `run` path never consults `hadTypeErrors()` — the same hole AGENTS.md
already documents on the bootstrap emit path, and possibly a case P0-1 (`96894932`) missed.

### B4 — ✅✅ **CLOSED** (fixed on `main`, `41a5986b` / PR #48; verified by the script on `e34e2b46`)

`run` now flushes buffered stdout before **every** abort path, not just a clean exit. Gated by
`test/diff_compiler_run_stdout_flush.sh` (enrolled in the tools shard, `47e041df`).

⚠️ **One ledger row still cites this bug as its blocker:** `test/CAPABILITY-EXCEPTIONS.txt:119`
(`flushStdout`, interpreter) says *"fix with the 'run drops stdout on panic' bug"* — that precondition
is now satisfied. Re-verify or promote the row.

#### (historical) `medaka run` discards buffered stdout on panic; the built binary does not
In a **well-typed** program, a `println` before a panic prints under `build` and vanishes under
`run`. Repro in `repro_multimodule_run_typecheck_gap/f3/flush.mdk`. A vicious debugging footgun:
your trace output disappears exactly when the program crashes — **it is what made B3 look
unreproducible.**

### B6 — ✅✅ **CLOSED (re-verified 2026-07-23, no tracking issue needed)**. `run` of `exit 3` now
prints "hi" (the preceding `println`) and exits 3, matching `build`. `exit` is implemented in eval.

#### (historical) `exit` works in `build`, is unbound under `run`
    main : <IO, Panic> Unit
    main =
      println "before exit"
      exit 3

`check` ✓ · `build` ✓ (prints, exits 3) · `run` ✗ `runtime error [E-PANIC]: unbound identifier:
exit`. It *is* bound; it is simply unimplemented in eval. (This also re-demonstrates B4 — the
`println` is lost.)

---

## P1 — data fidelity

### B7 — ✅✅ **CLOSED (fixed by issue #57, re-verified 2026-07-23)**. `floatToString` now emits
shortest-round-trip digits — `0.1 + 0.2` prints `0.30000000000000004`, not `0.3`. See also
`sql-parser-select.md` F3, which has the full before/after table.

#### (historical) `Float` cannot round-trip through display (~12 significant digits)

| expression | Medaka prints | actual IEEE double |
|---|---|---|
| `1.0 / 3.0` | `0.333333333333` | `0.3333333333333333` |
| `0.1 + 0.2` | **`0.3`** | `0.30000000000000004` |
| `123456789.123456789` | `123456789.123` | `123456789.12345679` |

`floatToString` truncates. The middle row is the worst of it: the language **prints `0.1 + 0.2` as
exactly `0.3`**, concealing the single most famous fact about floating point. For anything that
serializes numbers (a database library, JSON) this is silent precision loss, not cosmetics. The fix
is shortest-round-trip formatting (Ryū/Grisu, or `%.17g` then trim).

---

## P2 — tooling

### B8 ✅ FIXED (GH #55) — `medaka test` parses a Markdown blockquote in a doc comment as a doctest
A `-- > This is prose.` line inside a doc comment is compiled as a doctest and used to die with an
**unlocated** `runtime error [E-PANIC]: parse error` — which **aborted the whole file's doctest
run**. This had **silently disabled every doctest in `sqlite/lib/rowtype.mdk` for months**.
Markdown's blockquote and the doctest marker are still the same character (`-- > …`) — that half
of the report (a) is genuinely ambiguous (prose vs. expression) and was NOT attempted; it needs a
format decision, not a heuristic. What shipped is half (b), the load-bearing fix: each example is
now synthesized+parsed through `parseResult` (the non-panicking entry `frontend/parser.mdk`
already exposes for the LSP) **individually**, so a malformed example — blockquote or otherwise —
becomes one located `ERROR <file>:<line>: …` in that file's report instead of an uncatchable panic
that zeroes every OTHER example in the file. See `compiler/tools/doctest.mdk`
(`buildSynthResults`/`synthOne`/`oneResult`) and `compiler/tools/test_cmd.mdk`. Regression fixture:
`test/compiler_test_fixtures/blockquote_and_valid.mdk` (gate: `test/diff_compiler_test.sh`).

### B9 🟡 REPORTED — the tree is not `fmt`-clean under its own compiler
The `arr.[i]` → `arr[i]` Index migration landed in the compiler but never swept the tree, so
touching any `.[`-using file drags unrelated normalization into the diff. Confirmed for
`sqlite/lib/varint.mdk` (fmt-dirty at base, untouched by us). `SYNTAX.md:185` still documents the
old spelling. Wants one repo-wide sweep.

---

## P2 — diagnostics quality (all 🟡 REPORTED — leads, not verified)

- ~~A **parse error in an imported module** reports as an unlocated `E-PANIC: parse error`, even
  under `check --json`.~~ ✅ **FIXED (re-verified 2026-07-23)** — both `check` and `check --json`
  now locate it correctly (see `sql-parser-expr.md` F4).
- ~~A diagnostic in an imported module is printed with the **entry file's** name (`--json` gets it
  right — so it's the text renderer).~~ ✅ **FIXED by issue #41 (re-verified 2026-07-23)** — see
  `sql-parser-select.md` F5.
- `export data` hides constructors but the error says *"has no exported name"*, which misdescribes
  the cause. (Tracked in #103.)
- Omitting `where` on an `impl` points at the wrong line and never mentions `where`. (Tracked in
  #103.)
- `unexpected a number; expected a dedent` — ungrammatical, describes lexer state rather than the
  rule, and doesn't point at the construct that caused it. (Tracked in #103.)
- The same diagnostic reports a **different column** under `run` vs `build`. (Tracked in #103.)
- A multi-line list literal cannot be a `match` scrutinee. (Tracked in #103.)
- **No bounds-checked `array.slice`** — the only slice silently clamps, which is exactly the shape
  that hides corruption in a parser (this is arguably a P1: it is the sort of thing that turns a
  bug into a *silent* bug).

---

## Language design (not a bug — a decision) — ✅ RESOLVED 2026-07-14

**`<Mut>` effect masking — MOOTED by removing `Mut`.** Two independent authors hit the same wall:
`<Mut>` was contagious, so a pure function could not use a local mutable buffer, and
allocate→fill→freeze was unavailable to pure code. Costs paid: a duplicated stdlib encoder, and an
O(chunks × bytes) gather where O(bytes) was available. Investigating it turned up a **spec defect**
(issue **#61**): `Mut` was classified as "purity tracking", but allocation and reads are both pure, so
a **pure-typed function observably returned two different answers across a mutation**.

**Resolution (2026-07-14):** the `Mut`/`Panic` effect labels and the whole internal-label class were
**removed** from the language — effect labels are host capabilities only, and purity is no longer
tracked as an effect. The `mut` masking block proposed in `MUT-SCOPING-DESIGN.md` was **rejected** in
favor of removal. The reproductions `repro_mut_closure_launder.mdk` and `repro_mut_not_purity.mdk`
were **deleted** (their bug class no longer exists), and issue **#61 was closed as mooted**. The two
**MUT** workaround rows above were **reverted 2026-07-15** (#140 restored the O(bytes) blit gather in
`btree.mdk`; #141 deleted the duplicate encoder in `recordenc.mdk`).

---

## Environment (fixed here, in `ops/provision.sh`)

Two toolchain deps were missing from the box provisioning, and **both failed in a way that reads as
success**:

- **`sqlite3`** is the differential oracle for all of `sqlite/test/*_oracle.sh`. Absent, those gates
  die on the first `CREATE TABLE`.
- **`wasm-tools`** is what every wasm gate shells out to. Absent, each one prints `skipping` and
  **exits 0** — so the suite reports green while running nothing. This is the standing "1 skip" in
  `run_gates` 78/0/1, and it meant the WasmGC tandem gate had never actually run on this machine.

Also fixed: two SQLite oracles (`update_expr`, `writer_api`) had **never been able to pass** — each
set its destination path to the exact path `medaka build` writes to, then did `mv -f src dst` on the
same file and exited before running a single query. Suite went 16/2 → 18/0.
