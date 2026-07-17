# Workstream: TESTING

**Owns:** `test/`, `.github/workflows/`, the golden/oracle machinery.
**Does not own:** compiler fixes — if a compiler change needs a golden re-cut, that re-cut belongs to
*its* PR, not to this workstream.

```sh
gh issue list --label "ws:testing" --state open
```

**Baseline:** `run_gates.sh` = 83 passed / 0 failed / 0 skipped. Fixpoint C3a+C3b YES. Compiler source
type-clean.

---

## Principles this suite is built on — do not erode them

- **"This didn't run" must never look like "this passed."** *Every silent-green bug in this repo is that
  sentence.* A gate that compared nothing must **FAIL**, not pass. (That is why a phantom-skip counts as
  FAILED, not skipped.)
- **Normalize the ACTUAL, never the expected.** Expectations are literal. (ppx_expect and Dune both
  shipped regex matchers and then **deliberately removed them**.)
- **Blessing must be an explicit, named act.** `--bless` refuses to rubber-stamp a corpus; you name the
  path. **And read the count it prints back** — it will happily say `0 blessed`, and a stale golden
  shipped once because that number went unread.
- **A ledger, never a skip-list.** A skip-list cannot notice an *accidental fix*, so it rots. **Every
  exception entry must fail when the thing gets BETTER, too.** ⭐ The **tracker** was the last
  un-drained ledger — six entries were already dead when it was re-derived on 2026-07-14, two of them
  labelled *silent build miscompile*. `diff_compiler_must_fail.sh` is its expiry (#547).
- **Measure allocation, not wall-clock**, for perf gates. GC bytes are deterministic — machine-independent
  and noise-free, which no timing gate can be on a shared runner.
- **A gate must RUN where the bug lands.** A docs gate inside a gate shard is *skipped on docs-only PRs*
  — green forever, checking nothing. Ask **"where is this skipped?"** *before* you write it.

---

## ⚠️ THE CATEGORY IS A CLAIM. VERIFY IT.

A ledger row that asserts *why* something fails is asserting a conclusion. Get it wrong and you have
**laundered a bug behind a plausible label** — and every downstream reader treats the label as evidence.

It has happened three times:

- **17 ledgered "wasm bugs" were never bugs** — `wasm_emit` prefixed every unbound name with `"gap —"`,
  a category it could not verify.
- **16+ rows dissolved** on re-check (2026-07-13/14).
- **`test/fuzz_allowlist.txt` still allowlists `max`/`min`** as an open residual that `EMITTER-GAPS.md`
  declared **closed 2026-06-11**. An allowlist entry that outlives its bug **silently swallows a real
  future failure.**

The discriminating test lives in the ledger header — **run it before adding a row:**

```sh
./test/bin/llvm_emit_main <fixture>    # does the OTHER backend manage it?
./test/bin/wasm_emit_main  <fixture>
# BOTH fail the same way -> NOT a backend gap (a prelude-free-corpus fact). Do NOT write the row.
# ONLY wasm fails         -> a genuine wasm gap.
```

---

## ⚠️ A FIXTURE DIRECTORY IS A SHARED CORPUS

Adding, moving, or deleting a fixture **silently enrols (or de-enrols) you in gates you never named.**
Before touching one: `grep -rl '<fixture_dir>' test/` — then run **all** of them.

Known multi-consumer dirs:
- `test/eval_modules_fixtures/*/` → `diff_compiler_eval_modules.sh` **and**
  `diff_compiler_core_ir_modules.sh` (a P0 shipped "green" having run only the first)
- `test/wasm/fixtures/` → **four** consumers (`diff_wasm.sh`, `diff_compiler_engines.sh`,
  `tmc_census.sh`, and the keys of `test/engine_divergence.txt`)

---

## The agent loop — do NOT run the full suite locally

```sh
make preflight                                       # ✅ THE LOOP — derives the gate set from YOUR diff
sh test/run_gates.sh 'diff_compiler_parse*'          # ✅ targeted, by name
sh test/build_oracles.sh --for 'diff_compiler_*'     # ✅ fresh-worktree recipe (~2 min)
sh test/run_gates.sh                                 # ❌ all 83
FORCE=1 sh test/build_oracles.sh                     # ❌ all 54 oracles. Almost never right.
```

**This is a real cost, not an aesthetic preference.** Several agents share this box. One full suite +
oracle build takes the load average past 10 and **turns a 30-second gate run into several minutes for
everyone else.** Worse, a bare `FORCE=1 build_oracles.sh` spawns an `xargs -P` pool that **outlives the
agent's turn and gets RESPAWNED by the harness** — it has killed several agents.

⚠️ **`preflight` is a FILTER, NOT AN AUTHORITY.** It runs a subset and prints what it skipped. **CI on
the PR is the authority. Nothing merges on a green preflight.**

**A full local run IS justified when:** you changed `compiler/backend/*` (run `selfcompile_fixpoint.sh`)
· `compiler/support/*` or `stdlib/core.mdk` (blast radius genuinely is everything) · you are merging two
branches that touched the same subsystem (pre-merge greens do not carry over) · CI says something you
cannot reproduce.

---

## The gates that own a class

| Gate | What it proves |
|------|----------------|
| `selfcompile_fixpoint.sh` | Emitter self-compile fixpoint — **THE decisive gate for any compiler-source change** |
| `typecheck_compiler_source.sh` | Strict-typechecks the WHOLE compiler source. **The bootstrap emit path does NOT gate on type errors** — an ill-typed compiler builds green without this |
| `diff_compiler_run_check_agreement.sh` | `run` stdout == built-binary stdout, and a rejection must be a **diagnostic, not a panic** |
| `diff_compiler_engines.sh` | The 3-engine differential: eval == native == wasm on the SAME programs |
| `diff_compiler_perf_scaling.sh` | The O(n²) detector — grades **allocation** growth, not wall-clock |
| `diff_compiler_capability_matrix.sh` | Every extern in `stdlib/runtime.mdk` vs what each engine implements. **Its absence let 37 externs drift for six weeks** |
| `diff_compiler_shadow_semantics.sh` | Pins every shadow cell, **including the KNOWN-BAD ones** |
| `diff_compiler_must_fail.sh` | **The TRACKER's self-drain** (#547). Each `test/must_fail_fixtures/*/` pins one OPEN issue's bug as still reproducing; a fix flips it RED and the message says to close the issue. A RED here is usually a GOOD failure. Runs as a named step in `soundness` — NOT a shard, because shards are narrowed on `pull_request` and the drain would only fire in the merge queue |

**Stale oracles:** `diff_native_cli` and the bootstrap suites are especially stale-prone — force-rebuild
before trusting a pass/fail from those.
</content>
