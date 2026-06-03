# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–110, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md).

## Current status (2026-06-02)

The compiler pipeline is complete end-to-end —
`lexer → parser → desugar → resolve → method_marker → typecheck (runs exhaust)
→ eval` — with phases through ~110 done (see PLAN-ARCHIVE.md). The language has
records, ADTs, interfaces (with superinterfaces, `deriving`, dictionary-passing
for return-position/multi-param dispatch), effect rows, exhaustiveness checking,
`do`-notation, guards (with fall-through + exhaustiveness lint), list
comprehensions, string interpolation, type aliases/newtypes, container literals
(`Map { k => v }` / `Set { x }`, Phase 108), property testing, doctests, an LSP
server, a formatter, and a project-config/`medaka new` surface. Operators are
wired to the real `Eq`/`Ord`/`Num` interfaces in `core.mdk` (Phase 52).

The stdlib in Medaka covers `core`, `list`, `array`, a drafted `string`
(STDLIB.md Modules 1–4), and the weight-balanced ordered `map` + `set`
(Module 5, complete). As of 2026-06-02 the user lifted the hand-write-it-myself
constraint and delegated the remaining modules.

**Conventions.** Work is still organized by numbered **Phases**; commit messages
and code comments reference them. Phases that were left *partial* keep their
original number (e.g. Phase 82, 101); genuinely new work gets the next free
number (last used: 114). At task triage, match the work against AGENTS.md's
task-playbook table and load the matching skill before planning.

---

## North star — self-hosting, then LLVM

The long-term goal that orders everything below: **rewrite the Medaka compiler
in Medaka, then compile it to native code via LLVM.** Chosen path (2026-06-02):
**bootstrap on the existing tree-walking interpreter first** — get a self-hosted
compiler running (slowly but correctly) on the interpreter, *then* build the
LLVM backend so that compiler emits native code. This validates the language as
a real engineering medium before we pay for the heavy memory-model / GC / codegen
work.

Most items in the Open roadmap are small course-corrections; this section is the
destination they steer toward. Three stages, each a gate on the next.

### Stage 0 — Prerequisites before self-hosting can begin

The language is already expressive enough to *describe* a compiler (ADTs,
records, exhaustive pattern matching, interfaces, modules, effects — all done).
What's missing is the supporting surface a real multi-thousand-line program needs:

- **Standard library breadth.** The compiler needs the data structures it is
  itself built on:
  - **`Map` / `Set`** — symbol tables, scopes, type-variable substitutions, impl
    registries. ✅ **DONE** (Module 5, ordered/weight-balanced). A hash variant
    (Module 6) is still open, mainly for performance.
  - **`io`** — read source files, write artifacts, stdin/stdout, process args,
    exit codes, structured error reporting. *Today: missing (Phase 19 module 7).*
    **The remaining critical-path Stage 0 prerequisite.**
  - `string` finalized and reviewed (drafted; awaiting review).
- **Language stability / completeness.** Close the sharp edges that would bite a
  large codebase, then *freeze the surface syntax and semantics* for the duration
  of the port:
  - ~~`do`→`Thenable` (Phase 98)~~, ~~guard exhaustiveness + inline guards (Phase
    91)~~, ~~plain multi-clause exhaustiveness (Phase 102)~~ — **DONE**.
  - Multi-module / return-position dispatch residuals (Phase 83/84) shouldn't
    force arg-tag workarounds in compiler code — mostly closed; nested-dict
    residual remains.
- **Interpreter performance, "good enough" to bootstrap.** Running the compiler
  *on* the interpreter must finish in minutes, not hours. May require interpreter
  hot-path work (the eval loop, environment representation) — measure once a
  non-trivial program exists.
- **Multi-file ergonomics at scale.** The module system, qualified access, and
  `medaka.toml` workspaces exist; per-module eval isolation landed (Phase 110).
  Confirm they hold up across the dozens of files a compiler needs. Surface gaps
  here become new phases.

### Stage 1 — Self-host on the interpreter

Port the pipeline (`lexer → parser → desugar → resolve → typecheck (runs
exhaust) → eval`) into Medaka, one stage at a time, checked against the OCaml
reference at each step. **Done when** Medaka-in-Medaka compiles a real program identically to
the OCaml compiler, and ultimately compiles *itself*. The output of this stage is
a validated language and a compiler whose only slow part is the interpreter
underneath it.

