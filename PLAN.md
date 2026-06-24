# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–145+, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md). The detailed,
living record of the self-host port is [`selfhost/README.md`](./selfhost/README.md).

## Current status (2026-06-23) — formatter hardening (fmt bugs + style rules)

**Driven by dogfooding `fmt` on the `parsec` library; `main` = `966b546`.** All native-only
(`printer.mdk`/`fmt.mdk` are OUTSIDE the emitter self-compile graph; the one in-graph helper
`util.mdk` had its seed re-minted at `5a1f3be`, `bootstrap_from_seed` C3a PASS). Each landing
recaptured the native-sourced fmt/printer goldens and kept `diff_selfhost_fmt`/`diff_selfhost_printer`
green:
- **3 `fmt` bugs fixed:** (a) inner-block trailing comments were relocated below the block — now stay
  inline (`838f21d`, `fmt.mdk` per-source-line splice); (b) a nested `if`/`else-if` in `else` position
  collapsed onto one >80-char line — now ladders as an `else if … then` cascade (`226f139`); (c) an
  overflowing single-arg application isolated its head — now keeps `= head (…` inline and breaks inside
  the argument (`226f139`).
- **Style rule applied:** cons `::` renders **tight everywhere** (expression position now matches
  patterns; other operators unaffected) — `9c14bcb`, STYLE.md **§9**.
- **STYLE.md §10** documents the intentional `export`-on-its-own-line rule above a value signature
  (Idris-style; avoids reading as a type export). `export data`/`export impl` still collapse (they ARE
  type-level). This was reviewed and kept BY DESIGN, not "fixed."
- **Regression fixture** `test/fmt_fixtures/wrap_elseif_headarg` gates the else-if-laddering +
  head-inline fixes (they had no golden coverage); `diff_selfhost_fmt` 44→45/0.
- **`parsec` formatted** (`b9cd7b3`) — semantics unchanged (check clean, run==build byte-identical).
- **Deferred (cosmetic):** import overflow goes one-name-per-line; a fill-to-width packing is a possible
  future tweak. The frozen OCaml `lib/fmt.ml` still has the old comment/spacing behavior — irrelevant,
  the gates are native-sourced.

## Current status (2026-06-23) — block-expressions inside brackets (LAYOUT §6.1)

**`match`/`do`/`function`/`record` block-expressions can now appear directly inside `( ) [ ] { }`**
(`main` = `5e041ab`, seed re-minted, `bootstrap_from_seed` C3a byte-for-byte PASS, fixpoint
C3a/C3b YES). Grew out of the dogfood session below — `parsec` had to lift every `=> match` body into
a named top-level helper because brackets fully disabled layout (the deliberate `LAYOUT-SEMANTICS §6`
rule). Design + locked scope: [`LAYOUT-BRACKETS-DESIGN.md`](./LAYOUT-BRACKETS-DESIGN.md). Staged:
- **Design pass** reproduced the boundary; found it was TWO gates (lexer §6 + a presumed grammar gap).
- **Stage 1+2 grammar** (`2ca1df3`) — KEY finding: `match`/`do`/`function`/`record` ALREADY parsed
  inside brackets (`expr_no_block → expr_lam`); only the bare-`INDENT` block was a real grammar gap
  (added via a contained `bracket_block` nonterminal, **zero new Menhir conflicts**). The design's
  "Gate B excludes block forms" was a misread — caught by `menhir --interpret`.
- **Stage 3 lexer** (`8abe0aa`, the crux) — a **bracket-frame stack** in BOTH lexers (byte-identical):
  inside brackets, free-form stays the default; a herald (`match`/`do`/`function`/`record` via
  `isOpener`) arms a nested layout context, closed on dedent-≤-herald-col OR the matching closer
  (force-flush). Free-form continuation UNCHANGED (`diff_selfhost_lexer` 57/0, `bootstrap_lex` 57/0).
- **Dogfood payoff** (`5e041ab`) — reverted `parsec`'s 6 lifted helpers to inline bracketed blocks,
  output byte-identical to before. (`satisfyStep`/`eofStep` stay — multi-clause guard syntax, a
  different shape.)
- **Deferred (by design):** `let…in` & `if/then/else` blocks inside brackets; the bare-`INDENT` block
  herald (no keyword to arm it without regressing free-form); a closer on its OWN line after a herald
  block (grammar shape — keep the closer on the last arm's line).

## Current status (2026-06-23) — dogfood soak session 2

**A parser-combinator dogfood library + 4 compiler/tooling bugs it surfaced**
(`main` = `5855012`, seed re-minted, `bootstrap_from_seed` C3a byte-for-byte PASS, fixpoint
C3a/C3b YES). Built a real library to exercise the language; everything below was
reproduced on the binary, gated (run==build byte-identical where applicable), and merged:

- **`parsec/` — a char-level parser-combinator library** (`03720e7`/`40dd1d2`/`50da658`/`5fc6ee8`):
  added an `Alternative` typeclass (`noMatch` + `orElse`, named methods — **no `<|>` operator**,
  deliberate readability choice) with `List`/`Option` impls to `stdlib/core.mdk`; a `Parser a`
  library with `Mappable`/`Applicative`/`Thenable`/`Alternative` impls + do-notation + primitives
  + combinators (`many`/`some`/`sepBy`/`between`/`chainl1`/`choice`); and a **TOML parser** built on
  it. Headline result: higher-kinded typeclass dispatch is byte-identical across the tree-walker
  (`run`) and native codegen (`build`).
- **Finding #1 — run/build accepted programs `check` rejects** (`521a96e`) — the run/build guards
  consulted only `hadTypeErrors`; **resolve-phase** errors (`PrivateNameAccess` et al.) slipped past.
  Now run/build run the resolve-error gate and abort before eval/emit, exactly like `check`. Closes
  the long-open "emit lacks a hadTypeErrors guard before codegen" gap for the resolve channel.
- **Finding #2 — humane resolve-error rendering** (`521a96e`) — native multi-module `check` raw-ADT
  printed `(PrivateNameAccess …)`; now all 18 `ResError` variants render humanely, byte-identical to
  the OCaml oracle (`'X' is private to module Y`).
- **Finding #1b — selfhost source violated its own Phase-148 contiguity rule** (`a987a7a`,
  unmasked by #1) — `eval`/`declSexp` were split by intervening decls; `dropS`/`clauseArity`/
  `isDictParamName`/`startsWithStr` were **dead duplicate definitions**. Made contiguous / removed the
  dead copies (pure reorg, fixpoint-proven behavior-preserving).
- **Finding #3 — `medaka test` couldn't resolve project-sibling imports** (`e2846d0`) — two bugs:
  `loader.mdk`'s `findProjectRoot` returned `""` for a bare dir name (walk-up stopped), and the
  doctest path keyed the root module by last-path-component not the full dotted id. Doctests in a
  `medaka.toml` project that import siblings now work.
- **Golden cleanup** (`766cca7`) — Stage A's `core.mdk` edit had left `core.{desugar,mark,lextok}`
  goldens stale (only `core.test.golden` was recaptured); recaptured them + captured a pre-existing
  missing `local_shadow_method` sexp golden. **Lesson: a `stdlib/core.mdk` edit ripples to the
  desugar/mark/lextok/sexp golden suite, not just `test` — recapture all of them.**

## Current status (2026-06-23)

**Soak session 2026-06-23 — 5 correctness landings + a typechecker-item sweep**
(`main` = `445c10a`, seed re-minted, `bootstrap_from_seed` C3a PASS). All fixpoint-gated,
each independently re-verified before merge:
- **Bug C** (`0d40398`) — `toList m : Map` routes to the map.mdk standalone, not the
  `Foldable` method (check/run/build).
- **Empty multi-param container literal** (`98afb77`) — `Map { } : Map Int Int` types
  correctly via declared-arity head-pin (was rejected `Map vs Map Int`).
- **Use-time ambiguous-import error** (`421a4bd`, both compilers) — an unqualified name
  exported by ≥2 non-`core` modules → located `AmbiguousOccurrence` at the use (Haskell
  semantics). [`MAP-SET-AMBIGUITY-DESIGN.md`](./MAP-SET-AMBIGUITY-DESIGN.md).
- **`ppTy` effect rows** (`067c897`) — renders `<…>` like OCaml `pp_ty` (was dropping).
- **`@Impl` named-instance hints ported to native** (`45d52f7`) —
  [`AT-IMPL-PORT-DESIGN.md`](./AT-IMPL-PORT-DESIGN.md). Closes audit D9.
- **Typechecker-item sweep:** all 5 documented items reproduce-verified — #1 (ppTy) and D9
  (@Impl) were real and fixed; **D7, D8, foldMap-RNone confirmed latent/dormant** (not
  observable on the binary), re-labeled accordingly. (Methodology note: every item needed
  reproduction — Bug C's filed root cause was stale, the "definer-shadow `toList`" residual
  was a mislabel that became the empty-literal bug + the ambiguous-import feature, and D9's
  symptom had shifted. Reproduce-before-trust held throughout.)

## Current status (2026-06-18)

**Post-flip soak progress (since the 2026-06-12 native-canonical flip):** the
**gate suite is fully re-rooted off the OCaml oracle** — every correctness gate is
OCaml-free (`selfhost/REROOT-PLAN.md`); capture/mint tooling and the perf-baseline
gates keep OCaml at capture time by design until `lib/` removal. The **driver
collapse** is done (`selfhost/DRIVER-COLLAPSE-PLAN.md`): single-file typecheck+eval
now run as the 1-module case of the multi-module path (closes audit §6's recurring
single-vs-multi defect), and `medaka check` resolves imports. Native dispatch fixes
landed: **#55** (sum/product two-constraint, on both the build AND eval paths),
**#21** (binop over-application on parametric user `impl`s — removed the
`suppressBinopStamp` workaround), and the map **`Foldable (Map a)`** typecheck
false-positive + `medaka test` SIGBUS. Native stdlib test coverage expanded
(json/toml/list/set doctests+props), and the **fuzzer is ported to native**
(`fuzz_diff.sh` OCaml-free). The native-emitter **cross-module constructor-name
collision** fixed via universal ctor mangling; the **`argStampEnabled` eval-vs-emit
dispatch unification COMPLETE** (eval threads dicts; `evalDictLayerActive` retired;
`selfhost/ARGSTAMP-UNIFY-PLAN.md`); **emit-path Set-literal / mutual-rec-Monoid dict
gaps** fixed.

**2026-06-18 correctness arc — ALL LANDED** (`main` = `e638673`, seed re-minted, C3a PASS):

- ✅ **Cross-module Num-obligation soundness hole FIXED** — native `check` was accepting
  imported calls where a numeric literal unified with a non-`Num` type (e.g. `member s 3`
  with `s : Set Int`). Root: typecheck-module path passed `implDecls=[]` → obligation
  dropped. Fixed in `selfhost/types/typecheck.mdk` (register iface params over full universe
  + `checkImplObligations` on typecheck path). Broad fix — every imported numeric-literal
  call was affected.
- ✅ **Top-level `DLetGroup` (`let rec … with …`) — RUN + BUILD both work** (A7/D10 FULLY
  CLOSED). `funClausesOf`/`lowerLetBind`/`letGroupClausesOf` in `core_ir_lower.mdk`;
  `isEmittingDecl` in `dce.mdk` includes `DLetGroup`. Coverage:
  `test/build_diff_fixtures/letgroup_toplevel.mdk` + `test/eval_fixtures/letgroup_toplevel.mdk`.
- ✅ **Recursive inferred-constraint dict-forwarding FIXED** (`inferDictAtFound`,
  `anyIdPinned` gate) — unannotated recursive fns with inferred constraints dropped their
  forwarded dict → miscompiled in both `run` and `build`. Coverage:
  `test/eval_fixtures/inferred_rec_dict.mdk`.
- ✅ **Type-arg-blind impl dispatch FIXED** (both backends) — two `impl`s sharing a head
  tycon but differing in type args dispatched to the FIRST impl. Fixed via canonical
  full-type key through `resolveArgStamp` + Core-IR/LLVM backend. Coverage:
  `test/eval_dict_fixtures/same_head_argpos.mdk` + `test/build_diff_fixtures/same_head_typeargs.mdk`.
