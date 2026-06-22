# Next-orchestrator handoff — Medaka, WasmGC backend + soak (2026-06-19)

You are the **orchestrator** for Medaka, a self-hosting functional language whose native
LLVM backend is now CANONICAL (compiles itself + all user code OCaml-free). You design and
delegate work to subagents, verify their output against gates, and keep `main` + docs
coherent. You usually do NOT implement directly. **Read `.claude/ORCHESTRATING.md` first**
(the orchestrator playbook — core loop, agent-prompt skeleton, verification discipline,
footguns) and `AGENTS.md` (the agent-facing router/map).

## RESUME — 🏁 WasmGC SELF-HOST PUSH: front-end EMITS+ASSEMBLES+VALIDATES; lexer RUNS (2026-06-22). `main` ≈ `a889a23`

**The active workstream + the big result of this session.** Drove the WasmGC backend toward
self-hosting the compiler (the frontend-only-playground goal). Owning doc:
**`selfhost/WASM-SELFHOST-ROADMAP.md`** (authoritative status + the gate commands). Memory:
`project_wasmgc_backend`. Every landing below was reproduced on the binary, gated, and merged.

- **🏁 Per-binding emitter-gap census 1428 → 0.** Built a gap-record census mode
  (`selfhost/entries/wasm_emit_gaps_main.mdk` + `enableGapRecordW` in `wasm_emit.mdk`) over the
  whole compiler graph (`all_modules_entry.mdk` + `selfhost` root). Closed **9 categories**: panic
  + array intrinsics; Ref (`$refbox`); `__fallthrough__` (label encoded in the Core-IR node, NOT a
  mutable ref — the emitter is LAZY, forces strings at final assembly); string-literal clause heads
  + charCode; destructuring/refutable/assign let-binds; UTF-8 codec externs; **nested-closure
  free-var capture** (THE key fix — `freeVarsExpr` lacked compound-value-node arms (CTuple/CRecord/…)
  so do-notation `pure (a,b)` dropped earlier `<-` binds); structural batch (Char/String match-switch
  heads, ctor/tuple lambda-params, record-ctor registration via `registerRecordCtors` in
  `lowerProgramEmit` — the ONE in-graph change, fixpoint + diff_selfhost_build verified); char-class
  externs; **IO host surface** (readFile/fileExists/args/getEnv/exit via length+byte-at-a-time host
  imports, `run.js` shim with a swappable vfs seam for the browser). diff_wasm 85→130.
- **🏁 Whole-program LINKAGE closed + VALIDATE_OK.** `check_main.mdk` (the real
  lex→parse→resolve→exhaust→typecheck front-end) emits a **6.77 MB WAT** that now `wasm-tools parse`s
  AND `validate`s. Linkage fix: `scanFnValueUses` had the SAME compound-value-node hole as
  `freeVarsExpr` (value-uses in CTuple/CRecord/CRecordUpdate missed → closure-wrapper ref to an
  undefined fn). Validate layer (peeled class-by-class): eta-saturate plain constrained fns
  (`elem=fold…`), ctor-as-value eta-closures, and the litswitch phantom-`if`-result-in-nested-tower
  bug. Gate: **`test/wasm/assemble_check_main.sh`** (ASSEMBLE_OK + VALIDATE_OK).
- **🏁 The self-hosted LEXER and PARSER RUN under Node.** Runtime layer-1: `debugStringLit`/
  `debugCharLit` were stubbed to `unreachable` but the real lexer quotes every token — added a real
  WAT escape runtime byte-identical to `lib/eval.ml`. Runtime layer-2 (parser): top-level nullary
  value globals (CAF combinator ladder, `parseAppend = chainl1 parseAdd …`) were init'd in SOURCE
  order → a forward-referenced global was still `ref.null` when read (`ref.as_non_null` trap). Fixed
  by **topo-sorting value-global inits by EAGER (non-closure) deps** (ported the LLVM backend's
  `eagerVars`/`orderedValBinds`; the subtlety: do NOT descend lambda bodies — closures resolve globals
  at call-time, so only non-lambda refs are init-order deps). `lex_main`/`parse_main` run under Node.
- **🏁 Runtime layer-3 FIXED — `check_main` now INSTANTIATES + parses args + enters the check logic.**
  The "illegal cast" was list `++` miscompiled as STRING append: `emitBinRef "++"` hard-wired
  `$mdk_str_append` + `ref.cast (ref $str)` (a documented W8 gap), so `buildOracle`'s
  `flatMap dataTypeCtors prog ++ builtinTypeCtors` (list `++`) cast a `$C_Cons` to `$str` → trap.
  Fixed with a runtime-shape-dispatching `$mdk_append` (`$str`→str-append, i31-Nil/`$C_Cons`→recursive
  list append), mirroring LLVM's `@mdk_append`. **Also fixed the `run.js` args delimiter** (was split
  on `\0` — uncarryable in an env var, collapsing multi-arg to one; now `' '`) → the `args()` bug noted
  below is RESOLVED. `check_main`: 3 args reach `withFiles`, check logic runs. (`377365f`, gates 130/6/13
  + VALIDATE_OK.)
