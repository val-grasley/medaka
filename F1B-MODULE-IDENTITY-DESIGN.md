# F1b Loader Module-Identity — Decision-Ready Design

Status: ✅ **LANDED 2026-06-25** (`ac4b04a` + extern `33972aa`, seed re-minted `6a1a67e`). Built per the
HYBRID (Option A+) below. AS-BUILT: the deterministic-derivation form (no threaded memo) was used —
both spellings already share the same `owningRoot`, so they collapse without a memo; the
**two-dep-NAMES** corner is closed via a new `canonicalizePath` (realpath) extern that normalizes roots
before the dep-name reverse-lookup (first-declared name wins deterministically). resolve/typecheck/eval
were NOT touched (containment held). Gates: `cross_project_twonames` 3/3, `cross_project_deps` 3/3,
fixpoint C3a/C3b YES, cold `bootstrap_from_seed` PASS. Original decision-ready design follows.

## 0. Base
Reproduced on `main` = `50ca332` (native binary built OCaml-free via `make medaka`).

## 1. REPRO (confirmed — filed root cause is CORRECT)
Minimal 2-package repro: `pkgB/medaka.toml` declares `byteparser = "<repo>/byteparser"`; `pkgB/main.mdk`:
```
import byteparser.lib.byteparser.{runByteParser, beUint}
import byteparser.lib.bytebuilder.{newBuilder, emitU8}
main = println "hi"
```
`./medaka check pkgB/main.mdk` →
```
TYPE ERROR: conflicting `impl Alternative`: defined in byteparser.lib.byteparser and lib.byteparser
```
The two modIds: `byteparser.lib.byteparser` (entry's dep-prefixed spelling) and `lib.byteparser`
(the rebased intra-package spelling that `bytebuilder.mdk`'s `import lib.byteparser.{…}` produces —
`bytebuilder` is loaded under `owningRoot = byteparserRoot`, so its sibling import resolves to modId
`lib.byteparser`). `byteparser.mdk` declares `export impl Alternative ByteParser`
(`byteparser/lib/byteparser.mdk:77`), so loading it under two modIds double-counts that impl.
Each spelling alone is clean. The existing gate `test/cross_project_fixtures/` already triggers the
identical double-load (silently — `minilib.mdk` declares no impl, so coherence doesn't fire).

## 2. TOUCHPOINT MAP
All three native stages key identity by the dotted modId STRING; every importer looks up by its
literal `useModId path` spelling.
- **`selfhost/driver/loader.mdk`** — `moduleIdOfPath` (`:381`,`:88-90`); `visitMod` keys
  visited/stack/acc by `modId` string (`:354` dedup, `:356` cycle, `:365` acc). The two spellings
  arise because `directImports prog` (`:244-249`) returns each import's `importModId` (`:234-242`)
  verbatim — no canonicalization. `owningRoot` is known at `:360` but unused for canonicalization.
- **`selfhost/frontend/resolve.mdk`** — `findExports mid` string-equals `ModuleExports.modId`
  (`:1052-1056`); import resolution looks up by literal `useModId path` (`:1156`,`:1213`,`:1275`,
  `:1295`,`:1510`); `buildExports` tags exports with the loader's `mid` (`:1329`,`:1520`). `known`
  currently holds TWO entries from `byteparser.mdk` → resolve does NOT error today (each literal
  spelling finds its own copy).
- **`selfhost/types/typecheck.mdk`** — `cohImplsOfMid` stamps each impl with its mid (`:5520-5522`);
  `cohCollectModuleImpls` flat-collects over `(mid,prog)` (`:5962-5965`) → impl appears under both
  mids; `cohCrossModuleMsg` (`:5704-5712`) prints the observed message. The `:5957-5959` comment
  ASSUMES imports don't copy impls — the double-load violates that invariant.
- **eval `selfhost/eval/eval.mdk`** — `evalModules` flat-maps decls (`:2112`, impls coalesce
  `:2127`); `exportsMap` keyed by `mid` (`:2136-2142`); imports resolved by literal spelling
  (`:2220`,`:2231`).
- **Frozen OCaml `lib/`** — NO `[dependencies]`/cross-project support. Cross-project deps are
  NATIVE-ONLY. Gate `test/cross_project_deps.sh` is native-only (no oracle leg). **→ no `lib/`
  mirror required, no differential-vs-oracle gate.**

## 3. Why load-only dedup is UNSOUND
If the loader collapses the two entries to one modId without rewriting the other importer's `DUse`,
then `bytebuilder`'s `DUse` still literally says `lib.byteparser` → resolve's
`findExports "lib.byteparser"` and eval's `lookupAssoc "lib.byteparser"` MISS →
`Unknown module: lib.byteparser`. **Fix must collapse both spellings to one canonical id AND rewrite
the `DUse` spellings to match.** KEY: if the loader rewrites each `DUse` to the same canonical modId
it uses as the load key, resolve+eval+typecheck need ZERO changes — they already look up
`useModId(DUse)` against `(mid,prog)` keys, now both reading the canonical id.

## 4. OPTION A vs B
### Option A — canonical dep-prefixed modId rewrite at load (RECOMMENDED)
When `visitMod` loads a module under `owningRoot` == a declared dep's root, rewrite every
intra-package import (resolving UNDER `owningRoot`, not stdlib) to `<depName>.<relativeModId>`, and
use that as the recursion/acc/visited key. `byteparser.mdk` then loads once under
`byteparser.lib.byteparser` from both spellings → dedup at `:354`.
- **Blast radius:** `loader.mdk` ONLY. resolve/typecheck/eval unchanged. loader.mdk IS in the
  emitter self-compile graph (`llvm_emit_modules_main.mdk:30` imports `driver.loader`) → fixpoint
  must hold + seed re-mint at checkpoint.
- **Cases to handle:** all 4 `UsePath` variants (`UseGroup`/`UseWild`/`UseAlias` via `joinDot ns`;
  `UseName` special, modId = `initList ns` when >1 else `lastOr`); **intra-package vs stdlib
  discrimination** (a dep's `import list`/`import array` must NOT be prefixed — prefix only imports
  resolving under `owningRoot`; trickiest part); self/bare-name refs; transitive deps (already
  canonical → no rewrite); entry/stdlib modules (no rewrite).
- **Reverse lookup:** `owningRoot → depName` (find the `(depName,depRoot)` whose `depRoot ==
  owningRoot`).
- **Residual under-merge (exotic):** same physical dep reachable under two different dep NAMES still
  double-loads (name-based identity can't dedup name aliases). Over-merge is not a risk.
- **Pros:** small, single-file, fixpoint-local, readable diagnostics. **Cons:** dep-name-aliasing
  corner; per-`UsePath` rewrite is fiddly.

### Option B — path-based identity end-to-end
Key identity by canonical absolute file path; thread a spelling→path map into resolve+eval.
- **Blast radius:** loader + resolve + typecheck + eval (4 files), all in the emitter graph.
- **Pros:** collision-free (immune to dep-name aliasing). **Cons:** much larger coordinated change;
  diagnostics print absolute paths (need a path→display-modId side table); higher fixpoint/seed risk;
  touches hot import paths.

**Equivalence note:** B can also be a loader-only `DUse` rewrite with a path-derived canonical id —
collapsing B's file count to 1 too. The irreducible distinction is the **naming scheme**
(dep-name-prefixed vs path-derived), not file count.

## 5. RECOMMENDATION — HYBRID (Option A+): path-keyed dedup, dep-name display
**LOCKED.** Take Option B's identity model (the canonical absolute *path* IS the module) but realize
it loader-contained like Option A (rewrite `DUse` so resolve/eval/typecheck stay string-keyed and
unchanged). This is strictly more principled than plain A (alias-immune) and strictly cheaper than B
(single file, readable diagnostics).

### 5a. The mechanism
The loader maintains a memo **`canonicalPath → canonicalModId`**:
- The first time a physical file (by its resolved canonical absolute path) is loaded, assign it ONE
  canonical modId = the readable **dep-name-prefixed** form `<depName>.<relativeModId>` (computed from
  the package it was first reached through; for entry/stdlib modules the modId is unchanged from
  today).
- Every `DUse` (in any module) whose import resolves to that same canonical path is rewritten to the
  memoized modId, and the loader's recursion/acc/visited key for that file is the memoized modId.
- Because two spellings of one file resolve to one path → one memoized modId, both `DUse`s are
  rewritten to the SAME string → resolve (`findExports`), typecheck (`cohImplsOfMid`), and eval
  (`exportsMap`/`useImports`) all collapse them with ZERO changes (they remain string-keyed; the
  string is now canonical).
- **Alias-immunity:** same file under two different dep-NAMES → same canonical path → same memoized
  modId (the first-seen dep-name wins deterministically) → still collapses. This closes Option B's
  only real advantage.
- **Readable diagnostics:** the canonical modId is a dotted dep-name, not an absolute path — no
  path→display side table needed.

### 5b. Why it stays loader-contained
resolve/typecheck/eval look up modules by the literal `useModId(DUse)` string against `(mid,prog)`
keys. Rewriting every `DUse` for a given file to one identical canonical string means those stages
see a single consistent key — no edits there. The whole change is `loader.mdk` (+ its LSP twin
`visitModF`) + one fixture. loader.mdk IS in the emitter self-compile graph → fixpoint must hold +
seed re-mint at checkpoint.

### Staging plan
1. **Failing fixture first (red).** Add a trivial `interface`+`export impl` to
   `test/cross_project_fixtures/minilib/lib/minilib.mdk` + reference its method from `consumer/main.mdk`.
   Gate `sh test/cross_project_deps.sh` → expect FAIL `conflicting impl …: minilib.lib.minilib and
   lib.minilib`.
2. **Implement in `loader.mdk`.** `owningRoot→depName` reverse lookup + `canonicalizeImport` per-import
   (resolve, prefix only under-`owningRoot`); apply in `visitMod`/`visitMods` to BOTH the recursion key
   (`directImports`) and the stored `prog`'s `DUse` decls; mirror in `visitModF` (LSP twin).
   Gate `sh test/cross_project_deps.sh` → PASS 3/3 (check+run+build); re-capture its 3 goldens.
3. **Regression-guard single-root path.** `FORCE=1 bash test/build_oracles.sh` then
   `sh test/bootstrap_{resolve,eval,typecheck}.sh` unchanged; `sh test/diff_native_cli.sh` unchanged.
4. **Fixpoint + seed.** `FORCE_EMITTER_REBUILD=1 make medaka` then `sh test/selfcompile_build_fixpoint.sh`
   holds; re-mint seed at the checkpoint (defer per "Defer seed re-mints"); verify
   `sh test/bootstrap_from_seed.sh` cold.

## 6. DESIGN FORKS — RESOLVED
1. **Naming scheme:** HYBRID (§5) — path-keyed dedup, dep-name-prefixed display modId. Gets B's
   alias-immune identity at A's blast radius.
2. **Dep-name aliasing:** closed by the hybrid (same path → same memoized modId regardless of
   dep-name). No residual under-merge.
3. **Diagnostic spelling:** messages print the canonical (first-seen-dep-name-prefixed) modId.
   Accepted (clearer; dotted, not a path).
4. **Entry project's own self-imports:** left as-is (modId unchanged for entry/stdlib modules — the
   memo only rewrites modules reached under a declared dep root).

## 7. FIXTURE PLAN
Extend native-only `test/cross_project_fixtures/` (`test/cross_project_deps.sh`) — already has the
double-load topology. Add a minimal typeclass `interface`+`export impl` to `minilib/lib/minilib.mdk`,
reference its method from `consumer/main.mdk`. Asserts: `check` succeeds (no `conflicting impl`); `run`/
`build` produce expected output using the method (proves import frames intact). One fixture exercises
all three keyed stages; zero oracle-parity obligation.
