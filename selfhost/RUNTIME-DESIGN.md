# Runtime & extern strategy for the native (Stage 2.4) backend

How Medaka's 71 `extern` primitives (declared in [`../stdlib/runtime.mdk`](../stdlib/runtime.mdk),
implemented natively in [`../lib/eval.ml`](../lib/eval.ml)'s `primitives` table)
get realized once the tree-walking interpreter is replaced by a bytecode VM
(Stage 2.2) and then LLVM (Stage 2.4). This is the contract the native runtime
must satisfy and the per-extern disposition for building it.

See [`STAGE2-DESIGN.md`](./STAGE2-DESIGN.md) for the backend-architecture decision
(bytecode-VM-first) and [`../PLAN.md`](../PLAN.md) "North star → Stage 2".

> **Status (2026-06-05):** design only — no native runtime exists yet. The current
> backend is the tree-walker; the bytecode VM (§2.2) is the next consumer that will
> first exercise this contract. **Decide nothing here as final until the value
> representation is fixed (see §2 and §8).** A Stage-2.4 *de-risking spike* (see
> [`STAGE2-DESIGN.md`](./STAGE2-DESIGN.md) §2.4 and `selfhost/llvm_emit.mdk`) has now
> exercised the emit→clang→link→run→diff toolchain end-to-end against the
> tree-walker oracle for the scalar slice, using a **provisional** uniform tagged
> word. §8 (new) turns what it surfaced into a value-representation +
> calling-convention proposal **for human ratification** — it is not yet locked.

---

## 1. The thesis: "what language" is the *secondary* axis

The natural first question is "C or Rust for the runtime helpers?" — but that
choice is downstream of, and largely reversible relative to, three things that
actually constrain the design. The 71 externs are not one kind of thing; sorting
them by *coupling to the runtime* (not by implementation convenience) collapses
most of the apparent difficulty:

- **~15 are single LLVM instructions** and should never be a runtime call at all.
- **~3 take Medaka closures** (sorts, array builder) — the only ones where an
  FFI callback boundary appears, and the reason to *avoid* native helpers for them.
- **~2 are structural over any value** (`hash`, `inspect`) — the only ones that
  would force runtime value-layout reflection, and the reason to push them into
  the typeclass system instead.
- **The rest (~50)** are leaf operations — scalar/string formatting, unicode,
  syscalls, RNG — pure or effectful but with no callback and no value reflection.
  These are easy in *any* native language.

So the language decision only meaningfully applies to that last bucket, and there
it is **per-helper and reversible**. The architecture is decided by §2.

## 2. The three real constraints — decide these first

These are expensive to retrofit; everything else follows from them.

### 2a. Value representation + GC allocation entry point
`PLAN.md` commits to **Boehm (conservative) GC first**. Boehm is a C library and
scans the C stack conservatively. The consequence that dominates the extern design:

> **Any extern that *returns* a Medaka value must allocate it in the GC heap with
> the correct object header — it cannot hand back a native-allocated buffer.**

`stringConcat` can't return a Rust `String`; `arrayCopy` can't return a Rust
`Vec`; `Ref` can't return a `Box`. They must call *your* `gc_alloc` and write
*your* object layout. So the runtime boundary is **C-ABI over raw pointers** no
matter what language implements the body — the ergonomic native types live
*inside* a helper, never *across* its interface. Pick the uniform value
representation (tagged word? NaN-boxing? boxed-everything?) **before** writing any
helper, because every entry in the LEAF/GC buckets below is a function of it.
**The proposal — with a recommendation — is now §8;** the spike has data.

### 2b. Closure ABI
Three externs invoke a Medaka function (`arraySortBy`/`arraySortInPlaceBy` take a
comparator, `arrayMakeWith` takes a builder). A native helper for these must call
back into compiled Medaka through the C ABI, which couples the runtime to the
**closure representation** (env pointer + code pointer) and the calling
convention. This coupling is avoidable (see §4, `→MEDAKA`) and should be avoided.

### 2c. Structural reflection
`hash : a -> Int` and `inspect : a -> <IO> Unit` traverse arbitrary values. The
*only* way to keep the native runtime free of value-layout reflection (RTTI, tag
dispatch on every field) is to not have these as reflective externs at all — route
them through the typeclass machinery you already have (see §4, `→METHOD`).

### Sequencing note
**Prototype this entire extern ABI at the bytecode-VM stage (§2.2), not at LLVM.**
The VM already forces a commitment to value representation, a C-ABI extern
boundary, and a closure layout — and it is gated **byte-for-byte against the
tree-walker oracle** per slice (`diff_selfhost_eval*.sh`). So the whole runtime
strategy gets validated in the cheap setting, with a trusted reference, before any
native code generation exists. By 2.4 the ABI is already proven and the VM becomes
a *second* oracle for the native backend.

## 3. The disposition taxonomy

| Tag | Meaning |
|-----|---------|
| `INTRINSIC` | Emitted inline by codegen (one or few LLVM instructions); **no runtime call**. |
| `LEAF` | Small pure native helper, C-ABI; allocates any output via `gc_alloc`. Language is free choice (C default). |
| `UNICODE` | A `LEAF` whose logic is unicode classification/case-mapping — the one place **Rust earns its keep** (a `unicode-*` crate beats hand-rolled tables). Still C-ABI, output copied into the GC heap. |
| `IO` | Native syscall wrapper (effectful). Any language; Rust pleasant. |
| `RNG` | Native, holds RNG state across calls. |
| `GC/CTRL` | Native, intimate with the allocator / unwinder / trap path. **Must** be hand-written against the runtime internals. |
| `→MEDAKA` | **Not a native helper.** Rewrite in Medaka, compiled by our own backend — so the Medaka callback never crosses an FFI boundary. |
| `→METHOD` | **Not an extern.** Convert to a derived/dispatched typeclass method, eliminating runtime value reflection. |

## 4. The hard cases, in detail

