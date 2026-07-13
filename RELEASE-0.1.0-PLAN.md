# RELEASE-0.1.0-PLAN.md — the road to a public 0.1.0 preview

**Status:** OPEN — live roadmap hub for the 0.1.0 public preview push. What
remains: see the W1-W9 workstream table below; W6 (License) is now DONE, W7
(`KNOWN-GAPS.md`) is still genuinely not started.

> **North star for the current phase.** Everything internal is mature — Medaka
> self-hosts, has two backends, a real type system, a stdlib, LSP, formatter,
> linter, doctests. The distance to a public release is almost entirely
> **outward-facing surface**: distribution, a front door, human docs, and
> release hygiene. This doc is the hub for that push. PLAN.md's Workstreams table
> links here; detailed technical design for the meatiest workstream (native
> binary distribution) lives in [`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md).

Owning memory: `project_release_0_1_0` (to be written). Companion docs:
[`PLAYGROUND-DESIGN.md`](./PLAYGROUND-DESIGN.md) + [`PLAYGROUND-EDITOR-DESIGN.md`](./PLAYGROUND-EDITOR-DESIGN.md)
(the front door), [`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md) (the download),
[`compiler/ERROR-QUALITY.md`](./compiler/ERROR-QUALITY.md) (diagnostics, freeze-for-preview).

---

## 0. What 0.1.0 *is*

A **very preliminary public preview** — the point where Val is comfortable
putting Medaka in front of strangers (HN/Reddit-scale, people who *will* try to
break it), not a production release. A preview is *allowed* holes; it is **not**
allowed *surprising* holes. The bar is credibility, not completeness.

**The testable north-star statement:**

> A stranger can go from a link to a **working, formatted, type-checked, running**
> Medaka program in **under ten minutes**, and **every hole they hit is one we
> already told them about.**

That reframes the whole checklist into one end-to-end path, and it makes the two
big scoping decisions fall out naturally (below).

## 1. The two structural decisions (settled)

**Distribution is a funnel, not one artifact.** The playground and the download
serve different users at different funnel stages, and — critically — the
**playground cannot do practical IO** (it runs the WasmGC backend inside the
browser sandbox: no filesystem, no network). So:

1. **Playground = the front door.** Zero-install, sandboxed, pure + console IO.
   "Try the language in 60 seconds." Already largely built (`playground/`,
   Stages 0–4 done). Front door of the launch. Ships regardless — even alone it
   is a credible preview and is our risk buffer if the download slips.
2. **Native binary = the "now do something real" path.** A downloadable
   `medaka` for macOS + Linux that supports `medaka build` (native codegen with
   full fs/net IO). This is what makes Medaka a *language you'd actually use*,
   not just evaluate in a browser. **Decided in-scope for 0.1.0** (Val's call:
   an interpreter-/playground-only preview is too lackluster — no practical IO).
   Technical design + blocker map: [`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md).

**Interpreter-only distribution was considered and rejected** — the tree-walk
interpreter (`medaka run`) has no fs/net, so nothing practical can be written
with it. See the side-quest in §3 (implement fs/net in the interpreter) — cheap
value on the same theme, but *not* the distribution story.

## 2. Floor vs ceiling

Organize the launch as a **hard floor** (blocks 0.1.0) and a **soft ceiling**
(ship if the difficulty is reasonable; the difficulty of the one uncertain item
is being spiked — see `DISTRIBUTION-DESIGN.md`).

**FLOOR — must ship, blocks 0.1.0:**
- Playground polished into a genuine front door (§W2).
- Human-written quickstart / language overview (§W3).
- Stdlib reference docs (§W4).
- Public repo, curated (§W5), with a **LICENSE** (§W6).
- `KNOWN-GAPS.md` — the honest public gaps list (§W7).
- `medaka --version` (§W8).

Even if native build slips, the floor alone is a legitimate, honest preview
(playground front door + docs + honest gaps).

**CEILING — ship for 0.1.0 if tractable (Val wants it; likely tractable with AI
assistance — the one real unknown is the Linux deep-recursion stack, spiked
first):**
- Native `medaka` binary + `build` for macOS + Linux, distributed via package
  manager (§W1 / `DISTRIBUTION-DESIGN.md`).
- Release CI matrix that *produces* those binaries (§W8).
- Editor extension published or one-step installable (§W9) — near-free
  credibility multiplier given the LSP already exists.

---

## 3. Workstreams

Each has a status and an owning location. Statuses roll up into PLAN.md's
Workstreams table.

### W1 — Native binary distribution (macOS + Linux) — 🟢 CEILING, headline; D0 spike GREEN

Ship a relocatable `medaka` (+ `medaka_emitter`) that a stranger can install and
use `medaka build` with. Full technical design, the repo-dependency blocker map,
and the phased plan are in **[`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md)**.