### Stage 2 — LLVM backend (after self-host)

With the language proven, build native codegen. The heavy, decision-dense work
deliberately deferred to here:

- **A frozen Core IR** as the codegen input: desugared, fully typed, effects
  erased, **dictionaries explicit**. The existing elaboration already inserts
  `EMethodRef`/`EDictApp` — that is the foundation; this stage commits to it as a
  serializable lowering target.
- **Typeclass lowering strategy:** runtime dictionary passing (already the eval
  model) vs. monomorphization. Decide deliberately — it shapes the whole backend.
- **Memory model & value representation:** heap allocation, closure layout,
  tagged ADTs/records, boxing/unboxing. *Decision-dense; the real cost of going
  native.*
- **Garbage collection:** conservative (Boehm) to start vs. reference counting
  vs. a precise collector. Strict + functional + closures ⇒ this is unavoidable.
- **Runtime library:** re-implement the `extern` catalog (today OCaml in
  `eval.ml`, incl. Unicode via `uucp`, arrays, strings, IO) against the native
  runtime.
- **LLVM lowering:** Core IR → LLVM IR, calling convention, FFI.
- **Bootstrap closure:** self-hosted compiler + LLVM backend compiles itself to a
  standalone native binary — the finish line.

---

## Open roadmap

Each item is independently shippable; pick one per session. Grouped by area, not
strict priority. Where an item is a **Stage 0 prerequisite** for the north star
above, it is flagged ⭐.

### Compiler / language

- **Phase 101 — drive property generation/shrinking through the `Arbitrary`
  interface (101b).** 101a (registry-first `arbitrary`/`shrink`, native element
  recursion) is **DONE** (see PLAN-ARCHIVE.md). What remains — **101b, deferred,
  reassess later**: synthesized typed generators + parametric `core.mdk`
  `Arbitrary` impls. Phase 83/84 made single-level interface-driven generation
  work (`impl Arbitrary (List a)` generates `List Int`/`List Tagged`/`Option
  Int`), but **nested** parametric elements (`List (List Int)`) still fail — the
  flat `VDict of string` dict can't carry a recursive element dict. Since 101a
  (native + registry recursion) already handles every case *including* nesting
  and makes hand-written element impls win, 101b's only unique gain is honoring a
  user's custom container-*generation* strategy — niche. Revisit only if that
  need arises (also wants structured/recursive dicts to lift the nesting limit).
  WIP on branch `claude/suspicious-sammet-21d73e` (commit `860ba12`). Skill:
  **add-language-feature** (cross-cutting).