**Sorts & array builder (`arraySortBy`, `arraySortInPlaceBy`, `arrayMakeWith`) →
`→MEDAKA`.** A native `sort_by` wants a native comparator; ours is a Medaka
closure. A native helper would have to marshal the array to a raw `*mut Value`,
wrap a trampoline that re-enters compiled Medaka per comparison through the C ABI,
and allocate the result through the GC — i.e. `unsafe` raw-pointer code in which
Rust's `Vec`/`sort_by`/safety all evaporate at the boundary. Writing the sort *in
Medaka* (a standard mergesort/introsort over `Array`, compiled by our backend)
keeps it one calling convention end-to-end, allocates through the normal path, and
is validated by the existing differential harness for free. Same argument for
`arrayMakeWith` (the `Int -> a` builder is a Medaka closure). **This is the lever
that removes the FFI-callback problem entirely.** (They are native in the
tree-walker only because OCaml's `Array.sort` was conveniently at hand.)

**`hash : a -> Int` → `→METHOD`.** Note `==`/`compare`/`debug` are already
typeclass methods (`Eq`/`Ord`/`Debug`), not externs — they monomorphize /
dictionary-pass at compile time. `hash` is the lone structural straggler. Make it
a derived **`Hashable`** method (same `deriving` machinery as `Eq`), so per-type
hash code is *generated*, not computed by a runtime that walks an unknown layout.
Net effect: **the native runtime needs zero knowledge of value layout** — it only
ever sees opaque pointers and scalars.

**`inspect : a -> <IO> Unit` → `→METHOD` + `IO`.** It's both reflective *and*
effectful. Decompose: render via the `Debug` method (compile-time dispatched) to a
`String`, then `putStr` it. No reflective extern remains.

**`Ref` / `set_ref` → `GC/CTRL`.** `Ref` allocates a one-slot mutable cell in the
GC heap; `set_ref` is a store. Under Boehm both are trivial (plain store, no
barrier). If a later precise/generational GC replaces Boehm, `set_ref` grows a
**write barrier** — isolate it now so that change is one function.

**`panic` / `exit` / `__fallthrough__` → `GC/CTRL`.** `panic` prints to stderr and
aborts (or unwinds, if you ever want catchable panics — decide the unwind model
when you pick the calling convention). `exit` is `IO`-tagged but is really a
process-control primitive. `__fallthrough__` is compiler-internal (raised on a
non-exhaustive match the checker couldn't rule out) — lower it to the same trap as
`panic` with the standard "non-exhaustive match" message.

**Strings & `stringLength` — representation-dependent.** If Medaka strings are
stored UTF-8 with a cached codepoint count, `stringLength` is `INTRINSIC` (header
read); if codepoint count is computed on demand it is `LEAF` (O(n) scan). Likewise
`charCode` is `INTRINSIC` only if `Char` is a 32-bit codepoint. **Lock the string
representation in §2a and revisit the two rows tagged `(rep)` below.** Medaka is
codepoint-aware (per `runtime.mdk`), so favor a representation that keeps codepoint
length and indexing cheap.

## 5. Per-extern disposition (all 71)

### Constants & scalar conversions — `INTRINSIC`
| Extern | Signature | Disposition | Note |
|--------|-----------|-------------|------|
| `pi` | `Float` | INTRINSIC | float constant |
| `e` | `Float` | INTRINSIC | float constant |
| `intMinBound` | `Int` | INTRINSIC | constant |
| `intMaxBound` | `Int` | INTRINSIC | constant |
| `charMinBound` | `Char` | INTRINSIC | constant |
| `charMaxBound` | `Char` | INTRINSIC | constant |
| `intToFloat` | `Int -> Float` | INTRINSIC | `sitofp` |
| `floatToInt` | `Float -> Int` | INTRINSIC | `fptosi` (truncates toward zero, matches OCaml `int_of_float`) |
| `charCode` | `Char -> Int` | INTRINSIC `(rep)` | `zext`/identity iff `Char` is a 32-bit codepoint |

### Array slots — `INTRINSIC`
| `arrayLength` | `Array a -> Int` | INTRINSIC | header load |
| `arrayGetUnsafe` | `Int -> Array a -> a` | INTRINSIC | GEP + load |
| `arraySetUnsafe` | `Int -> a -> Array a -> <Mut> Unit` | INTRINSIC | GEP + store |

### Pure leaf helpers (allocate output via GC; C-ABI) — `LEAF`
| Extern | Signature | Disposition | Note |
|--------|-----------|-------------|------|
| `charToStr` | `Char -> String` | LEAF | encode codepoint → UTF-8, alloc |
| `intToString` | `Int -> String` | LEAF | |
| `floatToString` | `Float -> String` | LEAF | match `%g` rendering (see lexer float-text normalization note) |
| `stringToFloat` | `String -> Option Float` | LEAF | alloc `Some`/`None` |
| `debugStringLit` | `String -> String` | LEAF | escape rendering |
| `debugCharLit` | `Char -> String` | LEAF | escape rendering |
| `stringToChars` | `String -> Array Char` | LEAF | alloc array |
| `stringFromChars` | `Array Char -> String` | LEAF | |
| `charFromCode` | `Int -> Option Char` | LEAF | validate codepoint range |
| `stringSlice` | `Int -> Int -> String -> String` | LEAF | codepoint-indexed |
| `stringConcat` | `List String -> String` | LEAF | single `gc_alloc` + blit; keep the amortized-O(1) behavior `PERF-NOTES.md` relies on |
| `stringIndexOf` | `String -> String -> Option Int` | LEAF | |
| `stringCompare` | `String -> String -> Ordering` | LEAF | returns `Lt`/`Eq`/`Gt` ctor |
| `stringLength` | `String -> Int` | LEAF `(rep)` | INTRINSIC iff codepoint count is cached in the header |
| `arrayMake` | `Int -> a -> Array a` | LEAF | alloc + fill (opaque slots; no reflection) |
| `arrayCopy` | `Array a -> Array a` | LEAF | |
| `arrayBlit` | `Array a -> Int -> Array a -> Int -> Int -> <Mut> Unit` | LEAF | memmove of slots |
| `arrayFill` | `a -> Array a -> <Mut> Unit` | LEAF | |
| `arrayFromList` | `List a -> Array a` | LEAF | walk list, alloc array |

### Unicode (best in Rust) — `UNICODE`
| `charIsAlpha` | `Char -> Bool` | UNICODE | |
| `charIsSpace` | `Char -> Bool` | UNICODE | |
| `charIsUpper` | `Char -> Bool` | UNICODE | |
| `charIsLower` | `Char -> Bool` | UNICODE | |
| `charIsPunct` | `Char -> Bool` | UNICODE | |
| `charToUpper` | `Char -> Char` | UNICODE | case mapping |
| `charToLower` | `Char -> Char` | UNICODE | case mapping |
| `stringToUpper` | `String -> String` | UNICODE | full-string case mapping, alloc |
| `stringToLower` | `String -> String` | UNICODE | |

### IO / syscalls — `IO`
| `putStr` | `String -> <IO> Unit` | IO | |
| `putStrLn` | `String -> <IO> Unit` | IO | |
| `ePutStr` | `String -> <IO> Unit` | IO | stderr |
| `ePutStrLn` | `String -> <IO> Unit` | IO | stderr |
| `readLine` | `Unit -> <IO> String` | IO | |
| `readLineOpt` | `Unit -> <IO> Option String` | IO | `None` at EOF |
| `readAll` | `Unit -> <IO> String` | IO | all of stdin |
| `readFile` | `String -> <IO> Result String String` | IO | |
| `writeFile` | `String -> String -> <IO> Result String Unit` | IO | |
| `appendFile` | `String -> String -> <IO> Result String Unit` | IO | |
| `fileExists` | `String -> <IO> Bool` | IO | |
| `listDir` | `String -> <IO> Result String (List String)` | IO | |
| `args` | `Unit -> <IO> List String` | IO | program args |
| `getEnv` | `String -> <IO> Option String` | IO | |
| `wallTimeSec` | `Unit -> <IO> Float` | IO | `gettimeofday` |
| `assert_snapshot` | `String -> String -> <IO> Unit` | IO | test-harness only; may stay tree-walker-only and not ship in the native runtime |

### RNG — `RNG`
| `randomInt` | `Int -> Int -> <Rand> Int` | RNG | holds state |
| `randomBool` | `Unit -> <Rand> Bool` | RNG | |
| `randomFloat` | `Unit -> <Rand> Float` | RNG | |
| `randomChar` | `Unit -> <Rand> Char` | RNG | |
| `setSeed` | `Int -> <Rand> Unit` | RNG | seeds the state |

### GC / control — `GC/CTRL`
| `Ref` | `a -> Ref a` | GC/CTRL | alloc one-slot cell |
| `set_ref` | `Ref a -> a -> <Mut> Unit` | GC/CTRL | store; **add write barrier if GC changes** |
| `panic` | `String -> a` | GC/CTRL | stderr + abort/unwind |
| `exit` | `Int -> <Panic> Unit` | GC/CTRL | process exit |
| `__fallthrough__` | `Unit -> a` | GC/CTRL | non-exhaustive-match trap (compiler-internal) |

### Rewrite in Medaka (no native helper) — `→MEDAKA`
| `arraySortBy` | `(a -> a -> Ordering) -> Array a -> Array a` | →MEDAKA | comparator is a Medaka closure |
| `arraySortInPlaceBy` | `(a -> a -> Ordering) -> Array a -> <Mut> Unit` | →MEDAKA | |
| `arrayMakeWith` | `Int -> (Int -> a) -> Array a` | →MEDAKA | builder is a Medaka closure |

### Convert to typeclass (no extern) — `→METHOD`
| `hash` | `a -> Int` | →METHOD | derive `Hashable` |
| `inspect` | `a -> <IO> Unit` | →METHOD + IO | `Debug` render → `putStr` |

### Disposition totals
`INTRINSIC` 12 · `LEAF` 19 · `UNICODE` 9 · `IO` 16 · `RNG` 5 · `GC/CTRL` 5 ·
`→MEDAKA` 3 · `→METHOD` 2  = **71**.

After applying `INTRINSIC` (no call), `→MEDAKA` (compiled Medaka), and `→METHOD`
(typeclass), the **actual native runtime is ~54 leaf functions** — and every one
is C-ABI over opaque pointers/scalars with **no callbacks and no value-layout
reflection**.

## 6. Language recommendation for the native surface

- **`LEAF` / `IO` / `RNG` / `GC/CTRL`:** **C is the frictionless default** — Boehm
  is C, the boundary is C-ABI, the GC/`gc_alloc`/header code is C-shaped. Choose
  Rust per-helper where its internal logic is non-trivial and self-contained
  (parsing, `listDir`, RNG), but expose `#[no_mangle] extern "C"` over raw
  pointers and copy any output into the GC heap. The choice is **reversible
  per-function**, so don't over-invest in it up front.
- **`UNICODE`:** prefer **Rust** (`unicode-*` crates) — materially better than
  hand-rolled C tables, and the inputs/outputs are scalars/owned strings that copy
  cleanly into the GC heap.
- **Do not** reach for Rust expecting `Vec`/`HashMap`/`sort_by` "for free" — they
  cannot cross the C-ABI/GC boundary; that intuition does not transfer (this is
  exactly why the sorts are `→MEDAKA`).

## 6a. Targets, capability interfaces & stdlib stratification (decided 2026-06-06)

Medaka ships as **one language, one core, identical semantics**, parameterized by a
**target = (available capability set) × (backend)**. NOT full Roc-style platforms;
NOT separate forked language variants. The ratified middle path:

- **Capability-interface model.** The runtime surface is a *parameter*, expressed as
  effect-labeled extern declarations bound per target — not a stdlib hardcoded into
  the compiler. The same effect-labeled extern (`fetch`, `readFile`) binds to a C
  function on native and a host import on WASM: same signature/semantics, different
  glue. (This is the platform abstraction of [`../CAPABILITY-PLATFORM.md`](../CAPABILITY-PLATFORM.md)
  viewed from the supply side — a platform *provides* capabilities; an effect row
  *declares* which are consumed.)
- **Stdlib stratification — a discipline to adopt NOW.** Split the library into:
  - a **pure core** (data structures, algorithms — capability-free), byte-identical
    on every target; and
  - **capability modules** (file IO, net, KV, time, RNG, …), effect-labeled, present
    only where the target provides the capability.
  Capability-bearing functions must be effect-labeled and live in capability
  modules, never the pure core. Retrofitting this is expensive — design it into the
  first stdlib reorganization. (See `../STDLIB.md`.)
- **Targets are configurations, not forks.** "General-purpose Medaka" = all
  capabilities + LLVM-native. "WASM-edge Medaka" = the host-granted subset + WasmGC.
  Same frontend, type system, Core IR, and pure core.
- **Effects make multi-target HONEST.** A program using `<File>` simply won't
  typecheck/link against a target that doesn't provide `<File>` — a clear *static*
  error, never silent runtime divergence. This is the guarantee against "one language
  that is secretly two."
- **Capabilities are the mechanism for EVERY native-vs-WASM "what can it do"
  difference** — threads, raw filesystem, real sockets become capabilities the native
  target provides and the edge target doesn't, surfaced in types. No forks, no
  `#ifdef`.
- **Guardrail for the general-purpose ambition:** general-purpose = a *superset of
  capabilities over identical semantics*, never different semantics. The moment
  "native" means values *behave* differently (not just "more capabilities
  available"), the language has split. The value-representation discipline (§7.1)
  enforces this.

## 7. Open decisions to lock before building the runtime

1. **Value representation — one abstract contract, two physical encodings
   (RATIFIED 2026-06-07; reconciliation in §8.6).** There is **no single physical rep across backends** —
   WasmGC has no machine words to tag and no conservative GC, so a tagged word cannot
   port to it. The resolution is layering, not a winner: a single **abstract value
   contract** (`Int` **63-bit** as today — §8.0 fact 1; `Float` 64-bit IEEE; the value
   kinds; equality/ordering/match; type-directed behaviour resolved at compile time;
   **boxing invisible**) that the **Core IR, extern *signatures*, and all observable
   semantics depend on** — plus two physical encodings that never leak upward:
   **native** = OCaml-style uniform tagged word (§8.1, recommended, spike-proven);
   **WasmGC** = `i31ref` (≤31-bit immediates) + typed structs over the host GC. The
   only asymmetry is WasmGC boxing 32–63-bit ints — a perf cost, **invisible to
   semantics**. So §8's tagged word and the WasmGC constraint are not in conflict;
   they live at different layers. Gates every `LEAF` row and the two `(rep)` rows.
   (§2a; full reconciliation §8.6; rationale `STAGE2-DESIGN.md` §2.4/§2.4b.)
2. **String representation** — UTF-8 + cached codepoint count vs. other; gates
   `stringLength`/`charCode` intrinsic-vs-leaf and all string `LEAF`/`UNICODE`
   helpers. (§4) — **still open.**
3. **GC**: Boehm-first is decided; the `gc_alloc`/object-header contract is now
   **partly settled** — the **uniform one-word header is ratified** (§8.4, 2026-06-07),
   so `gc_alloc` returns a `{header, fields…}` cell. **Still open:** whether `set_ref`
   needs a write barrier now or later. (§2b)
4. **Closure ABI & calling convention** — **substantially RATIFIED 2026-06-07** (§8.5):
   uniform `i64`-in/`i64`-out ABI, `musttail`/`tailcc` for guaranteed TCO (spike-proven,
   self-recursive), and the boxed closure cell `{header, code_ptr, captured…}` with the
   closure word passed as the leading arg. **Still open:** the `panic` **unwind model**
   (abort vs. catchable unwind, §4) and cross-function `musttail` (mutual recursion,
   the prototype-match increment). **Guaranteed tail calls are available on both
   backends** (LLVM `musttail`; WasmGC `return_call`, Wasm 3.0 — verified 2026-06-06,
   see `STAGE2-DESIGN.md` §2.4).
5. **Where the ABI is first proven**: at the **bytecode VM (§2.2)**, against the
   tree-walker oracle — not at LLVM. (§2 sequencing note) — **done** (the VM + the LLVM
   spike thru slice 9 both exercised it; §2.2/§2.4).

Decisions 1, 4, and 3's header half are now settled (2026-06-07 rep ratification, §8);
2, the `set_ref` barrier, the unwind model, and string rep remain — all exercisable in
the cheap, oracle-backed bytecode-VM/spike setting before any native runtime exists.

## 8. Value representation & calling convention

> **Status: RATIFIED 2026-06-07.** Option A (uniform tagged word) is adopted as the
> **native** physical encoding, *under the shared abstract value contract of §8.6* —
> the ratification is of the contract + this encoding, not a backend-specific bit
> layout (so WasmGC compatibility is structural: it implements the same contract with
> `i31ref` + typed structs; §8.6). The Stage-2.4 de-risking spike
> (`selfhost/llvm_emit.mdk` + `runtime/medaka_rt.c`, gated by
> `test/diff_selfhost_llvm.sh`, 43/43 byte-identical to the tree-walker) proved the
> encoding end-to-end. **Ratified decisions (human, 2026-06-07):**
> 1. **Native rep = Option A** (low-bit-1 immediate 63-bit `Int`/`Char`/`Bool`/`Unit`/
>    nullary ctors; boxed pointers) — *conditioned on §8.6's abstract contract so the
>    semantics are WasmGC-compatible*.
> 2. **Constructor tag = dense i32 ctor-ordinal per type** (NOT the spike's i64
>    string-hash) — ports to LLVM/WasmGC `br_table` and eliminates the
>    hash-**collision** miscompile class. (The separate `decodeHead` reserved-name
>    aliasing bug — a user ctor named `Cons`/`Nil`/`Unit` decoding to the built-in
>    head at lowering — was a *distinct* name-keying hazard; FIXED 2026-06-07 by
>    reserving synthetic `__cons__`/`__nil__`/`__unit__` head names in `canonPat`,
>    not by the tag change; PLAN.md.) **The spike now emits ordinals** (done
>    2026-06-07, `llvm_emit.mdk` `cellTag`): a composite `typeId<<32 | ordinal` whose
>    low half is the ratified dense per-type ordinal and whose high half is a per-type
>    id that keeps the spike's cross-type arg-tag dispatch correct (the real backend
>    resolves those sites statically and keeps only the low-half ordinal). `ceval` is
>    irrelevant to tags — it walks `VCon` by name and never materializes a tag.
> 3. **Heap header = keep a uniform one-word header on every boxed cell** (the ADT tag
>    rides here; uniform cell shape for switch tag-testing; eases precise-GC migration).
> 4. **`Float` = boxed-first** (§8.4) — type-directed local unboxing only if profiling
>    demands it.
> 5. **Scalar self-description = not required** (§8.4) — generic rendering goes through
>    compile-time `Debug` (`→METHOD`, §2c); the runtime never reflects on scalar layout.
>
> The spike's rep remains revisable in one place (`llvm_emit.mdk`'s tag/box helpers +
> `medaka_rt.c`); ratifying the *contract* is what is now locked, not the spike's
> expedient i64 hash (decision 2 supersedes it for the real backend).

> **Layering note (reconciles §7.1's WasmGC constraint — 2026-06-06).** §8.0–8.5
> describe the **native (LLVM + Boehm) physical encoding** — *one of two* physical
> encodings of a single shared **abstract value contract**. The WasmGC encoding (the
> wedge backend) is its peer, defined in **§8.6**, which also states the shared
> contract and the layering rule that keeps the two "one language." §8's tagged word
> and §7.1's "no tagging on WasmGC" are **not in conflict**: §8 answers *"how does the
> native backend encode a value"* (tagged word — correct), the WasmGC constraint
> answers *"what may the shared contract assume"* (not tagging — correct). The only
> error would be conflating them; §8.6 keeps them at separate layers.

### 8.0 What the value set actually is (the constraints)

The native rep must encode every runtime value kind the tree-walker has
(`lib/eval.ml`'s `Value` / `selfhost/eval.mdk`'s `Value`), effects erased:
**immediate-ish scalars** — `Int`, `Float`, `Char`, `Bool`, `Unit`; **heap
aggregates** — `String`, `Tuple`, `List`, `Array`, ADT (`VCon`), `Record`, `Ref`,
closures; and the laziness cell `VThunk` (letrec / recursive values). Three facts
dominate the choice:

1. **Medaka's `Int` is already 63-bit.** It *is* OCaml's `int`: `intMaxBound =
   4611686018427387903 = 2^62 − 1`, `intMinBound = −2^62` (verified on the binary).
   Every Medaka program already assumes a 63-bit `Int`. So a rep that spends **one**
   bit on a tag and keeps 63 for the integer is **lossless** — it changes no
   observable behaviour. Any rep that gives `Int` *fewer* than 63 bits (e.g.
   NaN-boxing's 48–51) is a **semantic regression**.
2. **`Float` is a full 64-bit IEEE double.** A 64-bit word holds a full `Int` *or* a
   full `double`, never both *plus* a tag. Something has to give for floats; which
   thing differs per option below. (The spike confirmed this physically: floats are
   the one slice-1 value it had to heap-allocate — `CLit (LFloat _)` is the only
   node that calls `@mdk_alloc`.)
3. **GC is conservative first (Boehm).** `PLAN.md` commits to Boehm before any
   precise GC. Conservative scanning of the C stack/heap interprets any word that
   *looks like* an aligned heap pointer as a live reference. This **couples the rep
   to GC correctness** and is the single most decision-changing constraint — it is
   what eliminates the otherwise-attractive NaN-box (see 8.2). **Spike status
   (2026-06-07): live — `runtime/medaka_rt.c`'s `mdk_alloc` now routes to Boehm's
   `GC_malloc` (`GC_INIT()` once via a constructor before the emitted `main`).** The
   nullary-ctor IMMEDIATE rep made this sound across the whole value set: every
   immediate is odd, every boxed value an 8-byte-aligned real pointer, so Boehm's
   conservative scan never mistakes a scalar for a pointer and never misses a live
   cell. Verified collecting (not a silent malloc fallback): a 2×10⁸-cons churn
   program holds ~3 MB RSS where malloc-and-leak balloons to ~600 MB. Precise GC
   remains future work.

Also load-bearing, and already decided elsewhere in this doc: `hash`/`inspect` are
`→METHOD` and `Eq`/`Ord`/`Debug` are typeclass methods (§2c, §4). So **the runtime
never reflects on an opaque value's layout** — type-directed behaviour is resolved
at compile time. That is what lets the rep get away with *not* self-describing
every value (see the Bool-vs-Int note in 8.4).

### 8.1 Option A — Uniform tagged word  *(RECOMMENDED)*

A value is one 64-bit machine word. The low bit discriminates:

- **low bit 1 → immediate.** The other 63 bits are a signed integer. `Int`, `Char`
  (codepoint), `Bool` (0/1), `Unit` (0), and **nullary data constructors** (`None`,
  `Nil`, `True`, an enum's tag index) are all immediates — *no allocation*.
  Untag = `ashr 1`; tag = `(x << 1) | 1`. This is exactly OCaml's own scheme.
- **low bit 0 → pointer.** An 8-byte-aligned pointer to a heap cell (whose low 3
  bits are therefore 0). `Float`, `String`, `Tuple`, `List` cons, `Array`,
  `VCon`-with-fields, `Record`, `Ref`, closures, thunks all box.

The heap cell carries a **one-word header** (a small layout/tag id + field count)
followed by the fields (each itself a word). The spike boxes `Float` as exactly
this: `{ i64 header, double }`.

**Why this wins for Medaka, concretely:**
- **Lossless `Int`** (fact 1) — the entire reason it beats NaN-box. 63-bit ints are
  *the* hot value in a compiler workload (the self-host source is integer- and
  pointer-heavy; floats are rare).
- **Conservative-GC-friendly** (fact 3) — immediates are *odd*, so Boehm never
  mistakes an `Int`/`Char`/`Bool` for a pointer; real pointers are genuine aligned
  pointers Boehm tracks natively. No hidden pointers, no displacement tricks. This
  is the property NaN-box cannot offer under Boehm. **The spike now runs on Boehm**
  (2026-06-07): `mdk_alloc` → `GC_malloc`; this odd-immediate invariant is exactly
  what makes the conservative scan sound, now that nullary ctors are immediates too.
- **Nullary constructors are free** — `None`/`Nil`/enum tags never allocate, a real
  win for the `Option`/`List`/`Result`-heavy stdlib.
- **Proven** — it is what the spike runs, and it is OCaml's battle-tested scheme,
  so the reference interpreter and the native backend share an integer model.

**Cost:** every `Int` arithmetic op pays a shift to untag and a shift+or to retag
(visible in the spike's emitted IR — that visibility is deliberate). Two mitigations
make this a non-issue *without* changing the uniform rep: (a) at `-O`, LLVM folds
much of the tag arithmetic across a chain of ops (the tags cancel); (b) because
Medaka is statically typed and monomorphizable, a later pass can keep `Int`/`Float`
**unboxed in locals/loops** (carry a native `i64`/`double` through a hot region,
tag/box only at boundaries) — an optimization the uniform rep permits but does not
require. The standing `Float`-always-boxes cost is the real one; see 8.4.

### 8.2 Option B — NaN-boxing  *(rejected as the primary rep)*

Encode every value inside a 64-bit double: real doubles are themselves; everything
else hides in the payload of a quiet NaN (the 51-or-48 spare bits carry a tag +
pointer/immediate). Floats are *free* (no box); the trade is that pointers/ints live
in NaN payloads.

**Two disqualifiers for *this* project, in priority order:**
1. **It fights conservative GC (fact 3) — the dealbreaker.** A heap pointer hidden
   in a NaN payload is stored as `0x7FFA_<48-bit-ptr>`, not as a clean aligned
   pointer. Boehm scanning that stack/heap word sees the NaN bit-pattern, **not** the
   pointer → it will not mark the pointee → use-after-free. NaN-boxing effectively
   *requires a precise GC* (or fragile interior-pointer/displacement hacks). We
   committed to Boehm-first; NaN-box would force precise GC up front — the exact
   "decision-dense, expensive" work Stage 2 defers.
2. **It regresses `Int` (fact 1).** A NaN payload gives ~48–51 bits, so `Int`
   becomes 48-bit — a silent narrowing of a type every existing program assumes is
   63-bit. Either accept the regression (changes semantics) or box big ints (adds a
   branch to *every* int op) — both worse than Option A's uniform shift.

NaN-boxing is the right call for a *float-dominated, precisely-GC'd* dynamic language
(it's why some JS engines use it). Medaka is int/pointer-dominated and Boehm-first —
the tradeoff points the other way. Revisit only if (a) a precise GC lands *and* (b)
profiling shows float boxing dominates.

### 8.3 Option C — Boxed-everything  *(rejected; kept as the correctness floor)*

Every value, including `Int`, is a heap pointer to a tagged cell. Conservative GC
becomes trivially correct (every word is a real pointer), and there is no tag
arithmetic. But an `Int` per allocation is catastrophic for an integer-heavy
workload — allocation and GC pressure on the hottest value. Rejected for perf.

It is worth naming because it is **what the spike's `Float` path already is** (a
boxed scalar) and what a first-cut bytecode VM can use unchanged: it is the
zero-risk fallback if a tagged-word bug ever needs bisecting. Correctness floor, not
a destination.

### 8.4 Recommendation & the questions it leaves for ratification

**Adopt Option A (uniform tagged word, OCaml-style: low-bit-1 immediate `Int`,
boxed pointers).** It is lossless for Medaka's 63-bit `Int`, conservative-GC-safe
under Boehm, frees nullary constructors, and is already proven by the spike. NaN-box
is rejected primarily because it breaks conservative GC and secondarily because it
narrows `Int`; boxed-everything is the correctness floor, not the rep.

Decisions this leaves open — **all RATIFIED 2026-06-07** (see the §8 status banner;
recorded inline here):

- **Constructor tag scheme** (NOT in the original list — surfaced by spike slice 3).
  **RATIFIED: dense i32 ctor-ordinal per type**, replacing the spike's i64
  string-hash. Ports to LLVM/WasmGC `br_table` and eliminates the hash-**collision**
  miscompile class. (The `decodeHead` reserved-name aliasing bug was a *distinct*
  name-keying hazard — FIXED 2026-06-07 by reserving synthetic `__cons__`/`__nil__`/
  `__unit__` head names in `canonPat`, not by the tag change.) **The spike now emits
  ordinals** (done 2026-06-07): `llvm_emit.mdk` `cellTag` stamps a composite
  `typeId<<32 | ordinal` (low half = the ratified dense per-type ordinal for
  `br_table`; high half = a per-type id retained only for the spike's runtime
  cross-type arg-tag dispatch, which the real backend resolves statically). `ceval`
  is irrelevant to tags — it dispatches on `VCon` by name, never a tag.
- **Heap header.** Include a one-word header on boxed cells now (the spike does), or
  omit under Boehm (which tracks size itself) and add it when precise GC lands?
  **RATIFIED: include it** — 8 bytes/object buys an easy precise-GC migration, a
  uniform cell shape for switch tag-testing (the ADT tag rides here), and a fallback
  generic `Debug`, cheap relative to the allocation it rides on.
- **`Float` unboxing.** Ship floats boxed (Option A baseline) and add type-directed
  local unboxing later, or invest in unboxed `Float` from day one? **RATIFIED: boxed
  first** — floats are rare in the bootstrap path; unbox only if profiling says so.
  (This is the one row where NaN-box would have helped — record it.)
- **`Bool`/`Int` indistinguishability.** Under Option A a `Bool` and the `Int` 0/1
  share a bit-pattern. The spike handles this by choosing the print routine from the
  *static* type — fine because slice 1 is monomorphic and `Debug` is `→METHOD`
  (compile-time dispatched, §2c). **RATIFIED: the rep is not required to
  self-distinguish scalar types** — generic rendering goes through compile-time
  `Debug`, never runtime reflection. (If a future feature needs runtime scalar
  reflection, that is when a header tag on a boxed scalar, or a distinct `Bool`
  immediate tag, earns its keep.)

### 8.5 Calling convention sketch (commit: `musttail` for tail calls)

The uniform-word rep makes the convention fall out cleanly:

- **Uniform word ABI.** Every compiled Medaka function takes and returns the 64-bit
  value word. An arity-*n* function is `T @f(T %a0, … , T %a{n-1})` with `T = i64`.
  Medaka's multi-arg lambdas are **true n-ary** (`x y => body`, *not* curried — see
  AGENTS.md), so a function has a fixed arity; partial application builds a closure
  (PAP) rather than currying through one-arg trampolines.
- **Two calling conventions, one boundary.** Medaka↔Medaka calls use a
  **tail-callable convention** (`tailcc`); Medaka↔runtime-extern calls use the **C
  convention** (`ccc`) — the C-ABI-over-opaque-pointers boundary §2a/§6 already
  commit to. The runtime never sees `tailcc`; compiled code marshals to `ccc` at the
  extern call (the spike already does this: its `@mdk_print_*` / `@mdk_alloc` calls
  are plain C-ABI).
- **`musttail` for syntactic tail calls — committed.** Medaka leans on deep
  non-accumulating recursion (the unary `isEven`/`isOdd`, `foldl`, the tree-walker's
  own recursion); without guaranteed TCO it would stack-overflow where the
  tree-walker does not. Emit LLVM **`musttail`** on every call in tail position.
  `musttail` requires the caller and callee to share calling convention and return
  type and for the call to be immediately followed by `ret` — and the **uniform
  i64-in/i64-out ABI satisfies the signature-match constraint for free** (every
  Medaka function is `i64(…)→i64`). That synergy is a second, independent reason the
  uniform word pays off: it is precisely what makes universal `musttail` legal. Use
  `tailcc` to also get TCO on calls LLVM can't mark `musttail` (e.g. through a
  function-pointer/closure where the convention still matches).
- **Empirically validated (2026-06-05) — spike slice 2.** The de-risking spike
  (`llvm_emit.mdk`, STAGE2-DESIGN.md §2.4) now emits real functions + calls, and
  `musttail` is confirmed end-to-end on `clang -O0` for arm64: a self-recursive
  tail call lowers to `%r = musttail call i64 @mdk_f(…)` immediately followed by
  `ret i64 %r`, and a 5,000,000-deep tail-recursive `sumTo` returns the correct
  total with no stack growth (a plain `call` overflows). The spike uses the **C
  convention (`ccc`) for the i64-in/i64-out functions**, not `tailcc`, and
  `musttail` is still accepted and TCO-correct there — so the signature-match
  argument above holds under the default cc, and the `tailcc` upgrade (line above)
  is an optimization for the non-`musttail`-able cases rather than a prerequisite.
  Scope caveat: only **self-recursive** tail calls are emitted as `musttail` so far
  (self-recursion trivially satisfies the prototype-match rule); cross-function
  `musttail` (mutual recursion) needs an explicit prototype-match check and is the
  next increment.
- **Empirically validated (2026-06-06) — spike slice 3 (ADTs + match).** The spike
  now emits the first **heap-allocated non-scalar** values: a constructor is a boxed
  cell `{ i64 tag, field… }` via `mdk_alloc` (the §8.4 Option-A layout, the Float
  box extended to N fields), and a `match` is a decision-tree CFG (tag-test `br`
  switch → `getelementptr` field projection → arm body). 22/22 gate. Two rep
  decisions surfaced for the real backend (deferred — see STAGE2-DESIGN.md
  §2.4/§2.4a spike-rep notes):
  (1) ~~the spike **boxes nullary constructors** (1-word alloc) where §8.1 says they
  should be **immediate/free**~~ **DONE 2026-06-07** — the spike now emits a nullary
  ctor as the §8.1 IMMEDIATE word `(cellTag<<1)|1` (no alloc, the Bool immediate
  generalised); a `match` head reads the tag via `loadDiscriminant` (branch on the
  low bit: immediate ⇒ `ashr 1`, boxed ⇒ load header), so a type mixing nullary +
  boxed ctors discriminates without dereferencing an immediate (`llvm_emit.mdk`
  `emitCtorAlloc`/`loadDiscriminant`; adversarial `test/llvm_fixtures/adt_imm_mixed.mdk`);
  (2) ~~the i64 string-hash
  tag~~ **DONE 2026-06-07** — the spike now emits the **dense i32 ctor-ordinal**
  (per type, via `cellTag`) that ports to LLVM/WasmGC `br_table` cleanly and avoids
  collisions. The emitted encoding is
  the native physical rep (§8.6); a WasmGC sibling would use `i31ref` + typed structs
  over the host GC, sharing only the Core IR, not the bits.
- **Empirically validated (2026-06-06) — spike slice 4 (closures + HOFs).** The
  closure rep below is now proven on the spike: a `CLam` lambda-lifts to a top-level
  `define`, the closure cell `{ header, code_ptr, captured… }` allocates via the
  same `mdk_alloc` path, and a higher-order call loads `code_ptr` and passes the
  closure word as the leading arg. 35/35 gate (slices 1–5b). Rep decisions surfaced (deferred —
  STAGE2-DESIGN.md §2.4/§2.4a spike-rep notes (d)–(f)): the one-word **header is never inspected** and
  could be dropped; **saturated calls only** (arity must move into the cell for
  partial/over-application); named-fn-as-value is **eta-wrapped per use** (could be
  interned once arities are carried).
- **Closures.** A closure value is a boxed cell `{ header, code_ptr, captured… }`;
  calling loads `code_ptr` and passes the closure (env) pointer as a leading
  argument. (LLVM spike slice 4, 2026-06-06: proven end-to-end — `CLam`
  lambda-lifted to a top-level `define @mdk_lamN(i64 %clos, i64 %arg…)`, cell
  allocated via the same `mdk_alloc` path as ADTs with "fields" =
  `[code_ptr, capture…]`, indirect call passes the closure word as the leading arg.
  **Saturated calls only** — the type-erased Core IR can't see arity at the call
  site, so partial/over-application are deferred: the real backend must carry arity
  in the cell. The spike's one-word header is never inspected and could be dropped.
  See STAGE2-DESIGN.md §2.4/§2.4a spike-rep notes (d)–(f).)
- **`panic`/`exit`.** `noreturn` (§4). The unwind model (abort vs. catchable
  unwind) is deferred with the convention, as §4 already notes.

**Where this gets proven.** Per the §2 sequencing note, the rep + convention should
be exercised at the **bytecode VM (§2.2)** against the tree-walker oracle before the
real LLVM backend — the VM forces the same value-representation and C-ABI-extern
commitments in the cheaper, single-steppable setting. This spike is the *earliest*
such exercise (LLVM-side; scalars + functions + ADTs/match + closures/HOFs so far); the VM will
broaden it to the full value set (records, arrays, closures, thunks, dispatch) with
the same oracle.

### 8.6 The shared contract + the WasmGC encoding (reconciliation)

§8.0–8.5 are the **native (LLVM + Boehm) physical encoding**. WasmGC — the wedge
backend (`STAGE2-DESIGN.md` §2.4b) — *cannot* use them: it has **no machine word to
tag** (references are opaque; you can't put an `Int` in a pointer's low bit) and **no
conservative GC** (it is a precise, host-managed collector over typed references). So
there is no single physical rep across both backends — **and there does not need to
be.** What must be single is the **abstract value contract** both encodings implement.

**The shared abstract contract** — the source of truth for the **Core IR, extern
*signatures*, and all observable semantics:**
- Value kinds: `Int` (**63-bit**, today's OCaml-int semantics — §8.0 fact 1), `Float`
  (64-bit IEEE), `Char`, `Bool`, `Unit`, `String`, `Tuple`, `List`, `Array`, ADT,
  `Record`, `Ref`, closure, thunk.
- Semantics — equality, ordering, pattern matching, arithmetic width — identical on
  every backend.
- Type-directed behaviour (`hash`/`Debug`/`Eq`/`Ord`) is resolved at **compile time**
  (§2c), so the runtime never reflects on layout — true for both encodings.
- **Boxing is invisible** — whether a value is unboxed or heap-allocated is a
  per-backend optimization, never observable.

**The two physical encodings:**

| | Native (LLVM + Boehm) — §8.1 | WasmGC (wedge backend) |
|---|---|---|
| value slot | 64-bit tagged word | `anyref`/`eqref` |
| immediates | low-bit-1: **63-bit** Int / Char / Bool / Unit / nullary ctors | **`i31ref`** — but only **≤31-bit** |
| heap aggregates | aligned pointer to `{header, fields…}` | typed `struct`/`array` refs |
| `Int` 32–63 bits | unboxed (63-bit immediate) | **boxed** `(struct (field i64))` |
| `Float` | boxed `{header, double}` | boxed `(struct (field f64))` |
| GC | Boehm conservative (immediates odd → never mistaken for a pointer) | host precise GC over the declared struct types |
| headers | one-word layout/tag id (§8.4) | the struct *type* carries layout; explicit tag field only where a sum needs it |

**The one honest asymmetry.** WasmGC unboxes only `≤31-bit` ints (`i31ref`); native
unboxes the full **63-bit** range. So 32–63-bit ints **box on WasmGC but not native**
— a *performance* asymmetry, **invisible to semantics** (a boxed int is still a full
63-bit `Int`). It costs the edge target some boxing on large ints (rare in typical
edge/plugin code) and costs the language nothing semantically. (This is the WasmGC
analogue of §8's "Float always boxes" cost.)

**The layering rule (what keeps it one language).** The **Core IR, the extern
*signatures*, and every observable behaviour depend ONLY on the abstract contract.**
The tagged word (§8.1) is the native backend's private encoding; the i31/struct scheme
is WasmGC's; neither leaks upward. §8.5's uniform `i64`-in/`i64`-out ABI +
`tailcc`/`musttail` is the **native** calling convention; the WasmGC convention is its
peer — `anyref` params/returns and **`return_call`** for guaranteed TCO (verified
available, `STAGE2-DESIGN.md` §2.4b) — achieving the *same* guaranteed-TCO contract by
a different instruction. Extern *bindings* differ per backend (C-ABI native;
host-import/WIT on WasmGC — §6a); only the signatures are shared.

**Single recommendation (resolves the §7.1 flag) — RATIFIED 2026-06-07.**
1. **Ratify §8.1 Option A as the *native* encoding** — its Boehm/tagged-word argument
   is sound and spike-proven; nothing here changes it. ✅ **ratified.**
2. **Adopt the abstract contract above as the cross-backend source of truth** — Core
   IR, extern signatures, and observable semantics target *it*, never an encoding.
   ✅ **ratified** (this is the condition attached to decision 1 — the native encoding
   is adopted *under* this contract, so WasmGC compatibility is structural).
3. **Plan the WasmGC encoding as a peer** (`i31ref` + typed structs, host GC),
   designed to the same contract when the WasmGC backend is built. ✅ **ratified as the
   plan;** the dense-i32-ctor-ordinal tag decision (§8.4) was made `br_table`-ready
   precisely to serve this peer.
4. **Accept the ≤31-bit unbox asymmetry on WasmGC** — the one net-new decision; it is
   invisible to semantics, so accept it. ✅ **accepted.**

Two physical runtimes (Boehm+tagged-word native; host-GC+structs WasmGC) are
*expected and fine* — "one language" is guaranteed by the shared contract + the
layering rule, not by a shared encoding. §8 and §7.1 were never in real conflict;
they sit at different layers.