**✅ D0 Linux spike DONE (2026-07-04) — native build CONFIRMED VIABLE on Linux.**
The one genuine unknown (does the deeply-recursive compiler survive Linux's small
stack?) is resolved: in a Docker `ubuntu:24.04` aarch64 container, the full
pipeline works end-to-end (seed bootstrap → CLI → `medaka run` → `medaka build` →
native ELF prints `3`). The deep-recursion stack is **required but bounded** (8MB
segfaults, 512MB works → provide at runtime via pthread/setrlimit). Two other
Linux deltas, both trivial: add `-lm`, make `-Wl,-stack_size` Darwin-conditional.
No structural surprise — the rest is the mechanical D1–D4 packaging.

Summary of what's known today (dependency audit done):
- The compiler is already **cross-platform in the parts that matter** — emitted
  LLVM IR carries no target triple, `runtime/medaka_rt.c` is POSIX-clean.
- The work is all in the **packaging + discovery seam**, not codegen. Concrete
  blockers: exe-relative stdlib discovery (no exe-path extern exists today), the
  Mach-O-only stack-size linker flag (breaks on Linux), the two-binary
  `MEDAKA_EMITTER` ritual, and libgc as a system dep.
- **De-scoper:** lean on the package manager (Homebrew `depends_on "bdw-gc"`;
  Linux tarball documents clang + libgc) rather than chasing a zero-dependency
  static binary. `medaka build` fundamentally shells to `clang`, so "you need a C
  toolchain" is an inherent, acceptable ask for a *developer* audience.
- **The one genuine unknown → spike first:** does the deeply-recursive
  self-hosted compiler even run on Linux (macOS gives it a 512MB stack via a flag
  GNU ld rejects)? A CI/container Linux-build probe answers this cheaply and is
  the first task in `DISTRIBUTION-DESIGN.md`.

### W2 — Playground as the front door — 🟢 built, needs polish

The playground already runs the compiler fully client-side (WasmGC, server-free;
`playground/`, Stages 0–4 done per [`PLAYGROUND-DESIGN.md`](./PLAYGROUND-DESIGN.md)).
For 0.1.0 it must become a *nice* front door, not just a tech demo. Polish
backlog (detail → `PLAYGROUND-DESIGN.md` / `PLAYGROUND-EDITOR-DESIGN.md`):
- ✅ **Real editor — CodeMirror 6 (S1 highlighting + S2 inline squiggles) DONE 2026-07-04**
  (`d5306c81`); Playwright e2e harness `playground/e2e/` (`d4dca8da`). *(Deferred: S3 hover /
  S4 autocomplete — the two stateless wasm entries.)*
- ✅ **Visual / layout polish — DONE 2026-07-06 (`13e29e90`).** Mockup-first as planned:
  three static directions as an Artifact, Val picked "quiet column + funnel strip"
  (centered ~1040px column, fish wordmark header + placeholder Quickstart/Stdlib/GitHub
  links, dismissible "get the native compiler →" funnel strip, unified console replacing the
  stdout/stderr/problems trio). Verified via the updated `playground/e2e/` harness (21 checks)
  + screenshot review. Palette kept: bg `#0b0e14`/`#0d1117`, accent `#e2b96f`.
- ✅ Shareable permalinks — DONE 2026-07-06 (`13e29e90`): Share button encodes the program as
  base64url in `#code=`, loads from hash on init, copies the URL to clipboard.
- ✅ Examples/presets dropdown — DONE-minimal 2026-07-06 (`13e29e90`): 3 embedded examples
  (hello / shapes / pipeline), each e2e-verified to run. Grow it from §W-showcase programs
  when those exist.
- ✅ First-class error rendering — DONE as CM6 inline squiggles + gutter markers (S2); the
  problems pane is kept as a list alongside.
- Mandatory browser-support feature-detect + banner (**needs current Chrome/Firefox** —
  Safari + older engines lag the finalized WasmGC encoding; empirically verified).
