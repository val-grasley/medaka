# PRELUDE-OBJ-DESIGN.md — precompiling the prelude to a shared object

**Status:** SHIPPED. Issue #118. `medaka build --emit-prelude-obj <path>` +
`MEDAKA_PRELUDE_OBJ`, opt-in exactly like `MEDAKA_RT_OBJ`; soundness gate
`test/diff_compiler_prelude_obj.sh`; wired into `diff_compiler_engines.sh` and
`build_oracles.sh`.

**The blocker in §5(e) is GONE, and §6's decision was overtaken by events.** That
section is right that a program's own `impl` decls used to structurally rewrite core
prelude bodies — but the fix was neither Option D (partition) nor Option E (rewrite the
dict representation). **Outlining the dispatch chain** (issue #118 step 2, PR #129 —
Option C, which §6 called "cleaner, riskier") moved every chain into a shared
`@mdk_disp_<method>_<nMeth>_<nArgs>` define, and prelude bodies became program-independent
outright. Verified against two programs differing only by an `impl Eq Color`: of the 249
shared prelude defines, **zero differ structurally** — only the module-global gensym
counter shifts the `@mdk_lamN`/`@mdk_etac_*_N` names.

**Read §1–§5 for the mechanism and the measurements. Do NOT act on §6 — the decision it
poses was answered by outlining, and Prereq A (renumber the prelude gensyms) turned out
to be UNNECESSARY: the two halves are emitted by independent emitter runs, so they simply
take disjoint gensym ranges (`programHalfIdBase`, `compiler/backend/llvm_emit.mdk`).**

⚠️ **§4's binary-size table is STALE and its −51% is not reproducible today.** It was
measured before `--gc-sections` landed in the default link line (issue #120), so its
"Today" baseline is an un-GC'd binary. Measured on the shipped implementation, with
`--gc-sections` on BOTH arms, the split build is **+20% larger** (23,328 → 28,064 B on
`adt_enum_nullary`) — cross-module inlining is lost, so more prelude sections stay
referenced. The size is a real, modest COST, not a win.

Every number in §1–§5 was measured on this box (x86_64 Debian 13, 12 cores) with the
binary built from `19011a98`, min-of-5, and is reproducible from §8. The shipped
implementation's numbers are in the PR.

---

## 1. The problem

A **9-line** fixture (`test/wasm/fixtures/adt_enum_nullary.mdk`) emits **32,895 lines
of LLVM IR** with **272 `define`s — exactly one of which is the program's own.** The
other 271 (99.6%) are prelude. `clang -O2` re-optimizes all of it on every single
`medaka build`.

Measured decomposition of one `medaka build` of that fixture, with the existing
`MEDAKA_RT_OBJ` fast path already ON:

| Step | Time | Share |
|------|------|-------|
| `medaka build` end to end | **1.185 s** | 100% |
| ↳ emitter (front end) | 0.300 s | 25% |
| ↳ **`clang -O2` on the emitted IR** | **0.859 s** | **72%** |

`diff_compiler_engines` — CI's critical-path gate — pays this **346 times**.

## 2. The precedent this mirrors

`MEDAKA_RT_OBJ` (`compiler/driver/build_cmd.mdk:462-468`) precompiles
`runtime/medaka_rt.c` once via `medaka build --emit-rt-obj` (`emitRtObj`, line 484)
and links the object, saving ~0.6 s/build. Its soundness gate is
`test/diff_compiler_rt_obj.sh`, which proves the inline and prebuilt link paths
produce a **byte-identical binary**. This design is the same shape one level up.

## 3. The prototype, and the win

Hand-split the kept `.ll` into a prelude half and a program half, compile the prelude
half once, and link it per program.

| | Time (min-of-5) |
|---|---|
| **Today**: full IR + `rt.o` → binary | **0.859 s** |
| One-time: full prelude → `prelude.o` (`-O2 -ffunction-sections -fdata-sections`) | 0.998 s |
| **Proposed per-build**: 555-line program `.ll` + `prelude.o` + `rt.o`, `-Wl,--gc-sections` | **0.075 s** |

**11.4× on the clang step.** The whole `medaka build` would go 1.185 s → ~0.40 s
(~3×); clang's share of a build drops from 72% to ~19%.

Both binaries produce identical output (`30`). Extrapolating to
`diff_compiler_engines`: 346 builds × ~0.78 s = ~270 CPU-seconds removed. For
calibration, `MEDAKA_CLANG_OPT=-O0` saves ~0.6 s/build and moves that gate
127 s → 76 s wall; this saves *more* per build **and is sound**, so a similar or
better wall reduction is expected. (Wall projection is an extrapolation, not a
measurement — the gate has not been run against a real implementation.)

## 4. The three questions the issue asked — answered

### Q1. DCE — does `--gc-sections` recover the binary size? **YES, and then some.**

The prelude is currently DCE'd per program (`dceFilter`, called at
`compiler/entries/llvm_emit_modules_main.mdk:73`). A prebuilt object must ship the
**whole** prelude and let the linker GC it. Measured, on the same fixture:

