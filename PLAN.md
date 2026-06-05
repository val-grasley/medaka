# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–141, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md). The detailed,
living record of the self-host port is [`selfhost/README.md`](./selfhost/README.md).

## Current status (2026-06-05)

The OCaml compiler pipeline is complete end-to-end —
`lexer → parser → desugar → resolve → method_marker → typecheck (runs exhaust)
→ eval` — with phases through ~141 done (see PLAN-ARCHIVE.md). The language has
records, ADTs, interfaces (with superinterfaces, `deriving`, dictionary-passing
for return-position/multi-param dispatch), effect rows, exhaustiveness checking,
`do`-notation, guards (with fall-through + exhaustiveness lint), list
comprehensions, string interpolation, type aliases/newtypes, container literals
(`Map { k => v }` / `Set { x }`), property testing, doctests, **unit tests**
(Phase 127), an LSP server, a formatter, and a project-config/`medaka new` surface.

The stdlib in Medaka is **complete** across `core`, `list`, `array`, `string`
(frozen, Phase 128), ordered `map`/`set`, mutable `hash_map`/`hash_set`,
`mut_array`, `io`, and `json` (STDLIB.md Modules 1–9 all done).

**The self-host port (Stage 1) is essentially complete** — all eight pipeline
stages are ported to Medaka and validated byte-for-byte against the OCaml
reference, and the bootstrap closure ("the compiler processes its own source")
has landed for Legs A–C. See [North star → Stage 1](#stage-1--self-host-on-the-interpreter)
below and `selfhost/README.md` for the full slice log. Only **Leg D** (running
the typechecker stage on the self-hosted eval) and a couple of forward-looking
performance levers remain.

**Conventions.** Work is organized by numbered **Phases**; commit messages and
code comments reference them. Phases left *partial* keep their original number
(e.g. Phase 83/84, 101); genuinely new work gets the next free number (last used:
144). At task triage, match the work against AGENTS.md's task-playbook table and
load the matching skill before planning.

---

## North star — self-hosting, then LLVM

The long-term goal that orders everything below: **rewrite the Medaka compiler
in Medaka, then compile it to native code via LLVM.** Chosen path: **bootstrap on
the existing tree-walking interpreter first** — get a self-hosted compiler running
(slowly but correctly) on the interpreter, *then* build the LLVM backend so that
compiler emits native code.

Three stages, each a gate on the next.

### Stage 0 — Prerequisites before self-hosting can begin — ✅ COMPLETE

All Stage-0 prerequisites are met (details in PLAN-ARCHIVE.md):

- **Standard library breadth** — `Map`/`Set` (ordered) + `HashMap`/`HashSet`
  (mutable) + `mut_array`, `io`, and a finalized importable `string` are all done.
- **Language stability** — `do`→`Thenable`, guard exhaustiveness, plain
  multi-clause exhaustiveness, and the multi-module / return-position dispatch
  residuals are closed (only the nested/structured-dict residual #5 remains — see
  Phase 83/84 below; it does not block the port).
- **Interpreter performance** — "good enough to bootstrap" confirmed; the cost is
  typeclass dispatch + persistent-tree allocation, addressed opportunistically in
  the self-host perf work (`selfhost/PERF-NOTES.md`), not a blocker.
- **Multi-file ergonomics at scale** — scale-probed; cross-module user-defined
  interfaces (the one hard gap) closed by Phase 130.

### Stage 1 — Self-host on the interpreter — ✅ stages done; bootstrap Leg D remaining

Port the pipeline into Medaka, one stage at a time, checked against the OCaml
reference. The self-host tree lives in `selfhost/`, each stage validated against
the OCaml reference via a differential harness on the interpreter.

**All eight stages are ported and validated byte-for-byte** (full per-stage slice
logs in `selfhost/README.md`):

| Stage | Status | Validated against |
|-------|--------|-------------------|
| lexer (Phase 132) | ✅ | 17/17 fixtures + all 13 real `.mdk` files |
| parser (Phase 135) | ✅ | stdlib + `parse_fixtures` + `diff_fixtures` + self-source |
| desugar | ✅ | `astdump --desugar`, 95/95 corpus |
| resolve (single + multi-module) | ✅ | `diagdump --resolve[-modules]`, corpus + fixtures |
| method_marker | ✅ | `astdump --mark`, full corpus |
| exhaust (guard coverage) | ✅ | `diagdump --exhaust`, corpus + 5 fixtures |
| eval (untyped, typed/RKey, multi-module) | ✅ | `eval_probe` + all 16 `=== EVAL ===` goldens |
| typecheck | ✅ | `tc_probe` + all 16 `=== TYPES ===` goldens |

**Integration milestones beyond per-stage validation:**
- **Composed front-end** (`selfhost/check.mdk`) — parse → desugar → resolve →
  exhaust → typecheck in one program; reproduces all 16 TYPES goldens + the
  resolve diagnostics.
- **True execution** (`selfhost/eval_run_main.mdk`) — runs programs for stdout,
  matching all 16 `=== EVAL ===` goldens.
- **Typed eval path / return-position dispatch** (`selfhost/eval_typed_main.mdk`).

**The bootstrap closure** ("the compiler processes its own source"), validated by
`test/diff_selfhost_selfproc.sh`:
- ✅ **Leg A** — the self-hosted multi-module front-end typechecks all 12 selfhost
  modules of its own source and matches the OCaml reference.
- ✅ **Leg B** — the self-hosted eval engine executes a real selfhost stage (the
  lexer) identically to the `eval_modules` oracle.
- ✅ **Leg C** — the *typed* self-hosted eval executes a `Parser`-monad stage (the
  parser) identically to the oracle, via `typecheck.elaborateModules`.
- 🚧 **Leg D — run the typechecker stage on the self-hosted eval. NEXT.** The
  natural extension of Leg C along the typed multi-module path: execute
  `typecheck.mdk` (also monadic → return-position dispatch) through
  `eval_typed_modules_main.mdk`, validated the same way Leg C validates the parser.
  See `selfhost/README.md` → "Leg D".

**Dictionary passing** for user `=>`-constrained functions is also ported
(`eval_dict_main.mdk` + `typecheck.elaborateDict`), including inferred/unsignatured
constraints and self/mutual recursion — beyond the RKey-only minimum the bootstrap
source needs (the selfhost source has no `=>`-constrained user polymorphism).

**Forward-looking performance levers** (backend-independent, cheap now / expensive
to retrofit — recorded so they aren't lost; not blocking):
- **Lexical addressing** — resolve emits a `(frame, slot)` address per variable
  reference to replace the assoc-list env scan. 🚧 IN PROGRESS: the EMIT half
  landed (resolve annotates `EVarAt`; harnesses byte-identical because consumption
  is unwired). The eval-consumption half (+ VThunk / Phase-112 shadow interaction)
  is the supervised follow-up. This is the top un-attempted perf lever.
- ✅ **Stdlib string builder** — killed the O(n²) `++` string-building in
  lexer/formatter via native `stringConcat` over cons-built lists (2026-06-05; see
  `selfhost/PERF-NOTES.md`).
- Larger levers (bytecode VM, decision-tree match compilation) are recorded as
  post-profiling work, and feed Stage 2.

### Stage 2 — LLVM backend (after self-host)

> **Backend-architecture decision (bytecode VM first vs. straight to LLVM):** see
> [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md). Recommends a Core IR
> + bytecode VM as a "Stage 1.5" on-ramp (conditionally), on differential-testing
> grounds — the bytecode VM is gated against the existing tree-walker oracle per
> slice, where LLVM-first is not. The staged plan there feeds the work items below.

With the language proven, build native codegen. The heavy, decision-dense work
deliberately deferred to here:

- **A frozen Core IR** as the codegen input: desugared, fully typed, effects
  erased, **dictionaries explicit**. The existing elaboration already inserts
  `EMethodRef`/`EDictApp` — this stage commits to it as a serializable lowering
  target.
- **Typeclass lowering strategy:** runtime dictionary passing (already the eval
  model) vs. monomorphization.
- **Memory model & value representation:** heap allocation, closure layout,
  tagged ADTs/records, boxing/unboxing.
- **Garbage collection:** conservative (Boehm) to start vs. reference counting
  vs. a precise collector.
- **Runtime library:** re-implement the `extern` catalog against the native
  runtime.
- **LLVM lowering:** Core IR → LLVM IR, calling convention, FFI.
- **Bootstrap closure:** self-hosted compiler + LLVM backend compiles itself to a
  standalone native binary — the finish line.

---

## Open roadmap

Each item is independently shippable; pick one per session. Grouped by area, not
strict priority.

### Self-host (Stage 1 tail)

- 🚧 **Leg D — run the typechecker stage on the self-hosted eval.** See Stage 1
  above and `selfhost/README.md`. The last bootstrap leg.
- 🚧 **Lexical-addressing perf hook — eval-consumption half.** See Stage 1
  performance levers. Resolve already emits `EVarAt (frame, slot)`; wire eval to
  consume it (with the VThunk / Phase-112 shadow-bypass interaction) and measure.

> **Note for OCaml-compiler tasks below:** the self-host port mirrors the OCaml
> pipeline stage-for-stage (`selfhost/{lexer,parser,desugar,resolve,marker,
> exhaust,typecheck,eval}.mdk`). A change to a *ported* stage in `lib/` must be
> mirrored into the corresponding `selfhost/*.mdk` and re-validated with that
> stage's `test/diff_selfhost_*.sh`, or the differential harness breaks. Changes
> to *non-ported* parts (printer/`fmt`, diagnostics, the CLI driver, doctest) have
> no self-hosted counterpart.

### Compiler / language

- **Phase 145 — an explicit selective `import M.{name}` does not shadow a
  prelude binding of the same name. TODO.** A *local* top-level definition that
  collides with a prelude name shadows it correctly, but an explicit selective
  import of the same name does not — the call site still resolves to (and is
  typechecked against) the prelude binding. Repro (two files in one dir):
  ```
  -- helper.mdk
  export
  apply : Int -> Int -> Int
  apply x y = x + y
  -- main.mdk
  import helper.{apply}
  main = println (apply 3 4)
  -- → Type mismatch: a -> b vs Int
  --   (the prelude `apply : (a -> <e> b) -> a -> <e> b` is used at the call site,
  --    not helper's `apply : Int -> Int -> Int` — `3` is not a function)
  ```
  The control cases confirm the scope: a local `apply x y = …` defined directly in
  `main.mdk` *does* shadow the prelude (prints `7`), and a non-colliding imported
  name resolves fine — so the bug is specific to **imported names vs. the
  auto-injected prelude**. **Where it lives:** name-binding precedence in
  `lib/resolve.ml` (and `selfhost/resolve.mdk` for parity) — the implicit prelude
  frame is being consulted before, or coalesced ahead of, an explicit selective
  import. **Decision needed (design):** either (a) give an explicit `import
  M.{name}` precedence over the prelude (the conventional rule — explicit beats
  implicit), or (b) declare the prelude deliberately un-shadowable-by-import and
  document the alias convention. **Workaround in use:** `selfhost/eval.mdk` exports
  `applyValue = apply` so `selfhost/core_ir_eval.mdk` can import value-application
  unambiguously. Surfaced by the STAGE2 §2.1 Core IR session (the Core-IR evaluator
  importing `eval.{apply}` collided with the prelude's `apply`).

- **Phase 143 — block-`let` is non-recursive while expression `let … in …` is
  recursive: same surface form, opposite recursion. TODO (needs a design
  decision).** The identical syntax `let f x = … f …` recurses at expression
  position (parser emits `ELet _ True`, auto-recursive) but, inside a bare block,
  desugars to a non-recursive `DoLet`, so the self-reference is reported as
  **`Unbound variable: f`** — a confusing error naming the very binding just
  written. Repro:
  ```
  countdown p =
    let go n = if n == 0 then p else go (n - 1)   -- → Unbound variable: go
    go 3
  -- but the one-liner works:
  countdown p = let go n = if n == 0 then p else go (n - 1) in go 3   -- 42
  ```
  **Where it lives:** desugar of block `DoLet` (`lib/desugar.ml`) vs the
  expression-`let` parse rule that sets `isRec` for the param form
  (`parser.mly`); `lib/eval.ml`'s `blockLet` evaluates the RHS before extending
  the frame, so a block-`let` closure never captures its own name. **Decision
  needed (design):** either (a) make a block-`let` with parameters recursive to
  match expression-`let` and the top-level form, or (b) keep it non-recursive but
  replace the bare `Unbound variable` with a targeted hint. Surfaced by the
  lexical-addressing emit session (the addresser correctly emitted `AGlobal` for
  the block-`let` self-reference, matching eval).


- **Phase 138 — clear error for a recursive *value* forced during its own
  definition (replace the `CamlinternalLazy.Undefined` leak). DONE
  (2026-06-03).** A non-function binding that references itself such that the
  reference is *forced* while the binding is still being computed crashed the
  interpreter with a raw OCaml `Fatal error: exception
  CamlinternalLazy.Undefined` instead of a Medaka diagnostic. Typechecks fine;
  it's an **eval-time** crash. **Minimal repro (now a clean error):**
  ```
  ident x = x
  loop = ident loop      -- forces `loop` (a strict arg) while defining it
  main = println loop    -- → panic: recursive value 'loop' is forced while …
  ```
  Surfaced by the Phase 135 combinator parser, where recursive parser *values*
  (`skipNewlines = orElse (sepThen … skipNewlines) …`) hit exactly this — the fix
  there was to recurse through a `do`-continuation (lazy) instead of a strict
  self-argument. **Fix:** a `force_thunk name t` helper in `lib/eval.ml` wraps
  `Lazy.force` and converts `CamlinternalLazy.Undefined` into a named
  `Eval_error` ("recursive value 'NAME' is forced while it is being defined; a
  non-function recursive binding must defer its self-reference (through a lambda
  or continuation)"). The two thunk-force sites that know the binding name —
  `lookup` and `lookup_method` — route through it; the deferred-force loop and
  multi-module driver force via `lookup`, so they inherit the catch. `loc` is
  `None` (the force site has no convenient source loc, matching the existing
  "unbound identifier" error). Regression tests in `test_run` (raw-crash-vs-
  Eval_error + message-content). Found via the self-host port — exactly the rough
  edge it exists to surface.

- **Phase 137 — allow an expression RHS to wrap onto a continuation line
  (`.mdk` layout ergonomics). DONE (2026-06-03).** A long application can now
  break an argument onto a more-indented following line:
  ```
  parseCmp = chainl1 parseCons
    (choice [...])      -- now continues `chainl1 parseCons`
  ```
  **Lexer-only change** (`lib/lexer.mll`); `parser.mly` untouched, so
  `parser.conflicts` is unchanged. The continuation is purely *subtractive* (it
  removes an INDENT a one-line form never had), so every continued form parses to
  the **identical AST** as its one-liner. Mechanism: when a would-be INDENT
  (`col > current`, `paren_depth = 0`) is *not* a block, suppress it (leave the
  indent stack at the statement's base column, like the leading-operator rule).
  An INDENT opens a block iff (a) it follows a `match`/`record` header — the only
  two openers whose INDENT is preceded by an expression atom, tracked by one-shot
  `match_pending`/`record_pending` flags — or (b) the previous token *can't end an
  expression* (`=`/`then`/`=>`/`where`/`do`/… introduce every other block). The
  remaining candidates are deferred (`pending_indent`) and resolved in `token`
  once the deeper line's first token is known: an **atom-starter** continues the
  application; a `|`/`where`/`data`'s `=`/leading-operator *commits* the INDENT and
  replays the token (so guards, block-`where`, and block `data` keep working
  without their own flag). `prev_significant`/`can_end_expr`/`can_start_atom` carry
  the gates. Tests: `test_parser` group "expression-RHS continuation (Phase 137)"
  (10 cases — positive wraps + block-not-collapsed/guard/where/match/record/data
  regressions). Found via the self-host parser port (Phase 135), which worked
  around it by pulling args into one-line helpers.

- **Phase 136 — typechecker: generalize mutually-recursive binding groups. DONE
  (2026-06-03).** A single self-recursive polymorphic function generalized fine,
  but a **mutual-recursion group monomorphized to its first use**. **Minimal
  repro (now passes):**
  ```
  isEv : Int -> a -> List a        isOd : Int -> a -> List a
  isEv 0 x = []                    isOd 0 x = []
  isEv n x = isOd (n - 1) x        isOd n x = x :: isEv (n - 1) x
  -- isEv 3 (5:Int) and isEv 3 "a" together  →  used to be "Int vs String"
  ```
  **Root cause was NOT the generalization loop the TODO guessed** (that loop is
  correct, and the `let rec … with` / `DLetGroup` multi-member path always worked).
  It was **group *formation*:** `order_groups_by_deps` ran Tarjan SCC only to
  *reorder*, then **flattened a cyclic SCC back into separate singleton groups**.
  So mutual recursion was checked as sequential singleton `process_letrec_group`
  calls sharing a monomorphic top-level placeholder — member 1 generalized, then
  member 2's inference *re-linked* member 1's quantified var, leaving member 1's
  recorded `bound_ids` referencing a now-`Link`ed var → `instantiate` treated it
  as free/monomorphic → pinned by first use.
  **Fix (one site):** `order_groups_by_deps` now **merges** a multi-member SCC into
  one group, so all bodies are inferred before any member generalizes (the
  non-destructive final loop then builds every scheme against settled var ids).
  **Dict-passing fallout (the warned Phase 73/83/84 interaction, fixed here):**
  merging makes mutual-rec siblings share one constraint var id, which broke
  `find_enclosing_dict` — it picks the enclosing function by id-match and returned
  a *sibling's* `$dict_<fn>_<slot>` (unbound at eval) for pass-through constrained
  mutual recursion (`isEvenLen`/`isOddLen`) and promoted return-pos pairs
  (`ping`/`pong`). Fixed by threading an `enclosing`-function hint (a `current_fn`
  ref set per member in Pass B, captured into `dict_app_usages` /
  `recursive_promoted_usages` / `method_usages`) into `find_enclosing_dict`, which
  now prefers the enclosing member's own dict. Unblocks idiomatic parser
  combinators (`many`↔`some`, `chainl1`↔…) and any mutually-recursive polymorphic
  helper. Tests: `test_typecheck` "mutual poly {signed,unsigned,2nd}", `test_run`
  "mutual rec dict (Phase 136)" + the pre-existing `t_rec_mutual_constraint` /
  `t_infer_return_pos_mutual` now exercise the merged path.

- ⭐ **Phase 135 — self-host Stage 1: port the parser to Medaka. IN PROGRESS
  (started 2026-06-03); scaffold done.** Second pipeline stage. The Menhir LR
  grammar (`lib/parser.mly`, 1146 lines) becomes a **hand-written
  recursive-descent** parser over `List Token` from the (validated) lexer — no
  parser generator in Medaka. Tractable because precedence is a **stratified
  ladder, not `%left/%right`** (`expr_annot → expr_lam → expr_pipe → … →
  expr_add → expr_mul → expr_unary → expr_app → expr_atom`, ~18 levels), one
  recursive function per level. Target AST = **pre-desugar** (the parser emits
  surface sugar `EGuards`/`EDo`/`EStringInterp`/`EListComp`/`ESection`/`EQuestion`;
  desugar lowers them later). Stays **prelude-only** (`List`/`Array`/string
  externs + local AST type) — `Map`/stdlib isn't needed until *resolve*, so the
  stdlib-access decision (multi-root loader, which already exists, vs vendoring)
  is deferred again.
  **Validation = structural S-expression dump** (decided): no AST dumper existed
  (unlike the lexer's `token_to_string`), so added `dev/astdump.ml`
  (`Ast`-`to_sexp`, location-stripped, one decl per line; tags = `ast.ml`
  constructor names) + a Medaka mirror `selfhost/sexp.mdk`, diffed by
  `test/diff_selfhost_parse.sh`. Chose this over porting the 912-line
  `printer.ml` (less code, no whitespace/paren fragility). FLOAT text normalized
  away, like the lexer.
  **Done so far (scaffold, validation-first like Phase 132):** `selfhost/ast.mdk`
  (core node type — grows per slice), the dual dumpers (format **validated
  byte-for-byte** via the positive control), `parse_main.mdk` (dumps a hand-built
  control AST until the parser exists), and the harness. **Next slices:**
  expressions (the ladder + atoms) → patterns → declarations → types, each
  growing `ast.mdk` + `sexp.mdk` coverage and validated on fixtures, then hardened
  on real `.mdk` source (the lexer's 13/13 analog). **Chief risk:** layout-driven
  blocks (the parser consumes INDENT/DEDENT/NEWLINE to structure
  `let`/`match`/`do`/`where`/decl boundaries). See `selfhost/README.md`.

- ⭐ **Phase 132 — self-host Stage 1: port the lexer to Medaka. IN PROGRESS
  (started 2026-06-03); lexer fixture-complete.** First stage of the self-hosting
  effort (North star → Stage 1). **Done:** the `selfhost/` scaffold + differential
  validation loop (`selfhost/lexer.mdk`, `selfhost/lex_main.mdk`,
  `test/diff_selfhost_lexer.sh`), and the full tokenizer — literals, idents/
  keywords, operators/punctuation, line comments, string interpolation, and a
  faithful port of `lib/lexer.mll`'s INDENT/DEDENT/NEWLINE layout algorithm +
  else-continuation filter + leading-operator continuation. **All 15/15 fixtures
  in `test/diff_fixtures/` match the OCaml reference byte-for-byte.** Pure
  two-pass design (scan → RawTok stream with `RNewline` markers; layout pass →
  INDENT/DEDENT/NEWLINE). Lexer uses prelude + global externs only (no stdlib
  import), so `selfhost/` is a single-root project.
  **Now also validated on real source** (2026-06-03): added `{- … -}` nestable
  block comments, hex/bin/oct int literals, and the `@`/`AS_AT` adjacency rule —
  the gaps surfaced by self-lexing. `dev/lextok.exe` dumps the OCaml reference
  token stream for any file, and `test/diff_selfhost_lex_files.sh` diffs the
  Medaka lexer against it over **all 13 real `.mdk` files (every stdlib module +
  the lexer lexing itself) — 13/13 match byte-for-byte** (FLOAT text normalized:
  OCaml `%g` vs `floatToString`, same TFloat value). **Still deferred** (no real
  file or fixture uses them): triple-quoted strings (+ `strip_indent`) and nested
  interpolation. **Incorporated Phase 133** (char-literal escapes): `scanChar`
  now processes `\n \t \r \0 \\ \'` + `\u{…}` (mirroring the new `read_char`), so
  the lexer still self-lexes 13/13 after that landed — surfaced one more
  serialization-only nuance (a NUL char renders `\0` via `debugStringLit` vs
  `\000` via `%S`; unused in real files). **Next:** the parser stage, which forces
  the **stdlib-access** decision (multi-root loader or vendored
  `Map`/`List`/`string`).
  **Two self-host-surfaced compiler quirks to file/fix:** (1) char literals do no
  escape processing, so newline/tab/quote/backslash must be matched by `charCode`
  (worked around in `lexer.mdk`); (2) ✅ FIXED (Phase 134): an `<IO>`-returning
  *helper* called from a `match` arm produced no output — a cross-module
  dict-passing name collision, not the eval driver; `lex_main.mdk` now uses the
  helper form. Byte-for-byte
  serialization caveats mapped: OCaml `%S` escapes non-ASCII as decimal byte
  escapes (`debugStringLit` agrees on ASCII), `FLOAT` uses `%g` (vs
  `floatToString`). See `selfhost/README.md`.

- **Phase 134 — `<IO>` helper from a `match` arm produced no output: a
  cross-module dict-passing name collision. ✅ DONE (2026-06-03).** Surfaced by
  Phase 132. **Symptom:** factoring an `<IO>` body into a helper called from a
  `match` arm made the program exit 0 with **no output**; the inline form ran
  correctly. Only reproduced with the real `selfhost/lexer.mdk` — every minimal
  analog worked, which is what made it look like a deferred-thunk / eval-driver
  bug (Phases 96/103/121/125). It was **not** the eval driver. **Root cause:**
  `lexer.mdk` defines a private, genuinely `Num`-constrained 8-arg `emit` (the
  `+` on `pos`/`depth` leaves two `Num` constraints, so dict_pass gives its
  definition two leading dict params). `Eval.eval_modules` dict-passed the marked
  prelude **+ all modules jointly** and `Dict_pass.collect_arities` keyed
  dict-arity by **bare name**, so the global `emit→2` was applied to
  `lex_main.mdk`'s *unrelated, unconstrained* `emit` definition too. That
  definition became 3-param while its call site (`EDictApp` with no resolved
  route) applied zero dicts, so `emit path` returned an un-run **partial
  closure** — discarded by `main`'s thunk → clean exit, no output. The minimal
  analogs missed it because their helper-collision used `++` (no residual
  constraint ⇒ no dict params ⇒ no conflation). **Fix (`lib/eval.ml`
  `eval_modules_ex`):** stop dict-passing jointly. Scope each module's
  dict-arity table to references that can actually resolve to *its* definitions —
  the module's own decls ∪ the decls of its **transitive importers** (where the
  external call sites of its exported constrained functions live). The prelude,
  imported by everyone, keeps the full joint scope. Private constrained fns
  (lexer's `emit`) are covered by the own-decls part; public ones referenced only
  by importers (`mk : Tag a => …`) by the importer part. **Regression test:**
  `test_loader.ml` `test_eval_dict_arity_no_cross_module_collision` (drives
  `Eval.eval_modules`; the flat path can't express two top-level `emit`s, so it
  masks this). `selfhost/lex_main.mdk` now uses the helper form (named `emit` on
  purpose), so the diff harness exercises the fix over all 15 fixtures.

- **Phase 133 — char literal escape processing. ✅ DONE (2026-06-03).**
  Char literals now process the same escape suite as string literals: `\n \t \r \0 \\ \'`
  and `\u{…}`. The fix replaced the single-regex rule in `lib/lexer.mll` with a
  `read_char` auxiliary (matching the `read_string` / `read_triple_string` pattern);
  `lib/printer.ml` gained `escape_char_lit` so `LChar` round-trips correctly;
  `debugCharLit` in `lib/eval.ml` likewise escapes special chars. The `selfhost/lexer.mdk`
  workaround (comparing via `charCode` for `\t`/`\n`/`\'`/`\\`) was replaced with
  direct char literals. 7 new parser test cases cover every new escape form.

- **Phase 131 — add token-stream section to the diff harness. ✅ DONE
  (2026-06-03).** Added `Lexer.tokenize_string : string -> string list` +
  exhaustive `token_to_string` in `lib/lexer.mll` (no wildcard arm, so a new
  grammar token surfaces a non-exhaustive-match warning here). Prepended a
  `=== TOKENS ===` section (one token per line, same `rstrip_nl` normalization)
  to both `dev/gen_golden.ml` and `test/thorough/thorough_diff.ml`, regenerated
  all 15 goldens (purely additive), and the harness now runs 60 cases (15 ×
  {TOKENS, AST, TYPES, EVAL}, up from 45). `split_sections` is order-independent
  so it needed no change. The diff harness now validates lexer output for all 15
  fixtures before the Medaka lexer is wired in (Stage 1). Token format: payload
  tokens render kind + value (`INT 42`, `STRING "hi"`, `IDENT "foo"`), everything
  else (keywords/operators/punctuation/`NEWLINE`/`INDENT`/`DEDENT`/`EOF`) as the
  bare variant name.

- ⭐ **Phase 130 — cross-module user-defined interfaces ✅ DONE (2026-06-03).**
  A user `interface` declared+`export`ed in module A can now be `impl`'d for a
  type owned by module B and its constraint discharged in a third module C. The
  whole gap was a single resolve omission: the `DUse` import loop in `resolve.ml`
  copied an imported interface's *name* into `env.interfaces` but not its method
  set into `env.iface_methods`, so any `impl` of it tripped "Method 'X' is not
  part of interface Y". Layer 2 (impl discharge) needed **no** change — `te_impls`
  already propagates a module's `export impl`s by full `impl_key`, and the orphan
  check only fires when both iface and type are non-local. See PLAN-ARCHIVE.md for
  the full writeup. *Secondary ergonomic finding still open* (file separately if
  it compounds): every cross-module function needs its own `export` line, and an
  `impl` module must import each interface **method name** it references.

- **Phase 129 — differential-testing harness (self-host validation rig). ✅ DONE
  (2026-06-03).** 15 standalone `.mdk` fixtures in `test/diff_fixtures/`; each
  gets a `<name>.golden` with three sections committed to git: `=== AST ===`
  (canonical `Printer.program_to_string` round-trip), `=== TYPES ===` (full
  alphabetic type env from `Typecheck.check_program`), `=== EVAL ===` (typed
  pipeline stdout via `Elaborate.elaborate` + `eval_program ~prelude:false`).
  Regeneration probe: `dev/gen_golden.exe`. Comparison runner:
  `test/thorough/thorough_diff.ml` (45 alcotest cases), wired into `@thorough`
  via `(setenv DIFF_FIXTURES_DIR %{workspace_root}/test/diff_fixtures ...)`.
  Token-stream section deferred to Phase 131 (natural point: when the lexer port
  begins). Medaka-stage comparison slots in alongside each port stage.

- **Phase 128 — freeze `stdlib/string.mdk` (review + lock the API). DONE 2026-06-03.**
  49/49 doctests pass. Open decisions settled and documented in STDLIB.md (Module 3
  marked reviewed/frozen): (1) `length`/`isEmpty` intentionally absent — would
  clash with `Foldable`; callers use `stringLength`/`s == ""`; `Sized`/`HasLength`
  deferred. (2) `toUpper`/`toLower` confirmed as the String-level names (full
  Unicode, 1→N expansion); `charToUpper`/`charToLower` remain as Char-level kernel
  externs only. No code changes needed — decisions were already encoded; Phase was
  pure documentation/freeze.

- **Phase 127 — unit testing library (`test` keyword + `stdlib/test.mdk`). DONE 2026-06-03.**
  Medaka has doctests (example-as-documentation) and `prop` tests (universal
  laws) but no plain unit tests. Add a third kind for what the other two cover
  poorly: error/negative paths, non-`show`-able or multi-step results, effectful
  checks, and maintainer-only checks that shouldn't clutter docstrings. **Design
  settled 2026-06-03** (brainstorm); division of labor goes in STDLIB.md so the
  three don't compete.

  **Surface syntax** — a new `test` declaration keyword, symmetric with `prop`,
  whose body evaluates to an `Expectation`:
  ```
  test "reverse is an involution" =
    expectEqual (reverse (reverse [1, 2, 3])) [1, 2, 3]
  ```

  **Architecture: dogfooded Medaka runner, host does discovery only.**
  - *Host (discovery, no type inference):* scan `DTest` decls — exactly like
    `DProp` — and synthesize an injected registry value, wrapping each body in a
    thunk so nothing runs at collection time:
    `__tests__ : List (String, Unit -> Expectation) = [ ("name", () => <body>), … ]`.
    Then evaluate a call to the library's `runTests __tests__` and read the
    returned `VBool` for the exit code. New **third pass** in `bin/main.ml`
    (`if has_sub "test"`) after doctests + props, `&&`-ed into the result.
  - *`stdlib/test.mdk` (pure Medaka — the dogfooded part):* `public export data
    Expectation = Pass | Fail String` plus the assertion vocabulary —
    `expectEqual`/`expectNotEqual : (Eq a, Show a) => a -> a -> Expectation`,
    `expectTrue`/`expectFalse : Bool -> Expectation`,
    `expectLessThan`/`expectGreaterThan : (Ord a, Show a) => …`, `pass`, `fail :
    String -> Expectation`, `expectAll : List Expectation -> Expectation` (first
    `Fail` wins) — and `runTests : List (String, Unit -> Expectation) -> <IO>
    Bool`, which loops, forces each thunk, formats results (match
    `lib/test_cmd.ml`'s style), and returns all-passed. **v1 is minimal: one
    `Expectation` per test, `expectAll` for conjunction, NO `describe`/nesting**
    (group via `"List/reverse/…"` names).

  **The one new extern (`add-primitive`): `runExpectation`.** A pure-Medaka
  `runTests` cannot survive a crashing test — a partial match / `head []` is an
  OCaml-level `Eval_error`, and the language has no `try`/`catch`, so one crash
  takes down the whole run and loses every later test (doctests/props dodge this
  only because their loops live in OCaml). So a dogfooded runner *requires* a
  single narrow escape hatch — NOT a general `try`/`catch` (that would contradict
  the "errors are `Result` data, not exceptions" stance), but one purpose-built
  primitive:
  `runExpectation : (Unit -> <e> Expectation) -> <IO> Expectation`,
  implemented in `eval.ml` as `try force-thunk with Eval_error | Impl_no_match ->
  Fail <msg>`. `runTests` maps it over the registry and never sees a raw panic.

  **Resolution caveat (the real risk).** `test.mdk` is NOT in the prelude (see
  below), so test files `import test.{…}` and the host's injected `runTests
  __tests__` references an *imported* module. Route the discovery pass through
  the **proven multi-module loader path** Phase 92 built for import-bearing
  doctests (`Doctest.run_file` branches on `has_use_decls` → `Loader.load_program`
  + `Eval.eval_modules`) — reuse the same shared loader-assembly helper Phase 126
  wants factored out, rather than a new single-file path that would hit the
  loader-vs-flat eval landmines (Phases 96/103/121/125).

  **Why not the prelude (settled, not open).** Full prelude inclusion is
  *inadvisable*: it pollutes *every* program (incl. non-test code) with generic
  names — `Pass`/`Fail`/`fail`/`pass`/`Expectation` — and taxes every compile
  with test machinery + the `runExpectation` `<IO>` extern. `prop` needs no
  import only because it uses pure prelude vocab (`eq`/`&&`); `test` needs a real
  library, which shouldn't be global. v1 uses an explicit `import test.{…}`
  (conventional — Elm `import Expect`, HUnit/Hspec all import).

  **Followup (v2, deliberately deferred — do NOT bundle into v1):**
  *conditional auto-import.* Since the discovery pass already detects `test`
  decls, it can inject the test vocabulary **only into files that contain a
  `test` decl** — frictionless like a keyword, with zero pollution of non-test
  files. Deferred because it is a *second conditional-prelude* path, and
  `marked_prelude` coalescing + loader-vs-flat ordering is this codebase's most
  repeated bug source — build it on a working, tested v1, not speculatively.

  **Build shape:** `add-language-feature` (the `test` keyword: lexer.mll →
  parser.mly → ast.ml `DTest` → resolve.ml → `bin/main.ml` discovery) +
  `add-primitive` (`runExpectation` in runtime.mdk + eval.ml) + `extend-stdlib`
  (`stdlib/test.mdk`, STDLIB.md division-of-labor paragraph, gen/embed.ml if
  embedded). Tests: a fixture file with `test` decls (incl. one crashing test and
  one `expectAll`) driven through the multi-module path, plus an import-bearing
  variant — land in `test_run`/`test_doctest`-adjacent suites.

- **Phase 126 — `medaka test` prop phase now resolves sibling imports ✅ DONE
  (2026-06-03).** The prop phase routed import-bearing files single-file and failed
  at `Unbound variable: <name>`; it now reuses the loader exactly like doctests.
  Factored `Doctest.assemble_marked_modules` (shared by both phases), and the prop
  phase evals via the new `Eval.eval_modules_root_env` (the root's *full* env — the
  plain `eval_modules` returns only root locals, so prop bodies couldn't see imports
  or prelude operators). `--coverage` works on import-bearing files too. See
  PLAN-ARCHIVE.md for the full writeup.

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

- **Phase 83 / 84 #5 — true recursive/nested instance dictionaries. DEFERRED (the
  big remaining residual).** The instance-`requires` dict-threading into
  return-position impl bodies is DONE; the tractable set was closed by Phase 115,
  and #4 (free-`e` `Result`) closed via head-key dict-application routing (all in
  PLAN-ARCHIVE.md). Only #5 remains: the `List (List Int)` case needs **structured
  dicts** rather than flat impl-key strings — the real "pipeline restructure"; it
  also lifts the Phase 101b nesting limit. Skill: **harden-typechecker** /
  **add-language-feature** (cross-cutting).

### CLI surface (Phase 82, continued)

The design spec lists `new build run check test fmt lsp doc add remove update`;
`check / run / test / repl / lsp / fmt / new` exist, plus `bench`. Remaining
non-package-manager gaps:

- **`medaka build`** — needs its own design first: there is no artifact cache or
  typed-IR serialization format in the tree, so "typecheck + cache" has no honest
  implementation. Until that exists it would only be an alias of `check`.
- **`medaka doc`** — needs (a) a comment→decl matcher (doc comments aren't
  attached to AST nodes — a parallel `Lexer.take_comments()` stream matched by
  position, like `doctest.ml` does), (b) a signature renderer for a typechecker
  `scheme`, and (c) an output-format decision.
- **`medaka check --json` multi-file** — currently single-file (`Diagnostics.
  analyze` doesn't invoke the `Loader`), so a file with `import`s can
  resolve-error in the JSON output. Multi-file `--json` is the follow-up.
- Skill: none specific (lands in `bin/main.ml` + `lib/lsp_server.ml`).

### Stdlib enablement (Phase 19) — ✅ COMPLETE

All of Modules 1–9 are done (`core`/`list`/`array`/`string` + `map`/`set`, hash
containers, `io`, `mut_array`, `json`) — see PLAN-ARCHIVE.md and STDLIB.md. The
hand-write-it-myself constraint was lifted 2026-06-02 and the remaining modules
delegated. `stdlib/string.mdk` API frozen 2026-06-03 (Phase 128).

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
