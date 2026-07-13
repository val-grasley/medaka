# ENGINE-DIVERGENCE.md — where Medaka's three engines disagree

Measured 2026-07-13 by `test/diff_compiler_engines.sh` (TESTING-DESIGN.md §4.4).
The machine-readable form of this document is **`test/engine_divergence.txt`**, the
gate's known-failure ledger. This file is the prose: what each entry means, which
engine is wrong, and why.

**This is a bug backlog, not a skip-list.** Every entry asserts the *current, wrong*
behaviour. The gate fails if a line here starts passing — see "The ratchet" below.

---

## 1. Why this gate exists

Medaka has **three independent implementations of its own semantics**:

| engine | implementation | driver |
|---|---|---|
| **eval** | `compiler/eval/eval.mdk` (tree-walking interpreter) | `medaka run` |
| **native** | `compiler/backend/llvm_emit.mdk` → clang | `medaka build` |
| **wasm** | `compiler/backend/wasm_emit.mdk` → WasmGC | `test/bin/wasm_emit_main` |

Before this gate, **no program in the tree was ever compared across all three**, and
the two backends were validated on essentially disjoint corpora:

| | |
|---|---|
| `test/llvm_fixtures/` | 195 `.mdk` |
| `test/wasm/fixtures/` | 151 `.mdk` |
| basenames in common | **5** |

Worse, the one two-way check that existed was **not a live differential**.
`test/diff_compiler_llvm.sh` diffs the native binary's stdout against
`<fixture>.eval.golden` — a *frozen capture of the interpreter*, taken from the OCaml
interpreter that was deleted on 2026-06-26. A bug that got captured became the
**expected answer** for the backend too.

That circularity was not hypothetical. §3.1 below is a divergence that the frozen
goldens actively concealed for months.

Meanwhile the memory index lists **seven** distinct historical `run ≠ build` bugs
(poly-Unit autoprint, string/list index slice, partial-method closure,
comparison-operator dict, return-position dispatch, type-lost float, nested closure
capture). Every one was a disagreement between engines that already existed. Every one
was found by luck. This gate is the structural answer — Zig's anti-circularity device:
a codegen bug now has to corrupt all three engines *identically* to hide.

---

## 2. The census

346 fixtures = `test/llvm_fixtures/` (195) ∪ `test/wasm/fixtures/` (151).
Deterministic across repeated runs.

```
 T1  eval   == native    290 agree   15 differ   41 n/a
 T2  native == wasm      286 agree    7 differ   53 n/a
 T3  all three agree     254 agree   22 differ   70 n/a
```

The tiers separate the two bug classes cleanly: **T1's 15 are all one interpreter
bug** (§3.1); **T2's 7 are all wasm codegen bugs** (§3.2), every one of them on a
fixture from the *LLVM* corpus that the wasm backend had never been run on.

---

## 3. The 22 disagreements

### 3.1 `eval:rng-hash-lcg` — 15 fixtures. The interpreter's `random*`/`hash*` are wrong.

`llvm/{hash_int, hash_string, rng_bool, rng_char, rng_float, rng_int, rng_seq}`,
`wasm/{w8_hash_char, w8_hash_int, w8_hash_string, w8b_hash_float, w8_rng_bool,
w8_rng_char, w8_rng_int_determinism, w8b_rng_float_determinism}`

**native and wasm agree with each other on every one; eval differs on every one.**

```
hash_int    eval 5677099    native 803958421          wasm 803958421
rng_int     eval 4          native 2                  wasm 2
rng_float   eval 0.838264   native -0.476939056861    wasm -0.476939056861
rng_bool    eval False      native True               wasm True
```

`rng_int` is `main = let _ = setSeed 42 in randomInt 1 6`. **`setSeed 42; randomInt 1 6`
returns 4 under `medaka run` and 2 under `medaka build`.**

