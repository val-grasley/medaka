---
name: add-primitive
description: Add or modify a Medaka stdlib primitive (extern) — declare its type signature in stdlib/runtime.mdk and implement it in lib/eval.ml. Use when a built-in function/operation is needed that can't be written in Medaka itself.
---

# Add a stdlib primitive (extern)

Primitives are the native operations exposed to Medaka programs. Their
signatures live in `stdlib/runtime.mdk` (embedded into the compiler at build
time) and their implementations in the `primitives` list in `lib/eval.ml`. See
`stdlib/README.md` for the canonical conventions.

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
   `lib/eval.ml` (around the `let primitives : (string * value) list =`
   binding). The name must match the extern exactly. A startup completeness
   assertion fails at runtime if an extern has no implementation (or vice
   versa), so the two lists must stay in sync.

3. **Rebuild** — `dune build`. The dune rule reruns `gen/embed.ml` to
   regenerate `lib/stdlib_content.ml` from `runtime.mdk`, making the new extern
   visible to the type checker and evaluator immediately.

## Verify

```sh
./_build/default/test/test_eval.exe --compact
./_build/default/test/test_run.exe --compact
```

Write an end-to-end program that calls the primitive and add it to
`test/test_run.ml`. For a quick manual check, write a scratch `.mdk` and run
`./_build/default/bin/main.exe run scratch.mdk`.
