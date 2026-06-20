# PLAYGROUND-DESIGN.md — in-browser Medaka playground, with the server written in Medaka

> **Status: EXPLORATORY DESIGN (decision-ready, not yet implemented).** No code is
> proposed for landing here; §9 (design forks) is the list a human must rule on
> before any build starts. Companion to `selfhost/WASMGC-DESIGN.md` (the WasmGC
> backend this rides on), `ASYNC-DESIGN.md` (the locked async contract the server
> needs), `selfhost/RUNTIME-DESIGN.md` §6a (the capability-interface/extern
> disposition model), and `CAPABILITY-PLATFORM.md` (the product vision this is an
> instance of — §388 there already names "a web playground" as the highest-leverage
> next step past v1).

---

## 0. Verified starting state

Everything below was confirmed against the actual tree (worktree base `24828a8`,
local main merged at step 0). One note on the WasmGC status, and one correction to a
stale engine caveat.

**WasmGC MVP status — MET (compute + print, real-prelude, multi-module).** The
`medaka build --target wasm <prog>` MVP compiles real-prelude, multi-module
*compute + print* programs to WasmGC that run **byte-identically to `medaka build`**.
Slices W5 (dispatch/dict-passing), W6 (strings), W7 (collections), and W9 (multi-
module / real programs) land this, riding the real `medaka build` front end through
`selfhost/entries/wasm_emit_modules_main.mdk` (loader → `elaborateModules` with the
REAL `core.mdk` prelude → `lowerProgramEmit` → DCE → `emitProgram`). *Caveat for the
reader: the committed `selfhost/WASMGC-DESIGN.md` §9 at this base still marks only
W1–W4 DONE and reads "not yet implemented" in its header — that doc is being updated
by a parallel effort to reflect the met MVP; trust the MVP-met status, not the stale
slice ticks.* This plan therefore treats the client target as **available**, not a
blocker — the playground's gating prerequisite (Stage 0, §6) is satisfied.

**CORRECTION — local engine reality is better than a stale caveat implies.** The
inherited note says "the drift that made Node 20 fail this session." Per `WASMGC-DESIGN.md`
§8/§11, **Node ≥20.10 runs WasmGC unflagged** (V8 13.6); the local node is **v20.11.1**,
which is fine. `wasm-tools` **is installed locally** (`/opt/homebrew/bin/wasm-tools`) —
the §442 "not installed locally, MVP blocked" caveat is stale. The real drift caveat is
narrower: **Wasmtime <27 silently rejects** the module and needs `-W gc -W tail-call`;
browser-side, the finalized Wasm 3.0 GC encoding (shipped 2025-09-17) needs **current
Chrome/Firefox**, not the *engine* being the blocker the framing suggested.

**VERIFIED facts the plan rests on (checked directly):**
- `stdlib/runtime.mdk` has `runCommand` (`<Exec>`), `readFile`/`writeFile`
  (`<FileRead>`/`<FileWrite>`), `readLine`/`readAll`/`readExactly` (`<Stdin>`),
  `args`/`getEnv` (`<Env>`), `wallTimeSec` (`<Clock>`), etc. — and **ZERO socket /
  network externs** (grep for `socket|listen|accept|recv|send|bind|connect|Net` over
  `runtime.mdk` returns nothing). The server forces a brand-new extern surface.
- **`<Net>` already exists in both typecheckers** as a **Prefix-classified** builtin
  effect label (`lib/typecheck.ml`: `"Net", PPrefix None, ESecurity`; mirrored in
  `selfhost/types/typecheck.mdk`: `("Net", PPrefix None)`), alongside `FileRead`/
  `FileWrite`. Prefix = it carries a string domain param (a `<Net "host:port">` pin),
  exactly the shape the capability-platform wants. **No extern binds to it today.**
- The full builtin label set: `Stdout Stdin Stderr FileRead FileWrite Env Exec Panic
  IO Rand Clock Mut Net`.