- Nice-to-have: friendlier worker/asset load-failure message (currently a bare
  `compiler-worker error: undefined` when the server is gone — should say "is the server
  running? try reloading").
- Hosting: static assets, no server eval (sandboxed by construction — a real advantage).

### W3 — Quickstart / language overview docs — 🔴 FLOOR, **Val-authored**

A linear "Medaka in 20 minutes" for a *human* newcomer. **Written by Val** to
avoid AI-tone problems. This is the **serialization bottleneck of the whole
launch** (only Val can write it) → start early and in parallel, not last. Note:
AGENTS.md is superb *routing* but is the wrong genre — a newcomer needs the
inverse (linear tutorial), don't try to derive one from the other.

### W4 — Standard library reference docs — 🔴 FLOOR, agent-generated OK

Generated reference for the stdlib modules. `medaka doc` (doc-comment → Markdown
extractor) already exists — use it. Agent-generated is acceptable for 0.1.0;
quality bar is "complete and correct," not "beautifully written."

### W5 — Public repo (curated downstream export) — 🔴 FLOOR

A **separate public GitHub repo** that is a *curated snapshot*, not a fork where
work happens. Development continues in the private repo; the public repo is a
**downstream publish target** (push curated snapshots to it) to avoid maintaining
two active repos.
- **Public gets:** the language + stdlib + examples + human docs + `KNOWN-GAPS.md`
  + LICENSE + release binaries.
- **Public does NOT get:** PLAN.md / PLAN-ARCHIVE.md / the design-doc thicket /
  AGENTS.md-style agent routing. Decide the sync tooling (a scripted export/mirror).

### W6 — License — ✅ DONE — `LICENSE` (Apache-2.0) exists at repo root (`d94bae5f`)

Val wanted "MIT space" — maximal freedom to use/tinker, no copyleft. Shipped as
plain **Apache-2.0** (not the originally-recommended MIT-or-dual — Val's final
pick landed on Apache-2.0 alone, still permissive with an explicit patent grant).

### W7 — `KNOWN-GAPS.md` (public, human-facing) — 🔴 FLOOR

One honest public page of "what doesn't work yet." Converts "this is broken" into
"this is a known preview limitation." Source material already exists internally
(`compiler/EMITTER-GAPS.md`, PLAN.md "Known parser gaps", the parked items) —
this is a *curation + rewrite-for-humans* task, not new investigation.

### W8 — Release hygiene — 🟡 SHOULD (some floor)

Cheap individually, but their absence reads as amateur:
- **`medaka --version` / `medaka version`** (floor) — wire to the release tag; bug
  reports are useless without it.
- **Release CI matrix** (floor if W1 ships) — mac + linux artifacts built by
  *tagged CI*, not a laptop. Same machinery produces the Homebrew artifact. This
  is the delivery vehicle for W1.
- **Crash → report path** — panics are non-catchable by design; a crash should
  print "internal error; please report at <url> with this input," not a raw
  abort. Early users *will* hit the residual parser/emitter gaps.

### W9 — Editor extension — 🟡 SHOULD, near-free credibility

A full native LSP already exists. Publishing a `.vsix` (or marketplace listing)
gives "install the binary, install the extension, get red squiggles + hover
types" for near-zero incremental work — an outsized credibility signal. Even a
`.vsix` on the release page beats nothing. See `project_vscode_ext_stale_install`.

### W-showcase — Example programs — 🟡 SHOULD (doubles as marketing + fixtures)

A handful of real, runnable programs (the SQLite reader, a parser-combinator,
JSON) that prove Medaka is a real language. Triple duty: marketing, playground
presets (§W2), regression fixtures.

### W-errors — Error-message quality: FREEZE for preview — 🟢 good enough

Already at a defensible bar (corpus ~11.9/14; see `project_error_quality_workstream`).
**Freeze as "good enough for preview"** — further work is ongoing-not-blocking.
One cheap exception worth landing because a first-hour user notices it: the four
non-exhaustive-match *warnings* still print with no `file:L:C:` prefix in the
human CLI text (the JSON range is already real) — add the prefix in the warning
renderer. Tracked in PLAN.md's error-quality status.

---

## 4. Side quest (not a blocker): fs/net in the interpreter

fs/net are currently **native-only** (implemented only in the C runtime, not in
`eval.mdk`). Val believes there's no fundamental blocker to implementing them in
the tree-walk interpreter (the `add-primitive` path — implement the eval-side
externs). Doing so is a **strict improvement independent of everything above**:
it makes `medaka run` and the downloadable experience practical *even on machines
without clang*, and gives a self-contained interpreter fallback. Cheap, valuable,
**not on the launch critical path** — pick it up opportunistically. (⚠️ "probably
not fundamental" is unverified — the first step is confirming there's no
interpreter-level reason fs/net can't be evented, per the debug-pipeline habit of
reproducing before trusting.)

---

## 5. Sequencing

1. **Spike the Linux native build first** (`DISTRIBUTION-DESIGN.md` §first-task) —
   it's the only high-uncertainty item; its result reorders everything.
2. In parallel, **Val starts the quickstart (W3)** — the human serialization point.
3. Mechanical packaging (W1 exe-path discovery, two-binary smoothing, Homebrew,
   CI matrix) — low-surprise, fast with AI assistance.
4. Playground polish (W2) + public repo + LICENSE + KNOWN-GAPS (W5/W6/W7) — can
   proceed independently of the native-build spike.
5. Release hygiene (W8) + editor extension (W9) + showcase programs.

**Open framing question for Val (does not block starting):** confirm the audience
bar — "HN/Reddit strangers who'll try to break it" (assumed here) vs "a dozen
personally-invited people I can hand-hold." It shifts how hard the floor items
need to be, but not *what* they are.