- **🏁 Runtime layer-4 FIXED (`f9c9bc3`) — the `singleOp` `unreachable` trap is gone; the self-hosted
  LEXER now lexes `runtime.mdk` fully (749 tokens) byte-identical to the native oracle.** Root: a
  UTF-8 codepoint-count bug in `$mdk_io_result_to_str` (`wasm_preamble.mdk`) — it rebuilt a `$str`
  from the host readFile buffer with `cp_count = byte_len` (a "deliberate approximation"). But
  `$mdk_str_to_chars` allocates its output `Array Char` to `cp_count` and the lexer reads
  `arrayLength src` as the char count, so for multibyte UTF-8 (e.g. an em-dash `—` = 3 bytes / 1
  codepoint in a `runtime.mdk` comment) the decoded array was padded with trailing `\0` chars → a
  stray codepoint-0 fell through every lexer clause head into `singleOp`'s `panic` → `unreachable`.
  Fixed by counting true UTF-8 lead bytes (`(b & 0xC0) != 0x80`) for `cp_count`, mirroring the peer
  `$mdk_chars_to_str`. Emitter-only (`wasm_preamble.mdk`) → no fixpoint/seed. Gates 130/6/13 +
  VALIDATE_OK, all re-verified on freshly-rebuilt binaries.
- **🏁 Runtime layer-5 CLOSED — the WasmGC TRMC arc (Stages 0–2) — the self-hosted lexer now runs to
  COMPLETION under Node.** The blocker was `RangeError: Maximum call stack size exceeded` in the lexer's
  token-list build. Design pass (`selfhost/WASMGC-TRMC-DESIGN.md`) diagnosed it as **shape (b′):
  dispatch-into-single-target TMC** — each per-token leaf scanner does `RTok … :: scan …`, so the
  cons-bearing frame stays live to EOF while the recursion target is the single dispatcher `scan`
  (neither the LLVM self-recursive TRMC shape nor general mutual recursion). Fixed via a 3-stage,
  **emitter-only** TRMC port (the existing LLVM TMC is `selfhost/TRMC-DESIGN.md`):
  - **Stage 0 (`8c69296`, seed re-minted `6bbcde8`):** made WasmGC cons/ctor recursive struct fields
    `mut` (destination-passing prereq) + lifted the backend-agnostic TRMC analysis out of `llvm_emit.mdk`
    into shared `selfhost/backend/trmc_analysis.mdk` (pure code-move; fixpoint C3a/C3b YES — the ONE
    in-graph change of the arc).
  - **Stage 1 (`8737d11`):** WasmGC self-recursive destination-passing TMC (shape a). A 2M-cons builder
    goes from Node call-stack overflow → prints `2000000` with 0 recursive calls in the loop. Gate
    `test/wasm/fixtures/w_trmc_deep_cons.mdk`, `diff_wasm` 131.
  - **Stage 2 (`2688edb`):** the novel **dispatch-into-single-target (b′)** TMC (no LLVM precedent) —
    `detectDispatchGroups` grows a `scan`-rooted TMC group (49 members on the real lexer); each spine
    cons leaf becomes cons-into-dest + `return_call $scan__disploop` (the dest carried in 3 module
    globals, `return_call` IS the loop). Gate `w_trmc_dispatch.mdk` + `DISP-ASSERT` (0 recursive
    `call $scan`), `diff_wasm` 132. **Verified on the binary:** `check_main` now lexes `runtime.mdk`+
    `core.mdk` fully under Node (flat `tokenize→parse→runCheck` trace, no `scan`-recursion tower).
  - All Stage-1/2 work is **emitter-only** (`wasm_emit.mdk` is out of the compiler graph) → no
    fixpoint/seed. Regression gates green throughout (132/6/13 + VALIDATE_OK).
- **🏁 Runtime layer-6 CLOSED (`a332da7`, emitter-only) — `stringToFloat` ported; `check_main` runs
  PAST `floatTok`.** The deferred float-codec extern (`isDeferredFloatExternW`, was `unreachable`) is now
  implemented via a HOST SEAM — the inverse of `floatToString`'s `mdk_float_fmt`: a `mdk_str_to_float`
  import (`run.js`, JS `Number()`) + a WAT runtime `$mdk_string_to_float` that pushes the `$str` bytes
  through the IO path channel, gets an f64, boxes it into `Option Float`. Byte-identical to the native
  `strtod` oracle (`stringToFloat "3.14"` → `Some 3.14`; gate `test/wasm/fixtures_modules/w_string_to_float.mdk`,
  `diff_wasm_modules` 13→14). Wired into `isStrExternW`/`externArityW`/`emitStrExternRef` (removed from
  the deferred stubs). All gates green (132/6/14 + VALIDATE_OK). **Verified on the binary:** `check_main`
  no longer traps at `floatTok` — the trap moved deeper (the next layer).
- **🟡 NEXT — runtime layer-7: `frontend_lexer__stripComments` stack overflow (`Maximum call stack
  size exceeded`).** With `floatTok` unblocked, `check_main` now traps a **self-recursive overflow** in
  `frontend_lexer__stripComments` (authoritative wasm stack trace shows `stripComments` recursing into
  itself to the limit; NOT `coalesceStep` — the layer-6 agent's report was imprecise). This is a lexer
  self-recursion that Stage-1 self-TMC did NOT transform — **diagnose the shape first**: read
  `selfhost/frontend/lexer.mdk`'s `stripComments` to classify it (a cons-tail (a) case Stage-1 missed? a
  plain-tail recursion where WasmGC `return_call` TCO isn't firing? a non-tail accumulator needing
  restructure?). The fix likely extends the WasmGC TMC/TCO coverage (emitter-only) OR is another spine in
  the §4.2 Class-A set. Then re-measure `check_main` (more spines — parser `coalesceStep`?, typecheck —
  or the Class-B AST tree-walk may follow).
