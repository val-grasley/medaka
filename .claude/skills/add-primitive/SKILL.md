---
name: add-primitive
description: Add or modify a Medaka stdlib primitive (extern) — declare its type signature in stdlib/runtime.mdk and implement it in compiler/eval/eval.mdk. Use when a built-in function/operation is needed that can't be written in Medaka itself.
---

# Add a stdlib primitive (extern)

Primitives are the native operations exposed to Medaka programs. Their
signatures live in `stdlib/runtime.mdk` (loaded by the compiler at startup)
and their implementations in the `primitives` list in `compiler/eval/eval.mdk`.
See `stdlib/README.md` for the canonical conventions.

When you write **Medaka** code (e.g. wrappers in `core.mdk`/`list.mdk`), use
`x y => body`, never curried `x => y => body`.

## Steps

1. **Declare the signature** — add an `extern` line to `stdlib/runtime.mdk`:
   ```
   extern foo : a -> b
   ```
   Put an effect annotation on the **return type** if the operation is
   effectful — the effect checker reads these automatically:
   - pure → no annotation
   - IO → `<IO>` (e.g. `extern print : String -> <IO> Unit`)
   - mutation via refs → `<Mut>`
   - unrecoverable exit → `<Panic>`
   Type variables are implicitly universally quantified.

2. **Implement it** — add a matching entry to the `primitives` list in
   `compiler/eval/eval.mdk` (around the `primitives : List (String, Value)`
   binding). The name must match the extern exactly. A startup completeness
   assertion fails at runtime if an extern has no implementation (or vice
   versa), so the two lists must stay in sync.

3. **Rebuild** — `make medaka`. This recompiles the native compiler from
   `compiler/` source; the new extern becomes visible to the type checker and
   evaluator immediately.

## Verify

```sh
./medaka test stdlib/core.mdk        # run doctests
./medaka check stdlib/runtime.mdk    # extern signatures parse cleanly
```

Write an end-to-end program that calls the primitive and confirm it runs:

```sh
./medaka run scratch.mdk
```

For a broader gate, run the diff suite that exercises eval:

```sh
bash test/diff_compiler_eval.sh
bash test/diff_compiler_check.sh
```
