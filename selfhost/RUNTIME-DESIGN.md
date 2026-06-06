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
> representation is fixed (see §2).**

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

## 7. Open decisions to lock before building the runtime

1. **Uniform value representation** (tagged word / NaN-box / boxed) — gates every
   `LEAF` row and the two `(rep)` rows. (§2a)
2. **String representation** — UTF-8 + cached codepoint count vs. other; gates
   `stringLength`/`charCode` intrinsic-vs-leaf and all string `LEAF`/`UNICODE`
   helpers. (§4)
3. **GC**: Boehm-first is decided; confirm the `gc_alloc`/object-header contract
   and whether `set_ref` needs a barrier now or later. (§2b)
4. **Closure ABI & calling convention** — needed for `→MEDAKA` sorts to call their
   comparator, and for the unwind model behind `panic`. (§2b)
5. **Where the ABI is first proven**: at the **bytecode VM (§2.2)**, against the
   tree-walker oracle — not at LLVM. (§2 sequencing note)

All five are exercised by the bytecode VM before any native runtime exists, so the
cheap, oracle-backed setting is where they should be settled.
