# BROWSER-STACK-DIAGNOSIS.md — the playground `Maximum call stack size exceeded` overflow

> **Status: DIAGNOSIS ONLY (read-only).** No compiler source changed. This doc identifies the
> root cause, resolves the "b′ already fixed it" paradox, and ranks fix options for a follow-up
> agent. Reproduced empirically against a freshly-built `playground.wasm` (current `main`).

## TL;DR

The overflow is **NOT the lexer's `scan` token-spine** (which the WasmGC `b′` dispatch-TMC
*did* linearize — verified: 168 `scan__disploop` sites in the WAT, zero `scan` frames in the
trace). It is a **second, structurally-similar-but-uncovered recursive family in the same file**:
the lexer's **offside-rule LAYOUT pass** — `layout ↔ applyNl ↔ applyNlFrame ↔ applyNlTop ↔
{wouldIndent | resolveCont | popDedents}` and `layout ↔ flushClose ↔ flushCloseGo`
(`compiler/frontend/lexer.mdk:978–1192`). It recurses **~one net non-returning frame per source
NEWLINE/DEDENT event** — i.e. **O(#lines of the file being lexed)** — and it overflows on the
**PRELUDE** (`stdlib/core.mdk`, ~1200 lines), *not* the user program. The b′ Stage-2 analysis
never captured this family because its root `layout` **pattern-matches its first argument**, which
disqualifies it from `detectDispatchGroups` (`wasm_emit.mdk` requires all-PVar params).

---

## 1. Reproduced overflow + captured stack trace

Built `playground/dist/playground.wasm` (3.13 MB) from current `main` via
`playground/build_playground_wasm.sh`, driven through the production `playground/compile.mjs`
seam in Node v24 over an in-memory vfs (same code path the browser worker imports).

**Both a tiny program AND an EMPTY (prelude-only) program overflow identically:**

| user program | node default stack (~984 KB) | frames captured at overflow |
|---|---|---|
| `main = println "hi"` | TRAP `Maximum call stack size exceeded` | 2369 |
| *(empty file)* | TRAP `Maximum call stack size exceeded` | 2363 |

Empty-and-tiny overflow at the **same depth** ⇒ the deep recursion is the compiler processing the
**prelude** (`core.mdk`/`runtime.mdk`, lexed on every compile), **not** the user input. This
directly confirms the task's "critical hypothesis."

**Phase: LEXER (the layout / offside-rule sub-pass).** Captured `RangeError.stack`
(`Error.stackTraceLimit = Infinity`), repeating cycle:

```
RangeError: Maximum call stack size exceeded
  at frontend_lexer__isOpener        (wasm-function[212])   ← incidental deepest leaf
  at frontend_lexer__flushCloseGo    (wasm-function[209])
  at frontend_lexer__layout          (wasm-function[207])
  at frontend_lexer__flushCloseGo    (wasm-function[209])
  at frontend_lexer__layout          (wasm-function[207])
  ... layout ↔ flushCloseGo ↔ applyNlTop ↔ popDedents ↔ wouldIndent, thousands deep ...
  at frontend_lexer__applyNlTop      (wasm-function[221])
  at frontend_lexer__popDedents      (wasm-function[226])
  at frontend_lexer__layoutWithOffsets (wasm-function[…])   ← entry into the family
  at frontend_lexer__tokenize
  at frontend_parser__parse
  at entries_playground_main__analyzeSingle