- ~~args() bug~~ **RESOLVED** in `377365f` (run.js delimiter `\0`→`' '`; verified `foo bar`→2 args).
- **SEED: re-minted (`11f2229`), `bootstrap_from_seed` PASS** (was stale from the in-graph
  `core_ir_lower.mdk` structural-batch change; fixpoint C3a/C3b held throughout).
- **METHODOLOGY notes from this arc:** (1) the per-binding census measures EMITTABILITY only — it is
  BLIND to whole-program linkage AND runtime correctness; both are separate onion layers found only by
  emit→assemble→run. (2) the SAME compound-value-node bug bit twice (`freeVarsExpr` capture +
  `scanFnValueUses` linkage) — when adding a CExpr-walking pass, cover ALL compound value nodes. (3)
  the lazy emitter forbids mutable-ref-as-state-threaded-across-emit (reads default at use site) —
  encode in the Core-IR node / locals instead. (4) `wasm_emit.mdk` is OUT of the compiler graph (no
  fixpoint/seed) EXCEPT changes to `core_ir_lower.mdk`/`dce.mdk`. (5) ALWAYS rebuild the wasm emitter
  binaries (`bash test/wasm/build_wasm_oracle.sh`) before gating — stale-binary footgun bit twice
  (the 4 new structural fixtures read as failing on a stale emitter). Gate suite: `test/wasm/{diff_wasm,
  diff_wasm_typed,diff_wasm_modules,assemble_check_main}.sh` (130/6/13 + VALIDATE_OK); Node ≥22 (gates
  auto-`nvm use 24`).


## RESUME — Effect-and-capability conformance roadmap substantially CLOSED (2026-06-21). `main` = `9cc7c9f`

**The effect/capability conformance roadmap (`EFFECTS-CONFORMANCE-ROADMAP.md`, audit
`EFFECTS-CONFORMANCE-AUDIT.md`, spec `EFFECTS-SEMANTICS.md`) is substantially CLOSED — E1·E2·E3
fully closed, E4 native-done, E5 standing.** Authoritative status: the roadmap's "✅ Workstream
status" block + memory `project_effects_semantics_spec`. Every landing was native-canonical,
reproduced on the binary, fixpoint-gated (C3a/C3b YES), and merged; seed re-minted (`9cc7c9f`,
`bootstrap_from_seed` PASS).

- **WS-1a/1b/1c** (E1/E6 capability manifest) — `medaka check-policy` ported to the native CLI
  (`f9abda9`), parameter-level policy compare via domain `dsub` (`a5b057a`), and `medaka manifest`
  → TOML `[package.capabilities]` (`41509f6`). The wedge is now real on the canonical binary.
- **WS-2** (E3 α precision, `98bf22b`, **both compilers** in lockstep) — α scope-seeding: enclosing
  function-body `let`s thread into the known-prefix analysis; A4/outer reject→accept,
  computed/helper-laundered stay ⊤ (sound, intraprocedural-only by design).
- **WS-3** (E2 `Set` domain, `5a1d215`, native-only) + **WS-4** (E2 `Product`/structured Net,
  `b948ff3`, native-only) — `Set` (`<L {a,b}>`, ⊑=⊆, card-cap 16) and `Product`
  (`<Net Host="…" Method={…}>`, opt-in `effect Net Product`, pointwise lattice, soundness-critical
  `dsubN` axis-defaulting-to-⊤). Design banked in `WS-4-DESIGN.md`. **Abstraction held: no domain
  add ever touched `unify_row`/escape/manifest-extractor/AST.**
- **WS-3b** (E4 Env/Exec, `2188e6a`) — domain-directed inferred-hole fill landed (Env=Set,
  Exec=Prefix); the **builtin-extern flip in `stdlib/runtime.mdk` is the ONE deferred item**,
  blocked on the frozen OCaml oracle (registers Env/Exec atomic + reads the *embedded* runtime), so
  it rides the `lib/`-removal soak tail and lands with zero further native work.
- **OPEN follow-ups (both by design, neither urgent):** (a) the WS-3b shared-runtime flip
  (soak-tail). (b) **WS-5** extern-row assurance — a standing review discipline (the extern catalog
  is the trusted base), not a code task. Also downstream: Phase 146b parameterized-effect work
  (CAPABILITY-EFFECTS §6a).
- **METHODOLOGY notes from this arc:** (1) every domain add stayed native-only *except* WS-2 (an
  inference change to existing syntax → had to land in BOTH compilers or the diff gates diverge);
  new-syntax domains (Set/Product) are native-only because the frozen oracle is slated for removal.
  (2) **Editing `stdlib/runtime.mdk` stale-bakes the OCaml oracle** until `dune build bin/main.exe`
  regenerates `lib/stdlib_content.ml` — this is exactly why the WS-3b builtin-extern flip can't land
  while `lib/` lives. (3) The new gates `test/effect_set_domain.sh` (5), `test/effect_param_domain.sh`
  (6), `test/effect_product_domain.sh` (8), `test/diff_selfhost_check_policy.sh` (4+7), and
  `test/manifest_emit.sh` (6) are the effects canary set — keep them green.

## RESUME — Dict-passing conformance roadmap CLOSED (2026-06-21). `main` = `5d5bd08`

**The dict-passing conformance roadmap (`DICT-CONFORMANCE-ROADMAP.md`, audit `DICT-CONFORMANCE-AUDIT.md`,
spec `DICT-SEMANTICS.md`) is substantially CLOSED — D1 through D10 all resolved.** Authoritative status:
the roadmap's top "STATUS" block + memory `project_dict_semantics_spec`. Each landing was reproduced on the
binary, fixpoint-verified (C3a/C3b YES), and merged. Seed re-minted (`bootstrap_from_seed` PASS).

