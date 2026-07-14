# Workstream: STDLIB

**Owns:** missing stdlib/support functions.
**Touches:** `stdlib/`, `compiler/support/util.mdk`.

```sh
gh issue list --label "ws:stdlib" --state open
```

The items here are **not a wishlist.** Each one is *currently* causing duplication or a bug in the
compiler, and each was surfaced by an agent that had to hand-roll it.

---

## ⚠️ `stdlib/core.mdk` is THE PRELUDE. Land core changes at a checkpoint, ALONE.

Its blast radius is **5 golden families, ~120 files, 7 gates — and none of it is greppable**:

- snapshot goldens
- **every `check` golden is a full prelude SCHEME DUMP** — so adding one helper moves all of them
- `selfproc` + the LSP completion list
- `eval_prelude` / `core_ir_prelude` / `core.test.golden` — **doctests keyed on `core.mdk:NNN` line
  numbers**, so inserting a line moves them
- `stdlib/core.lextok.golden` — **token dumps**

Five helpers added to `core.mdk` once turned **5 of 6 CI shards red**. And in one session **three
agents claimed "no goldens moved". All three were wrong.**

**Re-cut the goldens in the SAME PR** — the compiler's own sources are in the snapshot corpus, so a
source change moves its own golden. Push the source without the golden and `main` goes red, and the
hook then forces the *next* agent to bless a file they never touched.

---

## The compiler MAY import `stdlib/` — but WEIGH IT PER MODULE

Policy changed 2026-06-29; the old blanket ban is retired. Measured:

- **Importing a module whose types' instances live in `core`** (the always-present prelude) is
  **near-free** — `import list`/`import string` drag no new instance surface, so DCE trims to the
  referenced standalone fns (**−256 B, +2% ≈ noise**).
- **Importing a module that defines a NEW type is not.** DCE keeps every `DImpl`/`DInterface` **whole**
  (runtime dict-passing → pruning an impl would be a silent miscompile), so `import map` drags `Map`'s
  entire Eq/Ord/Debug/Display/Mappable/Monoid surface in — **+34 KB binary, +4.8% self-compile.**
- The imported module is **re-typechecked on every compile** *and* every fixpoint iteration.
- Once the compiler imports a stdlib module, any change there that perturbs emitted IR **forces a seed
  re-mint + fixpoint re-validation.** (A feature — it converts silent `support/`-vs-`stdlib/`
  divergence into a build-time gate — but it is churn.)

### ⚠️ Anti-pattern (measured): do NOT delegate hot monomorphic helpers to prelude Foldable methods
`elem` / `any` / `all` / `length` lose `||`/`&&` **short-circuiting** and become dict-passed
fold+closure. Doing this to `util.mdk`'s hottest helpers cost **+56% self-compile.**

### Migrating a `support/` structure to stdlib
A **polymorphic empty must be a nullary constructor.** A constructor *application* like `OMap Tip` is
NOT generalized → it monomorphises → "Scheme vs Unit" cascades. And any harness running the
emitter/probes over compiler source must pass `$STDLIB` as well as the compiler root.

---

## The layout

`stdlib/runtime.mdk` (extern primitive catalog, read from disk at runtime) · `core.mdk` (**the implicit
prelude** — `Eq`/`Ord`/`Debug`/`Num`/…) · plus `list`/`string`/`array`/`map`/`set`/`io`/`hash_map`/
`hash_set`/`mut_array`/`json`/`byteparser`/`bytebuilder`.

**Only `core.mdk` is auto-prelude** — import the rest by bare name (`import map`). `io.mdk` is the
ergonomic layer over the `runtime.mdk` IO externs.

⚠️ A non-prelude `impl` is **out of scope until you `import` its module** — so "No impl / Ambiguous" is
*not* necessarily a dispatch bug.

---

## Two traps that make silent bugs

- **`boolToString` does not exist** (#79). `intToString`/`floatToString` are both externs; `Bool` has no
  sibling. This is not cosmetic: a shadow bug surfaced as the panic `intToString: not an Int`. **A
  `boolToString` would have made that bug LOUDER, not silent.**
- **Two `startsWith`s with OPPOSITE argument orders** (#79) — `util.startsWith pre s` vs
  `wasm_emit.startsWithStr s p`. **Both are `String -> String -> Bool`, so the typechecker cannot help
  you.** An agent wrote them in the wrong order, got a silent `False`, and found out four minutes into
  a full rebuild.

**When two functions have the same type and opposite meanings, the type system is not a safety net —
it is camouflage.**

---

## Doctest gotchas

Stdlib doctests are **single-file, all-or-nothing** — one malformed example aborts the file (#55). And
**every doctest runs under the interpreter**, so a compiled-only bug is invisible to them; wrap `Array`
in `toList` for stable output.
</content>