```

Frame-frequency over the 2369-frame trace (proves the recursive family):

| function | frames | role in the layout family |
|---|---|---|
| `frontend_lexer__layout` | 1097 | root dispatcher (`lexer.mdk:978`) |
| `frontend_lexer__applyNlTop` | 460 | newline handler (`:1137`) |
| `frontend_lexer__flushCloseGo` | 451 | bracket-close context flush (`:1005`) |
| `frontend_lexer__popDedents` | 174 | dedent emitter (`:1176`) |
| `frontend_lexer__wouldIndent` | 164 | indent/continuation decider (`:1145`) |
| `frontend_lexer__resolveCont` | 10 | continuation resolver (`:1164`) |

There are **zero** `scan`/`scanAt`/`scanLower`/`emit` frames — the token-scanning spine (the
DISTRIBUTION §3a shape) is fully linearized on WasmGC. The overflow lives entirely one layer up,
in the layout pass.

**Reproduce:** `playground/build_playground_wasm.sh`, then
`node playground/dev_compile_node.mjs dist/playground.wasm dist/runtime.mdk dist/core.mdk <any.mdk>`
→ diagnostic `compiler trap: Maximum call stack size exceeded`. (A scratch harness that dumps the
raw `RangeError.stack` — a patched `compile.mjs` with `attempts=1` — is in the session scratchpad.)

---

## 2. Root cause (precise)

`layout` is a **left-to-right token-stream transducer** `List RawTok -> … -> List (Token, Int)`.
Its *self*-recursive arm over ordinary tokens (`(t, off) :: layout rest …`, `lexer.mdk:982/985`)
**did** get Stage-1 self-TMC — there is a `loop $tmcloop` in the emitted `$frontend_lexer__layout`
body. **But every NEWLINE token punches out of that loop** through a chain of *ordinary
(non-tail) `call`s*:

```
layout (RNewline …) → applyNl → applyNlFrame → applyNlTop → { wouldIndent | popDedents } → layout …
```

and every one of these emits a cons whose recursion is a **`struct.new $C_Cons` argument**, e.g.:

```
applyNlTop … | col == top = (TNewline, off) :: layout rest …         -- lexer.mdk:1140
applyNl    … | frames == [] = (TNewline, off) :: layout rest …       -- lexer.mdk:1122
popDedents … | top > col = (TDedent,off)::(TNewline,off):: popDedents col off tl …  -- :1179
flushCloseGo … | otherwise = (TNewline,off)::(TDedent,off):: flushCloseGo t off rest tl … -- :1011
```

Because the recursive call sits **inside a cons cell being built** (not in tail position), the
caller's frame **stays live holding the half-built cell** until EOF. So each NEWLINE that routes
through `applyNl` adds ~3 permanent frames (`applyNl`+`applyNlFrame`+`applyNlTop`), each DEDENT run
through `popDedents`/`flushCloseGo` adds one per popped context. Net stack growth is
**O(#newlines + #dedents) = O(#lines)** of the file being lexed. `core.mdk` (~1200 lines) drives
~2400 live frames — over the browser worker limit, and over Node's ~1 MB default.

This is the SAME "tail-recursion-modulo-cons in a dispatch callee" (b′) shape as the `scan` spine —
it is just a **different, uncovered function family**, and a harder variant (see §3).

---

## 3. Paradox resolved: is `b′` TMC applied to this path? **NO — and it structurally cannot be, as written.**

`WASMGC-TRMC-DESIGN.md` §11 "AS BUILT" and `DISTRIBUTION-DESIGN.md` §3a claim the deep-recursion
overflow is "**exactly the b′ dispatch-TMC shape the WasmGC backend already fixed**." That claim is
**correct for the `scan` token spine and for the native (LLVM) Linux backtrace** in §3a (which is
genuinely `scan → scanAt → scanLower …`, and native never got b′ ported — it uses the 256 MB
pthread, D2 Track 1). **But it is STALE/incomplete for the current WASM overflow**, which is a
*different* family (`layout`), and the WAT proves b′ is not applied to it:

- `scan__disploop` / `g_tmc_head` / `g_tmc_dest` present — **168 hits** → `scan` group linearized. ✓
- `layout__disploop` — **0 hits** → the layout family is NOT a dispatch group. ✗
- `$frontend_lexer__layout`'s body still emits ordinary `call $frontend_lexer__flushClose` /
  `call $frontend_lexer__applyNl` / `call $frontend_lexer__closeAll` (non-tail) → recursion intact.

**Why `detectDispatchGroups` skips the layout family** (exact source reasons, `wasm_emit.mdk`):

1. **Root ineligibility (the decisive one).** `wDispTryRoot` (`:5596`) only admits a root whose
   clauses satisfy `wTrmcAllPVarParams` (`:5601`, `:5378`) — *all* clause parameters must be plain
   variables (dispatch via guards, like `scan src len pos depth id | pos >= len = …`). `layout`
   **pattern-matches its first argument** (`layout []`, `layout ((RTok t off _)::rest)`,
   `layout ((RNewline col off)::rest)`, `lexer.mdk:979–988`) → `allPlainParams` is False → `layout`
   is **rejected as a root outright**. `scan` qualified precisely because it is all-PVar + guards.

2. **Intermediate members cons onto NON-root members.** Even if (1) were relaxed, the group would
   still be rejected: `flushCloseGo` and `popDedents` do `_ :: _ :: flushCloseGo …` / `_ :: _ ::
   popDedents …` — a spine cons whose tail calls *themselves*, not the root `layout`.
   `wDispIsSpineCons` (`:5637`) only accepts a cons whose tail is a **saturated call to the single
   root** (`wDispIsSatRootCall`, `:5644`). A cons-to-intermediate-member is neither a root spine
   cons (case 2) nor a cons-free dispatcher tail-call (case 3), so `wDispLeafOk` (`:5773`) cannot
   linearize it. The layout family is a *nested* dispatch graph (intermediate members are
   themselves self-recursive-modulo-cons, emitting multi-token runs) — genuinely more general than
   the flat `scan → scanAt(router) → leaf` tree b′ was built for.

**Doc corrections to record** (do not edit those docs' logic here; noted for the fix agent):
- `WASMGC-TRMC-DESIGN.md` §4.1 census lists **only** "Lexer | token spine — `scanLower`/`emit`/…"
  as the lexer's (b′) site. It **misses the `layout` (offside-rule) family** — a second O(#input)
  (b′)-class spine in the same file, which Stage 2 did not close. §11's "check_main lexes core.mdk
  fully under Node" held in June only because `core.mdk` was smaller then (fewer lines → layout
  depth under the stack limit); the current, grown prelude crosses it.
- `DISTRIBUTION-DESIGN.md` §3a's "the overflow is 100% the lexer token spine / exactly the b′ shape
  the WasmGC backend already fixed" is true for **native/`scan`** but must not be read as "wasm is
  fixed": the wasm worker overflows on the **`layout`** family, which b′ does **not** cover.

---

## 4. Quantification (why ~8 MB, and whether the main thread fits)

Bisected the single-run (`attempts=1`, TurboFan-tiered module) stack threshold for the
**prelude-only** program:

| `--stack-size` (KB) | result |
|---|---|
| 900 | TRAP |
| **1000** | **PASS** |
| 2000 … 16000 | PASS |

- **Depth ≈ 2400 live frames** for `core.mdk`; **~400 bytes/frame** (TurboFan) ⇒ **~1 MB needed**
  for the prelude alone. (Node's default ~984 KB traps at 2363 frames — right at the edge.)
- **Browser Web Worker (~0.5 MB): overflows** (~2400×400 ≈ 960 KB ≫ 512 KB). Matches the report.
- **Browser main thread (~1 MB): borderline — prelude *just* fits, but Run does not reliably.**
  The prelude-only need (~1 MB) already equals the main-thread budget, and a real Run adds
  **the user file's own O(#user-lines) layout frames on top**, plus the emit phase. So
  **moving Run/squiggles to the main thread is a fragile stopgap, not a fix** — it will re-overflow
  on a moderately long user program or the next prelude growth. (This is why hover/autocomplete —
  which do *less* work and got the main-thread + first-call-retry treatment — currently survive,
  while Run does not.) The production `compile.mjs` retry (re-run to let V8 tier Liftoff→TurboFan,
  `:155`) shrinks frames but cannot change the O(#lines) *depth*.
- Node with `--stack-size=8000` (~8 MB) passes trivially — pure headroom, no logic difference.

---

## 5. Fix options (ranked, with forks / effort / risk / seed-remint)

| # | Option | Serves | Effort | Risk | Seed re-mint? |
|---|---|---|---|---|---|
| **A ⭐** | **Restructure the `layout` family in `lexer.mdk` to accumulator/iterative form** (thread an explicit output accumulator + reverse-at-EOF, so the whole family is O(1) stack — the same fix `scanStr` already uses) | wasm worker **+ native Linux default-stack + interpreter** (the O(#lines) recursion is latent on *every* backend) | MEDIUM (~10 mutually-recursive fns, all `:: <recurse>` sites) | MED–HIGH **process** risk (in-graph) | **YES** |
| **B** | **Extend `detectDispatchGroups`/b′ in `wasm_emit.mdk`** to admit (i) a pattern-matched root and (ii) intermediate members that cons onto non-root members | wasm only | MED–HIGH (new analysis: nested dispatch graph, multi-token spine runs) | MED (novel analysis; get it wrong → miscompiled tokens) | **NO** (emitter-only) |
| C | Run compile on the **main thread** (bigger stack) | wasm only, temporarily | LOW | HIGH — **§4 shows it does not reliably fit Run** | NO |
| D | Chunk/iterativize just the layout phase (special-case) | wasm only | MEDIUM | MEDIUM (ad-hoc) | YES if in-graph |

**Notes on the forks:**
- **A vs B is the same HUMAN-DECISION fork as `WASMGC-TRMC-DESIGN.md` §8 Fork A** (source-rewrite
  vs emitter-only b′-extension), now for the *layout* family instead of the *scan* family. The
  original doc chose emitter-only (B) for scan because scan's shape was clean; **the layout shape is
  materially harder for b′** (pattern-matched root + cons-to-intermediate-member), which tilts the
  cost balance toward A here.
- **A double-serves native D2 Track 2 and more.** DISTRIBUTION §3a's native Linux overflow is the
  `scan` spine; but the `layout` O(#lines) recursion is *also* latent on native (it just hides under
  the 256 MB pthread today). An accumulator rewrite of `layout` removes a real native stack consumer
  too, and helps the interpreter. B does not.
- **A's process cost is the real gate:** `lexer.mdk` is **in the self-host graph** → the change must
  (1) survive `selfcompile_fixpoint` C3a/C3b, (2) **force a seed re-mint**, and (3) reproduce the
  **frozen lexer goldens byte-identically** (`test/bootstrap_lex.sh`, `diff_compiler_lexer.sh`) —
  a `reverse`-at-EOF or difference-list rewrite must not perturb token order. This is the same
  contract §7/§8 of the design doc spells out for Option (ii).
- **B avoids all of that** (no seed, no goldens-as-risk, no fixpoint) but is wasm-only and needs the
  harder analysis; if the browser is the only consumer that overflows *today*, B is the surgical
  choice.

**Recommended path: A (source rewrite of the `layout` family), unless avoiding a seed re-mint is a
hard constraint — then B.** Rationale: the layout recursion is an O(input) latent overflow on
*every* backend, not a wasm-codegen artifact; fixing it at the source retires it everywhere (wasm
worker, native Linux, interpreter) with one change, and sidesteps building a new, trickier
dispatch-group analysis for the nested/multi-token layout shape. The cost is the in-graph
seed+fixpoint+goldens gate, which is well-trodden.

### Exact touchpoints for the fix agent

**Option A — `compiler/frontend/lexer.mdk`** (rewrite each family to thread an accumulator; both
families have the identical shape and BOTH overflow — the offset-pairs one feeds the LSP path):
- Primary family: `layout` (`:978`), `flushClose` (`:999`), `flushCloseGo` (`:1005`), `applyNl`
  (`:1120`), `applyNlFrame` (`:1128`), `applyNlTop` (`:1137`), `wouldIndent` (`:1145`),
  `resolveCont` (`:1164`), `popDedents` (`:1176`), `closeAll`/`closeDedents` (`:1185`/`:1188`).
  Entry `layoutWithOffsets` (`:1215`).
- Mirror family (same fix, else LSP hover/offsets still overflow): `layoutPairs` (`:1223`),
  `applyNlTopPairs` (`:1264`), `wouldIndentPairs` (`:1272`), `resolveContPairs` (`:1278`),
  `popDedentsPairs` (`:1288`), `closeAllPairs`. Entry `layoutWithOffsetPairs` (`:1311`).
- Gates after: `test/bootstrap_lex.sh`, `test/diff_compiler_lexer.sh` (byte-identical goldens),
  `test/selfcompile_fixpoint.sh` C3a/C3b, then re-mint the seed; re-run
  `playground/build_playground_wasm.sh` + `dev_compile_node.mjs` (no trap on empty/tiny program).

**Option B — `compiler/backend/wasm_emit.mdk`** (generalize the b′ group detector):
- `wDispTryRoot` (`:5596`) — relax the `wTrmcAllPVarParams` gate (`:5601`) to admit a
  pattern-matched root (`layout` dispatches by first-arg constructor, not guards).
- `wDispIsSpineCons` (`:5637`) / `wDispLeafOk` (`:5773`) — accept a spine cons whose tail calls an
  *intermediate* group member (e.g. `flushCloseGo`/`popDedents` self-cons emitting multi-token runs),
  and handle a leaf that emits **two** cons cells before the recursive call (`(TDedent,_)::(TNewline,_)::…`).
- Shared analysis lives in `compiler/backend/trmc_analysis.mdk` if the generalization is factored.
- Gates: `test/wasm/diff_wasm*.sh`, `test/wasm/assemble_check_main.sh` (VALIDATE_OK), plus a new
  deep-layout fixture under `test/wasm/fixtures/`; emitter-only → no seed/fixpoint.

---

## 6. Surprises / caveats

- The production `compile.mjs` **retry-until-TurboFan** loop (`:155`) masks this entirely in Node
  (even `--stack-size=500` "passes" with retries) — but it only shrinks frame *size*, never the
  O(#lines) *depth*, so it cannot save the fixed-small-stack browser worker. Do not be misled by a
  green Node run through the un-patched seam.
- The overflow is **prelude-driven and effectively input-independent** (empty and tiny programs trap
  at the same depth). The user-visible "tiny program overflows" is a red herring: it is `core.mdk`
  being lexed, not the user's code.
- Both the `layout` and `layoutPairs` families must be fixed together — the LSP hover/offset path
  goes through `layoutPairs`, which has the identical un-linearized shape (0 `disploop` sites).
