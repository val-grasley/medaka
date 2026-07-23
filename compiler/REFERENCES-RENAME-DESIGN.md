# Cross-file `references` + `rename` (#254) — Design / Scoping

**Status:** DESIGN — 87ea0120, 2026-07-23. Forks F1–F6 locked by Val (below); Stage 0 (index-builder) in progress. Design-of-record for #254.

All `file:line` claims below were grep-proven at design time; verify against current source before relying on any specific line.

## Decisions (locked 2026-07-23 by Val)

The §8 forks are resolved as the design's recommendations; this is the scope Stages 0–2 build to.

- **F1 — scope:** intra-project by default; `references` on a stdlib symbol finds its uses *within the project* but does not descend into stdlib internals; **`rename` refuses to cross into stdlib/prelude**.
- **F2 — partial results (unparseable files):** `references` = best-effort (index what parsed, mark partial); `rename` = **refuse** and name the broken file.
- **F3 — rename safety:** **conservative-refuse** — refuse if `newName` would capture/shadow a binder in any affected scope, or if the symbol is defined outside the project.
- **F4 — method/operator granularity:** group all impls under one method key for v1.
- **F5 — rename return shape:** LSP `WorkspaceEdit { changes }`.
- **F6 — includeDeclaration:** honor the flag; default include.

Hard constraint (Val): the analysis is **linear** — see §3d (big-O) and §7 (a scan-quadratic-catching op-count gate; the allocation gate is blind to it).

---

## 0. Executive summary (the answers, up front)

- **Does the linear substrate already exist? NO — it must be built, but cheaply, by
  reusing existing machinery.** The #837 "binding identity minted at resolve"
  (`stampBindingIds`, `resolve.mdk:2789`) is **not** the substrate references needs:
  its ids are **module-local** (`numberFrom 1` restarts per call, `resolve.mdk:2791`),
  cover **only top-level *value* binders** (locals/params/where get sentinel id 0,
  `resolve.mdk:2581-2586`; types/ctors/fields/methods get nothing), the stamped AST is a
  **transient local discarded after inference** (`checkBodyImpl`, `typecheck.mdk:11741-11748`
  — never returned), and on the multi-module path the stamp frame is built over **this
  module's decls only** (`Module _ _ _ => prog0`, `typecheck.mdk:11733`), so a use of an
  imported name gets id 0 — **binder identity does not cross module boundaries.**
  `resolveModule` itself returns only `(ModuleExports, List ResError)`
  (`resolve.mdk:2457`) — **no use→def mapping is retained**. And `annotateProgram`'s
  `EVarAt n Addr` collapses every global to `AGlobal` with **no module identity**
  (`Addr = ALocal Int Int | AGlobal`, `ast.mdk:96`). **Conclusion: references/rename needs
  a NEW analysis pass. This is a feasibility finding, and it determines the plan.**

- **What DOES exist and makes the new pass cheap:** (a) every variable occurrence is
  `ELoc`-wrapped with a precise use-site span (`parseAtom = located parseAtomRaw`;
  `TIdent x => emit (EVar x)`, `parser.mdk:788-800`); (b) #331 gives every decl-name /
  child-name / impl-head a real `Loc` (def-site spans); (c) the whole project is already
  enumerated once, parsed+desugared, in dependency order by
  `loadProgramFilesLocatedCached` → `List (modId, path, decls)`
  (`loader.mdk:824`, `diagnostics.mdk:667`); (d) import origin / re-export / alias
  resolution already lives in resolve (`reexportOrigins`/`reexportBindings`,
  `resolve.mdk:2401-2430`; alias-qualified `A.f` is rewritten by
  `rewriteDecls`, `loader.mdk:559`).