- `medaka check --json` exists in `selfhost/driver/medaka_cli.mdk` (`runCheckJsonCmd`,
  mirrors `bin/main.ml`'s `analyze_project → all_diagnostics_to_json`) — diagnostics
  are already machine-readable for the editor UI.
- The LLVM build driver (`lib/build_cmd.ml` + native dual `selfhost/driver/build_cmd.mdk`)
  runs the emitter as a **subprocess capturing stdout** (`medaka run <emitter-entry>
  <runtime> <core> <entry> <roots…> > out.ll`), then shells out to `clang`. No
  `--target` flag exists anywhere yet. `ASYNC-DESIGN.md` is **DESIGN LOCKED** with a
  degenerate-sequential v1 scheduler in pure Medaka, zero backend coupling.

---

## 1. Goal + architecture (the compile-server / run-in-sandbox split)

**Goal.** A shareable, install-free web page where a visitor edits Medaka source, hits
Run, and sees output — and where the playground itself is a live demonstration of the
capability-effects wedge: *untrusted user code never runs on our server; it runs
sandboxed in the visitor's own browser.*

**The architecture, in prose:**

```
  Browser (visitor's V8/SpiderMonkey sandbox)        Our host (one machine)
  ┌───────────────────────────────────────┐          ┌─────────────────────────────┐
  │  static page: editor + console + Run   │          │  medaka-server  (NATIVE bin, │
  │                                        │  HTTP    │  written in Medaka)          │
  │  POST /compile  { source }  ───────────┼─────────▶│   router → spawn compiler    │
  │                                        │          │   subprocess (`medaka build  │
  │  ◀── { wasm:bytes }  or  { errors:[…]} │◀─────────┤    --target wasm`) on a temp │
  │                                        │          │   file → read .wasm / errors │
  │  WebAssembly.instantiate(wasm, glue)   │          └─────────────────────────────┘
  │   → (start) runs → mdk_write_byte ─────┼─▶ console        compiles only;
  │     bytes → UTF-8 → console pane       │          never *runs* user code.
  └───────────────────────────────────────┘
```

**Two distinct Medaka programs, two distinct targets — state this clearly:**
- **The server** runs **NATIVE** (LLVM backend). It is long-running, does network IO,
  and spawns the compiler. It is *trusted* (it's our code). It must **never** be the
  WasmGC target.
- **The user program** compiles to **WasmGC** and runs in the *visitor's* browser
  sandbox. It is *untrusted* — and that's exactly why WasmGC is the right target: the
  browser already gives a memory sandbox + capability control by host-import omission
  (don't supply a `fetch`/file import → the module physically cannot reach the network
  or disk). The user program gets only `mdk_write_byte` (stdout) and `mdk_write_err_byte`
  (stderr). **Compute + print, nothing else.**

**Why this is the wedge demo (cross-ref `CAPABILITY-PLATFORM.md` §7c).** The platform
doc's "wow demo" is *compile-time* capability rejection on the tree-walker. The
playground is its web-native successor: the *same* effect-row machinery decides what
host imports a module is even *offered*, and the browser sandbox is the §397 "coarse
fence" backstop made literal. A playground that runs a `<Net>`-using user program
simply wouldn't be *granted* a network import — a live, in-browser instance of
"effects make multi-target honest" (`RUNTIME-DESIGN.md` §6a).

---

## 2. Half A — client-side delivery (small, language-side)

### 2.1 `medaka build --target wasm` CLI (DOESN'T EXIST — design)

Today the WasmGC emitter runs only via gate entry binaries
(`selfhost/entries/wasm_emit_modules_main.mdk`, invoked as a subprocess capturing WAT).
Wire it into the build driver as a real subcommand, **paralleling the LLVM path exactly**.

The LLVM path (verified, `lib/build_cmd.ml` lines ~219–275, native dual
`selfhost/driver/build_cmd.mdk`):
```
1. medaka check <input>                                              # G1 typecheck gate
2. medaka run selfhost/entries/llvm_emit_modules_main.mdk \
     <runtime.mdk> <core.mdk> <input> <input-dir> <selfhost> <stdlib>  > out.ll   # capture stdout
3. clang -O2 <gc-flags> out.ll runtime/medaka_rt.c <gc-libs> -o <bin>
```

The **`--target wasm`** path, structurally identical (already sketched in
`WASMGC-DESIGN.md` §7 line 324):
```
1. medaka check <input>                                              # G1 gate, UNCHANGED
2. medaka run selfhost/entries/wasm_emit_modules_main.mdk \
     <runtime.mdk> <core.mdk> <input> <roots…>                       > out.wat   # capture stdout
3. wasm-tools parse    out.wat  -o out.wasm                          # the clang analogue (assemble)
   wasm-tools validate out.wasm                                      # GC validation on by default
```

Concrete wiring, both drivers (mirror every LLVM change across the OCaml `lib/build_cmd.ml`
and the native `selfhost/driver/build_cmd.mdk` — they are duals):
- **Arg parse.** Extend `parseBuildArgs` (`medaka_cli.mdk` ~line 445) to accept
  `--target <name>` (default `native`), carry a target tag into `runBuildCmd`.
- **Backend dispatch.** `runBuild` takes the target; on `wasm` it swaps the emitter
  entry (`wasm_emit_modules_main.mdk`), the output extension (`.wat`→`.wasm`), and the
  assemble step (`wasm-tools parse|validate` instead of `clang`). The subprocess-capture
  harness (`run_capture` in OCaml; the native `runCommand`-based dual) is **reused
  unchanged** — both targets are "run the emitter, capture stdout, assemble."
- **Repo-root marker.** Both drivers locate the repo root off
  `selfhost/entries/llvm_emit_modules_main.mdk`; the wasm path needs its sibling
  `wasm_emit_modules_main.mdk` reachable from the same root — no second marker needed,
  same directory.
- **Toolchain assertion.** `wasm-tools` is an external dependency (like `clang`). Probe
  it up front and emit a clear error if absent. Wasmtime, if used for a server-side
  smoke-validate, needs `-W gc -W tail-call` and ≥27.

`wasm_emit.mdk` is **outside the self-host fixpoint** (the compiler doesn't emit WasmGC
for itself), so this CLI work is additive and fixpoint-safe — no seed re-mint.

### 2.2 Browser runtime glue (mature `test/wasm/run.js` into a browser module)

`test/wasm/run.js` (verified) is already the right shape — it supplies host imports and
accumulates raw bytes:
```js
const imports = { env: {
  mdk_write_byte:     (b) => { acc.push(b & 0xff); },   // stdout
  mdk_write_err_byte: (b) => { eacc.push(b & 0xff); },  // stderr
} };
WebAssembly.instantiate(bytes, imports).then(() => { /* UTF-8 decode acc/eacc */ });
```
The module produces **all** its own output bytes (real `intToString`/string codegen +
the byte-write print runtime in `selfhost/backend/wasm_preamble.mdk`); the runner only
decodes. **`(start $__init)` drives instantiation** — the value-binding prologue + `main`
run *during* `WebAssembly.instantiate`, so there is **no named entry to call**; instantiate
== run. (Browser caveat: a long-running or infinite-loop user program blocks the main
thread; the production glue should instantiate inside a **Web Worker** so the page stays
responsive and the worker can be terminated on a CPU-time budget — see §9d.)

Browser maturation of `run.js`:
- Re-target Node `fs.readFileSync` → `fetch(wasmUrl)` / the bytes from `POST /compile`.
- `mdk_write_byte`/`mdk_write_err_byte` → push into a `TextDecoder('utf-8')` stream
  feeding the stdout/stderr console panes (decode incrementally so partial multi-byte
  codepoints don't garble).
- Run inside a Worker; surface `instantiate failed` traps (Medaka `panic`/`exit` lower
  to a host `mdk_panic` import then `unreachable`/trap per `WASMGC-DESIGN.md` §6) as a
  clean "program panicked" console line.
- Engine gate: feature-detect WasmGC (`WebAssembly.validate` of a tiny GC module) and
  show a "needs current Chrome/Firefox" banner otherwise.

### 2.3 Diagnostics → editor UI

`check --json` already emits structured diagnostics (`runCheckJsonCmd`). The server runs
the G1 `check` gate before emit anyway; on failure return the JSON diagnostics array
(file/line/col/message) and surface them as editor squiggles + a problems pane. No new
compiler work — just plumb the existing JSON through `POST /compile`'s error response.

---

## 3. Half B — the Medaka server (the meaty part)

The server is the forcing function for real IO + (eventually) async. It runs native and
is small enough to **dogfood**: HTTP parsing in Medaka, only sockets as new externs.

### 3.1 Components

| Component | Responsibility | Built from |
|---|---|---|
| **Socket listener** | bind a TCP port, accept connections | NEW `<Net>` externs (§3.2) |
| **HTTP/1.1 parser** | parse request line + headers + body off a recv'd byte buffer | **pure Medaka** (dogfood; see §9b) |
| **Request router** | dispatch `POST /compile`, `GET /` (static page), 404 | pure Medaka |
| **Compile driver** | write source to a temp file, spawn `medaka build --target wasm`, read `.wasm` or stderr/JSON | existing `runCommand` (`<Exec>`) + `readFile`/`writeFile` |
| **Response writer** | serialize HTTP/1.1 response (status, headers, `.wasm` body or JSON errors) | pure Medaka + socket `send` |

The compile driver is the elegant part: it **already works today** — `runCommand`
(`<Exec>`) spawns the subprocess, `writeFile`/`readFile` (`<FileWrite>`/`<FileRead>`)
move source/artifact. The server reuses the exact subprocess-capture pattern the build
driver itself uses. **The only genuinely new native surface is the socket layer.**

### 3.2 The new native socket extern surface (under `<Net>`)

Per `RUNTIME-DESIGN.md` §6a (capability-interface model: same effect-labeled extern, C
function on native / host import on WASM) and the decided **runtime-is-C-not-Rust**
stance (`feedback_runtime_language_c_not_rust`: C = thin syscall shims, protocol logic in
Medaka), the sockets are **`LEAF`-disposition thin C shims** in `runtime/medaka_rt.c` +
OCaml impls in `lib/eval.ml`. **No bound C HTTP library** — HTTP is parsed in Medaka.

Proposed **BSD-socket-shaped** surface (recommended shape — see fork §9c), all under the
existing **`<Net>`** label, two-site add (`runtime.mdk` signature + `eval.ml`/`medaka_rt.c`
impl), returning `Result String _` so errno surfaces as a value (Result-canonical, no
exceptions):

```
-- A socket is an opaque OS file descriptor carried as Int (LEAF: no value reflection).
extern netListen  : String -> Int -> <Net "host"> Result String Int
  -- bind+listen on host:port; returns a listening fd.  host pins the <Net "host"> domain.
extern netAccept  : Int -> <Net> Result String Int
  -- block until a client connects; returns a connected fd.
extern netRecv    : Int -> Int -> <Net> Result String String
  -- read up to N bytes (UTF-8 String == byte buffer, per the String=UTF-8-bytes rep).
extern netSend    : Int -> String -> <Net> Result String Int
  -- write the bytes; returns count sent.
extern netClose   : Int -> <Net> Result String Unit
```

Notes:
- **Blocking by design for v1** (matches `ASYNC-DESIGN.md` §4: v1 IO externs block).
  The reactor stage (§4c) adds **non-blocking variants** the scheduler can poll
  (`netAcceptNB`/`netRecvNB` returning `WouldBlock`), *added alongside* — never
  replacing — so the locked async contract stays behavior-preserving.
- **`<Net "host">` Prefix pin** is already supported by the typechecker's PPrefix domain
  — `netListen` can carry the bound host, giving the platform a `Fetch "idp.example.com"`-
  style pinned-domain story for free.
- **WasmGC disposition:** these externs would bind to **host imports** on a WASI/edge
  target (per §6a's "C function on native, host import on WASM") — but they are
  **native-only for the playground** (the server is native; the user program never gets
  them). So the WasmGC binding is out of scope here (deferred to the edge-platform work).

### 3.3 Server effect row (verified manifest)

The server's `main` would carry, honestly:
```
main : <Net, Exec, FileRead, FileWrite, Stdout, Stderr, Clock, Env, Panic> Unit
```
- `<Net>` — sockets. `<Exec>` — spawn the compiler. `<FileRead>/<FileWrite>` — temp
  source + `.wasm` artifact. `<Stdout>/<Stderr>` — server logging. `<Clock>` — timeouts.
  `<Env>` — config (port, repo root). This row is the server's *capability manifest* —
  and it is conspicuously **maximal**, which is the whole point of §1's split: the
  **trusted** server holds broad authority; the **untrusted** user program holds none.

---

## 4. Async-runtime spectrum + staged recommendation

Grounded in `ASYNC-DESIGN.md` (DESIGN LOCKED): v1 `Async a` is a value-level monad,
implemented as a **degenerate sequential scheduler in pure Medaka** (D3/D6), deliberately
so the scheduler can later be swapped for a real reactor **with no observable-behavior
change**. A real concurrent server **is exactly that deferred swap** (§5 of ASYNC-DESIGN).

| Stage | What it is | What it needs | Cost | Concurrency |
|---|---|---|---|---|
| **(a) Blocking sequential** | one request fully handled before `accept`ing the next | the §3.2 blocking sockets + HTTP-in-Medaka. **NO async runtime at all.** | smallest; dogfoods socket IO + HTTP | none (serialized) |
| **(b) Thread/process-per-request** | `fork`/spawn a worker per connection | a **new thread-or-process-spawn capability** (native-only); plus per-worker temp-file isolation | medium; a new extern + concurrency-safety audit | true parallelism, OS-scheduled |
| **(c) Non-blocking reactor + `Async`** | epoll/kqueue event loop; non-blocking sockets; the locked `Async` scheduler swapped under the same API | non-blocking socket externs (`*NB`); a reactor scheduler replacing the sequential one in `stdlib/async.mdk`; `Suspend (_ => poll …)` wiring | largest — the real language addition the user wants | cooperative, single-thread, real IO overlap |

**Why (c) is an additive swap, not a rewrite (the ASYNC-DESIGN payoff).** The v1
trampoline `data Async a = Done a | Suspend (Unit -> Async a)` already models "this task
can be paused and resumed" — exactly the reactor hook. A non-blocking `netRecvNB` that
returns `WouldBlock` becomes `Suspend (_ => poll fd)`; the reactor drains the same run
queue. The **public face is untouched**: `pure`/`map`/`andThen` laws, `do` notation,
`concurrent : List (Async a) -> Async (List a)`, and `main : Async Unit` dispatch all
already exist and don't change. So a server written against the `Async` API in stage (a-as-
async) keeps working byte-for-byte when the reactor lands.

**RECOMMENDATION (the key fork): ship (a) for v1; defer (c); skip (b).**
- **(a)** delivers a *working playground* with zero async-runtime work — and it
  dogfoods the new sockets + HTTP-in-Medaka, which is the actual point of "the server
  in Medaka." A single-user-at-a-time playground compile-server is entirely adequate for
  the first shareable artifact (compiles take ~seconds; a small queue absorbs bursts).
- **(c)** is the user's "real async runtime" goal and the genuinely exciting language
  addition — but it is a *separate, large* project (reactor + non-blocking externs +
  scheduler swap). Sequence it **after** the playground ships, as its own milestone,
  precisely *because* the locked contract guarantees it slots in without breaking the
  shipped server. Building (c) to ship a playground would be backwards.
- **(b)** is a trap: it needs a *new* thread/process-spawn capability and a
  concurrency-safety audit of the whole eval/runtime, yet `Async` (c) gives better
  resource behavior for an IO-bound compile-server. Skip it unless a CPU-bound need
  appears that genuinely wants OS parallelism.

**What the server NEEDS for v1 vs what "real async" adds:** v1 needs *none* of async —
blocking sockets + a serial accept-loop is sufficient and simplest. "Real async" adds
*concurrency under load*, which the playground can live without until it has users.

---

## 5. Capability-effects integration (the playground IS the wedge demo)

Cross-ref `CAPABILITY-EFFECTS.md` + `CAPABILITY-PLATFORM.md` (§7c "wow demo", §397
boundaries). The playground operationalizes the platform's plugin-sandbox model on the web:

- **Server side (trusted, max authority):** its effect row (§3.3) is the honest manifest
  of a trusted component — broad, because it's *our* code. Soundness here is a security
  property (`CAPABILITY-PLATFORM.md` §8): a hole in effect inference is a hole in the
  guarantee, but the browser sandbox is the coarse backstop.
- **User side (untrusted, zero authority):** the user program is offered **only**
  `mdk_write_byte`/`mdk_write_err_byte`. Any `<Net>`/`<FileRead>`/`<Exec>` in user
  source means the emitted module references a host import **we do not supply** → it
  cannot instantiate, or (better) we reject at `check` time and show the effect row that
  exceeded the playground's `{Stdout, Stderr}` policy — the literal §7c demo, in-browser:
  *"your program uses `<Net>`, not permitted in the playground sandbox."*
- This makes the playground the §388 "highest-leverage next step": a one-click, install-
  free, *live* demonstration that the effect system gates real capabilities, with the
  browser's memory sandbox as the §397 honest backstop for the resource side (CPU/mem
  exhaustion — out of scope for effects, handled by Worker termination + budgets).

**Where this doc lives (fork §9f):** `CAPABILITY-PLATFORM.md` is the *product-vision*
doc; the playground is a *deployment form* of it. **Recommend: keep this as a standalone
doc, and add a one-paragraph forward-link from `CAPABILITY-PLATFORM.md` §7c/§388** ("the
web playground that §388 names — see PLAYGROUND-DESIGN.md"). Rationale: this doc spans
*two* concerns (the WasmGC delivery half + the Medaka-server/sockets/async half) that are
broader than the capability-platform narrative; folding it in would unbalance that doc.

---

## 6. MVP-first staging (each stage independently shippable)

1. **Stage 0 — client target available (prerequisite MET).** The WasmGC MVP
   (`medaka build --target wasm`, real-prelude multi-module compute+print, byte-
   identical to native) is met (§0). *Owned by the WasmGC backend effort, not this
   doc — listed here only to mark the dependency satisfied.* The playground can run
   any compute+print program today.
2. **Stage 1 — `medaka build --target wasm`** (§2.1): wire the wasm entry into both build
   drivers + `wasm-tools` assemble. Ship-test: a `.mdk` → `.wasm` that runs under
   `test/wasm/run.js`.
3. **Stage 2 — static playground page** (§2.2/§2.3): editor + console + a *server-stub*
   that shells `medaka build --target wasm` locally (no Medaka server yet) and returns
   bytes/errors. End-to-end in-browser run + diagnostics. **First shareable artifact.**
4. **Stage 3 — the Medaka server, blocking-sequential** (§3, async stage (a)): add the
   `<Net>` socket externs + HTTP-in-Medaka + the compile-subprocess driver. Replaces the
   stub. Dogfoods the sockets. Still single-request-at-a-time.
5. **Stage 4 — hardening**: compile sandboxing/resource limits (§9d), engine-feature
   banner, richer demos (the capability-rejection demo, shareable permalinks).
6. **Stage 5 (separate milestone) — the reactor + `Async`** (async stage (c)): non-blocking
   socket externs + scheduler swap → concurrent server. Additive per the locked contract.

---

## 7. What's explicitly NOT needed for a v1 playground

- **No socket/`<Net>` binding on the WasmGC side** — user programs are compute+print;
  the sockets are native-server-only.
- **No full WASI / file surface for user programs** — they get stdout/stderr only.
- **No async runtime for the server** (stage (a) is blocking-sequential).
- **No thread/process-spawn capability** (skip async stage (b)).
- **No persistence / database / auth / accounts / saved snippets** — stateless compile.
- **No multi-tenant isolation, billing, quotas** — that's the `CAPABILITY-PLATFORM.md`
  edge-host product, downstream.
- **No self-hosting the server on WasmGC** — the server is native, permanently (§9e).
- **No `wasm-opt`/perf pass** on emitted modules — correctness first; float-unboxing and
  `wasm-opt` are post-MVP WasmGC perf projects (`WASMGC-DESIGN.md` §11).

---

## 8. Open risks / unknowns

- **WasmGC backend maturity (met, watch the edges).** The compute+print MVP is met
  (§0); the client half is unblocked. Residual edges to track as the corpus grows:
  float-unboxing perf (`WASMGC-DESIGN.md` §11), the 32–63-bit-int box asymmetry, and
  any stdlib surface a richer demo reaches beyond the gated corpus.
- **Browser engine drift.** Finalized Wasm 3.0 GC needs current Chrome/Firefox; Safari/
  WebKit GC support must be checked before claiming "works everywhere." Feature-detect +
  banner.
- **Compile-server abuse.** The server runs the *real* compiler on *arbitrary* submitted
  source. The compiler can be made to consume CPU/memory (huge programs, pathological
  types, deep recursion in the tree-walker emitter). Needs resource limits *on the
  subprocess* (§9d) — this is a security surface even though user code never *runs*
  server-side.
- **HTTP-in-Medaka maturity.** A from-scratch HTTP/1.1 parser must handle chunked bodies,
  header limits, malformed input robustly — modest but real work; a bug is a server DoS
  vector. (Mitigated: the server only speaks to its own page; not a general web server.)
- **Socket extern semantics across backends.** The native C shims are straightforward,
  but the abstract-value contract (`String` == UTF-8 bytes) must hold for `netRecv`/
  `netSend` to treat a `String` as a raw byte buffer including non-UTF-8 bytes — verify
  the rep tolerates arbitrary bytes (binary `.wasm` over a `String` body especially).
- **`(start)`-driven run + infinite loops.** Instantiate==run means a non-terminating
  user program hangs the worker; needs a wall-clock budget + worker termination, and a
  way to surface "killed: time limit" to the console.
- **Async swap fidelity.** Stage 5's claim that the reactor is behavior-preserving rests
  on the ASYNC-DESIGN §2.1 trampoline encoding surviving the typechecker's value
  restriction (its own §2.1 validation gate) — verify on the binary before committing.

---

## 9. Design forks (need a human decision)

**(a) Async scope for v1 — blocking-sequential vs thread-per-request vs full reactor.**
*Recommend **blocking-sequential** (§4 stage a).* Tradeoff: simplest, zero async-runtime
work, fully dogfoods sockets + HTTP — at the cost of serialized compiles (fine for a low-
traffic playground; a small queue absorbs bursts). Defer the **full reactor (c)** to its
own post-launch milestone (the locked contract makes it a non-breaking swap); **skip
thread-per-request (b)** (needs a new spawn capability + concurrency audit for worse
fit than the reactor).

**(b) HTTP-in-Medaka vs a bound C library.** *Recommend **in-Medaka**.* Tradeoff: aligns
with the dogfood goal and the C-not-Rust stance (C stays thin syscall shims; protocol
logic in Medaka), and the parser is a great stdlib showcase — at the cost of writing +
hardening an HTTP/1.1 parser (chunked encoding, limits, malformed-input robustness) that
a C lib would give for free. Acceptable because the server only talks to its own page.

**(c) Socket extern surface shape — BSD-socket-style vs a higher-level listener.**
*Recommend **BSD-socket-style** (the §3.2 `netListen`/`netAccept`/`netRecv`/`netSend`/
`netClose`).* Tradeoff: minimal, faithful to the C shim, composes into any protocol, and
the non-blocking variants drop in cleanly for the reactor — at the cost of more Medaka-
side plumbing than a `serveHTTP : (Request -> Response) -> <Net> Unit` would. The
higher-level listener can be a *stdlib* layer **over** the BSD externs later; keep the
externs primitive.

**(d) Compile isolation / security of the subprocess.** The server runs the real compiler
on untrusted source. *Recommend: spawn the compiler in a **resource-limited subprocess***
— CPU-time + memory + wall-clock limits (`ulimit`/`rlimit`/`timeout`-style), a scratch
temp dir per request, and no inherited capabilities beyond reading the repo. Tradeoff:
needs a small native facility (or wrapping `runCommand` with limits) — but it's load-
bearing: even though user code never *runs* server-side, the *compiler* is an attack
surface. Open: whether to add a `<Net>`-style "spawn-with-limits" extern or rely on an OS
wrapper (`timeout`/cgroup) invoked via `runCommand`.

**(e) Server native-only forever vs eventual self-host-on-WasmGC.** *Recommend **native-
only, permanently**.* The compiler and the server stay native; WasmGC is the *user-program*
target. Tradeoff: none meaningful — a WasmGC server would need the very `<Net>`/`<Exec>`
host imports we're deliberately *not* granting in the sandbox, and the native target is
where the broad-capability trusted code belongs (§6a).

**(f) Where this doc lives — standalone vs `CAPABILITY-PLATFORM.md` section.**
*Recommend **standalone** + a forward-link from `CAPABILITY-PLATFORM.md` §7c/§388.*
Tradeoff: a standalone doc spans the two halves (WasmGC delivery + Medaka server) more
naturally than a platform-doc subsection; the cost is one cross-link to maintain. The
platform doc already *names* the playground (§388) — that's the anchor for the link.

---

## 10. Cross-reference summary

| Need | Source (verified) |
|---|---|
| WasmGC backend status, host-import ABI, engine caveats, `--target wasm` sketch | `selfhost/WASMGC-DESIGN.md` §6/§7/§8/§9/§11 |
| LLVM build-driver shape to parallel | `lib/build_cmd.ml` + `selfhost/driver/build_cmd.mdk`; dispatch in `selfhost/driver/medaka_cli.mdk` |
| Browser runtime glue | `test/wasm/run.js` |
| Locked async contract (the swap) | `ASYNC-DESIGN.md` §0/§4/§5 |
| Existing IO externs + the no-socket gap | `stdlib/runtime.mdk` |
| `<Net>` Prefix label (both backends) | `lib/typecheck.ml`, `selfhost/types/typecheck.mdk` |
| Extern disposition (C-shim/LEAF) + capability-interface model | `selfhost/RUNTIME-DESIGN.md` §6a + §5 |
| Product vision + the wedge demo this instantiates | `CAPABILITY-PLATFORM.md` §7c/§8/§388 |
| Two-site extern add convention | `stdlib/runtime.mdk` + `lib/eval.ml` (+ `runtime/medaka_rt.c` native) |