- **D1** existence gate + dispatch (`afe4b89`/`00cf2f7`/`83bb5c7`/`db091fd`/`72a1477`) — superinterface
  rejection + `expand_supers` superclass evidence + ambiguity-defaulting (sole-impl→default / ≥2→`AmbiguousImpl`).
- **D2** cross-module dict-arity collision (`e488cd9`); **full re-key (Option B) DEFERRED net-negative** —
  empirically proven the conservative fix IS the module-qualified re-key (call site definer-correct via scheme
  resolution); Option B = eval-dict footgun for zero gain.
- **D3** global coherence (`84642d0`) · **D4** WS-3 most-specific return-pos (`fdaefda`) · **D5/D6** WS-4
  guards (`adbbb97`) · **D7** flatten suffices · **D8** WS-5 phantom reject (`aa020b0`) · **D9/D10**
  flag rename + inert removals + doc fixes (`121b9dc`).
- **Found + fixed in passing** (`1765007`): `check` SIGTRAP on `Map`/`Set` literals (resolve missing
  `EHeadAnnot` arm); spurious cross-module `No impl of Ord for Int` (`checkCallObligations` omitted `accData`).
- **OPEN follow-ups:** (a) **WS-2 re-key (Option B)** — user wants it in a SUPERVISED new session (an Opus
  agent prompt was prepared); high-risk/zero-observable-gain cleanup, AST-origin threading through
  resolve/ast/typecheck/eval. (b) **Bug C** — `toList` on a `Map` resolves to the `Foldable` method not the
  `map.mdk` standalone (`map.mdk:350`) → native rejects `No impl of Foldable for Map a` where the oracle
  accepts; Phase-112 standalone-vs-method territory; was masked by the now-fixed SIGTRAP.
- **METHODOLOGY notes from this arc (read before the next dict task):** (1) every "confirmed bug" decomposed
  into finer real gaps under empirical scrutiny — reproduce before merging, always. (2) **3 unattended agents
  silently rooted their worktree at the session-start commit despite self-reporting `BASE_OK`** — verify base
  yourself via `git diff --stat <main> <branch>` (mass deletions / recent fixtures vanishing = stale) +
  `merge-base --is-ancestor <recent-sha>`; bake a `test -f <recent-fixture>` assert into prompts. (3)
  **`FORCE=1 bash test/build_oracles.sh` before `diff_selfhost_typecheck_errors`/`_eval_dict`** — they read
  mtime-skipping `test/bin/*` oracles; a hand-edit + un-FORCEd gate gave 5 FALSE failures that cost a wrong
  revert. See ORCHESTRATING.md Failure modes.

## RESUME — Web playground workstream: Stages 1+2 DONE (2026-06-19). `main` was `bd71d40`

**The active workstream** (user-chosen): the in-browser Medaka playground —
**`PLAYGROUND-DESIGN.md`** (design; §6 staging; §6.1 hosting DECIDED; §9 forks for the server half).
Architecture: a trusted compile API (runs `medaka`) + UNTRUSTED user programs compiled to WasmGC that
run sandboxed in the visitor's browser — a live capability-effects wedge demo.

- **Stage 0** (WasmGC `--target wasm` MVP) — MET.
- **Stage 1 — `medaka build --target wasm` CLI flag — ✅ DONE (`1323c36`, native-only).** `--target
  native|wasm` in `selfhost/driver/{medaka_cli,build_cmd}.mdk`; wasm branch runs `wasm_emit_modules_main`
  → WAT → `wasm-tools parse`+`validate`. Gate `test/build_wasm_cmd.sh` 4/0. **Residual:** needs a COMPILED
  wasm emitter via `MEDAKA_WASM_EMITTER` (entry `main = match args ()` can't run under interp; same as LLVM
  `MEDAKA_EMITTER`); `make medaka` mints `medaka_emitter` but nothing mints a canonical wasm emitter yet.
- **Stage 2 — static page + Node stub server — ✅ DONE (`3243849`).** `playground/` (5 files, zero npm
  deps, additive): `server.js` (Node HTTP stub — `POST /compile` runs `medaka check --json` then `medaka
  build --target wasm`, returns `application/wasm` bytes or `{errors}`; `PORT` env; probes prereqs),
  `worker.js` (Web Worker runner, host-import ABI copied verbatim from `test/wasm/run.js`, terminable),
  `main.js` (Run→POST→Worker, 10 s kill-timer, WasmGC feature-detect banner, diagnostics pane),
  `index.html` (textarea editor + console), `README.md`. **Independently verified:** good compile → valid
  wasm → run-path output matches oracle (`15`); bad compile → correct `check --json` diagnostics.
  *(Footgun hit during verify: main `./medaka` was stale (pre-Stage-1) → server's `--target wasm` failed
  "takes exactly one input file"; `make medaka` + `build_wasm_oracle.sh` fixed it. The CONTAINER must
  build medaka fresh.)*
