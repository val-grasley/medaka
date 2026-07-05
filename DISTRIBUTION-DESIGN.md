# DISTRIBUTION-DESIGN.md — shipping a native `medaka` binary to strangers

> **Goal.** A relocatable `medaka` (+ `medaka_emitter`) that a stranger on macOS
> or Linux can install and use `medaka build` with — the "now do something real"
> path of the 0.1.0 funnel ([`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) §W1).
> Windows is explicitly out of scope.

Status: **design + dependency audit done; not yet started.** The audit below was
taken directly against the tree — file:line evidence is load-bearing, re-verify
if the code has moved.

---

## 1. The good news — codegen and runtime are already portable

Two findings that mean this is a *packaging* problem, not a *compiler* problem:

- **Emitted LLVM IR carries no target triple / datalayout.** `llvm_preamble.mdk`
  emits only `declare` lines; grep for `triple|datalayout|arm64|x86_64|apple|darwin`
  across `llvm_emit.mdk` / `llvm_preamble.mdk` / `medaka_rt.c` returns nothing. IR
  is target-neutral; clang defaults to the host. No `-arch`, no `.dylib`/`.so`
  assumptions in the emitter.
- **`runtime/medaka_rt.c` is POSIX-clean** — standard POSIX headers + `gc.h`, no
  `__APPLE__`/`__linux__` ifdefs, no dylib logic. Portable between macOS and Linux
  as-is.

So the work is entirely in the **packaging + discovery seam**.

## 2. Portability blockers (audit)

Each is a thing that currently assumes "running inside this repo, on this dev
machine." File:line references are from the audited tree.

1. **stdlib is located only via `MEDAKA_ROOT` (default `.` = cwd).** No
   argv[0]-relative and no compiled-in path. `medaka_cli.mdk` header comment
   states there is **no `getcwd`/`executable_name` extern**. Every subcommand
   derives `root ++ "/stdlib/..."` (`medaka_cli.mdk` `check`~:203, `build`~:481,
   `run`~:633, `test`~:717, `doc`~:732). A binary moved out of the repo, run
   anywhere but the repo root, fails to load `stdlib/{runtime,core}.mdk`.
   → **Needs a new exe-path primitive + exe-relative default.** *(This is also
   shared with any interpreter-only distribution — it's not native-build-specific.)*

2. **Mach-O-only stack-size linker flag, hardcoded + unconditional.**
   `-Wl,-stack_size,0x20000000` at `build_cmd.mdk:262` (and every bootstrap
   script). GNU ld on Linux **rejects** this outright (it uses `-z stacksize=`).
   Documented as "the arm64 macOS ceiling" (`selfcompile_lex.sh:36`). → **Must be
   platform-conditional**, and see the Linux stack risk in §3.

3. **`medaka build` needs a second compiled binary, `medaka_emitter`**, pointed
   to by `MEDAKA_EMITTER`. The `medaka run <emitter>` fallback is **non-functional**
   (`build_cmd.mdk:176-182` — the LLVM entry's `main` uses the `args` runtime
   extern, unbound in `medaka run` → resolve error). So shipping `medaka` alone
   does not give a working `build`; ship **both** binaries + default the env var.

4. **libgc (bdw-gc) is a required system dep, dynamically linked (`-lgc`), not
   vendored.** Three-tier probe in `detectGC` (`build_cmd.mdk:85-118`):
   pkg-config `bdw-gc` → `brew --prefix bdw-gc` → bare `-lgc`; hard-errors with an
   install hint if all fail (`:254`). Both *building* and *every produced binary*
   depend on libgc at runtime. → **Either lean on the package manager to install
   it, or vendor + static-link.**

5. **`clang` assumed on `PATH`** (`CC` default `"clang"`, `medaka_cli.mdk:483`),
   and **`runtime/medaka_rt.c` is compiled from source on every build** (no
   prebuilt object/archive anywhere). → The user needs a full C toolchain +
   headers, and `medaka_rt.c` + `gc.h` must be present. Inherent to the design
   (build shells to clang); acceptable for a developer audience; optionally
   smoothed with a prebuilt `libmedaka_rt`.

6. **Hardcoded `/tmp` scratch paths** — the IR file `/tmp/medaka_build_<out>.ll`
   (`build_cmd.mdk:148`) and GC probe (`:114-116`). Works on mac/linux but assumes
   a writable `/tmp`; namespaced only by output basename (race note already in
   AGENTS.md). Low priority; note for hardening.

7. **`brew --prefix bdw-gc` is macOS-only** (`build_cmd.mdk:99`) — harmless middle
   tier; on Linux success rides on pkg-config or a system `-lgc`.
8. **`-lm` not linked** (surfaced by the D0 spike) — `medaka_rt.c`'s math externs
   (`fmod`/`sqrt`/`sin`/`pow`/…) need explicit `-lm` on Linux; macOS auto-links it
   via libSystem. Trivial; add to every clang link line. No-op on macOS.

## 3. The one genuine unknown — Linux deep-recursion stack — ✅ RESOLVED (D0 spike, 2026-07-04)

The compiler is deeply recursive. macOS gives it a **512MB stack** via
`-Wl,-stack_size,0x20000000` — the exact flag **GNU ld rejects**. Linux's
main-thread stack defaults to ~8MB. The question was **"does the self-hosted
emitter even run on Linux without blowing the stack?"**

**D0 spike result: YES, with a large stack — and the stack IS required.** Driven
in a Docker `ubuntu:24.04` aarch64 container (clang 18.1.3, GNU ld 2.42, libgc
8.2.6), the **full pipeline works end-to-end**: cold-bootstrap from the gzipped
seed → `medaka_emitter` (ELF, 17s) → build the `medaka` CLI (7s) → `medaka run
hello.mdk` prints `3` → `medaka build hello.mdk` produces a native aarch64 ELF
that runs and prints `3`. The recursive emit (seed_emitter re-emitting the whole
compiler graph — the deepest recursion) completed fine.

**The large stack is genuinely required, quantified:** with Linux's default
**8MB** stack (`--ulimit stack=8388608`) the recursive emit **segfaults**
immediately; with **512MB** (`--ulimit stack=536870912`, the honest equivalent of
the macOS link flag) it succeeds. So the fix is not optional — but it is bounded.
On macOS the 512MB is baked into the binary by the link flag; the **Linux
equivalent must provide the stack at runtime**. Options (a D2 decision):
`setrlimit(RLIMIT_STACK)` + self-re-exec; a big-stack `pthread` for the compiler
work (`pthread_attr_setstacksize`, most robust — no re-exec, no wrapper); or a
launcher wrapper that sets `ulimit -s`. Prefer baking it into the binary (pthread
or setrlimit+reexec) so no wrapper/env is needed.

**Two additional Linux link deltas the spike surfaced (both trivial, both
no-ops on macOS):**
- **`-lm` required** — `medaka_rt.c` uses `fmod`/`sqrt`/`sin`/`pow`/… ; macOS
  bundles libm in libSystem (auto-linked), Linux needs explicit `-lm`. Add it to
  every clang link line (`bootstrap_from_seed.sh`, `build_native_medaka.sh`,
  `build_cmd.mdk`'s `clangArgs`).
- **Drop `-Wl,-stack_size` on Linux** (blocker #2) — confirmed: GNU ld rejects it;
  patched out for the spike. Make it Darwin-conditional.

**Bottom line: native build for Linux is CONFIRMED VIABLE for 0.1.0.** No
structural surprise; the remaining work (§5 D1–D4) is mechanical + the bounded
runtime-stack provisioning. Reusable harness committed at
[`dist/linux-spike/`](./dist/linux-spike/) (`sh dist/linux-spike/run.sh spike`).

### 3a. Backtrace — the overflow is 100% the lexer (a TMC-able shape)

A gdb backtrace at the 8MB segfault (build `-O0 -g`, `dist/linux-spike/bt.sh`)
is unambiguous: **the entire deep recursion is the lexer**, 37,000+ frames of the
cycle

```
scan → scanAt → {scanOp | scanUpper | singleOp | handleNewline | afterNl} :: scan
```

crashing in `mdk_alloc` (allocating a cons cell for the token spine). **Zero
parser / typecheck / emit frames** in the deep stack — it is purely the token-list
build, one frame per token, spine live to EOF. This is *exactly* the
"dispatch-into-single-target (`b′`)" TMC shape `WASMGC-TRMC-DESIGN.md` §1
identified (single fixed self-call target `scan`; the cons is built in the
per-kind dispatch leaves) — **the shape the native TMC does not handle and the
WasmGC backend already fixed** (native never needed it because the deep C stack
masked it).

Implication: porting `b′` to the native LLVM emitter would eliminate *this*
overflow entirely (very possibly letting native self-compile fit Linux's default
8MB with no large stack). The genuine tree-depth floor (parser/typecheck on
adversarially nested input) is NOT exercised here — it is the insurance case, not
the observed case. This is what splits the fix cleanly into two tracks (D2).

## 4. Design decisions

- **Lean on the package manager; do NOT chase a zero-dep static binary for
  0.1.0.** Homebrew formula with `depends_on "bdw-gc"` (+ Xcode CLT provides
  clang) makes blockers #4/#5 mostly evaporate on mac. Linux ships a tarball whose
  README lists `clang` + `libgc-dev`. Static-linking libgc is *optional polish*,
  deferred — don't let it block launch.
- **exe-relative stdlib discovery** (blocker #1): add an `executable_path`
  primitive (`_NSGetExecutablePath` on mac, `readlink /proc/self/exe` on Linux),
  and default `MEDAKA_ROOT` to a layout-relative path (e.g. `<exedir>/../lib/medaka`
  or `<exedir>/stdlib`). `MEDAKA_ROOT` stays as an override. This is an
  `add-primitive` job (declare in `stdlib/runtime.mdk`, implement in
  `compiler/eval/eval.mdk` **and** wire the native path). Keystone fix — collapses
  #3 too (default `MEDAKA_EMITTER` to `<exedir>/medaka_emitter`).
- **Platform-conditional linker flag** (blocker #2): detect OS (a `uname`-style
  extern or a build-time constant) and emit the Mach-O flag only on Darwin; on
  Linux use the appropriate mechanism (informed by D0's result — may be a
  big-stack thread rather than a link flag at all).
- **Ship a conventional install layout**: `bin/medaka`, `bin/medaka_emitter`,
  `lib/medaka/stdlib/...`, `lib/medaka/runtime/medaka_rt.c` (+ optionally a
  prebuilt `libmedaka_rt`), discoverable exe-relative.

## 5. Phased plan

- **D0 — Linux build spike** (§3). ✅ **DONE 2026-07-04 — GREEN.** Native build
  confirmed viable on Linux; the deep-recursion stack is required but bounded.
- **D1 — exe-relative stdlib discovery. ✅ DONE 2026-07-04 (`1ce178b6`).** Added
  the `executablePath : Unit -> <Env> String` extern (mac `_NSGetExecutablePath`,
  Linux `readlink /proc/self/exe`, both realpath-resolved) + defaulted
  `MEDAKA_ROOT`/`MEDAKA_EMITTER` exe-relative in `medaka_cli.mdk`/`build_cmd.mdk`
  (explicit env still wins). A `medaka` copied outside the repo `run`/`check`/`build`s
  with no env vars; in-repo dev build unchanged. NOTE: the file/env/exec extern
  family is native-only (unbound under `medaka run`'s pure interpreter) — no
  `eval.mdk` arm needed since `medaka_cli.mdk` is always compiled natively.
- **D2 — platform link/stack handling (TWO TRACKS, decoupled).** Make `medaka
  build` (and the compiler's own build) work on Linux; keep macOS byte-identical.
  Measured need: ~32MB @ -O2 / ~128MB @ -O0 (8MB default segfaults; -O2 frame
  shrink helps ~4× but does NOT clear 8MB). Decided approach (both, on separate
  timelines — the TMC track does NOT retire the stack track, so the release is not
  serialized behind it):
  - **Track 1 (0.1.0 baseline): big-stack `pthread`. ✅ DONE 2026-07-04
    (`595b303e` + merge `40de5955`; seed re-mint `f5243120`).** The emitted entry
    `@main` → `@mdk_program_main`; `runtime/medaka_rt.c` now owns `int main`, which
    spawns a **256MB-stack worker thread via `GC_pthread_create`** (`GC_THREADS` +
    thread-aware Boehm so the worker's stack is a scanned GC root — a raw
    `pthread_create` would silently corrupt the heap) running `mdk_program_main`.
    Dropped `-Wl,-stack_size` from all six link sites (build_cmd + 5 build scripts);
    added `-pthread` + `-lm`. **Verified: Linux spike PASSES at the default 8MB
    stack** (the compiler self-provisions), macOS byte-identical (`diff_compiler_llvm`
    194/0, `_build` 53/0), fixpoint C3a/C3b YES, cold `bootstrap_from_seed` C3a PASS.
    Correctness-complete for ALL recursion shapes incl. tree-depth.
  - **Track 2 (fast-follow, own workstream): port WasmGC `b′` dispatch-TMC to
    native.** The backtrace (§3a) proves the observed overflow is 100% the
    `b′`-shaped lexer token-spine — one shape, one file (`lexer.mdk`), already
    designed (`WASMGC-TRMC-DESIGN.md`). Fixes the observed overflow at the root,
    closes a native↔wasm parity gap, hardens against pathologically long *lists*
    (which blow even a 256MB stack), reduces GC/stack pressure. Optimization +
    robustness, not the stack fix.
  - **Track 3 (capstone, aligns with error-quality): recursion-depth guard.** A
    clean `expression nesting too deep` diagnostic instead of a segfault on
    adversarial deep nesting — the piece that actually makes "never crash on any
    input" true (Track 1 + Track 3 together; Track 2 removes the list dimension).
- **D3 — install layout + package manager.** Homebrew formula (`depends_on
  bdw-gc`); Linux tarball + README deps; clang-missing UX (actionable error).
- **D4 — release CI matrix.** Tagged CI builds mac (arm64; x86_64 if cheap) +
  Linux (x86_64; arm64 if cheap) artifacts + Homebrew bottle. This is
  `RELEASE-0.1.0-PLAN.md` §W8's delivery vehicle.
- **D5 (optional polish, post-0.1.0-OK)** — vendor + static-link libgc for a
  self-contained binary; prebuilt `libmedaka_rt` so clang doesn't recompile the
  runtime each build; `/tmp` scratch hardening.

## 6. Cross-checks

- Any change to `build_cmd.mdk` / the runtime / the emitter graph that perturbs
  emitted IR forces a **seed re-mint + fixpoint re-validation** (AGENTS.md). The
  exe-path primitive touches `eval.mdk` + `stdlib/runtime.mdk` + the native path →
  expect a re-mint; batch it (`feedback_defer_seed_remint`).
- The exe-path extern is **also** what an interpreter-only / self-contained-`run`
  distribution needs — do it once, both funnels benefit.
- Keep every golden byte-identical on macOS through D1–D3 (the platform
  conditional must be a no-op on Darwin).
