# Workstream: STDLIB

**Owns:** missing stdlib/support functions.
**Touches:** `stdlib/`, `compiler/support/util.mdk`.

⚠️ **`stdlib/core.mdk` is the PRELUDE.** Touching it moves **every** snapshot golden and
perturbs the fixpoint. Land core changes at a checkpoint, alone, and re-cut goldens in the same
PR.

These are not wishlist items. Each one is **currently causing duplication or a bug** in the
compiler, and each was surfaced by an agent that had to hand-roll it.

---

## L-1 · An effectful traversal family — `mapMut` / `foldlMut` / `zipWithMut`

`map` / `zip` / `foldl` are **pure**, so **every `<Mut>` traversal in the compiler gets
hand-rolled.** `llvm_emit.mdk` now carries **four near-clones** (`bindFields` / `bindEach` /
`emitRefutFields` / `emitRefutEach`) plus a one-off `mapMut : (a -> <Mut> b) -> List a -> <Mut> List b`
written for exactly this reason.

Wanted, at minimum in `support/util.mdk`:
```medaka
foldlMut  : (acc -> a -> b -> <Mut> acc) -> acc -> List a -> List b -> <Mut> acc
zipWithMut : (a -> b -> <Mut> c) -> List a -> List b -> <Mut> List c
```

## L-2 · `boolToString : Bool -> String`

`intToString` and `floatToString` are both externs (`stdlib/runtime.mdk:171-172`). **`Bool` has
no sibling.** `display` on `Bool` works but drags in dict dispatch, which is unusable for
compiler-internal instrumentation.

Not merely cosmetic: a shadow bug surfaced as the panic `intToString: not an Int`. **A
`boolToString` would have made that bug LOUDER, not silent.**

## L-3 · String length has no ergonomic name

It is the raw extern `stringLength` (`runtime.mdk:210`). `stdlib/string.mdk` does not re-export
it, and the `Foldable` `length` does not apply to `String`. An agent guessed `strLen` and got
"unbound variable".

## L-4 · `dropPrefix` / `stripPrefix` / `dropSuffix`

`util` already has `startsWith` / `endsWith`. The obvious siblings are missing, so `wasm_emit.mdk`
hand-rolls `dropPrefix` as `stringSlice (stringLength p) (stringLength s) s`.

Haskell's shape is the one actually wanted: `stripPrefix : String -> String -> Option String`.

## L-5 · Two `startsWith`s with OPPOSITE argument orders

`support/util.startsWith pre s` (prefix first) vs `wasm_emit.startsWithStr s p` (string first).
**Both are `String -> String -> Bool`, so the typechecker cannot help you.** An agent wrote the
arguments in the wrong order, got a silent `False`, and only found out via an `unbound variable
'__ft__clause23113'` **four minutes into a full rebuild**.

Unify `wasm_emit`'s private `startsWithStr` / `dropPrefix` onto util's order and delete the
duplicates.