- **Phase 111 — `print`/`println` leak language internals; route them through a
  user-facing interface.** Surfaced 2026-06-02 in the Phase 108 `show` discussion.
  - **Problem (verified):** `println m` for a `Map` prints the raw
    weight-balanced tree — `Bin 2 1 10 Tip (Bin 1 2 20 Tip Tip)` — i.e. the
    internal constructors, not a user-facing form like `fromList [(1, 10), …]`.
    Every user ADT prints its raw `VCon` structure. `show m` is fine
    (`fromList […]`), but plain `println` is the common path and exposes the
    implementation.
  - **Root cause:** `print`/`println : a -> <IO> Unit` (stdlib/runtime.mdk) are
    **unconstrained** externs; eval's `print`/`println` (`lib/eval.ml` ~1088)
    call native `pp_value`, which renders a runtime value structurally (`VCon`
    name + args) with no interface dispatch — at runtime the value is just
    `VCon "Bin" […]`, so `pp_value` *can't* reach a type's user-defined rendering.
  - **Goal / the decision to make:** standardize human-facing output on a
    user-facing interface. Likely **`Display`** (`display : a -> String`,
    unquoted; already backs `\{…}` interpolation, and matches println's
    putStr-vs-show intent per runtime.mdk's comment) rather than `Show` (quoted,
    round-trippable). **Pick one.**
  - **`Display` should use the literal syntax (the Show/Display split, resolved).**
    Because `Display` does *not* need to round-trip, it is free to render a
    container with its pretty literal form, while `Show` keeps the re-evaluable
    function form:
      - `show m`    → `fromList [(1, 10), (2, 20)]` (round-trips; empty → `fromList []`)
      - `display m` → `Map { 1 => 10, 2 => 20 }` (pretty; empty → `Map {}`, which
        Show could *not* emit because it doesn't parse — but Display needn't care)
    So this phase adds `impl Display (Map k v)` (and per container) rendering the
    `Map { … }` literal, and `println m` then shows that. This is exactly why the
    Phase 108 `show` switch was declined but Display is the right home for the
    literal rendering.
    - **Sub-decision:** do the keys/values *inside* a Display'd container render
      via `Display` (unquoted — `Map { ada => 1 }`) or `Show` (quoted —
      `Map { "ada" => 1 }`)? Unquoted is Display-consistent but makes a string key
      read like an identifier. Decide when building.
  - **Clean implementation shape:** make `print`/`println` *Medaka* stdlib
    functions over a raw string-only extern — `putStr/putStrLn : String -> <IO>
    Unit` (the only externs), then `println : Display a => a -> <IO> Unit;
    println x = putStrLn (display x)`. This sidesteps the extern-can't-receive-a-
    dict wrinkle (externs take raw values; a constrained extern would need eval to
    supply the dict) by moving the constraint into Medaka where dict-passing
    already works.
  - **Cost / fork:** constraining the signature means **`Display` must cover every
    printable type** — built-ins (Int/Float/Bool/Char/String/Unit/tuples/List/
    Option/Result/Array/Map/…) plus `deriving (Display)` for user types; printing
    an un-`Display`able type becomes a *compile error*, losing today's
    "println anything" ergonomic. Mitigation: keep the current unconstrained raw
    dump under a debug name (`debug`/`inspect : a -> <IO> Unit`) for REPL/quick
    prints. `pp_value` is also used by error messages, the REPL result echo, and
    `applied non-function: …` — leave those raw (internal/debug), scope this to
    `print`/`println`.
  - Lands in: stdlib/runtime.mdk (externs) + stdlib/core.mdk (Display coverage +
    `print`/`println` defs + wider `deriving (Display)`) + `lib/eval.ml` (swap the
    externs for `putStr`/`putStrLn`). Skill: **add-language-feature**.

- **Phase 112 — prefer a locally-bound / explicitly-imported name over a
  no-impl interface method.** The recurring standalone-vs-interface-method
  collision. It bit `empty` (fixed in Phase 103), and currently makes map's
  exported `toList` / `isEmpty` **unreachable from a user file** — a bare
  `toList m` / `isEmpty m` resolves to the generic `Foldable.toList`/`isEmpty`,
  which has no `Map` impl, → `No impl of Foldable for Map`. Won't-do Phase 78c
  dropped the *export-a-bare-`length`* version (it would shadow `Foldable.length`
  everywhere), but this is the narrower, safer lever: **when a name is both an
  explicitly-imported/locally-bound function and an interface method, and the
  method has no applicable impl at the use site's type, resolve to the
  function.** Fixes the whole class (`toList`/`isEmpty`/`map`/`filter` on a type
  that doesn't impl the interface) without removing interfaces. Coherence
  subtleties to settle before building: an impl that exists for a *supertype* or
  via a superclass; interaction with the orphan/coherence checks; whether "no
  applicable impl" is decidable at resolve time vs. needs typecheck. `set.mdk`
  sidesteps the issue by *implementing* `Foldable`; map can't (its `toList` means
  pairs, not values). Lands in `lib/resolve.ml` + `lib/typecheck.ml`. Skill:
  **harden-typechecker**.