**Root cause — a scoped shortcut that escaped its scope.** `compiler/eval/eval.mdk`
(~line 1750) *deliberately* installs an LCG rather than the specified SplitMix64,
with a comment explaining that property-test generation "need NOT match the
reference." That reasoning is sound **for prop generation**. But `setSeed`,
`randomInt`, `randomBool`, `randomFloat`, `randomChar` and the `hash*` family are
*also* user-facing stdlib externs, whose contract (see the fixture headers, and
`project_rng_splitmix64` / `project_hash_per_type_specified`) is that they are
**byte-identical across engines**. The shortcut leaked out of the scope it was
justified in. It is not "unimplemented" — it is a local decision applied globally.

**Why nothing caught it:** `test/llvm_fixtures/hash_int.eval.golden` contains
`803958421` — the value **native** produces. The goldens were captured from the OCaml
interpreter, which *did* honour the spec. So the LLVM gate compares native against a
golden native agrees with, and no gate ever ran eval on these fixtures. The frozen
golden was laundering the bug. This is the circularity of §1, caught on the first run
of the new gate.

### 3.2 `wasm:codegen-bug` — 7 fixtures. The WasmGC backend is wrong.

All seven are from `test/llvm_fixtures/` — a corpus the wasm backend had never seen.

| fixture | eval | native | wasm | diagnosis |
|---|---|---|---|---|
| `llvm/char_max` | 1114111 | 1114111 | **2228223** | **i31 tag leak**: `2·1114111+1`. `charCode` returns the *tagged* word instead of untagging it. |
| `llvm/char_min` | 0 | 0 | **1** | Same bug: `2·0+1`. |
| `llvm/fn_float_chain` | 10.0 | 10.0 | **trap** | `illegal cast`. **Verified**: adding `f : Float -> Float` signatures makes it emit and run correctly. The wasm float detection is *signature-driven* (`declSigTypeNames`, per the 2026-06-30 float hardening), so an **unsignatured** float function is mis-typed as Int and the `ref.cast` traps. eval and native both infer it correctly. |
| `llvm/debug_charlit` | `'\n'` | `'\n'` | **trap** | `illegal cast` in `debugCharLit`. |
| `llvm/debug_strlit` | `"a\tb\"c"` | `"a\tb\"c"` | **trap** | `illegal cast` in `debugStringLit`. |
| `llvm/fn_bool_return` | True | True | **1** | The wasm scalar auto-print renders a `Bool` main as `1`. Formatting, not a value bug. |
| `llvm/arr_set_unit` | *(empty)* | *(empty)* | **0** | The wasm scalar auto-print renders a `Unit` main as `0`; the other two correctly print nothing. |

The first five are genuine codegen bugs. All seven exist **only** because the two
backends' corpora were disjoint — which is precisely the thesis this gate tests.

---

## 4. The engine-unavailability categories

70 fixtures cannot be run by at least one engine. These are ledgered, never silently
skipped, and each carries its specific reason.

### 4.1 `eval:extern-not-implemented` — 23 fixtures (was 25). **`medaka run` could not do I/O.**

> **STATUS 2026-07-13 — LARGELY FIXED.** `medaka run` now installs real host I/O
> primitives from `eval.mdk`'s **`ioExternBindings`** table (the "host is the
> handler" seam — `EFFECTS-SEMANTICS.md` §7): the File family (12), Env
> (`args`/`getEnv`/`executablePath`), Stdin (4), Clock (`wallTimeSec`/
> `monotonicSec`/`sleepMs`), `allocBytes`, and `ePutStr`/`ePutStrLn` (which
> previously **silently discarded all stderr**). `arrayFill`/`arraySortInPlaceBy`/
> `arraySortBy` — pure/`<Mut>`, no I/O at all — went into the shared pure table.
> Interpreter extern coverage: **98/134 → 120/134**. The differential oracle still
> installs ONLY the pure `externBindings`, so every eval golden is byte-identical.
>
> The two fixtures that were failing purely on `arrayFill` (`llvm/arr_fill`,
> `wasm/stagea_extern_probe`) are **promoted out of the ledger**. The verbatim
> `readFile` and `args` repros below now both work, including the
> AGENTS.md-documented probe workflow (`medaka run compiler/entries/eval_main.mdk
> <file>`), which had been broken.
>
> **STILL OPEN** (why the remaining fixtures stay in the ledger): `exit` (needs a
> per-driver policy — a doctest calling `exit 0` would kill `medaka test` with a
> SUCCESS status, silently skipping every remaining test), `runCommand` + the 10
> `net` externs (gated on the `--allow-exec`/`--allow-net` security posture), and
> `flushStdout` (a no-op by construction while `run` buffers stdout — fix it with
> the "run drops stdout on panic" bug). Also: only `medaka run` installs the I/O
> table; `medaka test`/`repl`/`check-policy` still drive the pure one, so a
> *doctest* still sees the frozen clock and has its stderr dropped. See
> `test/CAPABILITY-EXCEPTIONS.txt`.
>
> Everything below this line is the ORIGINAL census text, kept for the diagnosis.

