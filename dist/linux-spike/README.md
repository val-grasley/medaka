# dist/linux-spike — Linux native-build harness

A Docker harness for driving the native-binary distribution workstream
([`../../DISTRIBUTION-DESIGN.md`](../../DISTRIBUTION-DESIGN.md)) against a Linux
target from a macOS host. Built and validated during the D0 spike (2026-07-04).

## Quick start

```sh
sh dist/linux-spike/run.sh spike        # full end-to-end viability check (D0)
sh dist/linux-spike/run.sh experiment   # stack-size threshold sweep
sh dist/linux-spike/run.sh bt           # gdb backtrace at the overflow
```

`run.sh` snapshots the **current working tree** (uncommitted edits included) into
`repo.tar`, builds the image, and runs the chosen script. So you can edit source
(e.g. `compiler/frontend/lexer.mdk` for the Track-2 TMC port, or the build scripts
for the Track-1 stack fix) and re-run immediately. Requires Docker; host may be
macOS or Linux (image is `ubuntu:24.04`, native on arm64).

## Files

| File | What it does |
|------|--------------|
| `Dockerfile` | `ubuntu:24.04` + clang, lld, libgc-dev, pkg-config, gdb, binutils. |
| `run.sh` | Host driver: tar the tree → `docker build` → `docker run <script>`. |
| `spike.sh` | Applies the 3 Linux patches (drop Mach-O `-Wl,-stack_size`; add `-lm`; …) then cold-bootstraps from seed → builds the `medaka` CLI → `medaka run` + `medaka build` hello.mdk. The D0 green-path proof. |
| `experiment.sh` | Builds the seed emitter at `-O0` and `-O2`, sweeps `ulimit -s` (8→256MB) to find the stack threshold for the self-compile emit. |
| `bt.sh` | Builds `-O0 -g`, runs under gdb at 8MB, prints the innermost frames + a function histogram of the overflow. |

## What the harness established (D0, 2026-07-04)

- **Native build works on Linux** end-to-end (seed → CLI → `medaka build` → ELF
  that runs). No structural blocker.
- **Three Linux link/build deltas**, all handled by the patches in `spike.sh`:
  drop the Mach-O `-Wl,-stack_size` flag (GNU ld rejects it); add `-lm`
  (`medaka_rt.c` math externs; macOS auto-links via libSystem); rely on the
  package manager for libgc/clang.
- **The deep-recursion stack is real but bounded:** self-compile emit needs
  ~32MB @ `-O2` / ~128MB @ `-O0` (Linux's 8MB default segfaults; `-O2` frame
  shrink helps ~4× but does not clear 8MB).
- **The overflow is 100% the lexer** (`bt.sh`): 37k+ frames of
  `scan → scanAt → {scanOp|scanUpper|singleOp|handleNewline|afterNl} :: scan`,
  crashing in `mdk_alloc` (token-spine cons) — the WasmGC `b′`
  dispatch-into-single-target TMC shape native lacks. See `DISTRIBUTION-DESIGN.md`
  §3a and D2 (the two-track stack decision).

## Note on `repo.tar`

`run.sh` regenerates `repo.tar` on every run; it is a build artifact and should
not be committed (add to `.gitignore` if it shows up in `git status`).
