# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–145+, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md). The detailed,
living record of the self-host port is [`compiler/README.md`](./compiler/README.md).

## Current status (2026-07-04) — NEW NORTH STAR: 0.1.0 public preview release

> **Picking up the distribution workstream? Read [`HANDOFF.md`](./HANDOFF.md) first**
> — it has the ranked next actions (start: D2 Track 1 big-stack pthread), the D0
> spike results, and where each task lands.

**The current-phase north star is a public 0.1.0 preview** — the point where Medaka
goes in front of strangers. The compiler is mature; the distance is almost entirely
**outward-facing surface** (distribution, a front door, human docs, release hygiene).
Owning doc: **[`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md)**; the meatiest
technical workstream (native binary distribution) has its own design +
blocker-map doc **[`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md)**. See the new
[North star (current phase) — 0.1.0 public preview](#north-star-current-phase--010-public-preview)
section and the 0.1.0 rows in the [Workstreams table](#workstreams--where-each-roadmap-lives).

Testable statement: *a stranger goes from a link to a working, formatted,
type-checked, running Medaka program in under ten minutes, and every hole they hit
is one we already told them about.* Structure = **funnel** (playground front door →
downloadable native binary for real work) with a **floor** (playground polish, human
quickstart, stdlib docs, public repo, LICENSE, KNOWN-GAPS, `--version`) and a
**ceiling** (native `medaka build` binaries for mac/linux — Val wants it in; the one
unknown is the Linux deep-recursion stack, spiked first per `DISTRIBUTION-DESIGN.md`
§D0). The prior north star (self-hosting → LLVM) is ✅ COMPLETE.

## Current status (2026-07-10) — P0-19 both silent soundness holes CLOSED (rows 12/13); row 10 residual, row 14 deferred. `main` = `ef0874f3`

The two **silent build-garbage soundness holes** are fixed (`ef0874f3`, pure `compiler/types/typecheck.mdk`):
- **Row 12 (d5b)** `useIt x = size x; useIt (Box 3)` and **Row 13 (d9)** `size "hi"` now `check`/`run`/`build`
  all REJECT with a located `Type mismatch: Int vs Box` / `Int vs String` (no binary emitted). Bonus: row 11's
  over-general scheme fixed — `useIt : Int -> Int`, not `a -> Int`.
- **Root cause:** `recordImplObligation` (typecheck.mdk:4453) skipped the impl obligation for every definer-shadow
  name and nothing re-imposed the standalone's declared domain when a shadow occurrence resolved to the standalone
  (argument typed against the poly *method* scheme, not `Int -> Int`). Non-obvious second fact: the single-file
  `check` path runs **no marker**, so shadow heads arrive as bare `EVar` and never reached `inferDefinerShadowApp`
  (matches `EMethodAt` only). Fix: new `enforceStandaloneDomain` imposes the standalone domain on both the marked
  (run/build) path and a new un-marked `EVar` check path (`definerShadowVarHead`/`inferDefinerShadowVarApp`),
  gated by `shadowKeyTableRef` so a receiver *with* an impl still dispatches. Standalone sigs stashed in new
  `definerShadowSigsRef`; single-file `checkProgramSeeded` seeds `shadowKeyTableRef`.
- **Gates (orchestrator-verified):** agreement **22/0** (2 new REJECT fixtures `p0_19_poly_wrapper_shadow` +
  `p0_19_noimpl_domain_mismatch`), llvm 195/0, llvm_typed 44/0, build 60/0, typecheck 14/0, check 77/0,
  **fixpoint C3a/C3b YES**, no re-mint; 5 stdlib definer-shadows + accept cells (d1–d7) unchanged.

**Residual / deferred (not soundness holes):**
- **Row 10 (d4b)** `map size [Box 1, Box 2]` (value position, S4) still `check` ACCEPTs, build prints a *defined*
  `[1, 2]` (dispatches) — NOT garbage. The fix lives in `inferVar`'s resolution of a bare (non-applied)
  definer-shadow name, decoupled from the applied dispatch head (which shares `inferVar`); the applied helpers
  would then fetch the method scheme from `methodIfaceParamsRef` rather than `infer env f`. Genuinely a different,
  broader "which stage owns S4" mechanism — deferred, agent STOPPed here per guardrail.
- **Row 14 (d8)** definer shadow with imported interface+impl → all paths reject `Int vs Box` (loud/safe
  over-rejection). Opposite direction (relax to cross-module dispatch, S6) — a separate feature, deferred by
  decision (out of this batch's scope).

## Current status (2026-07-09) — P0-18 standalone-shadow dispatch FULLY CLOSED incl. importer-no-impl residual. `main` = `cfc4fa5a`

Final residual closed (`cfc4fa5a`): an **importer shadow on a no-impl receiver** (imported `size`,
receiver `Int`, no impl) now `check` ACCEPTs + `build`/`run` return the standalone (4); importer-on-
live-impl still dispatches (3); all definer cases unchanged. 4 path-scoped `typecheck.mdk` changes
(build routing via the mark-pass-seeded mangled-symbol signal; check obligation skips shadows in
`definerShadowNames` ∪ `standaloneValues`; importer detection recognizes a locally-declared
interface; importer dispatch includes the module's own impls). New gate `diff_compiler_check_cli_modules`
12/0; agreement 14/0, build 60/0, llvm byte-identical, fixpoint C3a/C3b YES, no re-mint. **All of
P0-18 (run/check + build + importer/N-way generalization + residual) is now closed.**

**Follow-up ✅ DONE (separate session, `c1ea45d8`):** `SHADOW-SEMANTICS.md` conformance spec
landed — decision matrix (24 cells) + per-stage enforcement table + fixture-per-cell plan
(`test/shadow_fixtures/`, all created, not yet gate-wired). Result: **14 OK / 4 BUG / 3 untested**.
Memory `project_shadow_semantics_spec`.

**Mutability model PIVOTED (user decision 2026-07-09):** drop `let mut` (0 real sites, half-broken,
runtime-identical to `let`); consolidate on the **`Ref` type + `<Mut>` effect** already dogfooded
by the compiler. Beta model: bindings immutable (`=` = declaration only); bare reassignment + `let
mut` → located error pointing to `Ref`; mutation via a NEW **`:=` operator** (`x := v` desugars to
`setRef x v`), read via `.value` (field-access deref; `!` is boolean-not, NOT a Ref reader).
Reserving `:=` for mutation vs `=` for declaration is a deliberate
clarity feature (OCaml/SML-style). Reframed P0-5 = enforcement + `:=` sugar + docs (no branch-write
engine); IN FLIGHT. Design: `qa-beta-2026-07-07/P0-5-MUTABILITY-DESIGN.md` (§4/§5 superseded).

**⭐ Language trim + Ref-ergonomics batch (DECIDED 2026-07-09; queued after P0-5).** Backed by the
read-only `LANGUAGE-SURFACE-AUDIT.md` (dogfood-usage census of every optional construct). Sequence
after P0-5 (shares lexer/parser/desugar/eval). The batch:
- **REMOVE (0 dogfood uses, redundant, low newcomer+future value):** the **`function` keyword**
  (→ RESERVE as a beginner-hint: "use `x => match x` or multi-clause"; `EFunction` arms are
  desugar-dead so removal is exhaustiveness-self-guiding across ~13 files); **backtick infix**
  `` x `f` y `` (Haskell-flavored, redundant with prefix app); the **`let rec … with` mutual-group**
  (keep single `let rec` for local recursive lambdas; drop only the `with` grouping); **`let-else`**.
- **REPURPOSE `!` (boolean-not → Ref-DEREF sugar).** `!x` desugars to `x.value` (the existing Ref
  read — mirrors `:=`→`setRef`; no new eval/emit arm). `not` becomes the SOLE boolean negation
  (already a prelude fn). 0 dogfood `!`-as-not uses → no compiler/stdlib migration. Add a hint on
  `!someBool` → "use `not`". Net: Refs get OCaml-standard ergonomics — `Ref x` / `!x` / `x := v`.
  **Also update P0-5's `R-IMMUTABLE-ASSIGN` error copy** from `.value` to the nicer `!c` once this lands.
- **KEEP-FOR-FUTURE:** compose `>>`/`<<` (foundational point-free FP, near-zero carry cost; pairs
  with the kept pipe `|>`). Everything else audited = KEEP (earned or high newcomer value).
Removal surface is dominated by `test/construct_fixtures/*` goldens + reference docs, not compiler
logic. Verify each cut construct isn't half-baked first; keep LLVM IR byte-identical + fixpoint.

**⭐ Interface-generalization batch (DECIDED 2026-07-09).** Backed by `INTERFACE-CANDIDATES.md`
(dispatch mechanism: operators stay `EBinOp` + a `binopMethod` map + obligation; "already general"
iff it has a `binopMethod` entry). Turn narrow/monomorphic operators into interface-dispatched ones
(like `+`→`Num`, `==`→`Eq`, `a[i]`→`Index`):
- **`++` → `Semigroup`** (HIGH value / LOW cost — do first). Interface EXISTS (`core.mdk`,
  `append : a -> a -> a`, List/String impls) but `++` bypasses it (`inferBinop "++" = arithOp`, no
  `binopMethod` entry, eval `appendVal` welded to VList/VString). Wire like `==`→`eq`: add
  `binopMethod "++" = "append"`, swap `arithOp` for a Semigroup-obligation op, route eval fall-through
  to the stamped method, KEEP VList/VString fast paths byte-identical (fixpoint-safe; verify no re-mint).
- **Unary minus `-x` → `Num.negate`** (LOW cost). `Num` already declares `negate`; `-x` is a hardcoded
  no-op ignoring it. Fold into the same batch.
- **Ranges `[lo..hi]`/`[lo..=hi]` → new minimal `Enum`** (`enumFromTo` + inclusive variant). Fixes a
  real asymmetry: range PATTERNS accept Char (`'a'..'z'` matches) but range EXPRESSIONS reject it.
  Enables `['a'..'z']` + user enums. Stepped ranges (`[0,2..]`) out of scope. New interface + Char/enum impls.
- **SKIP (ambiguity trap):** overloaded list literals `[1,2,3]`→`FromList` and string literals→`IsString`
  (bare `[…]`/`"…"` have no head-pin to disambiguate — the OverloadedLists can-of-worms). KEEP monomorphic.
- **Keep narrow (rejected):** `&&`/`||`/`if`-conditions (truthiness footgun), `!`/`not`, `::`, `|>`/`>>`/`<<`.

## ⭐ Pre-beta sequencing (DECIDED 2026-07-09, soundness-first)
1. **P0-5** ✅ DONE (`31f4ea80`+`b80ea8c7`, merged `36228029`): `:=` write operator (→`setRef`), `R-IMMUTABLE-ASSIGN` on bare reassignment, `let mut`→parser error (all `mut` LOGIC stripped; the `DoLet`/`ELet` Bool field kept inert+commented — full field removal was ~87 sites/18 files incl. s-expr round-trip, the documented balloon). Read is `.value` (NOT `!`). Verified in Docker: `:=` run==build, reject matrix (reassign/let-mut REJECT, shadow ACCEPT), agreement gate 20/0, llvm 195/0 byte-identical, fixpoint C3a/C3b YES, no re-mint.
2. **P0-19** — the 2 silent build-garbage shadow-conformance holes (rows 12/13) + rows 10/14 divergences
   (same class as the just-closed P0-18 hole; fixtures exist in `test/shadow_fixtures/`). SOUNDNESS FIRST.
3. **Language batches** (all share lexer/parser/desugar/typecheck/eval → strictly sequential):
   trim + `!`→deref → interface generalizations (`++`/negate/Enum) → indexing (`Index`/`IndexMut`;
   design pass then impl; `:=` from P0-5 is its write-side prerequisite).
4. **Remaining P0 bugs:** P0-2 (silent crashes), P0-10 (hash under run), P0-12 (REPL), playground trio
   P0-7/8/9 (needs node≥24 in the Docker image first — a cheap prereq bite).

**⭐ PRE-BETA (user elevated 2026-07-09): typeclass-based `[ ]` indexing — `Index`/`IndexMut`.**
"Affects ergonomics around common data structures a lot" → in the beta, not a fast-follow. A real
language-feature arc (interface(s) + NEW postfix `[expr]` grammar — none today, parser postfix does
only `.` — + desugar + impls + inference check). **Design LOCKED (Shape B, unified multi-param):**
- **Unified multi-param `Index c k v`** covering arrays (k=Int) AND maps (k=key) in one interface —
  NO associated types, NO blessed hatch. Justified by the existing `FromEntries c e` precedent
  (`core.mdk:888`, `impl FromEntries (Map k v) (k, v)`): Medaka's multi-param interfaces dispatch on
  the container head `c` and GROUND the trailing params from the matched impl. Ordinary
  dict-dispatched impls — NOT associated type families → the type-level-programming box never opens.
  User containers can opt in. **Rust names:** `interface Index c k v where index : c -> k -> v` and
  `interface IndexMut c k v requires Index c k v where setIndex : c -> k -> v -> <Mut> Unit` (a
  `<Mut>` setter, since Medaka has no lvalue `&mut`).
- **Revisits `language-design.md:847`** ("prefer HKT single-param; avoid `Collection c e` multi-param"):
  we now BLESS a small curated set of core multi-param interfaces (`FromEntries`, `Index`, `IndexMut`)
  as the sanctioned exceptions — the user's "blessed" instinct, relocated from a new type-system
  mechanism to interface-usage discipline. Update that note.
- **Desugar:** `a[i]` → `index a i`; `a[i] := v` → `setIndex a i v`.
- **Read semantics:** `a[i]` returns the ELEMENT, bounds/key-checked → clean **`E-INDEX-OOB`** /
  key-missing trap (NOT `Option`, even though `get` returns `Option`); the `Option` form stays the
  safe `.get`. Ties into the deferred coded-OOB seam.
- **Impls:** Array, MutArray, Map, HashMap (IndexMut for the mutable ones). **List/trees: OPEN
  sub-decision** — `impl Index List` (O(n) convenience vs the `xs[0]` perf-footgun hint). Design pass.
- **ONE feasibility check for the design pass:** `FromEntries` is 2-param; `Index` wants **3** (`c k v`).
  Confirm the multi-param machinery is arity-general at 3 params (likely yes). **Fallback if not:** the
  blessed-associated-types hatch (allow assoc types for compiler-blessed builtins only). Also lock:
  postfix `[]` grammar precedence, the coded-OOB trap seam, read-in-expression-position inference.
Sequence: after P0-5 lands, run the indexing DESIGN PASS (needs Docker → after P0-5 frees the volume),
then implement. Order vs P0-19 (soundness) TBD — lean soundness-first, indexing design pass can prep
in parallel (read-only).

## Current status (2026-07-09) — P0-18 standalone-shadow dispatch FULLY CLOSED (run/check + build); soundness hole gone. `main` = `01ac360d`

Both halves of P0-18 landed (Opus, Docker-gated throughout):
- **run/check** (`953d9ea1`): per-receiver dispatch in `typecheck.mdk` — `size (Box 3)` → **3** on run, `size 3` → **4**. Agreement gate 13→14/0 (Theme 1 closed on the exit-code predicate). DIAGNOSE-FIRST corrected the filed root cause (no unification "leak"; the occurrence was typed against the standalone scheme).
- **build soundness hole** (`0b4a7882` Part A + `01ac360d` Part B): `medaka build` was silently miscompiling `size (Box 3)` to garbage (exit 0). Fixed via **Option 3** (thread the mangle rename-info into the mark pass so it recovers the shadow post-mangle, marks with the bare dispatch name, and carries the mangled standalone symbol for the `RLocal` fallback) — mangler + pipeline order untouched. Build now → **3**; N-way → 3/30/4. Also fixed a second bug (element-type loss in `inferDefinerShadowApp` → SIGSEGV in Map `toList`). **Gates (Docker-verified):** build repro run==build, agreement 14/0, `diff_compiler_build` 60/0, `diff_compiler_llvm*` byte-identical (194/44/15), construct-coverage 139/0, eval 23/0, full suite 76/0/1skip, **fixpoint C3a/C3b YES — NO seed re-mint**. Design/scoping in `qa-beta-2026-07-07/P0-18-BUILD-PATH-DESIGN.md`.
- **Generalization (user override of the design's defer-recommendation):** N-way multi-impl and importer-shadow-on-a-live-impl receiver both already work post-fix.

**Remaining P0-18 residual (DEFERRED, a distinct cross-module seam — not the same soundness class):** an importer shadow on a **no-impl** receiver (`size 3` where `size` is imported) rejects at check + panics on build (run is correct). Needs cross-module registration of the imported shadow's bare name into the consuming module's `definerShadowNames`/`standaloneValues` + a check-path standalone-fallback accept. Filed for follow-up.

## Current status (2026-07-08) — beta-hardening batch 1: 8 P0s landed; run≠check theme largely CLOSED. `main` = `14f8d42d`

Worked the `qa-beta-2026-07-07/FINDINGS.md` queue. Merged (all fixpoint-clean, NO seed re-mint):
**P0-6** (test exit code), **P0-11** (parse-error location — theme 2), **P0-13** (cwd-relative
module resolution), **P0-16** (tuple-call hint), **P0-1** run≠check core (`run`/`build` gate on
`check`'s full diagnostic predicate + print real diagnostics), **P0-17** (impl-completeness
`T-INCOMPLETE-IMPL`), **P0-18 map-function-key** reject, + SYNTAX.md doc fixes. Landed the
FIXTURES.md §3 **run≡check agreement gate** (`test/diff_compiler_run_check_agreement.sh`) — now
**12/13**. **⭐ ONE deferred, DO FIRST next session:** `p0_18_standalone_fn_shadows_iface_method`
dispatch miscompile — user chose the principled per-receiver fix (Option A); full diagnosis +
plan in `qa-beta-2026-07-07/P0-18-STANDALONE-DISPATCH-DESIGN.md`. The current 1-red in `run_gates`
is that known-deferred fixture, not a regression. Full detail: HANDOFF.md top RESUME; memory
`project_beta_qa_sweep_2026_07_07`. Process lesson: strict-sequential heavy builds + `JOBS` cap
(`feedback_serialize_heavy_builds`). Remaining P0 queue (13) tracked; P0-3 (deriving) & P0-5
(mutability) need a design decision before spawning.

## Current status (2026-07-07) — ⭐ BETA-HARDENING QA SWEEP: findings + fixture plan filed in `qa-beta-2026-07-07/` — THE pre-beta triage queue

An 8-agent adversarial QA sweep (beginner-syntax, bindings/mutability, type-system,
numerics/strings, patterns/control-flow, tooling/CLI, test-gap analysis, playground-wasm;
~350 probe programs) hunting the bugs/gaps/poor-UX states a HUMAN newcomer would hit —
especially in the wasm playground. ~125 raw findings deduped into a prioritized queue.
**This is deliberately identification-only: root causes were NOT investigated** (one-line
hypotheses at most). Owning memory: `project_beta_qa_sweep_2026_07_07`.

**Where everything lives (all in-repo):**
- **`qa-beta-2026-07-07/FINDINGS.md`** — the master list: **18 P0 launch blockers**, 16 P1s,
  P2/P3 tails, each with severity, class, minimal repro, expected behavior, and a pointer
  (`report#Fn`) into the raw reports. Read its "Cross-cutting themes" section first.
- **`qa-beta-2026-07-07/FIXTURES.md`** — the regression-fixture plan, organized by harness
  (wasm gates, a NEW run-vs-check agreement gate, a NEW build-diagnostics gate, parse-error
  corpus, doctest gate, playground seam smoke), split [bug]-locking vs [pin]-working.
- **`qa-beta-2026-07-07/reports/*.md`** — the 8 raw per-area reports with every repro,
  variation, and the positive-surprise lists.

**How to start fixing (recommended attack order):**
1. **Theme 1 — `medaka run` ≠ `medaka check` (FINDINGS P0-1, plus P0-18/P0-17):** run
   executes ill-typed programs (missing-impl/constraint class) to wrong answers or
   unlocated panics. Decide the enforcement point (likely the run driver's error-kind
   gate in `compiler/driver/medaka_cli.mdk` / typecheck error classification), then add
   FIXTURES.md §3's run-vs-check agreement gate FIRST so the whole class is pinned.
   Skill: debug-pipeline → likely harden-typechecker/add-language-feature per site.
2. **Theme 2 — parse-error mislocation (P0-11):** every body-level parse error reports at
   the decl head `1:0: unexpected \`main\``. One parser-recovery fix (parser rewinds to
   decl start and discards the inner failure position) collapses ~a dozen findings and
   fixes the playground's wrong-line squiggle. This is parse Stage-3-adjacent work
   (see the 2026-07-04 error-quality entry's deferred list).
3. **Crash class (P0-2, P0-3, P0-4, P0-5):** silent SIGBUS/SIGSEGV (deep recursion,
   `xs = 1 :: xs`, refutable-let on native), deriving-on-records broken both directions,
   positional record patterns, mut-write-in-branch emitter panic. Each is an independent
   worktree-able bite; verify with the FIXTURES.md §3 matrix.
4. **Playground trio (P0-7 wasm TCO on un-annotated tail calls, P0-8 worker.js missing
   host imports, P0-9 map+set false warnings/ctor collision)** — the beta's front door.
5. Quick wins meanwhile: P0-6 (`medaka test` exit code), P0-15 (attributes unbind defs),
   P0-16 (tuple-call hint), and the FIXTURES.md "Doc fixes" list (SYNTAX.md corrections).

Overlap notes: P0-3/P1-x items partially overlap already-filed entries below (record
`deriving Display` run/build divergence; hash_map `hashInt`; multi-clause exhaustiveness;
run-path auto-print) — FINDINGS.md is now the superset; reconcile there when fixing.

## Current status (2026-07-06) — playground QA soak + error-message copy pass DONE (`a337ba17`)

A long human-in-the-loop session: the user drove the in-browser playground and reported issues live; each was reproduced, fixed (design→delegate→verify→merge), and re-verified in a rebuilt `playground.wasm`. Then a full **user-facing message copy** review. All error-path → fixpoint C3a/C3b YES throughout, **NO seed re-mints** the entire session (string/message/entry changes only; the committed seed still cold-bootstraps — verified via the fixpoint's step-0 seed bootstrap). Owning memory: `project_playground_qa_and_message_copy`.

**Playground polish + capability (all merged):**
- Header redesign: VSCode brand-mark icon (gold, 20px, centered), tagline trimmed, funnel banner reworked, Examples chip made a full click target (transparent `<select>` overlay), examples rewritten to idiomatic multi-clause + type sigs.
- **Stdlib imports bundled** — 20 pure/wasm-safe modules (`list`/`string`/`map`/`set`/`json`/`array`/`option`/`result`/… ) copied into `dist/` + threaded through `main.js`/`compile.mjs`/the two workers as `stdlib.extra`; `math`/`fs`/`net`/`time`/`io`/`test` excluded (native-only externs trap on wasm). `import list.{reverse}` etc. now work in-browser.
- **Warning surfacing** — the playground silently dropped compile WARNINGS (non-exhaustive `match` compiled + ran, then panicked). New `__MEDAKA_WAT_DIAGS__` marker carries warnings alongside the WAT so they show as squiggles + console notes AND the program still runs.

**Container API rename (`stdlib/{map,hash_map,set,hash_set}.mdk` + `support/ordmap.mdk` + `ir/dce.mdk`):** maps → `get`/`has`/`set`; sets → `has`/`insert`; `has` for membership everywhere; ordered `map`/`set` `lookupMin`/`lookupMax` → `getMin`/`getMax`. NOTE: `insert`→`add` for sets was **reverted** — `add` collides with `Num.add` (arg-tag dispatch picks the Num instance), unfixable by annotation; sets keep `insert`.

**Diagnostic-location + quality fixes (compiler; improve `check`/LSP too, not just the playground):**
- Unknown-import diagnostic now located on the import line (was line 1) — `playground_main.mdk` reused the loader's `unknownModuleIdOf`/`findImportLoc` entry-scan.
- Import-name diagnostic (`import m.{a, bad}`) narrowed to the offending name — added a `Loc` to `UseMember` (F3-style threading through parser/resolve/…), `withResErrorLoc` preserves the per-member loc.
- Parse-error line off-by-one fixed (`emitParseError` fed 1-based `parseErrorLine` into 0-based `cjRange`).
- `main () =` / no-`main` now emit friendly located errors (`W-MAIN-SHAPE`/`W-MAIN-MISSING`) instead of a wasm `unreachable` trap; the squiggle points at the `main ()` head.
- Duplicate unbound-variable diagnostic deduped (`R-UNBOUND` + redundant `T-UNBOUND` at the same loc → keep the hinted one; `diagnostics.mdk` `foldModuleTc`).
- Generic `Parse error` (leftover-token case) now **names the token** (`unexpected \`println\``) + a **layout-aware hint** when the leftover is a line-start token at column > 0 (indentation mismatch). New `describeToken` (lexer) + `leadingIndentAt` (parser).

**Error-message copy review:** `compiler/MESSAGE-AUDIT.md` (census of ~226 user-facing strings, ~65 flagged; tone rare, mostly consistency drift; centralization assessed + REJECTED — dynamic templates, no dedup benefit; standardize in place). Then: an **em-dash → period/colon pass** (82 messages, punctuation-only, 91 goldens proven punctuation-only) and the user's **57 authored copy edits** (rewordings, quoting, capitalization, `ambiguousField` de-persona'd, lint findings restored to `— <verb>` form, `check-policy` emoji dropped). Both merged; `run_gates` 73/0.

### Deferred items from this session (pick these up next)
- **Runtime-trap-format unification** (the biggest; from the message audit's "four-way trap divergence" + the user's deferred copy edits): the four backends trap differently — (1) `eval.mdk`: route the bare `panic "non-exhaustive match"` (~:693) through `runtimePanic`; route the "no 'main' binding" messages (~:2204/2238/2448) through the diagnostic channel; give `main : Async` (~:2452) a code + located form; (2) `stdlib/array.mdk`/`mut_array.mdk` OOB messages → route through the coded OOB path; (3) `runtime/medaka_rt.c` `E-DIV-ZERO`/`E-MOD-ZERO`/`E-NONEXHAUSTIVE` — add a source **loc** (blocked on Core IR carrying source locations — the deeper gap); (4) `typecheck.mdk` `T-EFFECT-PARAM` host-pattern message dedup (`:997`/`:969` share one builder). Needs a bit of design (the wasm backend drops `panic` messages entirely). `mdk_oob` → `[E-INDEX-OOB]` was the one literal piece already done.
- **Type-error span precision** — `No impl of Num for String` (and type errors generally) point at a 1-char `currentLoc` snapshot, not the offending operand's full span. A dedicated typecheck-span pass; it threads through constraint solving (`pendingBinopSites`), affects many type-error locs — do them together, not one-off.
- **Multi-clause FUNCTION exhaustiveness** (investigated, filed): non-exhaustive multi-clause functions (`f Red = …; f Green = …`, missing `Blue`) get NO warning even in native `check` (explicit `match` does). Root cause: they desugar to a `VMulti` dispatch list, not an `EMatch`; the parallel engine (`exhaust.mdk` `checkGroupCovered`) is **gated to guarded clauses only** (`checkGroup`'s `otherwise = []`, ~line 521-524). Fix is one line to remove the gate BUT measured **~524 new warnings tree-wide** (34 stdlib + 490 compiler), overwhelmingly intentional partial functions. A responsible fix = gate removal + per-clause locs + a specific message + a tree-wide cleanup of the intentional partials. Scoped mini-project.
- **Remaining em-dash hint-joins** (rare-path, low value): `loader.mdk` available-modules suffix, `build_cmd.mdk` wasm-tools/libgc-missing errors, and backend-internal `gap`/WAT-comment strings (not really user copy).
- **Placeholder links**: the playground header links (Quickstart/Stdlib/GitHub) + the funnel "Get the native compiler →" are still `href="#"` — need real targets before the public preview.
- **Bare non-Unit `main` — run/build divergence + composite-main emitter crash** (found 2026-07-06). A bare `main` whose inferred type isn't `Unit`/`Async` behaves **3-way inconsistently**: `medaka run` warns (`mainNonUnitMsg`) + prints nothing for ALL types; `medaka build` **auto-prints scalars/strings** (`main = 42`→`42`, `main = "hi"`→`hi`, `main = 6.0`→`6.0`) but **fails on composites** — `main = ("abc", 1.23)` / `main = [1,2,3]` → `error: emitter failed … llvm spike: cannot print an ADT value (slice N: 'main' must reduce to a scalar Int/Bool/Float)`. Three problems: (1) `run` warns while `build` prints — and the `mainNonUnitMsg` "prints nothing for a plain value" text is factually wrong for the build path; (2) the emitter's auto-print is scalar/String-only (no tuple/list/ADT); (3) composite-main build emits an **internal-panic-style, unlocated** error — a 0.1.0 beginner papercut (`main = (1, 2)` should never yield an `llvm spike`). **Design fork:** **(A)** uniform auto-print via the `Debug` instance for all types on BOTH run + build [recommended — best scratch/playground UX, kills the divergence; needs emitter auto-print of composites + `run` to print instead of warn]; **(B)** uniform friendly rejection (main must be `Unit`; drop the scalar auto-print too); **(C)** FLOOR regardless of A/B — route the composite-main emitter path through the same main-shape guard `run`/`build_cmd` use so it yields the friendly located `mainNonUnitMsg`, never an `llvm spike`. (C) is small; (A) is the real feature. ✅ **DONE 2026-07-07 (`5cc879dc`, merged; seed re-minted) — Option A for build + wasm + playground; `run` deferred.** Renderer = `println`/`display` (raw strings). A bare non-Unit value `main = <e>` is rewritten to `main = println <e>`, the **check gate is re-run on the wrapped source** (surfaces underived-ADT cleanly), then emitted — a single in-process mechanism (shared `compiler/driver/main_autoprint.mdk`, wired into the 3 emit entries; NO `build_cmd`/emitter-print change). Verified on the binary: `("abc",1.23)`→`(abc, 1.23)`, `[1,2,3]`→`[1, 2, 3]`, `deriving Display` ADT→ctor; `42`/`"hi"`/`True`/`6.0` unchanged; Unit main not doubled; `main () =` still rejected; **underived-ADT main → clean `No impl of Display for H; add 'deriving Display'`** (native + wasm + playground, not garbage). Gates: `diff_compiler_build` 57/0, `diff_wasm_modules` 30/0, run_gates 73/0, fixpoint C3a/C3b YES. **Two disproven premises along the way** (see design doc): the "in-process re-elaborate is unsound" STOP was itself wrong (double-elaborate = byte-identical IR; the underived miscompile was a *separate* cause — the emit path skips `checkImplObligations`, so the clean error must come from re-running the CHECK gate, not an inline obligation check on the mangled program); and two-process was unnecessary (in-process covers the single-process in-browser playground, which two-process couldn't). **`run` path (interpreter) still keeps its warning — deferred bite.** ⚠️ Minor cosmetic wart: the underived-ADT CLI error prints under a `error: emitter produced empty IR for <file>` wrapper line before the clean diagnostic (surfacing it cleanly needs a `<Panic>` `exit` threading the emit-driver signatures — deferred).
- **Record + `deriving Display` run/build divergence — PRE-EXISTING (surfaced 2026-07-07, not caused by composite-main).** `main = println (P {x=1,y=2})` (explicit wrap, single elaborate) diverges: `run` → `E-NONEXHAUSTIVE-MATCH` crash, `build` → `P 1 2`. A standing bug in derived `Display` for records. File + fix independently of the auto-print work.

- ✅ **Type display drops constraints — DONE 2026-07-07 (`bdfb5e59`, merged `7cc9e7e5`).** `ppScheme` now renders the constraint context (`add_ : Num a => a -> a -> a`; multi `elem : (Eq a, Foldable b) => …`). Filed root cause was stale — the `Scheme` carries no constraint list; the real source is `schemeObligationsRef` (populated unconditionally at generalization; `funConstraintsRef` is gated on `dictEligibleSetRef` and empty on the `check --types` path). New `ppSchemeCon`/`ppSchemeNamed` render the body first (fixing `ppMono`'s tyvar→letter `ctx`), then each `(iface, tyvarId)` constraint reusing that ctx so letters match the body. Wired into `schemeLines` (`check --types`), LSP hover/completion/inlay, and playground hover. Display-only → recaptured 63 goldens (only the added `=>`), fixpoint C3a/C3b YES, NO re-mint; `run_gates` 73/0.

### 2026-07-07 batch — playground deferred items + docs-review issues LANDED
Design→delegate→verify→merge, isolated worktrees; two batched seed re-mints (cold `bootstrap_from_seed` C3a PASS each). All: fixpoint C3a/C3b YES, run_gates 73/0; wasm gates (node v24) `diff_wasm` 154/0, `_typed` 8/0, `_modules` 31/0, `sqlite` 9/0.
- ✅ **Type-error span precision** — string literals now carry full span (lexer `scanStr` opening-quote offset); binop errors span the whole `l+r`; wrong-arg errors point at the argument; `pendingBinopSites` filed-hope was stale. (`TYPE-ERROR-SPAN-DESIGN.md`.)
- ✅ **Runtime-trap coding** — interp/native: non-exhaustive→`[E-NONEXHAUSTIVE-MATCH]`, no-main→`[E-NO-MAIN]`, native `panic`→`[E-PANIC]` prefix. **wasm: coded traps carry messages** (div-zero→`[E-DIV-ZERO]`, not the engine trap) + **Bool auto-print parity** (`main=True`→`True`, was `true`) → the playground no longer shows a generic "program panicked". (`RUNTIME-TRAP-UNIFY-DESIGN.md`; B4 stdlib coded-OOB seam still open.)
- ✅ **Emit-entry dedup (correct fix)** — extracted byte-identical `runEmit`/`emitModules` into `entry_support.runEmitWith`/`emitModulesWith` (emitTail param); `medaka lint` back to 0 findings.
- ✅ **Duplicate-binding — thorough** (below).

### 2026-07-07 batch 3 — thorough gate sweep + pre-existing bugs + more dogfood fixes (all merged; final re-mint `0f21af02`, cold bootstrap C3a PASS)
**Thorough gate sweep** (every gate incl. the ~40 NOT in `run_gates`): found NO session regressions — all failures were stale goldens (recaptured) or pre-existing bugs (verified identical at session-start). Fixed staleness: `bootstrap_typecheck` (stale ppScheme `.boot_typecheck.golden` + 2 missing since June → 14/14), `selfcompile_lex` (missing `$STDLIB` root, pre-existing since the ordmap→Map migration → 57/0), `diff_native_cli` 32/74→106/0, effect gates (emoji removal from msg-copy), `build_cmd` svm, `wasm/{assemble_check_main,w1}`, dead `question_op` fixture.
**Pre-existing genuine bugs fixed** (surfaced by the sweep): ✅ **`mdk_apply` name collision** — stdlib `apply` vs runtime PAP helper both `@mdk_apply`; renamed helper `__mdk_apply` (collision-proof); `diff_native_stack` 7/0. ✅ **`maximum`/`minimum` over derived-Ord ADT native crash** — MIXED case of GAP-2 phase-b: a method with SOME tagged impls + an interface default never took the default-synthesis path → derived-Ord ADT (only materializes `compare`) matched no `max`/`min` arm → nonexhaustive trap; `emitDispatchChainDefaulted` synthesizes default arms for uncovered tags; `build_construct_coverage` 139/0. ✅ **`lsp_harness`** — missing `Frame` import + gate `--allow-internal`. ✅ **`check-policy` stray eval error** — the accept-path demo `runPlugin` eval hit native-only externs unbound; stubbed them as no-ops in `check_policy.mdk`.
**More dogfood fixes** (guide author): ✅ **Binder type annotations** — `let p: Int = 5` (block-let + `let mut`), `x: Int <- e` (do-bind, was silently DROPPING the binder→Unbound; fixed by expand-to-DoBind+shadowing-let), `go: Int = 5` (where) now parse AND are enforced (negative fixtures per site); parser.mdk only, no re-mint. Residual: standalone where-signature line (`go : Int` on its own; needs an AST slot). Inline PARAM annotations (`(x:Int)=>x`, `f (x:Int)=x`, pattern ascription) intentionally NOT parsed — a **DESIGN DECISION** for Val (signature-driven style). ✅ **Composite-main Display obligations** — (1) composite w/ non-Display element was a **SIGSEGV** (silent blank) → recurse into conditional-instance `requires` → located `No impl of Display for Color`; (2) function-main `Ambiguous`→`No impl of Display for (Int->Int)`; (3) `record`-keyword decl now gets the deriving hint (`DRecord` registered in `dataParamKindsRef`); (4) the auto-print obligation now runs in the `check`/analyze path (`analyzeFrom`) so `check --json`/LSP surface it, pointing at the main body. ✅ **bind-outside-do** — `x <- act` in a bare (non-`do`) block was an internal panic → clean located `T-BIND-OUTSIDE-DO` (symmetric to `doRequiresMonadMsg`).
**Pre-existing, filed (not fixed):** `<-`-in-IO-block is now a clean error (above); stdlib `string` Unicode case-folding (2 doctests, ASCII-only impl — needs a Val decision); `hash_map`/`hash_set` `hashInt` doctest.

### Newly-surfaced issues (2026-07-07, from a docs-review session; reproduced on `main`)
- ✅ **Signed bare-value `main` — FIXED (`5cc879dc`-followup, merged).** The auto-print wrap now drops the stale `main : T` signature (`isMainTypeSig` filter). `main : (String,Float)` / `main : Int` build + auto-print correctly. Original bug detail:
- **[was] Signed bare-value `main` fails to build/run (regression in composite-main auto-print).** `main : Int` / `main : (String, Float)` + a bare value (`main = 42` / `main = ("abc", 1.23)`) → `medaka build` fails `Type mismatch: T vs Unit` (empty IR); the identical program WITHOUT the signature builds and auto-prints. Root cause: the auto-print wrap (`compiler/driver/main_autoprint.mdk`) rewrites `main = <e>` → `main = println <e>` (now `: Unit`) but leaves the explicit `main : T` `DSig` in the module → the re-check sees signature-vs-Unit. Fix: when wrapping, DROP (or rewrite) the `main` type signature. Matters because the quickstart recommends signing all top-level decls — this is the one combo that breaks. **DISPATCHED 2026-07-07.** (`run` still warns for signed AND unsigned — the deferred run-path auto-print bite.)
- ✅ **Duplicate binding — FIXED THOROUGH (`4d598290`, merged).** Not just top-level: added `R-DUP-BINDING` (top-level + let/where groups) and `R-DUP-BINDER` (non-linear patterns `(x,x)`/`Pair x x`, repeated function/lambda params `f x x`, guard binders) in `resolve.mdk`. Legal shadowing (nested-scope `let x` over outer `x`, sequential `let`/do-binds) correctly NOT flagged; multi-clause functions + impl-method reuse NOT flagged; 0 false positives across compiler/stdlib/sqlite. Located at the second occurrence. Residual (deliberate): `DProp` param names (test-only construct). Fixtures added; codes in `DIAGNOSTIC-CODES-DESIGN.md`.
- **NOT reproduced — Array Display:** a report that `main = someArray` fails `No impl of Display for Array String` does NOT reproduce on current `main` — Array has a Display impl (`main = fromList ["a","b"]` auto-prints `[|a, b|]`; `println (fromList [1,2,3])` → `[|1, 2, 3|]`). Likely a stale report. (Note the Array Display format is `[|…|]` vs List's `[…]` — intentional.)

### Pre-existing GENUINE bugs surfaced by the 2026-07-07 thorough gate sweep (all fail identically at session-start `54344aba` — NOT session regressions; the non-`run_gates` gates just weren't being run). Verified real, need SOURCE fixes:
- **`mdk_apply` name collision (`diff_native_stack`, 3 fixtures).** stdlib `apply` mangles to `@mdk_apply` (2-arg define) and collides with the runtime PAP helper `@mdk_apply` (3-arg, declared+called) → `invalid redefinition of function 'mdk_apply'` on `filter_deep`/`filtermap_deep`/`map_deep`. Introduced `0f4f4c11` (2026-07-02, the PAP `mdk_apply` helper). Fix: namespace the runtime helper or prefix user-fn mangling. Backend + re-mint. Repro: `test/bin/llvm_emit_typed_main stdlib/runtime.mdk stdlib/core.mdk test/stack_fixtures_typed/filter_deep.mdk` → two `@mdk_apply`.
- **`maximum`/`minimum` over a derived-Ord ADT — native-emit-only crash (`build_construct_coverage` `maximum_minimum_adt`).** `medaka run` prints `2 0` (correct); native `build` binary crashes `[E-NONEXHAUSTIVE-MATCH]` (empty stdout). A native-emit dispatch bug (not a documented gap). Needs an emit-path source fix + re-mint.
- **`lsp_harness` build fails** — two causes: (a) gate script omits `--allow-internal` (test-only, compiler entries use internal externs); (b) `compiler/entries/lsp_harness_main.mdk` uses the `Frame` type in a signature but never imports it (`Unknown type: Frame`) — a one-line source fix. Both confirmed to fix the build.
- **stdlib `string.mdk` Unicode case-folding (2 doctests).** `toUpper "Straße"`→`STRASSE` and `toLower "HÉLLO"`→`héllo` fail (ASCII-only impl, since Phase 75 `1a009fe6`). Needs a source decision (accept ASCII-only + fix the doctests, or implement Unicode case-folding).
- **UX follow-up:** `check-policy`/`manifest` (static analyses) EVALUATE the program to derive effect rows, hitting native-only externs (`getEnv`/`fetch`/file-IO) unbound under the interpreter → a stray `runtime error [E-PANIC]: unbound identifier: getEnv` line before the correct verdict. The eval-for-effects path should treat native-only externs as effectful no-ops rather than raising unbound.
- `hash_map`/`hash_set` doctests fail with `unbound identifier: hashInt` on unmodified `main` — a real pre-existing bug.
- `bootstrap_typecheck.sh`: `type_alias_param` / `value_restriction_ctor` fixtures (added `d4f4f411`) have never-committed `.boot_typecheck.golden` files.
- `test/native_fixtures/run.sh` `brace_block_if` expects an em-dash brace message the current binary emits with a period (pre-existing wording drift).
- `error_quality_fixtures/*.out` had caret/located-parse drift vs the current binary (partly recaptured this session during the copy pass); a clean full recapture of that grading corpus is owed.

## Current status (2026-07-05) — browser stack overflow FIXED: general dispatch-GRAPH TMC (b′ Stage 3) linearizes the lexer LAYOUT family; playground Run works in-browser again (`921b9126`)

**The in-browser playground `Run`/squiggles stack overflow is CLOSED.** A freshly-built `playground.wasm` (current compiler) had been trapping `Maximum call stack size exceeded` in the ~0.5 MB browser worker. Diagnosed → spiked → fixed, all this arc; owning doc `BROWSER-STACK-DIAGNOSIS.md` (§1–7 diagnosis + feasibility spike), `WASMGC-TRMC-DESIGN.md` (AS-BUILT); memory `project_playground_workstream`.
- **Root cause (not what the docs said):** NOT the lexer `scan` spine (`b′` already linearized that) — a SECOND uncovered recursive family, the **offside-rule LAYOUT pass** (`layout ↔ flushCloseGo ↔ applyNlTop ↔ popDedents ↔ wouldIndent` + the `layoutPairs` mirror), O(#lines) deep on the PRELUDE (`core.mdk`), ~2400 frames. An empty user program overflowed identically → it's the compiler processing the prelude, not user input.
- **Fix = Option B, general dispatch-GRAPH TMC (`b364bc28`, Opus, run by Val in a dedicated session):** extended the WasmGC `b′` analysis (`compiler/backend/wasm_emit.mdk`) from single-function to **strongly-connected dispatch graphs** with pattern-matched roots + cons-on-intermediate-members + multi-cell cons. Linearizes the layout family AND the `string.intersperse` emit-path domino — the whole spine-cons class. **Emitter-only → NO LLVM seed re-mint** (fixpoint C3a/C3b YES). Chosen over the source-rewrite (Option A) to kill the class in one mechanism.
- **One regression caught + fixed (`921b9126`, Opus):** the +517/−259 refactor left `stmtHasFallthrough` non-exhaustive (missing `CSLetElse`/`CSAssign`) → `let-else` wasm emit trapped `E-NONEXHAUSTIVE-MATCH`. Restored the arms (+5 lines).
- **Verified (orchestrator-rerun, force-rebuilt oracles):** browser Run **6/6** (was 0/6), `diff_wasm` **154/0** (b364 alone was 152/2), `diff_wasm_typed` 8/0, `diff_wasm_modules` 28/0, fixpoint C3a/C3b YES.
- **✅ Separate pre-existing `diff_sqlite` 6/3 — FIXED (`f73f97f2`, Opus).** The `inmem_{orderby,leftjoin,aggregate}` probes emitted malformed WAT (`error: duplicate func identifier $mdk_wctor_Some`). Root cause: a latent WasmGC-emitter asymmetry — `noteFuncRef` deduped the `(elem declare func)` by name but `addLifted` did NOT dedup the lifted `(func …)` *define*, so a bare ADT constructor/leaf-extern referenced **point-free at ≥2 sites** (via `emitCtorEtaClosure`/`emitExternEtaClosure`) lifted its `$mdk_wctor_<C>`/`$mdk_ext_<name>` define once per use-site → duplicate identifier. NOT a bisected commit regression — the sqlite ORDER BY/JOIN/aggregate features were the first to reference `Some` point-free twice. Fix: name-keyed `addLiftedNamed` (first-wins) for the two eta-closure lifts; use-site closure structs still emit per-site. Wasm-emitter-only → **no seed re-mint** (fixpoint C3a/C3b YES). Verified (orchestrator, force-rebuilt oracle): `diff_sqlite` **9/0**, `diff_wasm` 154/0.

## Current status (2026-07-04) — playground W2: CodeMirror 6 editor (S1 highlighting + S2 squiggles) + Playwright e2e harness DONE (`d4dca8da`)

**The playground front door got a real editor.** Per `PLAYGROUND-EDITOR-DESIGN.md` (CM6 + stateless-wasm-entries decided with Val; S1+S2 v1 scope), each designed→delegated→browser-verified→merged:
- **CM6 editor S1+S2 (`d5306c81`, Opus):** `<textarea>`→**CodeMirror 6** (vendored 384KB zero-build ESM bundle + import-map, `build_editor.sh` re-rolls; preserves the static-site property). **S1** syntax highlighting via a `StreamLanguage` tokenizer derived from the lexer token census (28 keywords, TUpper-vs-TIdent, nested `{- -}`, string `\{interp}`, hex/bin/oct, operators) + dark theme. **S2** live inline squiggles via a dedicated `language-worker.js` that reuses the existing `__MEDAKA_DIAGNOSTICS__` analyze path — **zero compiler work** (the diagnostics were already emitted in `check --json` shape). NO `.mdk`/emitter change → no fixpoint/seed. Tokenizer 35 tests, squiggle-map 10 tests, existing node integ 8/8+4/4.
- **Playwright e2e harness (`d4dca8da`, Sonnet):** committed `playground/e2e/` (`./run.sh`, `channel:'chrome'` system Chrome, node v24) — 4 browser tests (CM6 mounts, highlighting spans+colors, sample run→stdout, type-error→inline squiggle+gutter+problems) + screenshots. Documented in AGENTS.md. **This is the standing browser-verification path for frontend changes — agents run it, not just the human.** ([[reference_playwright_playground_e2e]]) Browser download is TLS-blocked here → drive system Chrome.
- **Deferred (S3/S4 = the two stateless wasm entries):** hover-types (`hover_main.mdk` wrapping LSP `hoverFor`) + autocomplete (`complete_main.mdk` wrapping `completionFor`) — the CM6 bundle already ships `hoverTooltip`/`autocompletion`, so wiring them later needs no re-vendor. ✅ **2026-07-06 (`13e29e90`, Sonnet): visual/layout redesign + permalinks + examples dropdown ALL DONE** — mockup-first (Artifact, Val picked "quiet column + funnel strip"); unified console, `#code=` share permalinks, 3 embedded e2e-verified examples; e2e harness updated to the new DOM (21 checks green). See RELEASE-0.1.0-PLAN.md §W2.

## Current status (2026-07-04) — distribution: D1 (exe-relative discovery) + D2 Track 1 (big-stack pthread) DONE — native build correctness-complete on mac+Linux (`f5243120`)

**The two native-distribution keystones landed** (each designed→delegated→independently-verified→merged; owning docs `DISTRIBUTION-DESIGN.md` §5 D1/D2, `HANDOFF.md`, memory `project_native_distribution_blockers`):
- **D1 — exe-relative stdlib discovery (`1ce178b6`, Sonnet):** `executablePath : Unit -> <Env> String` extern (mac `_NSGetExecutablePath`, Linux `readlink /proc/self/exe`, realpath-resolved; C `mdk_executable_path` + emitter `isFileExtern` arm + preamble decl) → `MEDAKA_ROOT`/`MEDAKA_EMITTER` default exe-relative in `medaka_cli.mdk`/`build_cmd.mdk` (explicit env still wins). A `medaka` copied outside the repo `run`/`check`/`build`s with no env; in-repo build unchanged. Finding: the file/env/exec extern family is native-only (unbound under `medaka run`'s pure interpreter) so no `eval.mdk` arm was needed. Gates: eval_run 50/0, check 73/0, fixpoint YES.
- **D2 Track 1 — big-stack pthread (`595b303e`, merge `40de5955`, Opus):** emitted `@main`→`@mdk_program_main`; `runtime/medaka_rt.c` owns `int main` spawning a **256MB-stack worker thread via `GC_pthread_create`** (`GC_THREADS` + thread-aware Boehm — the #1 trap: a raw `pthread_create` leaves the worker's stack unscanned → heap corruption). Dropped `-Wl,-stack_size` from all 6 link sites, added `-pthread`/`-lm`. **Linux spike PASSES at the default 8MB stack** (the compiler self-provisions — the deep-recursion overflow is gone on Linux), macOS byte-identical (`diff_compiler_llvm` 194/0, `_build` 53/0). Correctness-complete for ALL recursion shapes incl. tree-depth on both platforms.
- **Seed re-mint (`f5243120`):** the `@main` rename + new `int main` forced a re-mint (the committed seed stamped `@main` → duplicate-`main` link failure). Done via a one-time bridge (old emitter output linked against the pre-D2 runtime → a `mdk_program_main`-stamping bridge emitter → normal native mint). Verified: cold `bootstrap_from_seed` C3a PASS, `selfcompile_fixpoint` C3a/C3b YES, Linux spike PASS off the committed seed.
- **Next:** D3/D4 packaging (Homebrew formula + Linux tarball + release CI matrix) is the path to a downloadable binary. Track 2 (native TMC port) + Track 3 (recursion-depth guard) are independent robustness follow-ups, not launch blockers. Floor items W2–W9 (playground polish, quickstart, stdlib docs, public repo, LICENSE, KNOWN-GAPS, `--version`) are parallel.

## Current status (2026-07-04) — error-message quality: 0.1.0 BEGINNER-FACING pass DONE (freeze-for-preview); corpus 12.04/14 (`01cf6684`)

**0.1.0 beginner-facing error-quality pass — DONE.** Pivot to the 0.1.0 north star reframed the goal from "maximize the 68-fixture corpus" to "**fix what would genuinely frustrate a first-time user** — human-readable errors with actionable locations." A read-only beginner-mistake AUDIT (Python/JS/Haskell/Rust-flavored errors on `check`/`run`/`build`) produced a ranked shortlist; the top items shipped (each design→delegate→independently-verify→merge). **Most of the value is OUTSIDE the graded corpus** (native/CLI behavior), so the corpus barely moved (12.03→12.04) — that's expected, not a miss.
- **Native runtime traps (CRITICAL, `94931df4` div-zero + `95f52ee3` nonexhaustive; Opus; SEED RE-MINTED `670a34ca`):** compiled `10/0` returned RANDOM garbage + exit 0 (bare `sdiv` on zero = UB); compiled non-exhaustive match died with a silent SIGTRAP. Both now abort with `runtime error [E-DIV-ZERO]`/`[E-MOD-ZERO]`/`[E-NONEXHAUSTIVE-MATCH]` + nonzero exit, matching the interpreter (message-only — Core IR carries no source loc → **located native traps deferred**). Emitter zero-check → `noreturn` runtime abort; fixpoint C3a/C3b YES; seed re-minted at checkpoint (cold `bootstrap_from_seed` C3a PASS).
- **Parse-error locations (`dcb71810`, Opus; the big "actionable locations" lever; design `PARSE-ERROR-LOCATION-DESIGN.md`; ZERO golden churn, no re-mint):** parse errors were `1:0`, no caret, no explanation (worst part of the compiler vs. the excellent typecheck errors). **Stage 1** routes all CLI-text parse errors through `ppDiagCliSrc` → located caret + snippet everywhere (incl. run/build/fmt, which used to print a bare `parse error`). **Stage 2** adds beginner foreign-syntax hints via the pre-grammar chain: braces/`for`/`while`/`def`/`function`/`/* */`/`;`, each with a false-positive-safe discriminator (the brace one aborts when `if` shows `then`, so valid record literals `{ r | f = v }` don't false-fire — swept all fixtures, 0 spurious). **Stage 3** (general "unexpected `<token>`" naming — touches the Parser effect signature + re-mint) DEFERRED (user-approved: generic parse errors are already located-with-caret, clearing the preview bar).
- **`medaka check --types` (`a7e5e3ae`, Sonnet):** bare `check` no longer dumps ~120 prelude schemes on a clean file (showed a broken-looking wall) — now prints only the file's own bindings (`main : Unit`); `check --types` restores the full dump. Gated in the CLI only (probes keep dumping → ZERO probe-golden churn); the one CLI gate passes `--types`.
- **`main () = …` silent no-op (`d636097f`, Sonnet):** run/check on a function-shaped or non-Unit `main` was a silent no-op (exit 0, no output — a brutal first 5 min). Now a located warning (`'main' must be a value of type Unit — write 'main = …', not 'main () = …'`). New graded fixture `eval/main_not_value` (12/14). (The `build` path for `main ()` still fails ugly — a separate deferred gap; `main_takes_unit` build fixture stays 3/14.)
- **Resolve fixes (`1f3624ba` #5 + `3a9940a9` #8, Sonnet):** unbound name that IS an export of an imported module → `'reverse' is exported by 'list'; import it with 'import list.{reverse}'` (instead of a misleading edit-distance guess); and the `check` path's `1:0` unbound-var mislocation (it used the placeholder-loc loader while `run` used the located one) → real location. New fixture `resolve/unbound_but_exported_by_import` (13/14).
- **Deferred tickets (verified real, out of this pass):** #7 duplicate-constructor location (needs a `Variant` Loc field threaded through ~86 sites, mirroring the `TyCon` F3 precedent); located native runtime traps (needs Core IR to carry source locs); parse Stage 3; #4b interpreter stack-overflow SIGSEGV (tied to the `DISTRIBUTION-DESIGN.md` deep-recursion-stack blocker); `medaka check`'s prelude-dump was gated not filtered (124-golden churn avoided).
- **Process:** three agents hit the empty-report/waiting failure mode (all salvaged from live worktree edits + independently re-gated); the div-zero fix disproved a "just an error message" framing (it was a correctness/UB bug); measure-first blast-radius checks prevented two noisy landings (unknown-module list pollution, and the 124-golden prelude-dump).

## Prior status (2026-07-04) — error-message quality workstream: runtime diagnostics + typecheck actionable-fix cluster + mechanical sweep + non-exhaustive-warning locations DONE, corpus 11.15→11.90/14 (`a6168237`)

**Non-exhaustive-match warnings now LOCATED in CLI text — L 0→2 (`cdcc2e88`, Opus; re-grade `a6168237`; render-only → fixpoint YES, no re-mint).** The 4 `exhaust/nonexhaustive_*` warnings carried a real loc (the `--json` range was already correct) but the `medaka check` CLI text rendered them loc-free (`Warning: …`) → L=0. Now they render `file:L:C:` + caret, byte-consistent with errors → **all 4 are perfect 14/14**; exhaust stage 10.40→12.00; corpus 11.78→**11.90/14**. Implementation: the shared `runCheck`/`check_main` path is deliberately location-free (feeds the loc-stripped `diff_compiler_check`/`check_batch` goldens), so the fix lives ONLY in `medaka_cli.mdk`'s `checkRoute` CLI flow — it strips `runCheck`'s loc-free `Warning: …` lines from stdout and re-emits each warning `Diag` LOCATED to **stderr** (aligning warnings with errors; the prior loc-free-on-stdout was the anomaly). Verified: only the 1 `native_cli` golden with a warning moved; the 56/15 `diff_native_cli` failures are PRE-EXISTING prelude-growth staleness (ungated, not in `run_gates`; 55 of 56 have no warning so can't be from this change). Every non-exhaustive-match diagnostic (compile warning AND runtime error) is now located.

## Prior status (2026-07-04) — runtime diagnostics + typecheck actionable-fix cluster + mechanical cleanup sweep DONE, corpus 11.15→11.78/14 (`d9589c39`)

**Mechanical cleanup sweep — DONE (`7b085897` + `edbf6a6f` + `7900b7fc`; re-grade `d9589c39`; all error-path → fixpoint YES, ZERO re-mint).** Three small actionable-fix items, scoped first (a read-only pass that DISPROVED the framing on two of three — the parse F5 carveouts already graded 14/14, no `/=` fixture existed):
- **Non-exhaustive-match + missing-impl hints (`7b085897`, Sonnet):** non-exhaustive match now appends the EXACT uncovered witness as a ready-to-paste edit (`… missing case: 'Blue' — add a 'Blue => …' arm, or a '_' wildcard arm`) → F 1→2 on `nonexhaustive_{option,bool,list,custom}`. Missing-impl (`No impl of Eq for Color`) appends `add 'deriving Eq'…, or write an 'impl Eq Color'` → F 0→1, but ONLY for a user-declared data type (`dataParamKindsRef` hit) so builtins that can't derive + un-implementable function types stay hint-free. New `matchWarningHelp` side-channel (mirrors `typeErrorHelpFix`) + `noImpl` help push for `--json`. (Salvaged from an empty-report agent — work was real, independently gated: check_match 11/0, exhaust 5/0, typecheck_errors 52/0, fixpoint YES.)
- **Unknown-module hint (`edbf6a6f`, Sonnet):** `unknown module: collections — available modules: array, async, …, validation` (F 0→1). Enumerates the **stdlib dir only** via `listDir` (sorted/deduped, `core`/`runtime` excluded) — orchestrator caught + fixed a first cut that polluted the list with sibling test-fixture filenames (project-root fallback); stdlib-only is clean + stable. Pure did-you-mean can't fire (`collections` is edit-distance ~8 from every module).
- **Parse `::`/`/=` machine fix (`7900b7fc`, Sonnet):** `--json` now carries a machine-applicable `fix` for `::`→`:` (`P-HS-SIG`) and `/=`→`!=` (`P-BAD-NEQ`) via a message-keyed `parseErrHelpFix` side-channel (NOT a `ParseError` widen). Agent-quality nicety — ZERO corpus movement (CLI text unchanged; the `hs_*` fixtures already grade 14/14), gated by new `check_json_fixtures/{hs_sig_coloncolon,bad_neq}`.
- **Corpus (`d9589c39`):** F axis 0.69→0.81 (the only mover); total 11.66→**11.78/14**. exhaust 9.60→10.40, typecheck 12.04→12.17, resolve 12.91→13.00.
- **⭐ NEW cheap high-value finding (surfaced by the re-grade):** the 4 `exhaust/nonexhaustive_*` warnings are still **L=0** — the human CLI warning text carries NO `file:L:C:` prefix even though the JSON range is already real. Adding the prefix to the warning renderer (`diagnostics.mdk`, `ppDiag`/`ppDiagCliSrc` warning path) is a small change → **L 0→2 on ≥4 fixtures (+~8 pts, ~+0.12 corpus)** — bigger than this whole sweep. Top of the next-work list.

## Prior status (2026-07-04) — error-message quality workstream: runtime `run`-path diagnostics + typecheck actionable-fix cluster DONE, corpus 11.15→11.66/14 (`6e981912`)

**Typecheck actionable-fix reservoir (F-axis) — DONE (Batch A `33ff4422` + Batch B `77b4c032`/`295f263b`; all typecheck error-path → fixpoint C3a/C3b YES, ZERO re-mint; re-grade `6e981912`).** The type-mismatch cluster got Tier-3 *framing* earlier but stayed F=0 (the corpus's weakest axis). Scoping pass (Opus) found the KEY subtlety: F is graded off the human `.out` message text and the human renderer DROPS `help`/`fix`, so the hint must be **appended to the message string** (mirroring the record-field did-you-mean at `typecheck.mdk:~3985`), with structured `help`/`fix` as a JSON/A-dimension complement.
- **Batch A (`33ff4422`, Sonnet) — 4 help-only hints, F 0→1 each:** `apply_non_function`, `if_branch_mismatch`, `list_heterogeneous`, `cons_type_mismatch`. Localized attaches (`notAFunctionHint` at `inferAppNotFunction`; `numlitMismatchHint` discriminated by `numlitCtxKind` at `reportNumOrNoImpl`). Help-only (no single mechanical edit → honest F=1, not inflated). Each 12→13/14.
- **Batch B #6 (`77b4c032`, Opus) — `wrong_arg_type_in_map` reframe, 4-dim lift (C/R/J/F), 8→13/14:** `Type mismatch: a b vs String` (leaked raw tyvar) → `'map' expects a container (like List or Array) here, but got String — pass a List or Array; … convert it with \`string.toChars\` first.` New detector `containerParamScalarArg` in `inferApp`: fires when a callee's next param normalizes to `TApp (TVar…) elem` (higher-kinded container) and the arg is a bare `TCon` scalar. **Sound by construction** — `TApp _ _ ~ TCon n` can only ever FAIL (a real container arg is itself a `TApp` and unifies), so it can't hijack a legit HKT mismatch; option-(b) general (also reframes user-defined container HOFs, not just `map`). Residual: numeric-literal args route through a separate ENumLit sink (out of scope).
- **Batch B #5 (`295f263b`, Opus) — `arg_order_swapped` swap-detection, F 0→2 + machine fix + X 1→2, now perfect 14/14:** two confusing diags (`Int vs String` + `Int literal vs String`) → ONE `arguments to 'greet' look swapped — try 'greet "Alice" 3'.` + a `--json` machine `fix` performing the swap. Detects a 2-arg transposition in `inferApp` when: callee arity exactly 2, both params concrete + distinct, both args literals, in-order fit fails but transposed fit succeeds. **Soundness without trial-unification** (the codebase has no snapshot mechanism): scoped to concrete-params + literal-args so a pure structural `argLitFits` check is EXACT → the suggested swap always typechecks (orchestrator-verified: `greet "Alice" 3` checks clean). 6 over-firing probes pass. Residual: non-literal args / N-arg / non-adjacent swaps fall through (would need real trial-unification).
- **Corpus (`6e981912`):** typecheck stage 11.54→12.04; total 11.48→**11.66/14**. Golden churn = 6 `typecheck/*.out`, no re-mint.

## Prior status (2026-07-04) — runtime `run`-path diagnostics DONE (located text + `--json`), corpus 11.15→11.48/14 (`b58cedff`)

**Runtime-diagnostic channel — DONE (`8f446ff6` text + `37e7ab0d` JSON; all in `eval.mdk`+`medaka_cli.mdk`, error-path only → fixpoint C3a/C3b YES, ZERO seed re-mint since eval/CLI are outside the emitter graph).** The corpus's biggest remaining reservoir: the tree-walking interpreter (`medaka run`) surfaced every runtime error through the bare `extern panic : String -> a` — a naked string, no `file:L:C:`, no code, no JSON (6 eval fixtures stuck at L=0/A=0). Design `compiler/RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md`.
- **Located text (`8f446ff6`, Opus):** a mutable `Ref Loc` (`currentEvalLoc`) set at the single `ELoc` arm (was `eval env (ELoc _ e) = eval env e` — loc discarded; mirrors the OCaml `current_loc`), read by a new `runtimePanic code msg` chokepoint that formats `file:L:C: runtime error [E-*]: <msg>` INTO the panic message (panic is a `noreturn` C-abort → can't stash-and-return). New `E-*` code family (`E-DIV-ZERO`/`E-MOD-ZERO`/`E-INDEX-OOB`/`E-SLICE-OOB`/`E-PANIC`/`E-NONEXHAUSTIVE-MATCH`/`E-LET-REFUTE`/`E-NOT-A-FUNCTION`). Two location bugs the agent found+fixed via the STOP guardrail: the run driver used placeholder-loc `parse` (every span 1:0 → routed through `loadProgramFilesLocated`); and a non-located prelude helper clobbered the user span (fixed by `updateEvalLoc` ignoring the zero-width-at-origin sentinel). Internal-invariant panics ("eval: unsupported node" etc.) left bare as compiler-bug asserts.
- **`medaka run --json` (`37e7ab0d`, Sonnet):** a `runJsonMode : Ref Bool` (default False, set by the CLI `--json` flag) makes `runtimePanic` build a `Diag SevError code msg (Some loc) None None` and serialize it via **`cjAllToJson`** — the exact same serializer `medaka check --json` uses (no import cycle; `cjRangeOfLoc` ignores its `src` arg so no source-text threading needed). Emits the identical `{"files":[{"file":…,"diagnostics":[{code,kind,message,range,severity,source}]}]}` envelope, verified byte-consistent with the check contract. New gate `test/diff_compiler_eval_json.sh` (6/0).
- **Corpus (`b58cedff` re-grade):** eval stage 8.33→12.00; total 11.15→**11.48/14**. Also **decoupled the machine-`fix` requirement from the A (Agent-parseable) dimension** — A now = `code`+`kind`+span JSON (fix is scored under F, not double-counted); rubric row updated in `compiler/ERROR-QUALITY.md`, prior no-fix A=2 grades reconciled as consistent. Gates: eval_run 50/0, eval_modules 4/0, eval_errors 9/0, eval_json 6/0, fixpoint C3a/C3b YES.

## Prior status (2026-07-03) — error-message quality: Tiers 1–4 + `==`→Eq/`<`→Ord + Tier-3 framing + F-axis did-you-mean + Haskell name-alias + syntax carveouts + F3 resolver-diag locations (`44422ddc`)

**F-axis (actionable-fix) did-you-mean batch — DONE (`931cc3d4`; all error-path, fixpoint YES, no re-mint).** The weakest rubric dimension (F=0.33) — extended the suggestion machinery to more error classes:
- **Record-field did-you-mean** (`f7fbe6f4`+`d2bf6221`): `Field aeg does not belong to record Person — did you mean 'age'?` (CLI text + JSON `help`/`fix` with a machine-applicable replacement). Established a reusable typecheck help/fix side-channel (`typeErrorHelpFix`/`pushTypeErrorHelpFixAt` + `diagOfTypeError`) since the typecheck accumulator was a flat `(code,msg,loc)` triple.
- **Unknown-type did-you-mean + dedup** (`b2576242`): `Unknown type: Strng — did you mean 'String'?`; also deduped identical resolve errors (fixed a double-emit).
- **Haskell-alias hint table** (`f6302732`): a curated foreign-name table consulted BEFORE edit-distance (exact-match, higher confidence) across type/value/constructor positions — `fmap`→`map`, `Monad`→`Thenable`, `Maybe`→`Option`, `Just`→`Some`, `show`→`debug`, `Left`/`Right`→`Err`/`Ok`, etc. (16 mappings, each verified vs `stdlib/core.mdk`; `putStrLn`/`putStr` dropped — real externs). Message reads `Unbound variable: fmap — did you mean 'map'? ('fmap' is Haskell; Medaka uses 'map')`; JSON `fix.replacement` stays clean (`"map"`). High-value for the LLM-agent audience (models reflexively write Haskell). Fixtures `test/error_quality_fixtures/resolve/haskell_{fmap,monad,just}.mdk`. Sexp stability (resolve_modules gate) preserved (suggestion not serialized).
- **Also this session:** rebaselined 3 stale OCaml-reference gate goldens to native (`84db1a3a`; `lex_files`/`lsp_b4`/`test`) — pre-existing debt from the 2026-06-26 OCaml removal, unrelated to the diagnostics work.
**F3 — real `Loc` on the 3 `{0,0}` resolver diags — DONE (`9d6398ad`; design `compiler/RESOLVER-DIAG-LOCATION-DESIGN.md`; all loc-only → fixpoint YES, no re-mint, fully sexp-invisible so ZERO golden churn beyond the target fixtures).** Design pass found no positioned type-wrapper exists (unlike expr `ELoc`), so the fix needed new AST loc carriers. **Chunk B (`2d9138fb`):** `DUse Bool UsePath Loc` (captured in `parseImport`) → `R-PRIVATE-NAME` + `R-MODULE-LOAD` (entry-scan) now `file:1:0:` located. **Chunk A (`9d6398ad`):** `TyCon String (Option Loc)` field (decision A2, not a wrapper — avoids silent positional-match breakage; ~40 sites, compile-checked) → `R-UNKNOWN-TYPE` located + machine `fix`, AND every type-position did-you-mean (typos + Haskell type-aliases `Maybe`→`Option`/`Monad`→`Thenable`) now carries an agent-applicable `fix`. Both chunks kept the type/import sexp byte-identical (`tySexp`/`declSexp` ignore the loc) → desugar/mark/resolve_modules/typecheck_golden/positions all unchanged.

**F5 — Haskell SYNTAX carveouts — DONE (`44422ddc`; message-only, error-path only → fixpoint YES, no re-mint).** Friendly parse/lex hints when someone writes Haskell syntax (LLM-agent audience writes it reflexively), via the existing `parseResult` pre-scan chain (the shipped `/=`→`!=` template) + lexer single-char arms. Four SAFE carveouts, each with a verified false-positive discriminator: `\x -> e` (`L-HS-LAMBDA`, "lambdas are 'x => e'"), `$` (`L-HS-DOLLAR`, "apply directly / '|>'"), `case … of` (`P-HS-CASE`, "use 'match'" — discriminated by `case`-ident+`of` with no intervening `impl`), `f :: T` (`P-HS-SIG`, "'::' is cons; sig uses ':'" — discriminated by a **depth-0** decl-head ident immediately followed by `::`, so body/guard/match-arm `::` don't fire). **Dropped `1 : xs` cons** — genuinely ambiguous (byte-identical to a valid Medaka annotation `x : xs`; no safe token discriminator). Message-only (parse errors have no help/fix slot yet — a deferred follow-up could add one, retrofitting `fix` onto `::`→`:` and `/=`→`!=` together). Fixtures `test/error_quality_fixtures/parse/hs_{lambda,dollar,case_of,sig_coloncolon}` + an FP-guard fixture.

- **Open (error-quality follow-ons) — the workstream is now "freeze-for-preview"; these are deferred, none blocking 0.1.0:** (1) **located native runtime traps** — the compiled div/mod/nonexhaustive traps print the message but no `file:L:C:` (Core IR carries no source location; threading it is the invasive part). (2) **parse Stage 3** — general "unexpected `<token>`" naming for the generic residual (touches the Parser effect signature → re-mint; user-deferred since generic parse errors are already located-with-caret). (3) **#7 duplicate-constructor location** — needs a `Variant` Loc field threaded through ~86 sites (mirror the `TyCon` F3 precedent). (4) **`build`-path `main () =`** still fails with an ugly "emitter failed" error (run/check fixed; build not). (5) **#4b interpreter/native stack-overflow** on deep/infinite recursion → bare SIGSEGV (tied to the `DISTRIBUTION-DESIGN.md` deep-recursion-stack blocker — do it there). (6) `redundant_arm` is DONE (`W-UNREACHABLE-ARM`, `c98c166f`). F remains the corpus's weakest axis (0.86/2) — remaining help-only hints have a genuine F=1 ceiling; absolute-floor fixtures `main_takes_unit` (build) + `ambiguous_return` (silent accept) are accept-what-should-error, a harder class than message quality.

### Tier-3 typecheck mis-framing (`00ca0bfa`)

**Tier-3 typecheck mis-framing reservoir — DONE (`00ca0bfa`; corpus re-grade 10.25→10.60/14, the 8 moved fixtures +21, C/R +6 each + X +5).** The corpus's
largest remaining quality reservoir: type errors that surfaced with a misleading
frame. Design doc `compiler/TYPECHECK-ERROR-FRAMING-DESIGN.md` (with AS-BUILT).
Four staged chunks, each independently gated (fixpoint C3a/C3b YES, ZERO seed
re-mint — all error-path-only) + merged: **A** (`f1705a7f`) poisoned-var cascade
suppression — killed the secondary `ambiguous 'Debug a'`/`'Mappable a'` storms on
`too_many_args`/`apply_non_function`/`record_wrong_field`/`wrong_arg_type_in_map`
(X dimension), no over-suppression. **B** was DROPPED after reproduction —
`record_missing_field`'s `No impl of Debug for Person` secondary is a GENUINE
independent error (a well-formed Person still errors it; no auto-derive), not a
cascade; suppressing it would hide a real missing-impl. **C** (`29d1644a`)
context-aware "not a function" reframe (`T-NOT-A-FUNCTION`): `apply_non_function`
→ "…type Int, which is not a function…", `too_many_args` → "'inc' takes 1
argument(s) but is applied to 2." — killed the leaked `a -> b` tyvar. **D**
(`00ca0bfa`) literal-provenance Num-mis-framing reframe: `if_branch_mismatch`/
`list_heterogeneous`/`cons_type_mismatch`/`arg_order_swapped` now show
context-aware structural mismatches ("if branches have different types: Int vs
String", etc.) instead of `No impl of Num for String`; operator-sourced Num
errors (`int_vs_string` `x+1`) correctly UNCHANGED via a narrow before-unify
provenance taint. **Key process win: the design pass's "OCaml-parity blocker"
(Fork 1) was verified FALSE** — the OCaml compiler was removed 2026-06-26, so the
typecheck-error goldens are checked-in *native* output, freely re-capturable.
**Pre-existing stale goldens on main** (`diff_compiler_lex_files` 13/13,
`_lsp_b4` 1, `_test` doctest-summary) fail independent of this work — a recapture
pass is owed as separate tech-debt.

### Prior error-quality landings (Tiers 1–4)

A measure-first push on **error-message quality** (a named project goal, dual human+LLM-agent audience). Owning memory `project_error_quality_workstream`; docs `compiler/ERROR-QUALITY.md` (rubric + copy standard), `test/error_quality_fixtures/` (60-fixture corpus + `INVENTORY.md` + `GRADING.md`), `compiler/TYPECHECK-SIGNATURE-CONSTRAINT-DESIGN.md`, `compiler/EQ-DISPATCH-DESIGN.md`. **Corpus grading moved 8.00 → 10.25 / 14** (+2.25 over the session; the agent-parseable dimension 0.58→1.68 with 49/60 fixtures now at A=2, up from zero; lex stage 6.50→11.25). Each change independently verified (fixpoint C3a/C3b + `diff_compiler_build`/`_check`) and merged; **ZERO seed re-mints the entire workstream** (all fixes are typecheck/resolve/eval/driver, never the emitter).

Landed: **Tier-1 bugs** — `panic` now prints its message (was `unbound identifier: panic`, `32a51317`); `medaka build` on a type error shows the located diagnostic instead of "emitter failed/No such file" (single-file path routes through `check`, `c9790406`); unknown-import silent-exit-1 now emits a stderr diagnostic (`fc2b9cc8`). **`No impl of Alternative for Parser` false positive** fixed (`18080cf2`) — `parser.mdk`'s local `orElse` shadowed the prelude method + scope-blind marker made a phantom obligation; check↔build now agree on obligations. **Missing-constraint soundness check** (`9fddb349`) — a signature omitting a body-required constraint (which severed it for downstream callers → wrong-dict dispatch) is now rejected at the def-site (`Could not deduce 'C a'…`). **`==`/`!=` → Eq** and **`<`/`<=`/`>`/`>=` → Ord** now generate obligations (`e8b05a74`/`27235bd5`): comparing functions or un-derived-Eq/Ord types is rejected (the operators were builtins that bypassed the interface; dispatch was ALREADY routed through the dict via the Phase-151/#21 rewrite, so custom impls were already honored → no emitter work, no re-mint). Fixing the resulting #23 two-hop-forward regression (`8a6c308d`) **generalized** transitive-constraint forwarding for all interfaces. **Tier-2 content:** did-you-mean nearest-name suggestions on unbound names (`b21e08c8`, Levenshtein in `support/util.mdk`); exhaustiveness now names the missing constructor + location (`11808799`, `usefulWitness` Maranget-I). **Lex-error locations** (`dd00f55c`): raw lexer panics → parser-level located messages via a `TLexError` token; `bad_escape` "empty token" leak → `invalid escape sequence '\q'` (`67e82b45` also surfaced it through the panicking `parse` path used by parse_main/loader/eval). **Tier 4 (structured/agent-facing), push-site threading** (design+census `compiler/DIAGNOSTIC-CODES-DESIGN.md`): Stage 1 (`ab61283c`) — every `Diag` carries a stable per-stage `code` (`T-*`/`R-*`/`P-*`/`L-*`/`W-*`) + derived `kind` + a real `range` (warnings no longer `{0,0}`) in the JSON payload, CLI text byte-identical (the JSON-only lever kept churn to ~9 goldens vs ~100); Stage 2 (`761516e6`) — JSON `help` + machine-applicable `fix {range,replacement}` for did-you-mean (an agent can apply it verbatim). **Open (next):** the remaining A-ceiling is the 11 fixtures with no compile-time diagnostic — runtime `run`-path errors (div/mod-by-zero, index-oob, panic) emit no structured channel (biggest lump, the `eval` stage now weakest at 8.33); 3 resolver diags still `{0,0}`-range (capped A=1); `help`/`fix` for missing-constraint/missing-case (the flat `(code,msg,loc)` triple needs to carry structured suggestion data); constructor-vs-variable wording; `main () = …` build message; redundant-arm warning; optional CLI-visible `[CODE]` prefix (deferred — ~100-golden churn). *(Tier-3 typecheck mis-framing — leaked tyvars, Num-mis-framing, cascade storms — is now DONE; see the top status entry.)* `exit` extern unbound in interpreter is parked (its `<Panic>` sig needs dropping to `Int -> a`).

## Current status (2026-07-02) — `medaka lint` expanded 5→~20 rules + fmt trailing-comma record style (`6dbc8918`)

A dogfood session that grew the linter and reformatted for readability. **15 new lint rules** (all merged, each independently verified: clean surface + fixpoint C3a/C3b + lint→0 + zero regressions; the ratchet hook keeps the whole tree at 0 findings): lambda→section (26 sites), if→max/min, andThen+pure→map, destructure-in-param (single-arm irrefutable match on param; shares helpers with rule-match-on-param), missing-signature (=-Wmissing-signatures; exempt `main`), not-eq, bool-simplify, rem-parity, double-reverse, when-unless, complement-predicate (+`isNonEmptyL` helper), match→map (2-arm Option/Result match that IS a functor map, 68 sites), bind-chain→do (suggest-only, min-depth-3; converted 6 pyramids incl. `buildUpdateImage` 8-level → `do`). Plus two lint-rule-driven **cleanups**: dead-code rule (per-file reachability incl. doctest-`>`-line roots) → **excavated 65 dead compiler functions**; concat→interp rule → **rewrote 597 `++` chains to `"\{}"` interpolation** (mostly the two emitters). And a **fmt style change**: wrapped named-field records now format brace-on-ctor-line + trailing commas (pure printer change, emit-invisible, no re-mint; repo reflowed + proven behavior-preserving via rebuild→fixpoint). Method: census-first (read-only Explore agents, parallel) killed 2 subjective rules before building (pipe-chain ~1 site; match→guard 619 lateral sites) and sized the big arcs; an hlint-catalog survey seeded the backlog. Owning memory: `project_lint_rules_expansion` (workflow lessons); builds on `project_medaka_lint` + `project_lint_precommit_hook`. The tree is at **0 findings for all ~20 rules**, and — **MAX RATCHET (`6f0c71c2`)** — the pre-commit hook now GATES **every** rule (all 19 per-file rules in `GATED_LINT_RULES` + `rule-duplicate-body` cross-file): any NEW finding of any rule (style or correctness) fails the commit. Intentional exceptions use inline `-- lint-disable-*` directives; a too-noisy rule can be removed from `GATED_LINT_RULES` (it then still warns under plain `medaka lint`). End-to-end verified (a lambda-section violation is correctly blocked).

## Current status (2026-07-02) — FP stdlib P1 shipped + tuples as a real type constructor (`8c2d24b`)

FP stdlib pass landed (anti-gatekeep naming — friendly names over Haskell jargon; design `FP-STDLIB-DESIGN.md` §0.5, AS-BUILT section). New modules: `validation.mdk` (accumulating-error `Validation e a`, `Applicative requires Semigroup e`, deliberately no `Thenable`), `nonempty.mdk` (`NonEmpty a`, total `head`/`maximum`/`minimum`), `option.mdk`/`result.mdk` (`option`/`result` eliminators). `list.mdk` gained `somes`/`oks`/`errs`/`partitionResults`; `core.mdk` gained `on`/`curry`/`uncurry`/`discard`/`map2`/`map3`/`foldThen`/`repeatThen`/`filterThen`/`forEach`/`runEach`/`guard` plus a new `Bimappable p` interface (`bimap`/`mapFirst`/`mapSecond`) with `impl Bimappable Result` and `impl Bimappable (,)`. Full listing verified against source in `STDLIB.md` Modules 1/2/20–23.

Two compiler changes enabled it, both merged into the same arc:
- **Emitter PAP-in-container fix (`0f4f4c1`):** a partially-applied multi-arg closure stored in a container and later saturated (`map2`/`map3`'s `ap (map f fa) fb` shape) SIGSEGV'd on `build`. Fixed via arity-carrying closure cells + a runtime `mdk_apply` for arity-aware opaque application. See `compiler/EMITTER-GAPS.md`.
- **Tuples as a real type constructor (Stage 1 `a642a43` zero-observable-change, Stage 2 `c00ee2b`):** tuples are now internally `__tupleN__`-headed `TApp` spines; new `(,)`/`(,,)`/`(,,,)`/`(,,,,)` surface syntax (arities 2–5) names the bare unsaturated tuple constructor in type position, which is what makes `impl Bimappable (,)` possible. Design `compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md` (now marked SHIPPED). Seed re-minted (`9671acd`) — the prior seed couldn't parse `(,)`.

**Resolved item from this arc:** a cross-module sibling-impl-emit gap suspected mid-workstream was verified CLOSED on current main (2026-07-02, non-reproducing across 6 shapes incl. the exact fixtures) — almost certainly closed by the Bug-1 emitter fix; now build-guarded via `test/build_diff_fixtures/{bimappable_constrained_sibling,bimappable_tuple_sibling,traverse_parametric_sibling}/` (`diff_compiler_build` 49/0). **Deferred to P2** (per `FP-STDLIB-DESIGN.md`): monoid newtypes, Reader/Writer/State, zipWithThen/Kleisli/asum, Enum, lazy Seq.

## Current status (2026-07-01) — `medaka fmt` hardened (incl. full comment interleaving) → whole repo formatted → pre-commit hook LIVE (`03c7361`)

Dogfood arc: hardened `medaka fmt` (9 fixes — else-if ladder, pattern parens, record wrap, else-block, body break-at-`=`, verbatim comment safety-net, idempotency, **T** single-app body hang-at-`=`, **L Stage 3+4+5** full comment interleaving), proved safe+idempotent repo-wide (0 corruptions/0 non-idempotent), bulk-formatted all non-`test/` source `.mdk` (compiler rebuilt from its own reformatted source → fixpoint C3a/C3b, zero behavior change, **no seed re-mint the entire arc**), and installed a pre-commit hook (`.githooks/pre-commit`) that rejects unformatted staged `.mdk`. **The hook is ACTIVE clone-wide — `medaka fmt --write` changed `.mdk` before committing** (see AGENTS.md). **Comment interleaving COMPLETE** — operator chains (Stage 3+4) AND do/let/block statements (Stage 5) now format with each trailing comment attached across reflow; multi-line-statement / standalone interior comments keep the verbatim safety-net fallback. Every formatter-behavior change shifts the fmt fixed point → a repo-wide reflow follows each (all verified behavior-preserving via rebuild-from-reformatted-source → fixpoint). Repo fully fmt-clean. Details: `.claude/HANDOFF.md` top entry, memory `project_fmt_hardening_and_commit_hook`, design `compiler/FMT-COMMENT-INTERLEAVING-DESIGN.md`.

## Current status (2026-07-01) — tandem SQL: ORDER BY + INNER/LEFT JOIN + DISTINCT + arithmetic/UPDATE-SET-expr + computed SELECT columns (`f4b437d`)

Six tandem SQL features (each works identically native + wasm, auto-gated by `test/wasm/diff_sqlite.sh` — now 9/0), all **pure library** (`sqlite/lib/{select,mutate}.mdk`) → NO seed re-mint / fixpoint concern. Each independently orchestrator-verified vs the real `sqlite3` CLI AND native==wasm, then merged. Continues the dogfood-soak thesis (real library work flushes compiler bugs — none surfaced across all six; every order/join/distinct/arithmetic/projection shape ran `run`==`build`==native==wasm, including the type-lost-Float-prone Float-in-Cell arithmetic). Owning doc: SQLite design docs; memory: `project_sqlite_mutation_and_wasm` (tandem workflow).

- **Computed SELECT columns (`f4b437d`):** added `columns : List SqlExpr` to `Select` (default `[]` = `SELECT *`, byte-identical) + `withColumns` builder. The shared `runOverCells`/`runOverCellsDistinct` tails compile each projection expr via the exported `compileValue` evaluator (against the SAME `lookup`, so projection works over JOINs — `SELECT users.name, orders.total + 10`) and map each RAW surviving row → a projected `List Cell` BEFORE decode; the `RowType` decodes the projected row positionally. `columns=[]` skips projection (byte-identical). `render` emits `SELECT <e1>, <e2>, …`. DISTINCT dedups on the projected values. **v1 limitation:** WHERE + ORDER BY reference ORIGINAL columns on the raw row (ORDER-BY-on-computed deferred). Gates: 9 prior oracles byte-identical, new `projection_oracle.sh` PASS vs sqlite3 (`a+b, name`; reorder/subset `name, id`; computed-over-INNER-JOIN; `DISTINCT a*0`), diff_sqlite **9/0** (`inmem_proj_probe.mdk`).

- **SQL arithmetic + UPDATE…SET `<expr>` (`4d6d502`):** added `ArithOp = AAdd|ASub|AMul|ADiv|AMod` + an `EArith` node to `SqlExpr`, phantom builders `eAdd/eSub/eMul/eDiv/eMod`, and an `EArith` arm on the (now-exported) `compileOperand`/`compileValue` Cell-producing evaluator with **exact sqlite semantics**: NULL-propagation (either operand NULL → NULL), `CInt⊕CInt→CInt` for `+ - *` else `CFloat` (int coerced), integer division truncating toward zero (`-7/2=-3`), `÷0` and `%0 → NULL`, modulo sign follows dividend (`-7%3=-1`). `mutate.mdk`'s `Assign` now carries a `SqlExpr` RHS (new `assign` builder); `resolveAssigns` compiles each RHS to a per-row accessor and `applyUpdate` evaluates all RHS against the row's ORIGINAL cells before assigning (so `SET a=b, b=a` swaps correctly). Bonus: WHERE-with-arithmetic falls out of the same evaluator (query side). Gates: 8 prior oracles byte-identical, new `update_expr_oracle.sh` PASS vs sqlite3 (total+10 / x*2 / c=a+b / int-div-trunc / div0→NULL / modulo / multi-assign swap / float p*1.5), 4 WHERE-arith cases in `select_oracle.sh`, diff_sqlite **8/0** (`inmem_arith_probe.mdk`, Int+Float). **Scope note:** computed SELECT columns (`SELECT a+b`) deliberately NOT included — needs separate projection-expression plumbing; the evaluator is now the prerequisite for it.

- **DISTINCT (`ea68fdd`):** dedups on the **projected** values (the `RowType`, not the raw row) and **before** LIMIT — so it needs `Eq a`. Kept plain `query` unconstrained; added a separate `queryDistinct : Eq a => Db -> Select -> RowType a -> Result String (List a)` with an `Eq`-constrained sibling `runOverCellsDistinct` whose tail is filter → sort(cells) → decode-all → `nub` (stdlib, stable first-occurrence) → offset/limit-on-`List a` (new `dropTakeList`). `Select` gains `distinct : Bool` (default False) + `withDistinct`; `render` emits `SELECT DISTINCT`. Gates: 4 prior oracles byte-identical (distinct=False guard), new `distinct_oracle.sh` PASS vs sqlite3 (single-col, multi-col/tuple, and DISTINCT+LIMIT proving dedup-before-slice), diff_sqlite **7/0** (`inmem_distinct_probe.mdk`).

- **LEFT JOIN — superset of INNER (`b1c1acf`):** added `JoinKind = JInner | JLeft` + a `kind` field on `Join`; `leftJoin : String -> Expr Bool -> Select -> Select` builder (INNER path byte-identical). The nested loop now threads each right table's **schema-derived** column width (works even when the right table has zero rows) and, in `crossOne`, emits ONE null-padded row (`l ++ replicate width CNull`) when a left row matches nothing. WHERE-vs-ON semantics fall out for free — ON gates the join (unmatched left kept + null-padded), WHERE runs post-join in `runOverCells` over combined cells, so a WHERE on a null-padded right column drops that row exactly as sqlite3 does. LEFT-joined columns decode via `tOption` (no RowType change; documented). Render emits `LEFT JOIN`/`INNER JOIN` per kind. Gates: select/aggregate/join oracles byte-identical (INNER + single-table guard), new `left_join_oracle.sh` PASS vs sqlite3 (plain unmatched→NULL + WHERE-on-null-col drops rows + 3-table INNER-then-LEFT chain), diff_sqlite **6/0** (new `inmem_leftjoin_probe.mdk` native==wasm).

- **Multi-column ORDER BY (`fa8ecba`):** `Select.orderBy : Option (String,Bool)` → `List (String,Bool)`; `withOrderBy` now *appends* a key (single-column callers byte-identical; chain for multi-key). `sortRows` folds a per-key direction-aware comparator (drops unresolved keys, keeps the rest); `renderOrderBy` emits comma-joined `col DIR`. Gates: select_oracle + aggregate_oracle PASS vs sqlite3, diff_sqlite 4/0 (new `inmem_orderby_probe.mdk`).
- **INNER JOIN — single + N-way (`0d599c1`):** breaks the single-table assumption. Additive ADT (locked design): `from : String` kept as the first table + new `joins : List Join` (`Join = { table, on : SqlExpr }`, default `[]`); type-safe `innerJoin : String -> Expr Bool -> Select -> Select` builder; qualified `table.column` names via a new `validQualIdent` (existing `validIdent` untouched). Executor refactored into a shared cell-based pipeline (`runOverCells`): both paths materialize `List (List Cell)` + one combined `lookup` (`t.col`/bare-col → concatenated-row offset), joins are nested-loop concat filtered by the ON predicate (compiled via the existing `compilePred` seam); WHERE/ORDER BY/decode run downstream unchanged. Combined row = from-cols then each join table's cols in `joins` order → existing `RowType` decodes the wide row left-to-right (no RowType change). N-way landed cleanly (offset arithmetic didn't fight). Gates: select_oracle/aggregate_oracle byte-identical (joins=[] regression guard), new `join_oracle.sh` PASS vs sqlite3 (2-table equi + WHERE-on-join-col + WHERE-on-from-col + 3-table chain), diff_sqlite **5/0** (new `inmem_join_probe.mdk` native==wasm).
- **Next tandem bites (scouted, ranked):** string functions / `||` concat + comparison-expr projections (extend the evaluator to text ops + let projections/UPDATE-SET return computed text; also enables `SELECT upper(name)`-style); ORDER-BY-on-computed-column (lift the projection v1 limitation — sort the projected rows); subqueries (large — `SqlExpr`/`Select` recursion, scalar + `IN`). Index-use is a perf rewrite with no observable tandem diff → deprioritized. (computed SELECT columns + arithmetic + UPDATE-SET-expr + DISTINCT + LEFT JOIN ✅ landed above.)

## Current status (2026-07-01) — capability effects: WS-3b builtin-extern flip DONE (Env/Exec + FileRead/FileWrite) (`2d010b2`)

The last deferred item of the effect-and-capability conformance workstream — deferred solely because the (now-removed) frozen OCaml oracle registered Env/Exec as atomic and read the embedded `runtime.mdk` — is done. Three commits: `25435fb` (flip `getEnv`/`runCommand` to `<Env _>`/`<Exec _>`), `5e7c856` (bonus: top-level `PSet` manifest-render + `--allow` round-trip fix in `check_policy.mdk`/`typecheck.mdk`), `2d010b2` (flip all nine file-IO externs — `readFile`/`readFileBytes`/`fileExists`/`canonicalizePath`/`listDir` → `<FileRead _>`; `writeFile`/`writeFileBytes`/`appendFile`/`makeDir` → `<FileWrite _>`).

- The Env(Set)/Exec(Prefix)/FileRead(Prefix)/FileWrite(Prefix) domains were already pre-registered in `seedEffectDomains`, so the flip needed NO registry edit and NO per-program `effect` decl — call-site α refinement fires automatically off the builtins (`getEnv "HOME"` → `<Env {"HOME"}>`; `readFile "/etc/app/x"` → `<FileRead "/etc/app/x">`).
- Measured blast radius: tiny — 1 of ~300 file-IO call-sites passes a string literal; the rest pass dynamic paths → hole stays unfilled → degrades to ⊤ (identical to the old bare label) → escape-safe, ZERO golden churn.
- NO seed re-mint needed (runtime.mdk is the extern catalog read at typecheck; effects erase at runtime → emitted IR unchanged). Fixpoint C3a/C3b YES throughout.
- Gate: `test/effect_builtin_param_domain.sh` (12/0) drives the real stdlib builtins (no local extern shadowing) — Env/Exec/FileRead/FileWrite accept+reject + manifest render (Env array, FileRead string) + round-trip.
- **Remaining effect items (deferred, none OCaml-blocked):** WS-5 extern-row assurance (standing discipline, not a closeable code task); Wasm custom-section manifest emission (`backend/wasm_emit.mdk`, separate seam); Phase 146b user-facing parameterized effects (downstream, larger).

## Current status (2026-06-30) — Float-on-wasm hardening + type-lost-Float ROOT fix (`27969e7`)

Triggered by SQLite aggregates (SUM/AVG) trapping on wasm. Two arcs, all fixpoint/wasm-gated (see EMITTER-GAPS.md "W-SQLITE-4 + type-lost-Float"). Designs: `WASM-FLOAT-TYPING-DESIGN.md`, `SHARED-FLOAT-RESIDUAL-DESIGN.md`. Memory: `project_wasm_float_hardening`.

- **W-SQLITE-4 (wasm signature-anchored Float, `b5eb960`/`2d321af`):** wasm `cexprIsFloat` couldn't see Float through fn param / Float-returning call / record-or-ctor field. Threaded `declSigTypeNames`/`ctorFieldTypeNames` into new registries + `cexprIsFloat` arms. Removed the `faddF` aggregate workaround (`f657831`). Wasm-only → no re-mint.
- **Type-lost-Float ROOT fix (approach C, `f3d4f71`+`27969e7`):** a monomorphic concrete-Float binop anchored only through a poly-HOF-bound value (`let y = identity 2.5; y+y`, tuple, let-literal) miscompiled — native garbage, wasm trap. Typecheck stamps `RScalar "Float"` (grounded-only; poly `Num a` stays dict-routed) → `CBinPrim` scalar-tag → read by both emitters. Reuses the comparison-operator stamp infra. **No re-mint** (compiler's own IR unchanged; fixpoint C3a vs committed seed). Closed on BOTH backends.
- **Wasm polymorphic-Num gap CLOSED (approach A, `8afc613`):** `sq x=x*x`/`myMax` on Float traps no more — new `$mdk_value_add/sub/mul/div/mod` runtime helpers (port of native's `mdk_num_*` value-tag dispatch) + `$float` arms on `$mdk_value_cmp`/`_eq` (Ord/Eq sibling); `emitBinRef` routes only genuinely-polymorphic Num/Ord operands there (`numPolyLocalsRef`), keeping the static Int/Float fast path. Wasm-only, no re-mint. `diff_wasm` 154/0. **Float on WasmGC now fully closed** (monomorphic via C + polymorphic via A, both == native).
- **C4 bare-Float-main auto-print DONE (`ee2b53e`):** a polymorphic-return value main whose type is Float printed garbage (native `2182360976`) — `mainKind`/`refMainKind` defaulted to Int. Added a `mainTypeIsFloat` typecheck hint (mirrors `mainTypeIsUnit`) installed into both emitters → bare Float main prints `6.0`. Additive (Int/Unit/`println`-wrapped mains unchanged); no re-mint. **Float is now FULLY closed** — arithmetic (C+A) AND auto-print (C4), monomorphic AND polymorphic, native AND wasm.
- **Only remaining Float-adjacent item:** B/monomorphization — the separate instance-DCE/backend-dispatch roadmap item (`project_backend_dispatch_strategy`), NOT a Float bug.

## Current status (2026-06-30) — SQLite UPDATE/DELETE + WasmGC port (`66a8403`)

**Full rowid-faithful CRUD + SQLite running on WasmGC == native.** Both pure-library/wasm-backend → NO seed re-mint / LLVM fixpoint. Designs: `SQLITE-MUTATION-DESIGN.md`, `SQLITE-WASM-DESIGN.md`. Memory: `project_sqlite_mutation_and_wasm`.

- **UPDATE/DELETE (`a0fb00d`):** read-transform-rewrite (filter/map via `select.compilePred`, rewrite whole db); new `sqlite/lib/mutate.mdk`. Rowid-faithful (new explicit-rowid writer path, `d8cebbd`; IPK+auto byte-identical). Refuses index / WITHOUT-ROWID / IPK-column-SET with a clean `Err` (never silent corruption — indexes are silently dropped on rewrite AND `integrity_check` still passes). `sqlite3`-CLI oracles.
- **WasmGC port (stages A–D, `8cff4f3`→`3a633d7`):** in-memory + file CRUD under `--target wasm`, byte-identical to native. **ZERO emitter construct gaps** — the whole blocker was 9 missing externs (5 pure-compute → WAT, 2 float-reinterpret, 2 host I/O via the run.js seam). Lib UNCHANGED. **Soak win: 3 GENERAL wasm-emitter gaps closed** (EMITTER-GAPS.md W-SQLITE-1/2/3: point-free array extern, tuple-pattern lambda in freeVars, `maxIndexAt` scratch-local undercount — none sqlite-specific; the ref-mode census missed all three). **Tandem workflow live:** `test/wasm/diff_sqlite.sh` builds a probe under both targets + diffs → every future in-memory SQL feature gets a wasm test for free. Gates: `diff_wasm` 141/0, `diff_sqlite` 2/0 (node v24 via nvm).
- **Residual (deferred):** SQLite — in-place mutation, indexes (read/maintain/use), WITHOUT-ROWID, overflow pages, full b-tree balancing, durability/WAL. (SET-expressions, JOINs — INNER + LEFT — aggregates/GROUP BY, DISTINCT, multi-column ORDER BY, and computed SELECT columns are all now DONE — see the top status entry; the query engine is no longer single-table.) Next: add SQL features to native + wasm in tandem via the shared oracle (string functions / `||`, ORDER-BY-on-computed, subqueries).

## Current status (2026-06-30) — compiler↔stdlib unification step 2: util.mdk → stdlib `list`/`string` (`09e0154`)

Second measured step (after OrdMap→Map). `support/util.mdk` now delegates `reverseL`→`list.reverse`, `zipL`→`list.zip`, `joinWith`(+`joinNl`/`joinDot`)→`string.join` (`import list`/`import string` added; dead `intersperseStr`/`interspGo` removed). API + signatures unchanged → consumers untouched. Seed re-minted, cold `bootstrap_from_seed` PASS, fixpoint C3a/C3b YES, all self/user gates green (selfproc 3/0, check_modules 2/0, resolve_modules 13/0, check 73/0, typecheck_golden 57/0, eval 23/0). Memory: `project_compiler_stdlib_unification` (updated).

- **The measurement FLIPPED the assumption — the key generalizable finding:** (a) `import list`/`string` is **near-free** (−256 B, +2% self-compile within noise) because List/String instances are **core-defined** (always-present prelude) → DCE trims to the referenced standalone fns; no new instance surface (unlike `import map`, which added a NEW type → +34 KB / +4.8%). **Rule: importing a stdlib module whose types' instances are core-defined is near-free; importing one that defines a new type is not.** (b) **Anti-pattern (rejected):** delegating the compiler's hot monomorphic helpers (`contains`/`listLen`/`anyList`/`allList`) to the prelude Foldable methods (`elem`/`any`/`all`/`length`) cost **+56% self-compile** — they lose `||`/`&&` short-circuiting and become dict-passed fold+closure. Hot inner-loop helpers stay monomorphic.
- **Next candidates (revised by the finding):** the 28-file **cross-file local-duplicate dedup** (`HELPER-CENSUS.md`) — fold dups into util's *fast monomorphic* helpers, NOT prelude methods. Defer `replicate`/`startsWith`/`endsWith`/`stringTrim*` (name collisions + subtle semantic diffs — whitespace set, length-guard, Char-vs-String sep). Genuinely-private helpers (`lookupAssoc`/`escStr`/`dedup`(ordmap-backed)/utf8/Option helpers) stay in `support/`.
  - **✅ Quadratic-join dedup DONE (`4621272`):** the census's headline "drifted O(n²) joinWith in typecheck/eval" was already fixed (both import `util.joinWith`). The genuine remaining quadratic re-rolls — `lexer.joinNlStr`, `parser.joinSemi/joinComma`, `check_policy.joinSemiTok` — now delegate to `util.joinWith` (O(n), stdlib-`join`-backed). `check_policy.joinTomlLines` deliberately left (trailing-separator semantics ≠ `joinWith`). `concatList`/`concatLists` (eval/desugar) are linear, not quadratic — left (low value; no stdlib `concat`).

## Current status (2026-06-30) — transparent type aliases + relaxed value restriction (`5d6d1ea`)

Two coupled typechecker-semantics features landed (both touched `typecheck.mdk`/self-compile graph; seed re-minted at each checkpoint, cold `bootstrap_from_seed` C3a PASS, fixpoint C3a/C3b YES throughout). Design docs: `compiler/TYPE-ALIAS-EXPANSION-DESIGN.md`, `compiler/VALUE-RESTRICTION-DESIGN.md`. Memory: `project_type_alias_expansion`, `project_value_restriction_relaxed`.

- **Transparent type-alias expansion (5 stages, `29efddf`→`6d9eaec`):** `type X = Y`, parameterized `type Pair a = (a,a)` (with arity checking; unapplied/wrong-arity → error), `export type` across modules; cyclic/recursive aliases rejected (were a stack-overflow crash). Locus: typecheck pre-pass `aliasTableRef` expanded on-demand at `fromAstTypeE`/`fromAstTypeApp` + resolve `expTypesDirect` + typecheck `publicDataDecls` for the cross-module case. **Payoff (`22d6a88`):** `support/ordmap.mdk` dropped the `data OrdMap` wrapper for `export type OrdMap a = Map String a`. Known v1 wart: alias-error source locs point at the decl, not the use site.
- **Relaxed value restriction (`386a543`):** `isNonexpansive` now treats constructor-applications and records of non-expansive args as generalizable (the standard SML non-expansive set), so `e = MkBox []` generalizes (it didn't before — the over-restriction that forced the nullary-ctor `OrdMap` workaround). SOUND: `Ref` (the sole uppercase mutable-cell extern) is excluded by name — `Ref []` still correctly fails to generalize; function applications stay expansive. Relaxed-VR variance analysis ruled out (unneeded). Recaptured `effect_param` golden: `yld` now infers the more-general `Async a Unit` (was `Async <IO | a> Unit` — IO had leaked in when yld was monomorphic).

## Current status (2026-06-29) — compiler MAY use stdlib; OrdMap→stdlib `Map` shipped (`59f0545`)

**Policy change + first step of compiler↔stdlib unification.** A measurement spike retired the long-standing "compiler must NEVER import stdlib" rule (AGENTS.md updated). Importing stdlib from compiler code resolves fine (`build_native_medaka.sh` already passes `$STDLIB` to the emitter) and the cost is small — so the feared blocker (monomorphization / instance-level DCE) was never actually a blocker, just a cost decision. **First step landed:** `support/ordmap.mdk` now wraps stdlib `Map` (`import map`), retiring the duplicate hand-rolled weight-balanced tree so it can't diverge from `stdlib/map.mdk`. Consumers (`typecheck.mdk`/`llvm_emit.mdk`/`util.mdk`) only swapped `OTip`→`omEmpty`.

- **Measured cost:** `medaka` binary **+34 KB (+1.25%)**, full self-compile **+0.65s (+4.8%)** — the entire `Map` instance surface (Eq/Ord/Debug/Display/Mappable/Monoid) for one type. Verified: all 53 entries native-compile; selfcompile_fixpoint C3a/C3b YES (seed re-minted); self-gates (selfproc 3/0, check_modules 2/0, resolve_modules 13/0) + user gates (eval_dict 28/0, eval_run 50/0, check 72/0, typecheck_golden 57/0) green; **zero golden changes** (behaviourally invisible). Memory: `project_compiler_stdlib_unification`.
- **Three gotchas for the rest of the migration (carry forward):**
  1. **Value restriction** — a polymorphic empty must be a **nullary constructor** (syntactic value). A constructor *application* (`OMap Tip`, `OMap (fromList [])`) is NOT generalized by this typechecker → monomorphises to `…Unit` → cascading "Scheme vs Unit". Fix used: `data OrdMap a = OEmpty | OMap (Map String a)`; `omEmpty = OEmpty`.
  2. ~~**Type aliases are NOT expanded** by the typechecker~~ ✅ **DONE 2026-06-30** — type aliases now expand transparently (non-param `type X = Y`, parameterized `type Pair a = (a,a)` with arity checking, and `export type` across modules; cyclic/recursive aliases rejected). Locus: a typecheck pre-pass `aliasTableRef` expanded on-demand at the `fromAstTypeE`/`fromAstTypeApp` seam + resolve `expTypesDirect` + typecheck `publicDataDecls` propagation for the cross-module case. Design+as-built: `compiler/TYPE-ALIAS-EXPANSION-DESIGN.md`. The `data OrdMap` wrapper can now be `type OrdMap a = Map String a` (see migration follow-up). Known v1 wart: alias-error source locations point at the alias decl, not the use site.
  3. **Gates that run the emitter/probes over compiler source need the `$STDLIB` root** now that the compiler graph reaches `stdlib/map.mdk` — fixed in `selfcompile_fixpoint`, `diff_compiler_{selfproc,check_modules,check_modules_batch,resolve_modules}`, `profile_compiler`. Any NEW such gate needs the same.
- **Bidirectional coupling now in effect:** a `stdlib/map.mdk` change that perturbs emitted IR forces a seed re-mint + fixpoint re-validation (feature: converts silent divergence into a build gate; cost: more re-mint churn).
- **Next migration candidates:** ✅ step 2 (`support/util.mdk` → stdlib `list`/`string`) DONE 2026-06-30 — see the top status entry for the cost finding. Remaining: the cross-file local-duplicate dedup (`HELPER-CENSUS.md`), folding dups into util's fast monomorphic helpers.

## Current status (2026-06-29) — `medaka lint` modular linter SHIPPED

**`main` = `4adcea6` (linter v1 landed at `561da81`). A new CLI tool: `medaka lint` — a modular, rule-based linter.** The v1 landing was a no-emitter-graph change → committed seed still valid (cold `bootstrap_from_seed` C3a PASS, **no re-mint**); fixpoint C3a/C3b YES; gates `diff_compiler_lint` 5/0, `diff_compiler_lint_fix` 2/0, `diff_compiler_lint_multi` 1/0, `diff_compiler_exhaust` 5/0. Built in 4 staged, independently-gated landings (design pass → framework+rules → CLI+gate → `--fix`+location-fix → multi-file). Owning module `compiler/tools/lint.mdk`. **Extended below:** the cross-file rule tier + recursive walk (`a29df3f`), and the two latent emitter record-scanner gaps it surfaced were both FIXED (`73d51c0` CList-scan + `5049b43` type-directed field resolution; seed re-minted at `efa0415`).

- **Architecture:** runs on the **RAW pre-desugar AST** (`parse src`, never desugar) — the only seam where surface shapes (`match`-on-param, `impl Eq`, a fn named `reverse`) survive; mirrors `checkGuardExhaustiveness`. A `Rule { name, descr, severity, enabled, check : Positions -> List Decl -> List Finding, fix : Option (Decl -> Option (List Decl)) }` record registry (`allRules`) — **adding a rule = write one fn + append one list entry** (the modularity goal). Findings render via the existing `diagnostics.mdk` carat path; the golden gate uses location-stripped lines. Tool + entry probes are OUTSIDE the self-compile graph (only the `medaka_cli.mdk` dispatch arm is in-graph).
- **v1 rules:** `rule-match-on-param` (§8: guard-free `f x = match x …` ≥2 arms → multi-clause); `rule-hand-rolled-derivable` (§6: hand-written `impl Eq/Ord/Debug` over a single named type → suggest `deriving`); `rule-stdlib-reimpl` (§7a: top-level fn named like a curated stdlib fn). All default severity `warning`.
- **CLI:** `medaka lint [--fix] [--disable=R,…] [--only=R,…] [--deny=R,…] [paths…]`. ESLint-style per-rule severity — exit 1 iff any **error**-severity finding; `--deny=<rule>` promotes a rule to error. `--fix` autofixes **§8 only** (printer-rendered replacement decls spliced over the decl's line-span bottom-up; guard-free safe subset — guarded/scrutinee-referencing matches still WARN but are left byte-identical). Targets: multiple files, a directory (`listDir`, top-level `.mdk`), or no-arg project mode (walks up to `medaka.toml`). §6/§7a are suggest-only (can't prove equivalence / safe deletion). Real dogfood proof: `medaka lint` in `sqlite/` flagged genuine §8 sites (`renderCells`/`printRows`).
- **Two latent emitter gaps surfaced — both now FIXED (2026-06-29):** (1) ✅ FIXED (`73d51c0`) — `scanExprRecords` traversed `CArray` but not `CList`, so a record constructed inside a **list literal** never registered its field layout → `CFieldAccess: unknown field`; added the `CList` arm. (2) ✅ FIXED (`5049b43`, seed re-minted) — the mis-filed "cross-module function-field SIGSEGV" was DISPROVEN; the REAL bug was **type-unaware field resolution** (`findFieldIdx` resolved `CFieldAccess` by label only → two records sharing a field name at different indices loaded the wrong offset → garbage/SIGSEGV). Fixed by widening `EFieldAccess`/`CFieldAccess` to carry the typecheck-resolved record name (Bug-3 `Ref String` idiom) + resolving by `(record,label)` with label-only fallback; same fix applied to the sibling float-field-by-label bug. Diagnose-first caught that the emit-path record name is MANGLED (`<mid>__<name>`) → mangle-aware `lookupRecordByMangledHead`. Both run==build, fixpoint C3a/C3b YES, full `diff_compiler_*` 0-failing.
- **Open follow-ups:** §3 match-on-computed-value rule (deferred — false-positive-prone); config-file rule toggles; autofix for more rules; more cross-file rules. (See the 2026-06-29 fmt/lint dogfood update below for the newer rules + Tier 0 type-aware oracle.)

### Update (2026-06-29, `a29df3f`) — cross-file rule tier + recursive walk
- **Cross-file rule tier** added to `lint.mdk`: a `CrossFileRule { name, descr, severity, enabled, check : List (String, Positions, List Decl) → List Finding }` registry (`allCrossFileRules`) + `runCrossFileRules` driver (all `CrossFileRule`-record access kept inside `lint.mdk`; CLI passes plain data, applies `--deny`/`--only`/`--disable`, renders under a `cross-file:` header). First rule **`rule-duplicate-body`**: flags top-level functions whose **structurally-identical body** (keyed by `ir.sexp.exprSexp` = the existing ELoc-stripped serializer; threshold = ≥10 AST nodes so trivial bodies never fire) appears across ≥2 files → one finding per occurrence naming the other file(s). Calibration (zero false positives): parsec 0, stdlib 12 (genuine `map`↔`set` / `hash_map`↔`hash_set` parallel helpers), compiler 142 (the deliberate no-stdlib inline duplication). **Recursive subdir walk:** `medaka lint <dir>` / no-arg project mode now recurse into subdirectories (skip dotdirs), deterministic sort. Fixpoint C3a/C3b YES, cold `bootstrap_from_seed` PASS with the existing seed (**no re-mint** — CLI + visibility-only `export exprSexp` don't drift the emitter seed); gates `diff_compiler_lint_crossfile` 1/0, lint/lint_fix/lint_multi/exhaust unchanged.

### Update (2026-06-29, `bb32190`) — sqlite fmt/lint dogfood review + Tier 0 type-aware oracle
A file-by-file review of the sqlite library through `medaka fmt` + `medaka lint`. **Six commits** (each orchestrator-verified + merged; seed re-minted ONCE at `09aa961` for the fmt + exhaust graph changes — cold `bootstrap_from_seed` C3a PASS, fixpoint C3a/C3b YES):
- **fmt was UNSAFE on real code — 3 bugs fixed (`67fef29`):** `fmt --check` was a NO-OP (`FmtCheck => ()` discarded the formatted text → always exit 0); `export <sig>` printed on its own line → `fmt sqlite.mdk` no longer PARSED + non-idempotent; single-variant `data X = X {f:T -- cmt}` field comments orphaned below the decl (real re-attachment via new `printNamedFieldData`); + a neg-literal-as-wrapped-app-arg paren bonus. `diff_compiler_fmt` 47/0, `_printer` 28/0.
- **`rule-bind-then-destructure` + autofix (`23db203`):** dogfood-driven — `v <- e; match v {(tuple) => body}` (bind then immediately destructure as the do-block's final stmt) → `(tuple) <- e` with body flattened. Fires on irrefutable patterns; AST-rewrite autofix.
- **Tier 0 syntactic oracle (`cedc505`):** wired `exhaust.mdk`'s EXISTING `buildOracle : List Decl -> Oracle` (purely syntactic ctor table, NO typecheck) into the linter → the rule now proves single-ctor irrefutability (`Box x <-` fires, `Some`/`Ok` skip). `exhaust.mdk`: `export oGetCtors/oGetCtorType`. Design doc `compiler/TYPE-AWARE-LINT-DESIGN.md`. **CRUX:** no `Loc→Type` map exists (LSP hover is name-keyed) → true `typeOfLoc` = LARGE deferred (Tier 2); Tier 1 (name-keyed schemes) + §6 deriving-sharpening deferred.
- **§8 autofix improved (`bb32190`):** the autofix bailed whenever an arm body referenced the scrutinee param; now a `PWild` arm re-binds the param name (not `_`) instead of bailing. `pageCountOf`/`buildTablePages` now auto-fixable.
- **sqlite cleanup (`48cfa72`):** `lint --fix` on dbwriter/select/main (8 findings) + `magicBytes` deduped into `header.mdk`; all 8 sqlite oracles byte-identical. `diff_compiler_lint` 7/0, `_lint_fix` 5/0.
- **Open follow-ups:** Tier 1 name-keyed schemes + §6 deriving-sharpening (deferred per design); sqlite demo binaries aren't gitignored (an agent committed 5 by accident); the abstract-record `Oracle(..)` resolve-vs-emit inconsistency (minor).

## Current status (2026-06-27) — sqlite dogfood review batch (UTF-8 + Float % + `f -1` + Ordering Eq/Ord)

**SHIPPED** (`main` = `29c2120`, seed re-minted, cold `bootstrap_from_seed` PASS, full `diff_compiler_*` 0-fail, fixpoint C3a/C3b YES). A file-by-file review of the sqlite library landed a 10-task batch. New features: **UTF-8 codec externs** (`stringToUtf8Bytes`/`stringFromUtf8Bytes` + `stdlib/string.mdk` `toUtf8`/`fromUtf8`/`utf8ByteLength`); **Float `%` completed** (it was ~90% built — eval lacked the `VFloat` arm; fixed via a `floatRem` extern = C fmod == LLVM frem; reproduce-first nearly reimplemented a working operator); **negative literal in application position** `f -1` → `f (-1)` (lexer `TMinusTight` + head-gated `parseApp`, "Rule C"; `5 -1` stays subtraction); **`Ordering` Eq/Ord** (run≠build fix — `o == Lt` build-failed); **`bytebuilder.emitBeUint`** promoted. Cleanups: five dogfood libs de-rolled off hand-written stdlib reimplementations; `Display Cell`/`Display Row` consolidation; select `compare`/`Ordering` + param-destructure/record-update; btree §12 constants; rowtype `cellShape`→`debug`; MutArray-Builder adoption in dbwriter/recordenc. **`isEven`/`isOdd` were DROPPED** (blocked by the dict-pass shadowing bug below). Memory: `project_sqlite_review_batch`.

## Current status (2026-06-27) — internal-only array externs restricted (--allow-internal)

**SHIPPED** (`1b94b42` enforcement + `f2e6019` dogfood rewrites + `8e0390f` seed re-mint; cold `bootstrap_from_seed` C3a PASS, fixpoint C3a/C3b YES, full `diff_compiler_*` 0-fail incl. new `diff_compiler_internal_extern` 8/0). Referencing `arrayGetUnsafe`/`arraySetUnsafe`/`arrayBlit`/`arrayFill`/`arraySortInPlaceBy` from a non-stdlib module is now a resolve-phase compile error (`InternalExternAccess`), unless `--allow-internal` is passed (run/build/check). Trust is per-module via the loader's **owning root** (`stdlibTrustedMods` in `loader.mdk`), not modId; `--allow-internal` also trusts the entry project. `__fallthrough__` excluded (desugar-generated → would false-flag guards). The compiler self-compiles via the emitter entry which never runs resolve, so `make medaka`/fixpoint are unaffected; only `build_oracles`' `medaka build` of compiler entries got the flag. Dogfood libs (sqlite/parsec/byteparser) rewritten to safe public API (reads `arr.[i]`, writes `Array.set`, new safe `Array.blit` in `stdlib/array.mdk`); sqlite oracles byte-identical. Memory: `project_internal_extern_restriction`.

## Current status (2026-06-27) — D2 fn-level cross-module dict-arity collision FIXED (run-crash)

Closed the **fn-level** half of the long-deferred D2 re-key — and in the process **refuted its
"benign by construction" framing**. Reproduction (verify-before-documenting) found a genuine
**run≠build crash**, not the zero-payoff cleanup the diagnosis predicted: a module that *directly
imports* a constrained fn while a *different-`=>`-arity* same-named constrained fn lives in another
dependency hits the bare-name first-match in the jointly-seeded `funConstraintsRef` (most-recent
prepend = a FOREIGN module's arity) → the call over-applies → `medaka run` aborts `applied
non-function`, while `check` accepts and `build` is saved by universal mangling.

**Fix (contained, `compiler/types/typecheck.mdk` only, NO AST node, seed re-minted):**
`inferDictAtFound` resolves a cross-module constrained callee's dict arity by **module identity** —
a per-module `currentImportDefinersRef` (imported value name → import-source module id, from `prog`'s
`DUse`) keys the existing `(definer,name)` qual arity table plus a new slot-parallel ifaces mirror
`crossModuleFunConstraintIfacesQualRef`; bare first-match remains only as the fallback for wildcard
`import mod.*` and re-exports. Byte-identical on the corpus (the qual entry is the same ids the bare
first-match already returned absent a collision). Regression:
`test/eval_typed_modules_fixtures/cross_module_dict_arity_direct/` (both collision orientations, drives
`evalModules`). **Gates:** all `diff_compiler_*` 0-failing (incl. eval_typed_modules 11/0, build 36/0,
llvm 183/0, typecheck_golden 57/0; `effect_hole`/`lsp_b4` now also 0 after the FORCE oracle rebuild),
fixpoint **C3a/C3b YES**, cold `bootstrap_from_seed` PASS, bootstrap_typecheck 12/0, bootstrap_eval 23/0.
**Residual (deferred, now purely hygienic):** retiring the bare fallback for the wildcard/re-export
corner needs the full AST-origin `EVarFrom` re-key (resolve→original-definer-through-diamonds) designed
in `compiler/WS2-REKEY-DIAGNOSIS.md`. See the standing item in
[Self-host … open items](#self-host-typecheck--dispatch--runtime--known-open-items).

## Current status (2026-06-26) — OCaml compiler REMOVED; `selfhost/` → `compiler/` rename

**`main` = `fa5983c`.** Two milestones landed in a single mechanical sweep:

1. **OCaml reference compiler REMOVED.** `lib/` + `bin/` + `gen/` + `dev/` are
   deleted (commit `06356a8`). Tag `oracle-frozen` preserves the last
   lib/-present commit. Medaka is now native-only; `make medaka` (warm) /
   `test/bootstrap_from_seed.sh` (cold) are the only build paths.
2. **`selfhost/` renamed to `compiler/`** (commit `aee6056`) — directory,
   content tokens, `medaka.toml` paths, gate scripts
   (`diff_selfhost_*` → `diff_compiler_*`), and goldens all updated in
   lockstep; seed re-minted (`fa5983c`), cold `bootstrap_from_seed` C3a PASS.

**Pre-existing gate debt — ✅ RESOLVED 2026-06-26** (recapture `357e2ad`/`e6409e5`/`c5bf490`,
golden-only, fixpoint C3a/C3b YES). Diagnosed all BENIGN (no native bug), recaptured to native:
- `diff_native_cli` `check/` family: ~57 → **93/0** — the diff was uniformly the `sequence`/`traverse`
  prelude-method signature-dump lag (not OCaml drift).
- `bootstrap_typecheck`: 2 → **12/0** — `index_default`/`poly_let`; native defaults Num-poly literals
  to `Int` and is strictly more precise/sound than the un-defaulted OCaml goldens.
- `bootstrap_resolve`: ~15 → **15/0** — OCaml sexp error tags → native human-readable messages
  (same errors, same locations, none dropped).

## Current status (2026-06-26) — `sequence` default method + universal default-method specialization

**`main` = `f333125`, seed re-minted, cold `bootstrap_from_seed` C3a PASS.** Closed the
`sequence`-per-impl residual *principledly* — `sequence` is now a real `Traversable` default
method (the three per-impl copies are gone), and the mechanism generalizes. Five-commit arc, each
reproduced on the binary, gated, merged:
- **B — emit dict-source (`066b9ea`).** `emitDispatchChain` now sources a dispatched impl-method's
  method-level `=>` constraint dict (e.g. `traverse`'s `Thenable m`) from the caller's ambient dict
  arg, not an OOB load from the dispatch-dict cell → fixes the user-file generic free-fn build SIGSEGV.
- **Universal default-method specialization (`8a9aa3e`).** New `fillImplDefaults` desugar pass
  (mirrored from the OCaml desugar.ml, now removed) synthesizes a concrete-receiver per-impl copy of every same-module
  interface default into each impl that omits it — so a default that *sibling-dispatches on the
  receiver* (like `sequence ta = traverse identity ta`) gets a concrete receiver and dispatches/codegens
  correctly. Closes the whole class, not just `sequence`. Design: [`TRAVERSABLE-DEFAULT-METHOD-DESIGN.md`](./TRAVERSABLE-DEFAULT-METHOD-DESIGN.md).
- **`sequence` as a default (`f6c7f33`).** Moved `sequence` into the `Traversable` interface body,
  deleted the 3 per-impl copies.
- **Emitter dict-threading for true universal (`6ae5248`).** Two further gaps that blocked literal
  universal: (1) `typecheck.mdk registerImplRequires` keyed every method under one impl tyvar id →
  encl-blind first-match returned the wrong witness (fixed: encl-aware `activeDictVarForEncl` etc.);
  (2) `llvm_emit.mdk gatherGroup` eta-expanded eta-short defaults to `methodArityOf`, dropping leading
  dict params (fixed: include leading dict pats). **Also fixed a pre-existing parametric `Ord`
  soundness bug** — `max [1, 2] [1, 3]` returned `[1, 2]`. Then the Ord/Foldable exclusion was removed
  (`265b0a2`) → specialization is literally universal.
- **Verification:** fixpoint C3a/C3b YES; `diff_compiler_build` 36/0 (foldMap fixture green),
  `_llvm` 183/0, `_eval_dict` 28/0, `_typecheck`/`_errors` 12/40, `_typecheck_golden` 57/0 (recaptured —
  `sequence`/`traverse` now appear as prelude schemes); core 38 doctests + 9 props, list 63 + 12;
  `run == build` on `sequence`/`clamp`/parametric-`max`/`foldMap`.
- **⚠️ Native-only consequence — the OCaml oracle no longer typechecks the prelude.** Making
  `sequence` a default puts `identity` in a default-method body the frozen OCaml resolver can't bind
  (`core.mdk:764: Unbound variable: identity`), so `_build/default/bin/main.exe check <anything>` now
  fails. Foreseen (design §7) and accepted (native-canonical; all native gates green and rerooted
  off OCaml), but it degrades the OCaml-pipeline gates (`@thorough`, dune unit suites) for **all**
  prelude-using programs — the oracle is effectively retired for typecheck/eval. This brings the
  **`lib/` removal** decision forward.
- **Gap 3 stays OPEN (dodged, not fixed):** a truly generic prelude *free function* over a typeclass
  with a generic/primitive receiver still fails `medaka build` with the slice-7 `arg-tag dispatch on
  impl type that owns no constructors` error. Specialization dodges it (concrete receivers); it only
  bites a future generic prelude free-fn. Filed below + in the Open issues index.

## Current status (2026-06-25) — soak tail: Traversable shipped + cross-module dispatch + loader identity

**`main` = `8d93c8e`.** A run of soak landings since the 2026-06-23 entries below; each
reproduced on the binary, gated, merged, seed re-minted at checkpoints (cold
`bootstrap_from_seed` C3a PASS):
- **`Traversable t` typeclass shipped** (`b5ae3a2` + `bf7243c` + `104c69a`, seed `da2469d`) —
  the three "return-position `pure`" dispatch gaps are closed; `traverse`/`sequence` are a real
  interface in `stdlib/core.mdk` (List/Option/Result). Gap 1 was an oracle-only artifact (already
  correct on native); gap 2 = CDict-spine eta-saturation in the emitter; gap 3 = impl-body
  method-level constraint dicts unregistered in eval. Residual (`sequence` per-impl) **now CLOSED**
  2026-06-26 — see the top status entry. See [Compiler / language](#compiler--language).
- **D2 cross-module method-constraint dispatch** (`221af36`) + **`export import` re-export**
  (`a35c87b`) — sibling-module interface methods carrying a user `=>` constraint now dispatch
  correctly cross-module (root was stale-sweep first-match shadowing, NOT the bare-name collision
  the deferred D2 re-key targets), and values/fns/methods re-exported through an intermediate module
  via `export import` resolve downstream. The fn-level `EVarFrom` re-key stays deferred.
- **F1b loader module identity** (`cf8e12d` + `ac4b04a`, `canonicalizePath` extern `33972aa`) —
  the same file under two import spellings no longer double-loads (`conflicting impl`); the loader
  canonicalizes every `DUse` to one dep-name-prefixed modId before resolve/typecheck/eval. The
  two-dep-NAMES corner is closed via a realpath extern. Native-only.
- **CFieldAccess abstract-export diagnostic** (`4710d3a` + `e3e7e1b`) — the filed "emitter panics on
  cross-module `r.field`" was a NON-bug (canonical compiler is correct with `public export data` /
  the `record` keyword); `export data` is abstract-by-design. Fix = a clear diagnostic
  (`'Point' is exported abstractly; declare it \`public export\` to expose its fields`) in both
  resolve (destructure) and typecheck (dot-access).
- **Removed the `?` operator + list comprehensions** (`27116d9`) — both compilers in lockstep;
  the model is now: bare block = effect, `do` = monadic (the `<-` delimiter), `map`/`filter`/`|>`
  = transforms. See memory `project_remove_question_op_and_comprehensions`.



**Driven by dogfooding `fmt` on the `parsec` library; `main` = `966b546`.** All native-only
(`printer.mdk`/`fmt.mdk` are OUTSIDE the emitter self-compile graph; the one in-graph helper
`util.mdk` had its seed re-minted at `5a1f3be`, `bootstrap_from_seed` C3a PASS). Each landing
recaptured the native-sourced fmt/printer goldens and kept `diff_compiler_fmt`/`diff_compiler_printer`
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
  head-inline fixes (they had no golden coverage); `diff_compiler_fmt` 44→45/0.
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
  (force-flush). Free-form continuation UNCHANGED (`diff_compiler_lexer` 57/0, `bootstrap_lex` 57/0).
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
- **Finding #1b — compiler source violated its own Phase-148 contiguity rule** (`a987a7a`,
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
OCaml-free (`compiler/REROOT-PLAN.md`); capture/mint tooling and the perf-baseline
gates were previously OCaml-gated but that is now moot (OCaml removed 2026-06-26). The **driver
collapse** is done (`compiler/DRIVER-COLLAPSE-PLAN.md`): single-file typecheck+eval
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
`compiler/ARGSTAMP-UNIFY-PLAN.md`); **emit-path Set-literal / mutual-rec-Monoid dict
gaps** fixed.

**2026-06-18 correctness arc — ALL LANDED** (`main` = `e638673`, seed re-minted, C3a PASS):

- ✅ **Cross-module Num-obligation soundness hole FIXED** — native `check` was accepting
  imported calls where a numeric literal unified with a non-`Num` type (e.g. `member s 3`
  with `s : Set Int`). Root: typecheck-module path passed `implDecls=[]` → obligation
  dropped. Fixed in `compiler/types/typecheck.mdk` (register iface params over full universe
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
  `test/diff_compiler_check_cli_modules.sh`.
- ✅ **`medaka doc` ported to native** — `compiler/tools/doc.mdk` + `medaka_cli` wiring;
  byte-identical, single-file scope. Gate: `test/diff_compiler_doc.sh` (14 fixtures). Fixed a
  scheme name-collision (`lookupScheme` last-match → user-schemes-first ordering).
- ✅ **Native LSP `No impl` diagnostic range** fixed (was `{0,0}`; now carries `ELoc` span).

**Verified open-set — 2026-06-18 (reproduced on the binary; the REAL remaining gaps):**

*Tooling:*
1. **LSP parse-error in imported sibling → silent no-publish** — `didOpen` an entry importing
   a parse-broken sibling: server does NOT crash but emits zero `publishDiagnostics`. Root:
   loader/`analyzeProject` panics on a graph-member parse error before diagnostics surface.
   Needs loader error-recovery. Memory: `project_lsp_fault_tolerance`.
2. **`ppTy` dropped effect rows — ✅ DONE (2026-06-23, `067c897`, compiler-only).** `ppTy`'s
   `TyEffect` arm discarded the effect row. Fixed to render
   `<labels | tail> innertype` mirroring `ppTyP`/`ppMono`.
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
Medaka (`compiler/`), and the native **LLVM backend now compiles it**: all seven
pipeline stages (lex → parse → desugar → resolve → mark → typecheck → eval) are
native-compiled and **byte-identical to the tree-walker interpreter** (141
fixtures across `test/bootstrap_*.sh`), and the **self-compile fixpoint is
reached** — the native-compiled emitter emits the whole emitter graph (~10.6 MB
IR), reproduces the interpreter's IR byte-for-byte (C3a), and a second-generation
native emitter reproduces that IR exactly (C3b: `IR1 == IR2`). See
`compiler/BOOTSTRAP.md` for the B1–B7 + C1–C3 log and `compiler/EMITTER-GAPS.md`
for the closed/residual emitter gaps. The native lexer runs ~90× faster than the
tree-walker.

The **OCaml compiler** (`lib/*.ml`) has been **REMOVED** (2026-06-26, tag
`oracle-frozen`). Native is the sole compiler; `make medaka` builds it OCaml-free
from a checked-in IR seed (`compiler/seed/emitter.ll.gz`).

The OCaml compiler pipeline is now REMOVED (see the top 2026-06-26 status entry).
The language has
records, ADTs, interfaces (with superinterfaces, `deriving`, dictionary-passing
for return-position/multi-param dispatch), effect rows, exhaustiveness checking,
`do`-notation, guards (with fall-through + exhaustiveness lint),
string interpolation, type aliases/newtypes, container literals
(`Map { k => v }` / `Set { x }`), property testing, doctests, **unit tests**
(Phase 127), an LSP server, a formatter, and a project-config/`medaka new` surface.

The stdlib in Medaka is **complete** across `core`, `list`, `array`, `string`
(frozen, Phase 128), ordered `map`/`set`, mutable `hash_map`/`hash_set`,
`mut_array`, `io`, and `json` (STDLIB.md Modules 1–9 all done).

**Self-host (Stage 1) and the native backend (Stage 2)** are both ✅ COMPLETE —
all eight pipeline stages ported to Medaka and validated byte-for-byte, the
bootstrap closure landed for Legs A–D, and the LLVM backend promoted from spike to
a self-hosting native compiler (the C1–C3 fixpoint above). The forward-looking
interpreter-perf levers are all resolved (`compiler/PERF-NOTES.md`).

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
| **⭐ 0.1.0 public preview (CURRENT NORTH STAR)** | [`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) | 🔴 **NEW — kicking off** | Funnel: playground front door (built, needs polish) → native download (ceiling). **Floor:** playground polish · Val-authored quickstart · stdlib docs · public repo · LICENSE · KNOWN-GAPS · `--version`. **Ceiling:** native `medaka build` binaries mac/linux + release CI + `.vsix`. **First task:** Linux build spike (`DISTRIBUTION-DESIGN.md` §D0 — the one unknown). Side quest: fs/net in interpreter. |
| **Native binary distribution (0.1.0 §W1)** | [`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md) | 🟢 **D0 Linux spike GREEN (2026-07-04); viable** | Dependency audit done (codegen/runtime already portable; work is packaging seam). **D0 spike:** full pipeline builds+runs on Docker ubuntu:24.04 aarch64 (seed→CLI→`medaka build`→ELF prints 3). **Stack:** measured need ~32MB@-O2 / ~128MB@-O0; gdb backtrace shows the overflow is **100% the lexer `b′` token-spine** (TMC-able). D2 = 2 tracks: (1) big-stack pthread 256MB both-platforms (0.1.0 baseline, mandatory for tree-depth); (2) port WasmGC `b′` TMC to native (fast-follow parity/robustness — [Native TMC parity](#open-issues-index)). +`-lm`, +Darwin-conditional stack flag (trivial). Remaining mechanical: exe-relative discovery (D1), Homebrew+tarball (D3), release CI (D4). |
| **Self-hosting (Stage 1)** | [`compiler/README.md`](./compiler/README.md) §Roadmap | ✅ complete | perf-lever tail only (all closed) |
| **Native backend (Stage 2)** | [`compiler/STAGE2-DESIGN.md`](./compiler/STAGE2-DESIGN.md) + [`compiler/BOOTSTRAP.md`](./compiler/BOOTSTRAP.md) | ✅ **complete** | Core IR + bytecode VM (§2.1–2.2) done (bytecode VM removed 2026-06-10 — off canonical path); LLVM backend promoted from spike to a **native self-hosting compiler** — all 7 stages native==interpreter (141 fixtures), self-compile **fixpoint reached** (C1 emitter-IR reproduction · C2 native compiles the real lexer · C3 `IR1==IR2`). Runtime dict-passing dispatch (D3a/D3b done); Boehm GC; CTGuard lowered. Residual: `max`/`min` over primitive `Ord` (dead code). |
| **Make LLVM canonical (Stage 3)** | **this file** → [Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml) | 🏁 **COMPLETE** | Native canonical (2026-06-12 flip); TYPECHECK-AUDIT (16 findings) + all 4 dispatch gaps (#54/#55/#50/#21) + perf bar-4 + Phase-C CLI capstone + gate re-rooting + the driver collapse all ✅ DONE. **OCaml compiler (`lib/`+`bin/`) REMOVED 2026-06-26** (tag `oracle-frozen`). |
| **Capability-effects wedge (Phase 146)** | [`EFFECTS-CONFORMANCE-ROADMAP.md`](./EFFECTS-CONFORMANCE-ROADMAP.md) (v2 conformance) + [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §9 (lang) + [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md) §10 (product) | 🟢 **conformance substantially CLOSED (2026-06-21)** | E1/E6 manifest (WS-1a/b/c `41509f6`), E3 α scope-seeding (WS-2 `98bf22b`, both compilers), E2 `Set` (WS-3 `5a1d215`) + `Product`/structured Net (WS-4 `b948ff3`), E4 Env/Exec native machinery + builtin-extern flip (WS-3b `2188e6a`, ✅ DONE 2026-07-01 `2d010b2`) — all native-canonical, fixpoint-gated. **Open:** WS-5 (extern-row assurance, standing discipline) + Phase 146b. WS-4 design banked in `WS-4-DESIGN.md`. |
| **WasmGC backend (2nd backend)** | [`compiler/WASMGC-DESIGN.md`](./compiler/WASMGC-DESIGN.md) §9 (slices) + [`compiler/WASM-SELFHOST-ROADMAP.md`](./compiler/WASM-SELFHOST-ROADMAP.md) (self-host gap-closing) + [`compiler/WASMGC-TRMC-DESIGN.md`](./compiler/WASMGC-TRMC-DESIGN.md) (stack-safety) | 🟢🏁 **self-hosted FRONT-END runs on WasmGC byte-identical to native; browser playground LIVE** (2026-06-22) | Direct Core IR→WAT emitter. Compute+print MVP (W1–W9b+W8b) byte-identical to `medaka build`. **Playground Stages 0–4 DONE** (`playground/`): compiler-as-wasm runs fully client-side, static-only server, WAT assembly via committed `vendor/wat2wasm/` blob. Done: per-binding emitter-gap census **1428→0**; whole-program linkage + `wasm-tools validate` (`check_main` = 6.77 MB WAT); runtime layers 1–4 (escape runtime, value-global init topo-sort, list-`++`, UTF-8 cp_count); **layer-5 CLOSED — the WasmGC TRMC arc (Stages 0–2, `8c69296`/`8737d11`/`2688edb`)** ported the LLVM TMC (`TRMC-DESIGN.md`) + a novel **dispatch-into-single-target (b′)** TMC for the lexer; the self-hosted **lexer now runs to completion under Node** (flat `tokenize→parse→runCheck` trace). **layer-6 CLOSED** — `stringToFloat` via host seam (`a332da7`). **layers 7–13 CLOSED** — parser/resolve/typecheck correctness bugs; `check_main` runs to completion byte-identical to native. **THE EMITTER RUNS ON WasmGC (2026-06-22)** — WasmGC-compiled emitter compiles `println (1+2)` → 52K-line WAT, assembles + runs + prints `3`. `wasm_emit.mdk` is OUTSIDE the compiler graph → emitter changes need no fixpoint/seed. **Remaining:** `hashName`/`dictTag` i32-vs-i64 width (layer-17, pre-existing, self-consistent); `List_andThen`/`flatMap` overflow (layer-18, latent); eventual `wasm-opt` perf pass. See `WASM-SELFHOST-ROADMAP.md` for full layer log. |
| **SQLite read-path library (capstone)** | [`SQLITE-DESIGN.md`](./SQLITE-DESIGN.md) | 🟢 **v1 read + WRITE COMPLETE — reads AND generates real `.sqlite` files, verified vs `sqlite3`** | LANDED (`main` @ `de44b58`): foundation externs (`readFileBytes` + bitwise, `1b25c9b`); `byteparser/` (`986bbd4`); cross-project `[dependencies]` in the native loader (`0ad8ae9`); file-format reader (`6657238`); multi-page B-tree (`86b1ffa`); typed `RowType` combinators + SELECT executor (`8d4c39c`); INTEGER PRIMARY KEY rowid-substitution fix in the typed path (`ccd650a`); `bytesToFloat64` extern + `beFloat64` (`359957a`); library hygiene — stdlib de-dup + STYLE §8 multi-clause (`de44b58`). All emitter-graph changes fixpoint-verified; **seed re-minted (`848f712`), cold-bootstrap PASS**. Reads single-leaf + multi-page tables, NULL/int/text/blob, IPK rowid, typed Medaka records — byte-identical to `sqlite3`. **Float read path COMPLETE (2026-06-24, `72b4c58`, pure-library):** `CFloat` cell + serial-type-7 (8-byte IEEE) decode via `beFloat64`, and a `tFloat : RowType Float` combinator. `tFloat` **coerces `CInt → Float`** (decided after a dogfood finding: SQLite stores whole-number REAL values as *integer* serial types — its storage optimization — so a faithful REAL-column reader must coerce; non-numeric cells still error). **Phase-2 ADT query model COMPLETE (2026-06-24, `e9fd54e`, pure-library):** `sqlite/lib/select.mdk` — `Literal`/`CmpOp`/`SqlExpr`/`Select` core + a phantom-typed `Expr a` layer (smart constructors `eCol*`/`eLit*`/`eEq`/`eGt`/…/`eAnd`/`eNot` named off prelude methods; type-safe — `eEq (eColInt "age") (eLitT "x")` is a `check` error), injection-safe `render` (`?` placeholders + ordered `List Literal`), `compilePred` (SqlExpr → `List Cell -> Bool`, SQL 3-valued NULL logic), and `query` (ADT drives the scanner — WHERE pushdown over raw cells + limit/offset, then `RowType` decode). Differential `select_oracle.sh` matches `sqlite3` (17 rows). **The whole read-path NEXT list is done.** **🏁 WRITE path v1 COMPLETE (2026-06-24, P0–P4):** Medaka GENERATES a fresh single-table `.sqlite` that `sqlite3` validates + queries (`PRAGMA integrity_check`=ok). `writeFileBytes` extern (`a97e34b`); `byteparser/lib/bytebuilder.mdk` (`75ccf95`); `sqlite/lib/recordenc.mdk` record encoder (`c4b9731`); `sqlite/lib/dbwriter.mdk` byte-perfect single-page writer (`691baa1`); `sqlite/lib/writer.mdk` typed `CREATE TABLE`+`INSERT` API (`4e582a6`). int/text/null/blob, IPK-as-rowid or auto-rowid, single leaf page (clean `Err` on overflow). Owning doc [`SQLITE-WRITE-DESIGN.md`](./SQLITE-WRITE-DESIGN.md). **🏁 P5 float (REAL) write DONE (2026-06-29, `0bfc328`):** `floatToBytes64` extern (inverse of `bytesToFloat64`, fixpoint-verified, seed re-minted `5a17cd6`) + serial-type-7 encode + `TReal` API; `sqlite3` reads it as `real` (float arithmetic correct); also fixed a latent `pBytesToFloat64` interp overflow. **🏁 P6 multi-page write DONE (2026-06-29, `aed32e3`, pure-library):** single-leaf cap removed — rows span leaf pages under one 0x05 interior root (unbalanced; verified vs `sqlite3` integrity_check at 700/937/1000+ rows, `multipage_write_oracle.sh`). **🏁 P7 multi-table write DONE (2026-06-29, `6c383d0`, pure-library):** N tables in one `.db` — per-table b-tree building parameterized by absolute base page; page 1 = sqlite_master leaf with one record per table; new `writeTables`/`buildTables` API; `buildDatabase` routes through `buildDatabaseMulti` (N=1 byte-identical). Verified vs `sqlite3` at 3 mixed single/multi-page tables; `multitable_write_oracle.sh`. **Deferred (write):** overflow pages (row >~4088 B); multi-interior trees (~tens of thousands of rows); sqlite_master >1 leaf (~tens of tables); full b-tree balancing; `UPDATE`/`DELETE`; transactions/journal/WAL. **Write-workstream compiler/tooling bugs found+fixed:** native method-shadow run≠build (`96529b3`); `arrayBlit`/`arraySetUnsafe` missing from the native interp (`ecd2eee`); loader cross-package relative-import resolution F1 (`ec8c19c`). **Open from write workstream:** ~~F1b~~ ✅ DONE 2026-06-25 (`ac4b04a`, loader module identity canonicalized — both two-spellings AND two-dep-names corners closed via a `canonicalizePath` realpath extern); `CFieldAccess` cross-module record dot-access ✅ RESOLVED 2026-06-25 (`e3e7e1b` — was a non-bug; canonical compiler correct with `public export`, filed emitter framing stale; fixed the misleading abstract-export diagnostic instead). Fast-follows (PLAN tasks, not started): WasmGC port (bytes-first API makes it additive) + async SQL server. Dogfood findings → [Known parser gaps](#known-parser-gaps-compiler-parsermdk) (#1/#2/#3/#4/#5/#8 FIXED 2026-06-24; #6 deferred-documented; #7 oracle-only; +the method-shadow check/eval bug found via the phantom-`Expr` design, FIXED `96529b3`); future `medaka lint` → its workstream row below. |

| **Linter (`medaka lint`)** | **this file** → top status entry | 🟢 **v1 SHIPPED 2026-06-29** | Modular AST linter (`compiler/tools/lint.mdk`), runs on the RAW pre-desugar AST (mirrors `checkGuardExhaustiveness`). Per-file registry of `Rule { name, descr, severity, enabled, check, fix }` + a **cross-file registry** `CrossFileRule { …, check : List (path, Positions, decls) → List Finding }` — adding a rule = one fn + one list entry. Per-file rules: §8 match-on-bare-param → multi-clause; §6 hand-rolled `Eq`/`Ord`/`Debug` → `deriving`; §7a stdlib-name re-spelling. Cross-file rule: `rule-duplicate-body` (structurally-identical function bodies across ≥2 files, via `ir.sexp.exprSexp` key + node-count threshold). ESLint-style per-rule severity (`--deny=<rule>` → exit 1); `--disable`/`--only` filters; `--fix` autofix for §8; targets = files / dir / `medaka.toml`-project, **recursive into subdirs** (skips dotdirs). **Open follow-ups:** §3 match-on-computed-value rule (deferred — false-positive-prone); config-file rule toggles; autofix for §6/§7a (not safely auto-fixable as-is); more cross-file rules. |
| **Compiler / language correctness** | **this file** → [Compiler / language](#compiler--language) | 🟡 open items | Phase 101b (deferred) |
| **Standard library** | [`STDLIB.md`](./STDLIB.md) §"Remaining work" + §"Label refinement roadmap" | 🟡 modules done, extras open | `<>` Semigroup operator (not lexed); JSON pretty-printer + `ToJson`/`FromJson`; single-codepoint indexing; effect-label refinement |
| **CLI surface (Phase 82)** | **this file** → [CLI surface](#cli-surface-phase-82-continued) | 🟡 gaps | `medaka build` ✅ full-prelude (H closed, 2026-06-18 audit); `check --json` multi-file ✅ CLOSED; `medaka doc` ✅ ported to native CLI (single-file, 2026-06-18) |

---

## North star (current phase) — 0.1.0 public preview

The goal that orders the current phase: **ship a very preliminary public 0.1.0
preview** — the point where Medaka goes in front of strangers (HN/Reddit-scale).
The compiler is mature; the remaining distance is **outward-facing surface**.
Owning doc: **[`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md)** (hub for all
release workstreams); native-distribution technical design + blocker map:
**[`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md)**.

**Testable statement:** a stranger goes from a link to a **working, formatted,
type-checked, running** Medaka program in **under ten minutes**, and **every hole
they hit is one we already told them about.**

**Shape — a distribution funnel** (the two front-runners were resolved *together*,
not either/or):
1. **Playground = front door** — zero-install, sandboxed (WasmGC in-browser),
   pure + console IO. Already built (`playground/`, Stages 0–4 done); needs polish.
   Ships regardless — the risk buffer if the download slips.
2. **Native binary = "do something real"** — downloadable `medaka` + `build` for
   macOS + Linux with full fs/net IO. **In-scope for 0.1.0** (Val's call). The
   playground *cannot* do practical IO (browser sandbox), so this is not optional
   if the preview is to read as a real language.

**Floor (blocks 0.1.0)** vs **ceiling (ship if tractable)** — full breakdown in
`RELEASE-0.1.0-PLAN.md`:
- **Floor:** playground polished into a front door · Val-authored quickstart/overview ·
  stdlib reference docs · curated public repo · **LICENSE** (leaning MIT / dual
  MIT-OR-Apache-2.0, final pick pending) · `KNOWN-GAPS.md` · `medaka --version`.
- **Ceiling:** native `medaka build` binaries (mac/linux) + release CI matrix +
  editor extension (`.vsix`). The one genuine unknown gating the native binary is
  the **Linux deep-recursion stack** (macOS uses a 512MB stack via a flag GNU ld
  rejects) — spiked first (`DISTRIBUTION-DESIGN.md` §D0) before any mechanical work.
- **Freeze:** error-message quality is at a defensible preview bar (~11.9/14) —
  ongoing-not-blocking, except the one cheap located-nonexhaustive-warning win.
- **Side quest (not a blocker):** implement fs/net in the tree-walk interpreter
  (`eval.mdk`, `add-primitive`) — makes `medaka run` practical without clang;
  strict improvement, opportunistic.

**Open framing question (does not block starting):** confirm the audience bar —
"strangers who'll try to break it" (assumed) vs "a dozen personally-invited people."

---

## North star (prior, ✅ COMPLETE) — self-hosting, then LLVM

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
owning docs: `compiler/README.md` (Stage 1), `compiler/STAGE2-DESIGN.md` +
`compiler/BOOTSTRAP.md` (Stage 2). Forward work is
[Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml).

### Stage 3 — Make the LLVM backend canonical, retire OCaml

Stages 1–2 are done: Medaka self-hosts and the native LLVM backend compiles the
compiler to a self-reproducing fixpoint. **Stage 3 makes the native backend the
CANONICAL compiler** — the one users invoke and the one that builds the compiler.

**Retirement ≠ removal (decided 2026-06-10; removal executed 2026-06-26):**
- **RETIREMENT (2026-06-12):** native became canonical; the OCaml reference compiler was
  DEMOTED but kept in-tree frozen as a soak-period oracle.
- **REMOVAL (2026-06-26):** ✅ DONE — `lib/`+`bin/`+`gen/`+`dev/` deleted (commit
  `06356a8`); tag `oracle-frozen` preserves the last lib/-present commit.


**Status: Stage 3 is essentially COMPLETE — see the full item-by-item log in
[PLAN-ARCHIVE.md → Stage 3 — native-canonical completion log](./PLAN-ARCHIVE.md#stage-3--native-canonical-completion-log-archived-2026-06-14).**
The native LLVM backend is canonical (2026-06-12 flip): `make medaka` builds it
OCaml-free; all PRE-FLIP-GAPS soundness/capability gaps (G1–G9) closed; the full
TYPECHECK-AUDIT (16 findings — S1·S2·T1·T1b·T2·S3·C1·C2·C3·C6·C7·C8·C9·OBS3·OBS4)
closed; the construct-coverage sweep + all four native dispatch gaps (#54/#55/#50/#21)
closed; perf bar-4 done (5.68× self-compile / ~59× vs interp — `compiler/PERF-RESULTS.md`);
the Phase-C native-CLI capstone + Stage-4 tooling port (fmt/test/new/repl/build/lsp) done;
**gate re-rooting done** (all correctness gates OCaml-free — `compiler/REROOT-PLAN.md`);
the **single-file/multi-module driver collapse done** (`compiler/DRIVER-COLLAPSE-PLAN.md`,
closes audit §6; `medaka check` now resolves imports).

**Soak / Stage 3 status:** COMPLETE as of 2026-06-26. Closed 2026-06-14: `argStampEnabled`
eval-vs-emit dispatch unification — `compiler/ARGSTAMP-UNIFY-PLAN.md`, STATUS: COMPLETE,
retires the finer dispatch fork the driver collapse left, the shared root of #55/#21. Closed
2026-06-15: native-emit scale failure `unbound 'not'` — fuzzer 5%→100%; foldMap
method-level-constraint dict gap — eval_dict 25/0; whole-float rendering canonical `1.0`.)

**Gated milestone — retire `lib/*.ml`.** ✅ **DONE (2026-06-26):** `lib/`+`bin/`+
`gen/`+`dev/` deleted; tag `oracle-frozen` preserves the last OCaml-present commit.
**Re-rooting ✅ DONE (2026-06-13):** every correctness gate runs OCaml-free
(`compiler/REROOT-PLAN.md`). **Stage 3 is COMPLETE.**

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
| **0.1.0 — native binary distribution (mac/linux `medaka build`)** | 0.1.0 release | [`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md) (D0 Linux spike first) |
| **0.1.0 — playground polished into a front door** | 0.1.0 release | [`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) §W2; [`PLAYGROUND-DESIGN.md`](./PLAYGROUND-DESIGN.md) |
| **0.1.0 — Val-authored quickstart / language overview** | 0.1.0 release | [`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) §W3 (serialization bottleneck — start early) |
| **0.1.0 — stdlib reference docs (agent-generated via `medaka doc`)** | 0.1.0 release | [`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) §W4 |
| **0.1.0 — curated public repo (downstream export) + LICENSE + KNOWN-GAPS** | 0.1.0 release | [`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) §W5/W6/W7 |
| **0.1.0 — release hygiene (`--version`, release CI matrix, crash→report)** | 0.1.0 release | [`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) §W8 |
| **0.1.0 — editor extension published (`.vsix`)** | 0.1.0 release | [`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) §W9 |
| **0.1.0 — fs/net in the tree-walk interpreter (side quest, non-blocking)** | 0.1.0 release | [`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) §4 |
| **Native TMC parity — port WasmGC `b′` dispatch-into-single-target TMC to the native LLVM emitter** | Native backend / distribution | [`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md) §3a/D2 Track 2; template [`compiler/WASMGC-TRMC-DESIGN.md`](./compiler/WASMGC-TRMC-DESIGN.md) §1. Fixes the lexer token-spine overflow at root; native↔wasm parity; robustness vs long lists. Fast-follow (not a 0.1.0 blocker — big-stack pthread covers it). |
| **Recursion-depth guard — clean `nesting too deep` diagnostic instead of segfault on adversarial deep input** | Compiler / error-quality | [`DISTRIBUTION-DESIGN.md`](./DISTRIBUTION-DESIGN.md) §D2 Track 3. Makes "never crash on any input" true (with big-stack); aligns with error-quality workstream. |
| Confidence-gated `lib/` (OCaml) removal — the soak tail | ✅ DONE 2026-06-26 | see top status entry |
| Manifest emission (`[package.capabilities]` from a verified entry's effect row) | Capability-effects | this file → [wedge sequence](#capability-effects-wedge--near-term-sequence); [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §5a |
| WS-3b builtin-extern label flip (`getEnv`/`runCommand`, plus FileRead/FileWrite path refinement) | Capability-effects | ✅ DONE 2026-07-01 (`2d010b2`) — see [`EFFECTS-CONFORMANCE-ROADMAP.md`](./EFFECTS-CONFORMANCE-ROADMAP.md) |
| WS-5 extern-row assurance (standing discipline) | Capability-effects | [`EFFECTS-CONFORMANCE-ROADMAP.md`](./EFFECTS-CONFORMANCE-ROADMAP.md) |
| Phase 146b — parameterized effects (`<Fetch "x.com">`, `<KV "ns">`) | Capability-effects | [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §6a |
| `hashName`/`dictTag` i32-vs-i64 width (layer-17, self-consistent) | WasmGC backend | [`compiler/WASM-SELFHOST-ROADMAP.md`](./compiler/WASM-SELFHOST-ROADMAP.md) |
| `List_andThen`/`flatMap` overflow (layer-18, latent) | WasmGC backend | [`compiler/WASM-SELFHOST-ROADMAP.md`](./compiler/WASM-SELFHOST-ROADMAP.md) |
| `wasm-opt` perf pass (eventual) | WasmGC backend | [`compiler/WASMGC-DESIGN.md`](./compiler/WASMGC-DESIGN.md) §9 |
| **Bug C** — `toList` on an imported `Map` mis-resolves to the `Foldable` method | Compiler / language | ✅ DONE (2026-06-23, `0d40398`) — see [Compiler / language](#compiler--language) |
| Empty annotated multi-type-param container literal (`Map { } : Map Int Int`) rejected at `check` | Compiler / language | ✅ DONE (2026-06-23, `98afb77`) — see [Compiler / language](#compiler--language) |
| 🔴 Constrained user fn shadowing a prelude free fn → `run≠build` (`unbound $dict_<name>_0` on run, build OK) | Compiler / language | ✅ DONE (2026-06-28, `0c7cb79`) — NOT collect_arities (filed cause disproven); typecheck `discoverPromotedModules` pinned the shadow via the prelude SIGNATURE; fix `dropShadowedCore` drops shadowed core defs+sigs; isEven/isOdd re-added; memory `project_sqlite_review_batch` |
| 🔴 Constrained fn passed as a first-class HOF arg (`filter myParity [..]`) → BUILD fails `unsupported Core IR node CDict` (run OK) | Compiler / language | ✅ DONE (2026-06-28, `67c1b0b`) — new `emitDictValue` emits a dict-capturing closure for CDict-in-value-position (E22/PAP machinery, EMITTER-GAPS E23); run==build for filter/map/user-HOF |
| 🔴 wasm: CDict/CMethod-as-value emit a truncated call (no closure capture) — wasm analog of the above | Compiler / language | ✅ DONE (2026-06-28, `c300c9f`) — eta-expand to a lambda through `emitClosure`; diff_wasm 139/0, run==build==wasm (node v24) |
| 🟢 wasm: real-prelude point-free impl arity — foldMap-class impls emit under-applied `fold step empty` (missing container arg) → assemble_check func 1800 / diff_wasm_modules GAP | Compiler / language | ✅ DONE (2026-06-29, `fbbe633` concrete-impl path + `e68365c` DEFAULT-define path) — both `gatherImplGroup` and `emitDefaultDefineW` define arity now add the leading `requires`-dict count (`methodArityOf m + nDicts`), mirroring LLVM. `diff_wasm_modules` 0/20-gap → 22/0. The default-path twin triggers on a CROSS-MODULE impl of a prelude interface (`impl Foldable Bag` in a user file → keeps the default fallback → `foldMap`@Bag routes through `emitDefaultDefineW`) |
| 🟢 eval: constrained cross-module unspecialized DEFAULT method `no matching impl for dispatch` (run≠build) | Compiler / language | ✅ DONE (2026-06-29, `6b86824`) — `eval.mdk` `pickByTag`: when a route tag matches NO impl candidate, select the untagged interface DEFAULT (a bare VClosure/VThunk, never a VTypedImpl) so a CONSTRAINED default body runs with its forwarded method-level dict — mirrors LLVM `emitDefaultRKey`. Was: all sibling specialized defaults applied to the wrong receiver → hard panic. `foldMap`@Bag run==build (`[1,1,2,2,3,3]`); `length`@Bag control intact; fixture `test/eval_typed_modules_fixtures/cross_module_default_constrained/` (loader path). Eval-contained, ~12 lines |
| 🟢 Poly literal as a HOF arg → HOF spuriously `Num`-constrained w/ phantom dict param → runtime SIGTRAP | Compiler / language | ✅ DONE (2026-06-28, `a57378b`, seed re-minted) — the RUNTIME-CRASH FACE (FACE 2) of the slice-7/gap-3/#23 cluster. `app2 f = f 2 3; main = println (app2 (==))` BUILT but exited 133; now run==build==`False` (orchestrator-reverified on current main `e9f5866`, both exit 0). Root cause was inferred-constraint **iface-loss** (`ifaceForConstraintId` returns `""` on a compound `fromInt` occ → silent `RNone`), NOT the arg-stamp framing — fixed typecheck-only via `ifaceForInferredId` + `processSCC` call/dict-delta Num-defaulting. WasmGC E24 peer also fixed (`d143972`). memory `project_gap3_slice7_two_distinct_bugs`. Remaining residual = the build-rejection generic-free-fn face (next row), still deferred. |
| Phase 101b — `Arbitrary`-driven nested parametric generators (deferred) | Compiler / language | this file → [Compiler / language](#compiler--language) |
| ✅ emitter: `scanExprRecords` traverses `CArray` but not `CList` → a record constructed inside a list literal misses field-layout registration → `CFieldAccess: unknown field` | Compiler / language (emitter) | ✅ DONE 2026-06-29 (`73d51c0`) — added `scanExprRecords (CList es) = scanExprsRecords es`; run==build, fixpoint C3a/C3b YES, fixture `record_in_list` |
| ✅ emitter: **type-unaware field resolution** — `findFieldIdx`/`findRecordByLabel` (`llvm_emit.mdk` ~7636) resolved `CFieldAccess` by LABEL only, ignoring the receiver's record type → two records sharing a field name **at different indices** loaded the wrong offset → garbage (data) / SIGSEGV (function field). (The mis-filed "cross-module function-field SIGSEGV" framing was DISPROVEN — `collectRecords` runs over the whole merged program; the real root was label-only resolution.) | Compiler / language (emitter) | ✅ DONE 2026-06-29 (`5049b43`, seed re-minted) — widened `EFieldAccess`/`CFieldAccess` to carry the typecheck-resolved record name (Bug-3 `Ref String` idiom); emitter resolves by `(record,label)` with label-only fallback; also fixed the same-root float-field-by-label bug. Diagnose-first caught that `resolveFieldRecord` returns a MANGLED name on the emit path (record name = ctor, mangled `<mid>__<name>`) → new mangle-aware `lookupRecordByMangledHead`. run==build (Int/function/Float collisions), fixpoint C3a/C3b YES, full `diff_compiler_*` 0-failing, fixture `field_collision`. |
| Generic `Thenable m =>` multi-clause fn w/ return-pos `pure` stack-overflows in eval | Compiler / language | ✅ DONE (2026-06-25) — was an oracle-only artifact, already correct on canonical native; see [Compiler / language](#compiler--language) |
| Point-free constrained binding (`f = g identity`) mis-dispatches return-pos `pure` | Compiler / language | ✅ DONE (2026-06-25, `bf7243c`) — CDict-spine eta-saturation; see [Compiler / language](#compiler--language) |
| Per-method-constraint dict conflated w/ dispatch type's own instance — blocked `Traversable` interface | Compiler / language | ✅ DONE (2026-06-25, `104c69a` + `b5ae3a2`) — `Traversable t` shipped; see [Compiler / language](#compiler--language) |
| `sequence` only dispatches per-impl; default-method form misdispatches | Compiler / language | ✅ DONE (2026-06-26, `f333125`) — `sequence` is now a `Traversable` default via universal default-method specialization; see [Compiler / language](#compiler--language) |
| Generic prelude free-fn over a typeclass with generic/primitive receiver fails `build` (slice-7) — DEFERRED (zero callers; cross-cutting A+B; = ARGSTAMP-UNIFY irreducible residual) | Compiler / language | [`GAP3-SLICE7-DESIGN.md`](./GAP3-SLICE7-DESIGN.md); this file → [Compiler / language](#compiler--language) |
| Ambiguous return-position interface constraint silently mis-resolved (`run≠build`) | Compiler / language | ✅ DONE (2026-06-26, `d6e59aa`) — typecheck rejects ambiguous constraints; see [Compiler / language](#compiler--language) + [`RETPOS-DISPATCH-DESIGN.md`](./RETPOS-DISPATCH-DESIGN.md) |
| Bug 1 — comparison OPERATORS (`==`/`<`/…) on a bare constraint tyvar mis-route (`RNone`→arg-tag) → `run≠build` wrong value (HashSet/HashMap of non-primitives silently wrong) | Compiler / language | ✅ DONE (2026-06-27, `7450cf6`) — route enclosing fn's forwarded class dict via `enclDictVarOf`; memory `project_comparison_operator_forwarded_dict_bug` |
| Bug 2 — partial/escaping typeclass-method closure doesn't capture forwarded dict → `run≠build` SIGSEGV/empty (even `Int`) | Compiler / language | ✅ DONE (2026-06-27, `95ee25b`) — `emitMethodPap` + `defArityOf` define-arity table; memory `project_partial_method_closure_dict_capture_bug` |
| Bug 3 — String `.[]` index/slice sugar array-indexes a String (`CIndex`/`CSlice` type-lost) → `run≠build` wrong Char/oob | Compiler / language | ✅ DONE (2026-06-27, `493a5eb` String + `b9739ee` List) — new `CStringIndex`/`CStringSlice` + `CListIndex`/`CListSlice` nodes; memory `project_string_index_slice_emit_bug` |
| Bug 4 — polymorphic-Unit `main` (tyvar→Unit via HOF) auto-prints spurious `0` on build (`mainIsUnit` gate doesn't zonk) | Compiler / language | ✅ DONE (2026-06-27, `9f83b42`) — `mainTypeIsUnit` normalizes scheme → `installMainIsUnitHint`; memory `project_polymorphic_unit_main_autoprint_bug` |
| OCaml oracle removed (2026-06-26) — prelude no longer typechecks under OCaml (`sequence` default body) | ✅ DONE | see top status entry |
| Phase 149 (proposed) — record rest-capture + construction spread sugar | Compiler / language | this file → [Compiler / language](#compiler--language) |
| D7 (latent, verified), foldMap RNone emit-site (latent, verified), helper dedup, deferred GC/TRMC seams | Self-host internals | this file → [Self-host … open items](#self-host-typecheck--dispatch--runtime--known-open-items) |
| Leading-`|` `data` decls (native-only by design; now the sole ground truth since `lib/` removed) | Parser | this file → [Known parser gaps](#known-parser-gaps-compiler-parsermdk) |
| `<>` Semigroup operator (not lexed); JSON pretty-printer + `ToJson`/`FromJson`; single-codepoint string indexing; effect-label refinement | Stdlib | [`STDLIB.md`](./STDLIB.md) §"Remaining work" / §"Label refinement roadmap" |
| Diagnostic-position follow-ups (parse-error column accuracy; pattern-position spans; guard-exhaustiveness + multi-module match warnings still `None`) | Tooling / diagnostics | this file → [Stage 4](#stage-4--full-tooling-port--native-medaka-retire-ocaml-decided-2026-06-10); [`compiler/DIAGNOSTICS-SURFACING-PLAN.md`](./compiler/DIAGNOSTICS-SURFACING-PLAN.md) |
| Auxiliary port: `coverage.ml` + `bench_runner.ml` (port last) | Tooling | this file → [Stage 4](#stage-4--full-tooling-port--native-medaka-retire-ocaml-decided-2026-06-10) |
| Structured type-error ADT (replace string messages; enables LSP error codes/quickfixes) | Parked ideas / diagnostics | this file → "Future idea (parked): structured type-error ADT"; [`compiler/DIAGNOSTICS-SURFACING-PLAN.md`](./compiler/DIAGNOSTICS-SURFACING-PLAN.md) |
| Effect-reannotation utility; stack-performance recursion lint; bare effectful statements (drop `let _ =`) | Parked ideas | this file → the three "Future idea (parked)" sections below |
| `medaka add`/`remove`/`update` + `medaka.lock` | Blocked (needs package manager) | this file → [Blocked on a package manager](#blocked-on-a-package-manager-out-of-scope-until-one-exists) |

*Won't-do decisions (NUMLIT `fromInt` revert, Phase 78c, the rejected-features list) are in the [Won't-do](#wont-do-kept-intentional) section, not here.*

### Stage 4 — full tooling port → native `medaka`, retire OCaml (decided 2026-06-10)

**Stage 4 (full tooling port → native `medaka`) — ✅ COMPLETE.** All six tools —
`fmt` / `test` / `new` / `repl` / `build` / `lsp` — were ported to Medaka and
differential-tested byte-identical vs OCaml, and the **Phase-C native-CLI capstone**
(`compiler/driver/medaka_cli.mdk`, Slices 0–4) is done: the native `medaka` binary does
all 8 subcommands (`check`/`fmt`/`new`/`build`/`run`/`test`/`repl`/`lsp`) with no OCaml at
runtime. Full per-tool / per-slice completion log archived in
[PLAN-ARCHIVE.md → Stage 4 — tooling-port completion log](./PLAN-ARCHIVE.md#stage-4--tooling-port-completion-log-archived-2026-06-14).

**Remaining (minor, not retirement-blocking):**
- **Diagnostics surfacing layer** — ✅ **substantially DONE (2026-06-21, WS-4/F6,
  `compiler/DIAGNOSTICS-SURFACING-PLAN.md`).** Native `medaka check` now prints
  positioned, humane, **carat-rendered** diagnostics (`file:L:C: message` + source line
  + `^`, on stderr) for parse/type/resolve, byte-identical to the OCaml oracle; resolve
  errors carry real spans (`Option Loc` threaded through the resolve walk); non-exhaustive
  match warnings carry a span. Gates: `diff_compiler_check_json` 9/0, `diff_native_cli`
  `error/*` 7/7 vs live oracle + 99/0 overall, fixpoint C3a/C3b YES, seed re-minted.
  **Open position-accuracy follow-ups** (separate, not blocking): parse-error column is
  "which-token"-wrong on non-trivial inputs (deeper self-hosted-parser position tracking);
  pattern-position errors inherit the enclosing-`match` span; guard-exhaustiveness +
  multi-module warnings still `None`. See the plan doc's residuals.
- **Auxiliary port:** `coverage.ml` + `bench_runner.ml` — port last.

### Future idea (parked, not scheduled): structured type-error ADT (replace string messages)

**Current state:** `compiler/types/typecheck.mdk` represents type errors as plain `String`
messages — `pushTypeError : String -> <Mut> Unit` (dedups + accumulates), with each error's
wording produced by a per-error message-builder function (`ambiguousImplMsg`, `effectParamMsg`,
`effectLeakMsg`, …). ~34 raise sites. There is **no `TypeError` ADT / `ppError` printer** (that
was the removed OCaml `lib/typecheck.ml`). The string+builder approach works and is golden-gated.

**Idea:** introduce a structured `TypeError` ADT — one variant per error kind carrying its
payload (names + `Mono`s) — with a single `ppError` renderer. Benefits are about **structured
diagnostics**, not the messages themselves: stable error **codes/categories** (LSP `code`/`tags`),
**quickfix code actions** keyed by error kind, machine-readable diagnostics, and rendering
consistency enforced structurally (the shared-naming-context concern — two tyvars both printing
`a` — becomes a single chokepoint instead of per-builder discipline).

**Why parked:** non-trivial churn in the **hottest in-graph file** (every change there needs
`selfcompile_fixpoint` + a seed re-mint) across ~34 sites + goldens, for no behavioral gain
today. It only pays off once we want structured LSP diagnostics. **Lands naturally as the
enabling refactor for** [`compiler/DIAGNOSTICS-SURFACING-PLAN.md`](./compiler/DIAGNOSTICS-SURFACING-PLAN.md)
work (error codes + LSP quickfixes) — schedule it there, not standalone. Until then the
string+builder idiom is the convention (the `harden-typechecker` skill documents this).

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
across `compiler/`. The `_` exists only to give the effect a place in a `let`-chain; the binding
carries no value. Verbose, and `do`-notation doesn't cover it (no monad to thread in plain Unit-IO).
The **same `let _ =` tax also applies *inside* a `do` block** for an effect statement: a bare statement
in a monadic block is a `>>` and must be in the block's monad, so an `<IO>`/`<Mut>` call there must be
written `let _ = effectfulCall` (the motivating case: `sqlite/lib/dbwriter.mdk buildLeafPage`). With `?`
removed and `do`/`<-` the single monadic-bind form (2026-06-25), this `let _ =` tax is the only residual
of mixing effects with a value-monad — which is what makes this idea worth picking up.

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
`types/typecheck.mdk`. Mirror in `SYNTAX.md`. User deferred
2026-06-21; follow-up only.

### Capability-effects wedge — near-term sequence

**Owning roadmap:** [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md) §9 (language
work) + [`CAPABILITY-PLATFORM.md`](./CAPABILITY-PLATFORM.md) §10 (product/runtime).
Architecture context: the "Targets & the WASM soft-pivot" callout above. Effect
labels also drive [`STDLIB.md`](./STDLIB.md) §"Label refinement roadmap".

**Done (foundation):** effect soundness — propagation/inference, higher-order `<e>`
composition, binding-boundary escape, laundering soundness — gap 1, reference +
compiler mirror ✅; user-definable fine-grained labels (`effect Foo` declaration) —
gap 2 ✅; cross-module effect label export (`exp_effects` across the loader
boundary) — gap 3 ✅; stdlib capability audit ✅; the minimal **"wow" demo** ✅
(`demo/plugin_good.mdk` + `demo/plugin_malicious.mdk` + `medaka check-policy`: the
malicious plugin buries `fetch` four calls deep; the harness rejects it with the
full call chain). Detail in CAPABILITY-EFFECTS §5a + the Phase 146 entry below.
**✅ DONE 2026-07-01:** the WS-3b builtin-extern flip (`getEnv`/`runCommand` →
`<Env _>`/`<Exec _>`) and the file-path domain refinement (FileRead/FileWrite →
`<FileRead _>`/`<FileWrite _>`), the last soak-tail items blocked on the
now-removed frozen OCaml oracle — see `EFFECTS-CONFORMANCE-ROADMAP.md` for detail.

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
Current native-backend state + residual gaps: `compiler/BOOTSTRAP.md`,
`compiler/EMITTER-GAPS.md`. Forward work:
[Stage 3](#stage-3--make-the-llvm-backend-canonical-retire-ocaml).

### Self-host (Stage 1 tail)

#### Known parser gaps (compiler `parser.mdk`)

Constructs the **OCaml parser accepts but `compiler/parser.mdk` rejects** — check
here before assuming `compiler/` can parse a construct (AGENTS.md points here).
The differential `test/diff_compiler_parse*` / `diff_compiler_check*` gates only
cover the corpus; these are known holes outside it.

- **Leading-`|` `data` declarations.** Native parser accepts `data T =⏎ | A | B`;
  the OCaml parser (now removed) rejected them. **Native-only — now the sole ground truth.** See
  `LAYOUT-SEMANTICS.md` §9 (AUDIT P-DATAPIPE). Design note: own-line `in` (the `in`
  keyword leading a less/equally-indented line after a `let`) is **rejected by both
  parsers by design** — no `parse-error(t)` feedback loop; see `LAYOUT-SEMANTICS.md`
  §9/§11 and `no-parser-layout-feedback` decision memory.

- **Scientific-notation float literals (`1e12`, `1.5e-3`) rejected (lexer gap, native).**
  The lexer's `scanNumber` (`compiler/frontend/lexer.mdk`) does not recognize an exponent
  marker, so `1e12` lexes as `1` followed by the identifier `e12` ("Unbound variable: e12")
  and `1.5e-3` becomes a type error. **Radix/separator literals already work** — hex/bin/oct
  (`0x0D`/`0b1010`/`0o17`) and `_` digit separators (`1_000`) all parse and eval today; the
  exponent form is the one remaining numeric-literal representation still missing. Cross-ref
  the `float-literal-native-gaps` memory (gap B). Low priority (workaround: write the expanded
  decimal, e.g. `1000000000000.0`); fix is contained to the lexer's number scanner +
  parser/AST float construction. Verified open 2026-06-26.

- **SQLite-dogfood findings (2026-06-23, minor — DEFERRED, workarounds exist; affect BOTH
  compilers, so not compiler-only gaps).** Surfaced building the pure-Medaka SQLite reader;
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
     now lowers to `PCon name [PWild for unmentioned fields]` (declared field order from the ctor's
     field table), mirroring the logic in OCaml `lib/exhaust.ml` [now removed]. Soundness preserved (genuine non-exhaustive
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
     **UPDATE (2026-06-27):** the general fn-level re-key LANDED — `inferDictAtFound` now keys a
     cross-module constrained callee's dict arity by import-source module (the `(definer,name)` qual
     tables) instead of bare first-match. The same root also produced a sharper, separately-reproduced
     symptom: a direct cross-module import of two same-named different-`=>`-arity constrained fns
     **crashes `medaka run`** (`applied non-function`), not just the doctest `unbound constrained fn`.
     Both are addressed for DIRECT/explicit imports; a doctest that imports the fn via wildcard
     `import sibling.*` still falls back to bare (annotate, or use an explicit-name import). See the
     standing item below + `compiler/WS2-REKEY-DIAGNOSIS.md`.
  7. **OCaml-oracle-only false-reject (resolved — oracle removed 2026-06-26):** `let w = rtWidth ra` inside a
     `RowType a -> RowType b` body made the frozen OCaml oracle reject ("signature more general
     than body"); native always accepted + ran correctly. Non-issue now that native is the sole compiler.
  8. ✅ **Large integer literal (|n| ≥ 2^61) mis-tagged in `medaka build`.**
     **FIXED (2026-06-24, `9a7ace0`, native, emitter — out of self-compile graph so no fixpoint/seed).**
     `llvm_emit.mdk`'s `emitLit` computed the tagged immediate `n*2+1` in the emitter's own 63-bit
     Medaka Int, which overflowed for |n| ≥ 2^61 (e.g. the IEEE-754 bits for `1.0`,
     `4607182418800017408`, built to `-inf`). Now, for |n| ≥ 2^61 it emits a full-width LLVM
     `shl i64 n, 1` + `or i64 …, 1` (via the existing `tagInt` helper); small literals keep the direct
     immediate path unchanged. Fixture `test/llvm_fixtures/lit_int_large_tag.mdk`; `diff_compiler_llvm`
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
  Previously compiler-only; now both accept e.g. `f x =⏎  let go n = … in go x`.

- ✅ **Lexical-addressing perf hook — eval-consumption half. CLOSED (non-win on
  the tree-walker; 2026-06-05).** Wired `annotateProgram` into the single-file eval
  path and measured: correct (18/18 EVAL goldens byte-identical with `EVarAt`
  consume active; the slot/name assert never fires) but **~2.5% slower** than the
  by-name baseline (`fib 25`), independently re-confirming the earlier finding
  (list-indexed neutral, array frames −14%). Reverted the wiring; the `EVarAt` arm
  stays dormant. The lever's payoff is captured by the native LLVM backend; the
  bytecode VM (§2.2) that previously held this note was removed 2026-06-10. Do not
  re-attempt on the tree-walker. See `compiler/PERF-NOTES.md`.

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
  once structured `requires` routes land. **Confirmed LATENT — re-verified mechanistically
  2026-06-26.** The runtime dict word is **head-tag-only**: two constraints on one tyvar
  instantiated at the same type `T` carry the *same* head tag, and at a dispatch site the
  emitter (`llvm_emit.mdk emitMethodDispatchChain`) / eval (`narrowMethod`) load that head
  tag and switch over *the call-site method name's* impls — so even if D7 forwarded the
  wrong slot, `eq` vs `hash` still select the right impl. D7 only becomes OBSERVABLE once a
  dict cell carries something finer than the head tag for one tyvar — i.e. the **L2
  richer-dict-rep / structured-`requires`** direction (not landed). **Decision (2026-06-26):
  DEFER the `(iface, id)` re-keying until L2 lands, then do it together so it can be tested
  observably — a standalone robustness-only change trips the documented surviving-unify-var-id
  route-keying fragility (audit §Architecture #2) for zero behavioral gain.** Concrete keying
  plan (type `(Int,String)`→`(Int,String,String)`; writers `:7756/7867/7954/8493/8838`;
  readers need a `methodName→iface` registry threaded to `:1841/5309/5506/6510`) is recorded
  in the D7 investigation report. Owner: [`compiler/TYPECHECK-AUDIT.md`](./compiler/TYPECHECK-AUDIT.md) §D7.
- **D8 — `annotate.mdk` `DoLet` ignores `rec`.** The `DoLet` arm annotates the RHS
  before pushing the binding, so a `let rec` inside a `do`-block can't see its own name
  during annotation. **Confirmed DORMANT (2026-06-23):** `annotate.mdk` is the reverted
  lexical-addressing pass — NO driver runs it (eval.mdk:966-974), so this is dead code; a
  recursive do-let works on native run/build/oracle. Fix only if `annotate` is ever
  reactivated. Owner: [`compiler/TYPECHECK-AUDIT.md`](./compiler/TYPECHECK-AUDIT.md) §D8.
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
  from the eval-path `foldMap` dict gap already closed. Owner: [`compiler/DISPATCH-INVENTORY.md`](./compiler/DISPATCH-INVENTORY.md) §D3a.
- **Cross-module bare-name dict-arity collision (the D2 re-key / Phase 134 root) — fn-level OBSERVABLE collision CLOSED (2026-06-27); only the wildcard/re-export bare-fallback residual remains.**
  `Dict_pass.collect_arities` keys function arity by **bare name**, so when the prelude + all modules are
  dict-passed *jointly*, a genuinely-constrained function in one module (or the synthetic doctest
  bindings) can force spurious leading dict params onto an *unconstrained, same-named or unannotated*
  function elsewhere — its call site then under-applies / it becomes a constrained fn whose dict is
  never bound. **Observable manifestation (fn-level) — a run≠build CRASH, not the previously-filed
  doctest `unbound constrained fn`:** a module that **imports** a constrained fn directly while a
  *different-`=>`-arity* same-named constrained fn lives in another dependency hits the bare first-match
  in the jointly-seeded `funConstraintsRef`, which returns the most-recently-PREPENDED *foreign* module's
  arity → the call over-applies → `medaka run` crashes `applied non-function`; `check` accepts and `build`
  is saved by universal mangling.
  **✅ FIXED (2026-06-27, fn-level, `compiler/types/typecheck.mdk` only, NO AST node, seed re-minted).**
  The `WS2-REKEY-DIAGNOSIS.md` "benign by construction" verdict was **REFUTED by reproduction** (it
  assumed the importer *defines* the colliding callee; the wrapper-isolated fixtures hid the direct-import
  shape). Fix: `inferDictAtFound` resolves a cross-module constrained callee's dict arity by MODULE
  IDENTITY — a per-module `currentImportDefinersRef` (imported value name → import-source module id from
  `prog`'s `DUse`, via `importDefinersOf`) keys the existing `(definer,name)` qual arity table
  `crossModuleFunConstraintsQualRef` + a new slot-parallel ifaces mirror
  `crossModuleFunConstraintIfacesQualRef`; the bare first-match survives only as the fallback for wildcard
  `import mod.*` and re-exports (import source ≠ definer). Byte-identical on the corpus; regression
  `test/eval_typed_modules_fixtures/cross_module_dict_arity_direct/` (both orientations, drives
  `evalModules`). All `diff_compiler_*` 0-failing, fixpoint C3a/C3b YES, cold `bootstrap_from_seed` PASS.
  **Residual (deferred, now purely hygienic — zero observable payoff):** retiring the bare fallback for the
  wildcard/re-export corner needs the full AST-origin `EVarFrom` re-key (resolve must resolve a reference
  to its ORIGINAL definer through diamonds) designed in `WS2-REKEY-DIAGNOSIS.md`. Owners:
  `compiler/WS2-REKEY-DIAGNOSIS.md` + memory `project_dict_semantics_spec` (D2).
  **CORRECTION (2026-06-25):** A DISTINCT cross-module method-constraint failure — where a non-prelude
  sibling-module `interface` method carrying a USER `=>` constraint (`btraverse : Thenable m => …`)
  mis-dispatched cross-module (`check` accepted, `run` panicked, `build` SIGSEGVd) — is **CLOSED
  (`221af36`)** via a read-side `alignedMethodConstraintIds` helper in `recordMethodDicts`
  (`compiler/types/typecheck.mdk`). Its root was **stale-sweep first-match shadowing** (NOT the
  bare-name collision the D2 fn-level EVarFrom re-key addresses): `methodConstraintsRef` accumulates
  multiple entries per method from successive elaborate sweeps; `recordMethodDicts` took the bare
  first-match whose ids were disjoint from the live instantiation subst → empty dict route.
  The fix picks the entry whose ids most-overlap the live subst (falls back to first-match when
  none overlap — byte-identical on single-sweep fixtures). Fixture: `cross_module_method_userconstraint/`
  (direct sibling import). (The fn-level collision is now CLOSED — see the ✅ FIXED note above; only the bare-fallback wildcard/re-export corner of the `EVarFrom` full re-key stays deferred.)
- **`export import` re-export not threaded into the typecheck seed — CLOSED (`a35c87b`).** A value /
  function / interface-method re-exported through an intermediate module via `export import` was
  `Unbound` at the importer (any number of hops). Root: `publicValNames` collected only DEFINED names;
  `DUse` (what `export import` lowers to) fell through its catch-all, so a re-export-only module seeded
  an EMPTY `pubV` into typecheck's `depEnv`. Resolve already had the full re-export set — typecheck
  never mirrored it. Fix: a general `reexportSeed prog depEnv` helper (typecheck.mdk) walks `DUse True`
  decls, resolves each re-exported member against the source dep's `pubV` via `importFormSchemes` /
  `usePathModuleId` (schemes threaded by IDENTITY — never re-generalized, preserving original-definer
  constraint ids so `221af36`'s alignment stays diamond-safe), appended to `pubV` at all four driver
  loops. Covers value/fn/method re-exports, transitive chains, no private-name leak. New fixture:
  `cross_module_method_userconstraint_diamond/` (leaf→mid→main via `export import`). Gates:
  `diff_compiler_eval_typed_modules` 8/0, `diff_compiler_eval_dict` 28/0,
  `diff_compiler_typecheck_errors` 40/0, `diff_compiler_build` 36/0, fixpoint C3a/C3b YES.
- **F1b — loader module identity (cross-package double-load) — ✅ DONE (2026-06-25, `ac4b04a` + extern
  `33972aa`, seed re-minted `6a1a67e`; native-only).** The loader keyed modules by the dotted module-id
  STRING, so the SAME file reached via two import spellings (a dep's rebased `import lib.byteparser` vs the
  dep-name `import byteparser.lib.byteparser`) got two modIds → loaded TWICE → `conflicting impl` in
  `checkCoherence`. **Fix (loader-contained, design [`F1B-MODULE-IDENTITY-DESIGN.md`](./F1B-MODULE-IDENTITY-DESIGN.md)):**
  the loader now rewrites every `DUse` to ONE canonical dep-name-prefixed modId derived from WHERE the
  import resolves (`canonicalModId`/`revLookupRoot`/`rewriteUsePath`/`rewriteDecls` in
  `compiler/driver/loader.mdk`, applied in `visitMod`/`visitModF`). Both spellings collapse to one string
  before resolve/typecheck/eval (which stay string-keyed) see them — so resolve/typecheck/eval were NOT
  touched (containment held; verified by fixpoint). Single-root loads are a provable no-op (`deps=[]` →
  `revLookupRoot` always `None` → no rewrite). **Two-dep-NAMES corner also closed** (`ac4b04a`): the same
  physical file under two different dependency names (`bp = "../x"` vs `byteparser = "../x"`) is collapsed
  via TRUE path identity — a new `canonicalizePath : String -> <FileRead> String` extern (POSIX
  `realpath(3)`, `33972aa`: `runtime.mdk` decl + `medaka_rt.c` + `llvm_preamble`/`llvm_emit` + `compiler/eval/eval.mdk`
  parity) realpath-normalizes roots before the dep-name reverse-lookup, so the first-declared name wins
  deterministically. Gates: new `test/cross_project_twonames.sh` 3/3 (red→green), `cross_project_deps`
  3/3, bootstrap suites at baseline, `diff_native_cli` no new failures, fixpoint C3a/C3b YES, cold
  `bootstrap_from_seed` PASS. **Residual:** none observed — the extern is unwired on the WasmGC leg (the
  loader never runs under wasm; stubbed/noted), and not added to `compiler/eval/eval.mdk` (that eval-probe
  interp omits all file-IO externs by design — the loader only runs as compiled native code).
- **`CFieldAccess` cross-module record dot-access — ✅ RESOLVED as a NON-BUG + diagnostic fix
  (2026-06-25, `e3e7e1b`).** The filed "native emitter panics `CFieldAccess: unknown field`" was DOUBLY
  stale (gap-docs-lie): (1) it's a typecheck/resolve rejection, not an emitter panic — the emitter is
  never reached; (2) the canonical native compiler is **CORRECT** — cross-module record fields (dot-access
  AND destructure, check/run/build) work fully with `public export data X = X { … }` or the `record`
  keyword. The repro used `export data` (without `public`), which is **abstract by design** (ML-style
  opacity: exports the type NAME, not its fields). The real defect was the MISLEADING error
  (`Field x does not belong to record <unknown>` / `Unknown field`). **Fixed:** both the destructure
  (resolve, `4710d3a` — local signal: type in `env.types` but owns no fields) and dot-access (typecheck,
  `e3e7e1b` — needed threading: abstract tycon names reach neither `recordsRef` nor `dataParamKindsRef` in
  an importer, so a whole-program `abstractRecordTypesRef` is seeded once by the multi-module check
  drivers) paths now emit `'Point' is exported abstractly; its field 'x' is not accessible (declare it
  \`public export\` to expose its fields).` Narrow (genuine unknown/wrong fields keep precise errors;
  4 false-positive probes pass). Native-only. Regression: `test/eval_typed_modules_fixtures/
  cross_module_record_fields/` (working behavior) + `test/resolve_module_fixtures/abstract_record_field/`
  (the message). Gates: `diff_compiler_typecheck_errors` 40/0, `eval_typed_modules` 9/0, `resolve_modules`
  13/0, fixpoint C3a/C3b YES, cold bootstrap PASS. **Residual (low, noted):** the dot-access message has
  no native-sourced *multi-module check-error* regression gate (none exists — `check_modules` previously captured
  from the diverging oracle); verified by probes. A latent LSP edge: `abstractRecordTypesRef` is
  overwrite-seeded per multi-module check (not leak-prone on the common path) but a single-file check
  reusing the process could read a stale entry — only mislabels an already-erroring unknown-type field
  access. **Possible follow-up (deferred):** whether `export data` should expose fields by default
  (breaking; collapses `export`/`public export`) — kept abstract-by-default by decision.
- **Pre-existing failing gates (surfaced by the 2026-06-24 full sweep; NOT stale goldens — real
  native-vs-OCaml behavioral divergences; confirmed unrelated to that session's lexer/parser/exhaust
  batch by code inspection):**
  - **`diff_compiler_effect_hole` — 4 ok / 4 failing.** `reject_sibling` / `reject_computed` /
    `reject_outer_computed` + a WS-2 outer-let row all report `native_rejected=0, ocaml_rejected=1`
    in their golden; the OCaml oracle is now removed, so these goldens need re-baselining. The
    underlying question (is native genuinely under-rejecting on α-precision?) still needs diagnosis.
    Potential **capability-soundness gap** (or the gate encodes behavior WS-2 α-precision never shipped).
    Effects-roadmap WS-2 territory. Owners: `EFFECTS-SEMANTICS.md` / memory `project_effects_semantics_spec` (WS-2).
  - **`diff_compiler_lsp_b4` — 5 ok / 1 failing.** `completion empty prefix → full env` golden
    includes an `ocaml_set` comparison that is now stale. Needs golden re-capture against native-only
    completion. Owner: `compiler/tools/lsp.mdk`.
- **Helper duplication (code quality).** ~38 generic-helper clusters duplicated across
  compiler stages; `joinWith`/`joinNl` in `typecheck.mdk`/`eval.mdk` are O(n²) local copies
  despite the O(n) canonical in `support/util.mdk`. Consolidate into `support/`. Owner:
  [`compiler/HELPER-CENSUS.md`](./compiler/HELPER-CENSUS.md).
- **Deferred design seams (not pending work, tracked for provenance):** the `set_ref` write
  barrier (needed only if Boehm GC is ever replaced — [`compiler/RUNTIME-DESIGN.md`](./compiler/RUNTIME-DESIGN.md) §7);
  TRMC Phase 2 F1(b)/F2(b) + the Phase 3 b′ dispatch variant (no corpus target; emit seams
  pre-parameterized — [`compiler/TRMC-DESIGN.md`](./compiler/TRMC-DESIGN.md)). *(The `panic`
  unwind model is resolved by decision — abort, not catchable — see memory
  `no-catchable-panics-isolation`; not an open item.)*


### Compiler / language

- **✅ DONE — four `run≠build` codegen bugs (found + FIXED 2026-06-27). `main` = `9f83b42`, seed re-minted.** While
  re-checking the (already-DONE) L2 structured-dict task, a reproduce-first sweep surfaced four
  distinct bugs where `medaka run` (interpreter, the oracle) is correct but `medaka build` (native
  LLVM) miscompiled. `medaka check` accepted all four — pure backend/route bugs. They survived
  self-compile because the compiler's own source doesn't use these forms. All four are now fixed,
  each diagnose-first + fixpoint C3a/C3b YES + `diff_compiler_build` 0-fail + run==build on the repros.
  - **Bug 1 — comparison OPERATORS on a bare constraint tyvar — ✅ FIXED (`7450cf6`).** Root cause held:
    `resolveBinopSite` left the route `RNone` for a top-level constraint-var operand. Fix: route via a new
    `enclDictVarOf` keyed on `funConstraintsRef[encl]` (enclosing fn's OWN declared constraint slots, by
    fn name — NOT global `activeDictVars`, which is the line vs a stale cross-impl id collision); threaded
    `currentFn` into `pendingBinopSites`. No D7 re-key (D7 not observably broken). `HashSet`/`HashMap`
    membership of non-primitives now correct. (memory `project_comparison_operator_forwarded_dict_bug`)
  - **Bug 2 — partial/escaping typeclass-method closure under a forwarded dict — ✅ FIXED (`95ee25b`).** Filed
    `freeVars`-miss hypothesis REFUTED — two emitter holes on the RDict/RDictFwd path: (A) `emitMethod`
    dispatched under-applied dict-routed methods as saturated → new `emitMethodPap`; (B) closure-returning
    constrained fns eta-saturate to `dict+args+__eta` but call sites under-supply → new define-arity table
    `defArityOf` (signature arity ≠ define arity; the fnArity shortcut broke self-compile). All 7
    case-matrix rows incl. the hardest (bare escaping return) build==run. Ledger EMITTER-GAPS.md **E22**.
    (memory `project_partial_method_closure_dict_capture_bug`)
  - **Bug 3 — String `.[]` index/slice — ✅ FIXED (`493a5eb`).** Root cause held. Fix: typecheck stamps
    a receiver-kind discriminator (AST `Ref String`, the `EBinOp` Route idiom) → new `CStringIndex`/
    `CStringSlice` Core IR nodes (leaves `CIndex`/`CSlice` + the hot array emit arms byte-identical) →
    UTF-8/codepoint-aware string emit. **Sibling Bug 5 — List `.[]` index/slice — ✅ FIXED (`b9739ee`):**
    Bug 3 left List on the array path → garbage on build; mirrored option B with `CListIndex`/`CListSlice`
    + cons-walk C externs `mdk_list_index`/`mdk_list_slice` matching the interpreter exactly. String,
    Array, List `.[]` now all build==run. (memory `project_string_index_slice_emit_bug`)
  - **Bug 4 — polymorphic-Unit `main` spurious `0` — ✅ FIXED (`9f83b42`).** Root cause held. Main's zonked
    result type WAS reachable via `mainSchemeRef` (the channel backing `mainTypeIsAsync`); new
    `mainTypeIsUnit` (normalize scheme → `TCon "Unit"`) threaded to the emitter via `installMainIsUnitHint`,
    consulted by `mainIsUnit`. Value mains still auto-print. (memory `project_polymorphic_unit_main_autoprint_bug`)

- **Return-position `pure` dispatch gaps (the `Traversable` blockers) — ✅ DONE (2026-06-25,
  `b5ae3a2` + `bf7243c` + `104c69a`, seed re-minted `da2469d`).** The three filed gaps that
  blocked promoting `traverse`/`sequence` to a real interface are fixed; `traverse`/`sequence`
  are now a **`Traversable t` typeclass** in `stdlib/core.mdk` (List/Option/Result instances),
  and the free-fn workarounds were removed from `list.mdk`. **Every filed symptom had shifted —
  reproduce-on-current-main beat the doc** (a diagnose-only agent reproduced all three on
  canonical native, `run` vs `build` vs the frozen oracle):
  - **Gap 1 (multi-clause `pure` overflow) — was an oracle-only artifact, ALREADY correct on
    canonical native.** Both native paths evaluated it fine; it survived only as a frozen-`lib/`
    oracle hang. The filed "confirmed on oracle, native unverified" was the tell. No code change.
  - **Gap 2 (point-free `sequence = traverse identity`) — fixed `bf7243c`.** Native `run` was
    already correct; native `build` SIGSEGV'd (the filed `[[1,2,3]]` was the *oracle*). Root: an
    under-applied **CDict-spine** body the emitter's eta-saturation (`methodBodyDeficit` in
    `compiler/backend/llvm_emit.mdk`) skipped (it handled CMethod/CLam spines, not CDict). Fixed
    by mirroring the CMethod handling for CDict.
  - **Gap 3 (per-method-constraint dict conflation — THE interface blocker) — fixed `104c69a`.**
    Native `run` panicked "no matching impl"; native `build` was correct. Root: `inferImplMethod`
    never registered its method-level `=>` constraint dicts into `activeDictVars` (only
    `inferDefaultMethod` did), so the impl body's inner `pure []` routed `RNone` → arg-tag →
    panic. Fixed via a new `registerImplMethodDicts` (the impl-body analog of
    `registerMethodDictSlots`) in `compiler/types/typecheck.mdk`.

  Gaps 2 and 3 are **distinct roots** (opposite halves of the eval/emit path-parity fork —
  emit-hole vs eval-hole — that ARGSTAMP-UNIFY only partly closed), not one shared root. The D2
  re-key hypothesis was disproven (all three repro single-module). Gates: core 38 doctests / 9
  props, list 63 / 12, `diff_compiler_test` 10/0, fixpoint C3a/C3b YES, cold `bootstrap_from_seed`
  C3a PASS. See memory `project_generic_monadic_dispatch_gaps`.

- **`sequence` dispatch residual — ✅ DONE (2026-06-26, `f333125`).** Closed principledly: `sequence`
  is now a real `Traversable` default method (per-impl copies removed) via universal default-method
  specialization (`fillImplDefaults`), plus the emitter/typecheck dict-threading fixes that let
  specialization be universal (encl-aware `registerImplRequires` routing; eta-expand eta-short defaults
  including dict params). Also fixed a pre-existing parametric `Ord` bug (`max [1,2] [1,3]`). See the
  top status entry + `TRAVERSABLE-DEFAULT-METHOD-DESIGN.md` + memory `project_generic_monadic_dispatch_gaps`.

- **Generic prelude free-function over a typeclass with a generic/primitive receiver fails `build`
  (slice-7) — OPEN, DEFERRED (filed 2026-06-26; diagnose-first design pass 2026-06-26, `cc18724`).**
  A truly generic *prelude* free function (e.g. `sequence` as a free fn rather than a method)
  typechecks and RUNS correctly but fails `medaka build` with `arg-tag dispatch on impl type that
  owns no constructors (slice 7: primitive receiver carries no cell tag)`. The `sequence` work
  DODGED this by specializing to concrete receivers; it only bites a future generic prelude free-fn
  over a typeclass with a generic/primitive receiver — **no such stdlib helper exists today (zero
  current callers).** Authoritative design + reproduction: [`GAP3-SLICE7-DESIGN.md`](./GAP3-SLICE7-DESIGN.md).
  - **The filed framing was partly wrong (corrected by the design pass).** Slice-7 fires on the
    **caller's arg-position `debug`**, NOT the inner `traverse`: `debug`'s result mono is an unsolved
    tyvar so its route stays `RNone`, and the emitter arg-tag-dispatches over `debug`'s primitive impl
    groups (Int/String/Char/Bool/Float), which own no cell tag (`typecheck.mdk:1857` `resolveArgStamp`
    `None` arm → `llvm_emit.mdk:3518` `emitTagMatch … [] = gapStr`).
  - **There is a second, hidden defect behind it:** even when slice-7 is dodged (caller pattern-matches
    instead of `debug`), the generic prelude body is **mis-emitted at runtime** — wrong answer (`0` vs
    `3`) or segfault — i.e. the inner generic-receiver dispatch is also broken in codegen.
  - **The real fix is cross-cutting, NOT emitter-only, and is two changes that must ship together:**
    **Fix A** (typecheck arg-stamp grounding, so the site never reaches arg-tag) + **Fix B** (a
    generic-receiver dict-threading ABI change through typecheck/dict_pass/core_ir_lower/llvm_emit, so
    the inner method routes `RDict`). **Fix A alone is a silent miscompile** (turns a clean compile
    error into a wrong-answer/segfault), so A-without-B is forbidden. High blast radius (Fix A perturbs
    arg-position route stamping, the highest-traffic dispatch decision) + a seed re-mint (all four files
    are in the self-compile graph).
  - **Disposition (decided 2026-06-26): DEFER.** Per-impl specialization already delivers a working
    `sequence`; zero current callers; the cost is unjustified now. This is the SAME residual
    [`ARGSTAMP-UNIFY-PLAN.md`](./compiler/ARGSTAMP-UNIFY-PLAN.md) designates "the irreducible primitive
    residual" — schedule it there (with the A+B staging in `GAP3-SLICE7-DESIGN.md` §7) when a real
    generic prelude free-fn forces it. Not a blocker.

- **Ambiguous return-position interface constraint silently mis-resolved (`run ≠ build`) —
  ✅ DONE (2026-06-26, `d6e59aa`, seed re-minted).** Filed as "return-position-only method
  mis-dispatches"; the diagnose-first design pass ([`RETPOS-DISPATCH-DESIGN.md`](./RETPOS-DISPATCH-DESIGN.md))
  **overturned that framing: it was type AMBIGUITY, not dict mis-threading.** In
  `f x = reveal (make (reveal x))` (`f : Thing a => a -> Int`), `make`'s result tyvar is never
  tied to `f`'s constraint var — `f` infers as `a -> Int` with the tyvar appearing nowhere (the
  classic `show . read` ambiguity). The compiler silently resolved the un-anchored `Thing _`
  obligation and the two backends picked DIFFERENT impls (`run` → first-registered, `build` →
  other; both wrong). The RDict return-position machinery was already correct — proven by probe G
  (`g : Thing a => a -> a; g x = make (reveal x)` → `run==build==(1000,2000)`). **Fix
  (typecheck-only, eval/emit untouched): reject the ambiguous constraint** at every generalization
  boundary (mirroring `defaultAmbiguousNum`) — a new `registerAmbiguousConstraints` cluster wired
  at `blockRecLet`/`blockLet`/`inferRecLet`/`inferLetSimple`/`processLetGroup`/`processSCC`
  (`compiler/types/typecheck.mdk`), routing the genuine dispatch mono through the existing
  undetermined-obligation path (`ambiguousImplMsg`, impl-count≥2 guard so a sole-impl interface is
  never over-rejected). Three filters prevent over-rejection (member-type membership keeps probe G
  green; generalization-level; concrete-head-anchored vars). Now `f` and the no-constraint variant
  `h k = reveal (make k)` error cleanly (`ambiguous instance for 'Thing a': cannot determine which
  impl; annotate the type`) on run AND build; probe G unaffected. **Distinct from Gap 3 Fix B**
  (that's argument-position, dict-in-scope-but-unrouted; this is return-position-ambiguous-tyvar) —
  one fix does not cover both. Gates (orchestrator-verified independently): fixpoint C3a/C3b YES;
  `diff_compiler_check` 73/0, `_check_batch` 72/0, `_eval` 23/0, `_build` 36/0, `_typecheck_errors`
  42/0, stdlib core 9/0. Memory: `project_return_position_only_dispatch_bug`.

- **Unqualified-import name collision — use-time ambiguity error — ✅ DONE (2026-06-23, `421a4bd`,
  both compilers).** Two non-`core` modules exporting the same unqualified standalone (e.g. `map`
  and `set` both export `size`/`fromList`/…; also `list`+`set` share `singleton`) previously
  produced a SILENT single-binding collision that differed by compiler (native=leftmost-import wins,
  oracle=rightmost) → wrong-module dispatch (native crash / oracle silent-wrong). Now an unqualified
  USE of such a name emits a located `AmbiguousOccurrence(name, modA, modB)` resolve error (Haskell
  "Ambiguous occurrence" / use-time, user-locked over import-time). Importing both but using no
  colliding name STAYS valid; escape hatch = explicit `import map.{size}` groups or a single import.
  Clean on the 3 risky interactions (Bug-C method+standalone single-module shadow still routes the
  standalone; local-binding shadow wins; disjoint explicit groups). Fix landed in
  `compiler/frontend/resolve.mdk` (the frozen OCaml oracle was also patched for gate parity, and is now removed). Design:
  [`MAP-SET-AMBIGUITY-DESIGN.md`](./MAP-SET-AMBIGUITY-DESIGN.md). Gates: `diff_compiler_resolve` 16/0,
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
  first-match picked the method scheme over the standalone. Fix (`compiler/types/typecheck.mdk`,
  mirrors oracle `lib/typecheck.ml:2293-2329` [removed]): thread the full impl universe into the check
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
  root cause:** the compiler parser can't distinguish an empty `Map { }` from `Set { }`
  (`classifyBrace`, `compiler/frontend/parser.mdk:727`, finds no `=>` entry → `ESetLit "Map" []`),
  so desugar pins a UNARY `Map _a` (wrong arity for binary `Map k v`) and the `EHeadAnnot` unify
  `Map _a` vs `Map Int Int` fails. **Fix** (`compiler/types/typecheck.mdk`, `inferHeadAnnot`,
  mirrors oracle `lib/typecheck.ml:2554` [removed] Phase 114): rebuild the head-pin from the head tycon's
  DECLARED arity (`dataParamKindsRef`) instead of the literal annotation — `applyParams (TCon n)
  (freshVars arity)`, element vars ground via inference. Gates: repro flips (check/run/build → `0`,
  empty/non-empty Map+Set all correct); `medaka test stdlib/map.mdk` → 40 doctests + 7 props, 0
  failed; check/typecheck/eval differentials 0-failing; fixpoint C3a/C3b YES (orchestrator-
  re-verified). **Note:** importing both `map.*` and `set.*` in one file collides on
  `size`/`fromEntries` — pre-existing, unrelated, surfaced only in a combined-import test harness.

- **Num-polymorphic numeric literals — ✅ DONE (2026-06-16, both compilers, run + build).**
  Integer literals in expression position are `Num a`-polymorphic in BOTH the OCaml oracle and
  the compiler/native compiler; `x : Float; x = 0`, `1.0 + 2`, `g : Float -> Float; g x = x + 1`,
  and **polymorphic literal-bearing fns** (`inc x = x + 1` applied to `2.5` → `3.5`) all typecheck,
  `run`, AND `build` correctly (oracle == `medaka run` == `medaka build`). Full design + locked
  decisions: [`NUMLIT-DESIGN.md`](./NUMLIT-DESIGN.md). **Landing log:** Stages 0-2 OCaml (`eac278b`);
  Stages 3-4 compiler+native (`7424b64`); **soundness fix** OCaml (`e7031e6`) + compiler (`183b7b4`);
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
    let-binding) → typechecked then crashed; the compiler constraint tracking was fused with the
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
    reference + compiler mirror ✅; gap 2 (user-definable `effect Foo` labels) ✅;
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
  declarations of foo* here). Fix: in `resolve` (+ compiler `resolve.mdk` mirror),
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
  - **The work (thread through the pipeline + compiler mirror):**
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
    6. **Selfhost mirror** (`compiler/{parser,desugar,typecheck,eval}.mdk`) +
       `SYNTAX.md` entry + `test/parse_fixtures` / round-trip / eval fixtures.
  - Estimate: ~a day (Full scope). Skill: **add-language-feature** (cross-cutting —
    new pattern + construction syntax through parser/ast/typecheck/eval + compiler).

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
  `typecheck.ml` (the tailored error) + compiler `{desugar,typecheck}.mdk` mirror.
  Surfaced when an orchestrated agent misused `do` for IO and mis-filed the failure
  as a "missing IO monad gap" (2026-06-09) — the language is fine; the *diagnostic*
  is the gap. Skill: **add-language-feature** (desugar+typecheck provenance thread;
  not pure harden-typechecker — it needs the desugar tag).

- ~~**Phase 83 / 84 #5 — recursive/nested instance dictionaries**~~ **DONE
  (reference + compiler mirror, 2026-06-05).** Structured/recursive runtime dicts
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
  self-hosted emitter (`compiler/entries/llvm_emit_modules_main.mdk`, run as a subprocess
  capturing IR) → `clang` + `runtime/medaka_rt.c` + libgc → binary.
  `compiler/driver/build_cmd.mdk`, `test/build_cmd.sh` (build+run+diff vs interpreter oracle).
  Full `core.mdk` prelude supported (the old `max`/`min` + no-DCE block is LIFTED,
  verified 2026-06-18 audit). `import map/set/array/list/string` all work in `medaka build`.
  **Deferred:** a build-artifact CACHE — the serialized Core IR exists
  (`compiler/core_ir_sexp.mdk` — `cprogramToSexp`/`parseCProgram`, round-trip
  proven; `test/diff_compiler_core_ir_roundtrip.sh`) but a cache-key strategy
  (content hash of source + transitive imports) + on-disk layout remain unbuilt;
  also install-prefix asset packaging (assets resolved repo-relative today).
- **`medaka doc`** ✅ — done: `compiler/tools/doc.mdk`.  Comment→decl
  matcher (parallel `Lexer.take_comments()` stream matched by position),
  signature renderer via `Typecheck.pp_scheme` for values / AST renderers for
  types, Markdown output (one `## name` section per public decl).  Single-file
  typecheck path; multi-module follow-up tracked separately.
  **PORTED TO NATIVE CLI** ✅ (2026-06-18, single-file) — `compiler/tools/doc.mdk`
  (a faithful port of the OCaml `lib/doc.ml` [now removed]: `commentBody`/`expandComment`/`findDocForLine`,
  `renderSig`/`ppDataVariant`/`ppRecordFields`/`ppRequiresDoc`, a precise pre-desugar
  `ppTyP`) +
  `runDocCmd` in `medaka_cli.mdk`.  Schemes via the single-file
  `checkProgramSchemesWithRuntime` path (like lsp/repl).  Byte-identical to the
  OCaml oracle over `test/doc_fixtures` — gate `test/diff_compiler_doc.sh` (14/0).
  Known scoped divergence: a value whose inferred scheme hits the native-vs-OCaml
  ambiguous-Num/var-naming defaulting fork renders different type-var names — a
  pre-existing typechecker soak-tail issue, NOT a doc bug (doc renders whatever
  scheme the checker produced); such files are out of the doc corpus.
- **`medaka check --json` multi-file** ✅ **CLOSED** (2026-06-17/18) — `analyzeProject`
  now resolves imports via the loader; a file with `import`s no longer produces
  spurious resolve errors in the JSON output. Single-file path remained as the
  fast-path fallback.
- Skill: none specific (lands in `compiler/driver/medaka_cli.mdk` + `compiler/tools/lsp.mdk`).

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