This is the largest finding in the census, and it deserves its own workstream.

`compiler/eval/eval.mdk`'s hand-written `primitives` table (104 entries) **does not
contain a single filesystem, process, or environment extern**:

```
readFile   writeFile   appendFile   fileExists   listDir   makeDir
removeFile removeDir   renameFile   statFile     runCommand
getEnv     args        exit         arrayFill    readFileBytes  writeFileBytes
```

All 17 are declared in `stdlib/runtime.mdk` (so they typecheck, and `medaka check` is
green) and implemented in `runtime/medaka_rt.c` (so `medaka build` works). The
interpreter just panics:

```
$ cat rf.mdk
main = match readFile "/etc/hostname"
  Ok s => putStr s
  Err e => putStrLn e
$ ./medaka run rf.mdk
runtime error [E-PANIC]: unbound identifier: readFile
```

**`medaka run` cannot execute any program that touches the filesystem, argv, the
environment, or `exit`.** It type-checks clean and then dies with an internal panic.
This is an eighth — and by far the broadest — instance of the project's worst bug
class.

It is not a harness artifact. The workflow AGENTS.md documents, and that every
`compiler/entries/*.mdk` header advertises — `medaka run compiler/entries/eval_main.mdk
<file>` — **is itself broken**:

```
$ ./medaka run --allow-internal compiler/entries/eval_main.mdk test/llvm_fixtures/adt_imm_mixed.mdk
runtime error [E-PANIC]: unbound identifier: args
```

Those probes only work as *compiled* `test/bin/*` binaries.

It may well be **deliberate**: eval's `putStr`/`putStrLn` buffer into `outputRef` so
the evaluator stays `<Mut>`-only rather than `<IO>`, and real file I/O would force an
`<IO>` effect into the evaluator. If so, it is an undocumented design limit that
surfaces to users as an internal `E-PANIC`, which is still a bug — either implement
the externs or reject the program with a real diagnostic.

### 4.2 `eval:no-tco` — 6 fixtures

`wasm/{clos_deep_tco, clos_reftco_indirect, w_deep_append, w_trmc_deep_cons,
w_trmc_dispatch, w_trmc_strip_clauses}`. The tree-walking interpreter has no
tail-call optimisation and overflows past depth 25000. It says so cleanly
(`E-STACK-OVERFLOW`, with an explanatory message). A legitimate, documented engine
limitation — the only category here that is arguably *not* a bug.

### 4.3 `eval:unsupported-node` — 1 fixture

`wasm/w7_variant_update` → `E-PANIC: eval: unsupported node (slice 2)`. An AST node
the interpreter never learned to evaluate. Both backends handle it.

### 4.4 `eval:intended-abort` — 2 fixtures

`llvm/abort_panic` (`E-PANIC: boom`) and `wasm/w7_array_oob` (`E-INDEX-OOB: index 9
out of bounds`). These are the *program's own* intended aborts, not engine failures —
the gate's eval-arm classifier is deliberately conservative (any interpreter-level
`E-*` counts as n/a, because today the interpreter has no `exit` primitive, so a
nonzero exit is never a program-level exit). Ledgered explicitly rather than
special-cased, so the conservatism is visible instead of hidden.