- ✅ **D5 interp local-shadow FIXED** — local `let` shadowing a prelude-method name was
  mis-dispatched to the method in `run`. Fixed in `rewriteArgScoped` (scope-blind return-pos
  arm now skips locally-bound names). Coverage: `test/eval_fixtures/local_shadow_method.mdk`.
- ✅ **`medaka check --json` ported to native** — byte-identical to OCaml. Gate:
  `test/diff_selfhost_check_cli_modules.sh`.
- ✅ **`medaka doc` ported to native** — `selfhost/tools/doc.mdk` + `medaka_cli` wiring;
  byte-identical, single-file scope. Gate: `test/diff_selfhost_doc.sh` (14 fixtures). Fixed a
  scheme name-collision (`lookupScheme` last-match → user-schemes-first ordering).
- ✅ **Native LSP `No impl` diagnostic range** fixed (was `{0,0}`; now carries `ELoc` span).

**Verified open-set — 2026-06-18 (reproduced on the binary; the REAL remaining gaps):**

*Tooling:*
1. **LSP parse-error in imported sibling → silent no-publish** — `didOpen` an entry importing
   a parse-broken sibling: server does NOT crash but emits zero `publishDiagnostics`. Root:
   loader/`analyzeProject` panics on a graph-member parse error before diagnostics surface.
   Needs loader error-recovery. Memory: `project_lsp_fault_tolerance`. `lib/`-removal-relevant.