- **Linear approach:** one whole-project walk builds `HashMap<BinderKey, List (uri,Loc)>`
  (stdlib `hash_map`, `stdlib/hash_map.mdk:37`) + `HashMap<BinderKey, (uri,Loc)>` for the
  def site. Build = **O(total tokens)** with O(1) amortized inserts. A `references` query =
  resolve the click to a `BinderKey`, then **one O(1) lookup + O(#uses) emit**. A `rename` =
  the same index + a linear map from each `Loc` to an edit — **O(#uses)**, **edits returned,
  never written** (the #250 / `fmt --write` guardrail). **No `List`-as-set/map anywhere; no
  per-query re-walk.**

- **Perf-gate trap acknowledged:** `diff_compiler_perf_scaling.sh` is **allocation**-graded
  and a scan-quadratic can allocate ~nothing → the gate is **blind** to it. Linearity is
  argued **by construction** (§4) *and* backed by a dedicated **operation-count / wall-clock**
  N-vs-2N fixture (§7), not by the alloc gate.

---

## 1. Make-or-break: the binder-identity substrate (grep-proven)

### 1a. #837 `stampBindingIds` — what it actually is

`resolve.mdk:2575-2792`. Header (verbatim, 2576-2586): mints "a monotonic unique Int per
**TOP-LEVEL value binder**"; "INCREMENT 1 mints only top-level binders. Local / lambda /
pattern / where binders are pushed into scope as a frame of `(name, 0)`… their occurrences
carry the sentinel id 0". Signature + body:

```
export stampBindingIds : List Decl -> (List Decl, List (String, Int))   -- resolve.mdk:2789
stampBindingIds decls = let top = numberFrom 1 (dedup (topBinderNames decls))
                        (map (stampDecl top) decls, top)                 -- resolve.mdk:2790-2792
```

Four disqualifiers for cross-file references, each proven:

1. **Module-local ids.** `numberFrom 1` restarts at 1 every call (`resolve.mdk:2618-2621`).
   `(name, id)` therefore **collides across modules** — id 3 in module A ≠ id 3 in module B.
2. **Only top-level values.** `topBinderNames` walks `DFunDef` / `DLetGroup` members only
   (`resolve.mdk:2610-2616`). Locals → id 0 (`zeroFrame`, `resolve.mdk:2602-2607`). Types,
   constructors, record fields, interface methods are never minted.
3. **Discarded AST.** The only caller is `checkBodyImpl` (`typecheck.mdk:11741`): `progS`
   is a `let`-local fed to inference; the function returns `List (String, Scheme)`. The
   `EVarId`-stamped tree is thrown away. `ast.mdk:247`: "Only ever lives in the transient
   tree typecheck infers; never reaches emit/eval." Nothing indexes it.
4. **Does not cross modules.** On the multi-file path `prog = prog0`
   (`typecheck.mdk:11731-11733`), so the top frame is this module's binders only; an imported
   name's occurrence is not in the frame → `lookupBindId` returns 0
   (`resolve.mdk:2594-2599`). `ast.mdk:244`: "a cross-module/global/unbound name — read as
   the bare-name fallback."

**So #837 gives references *nothing queryable*, but it is a useful precedent**: the
`stampExpr` walk (`resolve.mdk:2624-2678`) is exactly the shadowing-frame traversal the new
index-builder needs — a `List (List (String, key))` scope stack, innermost-first, first
match wins. Reuse the *shape*, not the *output*.

### 1b. resolve retains no use→def index

`resolveModule : … -> (ModuleExports, List ResError)` (`resolve.mdk:2457`);
`resolveModulesErrorsG` threads exports and returns **only `List ResError`**
(`resolve.mdk:2480-2489`). `annotateProgram` produces `EVarAt n Addr`, but
`Addr = ALocal Int Int | AGlobal` (`ast.mdk:96`) — a global carries **no defining module**,
and the node is "Unconsumed today (no eval arm…)" (`ast.mdk:238-240`). **There is no existing
structure mapping a use occurrence to the definition (and module) it binds to.** The new
pass must compute that mapping itself — but the *inputs* it needs (import origins, scopes)
already exist in resolve and are cheap to re-derive.

**Feasibility verdict: linear cross-file references IS achievable, but requires a new
indexing pass. It is NOT free-riding on #837.**

---

## 2. The substrate that DOES exist (what the new pass stands on)

| Need | Exists? | Evidence |
|------|---------|----------|
| Enumerate all project files + parsed/desugared ASTs once | ✅ | `loadProgramFilesLocatedCached → Ok (List (modId, path, decls))`, `loader.mdk:824`, `visitModF` acc `(modId, path, prog2)` `loader.mdk:703-715` |
| Whole-project driver already wired for LSP/MCP | ✅ | `analyzeProject` (`diagnostics.mdk:661`), `projectEntrySchemes` (`diagnostics.mdk:693`), used by `typeAtPoint`/`projectEntryEnv` (`lsp.mdk:697,729`) |
| Per-file project cache (parse + module) | ✅ | `projectCache`/`projectParseCache` Refs threaded through `projectEntrySchemes` (`lsp.mdk:735-741`) |
| Precise USE-site span for every var occurrence | ✅ | `parseAtom = located parseAtomRaw`; `TIdent x => emit (EVar x)`; `located` wraps in `ELoc (locOfSpan …)` (`parser.mdk:213-219,788-800`) |
| Precise DEF-site span (decl name, child name, impl head) | ✅ | #331 landed — `declPosNameLoc`, child `Loc`s (`lsp.mdk:359-398`; commits `eba004e1`, `ced858b0`, `5cb7a598`) |
| Import origin / re-export / alias resolution | ✅ | `reexportOrigins`/`reexportBindings` (`resolve.mdk:2401-2430`); `rewriteDecls` canonicalizes alias-qualified names (`loader.mdk:559-563`; `ast.mdk:342`: "`EFieldAccess` on the alias → plain `EVar "A.f"`") |
| Mutable hash map/set keyed by String | ✅ | `HashMap k v` (`stdlib/hash_map.mdk:37`, `new`/`get`/`set` amortized O(1)); `HashSet a` (`stdlib/hash_set.mdk:29`); String is `Hashable` |
| MCP tool registry seam (add tool = 1 handler + 1 record) | ✅ | `McpTool name desc schema handler`, `mcpTools` list, derived `tools/list`+dispatch (`mcp.mdk:248-280`) |
| LSP capability seam | ✅ | `documentHighlightProvider` etc. advertised at `lsp.mdk:1359`; request dispatch at `lsp.mdk:1673` |

**The one missing piece is the pass that turns `List (modId, path, decls)` into a
binder-keyed reference index.** Everything else is plumbing that already runs.

---

## 3. The core design — a binder-keyed reference index

### 3a. `BinderKey` — the identity that makes "match binders, not strings" correct

A `BinderKey` is a **String** (so it is a `hash_map` key for free), formed canonically:

- **Top-level / exported value or type or ctor or field or method** →
  `"<definingModuleId> <namespace> <name>"`, where `namespace ∈ {val,ty,ctor,field,method}`.
  The **defining module** is resolved through the import graph (origin, not alias — see §5),
  so a use of `A.f`, a use of `f` under `import m.{f}`, and the def of `f` in `m` all map to
  the **same** key. Re-exports collapse to the true origin via `reexportOrigins`
  (`resolve.mdk:2401`).
- **Local binder (let / lambda param / match pattern / where)** →
  `"<moduleId> local <name> <binderLine>:<binderCol>"`. The binder's own `Loc`
  makes it **unique and shadow-correct**: an inner `x` and an outer `x` produce **different
  keys**, so a click on the inner `x` never returns the outer `x`'s uses. This is precisely
  the bug a string scan has (`highlightRanges`/`occurrences`, `lsp.mdk:342-346`, matches by
  substring and is wrong under shadowing).

The ` ` (NUL) separator is safe because identifiers cannot contain it; it prevents
`("m","foo")` colliding with `("m.foo", "")`. (Note the fmt-wrote-NUL grep-blindness trap
is about *source files*; this NUL lives only in in-memory keys, never written to disk.)

### 3b. The index

Two mutable hash maps, built once per project load:

```
defIndex : HashMap String (String, Loc)          -- BinderKey → (uri, defLoc)          [the def site]
refIndex : HashMap String (Ref (List (String, Loc)))  -- BinderKey → mutable list of (uri, useLoc)
```

(`refIndex` values are `Ref (List …)` so appends are O(1) push, never `xs ++ [x]` — the
`xs ++ [x]`-in-a-fold shape is the canonical quadratic per `compiler/AGENTS.md` and the
perf-hunt skill. Reverse once at query time if order matters.)

Optionally a third, `posIndex : Array (uri, sortedByLine [(Loc, BinderKey)])`, to answer
"what binder is at (line,col)?" for the *incoming click* without re-walking — but the MVP
can locate the click by a single linear scan of one file's occurrences (that file is O(its
own size), independent of project size), so `posIndex` is a v2 optimization, not required
for linearity.

### 3c. The build pass (one walk, scope-aware)

For each `(modId, path, decls)` from `loadProgramFilesLocatedCached` (already dependency-
ordered), run one recursive walk mirroring `stampExpr`'s frame-stack shape
(`resolve.mdk:2624-2678`), carrying:

1. a **scope stack** `List (List (name, BinderKey))` for locals (innermost first), and
2. the **module env** = names in scope from imports, each mapped to its origin `BinderKey`
   (built from `ModuleExports` of the already-resolved dependency modules — resolve computed
   these in dependency order, `resolve.mdk:2480-2489`).

At each site:
- **A binder** (decl name via #331 `Loc`, or a local binder Loc) → `hmSet defIndex key
  (uri, loc)` and push `(name, key)` onto the appropriate frame.
- **An occurrence** `ELoc loc (EVar n)` → resolve `n` to a `BinderKey` by the frame stack
  first (shadowing), else the module env (imports), else the module's own top-level, else a
  synthetic `"?unresolved?"` bucket (dropped from results). Push `(uri, loc)` onto
  `refIndex[key]`.

Every step is O(1) amortized (hash get/set + list push). Total = **O(Σ tokens) = O(program
size)**. The scope-stack lookup is O(frame depth), which is bounded by lexical nesting (not
program size) — the same bound `lookupBindId` already lives with (`resolve.mdk:2595-2599`),
and the exact bound the perf-hunt skill flags for union-find chains: keep it shallow, never
let a frame become a per-file accumulator.

### 3d. Big-O (the required statement)

- **Index build:** **O(N)** where N = total tokens across all project files, using
  `HashMap`/`Ref`-list. Runs once per project load (cached in a `Ref`, same pattern as
  `projectCache`, `lsp.mdk:736`).
- **`references` query:** locate click = O(size of the *clicked file*) worst case (one
  file's occurrence scan) + **one O(1) `hmGet`** + **O(#uses)** to emit ranges. Independent
  of project size except through #uses (which is inherent — you must return them all).
  **Total: O(clicked-file-size + #uses).**
- **`rename`:** same lookup, then **O(#uses)** to map each `Loc` to a
  `{ range, replacement }` edit. **Total: O(#uses).** No file is re-walked; the def site is
  one more edit from `defIndex`.

**Exact data structures named:** stdlib `HashMap String v` (`stdlib/hash_map.mdk`), stdlib
`HashSet String` (for the visited/unresolved sets), and `Ref (List …)` for O(1) append
buckets. **No `List` used as a set or map anywhere.**

---

## 4. Why it is linear *by construction* (not "it passes the gate")

The two ways this class goes quadratic, and why neither can occur here:

1. **`List`-as-map/set** (the eleven historical quadratics, `compiler/AGENTS.md`): avoided —
   every membership/lookup is a `HashMap`/`HashSet` op, never `elem`/`lookup`/`contains`
   over a `List`.
2. **`xs ++ [x]` in a fold** (perf-hunt skill: "already found it"): avoided — bucket appends
   are `Ref`-list O(1) pushes; the only list concatenation is the final per-query result
   assembly, which is O(#uses) and runs once.
3. **Per-query re-walk** (the naive references implementation — walk all files on every
   query): avoided — the walk happens once at build; queries are hash lookups.

The remaining risk is a **scan-quadratic** hiding in the click-location step (e.g. locating
the clicked identifier by scanning every occurrence in every file). The design confines
click-location to the **single clicked file**, so it is O(that file), never O(project).

---

## 5. Correctness hazards ("match binders, not strings")

| Hazard | Why a string scan is wrong | How BinderKey indexing fixes it |
|--------|---------------------------|--------------------------------|
| **Shadowing** | inner `let x` and outer `x` share the spelling; `occurrences`/`highlightRanges` (`lsp.mdk:342`) return both | inner binder → distinct `local x L:C` key; occurrence resolves via innermost frame first (`stampExpr` shape) |
| **Import alias `import m as A`; `A.f`** | `A.f` and `f` spell differently | `rewriteDecls` canonicalizes `A.f`→`f`@origin (`loader.mdk:559`, `ast.mdk:342`); both map to `m val f` |
| **Selective `import m.{f as g}`** | local `g` ≠ origin `f` | module env maps `g → m val f` (origin), via `reexportBindings` alias handling (`resolve.mdk:2398-2402`) |
| **Re-export chains** | `f` visible through B but defined in A | `reexportOrigins` walks to the true origin (`resolve.mdk:2401-2430`) → single key |
| **Same name, different modules** | `map` in `map.mdk` vs a user `map` | key is prefixed by defining module id → no collision (the exact `installConsts` last-write-wins hazard, `compiler/AGENTS.md`, avoided structurally) |
| **Value vs type vs ctor namespace clash** | `List` the type vs a `List` value | `namespace` field in the key separates them |
| **Operator / method names** | `(+)` / interface methods dispatch per-impl | key `method <name>` groups the method; per-impl definitions are distinct binder Locs (v2 can split by impl-head — see fork F4) |
| **`main`-style top-level not applied / lazy nullary** | n/a for references | no special case needed — it is a top-level value binder like any other |

The unifying point: **a `BinderKey` is derived from resolution (scopes + import origin), not
from spelling.** That is the entire correctness argument, and it reuses machinery resolve
already runs.

---

## 6. Tool + LSP wiring

### 6a. MCP (`compiler/tools/mcp.mdk`)

Add two `McpTool` records to `mcpTools` (`mcp.mdk:252`) — the seam is "1 handler + 1 record"
(`mcp.mdk:241`). Handlers have signature `runtimeSrc coreSrc stdlibDir args -> <IO> Json`.

- `medaka_references {file, line, col}` → build (or read cached) the project index rooted at
  `findProjectRoot (dirOf file)` (same root discovery as `projectEntryEnv`, `lsp.mdk:731-733`),
  locate the click, emit `jArray` of `{ uri, range }` (the cross-file result shape — one
  object per hit, `uri` per file, mirroring `definitionResult`'s single-hit shape,
  `lsp.mdk:1584`). Off-identifier / unresolved → empty `[]` (never a crash, never a wrong
  hit — the `medaka_definition` convention, `mcp.mdk:530-533`).
- `medaka_rename {file, line, col, newName}` → same index, then return
  `{ changes: { <uri>: [ { range, newText } ] } }` (LSP `WorkspaceEdit` shape). **NEVER writes
  to disk** — echo the edits; the caller applies them. State this in the tool description
  exactly as `medaka_fmt` does ("NEVER writes to disk", `mcp.mdk:258`).

**How the stateless server gets the whole project:** identical to `medaka_type_at` today,
which "resolves imported names against the project on disk" (`mcp.mdk:255`) via
`typeAtPoint → projectEntryEnv → projectEntrySchemes → loadProgramFilesLocatedCached`
(`lsp.mdk:697-741`). References reuses that exact load; the *only* addition is running the
index-builder over the returned `mods` instead of (or alongside) `checkModules`.

### 6b. LSP (`compiler/tools/lsp.mdk`)

Advertise `referencesProvider` + `renameProvider` in the capabilities object
(`lsp.mdk:1346-1359`), and add `textDocument/references` + `textDocument/rename` arms to the
request dispatch (`lsp.mdk:1673`). The handlers call the same index-builder as MCP over the
`Docs`-backed read callback (`lsp.mdk:734` `read = path => docsGet …`), so unsaved buffers
win — exactly how `analyzeProject`/`projectEntryEnv` already behave. **references and rename
share one code path across MCP and LSP** (the `add-lsp-capability` skill's canonical
"stateless harness + thin LSP wrapper" shape).

---

## 7. Perf-verification plan (catches a SCAN-quadratic — the gate does NOT)

The allocation gate (`diff_compiler_perf_scaling.sh`) is **blind** to a references scan that
is O(n²) but allocates ~nothing (per the task's explicit warning and
`project_perf_gate_time_vs_alloc`). So add a **dedicated operation-count / wall-clock**
fixture:

1. **Generative fixture, two sizes.** A generator emits a synthetic project of N modules ×
   M defs each, each def used K times across files, with a fixed one-symbol query. Capture
   at **N and 2N** (total program size doubled).
2. **Grade a size-independent quantity, not allocation:**
   - **Primary: index-build op-count.** Instrument the build to count `hmGet`+`hmSet`+push
     operations (a `Ref Int` counter, printed under a `MEDAKA_PERF`-style flag like the
     existing per-stage `[perf]` lines, perf-hunt skill). **Linear ⇒ op-count ratio ≈ 2.0×;
     scan-quadratic ⇒ ≈ 4.0×.** This is deterministic and machine-independent (like
     allocation, but it *sees* non-allocating scans).
   - **Secondary: query op-count at fixed #uses.** Hold K constant, grow N; a correct query
     is O(clicked-file + #uses) ⇒ **flat** as N grows. A per-query re-walk ⇒ **linear in N**
     — caught immediately.
   - **Tertiary (advisory, not gating): wall-clock** with `GC_INITIAL_HEAP_SIZE` pinned
     (perf-hunt skill — an unpinned heap resize fakes a 3.4× ratio on correct code). Report
     MIN over interleaved A/B runs (`feedback_interleave_ab_timing`).
3. **Wire it** as `test/diff_compiler_references_scaling.sh` (⚠️ must match a shard pattern
   in `ci.yml` or it silently never runs — `diff_compiler_ci_shard_coverage.sh` enforces
   this; `compiler/AGENTS.md`). Grade the op-count ratio, not the timing.

**Prove linearity by construction (§4) first; the fixture is the regression guard, not the
proof.** A green alloc gate must never be cited as evidence here.

---

## 8. Design forks needing Val's decision

- **F1 — Scope of "references".** Intra-project only (user modules), or also into `stdlib`
  and the prelude? Recommendation: **intra-project by default**; a `references` on a stdlib
  symbol returns its uses *within the project* but does not descend into stdlib internals
  (stdlib is read-only to the user). Rename **must** refuse to cross into stdlib/prelude
  (see F3).
- **F2 — Partial results when some files don't parse/resolve.** `analyzeProject` already
  degrades gracefully (attributes a parse error to its file, `diagnostics.mdk:672`).
  Options: (a) best-effort — index the files that parsed, mark the result partial; (b)
  refuse and report the broken file. Recommendation: **(a) for `references`** (a broken
  sibling shouldn't blind you), **(b) for `rename`** (a rename computed over a partial graph
  can miss a use → silent corruption; refuse with the offending file named).
- **F3 — Rename safety guarantee.** (a) *Mechanical* — return edits for every known use, no
  conflict analysis; (b) *Checked* — refuse if `newName` would capture/shadow an existing
  binder in any affected scope, or if the symbol is defined outside the project
  (stdlib/prelude). Recommendation: **(b), conservative-refuse** — this is the #250 spirit
  (never hand back an edit set that silently breaks the program). Minimum: refuse renaming a
  symbol whose def site is outside the project.
- **F4 — Method / operator granularity.** Group all impls of a method under one key (rename
  renames the interface method + all impls + all call sites), or split per-impl? Recommend
  **group by method** for v1 (that is what a user means by "rename this method"), revisit if
  a per-impl need appears.
- **F5 — `rename` return shape.** LSP `WorkspaceEdit {changes}` vs a flat edit list.
  Recommend **`WorkspaceEdit`** (the LSP-native shape; MCP echoes the same JSON).
- **F6 — Does `references` include the definition itself?** LSP has a
  `context.includeDeclaration` flag. Recommend honoring it; default **include**.

---

## 9. Staged plan

**Stage 0 — index-builder core (no tool yet).** New module, likely
`compiler/tools/refindex.mdk` (or fold into `lsp.mdk` if small). `BinderKey`, `defIndex`,
`refIndex`, the scope-aware walk reusing `stampExpr`'s frame shape. Unit-exercised via a
throwaway entry probe. **Decisive check:** the §7 op-count fixture at N/2N (linearity).
Model tier: **Opus** — it threads scope + import-origin resolution, the "looks like
typecheck but is cross-cutting" category (`add-language-feature` per AGENTS.md, not
`harden-typechecker`).

**Stage 1 — MVP `medaka_references` (single query).** MCP tool + LSP `textDocument/references`
sharing the Stage-0 index. Fixtures: cross-file use, shadowing (inner ≠ outer), alias import,
re-export, same-name-different-module — one `diff_compiler_*` gate asserting each hazard from
§5. **Decisive check:** the shadowing + alias fixtures (correctness) **plus** the §7 scaling
fixture (perf). Model tier: **Sonnet** once the index exists (wiring is mechanical).

**Stage 2 — `rename` edit-set.** references + `Loc→edit` map + `WorkspaceEdit` result +
conflict/out-of-project refusal (F3). **Never writes disk.** Fixtures include a rename that
*would* capture a binder (must refuse) and a rename spanning 3 files (must edit all).
**Decisive check:** a golden asserting the returned edit set, and a negative golden asserting
refusal on an out-of-project symbol. Model tier: **Opus** for the conflict logic, **Sonnet**
for the wiring.

**Files touched (all stages):** `compiler/tools/refindex.mdk` (new),
`compiler/tools/mcp.mdk` (2 tool records + handlers), `compiler/tools/lsp.mdk` (capabilities
+ 2 dispatch arms + shared handlers), `test/diff_compiler_references_*.sh` (new gates,
shard-registered), `test/references_fixtures/*` (new corpus — ⚠️ enumerate consumers before
touching, shared-corpus trap). Docs: this file → `compiler/`, plus a row in
`compiler/tools/` table of `AGENTS.md` and the `add-lsp-capability` skill.

---

## 10. Snapshot / gate landmines specific to this work

- The new `refindex.mdk` is compiler source ⇒ it is in the snapshot corpus ⇒ **bless its
  golden in the same commit** via `sh test/diff_compiler_snapshot_tools.sh --bless <path>`
  (or whichever suite owns `tools/`) — never the CLI. (`compiler/AGENTS.md`; memory
  `feedback_snapshot_new_writes_next_to_the_source`.)
- Touching `mcp.mdk`/`lsp.mdk` moves their transcript/selfproc goldens — expect to bless
  `native_cli` lsp/session goldens too (precedent: commit `b72fe6d2`).
- Register the new scaling gate under a `ci.yml` shard pattern or
  `diff_compiler_ci_shard_coverage.sh` bounces the merge queue.