### 4.5 `native:prelude-collision` — 7 fixtures

`llvm/{adt_list_fold, adt_option, clo_adt, list_filter, list_sum, rec_build,
rec_update}`. `test/llvm_fixtures/` is a **prelude-free** corpus: fixtures redefine
`IntList`, `Point`, `Option`… which collide with `stdlib/core.mdk` under a real
`medaka build`. This is a property of the corpus, not a compiler bug — it is exactly
why `diff_compiler_llvm.sh` drives the prelude-free `llvm_emit_main` entry rather
than `medaka build`. Ledgered so the count can never quietly grow.

### 4.6 `native:autoprint-ambiguous` — 1 fixture

`llvm/abort_panic`: `main = panic "boom"` has a polymorphic type, so the value-main
auto-print wrap (`main = println <e>`) cannot resolve a `Display` instance →
`Ambiguous instance for Display`. Arguably a real diagnostic gap for bottom-typed
mains.

### 4.7 `wasm:emitter-gap` — 29 fixtures

The WasmGC emitter cannot produce a module that assembles and validates. It reports
its own gaps, which is to its credit. Distinct causes, by frequency:

| n | gap |
|---|---|
| 5 | `ref-mode: unbound variable 'writeFile'` (and `statFile`, `runCommand`, …) — the I/O externs, same set as §4.1 |
| 4 | `wasm-tools parse: unknown func $mdk_char_to_str` — the preamble omits a helper it emits calls to |
| 4 | `ref-mode: unsupported pattern in match arm` |
| 4 | `ref-mode: unbound variable 'index'` |
| 4 | `ref-mode: recursive let binding` |
| 3 | `wasm-tools validate: func N failed to validate` |
| 2 | `wasm-tools parse: unknown type $str` |
| 2 | `scalar-mode: unsupported Core IR node CRecord` |
| 2 | `scalar-mode: unsupported Core IR node CLetGroup` |
| … | (see `test/engine_divergence.txt` for the per-fixture reason) |

The real-prelude wasm path (`wasm_emit_modules_main`) has a further known gap —
point-free-impl eta-expansion — documented in `test/wasm/diff_wasm_modules.sh`, which
is why this gate drives the prelude-free `wasm_emit_main` entry.

---

## 5. The ratchet — how the ledger works

`test/engine_divergence.txt` maps a fixture key to the **signature** the gate expects:

```
<key>  <agreement>:<eval>:<native>:<wasm>  <category>  <reason>
```

A fixture **absent** from the ledger is expected to be clean — `agree:ran:ran:ran`.

The gate compares each fixture's observed signature against its expected one and
**fails in both directions**:

* an **un-ledgered disagreement** → `REGRESS` (a new bug)
* a **ledgered entry that starts passing** → `PROMOTE` — a hard failure that says
  *delete its line from the ledger*

That second property is the entire point, and a plain skip-list cannot do it: it is
what stops a fix from silently rotting back later, and what converts this file from a
list of excuses into a bug backlog with a countdown. It is rustc's `tests/crashes`
model.

Regenerate the ledger after a deliberate change with `CAPTURE=1 bash
test/diff_compiler_engines.sh`, **then review the diff**: a brand-new divergence is
written out as a literal `TODO`, never inheriting a plausible-looking excuse from its
neighbours.

---

## 6. Suggested order of attack

1. **§4.1, the 17 missing I/O externs** — biggest user-visible hole; `medaka run` is
   unusable for any real program. Either implement them in `eval.mdk` or make the
   compiler reject the program with a real diagnostic instead of an `E-PANIC`.
2. **§3.1, the RNG/hash LCG** — a two-line-scope fix (install the real SplitMix64 for
   the user-facing externs, keep whatever prop generation wants) that closes 15
   fixtures and a silent `run ≠ build` divergence.
3. **§3.2, the wasm i31 tag leak and the unsignatured-float trap** — two real codegen
   bugs with sharp, verified repros.
4. Everything else is a gap, not a soundness hole, and can wait.