- **Phase 114 — container-literal residuals (Phase 108 follow-ups, low priority).**
  Two limitations of the `Map { … }` / `Set { … }` sugar:
  - **Empty literals don't work** — `Map { }` / `Set { }` fail (`Type mismatch:
    Map Int vs Map`): empty braces carry no `=>` to distinguish map-vs-set, so the
    parser emits `ESetLit(name, [])` and the lowering pins the *unary* `name _a`,
    the wrong arity for a binary `Map`. Low value (empty containers have
    `empty`/`Monoid.empty`). Possible fix: `EHeadAnnot` in typecheck ignores the
    lowering-supplied arity and applies the head tycon to its *declared* arity of
    fresh vars (a tycon-arity lookup).
  - **Two same-shape containers in scope need a type annotation** to disambiguate
    — the literal's name pins the *head* tycon, not the full type, so two
    `(k,v)`-entry container types both match `Map { … }`'s entry shape. Annotate
    (`m : Map _ _ = …`) to choose. Inherent to head-pinning; recorded.
  - Skill: **add-language-feature**.

- ⭐ **Phase 83 / 84 (residuals, deferred — layered like 69.x→74).** The
  instance-`requires` dict-threading into return-position impl bodies (single
  level) is **DONE** (see PLAN-ARCHIVE.md). Remaining, lower priority — each a
  known limitation with a correct-enough fallback today:
  - Runtime dict-threading *into* an inferred (unsignatured top-level) constrained
    body (currently arg-tag dispatch, correct for argument-dispatched wrappers).
    Distinct from the impl-body case. Needs a post-typecheck marker re-run against
    the final constraint tables — a pipeline restructure.
  - Self-/mutually-recursive *unsignatured* wrappers under-infer their own
    recursive-call routing.
  - `pure` in a do-block with **no `<-`** is groundable only from surrounding
    type context.
  - `Result e` with a free `e` mis-dispatches even when signatured (a multi-param
    dict-resolution gap). (Did not reproduce on the 2026-06-02 binary with the
    probes tried; re-verify before working it.)
  - True recursive/nested instance dictionaries (the `List (List Int)` case) need
    structured dicts rather than flat impl-key strings — the real "pipeline
    restructure"; also lifts the Phase 101b nesting limit.
  - Skill: **harden-typechecker** / **add-language-feature** (cross-cutting).

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

### Stdlib enablement (Phase 19)

Originally hand-written by the user by design; as of 2026-06-02 the user lifted
that constraint and delegated the remaining modules (Modules 5–8). STDLIB.md is
the per-module checklist. **Module 5 (`map` + `set`) is complete** — see
PLAN-ARCHIVE.md and STDLIB.md.

- **Phase 113 — `Ord` instances for `Map` / `Set`.** Neither has an `Ord` impl
  today, so you can't nest them (a `Map (Set a) v`, or a `Set (Set a)`) or sort a
  `List (Map …)`. Add lexicographic `Ord` on the canonical ascending list:
  `impl Ord (Map k v) requires Ord k, Ord v where compare a b = compare (toList a)
  (toList b)` (toList = assoc pairs; for set, the element list). Cheap; both
  already impl `Eq` the same way. Lands in `stdlib/map.mdk` + `stdlib/set.mdk`.
  Skill: **extend-stdlib**.

- ⭐ **`stdlib/string.mdk`** is drafted and passes its 49 doctests but is flagged
  *awaiting user review* (archive Phase 75 step 3). Open decisions: the
  `length`/`isEmpty`/`count` omissions and `toUpper` vs `charToUpper` naming.

- **Modules 6–8 unstarted:** `mut_array`/`hash_map`/`hash_set`, `io`
  (`readFile`/`writeFile`/`readLine`), `json` (type + parser + serializer).
  Expect each to surface new language gaps — record them here as new phases.
  - ⭐ **`io` is the remaining critical-path Stage 0 prerequisite** — a
    self-hosted compiler needs file I/O (it has symbol tables now: `map`/`set`).
    (`mut_array`/`hash_map`/`hash_set` matter mainly for *performance*; `json` is
    not on the self-hosting path.)

### Blocked on a package manager (out of scope until one exists)

- `medaka add` / `remove` / `update`, and a `medaka.lock` file.

---

## Won't-do (kept intentional)

- **Phase 78c — multi-module method shadowing.** Investigated 2026-06-01 and
  dropped: the motivating need (`length`/`isEmpty`/`toList` on `Array`) is
  already met by interface impls, and there is no safe export path for a bare
  `length : String -> Int` (it would shadow `Foldable.length` everywhere). The
  real lever, if ever needed, is a `Sized`/`HasLength` interface — which is
  stdlib design, not a compiler feature. (Phase 112 is the *narrower* lever —
  resolve to a local/imported name only when the method has no applicable impl —
  which is on the open roadmap; 78c stays dropped.)
- The broader **rejected-features** list (labeled arguments, active patterns,
  computation expressions, polymorphic variants, first-class modules, row
  polymorphism, macros, lazy sequences, higher-rank polymorphism, custom
  symbolic operators, …) lives in PLAN-ARCHIVE.md §8 with per-item rationale.
  Consult it before proposing any of them so the rejection stays intentional.