| Binary | Size | vs today |
|--------|------|----------|
| **Today** (source-DCE'd prelude, one object, no linker GC) | 192,336 B | — |
| Full prelude object, **`--gc-sections`** | **94,632 B** | **−51%** |
| Full prelude object, **no** `--gc-sections` | 216,048 B | +12% |

`--gc-sections` is not merely a mitigation — it is a **size win**. The linker's GC is
strictly more precise than source-level DCE, which by design keeps every `DImpl`/
`DInterface` **whole** (pruning an impl would be a silent miscompile under runtime
dict-passing — see `compiler/ir/dce.mdk:11-20`). The linker follows real relocations,
so it drops impl *bodies* that source DCE must retain.

Without `--gc-sections` the size regression the issue feared is real (+12%), so the
flag is load-bearing. ⚠️ **Dual-platform:** it is `-Wl,--gc-sections` on Linux and
`-Wl,-dead_strip` on macOS. Both arms must be kept alive.

**Side finding — `dce.mdk`'s stated rationale is STALE.** Its header
(`compiler/ir/dce.mdk:3-9`) says emitting the real `stdlib/core.mdk` *aborts* because
`maximum`/`minimum`/`clamp` hit the open `max`/`min` arg-tag-dispatch gap
(EMITTER-GAPS.md residual #2). **That gap is closed.** All three build and run on the
current binary:

```sh
printf 'main = println (clamp 1 10 42)\n'   > /tmp/p.mdk && ./medaka build /tmp/p.mdk -o /tmp/p && /tmp/p   # 10
printf 'main = println (maximum [3, 1, 2])\n' > /tmp/p.mdk && ./medaka build /tmp/p.mdk -o /tmp/p && /tmp/p # Some 3
printf 'main = println (minimum [3, 1, 2])\n' > /tmp/p.mdk && ./medaka build /tmp/p.mdk -o /tmp/p && /tmp/p # Some 1
```

And an emitter patched to skip `dceFilter` entirely emits the full prelude
successfully (exit 0, 38,537 lines, 351 defines, 67 `mdk_core__*` fns vs 9 DCE'd).
So "the whole prelude cannot be emitted" is no longer true, and `dce.mdk`'s header
needs correcting independently of this work.

### Q2. Cross-module inlining — lost. Does it matter? **Not for the CI use case.**

Prelude functions in a separate object cannot inline into user code without LTO. This
was **not** measured for runtime cost, and it should not be assumed negligible: the
prelude is where `==`, `compare`, `fold` and friends live. The conservative conclusion
stands on its own — this must be an **opt-in fast path for test/CI builds**
(`MEDAKA_PRELUDE_OBJ`, exactly parallel to `MEDAKA_RT_OBJ`), **never the default for
`--release`.** Fixtures need correct output, not speed. Quantifying the `--release`
cost is an open item (§7).

### Q3. Tail calls across the object boundary. **Sound.**

`-O0` broke `wasm/clos_reftco_indirect` because the emitted IR carries **zero**
`tail call`/`musttail` markers (verified: `grep -c 'musttail\|tail call'` on the
emitted `.ll` returns **0**) — *all* TCO comes from clang's own tail-call elimination,
which for **indirect** calls only runs at `-O1`+.

This design keeps **both** halves at `-O2`, so that mechanism is intact. Verified on
the exact fixture `-O0` broke — 3,000,000 frames, tail indirect closure call:

```
split-object build (prelude.o + program.ll, --gc-sections) -> 1000005, exit 0
today's `medaka build` (control)                           -> 1000005, exit 0
```

## 5. What the prelude IR actually depends on

The design lives or dies on this. Findings, in order of discovery:

**(a) The prelude IR is emitted from a single global gensym counter
(`Emit.counter : Ref Int`, `compiler/backend/llvm_emit.mdk:757`, drawn by `freshId`,
line 781).** It names `%tN` temps, block labels, `@mdk_lamN`, `@mdk_eta*_N`,
`@.strc.N`, and `@mdk_dc_N`.

**(b) `mdk_program_main` is emitted FIRST** (`llvm_emit.mdk:9309`), *before*
`emitFns`/`emitImpls` emit the core decls. It is the top-level initializer, so its
length depends on the program — and it burns counter values, shifting every prelude id
by a program-dependent offset. Measured across two fixtures: **21 of 272 prelude
define *names* differ**, and 240 of 250 shared define *bodies* differ. But after
normalizing the gensym numbering, **249 of 249 prelude defines are structurally
identical.** The difference is *purely* a counter offset.

**(c) Proof that (b) is the whole story for program *bodies*.** Two programs with the
same top-level *shape* (same number of top-level bindings) but completely different
function bodies emit a **byte-identical 38,487-line prelude** (same md5). So the
prelude IR is a pure function of (`core.mdk`, `runtime.mdk`, emitter) plus the counter
state when core lowering begins.

**(d) End-to-end proof that sharing works.** Compiled one program's prelude half to
`prelude.o` and linked a *different* program's program-half against it:

```
p2's program half + p1's prelude.o  -> 111   (correct)
p1's program half + p1's prelude.o  -> 30    (correct)
```

**(e) ⚠️ THE COUNTEREXAMPLE THAT KILLS THE NAIVE DESIGN.** A program's own **`impl`
decls structurally rewrite core prelude function bodies.** Adding a single

```medaka
impl Eq Color where
  eq a b = ...
```

to an otherwise identical program **structurally changes 8 core prelude defines** (not
just their numbering):

```
mdk_core__neq, mdk_impl_List_eq, mdk_impl_Option_eq, mdk_impl_Result_eq,
mdk_impl___tuple2___eq, mdk_impl___tuple3___eq, mdk_impl___tuple4___eq,
mdk_impl___tuple5___eq
```

Each grows a new arm:

```llvm
  %t154 = icmp eq i64 %t4, 210671116836          ; Color's type tag
  br i1 %t154, label %dispyes155, label %dispnext155
dispyes155:
  %t156 = call i64 @mdk_impl_Color_eq(i64 %arg1, i64 %arg2)
```

The emitter **inlines an exhaustive tag-dispatch chain over every impl of the interface in
the whole program** into the prelude's own bodies. It is the dispatch mechanism, not a fast
path that could simply be dropped.

> ### ⚠️ CORRECTED 2026-07-14 — this section originally blamed the wrong function, twice
>
> 1. **It is NOT `detectDispatchGroups` / `gDispStage1Claims` (`llvm_emit.mdk:9290-9298`).**
>    That is **TRMC dispatch-graph grouping** — *tail-recursion-modulo-cons*
>    (`compiler/backend/trmc_analysis.mdk:3`) — and has **nothing to do with impl dispatch.**
>    The real builder is `emitMethodDispatchChain` → `emitDispatchChain` → `emitDispatchArm`
>    (`llvm_emit.mdk:4037` / `:4172` / `:4155`), fed by **`implsOf`** (`:956`), the
>    whole-program impl table.
> 2. **The chain's terminal is `unreachable`** (`llvm_emit.mdk:4173`), not *"the final
>    `dispnext` branches straight to the join block"*. The conclusion was right; the evidence
>    was not.
>
> Both errors propagated into a downstream agent prompt before being caught. Recorded rather
> than silently corrected, because *a wrong root cause launders itself into every artifact
> that cites it.*

### 🔑 And the root cause is one level DOWN — in the dict REPRESENTATION

The chain is not an *alternative* to dict-passing. **It is HOW you consume this dict.**
**A Medaka dict carries no code pointers — it is a type TAG:**

```
llvm_emit.mdk:4421   -- allocate a boxed dict-witness cell `[ i64 headTag | i64 req_0 | … ]`
eval.mdk:114         | VDict String (List (Value e))
```

Field 0 is `hashName(impl-head-tag)`; fields 1..n are nested witness cells. There is nowhere
to put a function. So *projecting a method out of a dict* necessarily means **comparing that
tag against every impl of the method** (`loadTag`, `:4040`; `icmp eq`, `:4159`).

**The route choice (`RDict`) is deliberate and correct. The program-dependence is incidental.**

**And both of our own specs already say this representation is a placeholder:**

- `compiler/STAGE2-DESIGN.md:117` — *"Runtime dict representation (flat `VDict String` tag) …
  **LLVM wants a real dict struct / vtable pointer**. Routing reused, representation
  rewritten."* — **It was never rewritten.**
- `docs/spec/DICT-SEMANTICS.md:128` — *"A flat, impl-key representation is **unsound for the
  general case** and admissible only as a representation **optimization**."* And `:134` —
  *"Method values are **closed over their needed evidence** … so projecting `methods.m_i`
  yields a **directly-applicable**"* function.

**Therefore the prelude's *code*, not merely its numbering, is a function of the program's
impl set. One prelude object cannot serve all programs as things stand** — but see Option E.

## 6. The design — and the decision that must be made first

> ## ⭐ OPTION E (added 2026-07-14) — the spec already prescribes it, and it DOMINATES C and D
>
> §5 establishes the real root cause: **the dict carries no code pointer.** So fix *that*, and
> the whole problem evaporates.
>
> **Give the LLVM dict cell closure words per interface method** (code_ptr + captured
> `requires` dicts), and lower `RDict` to **load slot i; call** — i.e. exactly what
> `DICT-SEMANTICS.md:134` already specifies (*"method values closed over their needed
> evidence … projecting `methods.m_i` yields a directly-applicable"* function) and what
> `STAGE2-DESIGN.md:117` already promised (*"LLVM wants a real dict struct / vtable pointer …
> representation rewritten"*) **and never delivered.**
>
> | | |
> |---|---|
> | **Prelude bodies** | become **fully program-independent** ⇒ the **whole prelude** ships in `prelude.o`. #118 closes outright. |
> | **The O(#impls) linear `icmp` scan** | **dies** — replaced by an O(1) indirect call. On a self-compiled compiler full of `deriving (Eq)` types that chain is dozens of arms **and it runs once per element** in container equality. **This may be a perf WIN, not a cost — MEASURE IT.** |
> | **Blast radius** | **Backend-local.** Dicts are opaque and never observable, so `eval` / `core_ir_eval` / `wasm_emit` keep their `VDict`/i31 tags untouched under the single-evaluator law. |
> | **Allocation** | **None new.** Most dicts are already const-hoisted to `internal constant` globals (`emitConstDictCell`, `llvm_emit.mdk:4437`), so the closure words are static. |
>
> ⚠️ **Must preserve `soleImplDirect` / WS-1b** (`llvm_emit.mdk:4012-4035`): a single-impl method
> emits a **direct call and never loads the dict**, because an ambiguous return-position
> superclass constraint can pass a **NULL dict** — and a vtable would deref the same null. It is
> per-method, so it moves into the new representation cleanly.
>
> **Option C (trampoline) is DOMINATED**: it pays an extra call *and keeps the chain*.
>
> **Confidence:** high on the mechanism (every line grep-proved); **medium-low on the perf
> ordering — nothing here is measured.** That measurement is the next step.

> ### ⚠️ AND OPTION D (partition) IS WORTH LESS THAN §6 SAYS. "8 of 349" IS A FLOOR, NOT THE NUMBER.
>
> `prelude.o` is built **once for all programs**, so VOLATILE is not "the defines that moved in
> my one A/B" — it is the **conservative union of every define that contains a dispatch chain**:
> **all 37 `requires`-bearing impls in `stdlib/core.mdk`** (Eq×7, Ord×7, Debug×8, Display×8,
> Hashable×7) **plus ~26 `=>`-constrained standalone exports** (`neq`, `elem`, `maximum`, …).
>
> **≈60–90 of ~351, not 8.** The win survives (~75–80% still shared) but it is **not**
> "essentially preserved". **Measure the real VOLATILE set before committing to D.**

Two mechanical prerequisites, then the open choice.

### Prereq A — make prelude gensym ids program-independent

`mdk_program_main` must stop consuming counter values before core is emitted. Either
defer its body emission until after `emitFns`/`emitImpls` and splice its text back to
the top (the `Emit` record already has the buffer-swap machinery for this — it is how
lifted lambdas are redirected into `e.lams`), or give it a disjoint reserved id range.

⚠️ **Either way this renumbers the emitted IR for every program.** That makes it a
codegen change: load the `benchmark-emitter` skill, two rebuilds, `selfcompile_fixpoint`
(C3a/C3b), and a probable seed re-mint. This is the single largest cost item and the
main reason no code ships with this document.

### Prereq B — stop DCE'ing the prelude

Exempt `core`'s decls from `dceFilter` on the prelude-object path and let
`--gc-sections` do the work. Per Q1 this is a size *win*, and per the §4 side finding
the original reason for prelude DCE no longer applies.

### The open decision — what to do about (e)

- **Option D — partition (recommended, incremental).** Split prelude defines into
  **STABLE** (no program-dependent dispatch chain) and **VOLATILE** (contains one).
  STABLE → the shared `prelude.o`; VOLATILE → re-emitted per program into the program
  half. The emitter knows which is which at emit time. Measured cost for `impl Eq`:
  **8 of 349 defines** move to the program half — the win is essentially preserved.
  Needs **no change to dispatch semantics**, which is what makes it the safe first cut.
  Open: how large does VOLATILE get for a program impl'ing many prelude interfaces
  (Ord/Debug/Display/Hashable)? Must be measured before committing.

- **Option C — trampoline (cleaner, riskier).** Hoist each arg-tag dispatch chain out
  of the prelude into a per-program generated trampoline `@mdk_disp_<iface>_<method>`
  emitted in the program half. Prelude bodies then call a fixed symbol and become
  fully program-independent. Cost: one extra call per dispatch where an inlined icmp
  chain is used today — and `==` inside prelude generics is a hot path. **Must be
  benchmarked before it is chosen.**

- **Option B — restrict the fast path to impl-free programs.** Rejected: most fixtures
  define impls, so it buys nothing.

### Then, mirroring `MEDAKA_RT_OBJ` exactly

1. `medaka build --emit-prelude-obj <path>` — emit the prelude half (no DCE),
   `clang -O2 -ffunction-sections -fdata-sections -c` with the **same `clangOptFlag`**
   (`build_cmd.mdk:441`) and the same `detectGC` cflags the link uses, so the object's
   flags cannot drift from the link's. This is the whole point of having the
   *compiler* produce the object rather than a gate hand-rolling the clang call.
2. `MEDAKA_PRELUDE_OBJ=<path>` — when set and the file exists, the emitter emits only
   the program half (`declare`s for prelude symbols, `external` for prelude globals)
   and `clangLink` links the object with `-Wl,--gc-sections` / `-Wl,-dead_strip`.
   Unset or missing file → the exact current behavior, byte for byte.
3. **A soundness gate — to be added as `diff_compiler_prelude_obj.sh`** (does not exist yet;
   this is the proposal), modelled on `test/diff_compiler_rt_obj.sh`: for a fixture sample at
   both opt levels, build once inline and once with `MEDAKA_PRELUDE_OBJ` and assert
   **identical program OUTPUT**.
   (Note: unlike `rt_obj`, byte-identical *binaries* are **not** achievable — the two
   paths deliberately hand clang different IR — so the gate must compare behavior, and
   say so in its header.)
4. Wire into `test/diff_compiler_engines.sh` (alongside the `RTOBJ` block at line 326)
   and `test/build_oracles.sh:299`, best-effort: if the precompile fails, do not export
   the var and every build falls back to the unchanged inline path.

## 7. Open items

- **The `--release` cost of losing cross-module inlining is UNMEASURED** (§4/Q2). Until
  it is, `MEDAKA_PRELUDE_OBJ` must stay opt-in and off by default.
- **How big is VOLATILE** (Option D) for a program impl'ing many prelude interfaces?
- **Staleness.** `MEDAKA_RT_OBJ` has no staleness surface (`medaka_rt.c` cannot change
  mid-run). A prelude object depends on `stdlib/core.mdk` **and** the emitter. A gate
  that builds it at startup with the same binary inherits the same property; anything
  that caches it across runs does **not**, and needs a fingerprint.
- **Dict identity.** Prelude dict tables (`@mdk_dc_N`, `internal constant`) must live in
  exactly one object. If they were duplicated into both halves, two copies at different
  addresses would exist. The prototype kept them prelude-side only and was correct, but
  an implementation must not regress this.
- A duplicated-arm oddity was noticed while reading the dispatch chain in
  `mdk_impl_List_eq`: **three identical consecutive arms** all testing tag
  `7571402896630687` and all calling `mdk_impl_Ordering_eq`. **Root-caused 2026-07-14 and
  filed as #126:** `implsOf` (`llvm_emit.mdk:956`) is `filterTagged` with **no dedup**, while
  its sibling `ifaceTags` (`:4086`) *does* `dedupS`. **Not harmless** — a dict has no code
  pointer, so a dispatch *is* a linear scan of that list, and it runs **once per element** in
  container equality. (Not `detectDispatchGroups`, which is TRMC — see §5(e).)

## 8. Reproducing the measurements

```sh
# the IR
./medaka build --keep-ir test/wasm/fixtures/adt_enum_nullary.mdk -o /tmp/x   # writes /tmp/x.ll
grep -c '^define' /tmp/x.ll                       # 272
grep -c '^define.*@mdk_core__\|^define.*@mdk_impl_' /tmp/x.ll

# no TCO markers -> all TCO is clang's, which is why -O0 broke clos_reftco_indirect
grep -c 'musttail\|tail call' /tmp/x.ll           # 0

# the counter offset: mdk_program_main is emitted first and shifts every prelude id
grep -n '^define' /tmp/x.ll | head -3
```

The full split/renumber prototype scripts are not checked in (they are throwaway
`python3` line-mungers over the `.ll`); §5(c)/(d)/(e) are reproduced by emitting two
programs with the **same top-level shape**, stripping each one's own defines, and
diffing what remains.