2. **`ppTy` dropped effect rows — ✅ DONE (2026-06-23, `067c897`, selfhost-only).** `ppTy`'s
   `TyEffect` arm discarded the effect row (contradicting its "mirrors `lib/ast.ml` `pp_ty`
   byte-for-byte" comment — OCaml `pp_ty` = `pp_ty_prec 0` renders `<…>`). Fixed to render
   `<labels | tail> innertype` mirroring `pp_ty_prec` / the existing-correct `ppTyP`/`ppMono`.
   **Documented scope was OVERSTATED** ("affects hover/errors/doc broadly"): hover/scheme-dump
   use `ppMono`, `doc` uses `ppTyP` — both already correct; the buggy `ppTy` fed only two rare
   diagnostics (`sigTooGeneralMsg`/`annotTooGeneralMsg`). Real fix was a one-arm change closing
   a latent footgun (no golden churn). Gates: typecheck_errors/typecheck/check_json/doc all
   0-failing, fixpoint C3a/C3b YES (orchestrator-re-verified).

*Correctness:*
3. **Interp-behind-`build` externs** — `medaka run` lacks `hashString`/`arrayBlit`/Map
   `toList` display; `import hash_map` crashes under `run`, works under `build`. Build is
   canonical; lower severity.

*Stdlib:*
4. **Genuinely missing**: `<>` Semigroup operator (not lexed — cross-cutting: both lexers +
   parser + builtins + `Semigroup` impl); JSON pretty-printer; `ToJson`/`FromJson` codecs;
   single-codepoint string indexing (deferred by design). (`List` `zip`/`zip3`/`zipWith`/`unzip`
   ARE present — `list.mdk:494-533`.)

*Diagnostics:*
5. **Phase 147 ctor disambiguation** and other proposed compiler diagnostics — as-is.

**🏁 Medaka is a native self-hosting compiler.** The compiler is written in
Medaka (`selfhost/`), and the native **LLVM backend now compiles it**: all seven
pipeline stages (lex → parse → desugar → resolve → mark → typecheck → eval) are
native-compiled and **byte-identical to the tree-walker interpreter** (141
fixtures across `test/bootstrap_*.sh`), and the **self-compile fixpoint is
reached** — the native-compiled emitter emits the whole emitter graph (~10.6 MB
IR), reproduces the interpreter's IR byte-for-byte (C3a), and a second-generation
native emitter reproduces that IR exactly (C3b: `IR1 == IR2`). See
`selfhost/BOOTSTRAP.md` for the B1–B7 + C1–C3 log and `selfhost/EMITTER-GAPS.md`
for the closed/residual emitter gaps. The native lexer runs ~90× faster than the
tree-walker.

The **OCaml compiler** (`lib/*.ml`) is now the **frozen soak-period differential
oracle** — native is canonical (2026-06-12 flip) and the build is OCaml-free
(`make medaka`, from a checked-in IR seed). `lib/` stays in-tree, frozen, until a
confidence-gated soak completes, then is removed (retirement ≠ removal; see
[Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml)).

The OCaml compiler pipeline is complete end-to-end —
`lexer → parser → desugar → resolve → method_marker → typecheck (runs exhaust)
→ eval` — with phases through ~145 done (see PLAN-ARCHIVE.md). The language has
records, ADTs, interfaces (with superinterfaces, `deriving`, dictionary-passing
for return-position/multi-param dispatch), effect rows, exhaustiveness checking,
`do`-notation, guards (with fall-through + exhaustiveness lint), list
comprehensions, string interpolation, type aliases/newtypes, container literals
(`Map { k => v }` / `Set { x }`), property testing, doctests, **unit tests**
(Phase 127), an LSP server, a formatter, and a project-config/`medaka new` surface.

The stdlib in Medaka is **complete** across `core`, `list`, `array`, `string`
(frozen, Phase 128), ordered `map`/`set`, mutable `hash_map`/`hash_set`,
`mut_array`, `io`, and `json` (STDLIB.md Modules 1–9 all done).

**Self-host (Stage 1) and the native backend (Stage 2)** are both ✅ COMPLETE —
all eight pipeline stages ported to Medaka and validated byte-for-byte, the
bootstrap closure landed for Legs A–D, and the LLVM backend promoted from spike to
a self-hosting native compiler (the C1–C3 fixpoint above). The forward-looking
interpreter-perf levers are all resolved (`selfhost/PERF-NOTES.md`).

**Conventions.** Work is organized by numbered **Phases**; commit messages and
code comments reference them. Phases left *partial* keep their original number
(e.g. Phase 83/84, 101); genuinely new work gets the next free number (last used:
151). At task triage, match the work against AGENTS.md's task-playbook table and
load the matching skill before planning.

---

## Workstreams — where each roadmap lives

PLAN.md is the **hub**. Each workstream below has an **owning doc** that holds the
detailed, living roadmap; this file keeps only the one-line status + a pointer.
Edit the owning doc for detail; update the status line here when a workstream's
state changes. **Every open item — across all workstreams and owning docs — is
enumerated in the [Open issues index](#open-issues-index) below.**

| Workstream | Owning roadmap | Status | Near-term items |
|------------|----------------|--------|-----------------|
| **Self-hosting (Stage 1)** | [`selfhost/README.md`](./selfhost/README.md) §Roadmap | ✅ complete | perf-lever tail only (all closed) |
| **Native backend (Stage 2)** | [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md) + [`selfhost/BOOTSTRAP.md`](./selfhost/BOOTSTRAP.md) | ✅ **complete** | Core IR + bytecode VM (§2.1–2.2) done (bytecode VM removed 2026-06-10 — off canonical path); LLVM backend promoted from spike to a **native self-hosting compiler** — all 7 stages native==interpreter (141 fixtures), self-compile **fixpoint reached** (C1 emitter-IR reproduction · C2 native compiles the real lexer · C3 `IR1==IR2`). Runtime dict-passing dispatch (D3a/D3b done); Boehm GC; CTGuard lowered. Residual: `max`/`min` over primitive `Ord` (dead code). |
| **Make LLVM canonical (Stage 3)** | **this file** → [Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml) | 🟢 **essentially complete** | Native canonical (2026-06-12 flip); TYPECHECK-AUDIT (16 findings) + all 4 dispatch gaps (#54/#55/#50/#21) + perf bar-4 + Phase-C CLI capstone + gate re-rooting + the driver collapse all ✅ DONE (full log: PLAN-ARCHIVE.md → Stage 3 completion log). Soak fixes (2026-06-15): native-emit scale failure (`unbound 'not'`, fuzzer 5%→100%) ✅ DONE; foldMap method-level-constraint dict gap ✅ DONE (eval_dict 25/0). **`argStampEnabled` eval-vs-emit dispatch unification ✅ DONE (2026-06-14, [`ARGSTAMP-UNIFY-PLAN.md`](./selfhost/ARGSTAMP-UNIFY-PLAN.md)).** Soak tail: confidence-gated `lib/` removal. |
| **Capability-effects wedge (Phase 146)** | [`EFFECTS-CONFORMANCE-ROADMAP.md`](./EFFECTS-CONFORMANCE-ROADMAP.md) (v2 conformance) + [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §9 (lang) + [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md) §10 (product) | 🟢 **conformance substantially CLOSED (2026-06-21)** | E1/E6 manifest (WS-1a/b/c `41509f6`), E3 α scope-seeding (WS-2 `98bf22b`, both compilers), E2 `Set` (WS-3 `5a1d215`) + `Product`/structured Net (WS-4 `b948ff3`), E4 Env/Exec native machinery (WS-3b `2188e6a`) — all native-canonical, fixpoint-gated. **Open:** only WS-3b's builtin-extern flip in `runtime.mdk` (blocked on frozen oracle → rides `lib/`-removal soak tail) + WS-5 (extern-row assurance, standing discipline) + Phase 146b. WS-4 design banked in `WS-4-DESIGN.md`. |
| **WasmGC backend (2nd backend)** | [`selfhost/WASMGC-DESIGN.md`](./selfhost/WASMGC-DESIGN.md) §9 (slices) + [`selfhost/WASM-SELFHOST-ROADMAP.md`](./selfhost/WASM-SELFHOST-ROADMAP.md) (self-host gap-closing) + [`selfhost/WASMGC-TRMC-DESIGN.md`](./selfhost/WASMGC-TRMC-DESIGN.md) (stack-safety) | 🟢🏁 **self-hosted FRONT-END runs on WasmGC byte-identical to native; browser playground LIVE** (2026-06-22) | Direct Core IR→WAT emitter. Compute+print MVP (W1–W9b+W8b) byte-identical to `medaka build`. **Playground Stages 0–4 DONE** (`playground/`): compiler-as-wasm runs fully client-side, static-only server, WAT assembly via committed `vendor/wat2wasm/` blob. Done: per-binding emitter-gap census **1428→0**; whole-program linkage + `wasm-tools validate` (`check_main` = 6.77 MB WAT); runtime layers 1–4 (escape runtime, value-global init topo-sort, list-`++`, UTF-8 cp_count); **layer-5 CLOSED — the WasmGC TRMC arc (Stages 0–2, `8c69296`/`8737d11`/`2688edb`)** ported the LLVM TMC (`TRMC-DESIGN.md`) + a novel **dispatch-into-single-target (b′)** TMC for the lexer; the self-hosted **lexer now runs to completion under Node** (flat `tokenize→parse→runCheck` trace). **layer-6 CLOSED** — `stringToFloat` via host seam (`a332da7`). **layers 7–13 CLOSED** — parser/resolve/typecheck correctness bugs; `check_main` runs to completion byte-identical to native. **THE EMITTER RUNS ON WasmGC (2026-06-22)** — WasmGC-compiled emitter compiles `println (1+2)` → 52K-line WAT, assembles + runs + prints `3`. `wasm_emit.mdk` is OUTSIDE the compiler graph → emitter changes need no fixpoint/seed. **Remaining:** `hashName`/`dictTag` i32-vs-i64 width (layer-17, pre-existing, self-consistent); `List_andThen`/`flatMap` overflow (layer-18, latent); eventual `wasm-opt` perf pass. See `WASM-SELFHOST-ROADMAP.md` for full layer log. |
| **SQLite read-path library (capstone)** | [`SQLITE-DESIGN.md`](./SQLITE-DESIGN.md) | 🟢 **v1 read + WRITE COMPLETE — reads AND generates real `.sqlite` files, verified vs `sqlite3`** | LANDED (`main` @ `de44b58`): foundation externs (`readFileBytes` + bitwise, `1b25c9b`); `byteparser/` (`986bbd4`); cross-project `[dependencies]` in the native loader (`0ad8ae9`); file-format reader (`6657238`); multi-page B-tree (`86b1ffa`); typed `RowType` combinators + SELECT executor (`8d4c39c`); INTEGER PRIMARY KEY rowid-substitution fix in the typed path (`ccd650a`); `bytesToFloat64` extern + `beFloat64` (`359957a`); library hygiene — stdlib de-dup + STYLE §8 multi-clause (`de44b58`). All emitter-graph changes fixpoint-verified; **seed re-minted (`848f712`), cold-bootstrap PASS**. Reads single-leaf + multi-page tables, NULL/int/text/blob, IPK rowid, typed Medaka records — byte-identical to `sqlite3`. **Float read path COMPLETE (2026-06-24, `72b4c58`, pure-library):** `CFloat` cell + serial-type-7 (8-byte IEEE) decode via `beFloat64`, and a `tFloat : RowType Float` combinator. `tFloat` **coerces `CInt → Float`** (decided after a dogfood finding: SQLite stores whole-number REAL values as *integer* serial types — its storage optimization — so a faithful REAL-column reader must coerce; non-numeric cells still error). **Phase-2 ADT query model COMPLETE (2026-06-24, `e9fd54e`, pure-library):** `sqlite/lib/select.mdk` — `Literal`/`CmpOp`/`SqlExpr`/`Select` core + a phantom-typed `Expr a` layer (smart constructors `eCol*`/`eLit*`/`eEq`/`eGt`/…/`eAnd`/`eNot` named off prelude methods; type-safe — `eEq (eColInt "age") (eLitT "x")` is a `check` error), injection-safe `render` (`?` placeholders + ordered `List Literal`), `compilePred` (SqlExpr → `List Cell -> Bool`, SQL 3-valued NULL logic), and `query` (ADT drives the scanner — WHERE pushdown over raw cells + limit/offset, then `RowType` decode). Differential `select_oracle.sh` matches `sqlite3` (17 rows). **The whole read-path NEXT list is done.** **🏁 WRITE path v1 COMPLETE (2026-06-24, P0–P4):** Medaka GENERATES a fresh single-table `.sqlite` that `sqlite3` validates + queries (`PRAGMA integrity_check`=ok). `writeFileBytes` extern (`a97e34b`); `byteparser/lib/bytebuilder.mdk` (`75ccf95`); `sqlite/lib/recordenc.mdk` record encoder (`c4b9731`); `sqlite/lib/dbwriter.mdk` byte-perfect single-page writer (`691baa1`); `sqlite/lib/writer.mdk` typed `CREATE TABLE`+`INSERT` API (`4e582a6`). int/text/null/blob, IPK-as-rowid or auto-rowid, single leaf page (clean `Err` on overflow). Owning doc [`SQLITE-WRITE-DESIGN.md`](./SQLITE-WRITE-DESIGN.md). **Deferred (write):** floats (needs `floatToBytes64` extern); page splits/multi-page; `UPDATE`/`DELETE`; overflow pages; transactions/journal/WAL. **Write-workstream compiler/tooling bugs found+fixed:** native method-shadow run≠build (`96529b3`); `arrayBlit`/`arraySetUnsafe` missing from the native interp (`ecd2eee`); loader cross-package relative-import resolution F1 (`ec8c19c`). **Open from write workstream:** F1b (loader module-identity not canonicalized — same file under two import spellings double-loads; a cross-cutting loader+resolve+typecheck fix, STOPped + scoped, backlogged); `CFieldAccess` cross-module record dot-access emitter limitation (pre-existing). Fast-follows (PLAN tasks, not started): WasmGC port (bytes-first API makes it additive) + async SQL server. Dogfood findings → [Known parser gaps](#known-parser-gaps-selfhost-parsermdk) (#1/#2/#3/#4/#5/#8 FIXED 2026-06-24; #6 deferred-documented; #7 oracle-only; +the method-shadow check/eval bug found via the phantom-`Expr` design, FIXED `96529b3`); future `medaka lint` → its workstream row below. |

| **Linter (`medaka lint`) — FUTURE** | **this file** (idea; no design doc yet) | 💡 **idea / not started** | Build a lint pass for issues that are DETECTABLE but **inappropriate to auto-fix with the formatter** — `fmt` must preserve a definition's *shape*/structure, so these can't live there. Motivating case (and proof of need): STYLE §8 immediate-`match`-on-a-**bare param** → multi-clause functions, which had to be cleaned up BY HAND in the SQLite dogfood. Other seed rules from STYLE.md: §3 `match`-on-a-computed-value → guard; §6 hand-rolled `Eq`/`Ord`/`Debug` → `deriving`; §7 re-implemented prelude idioms; and **stdlib-function duplication inside user libraries** (also surfaced by the SQLite dogfood — `byteparser`/`sqlite` re-spelled `reverse`/`take`/`drop`). Default = warn/suggest (a definition-shape change is semantics-adjacent, not a pure reformat); an opt-in autofix could follow. Distinct from `fmt` precisely because it changes structure, not just layout. |
| **Compiler / language correctness** | **this file** → [Compiler / language](#compiler--language) | 🟡 open items | Phase 101b (deferred) |
| **Standard library** | [`STDLIB.md`](./STDLIB.md) §"Remaining work" + §"Label refinement roadmap" | 🟡 modules done, extras open | `<>` Semigroup operator (not lexed); JSON pretty-printer + `ToJson`/`FromJson`; single-codepoint indexing; effect-label refinement |
| **CLI surface (Phase 82)** | **this file** → [CLI surface](#cli-surface-phase-82-continued) | 🟡 gaps | `medaka build` ✅ full-prelude (H closed, 2026-06-18 audit); `check --json` multi-file ✅ CLOSED; `medaka doc` ✅ ported to native CLI (single-file, 2026-06-18) |

---

## North star — self-hosting, then LLVM

The long-term goal that orders everything below: **rewrite the Medaka compiler
in Medaka, then compile it to native code via LLVM.** Chosen path: **bootstrap on
the existing tree-walking interpreter first** — get a self-hosted compiler running
(slowly but correctly) on the interpreter, *then* build the LLVM backend so that
compiler emits native code.

Three stages, each a gate on the next.

> **Why native matters — the wedge.** Self-hosting + LLVM aren't the end goal;
> they're what *enables* it. The candidate "killer feature" is **capability-safe
> effects** (Phase 146 / [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md)): a
> function's type becomes a compiler-verified manifest of what it can do, aimed at
> **WebAssembly edge / plugin / sandboxed compute** for untrusted, increasingly
> AI-generated modules. The native (WasmGC) backend is the delivery vehicle for
> that wedge; the wedge is the reason the backend is worth building.

### Stages 0–2 — ✅ COMPLETE (self-host + native backend)

Stages 0 (prerequisites), 1 (self-host on the interpreter), and 2 (LLVM backend)
are done — Medaka self-hosts and the native backend compiles it to a reproducing
fixpoint (see [Current status](#current-status-2026-06-18)). Full per-stage detail
archived in [`PLAN-ARCHIVE.md` → Archived north star stages 0 to 2](./PLAN-ARCHIVE.md#archived-north-star-stages-0-to-2);
owning docs: `selfhost/README.md` (Stage 1), `selfhost/STAGE2-DESIGN.md` +
`selfhost/BOOTSTRAP.md` (Stage 2). Forward work is
[Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml).

### Stage 3 — Make the LLVM backend canonical, retire OCaml

Stages 1–2 are done: Medaka self-hosts and the native LLVM backend compiles the
compiler to a self-reproducing fixpoint. **Stage 3 makes the native backend the
CANONICAL compiler** — the one users invoke and the one that builds the compiler.

**Retirement ≠ removal (user, 2026-06-10 — see memory `retirement-is-not-removal`):**
- **RETIREMENT (the milestone):** native is canonical; the OCaml reference (`lib/`+`bin/`) is
  DEMOTED from "the reference" but **kept in-tree, frozen, as a soak-period oracle.** Reached
  when the bar below is met.
- **REMOVAL (separate, later, confidence-gated):** delete `lib/`+`bin/` ONLY after **a few days
  of clean native-only development with no need to consult OCaml** AND **the tools suite exercised
  end-to-end** (real use, beyond the per-slice differential gates). The frozen OCaml = the
  soak-period safety net (maps to the frozen-third-oracle bar item). Do NOT `rm lib/` at the
  retirement milestone.


**Status: Stage 3 is essentially COMPLETE — see the full item-by-item log in
[PLAN-ARCHIVE.md → Stage 3 — native-canonical completion log](./PLAN-ARCHIVE.md#stage-3--native-canonical-completion-log-archived-2026-06-14).**
The native LLVM backend is canonical (2026-06-12 flip): `make medaka` builds it
OCaml-free; all PRE-FLIP-GAPS soundness/capability gaps (G1–G9) closed; the full
TYPECHECK-AUDIT (16 findings — S1·S2·T1·T1b·T2·S3·C1·C2·C3·C6·C7·C8·C9·OBS3·OBS4)
closed; the construct-coverage sweep + all four native dispatch gaps (#54/#55/#50/#21)
closed; perf bar-4 done (5.68× self-compile / ~59× vs interp — `selfhost/PERF-RESULTS.md`);
the Phase-C native-CLI capstone + Stage-4 tooling port (fmt/test/new/repl/build/lsp) done;
**gate re-rooting done** (all correctness gates OCaml-free — `selfhost/REROOT-PLAN.md`);
the **single-file/multi-module driver collapse done** (`selfhost/DRIVER-COLLAPSE-PLAN.md`,
closes audit §6; `medaka check` now resolves imports).

**Soak tail (remaining, see "Current status" above for live state):** a clean bug-free
soak stretch and the confidence-gated `lib/` removal. (Closed 2026-06-14: `argStampEnabled`
eval-vs-emit dispatch unification — `selfhost/ARGSTAMP-UNIFY-PLAN.md`, STATUS: COMPLETE,
retires the finer dispatch fork the driver collapse left, the shared root of #55/#21. Closed
2026-06-15: native-emit scale failure `unbound 'not'` — fuzzer 5%→100%; foldMap
method-level-constraint dict gap — eval_dict 25/0; whole-float rendering canonical `1.0`.)

**Gated milestone — retire `lib/*.ml`.** ✅ **Native is now the default build (2026-06-12
flip):** `make medaka` builds the canonical native compiler OCaml-free from the seed; docs
updated; OCaml frozen as the soak oracle. **Re-rooting ✅ DONE (2026-06-13):** every
correctness gate runs OCaml-free (`selfhost/REROOT-PLAN.md`); only the capture/mint tooling
(`capture_goldens.sh`/`refresh_seed.sh`) and the perf-baseline gates (`bench.sh`/`profile_selfhost.sh`)
still invoke OCaml — by design, deleted with `lib/`. **Remaining gated steps (post-soak):**
a clean bug-free soak stretch, then archive/delete the OCaml compiler. Sequenced toward, not dated.
(Soak tail: ~~the `argStampEnabled` eval-vs-emit dispatch unification (`selfhost/ARGSTAMP-UNIFY-PLAN.md`)~~ — ✅ DONE 2026-06-14.)

After Stage 3, the **capability-effects wedge** (Phase 146) + the **WasmGC
backend** are the product horizon (see the Workstreams table).

---

## Open roadmap

Each item is independently shippable; pick one per session. Grouped by area, not
strict priority.

### Open issues index

**Single locator for every open item.** If work is open, it is in this table — either
defined below in this file or with a pointer to its owning doc. Statuses stay terse here;
the linked location holds live detail. (Keep this table in sync when an item opens/closes.)

| Open item | Area | Tracked in |
|-----------|------|-----------|
| Confidence-gated `lib/` (OCaml) removal — the soak tail | Retirement | this file → [Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml) |
| Manifest emission (`[package.capabilities]` from a verified entry's effect row) | Capability-effects | this file → [wedge sequence](#capability-effects-wedge--near-term-sequence); [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §5a |
| WS-3b builtin-extern label flip (`getEnv`/`runCommand`) — rides `lib/`-removal | Capability-effects | [`EFFECTS-CONFORMANCE-ROADMAP.md`](./EFFECTS-CONFORMANCE-ROADMAP.md) |
| WS-5 extern-row assurance (standing discipline) | Capability-effects | [`EFFECTS-CONFORMANCE-ROADMAP.md`](./EFFECTS-CONFORMANCE-ROADMAP.md) |
| Phase 146b — parameterized effects (`<Fetch "x.com">`, `<KV "ns">`) | Capability-effects | [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §6a |
| `hashName`/`dictTag` i32-vs-i64 width (layer-17, self-consistent) | WasmGC backend | [`selfhost/WASM-SELFHOST-ROADMAP.md`](./selfhost/WASM-SELFHOST-ROADMAP.md) |
| `List_andThen`/`flatMap` overflow (layer-18, latent) | WasmGC backend | [`selfhost/WASM-SELFHOST-ROADMAP.md`](./selfhost/WASM-SELFHOST-ROADMAP.md) |
| `wasm-opt` perf pass (eventual) | WasmGC backend | [`selfhost/WASMGC-DESIGN.md`](./selfhost/WASMGC-DESIGN.md) §9 |
| **Bug C** — `toList` on an imported `Map` mis-resolves to the `Foldable` method | Compiler / language | ✅ DONE (2026-06-23, `0d40398`) — see [Compiler / language](#compiler--language) |
| Empty annotated multi-type-param container literal (`Map { } : Map Int Int`) rejected at `check` | Compiler / language | ✅ DONE (2026-06-23, `98afb77`) — see [Compiler / language](#compiler--language) |
| Phase 101b — `Arbitrary`-driven nested parametric generators (deferred) | Compiler / language | this file → [Compiler / language](#compiler--language) |
| Phase 149 (proposed) — record rest-capture + construction spread sugar | Compiler / language | this file → [Compiler / language](#compiler--language) |
| D7 (latent, verified), foldMap RNone emit-site (latent, verified), helper dedup, deferred GC/TRMC seams | Self-host internals | this file → [Self-host … open items](#self-host-typecheck--dispatch--runtime--known-open-items) |
| Leading-`|` `data` decls (native-only by design; auto-resolves at `lib/` removal) | Parser | this file → [Known parser gaps](#known-parser-gaps-selfhost-parsermdk) |
| `<>` Semigroup operator (not lexed); JSON pretty-printer + `ToJson`/`FromJson`; single-codepoint string indexing; effect-label refinement | Stdlib | [`STDLIB.md`](./STDLIB.md) §"Remaining work" / §"Label refinement roadmap" |
| Diagnostic-position follow-ups (parse-error column accuracy; pattern-position spans; guard-exhaustiveness + multi-module match warnings still `None`) | Tooling / diagnostics | this file → [Stage 4](#stage-4--full-tooling-port--native-medaka-retire-ocaml-decided-2026-06-10); [`selfhost/DIAGNOSTICS-SURFACING-PLAN.md`](./selfhost/DIAGNOSTICS-SURFACING-PLAN.md) |
| Auxiliary port: `coverage.ml` + `bench_runner.ml` (port last) | Tooling | this file → [Stage 4](#stage-4--full-tooling-port--native-medaka-retire-ocaml-decided-2026-06-10) |
| Effect-reannotation utility; stack-performance recursion lint; bare effectful statements (drop `let _ =`) | Parked ideas | this file → the three "Future idea (parked)" sections below |
| `medaka add`/`remove`/`update` + `medaka.lock` | Blocked (needs package manager) | this file → [Blocked on a package manager](#blocked-on-a-package-manager-out-of-scope-until-one-exists) |

*Won't-do decisions (NUMLIT `fromInt` revert, Phase 78c, the rejected-features list) are in the [Won't-do](#wont-do-kept-intentional) section, not here.*

### Stage 4 — full tooling port → native `medaka`, retire OCaml (decided 2026-06-10)

**Stage 4 (full tooling port → native `medaka`) — ✅ COMPLETE.** All six tools —
`fmt` / `test` / `new` / `repl` / `build` / `lsp` — were ported to Medaka and
differential-tested byte-identical vs OCaml, and the **Phase-C native-CLI capstone**
(`selfhost/driver/medaka_cli.mdk`, Slices 0–4) is done: the native `medaka` binary does
all 8 subcommands (`check`/`fmt`/`new`/`build`/`run`/`test`/`repl`/`lsp`) with no OCaml at
runtime. Full per-tool / per-slice completion log archived in
[PLAN-ARCHIVE.md → Stage 4 — tooling-port completion log](./PLAN-ARCHIVE.md#stage-4--tooling-port-completion-log-archived-2026-06-14).

**Remaining (minor, not retirement-blocking):**
- **Diagnostics surfacing layer** — ✅ **substantially DONE (2026-06-21, WS-4/F6,
  `selfhost/DIAGNOSTICS-SURFACING-PLAN.md`).** Native `medaka check` now prints
  positioned, humane, **carat-rendered** diagnostics (`file:L:C: message` + source line
  + `^`, on stderr) for parse/type/resolve, byte-identical to the OCaml oracle; resolve
  errors carry real spans (`Option Loc` threaded through the resolve walk); non-exhaustive
  match warnings carry a span. Gates: `diff_selfhost_check_json` 9/0, `diff_native_cli`
  `error/*` 7/7 vs live oracle + 99/0 overall, fixpoint C3a/C3b YES, seed re-minted.
  **Open position-accuracy follow-ups** (separate, not blocking): parse-error column is
  "which-token"-wrong on non-trivial inputs (deeper self-hosted-parser position tracking);
  pattern-position errors inherit the enclosing-`match` span; guard-exhaustiveness +
  multi-module warnings still `None`. See the plan doc's residuals.
- **Auxiliary port:** `coverage.ml` + `bench_runner.ml` — port last.

### Future idea (parked, not scheduled): effect-reannotation utility

**Problem (the effect-annotation tax):** add an effect at a program leaf — e.g. a `<Mut>`
deep in a helper — and every transitive caller's written effect annotation is now too
narrow, so each one must be hand-updated up the call graph. Tedious for humans and a
recurring friction for agents.

**Idea:** a utility that propagates the new effect and **rewrites the stale annotations
automatically.** Medaka is well-suited to this because the effect system **already infers
the true effect rows** — the typechecker already knows where an annotation is narrower than
the inferred effect (that's the same information behind the "effect not in annotation" error).
So the tool mostly *consumes* existing inference: run effect inference, find each signature
whose written row ⊊ inferred row, and rewrite the annotation to the inferred row (using the
printer/`fmt` machinery to edit in place, comment-preserving).

**Surfaces:** an LSP **code action / quick-fix** ("update effect annotation" — and a
"propagate effect through callers" project-wide variant), and/or a CLI command
(`medaka fix-effects`). Leverages: the effect inference (have it), the located diagnostics +
LSP (B.10.x), `parseWithPositions`/`ELoc` for the edit site, and `fmt`/printer for the rewrite.

**Why parked:** nice-to-have ergonomics, not on the retirement path. Lands naturally AFTER the
LSP code-action infrastructure exists. Cross-ref [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md).

### Future idea (parked, not scheduled): stack-performance recursion lint

An **opt-in** compiler lint that flags self-recursive functions whose recursion is **neither tail**
(handled by `musttail`) **nor tail-modulo-constructor** (handled by TRMC #56) — i.e. functions that
will grow the native stack on deep input — to nudge users toward accumulator / tail-modulo-cons shapes
for better stack performance. **Nearly free once TRMC lands:** reuse TRMC's `trmcEligible` + the
tail-call classifier — the "neither" bucket *is* the warning. Surface through `medaka check` + LSP.

**Key design tension = NOISE.** Most non-tail recursion is perfectly safe (balanced-tree recursion is
O(log n) stack; bounded recursion never gets deep). A blanket warning fires on tons of legitimate code
and trains users to ignore it — which is exactly why **OCaml and GHC don't warn on non-tail recursion
by default.** So the principled version is **off by default** (a `--warn-stack` lint level /
annotation-suppressible), scoped to self-recursion over a **recursive data structure** in non-tail
non-TRMC position (the `length (x::xs) = 1 + length xs` accumulator-able shape), NOT all non-tail
recursion.

**Why parked:** QoL diagnostic, off the canonicalization critical path. Needs TRMC's classifier (do
after #56). The complement to the TRMC + big-stack stack-safety work, not a blocker.

### Future idea (parked, not scheduled): bare effectful statements (drop `let _ =`)

**Problem (the `let _ =` tax):** sequencing Unit-returning effects (`putStr`, `writeFile`, `set_ref`,
`logLine`, dispatch handlers) is written as a stack of `let _ = action` bindings — ~1450 occurrences
across `selfhost/`. The `_` exists only to give the effect a place in a `let`-chain; the binding
carries no value. Verbose, and `do`-notation doesn't cover it (no monad to thread in plain Unit-IO).

**Idea:** allow a **bare expression as a statement** in block bodies, sequenced by the existing
same-indent NEWLINE — so `putStr header` / `putStr body` on consecutive lines run in order without
`let _ =`.

**Feasibility (already scoped):** *not* a lexer-ambiguity problem. The layout pass
(`frontend/lexer.mdk` `applyNlTop`/`resolveCont`) already makes same-column lines **separate logical
lines** (`col == top` → bare `NEWLINE`, no INDENT), and the only application-across-lines case is a
**deeper-indented** continuation (Phase 137 `resolveCont`), already disambiguated. So `foo\nbar` at the
same column can never be `foo bar` today. Work is:
- **Parser:** add an expr-statement production in block bodies; the one snag is distinguishing a bare
  statement from a binding (`foo x` vs `y = 3`) → `=`/clause lookahead (try-binding-else-expr).
- **Type policy (the real design call):** `let _ = e` *documents* intentional discard; a bare statement
  silently drops `e`'s result — a footgun when a non-Unit result was meant to be used. Pick one:
  require non-final statements be `Unit`-typed (reject accidental drops), or warn on discarded non-Unit
  (cf. GHC `-fwarn-unused-do-bind`). `let _ =` would remain the explicit-discard escape hatch.

**Why parked:** ergonomics, not on any critical path. Threads `frontend/parser.mdk` +
`types/typecheck.mdk` (both compilers if done pre-`lib/` removal). Mirror in `SYNTAX.md`. User deferred
2026-06-21; follow-up only.

### Capability-effects wedge — near-term sequence

**Owning roadmap:** [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §9 (language
work) + [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md) §10 (product/runtime).
Architecture context: the "Targets & the WASM soft-pivot" callout above. Effect
labels also drive [`STDLIB.md`](./STDLIB.md) §"Label refinement roadmap".

**Done (foundation):** effect soundness — propagation/inference, higher-order `<e>`
composition, binding-boundary escape, laundering soundness — gap 1, reference +
selfhost mirror ✅; user-definable fine-grained labels (`effect Foo` declaration) —
gap 2 ✅; cross-module effect label export (`exp_effects` across the loader
boundary) — gap 3 ✅; stdlib capability audit ✅; the minimal **"wow" demo** ✅
(`demo/plugin_good.mdk` + `demo/plugin_malicious.mdk` + `medaka check-policy`: the
malicious plugin buries `fetch` four calls deep; the harness rejects it with the
full call chain). Detail in CAPABILITY-EFFECTS §5a + the Phase 146 entry below.

**Near-term (remaining), dependency-ordered:**
1. **Research pass** — WASI Preview 2 / Wasm component-model capability model;
   edge-host isolation (Cloudflare/Fastly/Fermyon); object-capability &
   effects-as-security literature; competitor scan (MoonBit closest; Grain; Roc).
   TCO + WasmGC viability already verified (STAGE2-DESIGN §2.4b). Output: a findings
   note. Skill: none (research).
2. **Design note + manifest format** — concrete surface syntax + the
   capability-manifest format a host reads, pressure-tested against the 2–3 worked
   plugin shapes in CAPABILITY-PLATFORM.md. Gate before manifest coding. Skill:
   **add-language-feature** (planning).
3. ✅ **Cross-module effect label export** — done (gap 3, 2026-06-07). `pub effect
   Fetch` visible across the loader boundary via `exp_effects` in `module_exports`.
4. **Manifest emission** — emit `[package.capabilities]` from a verified entry
   point's effect row; final Phase 146 item, waits on label refinement
   (STDLIB.md §"Label refinement roadmap").

Downstream (captured, NOT near-term): **Phase 146b** parameterized effects
(CAPABILITY-EFFECTS §6a); the **WasmGC backend** (STAGE2-DESIGN §2.4b); the
**capability platform/runtime** (CAPABILITY-PLATFORM.md §9 open questions).

### Native backend (Stage 2) — build log — ✅ COMPLETE (archived)

The D0–D4 dispatch-staging + native-extern-catalog build log (how the spike
became a self-hosting native compiler) is archived in
[`PLAN-ARCHIVE.md` → Archived native backend build log](./PLAN-ARCHIVE.md#archived-native-backend-build-log).
Current native-backend state + residual gaps: `selfhost/BOOTSTRAP.md`,
`selfhost/EMITTER-GAPS.md`. Forward work:
[Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml).

### Self-host (Stage 1 tail)

#### Known parser gaps (selfhost `parser.mdk`)

Constructs the **OCaml parser accepts but `selfhost/parser.mdk` rejects** — check
here before assuming `selfhost/` can parse a construct (AGENTS.md points here).
The differential `test/diff_selfhost_parse*` / `diff_selfhost_check*` gates only
cover the corpus; these are known holes outside it.

- **Leading-`|` `data` declarations.** Native parser accepts `data T =⏎ | A | B`;
  the frozen OCaml parser rejects them. **Native-only by design; oracle frozen.**
  Auto-resolves at `lib/` removal (native becomes sole ground truth). See
  `LAYOUT-SEMANTICS.md` §9 (AUDIT P-DATAPIPE). Design note: own-line `in` (the `in`
  keyword leading a less/equally-indented line after a `let`) is **rejected by both
  parsers by design** — no `parse-error(t)` feedback loop; see `LAYOUT-SEMANTICS.md`
  §9/§11 and `no-parser-layout-feedback` decision memory.

- **SQLite-dogfood findings (2026-06-23, minor — DEFERRED, workarounds exist; affect BOTH
  compilers, so not selfhost-only gaps).** Surfaced building the pure-Medaka SQLite reader;
  also documented in `SQLITE-DESIGN.md`:
  1. ✅ **`record` is a reserved keyword**, so a module file `record.mdk` couldn't be imported.
     **FIXED (2026-06-24, `ff658b2`, native).** `parser.mdk`'s `importIdentFor` now accepts `TRecord`
     (and the obviously-safe `TData`/`TType`) as module-path segments. `import record.*` resolves
     (`test/native_fixtures/keyword_import_record/`); fixpoint C3a/C3b YES.
  2. **`/=` mis-lexes** as `/` then `=` (not-equal is `!=`), producing a *misleading,
     locationless* "Parse error". Diagnostic-quality bug — the lexer should accept `/=` or
     emit a located "did you mean `!=`?" hint.
  3. **Layout parse error**: a leading `let x = e` followed by a multi-line `if/then/else`
     whose `else` branch has further `let`s. Workaround: inline the leading `let`. Worth a
     focused layout repro.
  4. ✅ **Multi-line `->` type signatures** — a type sig split across lines.
     **FIXED (2026-06-24, `ff658b2`, native).** `parser.mdk`'s `tyArrowTail` is now layout-aware:
     after `->` it consumes the trailing `TIndent`/`TNewline` (and unwinds the matching
     `TNewline TDedent`), so `f : Int ->⏎  Int -> Int` parses (`test/native_fixtures/multiline_ty_arrow.mdk`);
     fixpoint C3a/C3b YES. (A bare `skipNewlines` was insufficient — the indented continuation emits
     `TIndent`, not `TNewline`.)
  5. ✅ **Spurious non-exhaustive-match warning on a partial record pattern** (`RowType { width = w }`).
     **FIXED (2026-06-24, `b0cfb71`, native).** `exhaust.mdk`'s `desugarPat` lowered a partial record
     pattern `PRec name _ False` to a sentinel literal the Maranget matrix never recognized as a ctor;
     now lowers to `PCon name [PWild for unmentioned fields]` (declared field order from the Oracle's
     new `ctorFields`), mirroring OCaml `lib/exhaust.ml`. Soundness preserved (genuine non-exhaustive
     matches still warn — negative fixture `test/native_fixtures/real_gap_still_warns.mdk`); fixpoint
     C3a/C3b YES.
  6. **In-module doctests + an UNANNOTATED cross-module function → `unbound constrained fn`.**
     ⚠️ *Original description ("single-file-path parse error") is STALE — that parse error was fixed
     in `e2846d0`; the multi-module doctest path now resolves sibling imports.* What remains
     (reproduce-verified 2026-06-24, native): a doctest expression that calls a function **imported
     from a sibling module** succeeds **iff that imported function has an explicit type signature**;
     without one, `medaka test` fails with `unbound constrained fn: <name>`. **Repro:** sibling
     `lib/user.mdk` exporting `myDouble x = x * 2` (no sig), doctested elsewhere → `unbound
     constrained fn: myDouble`; add `myDouble : Int -> Int` → passes. **Workaround (low-friction,
     already the project style):** give exported functions used in doctests an explicit signature.
     **Root cause — NOT doctest-specific:** the cross-module **bare-name dict-arity collision** (see
     the standing item in [Self-host typecheck / dispatch / runtime — known open items](#self-host-typecheck--dispatch--runtime--known-open-items)
     below). The doctest path synthesizes `__dt_i__ = debug (expr)` bindings and runs them through the
     *joint* multi-module typecheck + dict-pass; `collect_arities` keys arity by bare name (AGENTS.md
     Phase 134 gotcha), so an unannotated cross-module fn gets spurious leading dict params forced on
     and is treated as a constrained fn whose dict is never bound. A signature pins the arity and
     sidesteps it. **DEFERRED by decision (2026-06-24):** the fix means touching dict-passing internals
     during the soak (high-risk/low-reward, clean workaround exists); fix it via the *general* bare-name
     re-key, not a doctest-path patch.
  7. **OCaml-oracle-only false-reject** (native CORRECT): `let w = rtWidth ra` inside a
     `RowType a -> RowType b` body makes the frozen OCaml oracle reject ("signature more general
     than body" / "infinite type involving a"); native accepts + runs correctly. Auto-resolves at
     `lib/` removal. (These sqlite modules are native-only checkable anyway.)
  8. ✅ **Large integer literal (|n| ≥ 2^61) mis-tagged in `medaka build`.**
     **FIXED (2026-06-24, `9a7ace0`, native, emitter — out of self-compile graph so no fixpoint/seed).**
     `llvm_emit.mdk`'s `emitLit` computed the tagged immediate `n*2+1` in the emitter's own 63-bit
     Medaka Int, which overflowed for |n| ≥ 2^61 (e.g. the IEEE-754 bits for `1.0`,
     `4607182418800017408`, built to `-inf`). Now, for |n| ≥ 2^61 it emits a full-width LLVM
     `shl i64 n, 1` + `or i64 …, 1` (via the existing `tagInt` helper); small literals keep the direct
     immediate path unchanged. Fixture `test/llvm_fixtures/lit_int_large_tag.mdk`; `diff_selfhost_llvm`
     182→183, build 35/35.
  9. ✅ **`else let x = e` + indented body — BY-DESIGN, not a bug (2026-06-24, SQLite Phase-2 dogfood).**
     `… else let x = e` with the body on the NEXT line parse-errors **in both compilers** — they
     correctly implement `LAYOUT-SEMANTICS.md` (§11 + §7.1/§7.2). With `else let x = 1` on one line,
     `1` is the last token (`canEndExpr`), so the next line `x + 1` (`canStartAtom`) is absorbed as a
     continuation, not a new block; and the inline `let` form requires `in`. The spec gives the
     analogous failing example (`x = id⏎ let …`). **Valid forms:** `else let x = e in body` (one-liner)
     or `else` on its own line + an indented `let … ⏎ body` block. Documented in SYNTAX.md +
     LAYOUT-SEMANTICS.md §9. (The native parse error was *mislocated* (`2:0`) — IMPROVED `8686e26`: a
     token pre-scan now emits a located, hinted error at the `let` (`inline 'let' requires 'in' …; or
     put 'else' on its own line and indent the block`).)

- ✅ **`let … in` as an indented clause body. CLOSED (both compilers, 2026-06-21).**
  Previously selfhost-only; now both accept e.g. `f x =⏎  let go n = … in go x`.

- ✅ **Lexical-addressing perf hook — eval-consumption half. CLOSED (non-win on
  the tree-walker; 2026-06-05).** Wired `annotateProgram` into the single-file eval
  path and measured: correct (18/18 EVAL goldens byte-identical with `EVarAt`
  consume active; the slot/name assert never fires) but **~2.5% slower** than the
  by-name baseline (`fib 25`), independently re-confirming the earlier finding
  (list-indexed neutral, array frames −14%). Reverted the wiring; the `EVarAt` arm
  stays dormant. The lever's payoff is captured by the native LLVM backend; the
  bytecode VM (§2.2) that previously held this note was removed 2026-06-10. Do not
  re-attempt on the tree-walker. See `selfhost/PERF-NOTES.md`.

#### Self-host typecheck / dispatch / runtime — known open items

Carried from the self-host audit docs; surfaced here so they're locatable from the
[Open issues index](#open-issues-index). None block the soak today (arg-tag dispatch
covers the dispatch ones); they bite when arg-tag retires or structured `requires`
routes land. Detail lives in the owning doc cited.

Carried from the self-host audit docs; surfaced here so they're locatable from the
[Open issues index](#open-issues-index). None block the soak today (arg-tag dispatch
covers the dispatch ones); they bite when arg-tag retires or structured `requires`
routes land. Detail lives in the owning doc cited. **(D7/D8/foldMap reproduce-verified
2026-06-23 as confirmed-latent — not observable on the current binary; D9 closed.)**

- **D7 — `activeDictVars` interface-blind.** Keyed by tyvar id only, not `(iface, id)`,
  so two constraints on one tyvar (`Eq a, Hash a`) could forward the wrong dict slot
  once structured `requires` routes land. **Confirmed LATENT (2026-06-23):** two
  constraints on one tyvar (`(Tagger a, Sizer a) => a`) dispatch correctly on native
  run/build AND oracle — not observable today. Owner: [`selfhost/TYPECHECK-AUDIT.md`](./selfhost/TYPECHECK-AUDIT.md) §D7.
- **D8 — `annotate.mdk` `DoLet` ignores `rec`.** The `DoLet` arm annotates the RHS
  before pushing the binding, so a `let rec` inside a `do`-block can't see its own name
  during annotation. **Confirmed DORMANT (2026-06-23):** `annotate.mdk` is the reverted
  lexical-addressing pass — NO driver runs it (eval.mdk:966-974), so this is dead code; a
  recursive do-let works on native run/build/oracle. Fix only if `annotate` is ever
  reactivated. Owner: [`selfhost/TYPECHECK-AUDIT.md`](./selfhost/TYPECHECK-AUDIT.md) §D8.
- **D9 — `@Impl` named-instance-selection hint — ✅ DONE (2026-06-23, `45d52f7`, native).**
  Was a REAL observable divergence (the audit's "→VUnit" symptom had shifted to native
  `check` rejecting `combine @Additive` as `Unbound variable: @Additive`; oracle returned
  `7`/`12`). Ported to native per [`AT-IMPL-PORT-DESIGN.md`](./AT-IMPL-PORT-DESIGN.md): the
  feature was ~80% present (parser/resolve-exemption/named-impl-key-storage/`VTypedImpl`
  value-rep done); added the typecheck `EApp(f, EVar "@hint")` arm + `currentImplHintRef`,
  stamped `RKey` with the named impl key (reuses C7 narrow-by-key — no new value variant),
  an eval arm dropping the stray hint node, and the emit-path (`core_ir_lower.mdk`) hint-drop.
  Unknown hint → clean `No impl named 'X' found for …` (`UnknownImplName`), not `Unbound`.
  Byte-identical to the oracle on check/run/build (`7`/`12`); fixpoint C3a/C3b YES
  (orchestrator-re-verified); gates incl. llvm 181 / build 35 / diff_native_cli 100/0.
- **`foldMap` Monoid-default seed emits `RNone` on the LLVM path** (emitter falls back to
  arg-tag — safe now, wrong when arg-tag retires). **Confirmed LATENT/safe-now (2026-06-23):**
  `foldMap (x => [x,x]) xs` via the Monoid default works on native build AND oracle. Distinct
  from the eval-path `foldMap` dict gap already closed. Owner: [`selfhost/DISPATCH-INVENTORY.md`](./selfhost/DISPATCH-INVENTORY.md) §D3a.
- **Cross-module bare-name dict-arity collision (the D2 re-key / Phase 134 root).** `Dict_pass.
  collect_arities` keys function arity by **bare name**, so when the prelude + all modules are
  dict-passed *jointly*, a genuinely-constrained function in one module (or the synthetic doctest
  bindings) can force spurious leading dict params onto an *unconstrained, same-named or unannotated*
  function elsewhere — its call site then under-applies / it becomes a constrained fn whose dict is
  never bound. **Observable manifestation today:** the doctest finding #6 above (an unannotated
  cross-module fn in a doctest expr → `unbound constrained fn`); workaround = annotate the fn.
  **Principled fix = re-key arity by module-qualified name (DICT-CONFORMANCE "Option B", deferred
  net-negative there as a zero-observable-gain cleanup).** That earlier deferral predates the doctest
  manifestation, which makes the re-key now *observably* useful, not just hygienic. Higher-risk
  (AST-origin threading through resolve/ast/typecheck/eval — AGENTS.md Phase 134 documents how this
  area repeatedly mis-diagnoses); do it **supervised**, not as a soak-tail drive-by. Owners:
  AGENTS.md Phase 134 gotcha + memory `project_dict_semantics_spec` (D2).
- **F1b — loader does NOT canonicalize module identity (cross-package double-load). BACKLOGGED workstream
  (2026-06-24, SQLite-write dogfood; well-diagnosed, STOPped per guardrail).** The loader keys modules by
  the dotted module-id STRING (`visitMod`/visited/`acc` in `selfhost/driver/loader.mdk`). The SAME file
  reached via two import spellings — a dep's relative `import lib.byteparser` (rebased to the dep root by
  the F1 fix `ec8c19c`) vs the dep-name `import byteparser.lib.byteparser` — gets two modIds → loads TWICE
  → two copies of its decls/impls → `conflicting impl Alternative` (raised in `typecheck.mdk`
  `checkCoherence`). **Repro:** a `sqlite/lib/` file importing BOTH `byteparser.lib.bytebuilder` and
  `lib.recordenc` (each alone is fine). **Why it's not loader-contained:** path-dedup at load is easy and
  sound (both spellings resolve to a byte-identical path; different packages → different roots → no
  over-merge), BUT `resolve.mdk` `findExports` matches by modId string and each importer's `DUse` is looked
  up by its literal spelling — collapsing the load to one entry makes the OTHER importer's reference fail
  (`Unknown module`). The real fix must make BOTH spellings resolve to ONE canonical module across
  loader+resolve+typecheck+eval (the differential-gated module-identity model). **Options:** (A) rewrite
  each `DUse` to a canonical **dep-prefixed** modId at load (smaller; needs an `owningRoot→depName` reverse
  lookup + correct handling of all `UsePath` variants / self-refs / transitive deps / bare names — over/
  under-merge risk); (B) thread the canonical path into module identity end-to-end (bigger, coordinated).
  **Impact:** the shared `byteparser/lib/bytebuilder.mdk` can't be used alongside `recordenc`; the SQLite
  write path stays self-contained (modest emit-logic duplication). Owner: `selfhost/driver/loader.mdk` +
  `selfhost/frontend/resolve.mdk`. Cheap interim workaround if needed: make `bytebuilder` import-free of
  `byteparser` (move its round-trip doctests to a standalone test file).
- **`CFieldAccess` cross-module record dot-access (emitter limitation, pre-existing, tracked).** The native
  emitter panics `CFieldAccess: unknown field '<f>'` on DOT-access (`r.field`) of a record type imported
  from ANOTHER module — the field-label table is built by scanning `CRecord` ctor exprs in the current
  compilation unit only. Workaround: destructure (`match r { R { field = x } => … }`) instead of `r.field`.
  Surfaced by the SQLite-write P4 API. Owner: `selfhost/backend/llvm_emit.mdk` (the `CFieldAccess` field
  resolution).
- **Pre-existing failing gates (surfaced by the 2026-06-24 full sweep; NOT stale goldens — real
  native-vs-OCaml behavioral divergences; confirmed unrelated to that session's lexer/parser/exhaust
  batch by code inspection):**
  - **`diff_selfhost_effect_hole` — 4 ok / 4 failing.** `reject_sibling` / `reject_computed` /
    `reject_outer_computed` + a WS-2 outer-let row all report `native_rejected=0, ocaml_rejected=1` —
    i.e. **native ACCEPTS capability/effect programs that the OCaml oracle REJECTS** on α-precision
    grounds (native less strict). Potential **capability-soundness gap** (or the gate encodes
    behavior native's WS-2 α-precision never shipped). Effects-roadmap WS-2 territory; needs a
    dedicated effects-session diagnosis (is native genuinely under-rejecting, or is the gate ahead of
    native?). Owners: `EFFECTS-SEMANTICS.md` / memory `project_effects_semantics_spec` (WS-2).
  - **`diff_selfhost_lsp_b4` — 5 ok / 1 failing.** `completion empty prefix → full env == OCaml
    (incl alpha,beta)` — native completion environment differs from the OCaml set. Cosmetic-ish
    (completion list), not a soundness issue. Owner: `lib/lsp_server.ml` ↔ selfhost LSP.
- **Helper duplication (code quality).** ~38 generic-helper clusters duplicated across
  selfhost stages; `joinWith`/`joinNl` in `typecheck.mdk`/`eval.mdk` are O(n²) local copies
  despite the O(n) canonical in `support/util.mdk`. Consolidate into `support/`. Owner:
  [`selfhost/HELPER-CENSUS.md`](./selfhost/HELPER-CENSUS.md).
- **Deferred design seams (not pending work, tracked for provenance):** the `set_ref` write
  barrier (needed only if Boehm GC is ever replaced — [`selfhost/RUNTIME-DESIGN.md`](./selfhost/RUNTIME-DESIGN.md) §7);
  TRMC Phase 2 F1(b)/F2(b) + the Phase 3 b′ dispatch variant (no corpus target; emit seams
  pre-parameterized — [`selfhost/TRMC-DESIGN.md`](./selfhost/TRMC-DESIGN.md)). *(The `panic`
  unwind model is resolved by decision — abort, not catchable — see memory
  `no-catchable-panics-isolation`; not an open item.)*

> **Note for OCaml-compiler tasks below:** the self-host port mirrors the OCaml
> pipeline stage-for-stage (`selfhost/{lexer,parser,desugar,resolve,marker,
> exhaust,typecheck,eval}.mdk`). A change to a *ported* stage in `lib/` must be
> mirrored into the corresponding `selfhost/*.mdk` and re-validated with that
> stage's `test/diff_selfhost_*.sh`, or the differential harness breaks. Changes
> to *non-ported* parts (printer/`fmt`, diagnostics, the CLI driver, doctest) have
> no self-hosted counterpart.

### Compiler / language

- **Unqualified-import name collision — use-time ambiguity error — ✅ DONE (2026-06-23, `421a4bd`,
  both compilers).** Two non-`core` modules exporting the same unqualified standalone (e.g. `map`
  and `set` both export `size`/`fromList`/…; also `list`+`set` share `singleton`) previously
  produced a SILENT single-binding collision that differed by compiler (native=leftmost-import wins,
  oracle=rightmost) → wrong-module dispatch (native crash / oracle silent-wrong). Now an unqualified
  USE of such a name emits a located `AmbiguousOccurrence(name, modA, modB)` resolve error (Haskell
  "Ambiguous occurrence" / use-time, user-locked over import-time). Importing both but using no
  colliding name STAYS valid; escape hatch = explicit `import map.{size}` groups or a single import.
  Clean on the 3 risky interactions (Bug-C method+standalone single-module shadow still routes the
  standalone; local-binding shadow wins; disjoint explicit groups). Both `lib/resolve.ml` +
  `selfhost/frontend/resolve.mdk` (frozen oracle edited for gate parity, the known exception). Design:
  [`MAP-SET-AMBIGUITY-DESIGN.md`](./MAP-SET-AMBIGUITY-DESIGN.md). Gates: `diff_selfhost_resolve` 16/0,
  `_resolve_modules` 12/0 (incl. 2 new `test/resolve_module_fixtures/` + corpus no-false-positives),
  check/typecheck differentials 0-failing, fixpoint C3a/C3b YES (orchestrator-re-verified). **Note:**
  the surfacing of this was a multi-step soak find — see the Bug-C / container-literal entries below;
  the `dropShadowedExp`/`toList`-shadow theories along the way were red herrings.

- **Bug C — `toList` on an imported `Map` — ✅ DONE (2026-06-23, `0d40398`, native).**
  Native `check`/`run`/`build` now route the bare name `toList m` (for `m : Map k v`) to
  `map.mdk`'s standalone, not the `Foldable` method, byte-identical to the OCaml oracle
  (`run`/`build` → `[("a", 1), ("b", 2)]`). The filed root cause was **stale** — the bug was
  NOT the single-file driver but three layered defects on the **multi-module** `check` path
  (`import map.*` loads map as a 2nd module): (1) `checkModuleFullDiags` seeded `implDecls=[]`
  so `buildStandaloneShadows` never saw map's imported `toList` → empty shadow set; (2) the
  call typed against the rebound *method* scheme leaving the result element free → `debug`/
  `println` mis-dispatch (`intToString: not an Int` garbage at runtime); (3) `pickSchemes`
  first-match picked the method scheme over the standalone. Fix (`selfhost/types/typecheck.mdk`,
  mirrors oracle `lib/typecheck.ml:2293-2329`): thread the full impl universe into the check
  driver; add a standalone-shadow arm to `inferAppExpr` (single-param interface method that is a
  registered importer shadow whose receiver has no impl → type against the standalone, stamp
  RLocal; handles marked `EMethodAt` and unmarked `EVar` heads); `pickStandaloneSchemes` selects
  the concrete-`TCon`-receiver seed entry after `normalize`. Correctly NARROW: `length` on a Map
  (no Map standalone) is still soundly rejected (the oracle over-accepts then panics at runtime —
  native is *more* sound here). Gates: repro flips green; check/typecheck/eval differentials
  0-failing; fixpoint C3a/C3b YES (orchestrator-re-verified). **Follow-on (now ALSO fixed):**
  the `medaka test stdlib/map.mdk` failure first filed here as a "definer-shadow" residual was
  a MISLABEL — bisection showed it was the empty multi-param container-literal typing bug, fixed
  in `98afb77` (see the entry two above). `medaka test stdlib/map.mdk` now passes (40 doctests +
  7 props).

- **Empty annotated multi-type-param container literal — ✅ DONE (2026-06-23, `98afb77`, native).**
  Native `check` rejected `Map { } : Map Int Int` with `Type mismatch: Map vs Map Int` where the
  oracle accepts (`run`/`build` → `0`). Non-empty `Map { 1 => 10 }` and empty/non-empty `Set { }`
  (1-param) were fine — only the EMPTY literal on a MULTI-param container failed. This ALSO
  surfaced as `medaka test stdlib/map.mdk` panicking `no matching impl for dispatch` (the doctest
  harness's arg-tag fallback masked the check failure into an eval panic; map.mdk's `size (Map { }
  : Map Int Int)` doctest is the trigger). **Investigation note (3 wrong diagnoses before the
  real one):** first filed as a "definer-shadow `toList`/`Foldable`" eval-dict bug, then as
  `dropShadowedExp` being too narrow — BOTH disproved by minimal repros. A strict mechanical
  bisection found the true trigger; the `Ord k`/`FromEntries` framing was a red herring. **Real
  root cause:** the selfhost parser can't distinguish an empty `Map { }` from `Set { }`
  (`classifyBrace`, `selfhost/frontend/parser.mdk:727`, finds no `=>` entry → `ESetLit "Map" []`),
  so desugar pins a UNARY `Map _a` (wrong arity for binary `Map k v`) and the `EHeadAnnot` unify
  `Map _a` vs `Map Int Int` fails. **Fix** (`selfhost/types/typecheck.mdk`, `inferHeadAnnot`,
  mirrors oracle `lib/typecheck.ml:2554` Phase 114): rebuild the head-pin from the head tycon's
  DECLARED arity (`dataParamKindsRef`) instead of the literal annotation — `applyParams (TCon n)
  (freshVars arity)`, element vars ground via inference. Gates: repro flips (check/run/build → `0`,
  empty/non-empty Map+Set all correct); `medaka test stdlib/map.mdk` → 40 doctests + 7 props, 0
  failed; check/typecheck/eval differentials 0-failing; fixpoint C3a/C3b YES (orchestrator-
  re-verified). **Note:** importing both `map.*` and `set.*` in one file collides on
  `size`/`fromEntries` — pre-existing, unrelated, surfaced only in a combined-import test harness.

- **Num-polymorphic numeric literals — ✅ DONE (2026-06-16, both compilers, run + build).**
  Integer literals in expression position are `Num a`-polymorphic in BOTH the OCaml oracle and
  the selfhost/native compiler; `x : Float; x = 0`, `1.0 + 2`, `g : Float -> Float; g x = x + 1`,
  and **polymorphic literal-bearing fns** (`inc x = x + 1` applied to `2.5` → `3.5`) all typecheck,
  `run`, AND `build` correctly (oracle == `medaka run` == `medaka build`). Full design + locked
  decisions: [`NUMLIT-DESIGN.md`](./NUMLIT-DESIGN.md). **Landing log:** Stages 0-2 OCaml (`eac278b`);
  Stages 3-4 selfhost+native (`7424b64`); **soundness fix** OCaml (`e7031e6`) + selfhost (`183b7b4`);
  **emitter Gap E/C4 closure** (`a8b95d7`). Mechanism: a transparent `ENumLit` AST node (renders
  identically to `ELit (LInt n)` so sexp/round-trip unaffected) carries a `Num` obligation; a
  **defaulting pass** at every generalization boundary grounds an *ambiguous* Num-constrained var
  (not arg-reachable) to `Int` (MR-for-Num, locked §0.2); a post-HM stamp elaborates the literal —
  concrete-Int → `LInt`, concrete-Float → `LFloat`, **still-polymorphic `Num a` → `fromInt n`
  (dict-dispatched)** so it honors Float at runtime. Locked scope (§0): **integer literals only**
  (no `Fractional`; `1.0` stays `Float`), patterns stay `Int`.
  - **Soundness hole found by verification + closed:** an interim version elaborated a polymorphic
    literal to a static `VInt`, so `inc 2.5` typechecked but panicked at runtime; the `fromInt`-routing
    fix (`e7031e6`/`183b7b4`) makes a surviving-polymorphic `Num` literal dispatch through the
    enclosing `Num` dict, like `core.mdk`'s `fromInt 0`.
  - **Pre-existing emitter gap #11 EXPOSED + closed (Gap E / C4 residual, `a8b95d7`):** the native
    emitter seeded a poly-`Num` param as `LTNum` (→ runtime `@mdk_num_*`) only when the fn had an
    explicit signature; an *unannotated* poly-`Num` fn at Float (`dbl x = x + x`) defaulted to
    `LTInt` → integer `add` on the Float box → silent garbage on `medaka build`. Fixed by seeding
    `LTNum` for any unannotated arith-used param + a `reservedCtorsOfType` fallback for the
    List/Option/Result/Ordering Foldable-dispatch sibling. Fixpoint C3a/C3b held byte-for-byte.
  - **Soak found 3 more native/oracle divergences (all closed) — #11 was bug-dense:** (3) native
    `check` accepted `g = f "hello"` (`f : Num a => a -> a`, a concrete `Num String` obligation at a
    let-binding) → typechecked then crashed; the selfhost constraint tracking was fused with the
    dict/emit machinery and empty on the plain check path — fixed with always-on
    `schemeObligationsRef`/`checkCallObligations` mirroring the oracle's `is_concrete` (`68d9da1`).
    (4) two typecheck differential gates went blind (goldens from a no-prelude probe that #11's
    `1`→`fromInt 1` breaks) — re-rooted onto the prelude-aware oracle (`bee51ba`, test-only).
    (5) native didn't apply **value-level** `Num` defaulting (`nums = [1,2,3]` → native `List a`
    vs oracle/§0.2 `List Int`) — the no-prelude driver wasn't recording the literal's `Num`
    obligation at all; fixed + a specialized default-method-body type error (`4fc5f47`/`18176ea`).
    **Native and the OCaml oracle now fully agree; all diff gates 0-failing, fixpoint C3a/C3b YES.**
  - **Tracked follow-up (capture-infra footgun):** `capture_goldens.sh tc` corrupts literal-bearing
    fixtures NOT in `PRELUDE_DEP_TC` (poly_let, index_default, effects, records, signatures,
    missing_field, unknown_field_create) to `Unbound variable: fromInt` (sourced from the no-prelude
    `tc_probe`). Goldens are currently correct; the trap only bites on recapture. Fix = widen
    `PRELUDE_DEP_TC` to all prelude-dependent literal fixtures. Low urgency, do before the next bulk
    `tc` recapture.
  - **Remaining (optional cleanup):** revert the `sum`/`product` `fromInt 0/1` workaround in
    `core.mdk` to literal `0/1` — **NOT safe** (the OCaml oracle's `fromInt`-routing misses the
    point-free seed position → it panics on Float while native is correct; see memory
    `project_oracle_fromint_pointfree_gap`). Keep the `fromInt` form. Closed as won't-do.

- ⭐ **Phase 146 — Capability-safe effects (the headline wedge). IN PROGRESS.**
  Make Medaka's existing effect rows **sound + fine-grained** so a function's type
  becomes a compiler-verified **capability manifest** — "the program tells you (and
  the host that runs it) exactly what it can do." Target: WebAssembly edge / plugin
  / sandboxed compute for untrusted, increasingly AI-generated modules. **Effect
  *tracking*, NOT algebraic-effect *handlers*** (no `perform`/`handle`/`resume`; the
  host is the handler). Effects stay **erased at runtime** (manifest is metadata).
  Skill: cross-cutting → **add-language-feature**. **Note:** deliberately revisits
  the *row-polymorphism* rejection in PLAN-ARCHIVE §8, narrowed to *effect* rows.
  - **Full design, per-piece status, and the implementation log live in
    [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §5a.** The near-term sequence
    is the [Capability-effects wedge](#capability-effects-wedge--near-term-sequence)
    section above.
  - **Done:** gap 1 (soundness — propagation, laundering, directional subsumption),
    reference + selfhost mirror ✅; gap 2 (user-definable `effect Foo` labels) ✅;
    gap 3 (cross-module label export, `exp_effects` across the loader boundary) ✅ (2026-06-07).
  - **Remaining:** manifest emission (final Phase 146 item, waits on label refinement);
    **Phase 146b** parameterized effects `<Fetch "x.com">` /
    `<KV "ns">` (designed in CAPABILITY-EFFECTS §6a, follows gap 2).

- ~~**Phase 145**~~ **DONE.** See PLAN-ARCHIVE.md.

- ~~**Phase 143**~~ **DONE.** See PLAN-ARCHIVE.md.

- **Phase 101 — drive property generation/shrinking through the `Arbitrary`
  interface (101b). DEFERRED, reassess later.** 101a (registry-first
  `arbitrary`/`shrink`, native element recursion) is DONE (PLAN-ARCHIVE.md). What
  remains — **101b**: synthesized typed generators + parametric `core.mdk`
  `Arbitrary` impls. Phase 83/84 made single-level interface-driven generation
  work, but **nested** parametric elements (`List (List Int)`) still fail — the
  flat `VDict of string` dict can't carry a recursive element dict. Since 101a
  already handles every case *including* nesting and makes hand-written element
  impls win, 101b's only unique gain is honoring a user's custom
  container-*generation* strategy — niche. Revisit only if that need arises (also
  wants structured/recursive dicts, same as Phase 83/84 #5). WIP on branch
  `claude/suspicious-sammet-21d73e` (commit `860ba12`). Skill:
  **add-language-feature** (cross-cutting).

- **Phase 148 — ✅ DONE (2026-06-16, `7d755a9`, both compilers) — diagnose duplicate / non-contiguous top-level bindings.**
  Two same-named top-level bindings separated by other declarations are silently
  **coalesced into one multi-clause function** instead of being flagged. Symptoms,
  verified on the binary:
  - conflicting type sigs → a confusing `Type mismatch` reported at the *first*
    binding's body, with NO mention that a duplicate exists elsewhere (this cost a
    real debugging loop while adding `cellTag`'s helpers — an accidental second
    `indexOfStr` 600 lines from the original surfaced only as "Option Int vs Int");
  - matching sigs → silently accepted, the later definition becoming **dead clauses**
    with no warning.
  The resolver already detects `Duplicate constructor: Bar`, so duplicate-detection
  exists for the *constructor* namespace but not for value/function bindings, and
  there is no "equations must be contiguous" check (Haskell errors *Multiple
  declarations of foo* here). Fix: in `resolve` (+ selfhost `resolve.mdk` mirror),
  treat a same-named top-level binding separated from its earlier clauses by an
  intervening declaration as an error (`DuplicateBinding` / "clauses of `foo` must be
  contiguous"); adjacent multi-clause stays valid. Lands in resolve + diagnostics,
  not the typechecker — a missing diagnostic, not a unification change. Low blast
  radius; high debuggability win. Skill: **add-language-feature** (resolve-rooted).

- **Phase 149 (proposed) — record rest-capture pattern + construction spread sugar.**
  Surface sugar for the "transform some fields, keep the rest" idiom that recurs all
  over the compiler passes (`annotateDecl`, `desugar`, etc.):
  ```
  annotateDecl DInterface { methods, ...rest } =
    DInterface { methods = map annotateIfaceMethod methods, ...rest }
  ```
  desugars to today's record/variant update — `DInterface { rest | methods = ... }`.
  **Scope decision (locked 2026-06-09): FULL rest semantics, NO row polymorphism.**
  `rest` binds to the **whole scrutinee** at the *same nominal record type* (it still
  carries the captured fields — harmless, the explicit field overrides it on the
  construct side). So this is **same-nominal-type only**: you cannot spread `rest`
  into a *different* constructor, and `rest.field` for a captured field returns the
  *old* value. The cross-type version (a standalone "type-minus-fields" value) needs
  row/structural records — **explicitly out of scope** (stays on the PLAN-ARCHIVE §8
  / "Won't-do" row-polymorphism rejection).
  - **Why it's cheap:** both halves land on existing nodes. Construction spread →
    `EVariantUpdate` (named-field ctors, `ast.ml:160`/`eval.ml:1051`) or
    `ERecordUpdate` (bare record types). Pattern rest-bind → bind the matched
    `VCon`/`VRecord` value (`eval.ml:431-466`). No new typecheck/eval *machinery*,
    no new runtime value shape.
  - **The work (thread through the pipeline + selfhost mirror):**
    1. **Parser** (`parser.mly:538`, `record_pat_rest`): the rest tail is currently
       an anonymous `ELLIPSIS` (= "ignore remaining fields"); extend to
       `ELLIPSIS IDENT` to carry a **bind name**. Add `...IDENT` spread to the
       record-construction field list (`parser.mly:805-830`).
    2. **AST** (`ast.ml:39`, `PRec`): the rest flag is `bool` → widen to
       `ident option` so the bound name survives to eval. New construction-spread
       carries the rest source expr (reuse / lower to the update nodes in desugar).
    3. **Typecheck** (`typecheck.ml:1302`): on a named rest, add `rest : <nominal
       record type>` to the env. Confirm `has_rest=true` already relaxes the
       all-declared-fields-must-appear check (it must, for partial mention — verify;
       may be part of the work).
    4. **Eval** (`eval.ml:431-466`): bind the rest name to the matched record value.
       Construction spread is pure desugar → existing update eval, so no new arm.
    5. **Exhaust** (`exhaust.ml:65`): unchanged — rest fields already map to
       wildcards.
    6. **Selfhost mirror** (`selfhost/{parser,desugar,typecheck,eval}.mdk`) +
       `SYNTAX.md` entry + `test/parse_fixtures` / round-trip / eval fixtures.
  - Estimate: ~a day (Full scope). Skill: **add-language-feature** (cross-cutting —
    new pattern + construction syntax through parser/ast/typecheck/eval + selfhost).

- **Phase 150 — ✅ DONE (2026-06-16, `5d11e77`, both compilers) — better error for `do` used on a non-monad.** Implemented via a transparent `EDoOrigin loc expr` node (desugar wraps the lowered do-chain; typecheck raises `DoRequiresMonad` on a non-monad shape). Using `do`
  to sequence IO (a common newcomer mistake, since Medaka IO is **not** a monad —
  imperative IO is a bare indented block, see [[medaka-io-not-a-monad]] / SYNTAX.md
  §"do notation") produces a baffling diagnostic. Verified on the binary:
  ```
  main = do
    println "one"
    println "two"
  -- → 2:12: Type mismatch: a b vs Unit   (caret on the string literal!)
  ```
  No mention of `do`, monads, or the fix; the caret lands on `println`'s argument.
  **Root:** `do` lowers to `andThen`/`pure` in **`desugar.ml` (runs first)**, so by
  typecheck the `do` shape is gone — unification fails deep in the synthesized chain
  with no provenance back to the `do`. **Fix path:** thread `do`-origin provenance
  from the desugaring (tag the lowered `EApp (andThen …)`/`pure` nodes, or keep an
  `EDo` source span) so the typechecker, on failure to satisfy the
  `andThen`/`Monad`/`Mappable` constraint for a do-lowered node, emits a tailored
  `type_error`: *"`do` requires a monad (e.g. `Option`/`Result`); for imperative IO
  sequencing use a bare indented block."* Lands in `desugar.ml` (provenance) +
  `typecheck.ml` (the tailored error) + selfhost `{desugar,typecheck}.mdk` mirror.
  Surfaced when an orchestrated agent misused `do` for IO and mis-filed the failure
  as a "missing IO monad gap" (2026-06-09) — the language is fine; the *diagnostic*
  is the gap. Skill: **add-language-feature** (desugar+typecheck provenance thread;
  not pure harden-typechecker — it needs the desugar tag).

- ~~**Phase 83 / 84 #5 — recursive/nested instance dictionaries**~~ **DONE
  (reference + selfhost mirror, 2026-06-05).** Structured/recursive runtime dicts
  (`VDict`/`VDictHead` + `RKey` routes) replaced the flat impl-key strings;
  `def : List (List Int)` → `[[0]]` etc. on both loader paths. Closing this also
  lifted the Phase 101b nesting limit. Write-up moved to PLAN-ARCHIVE.md (§"Phase
  83/84 residual #5"). No Phase 83/84 dispatch residuals remain.
- ✅ **Core IR: reserved-name collision in `decodeHead`. DONE (2026-06-07).**
  `core_ir_lower.decodeHead` keyed the built-in list/tuple/unit heads by the
  user-facing NAMES (`"Cons"` → `HCons`, `"Nil"` → `HNil`, `"Unit"` → `HUnit`),
  so a user constructor literally named `Cons`/`Nil`/`Unit` aliased the built-in
  head. `check` accepted it and the AST tree-walker ran it correctly, but `ceval`
  panicked `no matching clause in match` (`core_ir_eval.mdk:151`) — `HCons`/`HNil`
  route `headExtract` to the built-in `VList` shape while the value is a user
  `VCon "Cons"`. The 2026-06-07 rep ratification promoted this from latent
  (ceval-only) to real-backend-blocking: the spike's i64-hash immunity (both
  user-`Cons` and built-in list hash to `"Cons"`) does NOT survive the ratified
  dense i32 ctor-ordinal, under which a user `Cons` carries its type's ordinal
  while a name-keyed match still routes to the built-in head.
  **Fix path selected (research):** the two pattern forms — built-in `PCons`/
  `PList` vs a user `PCon "Cons"` — are distinct *forms* only up to `canonPat`,
  which collapsed both onto the bare name `"Cons"`; past that point only the name
  reaches `decodeHead`. So neither prompt option was needed — instead `canonPat`
  now lowers the built-in forms to **reserved synthetic head names** (`__cons__`/
  `__nil__`/`__unit__`, un-writable as user ctors, mirroring the existing
  `__tuple__`), and `decodeHead` keys those. A genuine user ctor keeps its own
  name and lowers to `HCon "Cons"`. This is the lowest-blast-radius fix: **no
  `CHead` shape change**, so no serializer / sexp / consumer churn. The whole
  matrix machinery (colHeads/specializeCon) is pure string-equality and internal
  to `compileTree`; serialized Core IR for genuine built-in lists is byte-identical,
  and `conHeadInfo` maps `HCons` and `HCon "Cons"` to the same `hashName "Cons"`
  tag so the LLVM spike stays green. Regression guard: `test/eval_fixtures/
  adt_user_cons_nil.mdk` (byte-identical across tree-walker, ceval, and the LLVM spike; `test/llvm_fixtures/adt_list_fold.mdk` was unwound from its
  `Node`/`Empty` workaround back to `Cons`/`Nil`.

- **Phase 147 (proposed) — type-directed constructor disambiguation.** Today a
  constructor name must be **globally unique** (resolve rejects `Duplicate
  constructor: Bar`), so `data A = Foo | Bar` and `data B = Bar | Baz` cannot
  coexist — the Haskell-within-a-module model. Two cleaner end-states exist:
  **OCaml-style** (unqualified `Bar` allowed in multiple types, resolved by the
  expected type at the use site; ambiguity warns / annotates) and **Rust/Swift-style**
  (always-qualified `A.Bar`). Recommend **OCaml-style**, because Medaka already has
  the machinery: **Phase 72** added `field_owners` (receiver-directed resolution) so
  record *field* names can be reused across types — this is the same problem for the
  *constructor* namespace, i.e. generalize `field_owners` to ctors. **Coupling to the
  native rep:** the ratified **per-type ctor-ordinal** tag (the LLVM spike's tag
  scheme) is correct *precisely because* a constructor is conceptually owned by its
  type; today's flattened namespace forces the tag to be keyed by globally-unique
  *name* (and the spike's arg-tag dispatch to carry a synthetic type-id alongside the
  ordinal — see `llvm_emit.mdk` `cellTag`). Per-type ctors would let lowering carry
  `(type, ctor)` directly, dropping the name-keyed lookup and the built-in-list
  special-casing. **Scope/cost:** resolver gains ambiguity handling + optional
  qualifier syntax + the `data`-decl/inference coupling; a surface-syntax relaxation,
  not a semantic necessity (the underlying model is already per-type). Not bundled
  with the bootstrap-era tag work. Skill: **add-language-feature** (resolve +
  typecheck, cross-cutting).

### CLI surface (Phase 82, continued)

The design spec lists `new build run check test fmt lsp doc add remove update`;
`check / run / test / repl / lsp / fmt / new` exist, plus `bench`. Remaining
non-package-manager gaps:

- **`medaka build`** ✅ **MVP done (2026-06-09, `39f3318`)** — `medaka build
  foo.mdk [-o out]` compiles arbitrary user programs to native binaries:
  self-hosted emitter (`selfhost/entries/llvm_emit_modules_main.mdk`, run as a subprocess
  capturing IR) → `clang` + `runtime/medaka_rt.c` + libgc → binary.
  `lib/build_cmd.ml`, `test/build_cmd.sh` (build+run+diff vs interpreter oracle).
  Full `core.mdk` prelude supported (the old `max`/`min` + no-DCE block is LIFTED,
  verified 2026-06-18 audit). `import map/set/array/list/string` all work in `medaka build`.
  **Deferred:** a build-artifact CACHE — the serialized Core IR exists
  (`selfhost/core_ir_sexp.mdk` — `cprogramToSexp`/`parseCProgram`, round-trip
  proven; `test/diff_selfhost_core_ir_roundtrip.sh`) but a cache-key strategy
  (content hash of source + transitive imports) + on-disk layout remain unbuilt;
  also install-prefix asset packaging (assets resolved repo-relative today).
- **`medaka doc`** ✅ — done: `lib/doc.ml` + `test/test_doc.ml`.  Comment→decl
  matcher (parallel `Lexer.take_comments()` stream matched by position),
  signature renderer via `Typecheck.pp_scheme` for values / AST renderers for
  types, Markdown output (one `## name` section per public decl).  Single-file
  typecheck path; multi-module follow-up tracked separately.
  **PORTED TO NATIVE CLI** ✅ (2026-06-18, single-file) — `selfhost/tools/doc.mdk`
  (a faithful port of `lib/doc.ml`: `commentBody`/`expandComment`/`findDocForLine`,
  `renderSig`/`ppDataVariant`/`ppRecordFields`/`ppRequiresDoc`, a precise pre-desugar
  `ppTyP` mirroring `Ast.pp_ty_prec` since selfhost `ppTy` drops effect rows) +
  `runDocCmd` in `medaka_cli.mdk`.  Schemes via the single-file
  `checkProgramSchemesWithRuntime` path (like lsp/repl).  Byte-identical to the
  OCaml oracle over `test/doc_fixtures` — gate `test/diff_selfhost_doc.sh` (14/0).
  Known scoped divergence: a value whose inferred scheme hits the native-vs-OCaml
  ambiguous-Num/var-naming defaulting fork renders different type-var names — a
  pre-existing typechecker soak-tail issue, NOT a doc bug (doc renders whatever
  scheme the checker produced); such files are out of the doc corpus.
- **`medaka check --json` multi-file** ✅ **CLOSED** (2026-06-17/18) — `analyzeProject`
  now resolves imports via the loader; a file with `import`s no longer produces
  spurious resolve errors in the JSON output. Single-file path remained as the
  fast-path fallback.
- Skill: none specific (lands in `bin/main.ml` + `lib/lsp_server.ml`).

### Standard library (Phase 19)

**Owning roadmap:** [`STDLIB.md`](./STDLIB.md) §"Remaining work" + §"Label
refinement roadmap" (the effect-label half is shared with the capability wedge).

Core modules 1–9 are **complete** (`core`/`list`/`array`/`string` + `map`/`set`,
hash containers, `io`, `mut_array`, `json`) — see PLAN-ARCHIVE.md. `stdlib/string.mdk`
API frozen 2026-06-03 (Phase 128). Remaining work is incremental additions tracked in
STDLIB.md (verified 2026-06-18 audit): the `<>` Semigroup operator (not lexed at all),
JSON pretty-printer + `ToJson`/`FromJson` codecs, single-codepoint string indexing
(deliberately deferred), and the effect-label refinement steps (`wallTimeSec`→`<Time>`,
`<IO>` split, `panic`/`exit` split). Skill: **extend-stdlib** (user-reserved unless asked).

### Blocked on a package manager (out of scope until one exists)

- `medaka add` / `remove` / `update`, and a `medaka.lock` file.

---

## Won't-do (kept intentional)

- **Phase 78c — multi-module method shadowing.** Investigated 2026-06-01 and
  dropped: the motivating need (`length`/`isEmpty`/`toList` on `Array`) is
  already met by interface impls, and there is no safe export path for a bare
  `length : String -> Int` (it would shadow `Foldable.length` everywhere). The
  real lever, if ever needed, is a `Sized`/`HasLength` interface — which is
  stdlib design, not a compiler feature. (Phase 112 — the *narrower* lever:
  resolve to a local/imported name only when the method has no applicable impl —
  is **DONE** (PLAN-ARCHIVE.md); 78c stays dropped.)
- The broader **rejected-features** list (labeled arguments, active patterns,
  computation expressions, polymorphic variants, first-class modules, row
  polymorphism, macros, lazy sequences, higher-rank polymorphism, custom
  symbolic operators, …) lives in PLAN-ARCHIVE.md §8 with per-item rationale.
  Consult it before proposing any of them so the rejection stays intentional.
