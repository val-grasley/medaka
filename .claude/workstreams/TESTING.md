# Workstream: TESTING

**Owns:** `test/`, `.github/workflows/`. **Does not own:** compiler fixes — if a compiler change
needs a golden re-cut, that re-cut belongs to *its* PR, not to this workstream.

**Baseline:** `run_gates.sh` = 83 passed / 0 failed / 0 skipped. Coverage = 103 of 110 gates in
CI. Fixpoint C3a+C3b YES. Compiler source type-clean.

---

## T-1 · TWO auto-print contracts (start here — it undermines a whole gate)

`test/llvm_fixtures/bool_false.mdk` is `main = (3 >= 4) && (1 == 1)`.

| | prints |
|---|---|
| committed `.eval.golden` | `false` (lowercase) |
| `medaka build` → run the binary | **`False`** |
| `test/bin/eval_autoprint_main` | **`False`** |

…and `diff_compiler_llvm` passes **201/201** comparing its own probe's binary against that
*lowercase* golden. So the gate's probe (`test/bin/llvm_emit_main` → clang) emits a binary that
prints `false`, while the **shipping compiler** emits one that prints `False`.

**Why it matters:** that gate exists to prove *native binary output == the interpreter*. If the
probe's print contract differs from the shipping compiler's, the gate is validating **a path
users never take** — and it would not notice a Bool-rendering regression in `medaka build`.
39 of 201 goldens differ from what `eval_autoprint_main` produces (the bools, plus the
abort/panic fixtures where stdout-before-abort differs).

**Do NOT "fix" this by regenerating the goldens.** I wrote a `--frozen llvm_eval` regenerator
and **reverted it**: it would have rewritten those 39 goldens and silently re-pinned the corpus
to a different contract — fixing the symptom by hiding the question. **Establish which contract
is correct first.**

## T-2 · There is NO supported way to regenerate a `test/llvm_fixtures` golden

`capture_goldens.sh`'s header still advertises a `test/llvm_fixtures/*.mdk (180)` row. **That
row was deleted in `6869cc8d`.** So AGENTS.md's "Writing tests" recipe ("capture a golden:
`bash test/capture_goldens.sh`") silently does **nothing** for the one corpus you add an emitter
fixture to. An agent adding a miscompile regression fixture had to reverse-engineer the
invocation out of `diff_compiler_engines.sh`.

Blocked on T-1: you cannot write the regenerator until you know which contract it should use.

## T-3 · `build_construct_coverage` is RED and unexamined

138 ok, **1 failing**, 5 skipped (of 144), and it takes 330s. It is ledgered out of CI in
`test/CI-COVERAGE-EXCEPTIONS.txt` — honest, but **nobody has looked at the failure.** Triage it,
then either fix it and enrol it in a shard, or ledger it with a *reason* rather than a
placeholder.

## T-4 · Two gates have no home in CI

Both ledgered, both need a decision rather than a shrug:
- `check_removed_constructs` — a 2–3 min tree-wide scan. Too slow for every push. **A scheduled
  (nightly) job** is probably right.
- `fuzz_diff` — a **fuzzer**. It cannot be a pass/fail PR gate (a green run proves nothing; a
  red run may be unreproducible). It belongs in a scheduled job that **files** findings.

## T-5 · Finish the snapshot migration (R3–R7)

R1/R2 shipped (367/367 byte-identical; gates 84→80; the `_batch` gates vanished with **zero
replacement** — they existed only to amortize process spawn). ~55 gates remain on the old
shell/golden path. End state: retire `build_oracles.sh`, `test/bin/`, and the probe entries
entirely.

## T-6 · `run_check_agreement`'s `.out` pin is optional

It now compares the **value** (`run` stdout == built-binary stdout) for every ACCEPT fixture —
a real fix; it previously graded **by exit code alone**, so a build that exits 0 while printing
a *wrong number* was invisible to it, and it would have graded the shadow-bug fixture **PASS**.
Residual: the `.out` pin is optional, so a future fixture without one gets the differential but
no semantics pin. Make it required, or make its absence loud.

## T-7 · The 44 `wasm:emitter-gap` ledger rows are now *verified* — keep them that way

Audited 2026-07-13: all 44 are correctly categorised. But four rows were **wrong** before that
(they asserted a wasm ref-mode gap that did not exist), and I repeated the wrong story to an
agent as established fact. The discriminating test is now in the ledger header:

```sh
./test/bin/llvm_emit_main <fixture>    # does the OTHER backend manage it?
./test/bin/wasm_emit_main  <fixture>
# BOTH fail the same way -> NOT a backend gap (a prelude-free-corpus fact). Do not write
#                           wasm:emitter-gap.
# ONLY wasm fails         -> a genuine wasm gap.
```

**A ledger is only as good as the category you write in it.** Run the test before adding a row.

---

## Principles this suite is built on — do not erode them

- **"This didn't run" must never look like "this passed."** Every silent-green bug in this repo
  is that sentence. A gate that compared nothing must FAIL, not pass.
- **Normalize the ACTUAL, never the expected.** Expectations are literal. (ppx_expect and Dune
  both shipped regex matchers and then *deliberately removed them*.)
- **Blessing must be an explicit, named act.** `--bless` refuses to rubber-stamp a corpus; you
  name the path. **And read the count it prints back** — it will happily say `0 blessed`, and I
  once shipped a stale golden because I did not read that number.
- **A ledger, never a skip-list.** A skip-list cannot notice an *accidental fix*, so it rots.
  Every exception entry must fail when the thing gets better, too.
- **Measure allocation, not wall-clock,** for perf gates. GC bytes are deterministic, so the
  gate is machine-independent *and* noise-free — which no timing gate can be on a shared runner.
</content>