- **HOSTING DECIDED (2026-06-19, `bd71d40`, PLAYGROUND-DESIGN §6.1):** static front on a free CDN
  (CF/GH Pages); **compile API as a CONTAINER on Cloud Run / Fly Machines (scale-to-zero, ~$0 hobby,
  platform gives TLS + resource caps).** NOT edge-FaaS (can't exec native binaries). **Stage-3 Medaka
  socket server DEFERRED** — the containerized Stage-2 Node stub IS the v1 production backend; build the
  `<Net>` sockets + HTTP-in-Medaka later as a language/async-reactor milestone, swap into the same image.
- **NEXT — Stage 2b: containerize for Cloud Run/Fly.** A slim Dockerfile bundling `medaka` +
  `test/bin/wasm_emit_modules_main` + `wasm-tools` + `stdlib/*.mdk` (compiler reads stdlib via
  `MEDAKA_ROOT`), `server.js`, env wired, listen on `$PORT`; **build `./medaka` fresh in the image**
  (stale-binary footgun above); a deploy README. No clang on the wasm path → small image. Then Stage 4
  hardening (resource limits — much given by the platform; shareable permalinks; the capability-rejection
  demo). Stage 3 (Medaka server) + Stage 5 (async reactor) are deferred language milestones, NOT launch
  deps; their §9 forks come up only if/when we build the Medaka server.
- **Memory:** `project_playground_workstream`.


## RESUME — WasmGC 2nd backend: MVP MET + W8b DONE (2026-06-19). `main` was `7bae959`→`44c915f`

**The active workstream.** A direct **Core IR → WAT text** WasmGC emitter (`selfhost/backend/wasm_emit.mdk`
+ `wasm_preamble.mdk`), paralleling the LLVM emitter. Design + locked forks: **`selfhost/WASMGC-DESIGN.md`**
(§9 slice list, §10 forks). Authoritative status: memory **`project_wasmgc_backend`**. PLAN.md hub row added.

- **Slices W1–W9b DONE + on `main`.** W1 toolchain · W2 scalar · W3 ADTs/match (`br_table`) · W4
  closures/`call_ref`/TCO (`return_call`, arity-in-struct) · W5 dispatch (`CMethod`/`CDict`) · W6a strings
  (`(array i8)`+cp_count, byte-write IO) · W7 collections · W8 RNG/hash/string-externs · W9 + **W9b** the
  real-prelude + multi-module pipeline. **MVP = real-`core.mdk`-prelude + multi-file compute+print programs
  compile to WasmGC and run byte-identical to `medaka build`** — independently verified end-to-end (Node 24).
- **Gates** (all green): `test/wasm/diff_wasm.sh` 85 (prelude-free entry), `diff_wasm_typed.sh` 6 (typed
  entry, own-interface dispatch fixtures), `diff_wasm_modules.sh` 9 (real-prelude/multi-module, incl
  multi-file `mm_sum→43`). Oracle = `./medaka build` (needs `MEDAKA_EMITTER=$PWD/medaka_emitter` env).
- **KEY: `wasm_emit.mdk` + its entries are OUTSIDE the self-host compiler graph** (only `test/bin/wasm_*`
  import them, not `medaka_cli.mdk`) → **no fixpoint, no seed re-mint** for emitter changes. The decisive
  check is the output-diff gate. (The 2 lexer ergonomics fixes this session WERE in-graph → fixpoint + seed.)
- **Engines installed** (engine drift is real — `WASMGC-DESIGN.md` §11): `wasm-tools` 1.252, `wasmtime` 45,
  **Node 24 via nvm** — the default `node` 20.11 FAILS the finalized Wasm 3.0 GC encoding ("invalid array
  index"); the gates auto-`nvm use 24`. `make medaka` may need `FORCE_EMITTER_REBUILD=1` to carry a graph change.
- **DONE — W8b** (main `993d4f3`): Floats (literals → `f64.const`+`struct.new $float`; arith/cmp via
  structural Float recovery; `intToFloat`/`floatToInt`/`hashFloat`/`randomFloat` pure WAT; `floatToString`
  = HOST IMPORT `mdk_float_fmt` reproducing `%.12g` byte-for-byte — the authorized one host-dependent
  formatter, parallel to the IO seam) + `stringIndexOf`/`stringCompare` (pure WAT building Option Int /
  Ordering). Gates 85/6/9. `WASMGC-DESIGN.md` §9/§11 + memory `project_wasmgc_backend` reconciled.
  **DEFERRED (clean gaps):** `stringToFloat` (strtod port). Surfaced 2 pre-existing native float-literal
  gaps → memory `project_float_literal_native_gaps` (LLVM e-form const build bug FIXED `7bae959`;
  scientific-notation source literals still rejected at check by both compilers — open/deferred).
- **WasmGC roadmap AFTER W8b** (next agents): (1) **IO/WASI host surface** — file/exec/stdin/args/env, the
  capability-manifest payoff (this is where the wedge value lands; currently the only big deferred set besides
  `stringToFloat`); (2) **Wasmtime execution cross-check** (a WASI write path — today only `wasmtime compile` accepts the
  module; running needs host imports); (3) **Float-unboxing perf** (starts all-floats-boxed); (4) **browser
  interop** (JS String Builtins) / the in-browser playground (`PLAYGROUND-DESIGN.md`); (5) **self-host-on-WasmGC** (far horizon — needs the withheld IO surface).

### Lexer ergonomics fixes landed this session (both compilers, fixpoint-gated, seed re-minted)
- **Comment-only lines now layout-transparent** + **multi-line `if`/`then`/`else`** (leading `then`/`else`
  continues the `if`). Both in `lib/lexer.mll` + `selfhost/frontend/lexer.mdk`, mirrored, no associativity
  change. Memory `project_comment_line_layout_fix`.

## RESUME — 2026-06-18 correctness arc COMPLETE. `main` = `e638673`

**All items below are on `main`, fixpoint-gated (C3a/C3b YES), independently verified, seed re-minted.**


### Stale-golden / gate cleanup (start of session)
- Recaptured stale goldens (desugar/mark/lextok/test) after prior source edits.
- Numlit fixtures failing UNTYPED eval/lexer gates (they need typecheck-time `fromInt`) skip-listed
  in `eval_run` / `eval_run_batch` / `core_ir_run`; float-token normalization added to the curated
  `lexer` gate.
- Native LSP `No impl` type-error diagnostic RANGE fixed (was `{0,0}`; now carries the expr `ELoc`
  span — obligations were checked post-HM with stale `currentLoc`).

### Capability / parity landed
- **`medaka check --json`** — ported to native (was a no-op stub); byte-identical to OCaml oracle.
  Single-file via `analyzeLocated`, multi-module via `analyzeProject`. Gate
  `test/diff_selfhost_check_cli_modules.sh`.
- **`medaka doc`** — ported to native (`selfhost/tools/doc.mdk` + `medaka_cli` wiring); byte-identical
  to OCaml, single-file scope. New gate `test/diff_selfhost_doc.sh` (14 fixtures). Fixed a scheme
  name-collision (`lookupScheme` last-match → user-schemes-first ordering, mirroring OCaml).

### Verified gap audit + doc reconcile
5-agent read-only audit reproduced every doc-claimed-open gap on the binary. Finding: the gap docs
(CONSTRUCT-COVERAGE, TYPECHECK-AUDIT, STDLIB, etc.) were systematically stale — most "open" gaps
were already closed (all Gap C/H, most A-series, hadTypeErrors, zip/mut_array/io). Reconciled 11
planning/gap docs to reflect the real open-set.

### Correctness / soundness fixes (all fixpoint-gated, all on `main`)
- **#1 Cross-module Num-obligation soundness hole** (`selfhost/types/typecheck.mdk`): native `check`
  accepted imported function calls with numeric-literal args unifying against NON-`Num` types (e.g.
  `member s 3` with `s : Set Int`). Root: typecheck-module path passed `implDecls=[]` → `fromInt`/`Num`
  never registered → obligation dropped. Fixed by registering iface params over the full universe +
  running `checkImplObligations` on the typecheck path. Broadest fix — every imported numeric-literal
  call was affected.
- **#2 Top-level `DLetGroup` (`let rec … with …`)** wired through resolve/typecheck/marker/eval
  (`run` path).
- **#2b Recursive inferred-constraint dict-forwarding** (`inferDictAtFound`, `anyIdPinned` gate):
  unannotated recursive functions with inferred constraints (`countDown n = … countDown (n-1)`, mutual
  `isEven`/`isOdd`) dropped their forwarded dict → miscompiled in BOTH `run` and `build`. Broad win —
  all unannotated recursive numeric fns were affected.
- **#4/#5 Type-arg-blind impl dispatch**: two `impl`s of one interface sharing a head tycon but
  differing in type args (`MyPair Int Bool` vs `MyPair Bool Int`; `(Int,Int)` vs `((Int,Int),(Int,Int))`)
  dispatched to the FIRST impl in both backends. Fixed by threading the canonical full-type key through
  dispatch (`resolveArgStamp`) AND the Core-IR/LLVM backend. Coverage:
  `test/eval_dict_fixtures/same_head_argpos.mdk` + `test/build_diff_fixtures/same_head_typeargs.mdk`.
- **A7/D10 `DLetGroup` build residual FULLY CLOSED** (`run` AND `build`): `funClausesOf` arm +
  `lowerLetBind`/`letGroupClausesOf` helpers in `selfhost/ir/core_ir_lower.mdk`; `isEmittingDecl` in
  `dce.mdk` now includes `DLetGroup`. Coverage: `test/build_diff_fixtures/letgroup_toplevel.mdk`.
- **D5 interp local-shadow**: a local `let` binding shadowing a prelude-method name was mis-dispatched
  to the method in `run` (correct in `build`/oracle). Fixed in `rewriteArgScoped` (return-position arm
  was scope-blind; now skips locally-bound names, mirroring OCaml's `env.locals` skip). Coverage:
  `test/eval_fixtures/local_shadow_method.mdk`.
- **Seed re-minted** (`e638673`); `bootstrap_from_seed` C3a byte-for-byte PASS.

## REMAINING OPEN SET — 5 items (verified on the binary; authoritative next-session TODO)

These are the real soak items. Fix these before calling the soak done and removing `lib/`.

*Tooling (highest urgency — LSP correctness + lib/-removal prerequisite):*
1. **LSP parse-error in imported sibling → silent no-publish** — `didOpen` an entry importing a
   parse-broken sibling: server does NOT crash but emits zero `publishDiagnostics`. Root: the loader /
   `analyzeProject` path panics on a graph-member parse error before diagnostics can surface it. Needs
   loader error-recovery. Memory: `project_lsp_fault_tolerance`. `lib/`-removal-relevant.
2. **Latent `ppTy` drops effect rows** (new finding from the `doc` port): `selfhost/types/typecheck.mdk`'s
   `ppTy` renders interface-method effect rows wrong (drops `<IO>` etc.); the doc port worked around it
   with its own `ppTyP`. Affects LSP hover / `check` error rendering / `doc` output broadly. Fixing
   risks wide golden churn — scope carefully.

*Correctness:*
3. **Interp-behind-`build` externs** — `medaka run` (tree-walker) diverges from `build`/oracle on some
   stdlib externs: `import hash_map` (`hashString` unbound under `run`), map `toList` display,
   `arrayBlit`/IO. Build is canonical; lower severity. Need clean fixtures (privacy/API quirks muddled
   quick repros this session).

*Stdlib:*
4. **Genuinely missing**: `<>` Semigroup operator (not lexed at all — cross-cutting: both lexers +
   parser + builtins + `Semigroup` impl); JSON pretty-printer (`json.mdk` has compact `stringify` only);
   `ToJson`/`FromJson` codec interfaces; single-codepoint string indexing (deferred by design).

*Diagnostics:*
5. **Proposed compiler diagnostics** (Phase 147 ctor disambiguation, etc.) remain as-is in PLAN.md.

## Soak clock

The 2026-06-18 correctness arc found AND fixed multiple real soundness/correctness bugs (cross-module
Num over-accept, recursive dict-forwarding, type-arg dispatch, local-shadow misroute). **The soak
clock RESTARTS from this checkpoint.** Seed is FRESH (re-minted at `e638673`, `bootstrap_from_seed`
C3a byte-for-byte PASS). `lib/` stays frozen until a clean bug-free native-only stretch on top of
this base. Best soak activity = real-program use (dogfood `mq`, the jq-in-Medaka project) — surfaces
bugs + satisfies "tooling exercised end-to-end" removal gate.

## PRIOR — #11 Num-polymorphic integer literals + QoL 148/150 + concurrent d0a99a9 merged. `main` was `76177ca`
**#11 SHIPPED end-to-end (2026-06-16), native == OCaml oracle on every front, all diff gates 0-failing,
fixpoint C3a/C3b YES, seed re-minted.** Expression-position integer literals are `Num a`-polymorphic
in both compilers. Design+locked decisions: `NUMLIT-DESIGN.md` (§0). Memory:
`project_numpoly_literals_done` (authoritative). Mechanism: transparent `ENumLit` node + defaulting
pass (ground *ambiguous* not-arg-reachable Num var → Int, §0.2) + post-HM elaboration
(concrete-Int→`LInt`, concrete-Float→`LFloat`, **poly-survivor→`fromInt n` dict-dispatched**). Int-only
(no Fractional); patterns stay Int.

**QoL diagnostics:** Phase 148 (non-contiguous top-level binding clauses → `DuplicateBinding` error,
`7d755a9`) + Phase 150 (`do` on a non-monad → tailored monad message via `EDoOrigin` node, `5d11e77`),
both compilers, fixpoint-clean.

**Tracked follow-ups (low urgency):**
- **`capture_goldens.sh tc` footgun** — corrupts literal-bearing fixtures NOT in `PRELUDE_DEP_TC` on
  recapture. Goldens correct NOW; widen `PRELUDE_DEP_TC` before next bulk `tc` recapture. Memory:
  `project_numpoly_literals_done`.
- **`sum`/`product` `fromInt` workaround STAYS** (won't-do): frozen oracle panics on point-free Float
  seed; native correct. Memory: `project_oracle_fromint_pointfree_gap`.
- **`-0.0` interp/native divergence** — pre-existing, esoteric, deferred. Memory:
  `project_negzero_interp_native_divergence`.

## PRIOR — Async monad COMPLETE through ASYNC-DESIGN §7. (was `main` 463daaa)
**ASYNC FEATURE SHIPPED (2026-06-16).** Value-level effect-poly `Async e a` monad, both backends,
fixpoint-clean. `ASYNC-DESIGN.md` §0 = LOCKED decisions (authoritative); §7 staging all DONE. Memory:
`project_async_design.md`. The stages, in order:
- **Stage 1** (`stdlib/async.mdk`): effect-poly `data Async e a = Done a | Suspend (Unit -> <e> Async e a)`;
  Mappable/Applicative/Thenable; liftIO/yield/runAsync/stepAsync/concurrent; 7 doctests both backends.
- **Effect-row params on data decls** (2c1353a / native fix 85a9cb7): new `Mono` arm `TEff EffRow` /
  OCaml `TEff of effrow` in type-app arg slot; KRow kind-inferred from `<e>` field tails. Native gotcha:
  `instantiateSigTracked` seeds etbl from `effTailNames ++ rowArgNames` else bare KRow arg collapses
  to pureRow → spurious `<IO>` leak. Guard: `test/diff_fixtures/effect_param.mdk`.
- **Stage 2** (26784fb): `main : Async _` driver dispatch BOTH backends. **PARSER LIMITATION:** `<IO>`
  row literal won't parse in type-app arg position → annotate `main` unannotated OR
  `import async.*` + `main : Async e Unit`.
- **Stage 3 / D7** (463daaa): dropped vestigial `Async`/`Time` from `builtInEffects`/`builtin_effects`
  both backends. Fixpoint C3a/C3b green, no seed re-mint.

**Deferred async:** `await`/`sleep`, real parallelism/threads, non-blocking syscalls,
`spawn`/`Task` handles, cancellation/timeouts/select/race/streams.

---
## PRIOR — capability-effects v2 (Stages 1–3a merged). `main` was 4e4e5ce
Soak bug-hunt session. THREE soak fixes found+fixed+MERGED+verified:
- Native-emit scale failure (`unbound 'not'`, ~5% build rate): post-mangle synthesized-prelude-ref
  reconciliation in `dce.mdk` + `llvm_emit.mdk`. Fuzzer 900/900 clean.
- Whole-float rendering → canonical `1.0` (was `1.`): C runtime + OCaml eval + 14 goldens re-captured.
- foldMap method-level-constraint gap CLOSED (`diff_selfhost_eval_dict` 25/0 baseline).

**Stage 1** (1c22ffd): effect-row `labels:string-list` → `atom-list` over RefinementDomain, both backends.
**Stage 2b** (56e1b13): known-literal-prefix analysis + inferred-hole `<Net _>` surface form, both backends.
**Stage 3a / Half A** (4e4e5ce): IO decomposition — narrow labels (Stdout/Stderr/Stdin/FileRead/FileWrite/
Env/Exec/Clock/Net/Rand) + `IO` as widening alias. Re-annotated 19 leaf externs. Fixpoint YES.
**Stage 3 Half B (deferred):** extend `check-policy` + manifest emission per-label; port `check-policy`
to native CLI. Then the manifest/platform layer (Spin first) sits on top.

---
## The standing goal: the SOAK, then gated `lib/` removal
Native is canonical; OCaml `lib/`+`bin/` is FROZEN in-tree as the differential oracle. **The user's
gate to delete `lib/` (memory `[[retirement-is-not-removal]]`): a clean day-or-two stretch of
native-only dev where we STOP hitting bugs/gaps.** The 2026-06-18 arc surfaced+fixed multiple real
bugs — the soak clock restarted (see above). Frozen oracle is still earning its keep; `lib/` must
stay. Do NOT `rm lib/` until the user explicitly calls the soak.

## Open items (durably documented — verify before acting; docs drift)
- **5 verified open gaps** — see "REMAINING OPEN SET" above + PLAN.md §"Current status" (authoritative).
- **`lib/` removal** — soak-gated. The endgame.
- `eval_dict` 25/0 + batch 25/0 is the baseline (`diff_selfhost_eval_dict.sh` header updated).
- Deferred native-test modules: string (2 Unicode case-fold doctests), hash_map/hash_set
  (need byte-identical Int64-wrapping `hashInt`) — `diff_selfhost_test.sh` DEFERRED header.
- Stage-4 minor remainders: diagnostics-surfacing layer, coverage.ml/bench_runner.ml port — `PLAN.md`.
- `argStampEnabled` itself still has ~3 emit-only readers — possible further simplification
  (`ARGSTAMP-UNIFY-PLAN.md` §vestigiality). Not urgent.
- `capture_goldens.sh tc` footgun — widen `PRELUDE_DEP_TC` before next bulk `tc` recapture.
- Memory holds the rest (`/Users/val/.claude/projects/-Users-val-medaka/memory/MEMORY.md` index):
  dispatch-gap history, methodology, decided invariants.

## Non-negotiable operating rules (these cost real time this session — see ORCHESTRATING.md)
- **FORCE the oracle binaries:** `FORCE=1 bash test/build_oracles.sh` before ANY gate reading
  `test/bin/*` (`diff_selfhost_test`, `_eval_*`, the parity probe). `build_oracles.sh` mtime-skips
  rebuilds → a `typecheck.mdk`/`eval.mdk` change silently runs STALE source otherwise. Same for
  `./medaka` (rebuild via `make medaka`) and the parity probe binary (it doesn't auto-rebuild).
  A green/red on a stale binary means nothing.
- **The fixpoint is the decisive emitter gate.** Any change to `selfhost/types/typecheck.mdk`,
  `selfhost/eval/eval.mdk`, `selfhost/backend/*`, `selfhost/ir/*` is in the self-compiled emitter
  graph → `selfcompile_fixpoint.sh` C3a+C3b YES is MANDATORY.
- **Golden-diff, not convergence probes.** A probe comparing two modes (e.g. the argstamp parity
  probe) is BLIND to a regression that moves both modes the same wrong way. Gate on the OCaml
  golden (`diff_selfhost_eval_dict`, `diff_selfhost_test`, `diff_selfhost_build`).
- **Merge into LOCAL `main` via the MAIN checkout** (`cd /Users/val/medaka && git merge --ff-only
  <branch>`), then ASSERT it advanced (`git rev-parse main` == new tip). Never fetch/push.
  **Never `git checkout <sha>` in a worktree** (detaches HEAD; merges then strand commits on a
  dangling line). Use `git reset --hard <sha>` on the branch.
- **Agent prompts:** STEP 0 = `git merge main` + a `git merge-base --is-ancestor <expected-tip>
  HEAD && echo BASE_OK` assert. Hand the agent the verified root cause + file:line; a
  STOP-with-precise-diagnosis is a success, not a failure (the gap docs are systematically stale —
  tell agents to reproduce + disprove the hypothesis on current main). Agents commit on THEIR branch
  + report the SHA; YOU verify + merge.
- **Bounded orchestrator reading:** scope-read just enough to frame a precise prompt; delegate
  deep exploration to read-only agents; keep conclusions, not file dumps.
- **Seed:** emitter-graph changes leave the gz seed (`selfhost/seed/emitter.ll.gz`) stale; agents
  do NOT re-mint (they rely on the fixpoint). The ORCHESTRATOR re-mints
  (`CHECK_OCAML=0 bash test/refresh_seed.sh` → verify `bootstrap_from_seed.sh`) only at real
  checkpoints. Currently FRESH (re-minted at `e638673`; `bootstrap_from_seed` C3a PASS byte-for-byte).
- Build in the worktree with `dune build --root .`; never `dune test` (hangs); opam env is pre-set
  (no `eval $(opam env)`). The task list is SESSION-LOCAL — durable items go in PLAN.md/docs/memory.

## How to start
Ask the user what they want, or — if told to proceed autonomously — pick the highest-value open
item that advances the soak (likely: close one of the 5 documented gaps above, or chase whatever a
real-use bug report surfaces). For anything non-trivial, scope read-only first, present the plan,
then delegate + verify + merge. Surface genuine design decisions as questions; act on sensible
defaults otherwise.
