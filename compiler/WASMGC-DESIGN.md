# WASMGC-DESIGN.md — WasmGC backend implementation plan

**Status:** IMPLEMENTED — compute+print MVP MET (2026-06-19). Slices W1–W9b are done and
on `main`.

> **Status: IMPLEMENTED — compute+print MVP MET (2026-06-19).** Slices W1–W9b are
> done and on `main`; the per-slice §9 entries below were the original plan and are
> NOT all re-ticked — see the **Implementation status** banner at §9 for the real state.
> This is the
> plan for a *second* backend that consumes the same Core IR the LLVM backend
> consumes (`compiler/ir/core_ir.mdk`) and emits a runnable **WasmGC** module. It
> parallels the LLVM backend (`compiler/backend/llvm_emit.mdk`). It does **not**
> implement anything. §10 is the list of forks a human must rule on before any code.
>
> Cross-refs: `compiler/STAGE2-DESIGN.md` §2.4b/§2.4c (WasmGC ratified as the wedge
> backend), `compiler/RUNTIME-DESIGN.md` §6a/§7/§8.4/§8.5/**§8.6** (the binding
> abstract-value contract) and §5 (the 71-extern table), `CAPABILITY-EFFECTS.md` +
> `CAPABILITY-PLATFORM.md` (why this matters).

---

## 0. Web-research provenance + two corrections to the inherited docs

Researched June 2026. Two facts in the inherited docs / this task's framing need
correcting before they mislead an implementer:

- **Wasm 3.0 shipped 2025-09-17**, not Jan 2025. It is a *finalized W3C standard*
  (ed. Andreas Rossberg) — GC, typed references, tail calls, 64-bit memory,
  exception handling, relaxed SIMD all included.
  ([webassembly.org/news/2025-09-17-wasm-3.0](https://webassembly.org/news/2025-09-17-wasm-3.0/))
- **TCO is toolchain-emitted, not automatic.** `return_call` / `return_call_ref` /
  `return_call_indirect` are in 3.0 and the *engine* guarantees constant-stack
  frame replacement — but the **compiler decides where to emit them** (exactly like
  LLVM `musttail`). The inherited §8.5 phrasing "WasmGC `return_call` provides
  guaranteed TCO" is right *only* once our emitter places those opcodes at tail
  positions. One caveat the spec calls out: **tail calls into host imports are not
  guaranteed-tail** — relevant for IO externs (§6).
  ([tail-call Overview](https://github.com/WebAssembly/tail-call/blob/main/proposals/tail-call/Overview.md),
  [v8.dev/blog/wasm-tail-call](https://v8.dev/blog/wasm-tail-call))

Otherwise the inherited §8.6 contract is **confirmed sound and matches industry
prior art** (wasm_of_ocaml, Guile Hoot): i31ref immediates + typed struct/array
heap refs + host precise GC + `return_call` is precisely how the closest
comparable compilers lower an ML/Scheme value model. No contradiction with the
real Core IR was found (§2).

---

## 1. Goal + framing

WasmGC is Medaka's **wedge delivery vehicle**: the capability-safe-effects story
(`CAPABILITY-EFFECTS.md`) targets WebAssembly edge / plugin / sandboxed compute,
where a program's effect-row type *is* a compiler-verified capability manifest the
host reads to grant or deny capabilities. WasmGC is the runtime that makes that
demo real. The backend is a **direct emitter** — Core IR → WasmGC text (WAT),
exactly paralleling the existing Core IR → text-LLVM-IR emitter — assembled by a
shelled-out tool and run under a Wasm engine.

**What "done" means, scoped honestly:**
- **MVP (this plan's near horizon):** `medaka build --target wasm <prog.mdk>`
  compiles a **user program** to a runnable WasmGC module that produces
  byte-identical stdout to the interpreter/native oracle on a growing fixture
  corpus, staged slice-by-slice (§9).
- **Far horizon (NOT this plan — but MET, 2026-06-22):** the *compiler itself* self-hosting on WasmGC.
  That requires the full extern surface (subprocess, files, args) the wedge target
  deliberately does not grant. This was out of scope for the original MVP plan — but
  it was subsequently built (WASM-SELFHOST-ROADMAP.md layers 1–16): check_main runs
  byte-identical to native under Node, and the emitter itself compiles programs on WasmGC.
  The original framing "do not let it bound the MVP" was correct; the MVP shipped first,
  then the self-host was pursued separately.

The win is leverage: the IR, DCE, mangling, typecheck, and dict-passing dispatch
are all **already backend-neutral** (§2). A WasmGC backend is "a second
`emitProgram`," not a second compiler.

---

## 2. The contract you inherit (verified against the real Core IR)

### 2.1 The binding spec — RUNTIME-DESIGN.md §8.6 (restated, ratified 2026-06-07)

The **abstract value contract** is the single source of truth; the two backends
are two *physical encodings* of it, and neither encoding leaks above the Core IR.

- **Value kinds:** `Int` (**63-bit**, OCaml-int semantics), `Float` (64-bit IEEE),
  `Char`, `Bool`, `Unit`, `String`, `Tuple`, `List`, `Array`, ADT, `Record`,
  `Ref`, closure, thunk.
- **Semantics** (equality, ordering, pattern matching, arithmetic width) identical
  on every backend.
- **Type-directed behaviour** (`hash`/`Debug`/`Eq`/`Ord`) resolved at **compile
  time** — the runtime never reflects on layout.
- **Boxing is invisible** — unboxed vs heap is a per-backend optimization, never
  observable.

| | Native (LLVM + Boehm) §8.1 | WasmGC (this backend) |
|---|---|---|
| value slot | 64-bit tagged word | `(ref eq)` / `anyref` |
| immediates | low-bit-1: 63-bit Int / Char / Bool / Unit / nullary ctors | **`i31ref`** — only **≤31-bit** |
| heap aggregates | aligned ptr to `{header, fields…}` | typed `struct`/`array` refs |
| `Int` 32–63 bits | unboxed (63-bit immediate) | **boxed** `(struct (field i64))` |
| `Float` | boxed `{header, double}` | boxed `(struct (field f64))` |
| GC | Boehm conservative | host precise GC over declared structs |
| headers | one-word layout/tag id (§8.4) | the struct *type* carries layout; explicit tag field only where a sum needs it |

**The one honest asymmetry (accepted 2026-06-07):** WasmGC unboxes only ≤31-bit
ints; 32–63-bit ints box on WasmGC but not native. A *performance* asymmetry,
invisible to semantics.

### 2.2 Does the real Core IR feed a WasmGC emitter unchanged? — YES.

Verified by reading `compiler/ir/core_ir.mdk`. The IR is backend-agnostic and
**dict-passing dispatch is fully EXPLICIT as data** — the emitter consumes
pre-computed routing, it never computes routing. Confirmed nodes:

- `CMethod String Route (List Route) (List Route)` — return-position method
  dispatch; carries `Route` (the typechecker's `RKey`/`RDict` resolution) as
  immutable values.
- `CDict String (List Route)` — constrained-function dict params, routes explicit.
- `CDecision CExpr (List CArm) CTree` — match pre-compiled to a Maranget decision
  tree (`CTSwitch`/`CTLeaf`/`CTGuard`/`CTDrop`/`CTFail`) keyed on `CHead`
  (`HCon name arity` / `HTuple` / `HCons` / `HNil` / `HUnit` / `HLit`). The switch
  discriminant is exactly the **dense ctor ordinal** that drives `br_table` (§3.4).

Full node inventory the WasmGC `emitExpr` must handle (same set as LLVM):
`CLit, CVar, CApp, CLam, CLet, CLetGroup, CMatch, CDecision, CIf, CBinPrim, CUnOp,
CTuple, CList, CRecord, CFieldAccess, CRecordUpdate, CVariantUpdate, CArray,
CRangeList, CRangeArray, CIndex, CSlice, CBlock, CMethod, CDict`; block stmts
`CSExpr/CSLet/CSLetElse/CSAssign`; top-level `CBind/CClause`, impl entries
`CImplEntry/CImplTagged/CImplDefault`, program `CProgram` (groups + ctor arities +
ctor→type map + impl entries).

**Nothing in the IR is native-specific.** The only place the *native* encoding
leaks is the LLVM emitter's own helpers (`loadDiscriminant`'s low-bit test,
`@mdk_*` C calls) — those are private to `llvm_emit.mdk`, not in the IR. So the
inherited claim "Core IR is the shared seam" holds against the actual code. The
WasmGC backend reuses `core_ir_lower.mdk` (`lowerProgramEmit`), `dce.mdk`
(`dceFilter`), and `private_mangle.mdk` (`mangleUnits`) **unchanged**.

**One genuine seam mismatch to flag (not a contradiction, a porting cost):** the
LLVM emitter relies on a uniform `i64`-in/`i64`-out C-ABI and a C runtime
(`medaka_rt.c`) for ~53 leaf operations. WasmGC has *no C runtime* — those become
either WasmGC intrinsics, pure-Medaka code, or host imports (§6). The IR doesn't
change; the *extern realization* is wholly new.

---

## 3. WasmGC type-section design

All types live in one big `rec` group (iso-recursive, "nominal modulo
canonicalisation" — a single rec group gives nominal behaviour with constant-time
equivalence; [GC MVP](https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md)).

### 3.1 Universal value supertype

```wat
;; the unitype — every Medaka value is one of these at an abstract slot
(type $val (sub (struct)))         ;; or use the built-in `eq` / `any` directly
```
Recommendation (matching wasm_of_ocaml + Guile Hoot, the two closest value
models): use the **built-in `(ref eq)` as the universal slot type**, not a
user-declared root struct. Medaka is word-uniform (everything is one abstract
value), and `eq` already unifies `i31`, `struct`, and `array` with `ref.eq`
support for the few identity checks needed. Polymorphic positions (generics, dict
slots, `anyref` fields) are `(ref eq)`; WasmGC has no parametric polymorphism, so
generics erase to `eq` + downcast — the *same erasure* dict-passing already
assumes. ([Vouillon slides](https://cambium.inria.fr/seminaires/transparents/20231213.Jerome.Vouillon.pdf),
[wingolog: A world to win](https://wingolog.org/archives/2023/03/20/a-world-to-win-webassembly-for-the-rest-of-us))

### 3.2 Immediates

`Int` (≤31 bits), `Char`, `Bool`, `Unit`, nullary ctors → **`i31ref`** via
`ref.i31` / `i31.get_s`. This is the native low-bit-tagged immediate's peer.
`Int` outside ±2³⁰ → boxed `(type $boxint (sub $val (struct (field i64))))`.
Reading an `Int` from a polymorphic slot: `ref.test (ref i31)` → fast path
`i31.get_s`; else `ref.cast (ref $boxint)` + `struct.get`. (Scala.js MSB-check
recipe; [Scala.js wasmemitter README](https://github.com/scala-js/scala-js/blob/main/linker/shared/src/main/scala/org/scalajs/linker/backend/wasmemitter/README.md).)
For **monomorphic** `Int` arithmetic the emitter should keep values as raw `i32`
(MVP) / `i64` and only box at a polymorphic boundary — but the MVP can start
fully-boxed-via-i31 and optimize later.

### 3.3 Heap aggregates (per-kind struct/array types)

| Medaka kind | WasmGC type |
|---|---|
| `Float` | `(type $float (sub $val (struct (field f64))))` |
| `String` | `(type $str (sub $val (struct (field $cp_count i32) (field $bytes (ref $u8arr)))))`, `(type $u8arr (array (mut i8)))` — UTF-8 bytes + cached codepoint count (§5; mirrors RUNTIME-DESIGN §7 decision 2) |
| `Array` | `(type $arr (array (mut (ref eq))))` (`array.len` replaces the stored length word) |
| `Tuple n` | `(type $tupN (sub $val (struct (field (ref eq))ⁿ)))` — one struct type per arity present |
| `Record` | nominal `(struct (field …)ⁿ)` per record type; field index from the record-field-order table (peer to LLVM `emitFieldAccess`) |
| `Ref` | `(type $ref (sub $val (struct (mut (ref eq)))))` |
| `List` | `(type $cons (sub $val (struct (field $head (ref eq)) (field $tail (ref eq)))))`; `Nil` = an `i31` nullary ctor |

### 3.4 ADTs + match — dense ordinal drives `br_table`

Per **MoonBit's** model (the WasmGC-native sum-type template): one nominal struct
type per payload-bearing constructor under a per-datatype supertype, **with an
explicit `i32` discriminant field** as field 0 (the dense ctor ordinal from §8.4).
Field-less constructors → `i31` tags.

```wat
(type $Color    (sub $val (struct (field $tag i32))))           ;; datatype root
(type $Color_RGB (sub $Color (struct (field $tag i32)
                                       (field (ref eq))          ;; r
                                       (field (ref eq))          ;; g
                                       (field (ref eq)))))       ;; b
```

Match lowering (`CDecision`'s `CTSwitch`): read the discriminant — for an `i31`
nullary value `i31.get_u`; for a boxed variant `ref.cast (ref $Color)` +
`struct.get $Color $tag` — then `br_table` over the dense ordinal to the matching
arm block. Field extraction in an arm: `ref.cast` to the concrete variant struct +
`struct.get`. **Critical caution from Guile Hoot:** WasmGC subtyping is structural,
so two same-shape variants are *not* distinguishable by `ref.test` alone — this is
exactly why the explicit discriminant field is mandatory, not optional.

### 3.5 Where `ref.cast` is unavoidable

Anywhere a `(ref eq)`/`anyref` slot is consumed at a concrete type: match-arm field
extraction, reading a closure's captures, unboxing a non-i31 Int/Float, and dict
indirection. These are checked casts (trap on failure). They are the WasmGC tax in
place of the native low-bit tag test; prior art (all six surveyed compilers)
accepts them. `br_on_cast`/`br_on_cast_fail` fuse a cast with a branch and should
be used in the decision tree to avoid a separate test+cast.

---

## 4. Closures + guaranteed TCO

### 4.1 Closure ABI (peer to RUNTIME-DESIGN §8.5)

Closure = GC struct `{ funcref; captures… }`, dispatched by **`call_ref`** (not
`call_indirect` over a table). This is the unanimous prior-art choice
(wasm_of_ocaml, Kotlin, MoonBit, Hoot).

```wat
(type $clos (sub $val (struct (field $code (ref $codety)) (field (ref eq))*)))
```

Medaka already does **arity-aware indirect calls / PAP** in the LLVM backend
(`emitIndirect`, the `closureArityRef` table — see MEMORY "Nested closure
param-capture bug"). Port that to WasmGC using **Guile Hoot's uniform calling
convention**: a single code type `(func (param $self (ref eq)) (param $argc i32) …)`
with a small number of typed arg params plus a spill array for over-arity, so
over-application saturates + applies extra and under-application builds a PAP. This
is the cleanest mapping of the existing arity machinery and avoids one funcref type
per arity. ([wingolog: CPS in Hoot](https://wingolog.org/archives/2024/05/27/cps-in-hoot))

Capture-free top-level functions need no closure struct — a bare `ref.func` (Hoot
/ MoonBit optimization). Thunks (lazy top-level nullary, see MEMORY
"Lazy top-level nullary canonical") = a 0-capture closure forced on first
reference; represent identically to closures with a forced/value cache field.

### 4.2 TCO

Native `tailcc`/`musttail` (self-recursive tail call lowers to `musttail call;
ret`) maps directly to **`return_call`** (direct callee known) and
**`return_call_ref`** (closure / indirect). Emit these at every syntactic tail
position (Core IR tail position is already identifiable — same analysis the LLVM
emitter uses for `musttail`). Guaranteed constant-stack by the engine since Wasm
3.0 (Scala.js + Hoot precedent). **Exception:** a tail call to a *host import*
(an IO extern) cannot be guaranteed-tail — emit a normal `call` there (these are
leaf effect calls, never in a hot recursive loop, so it is harmless).

---

## 5. GC

WasmGC is a **precise, host-managed collector over typed references**. There is
**no `medaka_rt.c` Boehm path** — every `mdk_alloc`/`mdk_alloc_atomic` site becomes
a `struct.new` / `array.new` of the appropriate declared type; the host engine
owns marking and collection. Concretely:

- **Evaporates:** all of `medaka_rt.c`'s alloc layer (`mdk_alloc`,
  `mdk_alloc_atomic`, `mdk_alloc_bytes`), the conservative-GC tagging discipline
  (no low-bit tricks — i31 is a real reference), and the `MDK_*_TAG` header
  constants (the struct *type* carries layout; only the explicit discriminant
  survives, as a normal field).
- **Survives as logic, re-homed:** the *algorithms* in the LEAF/UNICODE/string
  functions (UTF-8 encode/decode, FNV-1a hash, SplitMix64 RNG, num dispatch,
  string compare/slice). These are pure and either (a) re-expressed as WasmGC
  intrinsics inline, (b) lifted into pure-Medaka stdlib, or (c) kept as host
  imports — see §6.
- **Becomes host imports:** the IO syscalls (`mdk_putstr`, files, args, etc.) — the
  host is the handler (§6, the capability seam).

No GC-control externs are needed (`mdk_set_seed` is RNG state, not GC). The native
`exit`/`panic` become a host import or `unreachable`/trap (§6).

---

## 6. Externs / IO / capabilities — the §5 analogue table

The native runtime is **~53 leaf functions** after INTRINSIC/→MEDAKA/→METHOD are
applied. WasmGC re-categorizes all 71 declared externs. Signatures are
**identical** to native (the abstract contract, §2.1); only the *binding* differs.

| §5 category | Native realization | **WasmGC realization** | Members |
|---|---|---|---|
| **INTRINSIC** (13) | CPU instr / constant / header read | **WasmGC intrinsic** — inline opcodes, no call. `arrayLength`→`array.len`; `arrayGet/SetUnsafe`→`array.get/set`; `stringLength`→`struct.get $str $cp_count`; `intToFloat`→`f64.convert_i32_s`; `floatToInt`→`i32.trunc_f64_s`; `charCode`/bounds/`pi`/`e`→constants | `pi e intMinBound intMaxBound charMinBound charMaxBound intToFloat floatToInt charCode arrayLength arrayGetUnsafe arraySetUnsafe stringLength` |
| **LEAF** (≈18–23) | C-ABI pure, GC-alloc | **Pure WasmGC** — emit as Medaka/WAT functions over our struct/array types (UTF-8 codec, FNV-1a, num dispatch, str compare/slice/concat, array make/copy/blit/fill, int/float→string). No host needed; all data-structure ops. Prefer pushing as many as possible into **pure-Medaka stdlib** to shrink the hand-written WAT preamble. | `charToStr intToString floatToString stringToFloat debugStringLit debugCharLit hashInt hashChar hashFloat hashBool hashString stringToChars stringFromChars charFromCode stringSlice stringConcat stringIndexOf stringCompare arrayMake arrayCopy arrayBlit arrayFill arrayFromList` |
| **UNICODE** (9) | best in Rust (codepoint tables) | **FORK (§10f).** Either (a) bundle a compact Unicode table as a WasmGC `(array i8)` data segment + pure lookup (host-independent, bloats module), or (b) **host import** (`env.mdk_char_is_alpha` etc.) on engines that have ICU/JS. MVP: host import; production-edge: bundled table. | `charIsAlpha charIsSpace charIsUpper charIsLower charIsPunct charToUpper charToLower stringToUpper stringToLower` |
| **IO** (16) | syscalls | **Host imports** — the capability seam. MVP: one custom import `env.mdk_write(ptr/arrayref,len)` for stdout (§8) + analogues for stderr/read. Production: WASI P1 `fd_write`/`fd_read`/`args_get` or P2 component-model. Files/`listDir`/`args`/`getEnv` are *granted capabilities* — absent on the wedge target unless the host provides them (a program using them won't link → honest static error, §2.1). `assert_snapshot`/`wallTimeSec` → host or test-harness import. | `putStr putStrLn ePutStr ePutStrLn readLine readLineOpt readAll readFile writeFile appendFile fileExists listDir args getEnv wallTimeSec assert_snapshot` |
| **RNG** (5) | SplitMix64 (shared algo) | **Pure WasmGC** — SplitMix64 is just i64 arithmetic; port the algorithm verbatim into a WasmGC function holding the seed in a mutable global. Deterministic, byte-gateable (matches the existing oracle). | `randomInt randomBool randomFloat randomChar setSeed` |
| **GC/CTRL** (5) | C primitives | `Ref`→`struct.new $ref`; `set_ref`→`struct.set`; `panic`/`exit`→host import `env.mdk_panic` then `unreachable` (no catchable panics — MEMORY decision); `__fallthrough__`→`unreachable` | `Ref set_ref panic exit __fallthrough__` |
| **→MEDAKA** (3) | already pure-Medaka stdlib | unchanged — stdlib code, backend-agnostic | `arraySortBy arraySortInPlaceBy arrayMakeWith` |
| **→METHOD** (2) | typeclass | unchanged — dict-passing | `hash inspect` |

**Capability-manifest / WIT seam (downstream — note, don't design fully).** The
effect-row on a function's type is the compiler-verified capability manifest
(`CAPABILITY-EFFECTS.md`); effects are **erased at codegen** (no runtime witness —
`core_ir_lower.mdk` drops `EAnnot`; `CExpr` carries no effect node). So the WasmGC
binary carries zero effect state — the manifest is *metadata* the platform reads
off the types at link time and maps to **WIT-described host imports** (grant `<File>`
→ bind `wasi:filesystem`; deny → the import is simply absent). Designing the
effect-label → WIT-world mapping is a separate downstream project; here we only
record that the IO-extern host-import boundary IS that seam.

---

## 7. Emitter seam — file plan

Parallel the LLVM backend's file structure exactly. **Reuse** everything above the
emitter; **new** files only for the WasmGC text production.

| Concern | LLVM file (reuse / parallel) | WasmGC file |
|---|---|---|
| Core IR (source of truth) | `compiler/ir/core_ir.mdk` | **reuse unchanged** |
| Lowering AST→Core IR | `compiler/ir/core_ir_lower.mdk` (`lowerProgramEmit`) | **reuse unchanged** |
| DCE | `compiler/ir/dce.mdk` (`dceFilter`) | **reuse unchanged** |
| Name mangling | `compiler/backend/private_mangle.mdk` (`mangleUnits`) | **reuse unchanged** |
| Emitter | `compiler/backend/llvm_emit.mdk` (`emitProgram : CProgram -> <Mut> String`) | **NEW** `compiler/backend/wasm_emit.mdk` (`emitWasmProgram : CProgram -> <Mut> String`) |
| Fixed preamble | `compiler/backend/llvm_preamble.mdk` | **NEW** `compiler/backend/wasm_preamble.mdk` (the fixed rec-group type section + host-import declarations + pure-WAT leaf/RNG functions) |
| Entry | `compiler/entries/llvm_emit_modules_main.mdk` | **NEW** `compiler/entries/wasm_emit_modules_main.mdk` (same `run` shape: read runtime/core/entry+roots → desugar → load → elaborate → mangle → DCE → lower → `emitWasmProgram` → stdout) |
| Build driver | `lib/build_cmd.ml` (G1 check → run emitter → trim → clang) | **extend**: add `--target wasm` flag → run the wasm entry → `wasm-tools parse`+`validate` (the clang analogue) → emit `.wasm` |

`wasm_emit.mdk` mirrors the LLVM emitter's per-concern function map:
`emitWasmExpr` (the big `CExpr` dispatcher), `emitWasmCtor`, `emitWasmDecision`
(→`br_table`), `emitWasmClosure`/`emitWasmIndirect` (→`call_ref`/`return_call_ref`),
`emitWasmMethod`/`emitWasmDictApp` (dict-passing — `RKey`→direct
`call`/`return_call`, `RDict`→cast+`call_ref` over the dict struct),
`emitWasmStringLit` (→ `(array i8)` data + `start`-initialized global),
`emitWasmArray`/`emitWasmList`/`emitWasmRecord`/`emitWasmFieldAccess`.

**Build driver shape** (extending `lib/build_cmd.ml` lines ~224–259):
```
medaka check <input>                                  # G1 gate, unchanged
medaka run compiler/entries/wasm_emit_modules_main.mdk <runtime> <core> <input> <roots…> > out.wat
wasm-tools parse out.wat -o out.wasm                  # the clang analogue (assemble)
wasm-tools validate out.wasm                          # GC validation on by default
# optional later: wasm-opt -O out.wasm -o out.opt.wasm
```
A `--target wasm` flag selects the entry + assembler; default stays LLVM/native.

---

## 8. Differential gate strategy

The existing oracle (`diff_compiler_build`: native vs interp **stdout byte-diff**)
is **mechanism-agnostic** — it compares program *output*, not IR. Exploit that:
add `diff_wasm_*` that compiles a fixture to WasmGC, runs it under the chosen
engine, and diffs stdout against the interpreter/native oracle.

- **Runner (MVP):** **Node ≥20.10** (V8 13.6, WasmGC + tail calls unflagged, no
  flags needed). `WebAssembly.instantiate(wasm, { env: { mdk_write } })`, capture
  the bytes the module writes via the custom `env.mdk_write` host import into an
  in-process buffer, print, diff. No WASI adapter matrix, no `_start` ceremony —
  matches the existing host-shim model and is the simplest stdout capture.
  ([developer.chrome.com/blog/wasmgc](https://developer.chrome.com/blog/wasmgc),
  [web.dev baseline](https://web.dev/blog/wasmgc-wasm-tail-call-optimizations-baseline))
- **Pure-CLI alternative:** `wasmtime run -W gc -W tail-call out.wasm` with WASI
  `fd_write` (Wasmtime GC is off-by-default — the `-W gc` flag is mandatory;
  Wasmtime ≥27 for GC, ≥22 for tail calls).
  ([Wasmtime 27.0](https://bytecodealliance.org/articles/wasmtime-27.0))
- A new `test/diff_wasm.sh` peer to the existing diff scripts; same golden corpus,
  same path-stripping discipline (MEMORY "Golden path-stability"). Stage the
  corpus to grow with §9's slices.

---

## 9. MVP-first staging (ascending-risk slices, each independently gated)

> **IMPLEMENTATION STATUS (2026-06-22) — compute+print MVP MET (W1–W9b); SELF-HOST + IN-BROWSER EMITTER COMPLETE.** The per-binding emitter-gap census is 0 (1428→0, 9 categories closed — W10–W12 + self-host layers 1–16). `check_main` (lex→parse→resolve→exhaust→typecheck) compiled to WasmGC runs to completion under Node byte-identical to native. The WasmGC-compiled emitter (`wasm_emit_modules_main`) runs end-to-end and compiles Medaka programs to working WasmGC modules. The in-browser playground is live (`playground/dist/playground.wasm`). Gates (all green): `test/wasm/diff_wasm.sh` **138** · `diff_wasm_typed.sh` **6** · `diff_wasm_modules.sh` **17**. Authoritative detail: `WASM-SELFHOST-ROADMAP.md` (layer log). **Previously REMAINING items now CLOSED:** `stringToFloat` (layer-6), IO/WASI host surface (step 10/W12), self-host-on-WasmGC (layer-12 front-end + layer-16 emitter). **Residual (layer-17, deferred):** `hashName`/`dictTag` i32-vs-i64 width — dispatch-hash `i32.const`s differ from native (deltas 2^30; self-consistent, true byte-identity needs hash-width fix).

Mirrors how the LLVM backend was staged (slices 1–14). Each slice is gated by
`diff_wasm.sh` on its fixture before the next starts.

1. **Slice W1 — toolchain proof.** `main = println (1 + 2)` → hand-shaped WAT
   (i31 arith + one `env.mdk_write` host import) → `wasm-tools parse`+`validate` →
   Node prints `3`. Proves the *whole pipeline* end to end. **Highest-value,
   lowest-code — do this first, before any emitter generality.**
2. **Slice W2 — immediates + arithmetic.** `CLit`/`CVar`/`CBinPrim`/`CUnOp`/`CIf`
   over `i31` Ints + Bools; `Float` boxing `(struct f64)`; the i31/box overflow
   path. Gate: arithmetic fixtures.
3. **Slice W3 — ADTs + match (`br_table`).** The rec-group type section per
   datatype, dense-ordinal discriminant, `CDecision`→`br_table`,
   `br_on_cast`/field extraction. Gate: ADT/match fixtures (incl. nullary-vs-payload
   mix — the cross-module ctor-collision class from MEMORY).
4. **Slice W4 — closures + `call_ref` + TCO. DONE (2026-06-19).** Closure struct
   with **arity-in-struct** (§11 — kills the native table-miss class by construction),
   a single uniform `$codety` `(func (param $self (ref eq)) (param $args (ref $argarr))
   (result (ref eq)))`, a universal `$mdk_apply` doing exact/under-PAP/over-saturate
   dispatch (`$mdk_pap` for partials), lambda-lift of `CLam`, closure wrappers for
   top-level fns used as values, multi-clause/pattern-param coalescing (fallthrough
   clause chain), and `return_call`/`return_call_ref` at tail positions in BOTH the
   scalar-i32 and ref paths. Gate: `diff_wasm.sh` 32/32 + a TCO IR-shape assertion
   (the 5M-deep `clos_deep_tco`/`fn_tailsum`/`clos_reftco_indirect` tails emit
   `return_call`, no plain `call` survives). Value rep: closures force the uniform
   `(ref eq)` rep (`useClos`).
5. **Slice W5 — dispatch (dict-passing).** `CMethod` (`RKey`→`return_call`,
   `RDict`→cast+`call_ref`) and `CDict` threading. Gate: typeclass/Eq/Ord/Num
   dispatch fixtures.
6. **Slice W6 — strings.** `(array i8)` UTF-8 + `cp_count`; string literals as data
   + `start`-init globals (the Hoot non-const-array gotcha); port the LEAF string
   functions (compare/slice/concat/UTF-8 codec). Gate: string fixtures.
7. **Slice W7 — collections.** `List` (cons struct + i31 Nil), `Array`
   (`(array (mut (ref eq)))` + `array.len`), `Tuple`, `Record`, `Ref`, ranges,
   index/slice. Gate: list/array/record fixtures.
8. **Slice W8 — RNG + remaining leaf/intrinsic externs.** SplitMix64 in WAT,
   INTRINSIC inlining, the §6 table's pure-WasmGC members. Gate: RNG determinism +
   stdlib coverage fixtures (json/list/set, as the native suite does).
9. **Slice W9 — multi-module + real programs.** End-to-end on multi-file user
   programs; compile a non-trivial stdlib-using program. Gate: the multi-module
   diff corpus.

**Far horizon (explicitly NOT an MVP slice — but MET 2026-06-22, see §9 status):** compiler self-host on WasmGC. Needs
the full IO/subprocess/file extern surface the wedge target withholds. Out of
scope; track separately.

---

## 10. Design forks — need a human decision

Each is an open choice with a recommendation; rule on these before any code.

| # | Fork | Recommendation | Tradeoff |
|---|---|---|---|
| **a** | **WAT text vs binary emission** | **Emit WAT text.** | Exactly parallels the current text-LLVM-IR approach (debuggable, diffable, no binary encoder to write); costs one assembler shell-out. Binary would skip the assembler but means writing a LEB128/section encoder — strictly more work for the MVP. |
| **b** | **Assembler (clang analogue)** | **`wasm-tools parse` + `validate`** (bytecodealliance). | GC validation on by default; text parser supports all proposals always; faithful text→binary (no rewrite). WABT `wat2wasm` **ruled out — no GC** ([#2530](https://github.com/WebAssembly/wabt/issues/2530)). Binaryen `wasm-as` rewrites instructions (lossy as a pure assembler) — keep `wasm-opt -O` as an *optional later* optimization pass only. **Installed: `wasm-tools 1.252.0` (verified 2026-06-22).** |
| **c** | **Test/run engine** | **Node ≥20.10 for the CI diff gate** (no flags, in-process stdout capture); Wasmtime ≥27 (`-W gc -W tail-call`) as the CLI/non-JS cross-check. | Node = zero-flag, simplest capture, already installed (v20.11.1). Wasmtime needs explicit `-W gc` (off by default) but is the engine an edge deployment actually uses. Support both behind the diff script. |
| **d** | **String representation** | **`(array i8)` UTF-8 + cached `cp_count`.** | Host-independent (identical Wasmtime + browser), pure WasmGC core, matches Medaka's locked native string rep (RUNTIME-DESIGN §7 decision 2) and codepoint-awareness. **stringref is dead** (Phase 1, not in 3.0). JS String Builtins (shipped, `externref`) are zero-copy on browsers but **useless under Wasmtime** — adopt only at a later browser-interop seam, never as the core rep. ([stringref#54](https://github.com/WebAssembly/stringref/issues/54), [js-string-builtins](https://github.com/WebAssembly/js-string-builtins/blob/main/proposals/js-string-builtins/Overview.md)) |
| **e** | **IO host interface (WASI P1 vs P2 vs custom)** | **Custom host import for the MVP** (`env.mdk_write` etc.); migrate IO/files/args to **WASI P1** for production CLI; P2/component-model + WIT later as the capability-manifest seam. | Custom shim avoids the P1/P2 adapter matrix and `_start`/memory-export ceremony, works identically across engines, matches the `medaka_rt.c` host-shim model, and is the simplest stdout capture. P2/WIT is where the capability-grant story ultimately lands but is over-scoped for an MVP. Node = P1-only anyway. |
| **f** | **Unicode externs (9)** | **Host import for MVP; bundled `(array i8)` table for production edge.** | Host import is trivial and correct where the host has ICU/JS, but the wedge target may have *no* such host → bundle a compact Unicode-property table as a data segment + pure lookup for self-containment. Defer the table to a post-MVP slice. |
| **g** | **MVP scope boundary** | **Done = user programs compile + pass the diff corpus through Slice W9.** Compiler self-host on WasmGC was explicitly **out of MVP scope** — and subsequently MET (layers 1–16, 2026-06-22). | Self-host needs the withheld IO/subprocess surface; chasing it would have ballooned the MVP; the MVP shipped first, then self-host was pursued separately — validating this sequencing decision. |

---

## 11. Open risks / unknowns

- **Engine version drift.** Wasmtime GC is *off by default* (`-W gc` mandatory,
  ≥27); a stale wasmtime silently rejects the module. Node ≥20.10 is fine
  unflagged but Deno's exact unflag version is unconfirmed ([deno #22861](https://github.com/denoland/deno/issues/22861)) —
  pin engines in the diff gate and assert versions, mirroring the
  "diff_native_cli stale-binary footgun" lesson (MEMORY).
- **`wasm-tools` installed** (`wasm-tools 1.252.0` at `/opt/homebrew/bin/wasm-tools`, verified 2026-06-22) — this was a pre-MVP risk; it is resolved. ~~Slice W1 is blocked on this.~~
- **Closure calling convention.** Hoot's uniform `(param argc …)` + spill-array
  scheme is the recommended port of Medaka's arity/PAP machinery, but Hoot's exact
  closure field layout is *not* in public sources — the spill/arg-global details
  must be re-derived against Medaka's `emitIndirect`/`closureArityRef` during
  Slice W4 (the residual "table-miss closure" arity-in-cell issue from MEMORY's
  nested-closure bug likely needs the same arity-in-struct fix here).
- **Float boxing perf.** Medaka's native backend has a large float-unboxing
  optimization arc (MEMORY "Float runtime perf"). WasmGC starts with *all* floats
  boxed `(struct f64)`; the analogous unboxing optimizations are a whole post-MVP
  perf project, not in scope. Expect WasmGC float-heavy code to be slower than
  native until then.
- **`i31` 31-bit ceiling.** The accepted 32–63-bit-int boxing asymmetry (§2.1) is
  semantics-invisible but must be *tested* — a fixture exercising ints across the
  ±2³⁰ boundary belongs in Slice W2's gate to prove the overflow→box path.
- **Match on structurally-identical variants.** The mandatory explicit-discriminant
  field (§3.4) defends against WasmGC's structural subtyping collapsing distinct
  same-shape variants; verify with a fixture (two single-field variants of one
  datatype) in Slice W3 — this is the WasmGC peer of the native cross-module
  ctor-collision class.
- **`wasm-opt` and the fixpoint discipline.** If `wasm-opt -O` is later added, it
  rewrites instructions — confirm it stays output-equivalent under the diff gate
  before trusting it (peer to the LLVM `-O2`-is-fixpoint-safe reasoning).

---

## Sources

- [Wasm 3.0 release (2025-09-17)](https://webassembly.org/news/2025-09-17-wasm-3.0/) ·
  [GC MVP spec](https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md) ·
  [GC Post-MVP](https://github.com/WebAssembly/gc/blob/main/proposals/gc/Post-MVP.md) ·
  [tail-call Overview](https://github.com/WebAssembly/tail-call/blob/main/proposals/tail-call/Overview.md) ·
  [V8 tail calls](https://v8.dev/blog/wasm-tail-call)
- [wasm-tools README](https://raw.githubusercontent.com/bytecodealliance/wasm-tools/main/README.md) ·
  [Binaryen GC discussion #5435](https://github.com/WebAssembly/binaryen/discussions/5435) ·
  [WABT GC issue #2530](https://github.com/WebAssembly/wabt/issues/2530)
- [Wasmtime 27.0 (GC)](https://bytecodealliance.org/articles/wasmtime-27.0) ·
  [Wasmtime Config](https://docs.rs/wasmtime/latest/wasmtime/struct.Config.html) ·
  [Chrome WasmGC](https://developer.chrome.com/blog/wasmgc) ·
  [web.dev WasmGC+tail-call Baseline](https://web.dev/blog/wasmgc-wasm-tail-call-optimizations-baseline) ·
  [Node WASI](https://nodejs.org/api/wasi.html)
- [stringref #54 (demoted)](https://github.com/WebAssembly/stringref/issues/54) ·
  [JS String Builtins](https://github.com/WebAssembly/js-string-builtins/blob/main/proposals/js-string-builtins/Overview.md)
- Prior art — wasm_of_ocaml/Wasocaml:
  [Vouillon slides](https://cambium.inria.fr/seminaires/transparents/20231213.Jerome.Vouillon.pdf),
  [Wasocaml paper](https://inria.hal.science/hal-04311345/file/main.pdf);
  dart2wasm [sdk#51619](https://github.com/dart-lang/sdk/issues/51619);
  Kotlin/Wasm [deep-dive](https://tanishiking.github.io/posts/kotlin-wasm-deep-dive/);
  Scala.js [wasmemitter README](https://github.com/scala-js/scala-js/blob/main/linker/shared/src/main/scala/org/scalajs/linker/backend/wasmemitter/README.md);
  MoonBit [docs](https://docs.moonbitlang.com/en/stable/language/fundamentals.html);
  Guile Hoot [A world to win](https://wingolog.org/archives/2023/03/20/a-world-to-win-webassembly-for-the-rest-of-us),
  [CPS in Hoot](https://wingolog.org/archives/2024/05/27/cps-in-hoot)
