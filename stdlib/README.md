# Medaka stdlib

<!-- Verified against native compiler, 2026-07-13 -->

## `runtime.mdk` — built-in extern catalog

`stdlib/runtime.mdk` is the authoritative source of type signatures for all
`extern` primitives — the native operations exposed to Medaka programs. It is
read from disk at compiler startup (no embed/generation step).

### Adding a new primitive

The canonical, step-by-step procedure — declaring the signature in
`runtime.mdk`, implementing it in `compiler/eval/eval.mdk`, and (if the
primitive must also work under `medaka build`/the WasmGC playground) wiring
it into the LLVM and/or WasmGC backends, plus the `test/diff_compiler_capability_matrix.sh`
gate that checks all three engines agree — is documented in
[`.claude/skills/add-primitive/SKILL.md`](../.claude/skills/add-primitive/SKILL.md).
Follow that; this file does not duplicate it.

### Convention

- Pure functions: no effect annotation (`extern foo : a -> b`).
- Effectful operations carry an effect on the **return type**, read
  automatically by the effect checker — e.g. `<Stdout>`, `<Stdin>`,
  `<FileRead "_">`, `<Net "_">`, `<Mut>` (mutation via `setRef`), `<Panic>`
  (unrecoverable exit), or the coarser `<IO>` alias. See existing entries in
  `runtime.mdk` for examples of each.
- Type variables in extern signatures are implicitly universally quantified.
- A handful of unsafe externs (`arrayGetUnsafe`, `arraySetUnsafe`, `arrayBlit`,
  `arrayFill`, `bytesToFloat64`) are restricted to trusted roots — see
  `internalExterns` in `compiler/frontend/resolve.mdk` and the `--allow-internal`
  CLI flag — if your primitive is similarly unsafe, follow that pattern.
