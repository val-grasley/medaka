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
| **wasm** | `compiler/backend/wasm_emit.mdk` → WasmGC | `medaka build --target wasm` |

Before this gate, **no program in the tree was ever compared across all three**, and
the two backends were validated on essentially disjoint corpora:

| | |
|---|---|
| `test/llvm_fixtures/` | 195 `.mdk` |
| `test/wasm/fixtures/` | 151 `.mdk` |
| basenames in common | **5** |

Worse, the one two-way check that existed was **not a live differential**.
`test/diff_compiler_llvm.sh` diffs the native binary's stdout against
`<fixture>.native.golden` (renamed from `.eval.golden` by #559) — every regenerator
since the OCaml interpreter was deleted on 2026-06-26 replays emit→clang→run, so the
golden **is** a frozen capture of native, comparing native against itself. A bug that
got captured became the **expected answer** for the backend too.

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

**404 fixtures** = the union of ALL FOUR emitter corpora:

| corpus | n | |
|---|---|---|
| `test/llvm_fixtures/` | 201 | untyped, prelude-free |
| `test/llvm_fixtures_typed/` | 45 | its typed sibling |
| `test/wasm/fixtures/` | 149 | untyped, prelude-free |
| `test/wasm/fixtures_typed/` | 9 | its typed sibling |

Deterministic across repeated runs.

> **The two TYPED corpora joined on 2026-07-14, and could not have before.** This gate is
> a THREE-WAY differential, so a fixture must run on all three arms to be in the corpus at
> all — **the corpus is capped by the weakest arm.** Until then the wasm arm was the
> prelude-free probe `test/bin/wasm_emit_main` (no typecheck, no prelude), so no fixture
> that needed the prelude could join, and **the gate structurally could not express a
> type-directed bug** — it could not have caught the record-update miscompile (#38).
> Moving the wasm arm onto `medaka build --target wasm` raised the ceiling and the typed
> corpora walked in. T3 (all three agree) went 263 → 305.

```
 T1  eval   == native    329 agree   15 differ   60 n/a
 T2  native == wasm      336 agree    9 differ   59 n/a
 T3  all three agree     305 agree   22 differ   77 n/a
```

The tiers separate the bug classes cleanly: **T1's 15 are all one interpreter bug**
(§3.1); **T2's 9 are all wasm codegen bugs** (§3.2) — 7 of them on fixtures from the
*LLVM* corpus that the wasm backend had never been run on, plus 2 more that only became
visible once the wasm arm became the shipping compiler.

---

## 3. The 22 disagreements

### 3.1 `eval:rng-hash-lcg` — RESOLVED (issue #98). 15 fixtures, now all `eq` across engines.

**Fixed 2026-07-15.** `compiler/eval/eval.mdk` now emulates a full uint64 over four
16-bit limbs (`add64`/`mulLow64`/`xor64`/`shr64`) and implements the SAME SplitMix64
RNG and SplitMix64/FNV-1a hashers as `runtime/medaka_rt.c`, byte-for-byte. `setSeed 42;
randomInt 1 6` now returns `2` under both `medaka run` and `medaka build`; `hashInt 42`
is `803958421` on every engine. All 15 rows below were promoted out of the ledger. (A
16th, `w8b_rng_float_determinism`, was promoted at the same time: rewriting the mantissa
scale as `intToFloat 9007199254740992` — the exact double 2^53 — instead of a `>= 1e15`
float literal both dodged the `medaka fmt` #51 corruption AND removed a 1-ulp
literal-parse discrepancy that had made the float draw render `…073` under eval vs
`…074` native.) The original analysis is retained below for the record.

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

**Why nothing caught it:** `test/llvm_fixtures/hash_int.native.golden` (then named
`.eval.golden` — renamed by #559) contains `803958421` — the value **native** produces.
The golden had been re-captured from native since the OCaml interpreter was removed,
though the OCaml interpreter (which *did* honour the spec) was its original source.
So the LLVM gate compares native against a golden native agrees with, and no gate ever
ran eval on these fixtures. The frozen golden was laundering the bug. This is the
circularity of §1, caught on the first run of the new gate.

### 3.2 `wasm:codegen-bug` — DISSOLVED (#383). Was 5 fixtures below; now 0 active rows.

⚠️ **The table below is HISTORICAL, not current** (#383 caught this stale 2026-07-16:
the section header used to read "5 fixtures. The WasmGC backend is wrong" — present
tense — long after the rows it counted were gone). **`test/engine_divergence.txt` is
the ledger the gate actually reads; this table is not.** To check the CURRENT count
yourself rather than trust a number here: `grep -vE '^\s*#' test/engine_divergence.txt
| grep -c 'wasm:codegen-bug'`.

Per `test/engine_divergence.txt`'s own header comment (search it for the five fixture
names below), all five of `fn_float_chain`/`debug_charlit`/`debug_strlit`/
`fn_bool_return`/`arr_set_unit` dissolved from the ACTIVE ledger on 2026-07-14 — filed
there as artifacts of the gate's own wasm arm (a prelude-free wasm probe that the
shipping `medaka build --target wasm` path never hit), not genuine backend bugs. ⚠️
That is the `.txt`'s claim, carried here rather than independently re-verified against
a build (this doc-drain pass is text-only, no compiler) — and the SAME file warns two
paragraphs later that an "artifact, not a bug" correction needs the identical proof a
filing does, because an earlier version of exactly this kind of correction (for
`num_int_max`/`num_int_min`/`where_sibling_ref`, see §3.3) turned out to be wrong. If
you need to know whether these five are real bugs or gate artifacts, that still needs a
build-and-probe, not another read of this table.

> **`rng_int_big` FIXED 2026-07-15 (#179).** A later `wasm:codegen-bug` row (added by
> #98) — `randomInt 0 1000000000000000` drew 457532755261734, which the old lowering
> wrapped in a bare `ref.i31` and trapped `illegal cast`. `$mdk_random_int` is now
> i64→i64 and the result reboxes through the `$mdk_box_int` seam (i31 / `$boxint`), so a
> draw above ±2^30 is representable. eval == native == wasm; row promoted out of the ledger.

> **`char_max` / `char_min` FIXED 2026-07-16 (#373).** The two rows blamed `charCode`
> for "leaking the i31 tag". **That diagnosis was wrong** — `charCode` is an identity in
> ref mode (`wasm_emit.mdk:emitLeafExternRef "charCode"`) and never touched a tag. The
> leak was in the bound CONSTANTS: `emitVarRefPlain` emitted `i32.const 1` /
> `i32.const 2228223` — llvm_emit's peer constants, which are correct THERE because
> native's word is tagged (`2·cp+1`) — into a wasm `ref.i31`, whose payload is
> **untagged**. So the tag arrived as part of the value. Now `i32.const 0` /
> `i32.const 1114111`, matching `emitLitRef (LChar _)` and every `i31.get_u` pattern
> test. eval == native == wasm; both rows promoted out of the ledger, and both fixtures
> gained absolute value pins (`test/engine_value_pins/llvm/char_{max,min}.pin`) so a
> future unanimous-but-wrong answer cannot hide behind the differential.
>
> The symptom the rows recorded (`charCode charMaxBound` printing 2228223) was only the
> printing half. Comparisons against the bounds were silently wrong too —
> `charMinBound <= c` was False for `c` = U+0000, i.e. every lower range check /
> validator. That frontier is now pinned by `llvmT/char_bounds_cmp`, which deliberately
> avoids the obvious probes: `charMinBound <= 'A'` and `'A' <= charMaxBound` both
> answered True on the BROKEN emitter (1 ≤ 65 ≤ 2228223 holds by luck), so a fixture
> built from those would have gone green.

All five are from `test/llvm_fixtures/` — a corpus the wasm backend had never seen.

| fixture | eval | native | wasm | diagnosis |
|---|---|---|---|---|
| `llvm/fn_float_chain` | 10.0 | 10.0 | **trap** | `illegal cast`. **Verified**: adding `f : Float -> Float` signatures makes it emit and run correctly. The wasm float detection is *signature-driven* (`declSigTypeNames`, per the 2026-06-30 float hardening), so an **unsignatured** float function is mis-typed as Int and the `ref.cast` traps. eval and native both infer it correctly. |
| `llvm/debug_charlit` | `'\n'` | `'\n'` | **trap** | `illegal cast` in `debugCharLit`. |
| `llvm/debug_strlit` | `"a\tb\"c"` | `"a\tb\"c"` | **trap** | `illegal cast` in `debugStringLit`. |
| `llvm/fn_bool_return` | True | True | **1** | The wasm scalar auto-print renders a `Bool` main as `1`. Formatting, not a value bug. |
| `llvm/arr_set_unit` | *(empty)* | *(empty)* | **0** | The wasm scalar auto-print renders a `Unit` main as `0`; the other two correctly print nothing. |

*(As originally diagnosed: the first three read as genuine codegen bugs, the last two as
auto-print formatting — see the ⚠️ note above §3.2's table before treating that as
settled.)* All five existed **only** because the two backends' corpora were disjoint —
which is precisely the thesis this gate tests.

### 3.4 `wasm:codegen-bug` — 3 ACTIVE rows, found by the #707 `eval_fixtures` promotion

These are **live** rows (category `wasm:codegen-bug`) — not the historical §3.2 table.
Issue #707 promoted `test/eval_fixtures/` (interpreter-only until then) into
`test/engine_fixtures/` so it runs the 3-engine differential. Three fixtures reproduce a
real `run != build` divergence: **eval == native, and the `medaka build --target wasm`
CLI path fails** (the wasm arm is `na` — the module never assembles/validates). The
engines-corpus row IS the self-draining pin for each issue: when the WasmGC backend is
fixed the wasm arm flips to `ran` and this gate goes RED, naming the issue to close.
(These wasm-build bugs are NOT pinnable by the must-fail suite — it has no `build` verb;
see `test/MUST-FAIL-NOT-PINNABLE.txt`.) The eval/native value is pinned in
`test/engine_value_pins/engine/<name>.pin` (only the arms that ran are checked, so the
`na` wasm arm never trips the pin).

| fixture | eval == native | wasm | issue | diagnosis |
|---|---|---|---|---|
| `engine/adt_user_cons_nil` | `(60, 3, 0)` | **parse fail** | #712 (S1) | wasm-tools **parse** rejects the WAT: *"duplicate type identifier"* on `$C_Cons`. A user ADT `data T = Cons Int T \| Nil` collides with the built-in list type ids the WasmGC backend synthesises for the reserved `Cons`/`Nil` names, declaring `$C_Cons`/`$T_List` twice. |
| `engine/hof_compose` | `(12, [2, 3, 4], 10, 11, 22)` | **validate fail** | #713 (S2) | wasm-tools **validate** rejects the module: *"type mismatch: expected i32, found (ref eq)"* — an i32↔(ref eq) boxing-lattice mismatch in the WasmGC backend on the list + HOF/compose/section closures. |
| `engine/effect_poly` | `(9, 81, 9)` | **validate fail** | #714 (S2) | wasm-tools **validate** rejects the module: *"type mismatch: expected (ref eq), found i32"* — the mirror i32↔(ref eq) boxing mismatch on the effect-polymorphic combinator's Ref-mutating instantiation. |

All three are genuine `run != build` divergences (eval and native agree on the correct
value; only wasm fails), exactly the class this gate exists to surface. The native LLVM
backend handles all three correctly — the defect is WasmGC-only.

### 3.5 `#710` — promoting `eval_dict_fixtures`/`eval_typed_fixtures`: 4 more divergences

Issue #710 promoted the interpreter-only `test/eval_dict_fixtures/` (dict-passing/dispatch —
this repo's #1 `run != build` class) and `test/eval_typed_fixtures/` onto the 3-engine
differential. 35 fixtures agree cleanly across all three engines; **four reproduce real
divergences.** Three are the same `wasm:codegen-bug` shape as §3.4 (eval == native, wasm
build fails). The fourth is different and worse — a **silent native+wasm miscompile**.

| fixture | eval == native | wasm | issue | diagnosis |
|---|---|---|---|---|
| `engine/impl_requires_terminal_body` | `2 / 11 / 21 / 2` | **validate fail** | #717 (S1) | wasm-tools **validate** rejects: *"values remaining on stack at end of block"*. A TERMINAL return-position impl body that IGNORES its forwarded `requires` dict (`impl S (List a) requires S a where s _ = 2`) leaves the over-supplied dict on the WasmGC operand stack; native's `usesImplDict` gate drops it correctly. |
| `engine/instance_terminal_default` | `[]` | **validate fail** | #717 (S1) | Same terminal-impl-body defect, `impl Default (List a) requires Default a where def = []` — the terminal value leaves the forwarded element dict on the stack. |
| `engine/prelude_default_parametric_requires` | 13-line `True/False/…` block | **validate fail** | #718 (S1) | wasm-tools **validate** rejects: *"expected (ref eq) but nothing on stack"*. A user `impl Ord (Box a) requires Ord a` defining only `compare` and INHERITING the prelude `lt`/`gt`/`min`/`max` defaults: the WasmGC inherited-default emit path (eta-prepending the forwarded `requires` dicts) leaves the operand stack short a `(ref eq)`. |
| `engine/return_pos_memoised` | **eval ≠ native** | `ran` (wrong) | #719 (**S0**) | `emitter:nullary-memo-dup`. A nullary return-position impl method with a side effect, used twice at one concrete type, runs its body ONCE under eval (memoised) but **TWICE under `medaka build` on BOTH backends**: `[eval] XX` vs `[eval] [eval] XX`. Signature `ne:eq:ne` — eval disagrees with native == wasm. **Silent** (no error). NOT value-pinnable (both wrong arms `ran`; the #86 pin layer has no per-arm ledger consult), so the `ne:eq:ne` row IS the pin. |

The first three are WasmGC-only (native LLVM is correct). `#719` is the standout: **both
compiled backends** are wrong and only the interpreter is right — a true silent `run !=
build`, exactly the class §1 says a differential-only gate cannot see without a value oracle,
here caught by eval being the value oracle for native/wasm.

`inferred_chain` (unsignatured inferred-constraint propagation through a call chain) was
NOT promoted: the shipping compiler REJECTS it uniformly (`medaka run` AND `medaka build`
both error *"Ambiguous instance for Monoid"*) — only the lenient `eval_autoprint_main`
oracle accepts it, so it is an oracle artifact, not a backend divergence. Its signatured
twin `monoid_nested` IS promoted and clean.

---

## 4. The engine-unavailability categories

Most ledgered fixtures cannot be run by at least one engine (derive the current tally —
never cite an encoded one: `grep -v '^#' test/engine_divergence.txt | grep -c ':na'`; note
#709 moved the 26 pure `native:prelude-collision` rows out to the rejection-parity gate).
These are ledgered, never silently skipped, and each carries its specific reason.

### 4.1 `eval:extern-not-implemented` — 23 fixtures (was 25). **`medaka run` could not do I/O.**

> **STATUS 2026-07-13 — LARGELY FIXED.** `medaka run` now installs real host I/O
> primitives from `eval.mdk`'s **`ioExternBindings`** table (the "host is the
> handler" seam — `EFFECTS-SEMANTICS.md` §7): the File family (12), Env
> (`args`/`getEnv`/`executablePath`), Stdin (4), Clock (`wallTimeSec`/
> `monotonicSec`/`sleepMs`), `allocBytes`, and `ePutStr`/`ePutStrLn` (which
> previously **silently discarded all stderr**). `arrayFill`/`arraySortInPlaceBy`/
> `arraySortBy` — pure/untracked-mutation, no I/O at all — went into the shared pure table.
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

### 4.3 `eval:unsupported-node` — 0 fixtures (FIXED 2026-07-13)

`wasm/w7_variant_update` → was `E-PANIC: eval: unsupported node (slice 2)` (bug #32):
`compiler/eval/eval.mdk`'s `eval` had no `EVariantUpdate` arm at all. Fixing it surfaced
a second, deeper gap in the pre-existing `evalVariantUpdate` helper (already used by
`core_ir_eval.mdk`'s `cevalModules`): it only matched a `VCon` base, but the tree-walking
`run` path's own `ERecordCreate` arm never populates `ctorFieldOrdersRef` (only the
Core-IR lowering/eval drivers do), so a named-field constructor value on `run` is always
a `VRecord`, never a `VCon` — `evalVariantUpdate` needed a matching `VRecord` arm too.
Both fixed in lockstep; `wasm/w7_variant_update` now agrees on all three engines and its
`test/engine_divergence.txt` line was deleted (promoted).

### 4.4 `eval:intended-abort` — 5 fixtures

`llvm/abort_panic` (`E-PANIC: boom`), `wasm/w7_array_oob` (`E-INDEX-OOB: index 9
out of bounds`), `llvm/eager_global_self_cycle` (`E-CYCLIC-VALUE`, #561 PR-A+PR-B), and two
PR-C regression-corpus additions covering other cycle shapes: `llvm/eager_global_mutual_cycle`
(a two-node mutual cycle, `x = y + 1` / `y = x + 1`) and `llvmT/eager_global_dispatch_hidden_cycle`
(a self-cycle whose back edge is hidden behind interface-method dispatch, `cell = mk True` /
`mk _ = cell + 1`) — both `E-CYCLIC-VALUE`. These are the *program's own* intended aborts, not
engine failures —
the gate's eval-arm classifier is deliberately conservative (any interpreter-level
`E-*` counts as n/a, because today the interpreter has no `exit` primitive, so a
nonzero exit is never a program-level exit). Ledgered explicitly rather than
special-cased, so the conservatism is visible instead of hidden.

`eager_global_self_cycle` (`x = x + 1`, a genuine non-productive value cycle)
**migrated INTO this category** from `emitter:shared-eager-init` once #561 landed on both
backends. Pre-fix, both backends mis-emitted the eager topo-sort (a value cycle has no
static order); PR-A (native) and PR-B (wasm) now emit dispatch-reaching / cyclic nullary
globals LAZILY (`emit_support.lazyGlobalNames` → native `@mdk_force_x`/`@mdk_gs_x`, wasm
`$force_x`/`$gs_x` 3-state), so all three engines raise the SAME coded `[E-CYCLIC-VALUE]`.
The category `emitter:shared-eager-init` asserts a shared-primitive defect where a backend
is WRONG; post-PR-B neither is, so the correct claim is `eval:intended-abort`. The **four
dispatch-reaching fixtures** in that family — `llvmT/eager_global_{dispatch_hidden,
lazy_bool, lazy_float, lazy_string}` — return a real value (42 / 1 / 3.5 / hello world),
so once PR-B fixed the wasm arm they became fully `eq:eq:eq` and were **promoted out of the
ledger entirely** (deleted). `emitter:shared-eager-init` now has ZERO `eager_global_*`
rows; the remaining `eager_global_{list,string}_slice` rows are `wasm:emitter-gap`
(a lowering gap, unrelated).

### 4.5 `native:prelude-collision` — MOVED OUT of this ledger (#709)

`test/llvm_fixtures/` and `test/llvm_fixtures_typed/` are **prelude-free** corpora:
fixtures redefine `IntList`, `Point`, `Option`, or a core interface (`Eq`, `Ord`,
`Semigroup`…) which collide with `stdlib/core.mdk` under a real `medaka build`. This is
a property of the corpus, not a compiler bug — it is exactly why `diff_compiler_llvm.sh`
drives the prelude-free `llvm_emit_main`/`llvm_emit_typed_main` entries (which prepend
nothing) rather than `medaka build`.

These fixtures made **ZERO cross-engine value comparison** in `diff_compiler_engines.sh`
(signature `na:na:na:*` — no two arms both `ran`): they only ever asserted that both
shipping backends REJECT them identically, which is a *rejection* property, not the value
*agreement* this differential exists to prove. Per #709 the **26 pure prelude-collision
rows were removed from this ledger** and re-homed into a dedicated rejection-parity gate:

- **manifest**: `test/rejection_parity_fixtures.txt` (the 26 keys)
- **gate**: `test/diff_compiler_rejection_parity.sh` — asserts native `medaka build` AND
  wasm `medaka build --target wasm` both reject each fixture. Self-draining: if a fixture
  starts COMPILING on either backend it goes RED and names it ("re-home it"); `checked 0`
  is a FAIL; a manifest key with no fixture file is a FAIL. It rides the `engines` CI shard
  (the only one with the wasm toolchain + `MEDAKA_REQUIRE_WASM=1`).

`diff_compiler_engines.sh` now EXCLUDES every manifest key (via `keyfor` + the manifest),
so its headline count reflects fixtures that actually compare. **Only 2 rows remain in
this ledger under this category**: `llvm/rec_build` and `llvm/rec_update` — they ALSO hit
a `wasm:emitter-gap` (native rejects the redefined `Point`; wasm panics on `CRecord`), so
the two backends do NOT reject for the same reason and they are NOT identical-rejection
fixtures. They stay here.

### 4.6 `native:autoprint-ambiguous` — 1 fixture

`llvm/abort_panic`: `main = panic "boom"` has a polymorphic type, so the value-main
auto-print wrap (`main = println <e>`) cannot resolve a `Display` instance →
`Ambiguous instance for Display`. Arguably a real diagnostic gap for bottom-typed
mains.

### 4.7 `wasm:emitter-gap` — count DERIVED, never encoded (see the ⚠️ below)

> **`math_externs`, `bitwise_ops`, `lit_int_large_tag` FIXED 2026-07-15 (#101).** The 23
> libm math externs (sqrt/floor/ceil/trunc/round + transcendentals + pow/atan2/hypot +
> floatRem) and the 4 bitwise externs (bitOr/bitXor/bitNot + intBitsToFloat) are now
> ported to wasm — IEEE-exact ops → native f64 opcodes, `round` → `$mdk_round`
> (C round(), half away from zero), transcendentals → JS `Math.*` host imports, bitwise →
> i64 ops over the `$mdk_box_int`/`$mdk_unbox_int` seam. `lit_int_large_tag` was a fourth
> row here (it uses `intBitsToFloat`). All three promoted; capability rows deleted.

> **Recursive `let..in` + refutable pattern guards FIXED 2026-07-16 (#379).** Five rows
> promoted: `lam_rec_tuple`, `let_local_fn`, `let_local_rec`, `rec_local` (all
> `ref-mode: recursive let binding`) and `guard_refut_ctor` (`ref-mode: refutable pattern
> guard (p <- e) in a tail match arm`). Both were wiring gaps, not design gaps.
> (1) `emitLetRef` had no `True (PVar x) (CLam …)` clause, so a recursive
> function-`let` in EXPRESSION position hit the catch-all — while the *block-statement*
> form of the same binding already routed to `emitSelfRecLocalBind`. That asymmetry was
> the whole bug; the `let..in` arm now takes the same route (peer of the native emitter's
> `emitLet … True (PVar f) (CLam …)` → `emitRecLam`).
> (2) Guards were emitted by `flatMap` over a FIXED env, which structurally cannot bind
> a name for later guards or the body. `emitGuardChainRef` now threads the env and lowers
> `CGBind` via the existing `patTestBind` (wasm's peer of native's `emitRefutMatch`) —
> a failed test `br`s to the same `$g<d>`/`$gt<d>` guard block the CGBool path always
> used, so the fall-through mechanism was reused verbatim, not redesigned.
> One genuinely new piece: wasm must PRE-DECLARE every local, whereas the native peer
> just reuses the SSA register `emitExpr` returns. The guard RHS is therefore stashed in
> `guardStashLocal` (`$__gbind`), declared via `collectGuardLocals`. ONE slot per function
> is sufficient — a stash is consumed (tests ++ binds) immediately after it is set, and a
> nested `CGBind` inside the RHS finishes evaluating before the outer `local.set`, so live
> ranges never overlap.

> ⚠️ **This note has now been wrong THREE times, in three different ways — the heading no
> longer carries a number at all.**
>
> 1. It said `26 fixtures` while the ledger held **31**, so the obvious `26 − 5 = 21`
>    would have been wrong twice over. Hence: *derive it, never subtract it.*
> 2. **The derivation it then prescribed was ITSELF WRONG.** `grep -c 'wasm:emitter-gap'
>    test/engine_divergence.txt` returns **24** — but ~20 of those hits are the category
>    NAME appearing in this ledger's own header prose and category list, not rows. Anyone
>    following the recipe got a confidently wrong number *from the very paragraph warning
>    about confidently wrong numbers.*
> 3. Consequently the `26` stood while the true row count fell to **2** (2026-07-17, #597).
>
> **Count ROWS, keyed on the category FIELD, skipping comments:**
> ```sh
> grep -v '^#' test/engine_divergence.txt | awk '$3=="wasm:emitter-gap"' | wc -l
> # every category at once, and it must sum to the gate's own `known (ledgered)` figure:
> grep -v '^#' test/engine_divergence.txt | grep -v '^[[:space:]]*$' | awk '{print $3}' \
>   | sort | uniq -c | sort -rn
> ```
> ⚠️ **The other `### 4.x` headings in this section carry the same class of encoded count.**
> §4.5 `native:prelude-collision` used to say *7 fixtures* while the ledger held **28**; that
> section has since been rewritten (#709 moved its 26 pure rows out to the rejection-parity
> gate, leaving 2) and now carries no encoded row count at all. The remaining `### 4.x`
> headings were not audited. **Derive before you cite any of them.**

The WasmGC emitter cannot produce a module that assembles and validates. It reports
its own gaps, which is to its credit. Distinct causes, by frequency:

| n | gap |
|---|---|
| 5 | `ref-mode: unbound variable 'writeFile'` (and `statFile`, `runCommand`, …) — the I/O externs, same set as §4.1 |
| 4 | `wasm-tools parse: unknown func $mdk_char_to_str` — the preamble omits a helper it emits calls to |
| 4 | `ref-mode: unsupported pattern in match arm` |
| 4 | `ref-mode: unbound variable 'index'` |
| 3 | `wasm-tools validate: func N failed to validate` |
| 2 | `wasm-tools parse: unknown type $str` |
| 2 | `scalar-mode: unsupported Core IR node CRecord` |
| 2 | `scalar-mode: unsupported Core IR node CLetGroup` |
| 2 | `ref-mode: unsupported Core IR node ? [in lg:concatRev]` — the slice receivers: `eager_global_list_slice`, `eager_global_string_slice` (#597, reproduced 2026-07-17). eval and native both run and are **correct**; only wasm cannot lower the node, and it says so. Note the `?` — the diagnostic does not name the node it choked on, which is the one thing it most needs to say |
| … | (see `test/engine_divergence.txt` for the per-fixture reason) |

> ⚠️ **The paragraph that used to sit here was stale, and it was load-bearing.** It said
> the real-prelude wasm path had a point-free-impl eta-expansion gap "which is why this
> gate drives the prelude-free `wasm_emit_main` entry". That gap is closed
> (`installMethodIface`, W9b), and driving the probe was costing far more than it saved:
> **17 ledger rows blamed on the wasm backend were artifacts of the probe**, and they
> dissolved the moment the arm moved to the shipping CLI (2026-07-14). See
> `test/engine_divergence.txt`'s header for the list and the discriminating test.
>
> The flip also **newly exposed 8 real wasm bugs on the path users actually run** — six
> modules that validate and then trap at instantiate (`unreachable` / `illegal cast` /
> JS-stack overflow), and one (`clos_partial_app`) that fails GC validation outright.
> Several of these were *clean under the probe*: the shipping wasm path is genuinely
> worse than the spike path, and nothing was measuring it.
>
> **All 8 are now FIXED** (2026-07-14): the two TMC ones by the dict-veto fix, and the
> other six in `compiler/backend/wasm_emit.mdk` — see §3.3.

### 3.3 The 6 shipping-path wasm bugs — FIXED 2026-07-14

`llvm/{num_int_max, num_int_min, where_sibling_ref}`, `llvmT/float_typelost_tuple`,
`wasm/{polynum_sq_sig_float, clos_partial_app}`. All promoted out of the ledger.

**The three `illegal cast` fixtures did NOT share one root — they had two.** (Worth
saying, because "one symptom ⇒ one cause" was the natural guess and it was wrong.)

| fixture | root cause | native peer that already existed |
|---|---|---|
| `num_int_max` / `num_int_min` | `emitVarRef` emitted a literal `unreachable` **trap-stub** for the Int bounds, on the *stale* grounds that a 64-bit bound "overflows i31". Layer-17 gave ref-mode the `$boxint` i64 box; the stub was never revisited. Now `i64.const <value>` + `$mdk_box_int`. | `llvm_emit` emits the tagged word. |
| `where_sibling_ref` | **`illegal cast` root #1.** `emitLetGroupRef` lambda-lifted *every* let-group member uniformly — including a nullary **VALUE** binding (`base = 10`), which became an arity-0 closure that was never forced. A sibling's `x + base` then ran `$mdk_unbox_int` over a `$clos`. Values are now evaluated at the use site and passed to the lifted members as ordinary captures. | `llvm_emit.emitLetGroup` has always had a dedicated `CBind n [CClause [] rhs]` arm. |
| `polynum_sq_sig_float` + `float_typelost_tuple` | **`illegal cast` root #2, shared by both.** An arithmetic operand whose type is known only at RUNTIME fell through to the inline i31 int primitive, which `ref.cast`s a boxed `$float`. Two independent under-seedings of `numPolyLocalsRef`: (a) `numPolyPatsAt` lined declared param types up against lowered params **without skipping the prepended `$dict_*` params**, so `sq : Num a => a -> a`'s type-var head `a` matched the *dict* slot — i.e. the explicit `Num a =>` signature was precisely what *disabled* dispatch; (b) **match-arm pattern binders** (tuple/ctor payload) were never seeded at all. | `llvm_emit` routes both to the runtime tag-dispatched `@mdk_num_*` helpers — via `inferParamTysSeedD` (whose comment names the dict misalignment as "the G3 root cause") and `binOperandTy`→`LTNum`. |
| `clos_partial_app` | `emitMethodRef`'s **`RLocal`** arm emitted a raw direct `call` with **no arity guard**, so an under-application pushed too few operands and the module failed GC validation. `inc = add 1` reaches that arm — not the (correctly guarded) `CVar` arm — because `add` shadows the prelude `Num.add` method name, so the marker rewrites it to `CMethod "add" (RLocal …)`. **That is exactly why the prelude-free probe never saw it** (no marker ⇒ a plain `CVar` head). Under-applied calls now route to `$__mdk_apply`, whose under-app arm builds the PAP. | `llvm_emit`'s RLocal arm delegates to `emitKnownFnSat`, which "builds a residual PAP when genuinely under-applied". |

**The pattern across all six: the native backend already had the guard and wasm lacked
it.** Core IR is deliberately type-erased, and each backend re-derives numeric type and
saturation facts in its own value representation (native: low-bit-tagged i64 + the `LTy`
lattice; wasm: `(ref eq)` with `i31`/`$float`/`$boxint` + boolean predicate refs). There
is no shared place to put these fixes short of a *typed* Core IR — so they are correctly
per-backend. What IS shared is now shared: `isDictParamName` moved to
`backend/emit_support.mdk`, since both backends need it for the same reason.

Note the wasm runtime helpers these route to (`$mdk_value_add/sub/mul/div/mod`, the peers
of native's `@mdk_num_*`) **already existed** — the bug was never a missing helper, only a
predicate that failed to reach them. On an `Int` instantiation they are byte-identical to
the inline int path, so only correctness moved, never a value.

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
2. ~~**§3.1, the RNG/hash LCG**~~ — DONE (issue #98, 2026-07-15). eval.mdk now runs the
   real SplitMix64/FNV-1a over a 4-limb uint64 emulation, byte-identical to native/wasm;
   prop generation keeps its own LCG. Closed 16 fixtures and the silent `run ≠ build`.
3. **§3.2, the wasm i31 tag leak and the unsignatured-float trap** — two real codegen
   bugs with sharp, verified repros.
4. Everything else is a gap, not a soundness hole, and can wait.
