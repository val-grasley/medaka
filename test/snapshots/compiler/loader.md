# META
source_lines=841
stages=DESUGAR,MARK
# SOURCE
-- Port of lib/loader.ml: parse a root .mdk file's transitive imports and return
-- them in dependency-first (topological) order.
--
-- Simplifications vs the reference (sufficient for the flat, single-root compiler
-- tree; noted so they're not mistaken for completeness):
--   * Nested module paths ARE supported: a dotted module ID `a.b` maps to the
--     nested file `<root>/a/b.mdk`, and a file path's module ID replaces `/`→`.`
--     (mirrors loader.ml file_of_module_id / module_id_of_path).  Flat bare names
--     (no `.` / no nested `/`) round-trip unchanged.
--   * No LSP buffer-override `read`, no multi-root AmbiguousModule check.
--   * Cycles ARE detected (an in-progress stack) and reported as an Err.

import frontend.ast.{
  Decl,
  DUse,
  DAttrib,
  UsePath,
  UseName,
  UseGroup,
  UseWild,
  UseAlias,
  Loc,
}
import frontend.parser.{
  ParseError,
  parseResult,
  parseLocatedResult,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
}
import support.util.{
  contains,
  listLen,
  reverseL,
  initList,
  startsWith,
  endsWith,
  joinDot,
  lookupAssoc,
  splitNl,
  stringTrim,
  sortUniqS,
}

-- ── small list helpers (no stdlib import — compiler is single-root) ──

lastOr : a -> List a -> a
lastOr d [] = d
lastOr _ [x] = x
lastOr d (_::xs) = lastOr d xs

-- split a String on a single-char separator (mirrors String.split_on_char).
-- Always returns ≥1 segment; empty input → [""].  No-sep input → [s].
splitOnChar : String -> String -> List String
splitOnChar sep s = splitGo sep s 0 (stringLength s) ""

splitGo : String -> String -> Int -> Int -> String -> List String
splitGo sep s i len acc =
  if i >= len then [acc]
  else
    let c = stringSlice i (i + 1) s
    if c == sep then
      acc :: splitGo sep s (i + 1) len ""
    else
      splitGo sep s (i + 1) len (acc ++ c)

-- join segments with "/" (mirrors String.concat "/")
joinSlash : List String -> String
joinSlash [] = ""
joinSlash [x] = x
joinSlash (x::xs) = stringConcat [x, "/", joinSlash xs]

-- replace every "/" with "." in a path (mirrors loader.ml module_id_of_path's
-- `String.map (fun c -> if c = '/' then '.' else c)`)
slashToDot : String -> String
slashToDot s = joinDot (splitOnChar "/" s)

-- ── path / module-id utilities ──

dropPrefix : Int -> String -> String
dropPrefix k s = stringSlice k (stringLength s) s

stripSuffixStr : String -> String -> String
stripSuffixStr suf s =
  if endsWith suf s then
    stringSlice 0 (stringLength s - stringLength suf) s
  else
    s

-- the file path a module ID maps to under a single root (no existence check).
-- A dotted module ID maps to a nested path: split on `.`, join with `/`, append
-- `.mdk` (mirrors loader.ml file_of_module_id).  A flat bare name (no `.`) →
-- `[name]` → `name`, so `<root>/name.mdk` — unchanged from the flat behaviour.
fileOfModuleId : String -> String -> String
fileOfModuleId root modId =
  stringConcat [root, "/", joinSlash (splitOnChar "." modId), ".mdk"]

-- the module ID a file path carries: strip the first matching root prefix, then
-- the `.mdk` suffix, then replace `/`→`.` (mirrors loader.ml module_id_of_path).
-- A flat file under the root has no `/` left after stripping → slashToDot is a
-- no-op, so flat behaviour is unchanged.
relUnderRoots : List String -> String -> String
relUnderRoots [] path = path
relUnderRoots (r::rs) path =
  let pre = stringConcat [r, "/"]
  if startsWith pre path then
    dropPrefix (stringLength pre) path
  else
    relUnderRoots rs path

moduleIdOfPath : List String -> String -> String
moduleIdOfPath roots path =
  slashToDot (stripSuffixStr ".mdk" (relUnderRoots roots path))

-- Walk up from `startDir` to the nearest directory containing `medaka.toml` (the
-- project / module root), mirroring lib/project_config.ml's root discovery.  This
-- is what lets tooling (LSP, run) resolve nested modules whose IDs are rooted at
-- the PROJECT dir, not the edited file's immediate directory — e.g. a file
-- `compiler/frontend/parser.mdk` importing `frontend.ast` resolves only when the
-- root is `compiler/` (where `medaka.toml` lives), not `compiler/frontend/`.
-- Falls back to `startDir` when no `medaka.toml` is found up to the top.
export findProjectRoot : String -> <IO> String
findProjectRoot startDir = findRootGo startDir startDir

-- The module-resolution roots for a single entry file: the entry's OWN
-- directory first, then the project root found by walking up from there
-- (`findProjectRoot`).  Two roots, not one, because they answer different
-- questions and neither subsumes the other:
--   * the entry's dir resolves a BARE sibling import (`import helper`) next to
--     the entry file, regardless of where (or whether) a `medaka.toml` lives;
--   * the project root resolves a DOTTED cross-package import rooted at the
--     project dir (`import frontend.ast` from `compiler/frontend/parser.mdk`,
--     where the root is `compiler/`, not `compiler/frontend/`).
-- Before this exported publicly, callers used just `findProjectRoot entryDir`
-- as the sole non-stdlib root — correct for the dotted case, but it silently
-- swallows a sibling import once a `medaka.toml` sits above the entry's own
-- dir (P0-13: `medaka run src/main.mdk` from a project root with
-- `src/helper.mdk` failed with `unknown module: helper`, because `helper`
-- resolved against the project root, not `src/`).  De-duplicated to a single
-- root when the entry already sits AT the project root (or no `medaka.toml`
-- was found, in which case `findProjectRoot` falls back to `entryDir` itself).
export entrySearchRoots : String -> <IO> List String
entrySearchRoots entryDir =
  let projRoot = findProjectRoot entryDir
  if projRoot == entryDir then [projRoot] else [entryDir, projRoot]

findRootGo : String -> String -> <IO> String
findRootGo cur fallback =
  if fileExists (stringConcat [cur, "/medaka.toml"]) then cur
  else
    let p = parentDir cur
    if p == cur || stringLength p == 0 then fallback else findRootGo p fallback

-- parent directory: strip the last `/`-component (mirrors the loader's dir logic).
parentDir : String -> String
parentDir path = parentGo path (stringLength path)

parentGo : String -> Int -> String
parentGo path 0 = "."
parentGo path i =
  if stringSlice (i - 1) i path == "/" then
    stringSlice 0 (i - 1) path
  else
    parentGo path (i - 1)

-- ── cross-project dependencies (medaka.toml [dependencies]) ──────────────────
--
-- A project's `medaka.toml` may carry a `[dependencies]` section of the form
--
--     [dependencies]
--     parsec = "../parsec"
--
-- where each value is a path string relative to the project root (the directory
-- containing the medaka.toml).  `readDeps root` reads that file, finds the
-- `[dependencies]` section, and returns a list of (depName, depRootAbsPath) with
-- the relative path resolved against `root` (left literal — the OS resolves any
-- `..` when the path later reaches fileExists/readFile).  No stdlib/parsec import:
-- a tiny hand-rolled line scanner (mirrors loader.mdk's no-stdlib style).
--
-- Threading: an import whose FIRST dotted segment equals a declared dep name is
-- resolved by stripping that segment and resolving the REMAINDER under the dep's
-- root (`parsec.lib.parser` → `<depRoot>/lib/parser.mdk`).  A dep's
-- OWN imports (stdlib `array`/`list`/… or its sibling modules) still flow through
-- the normal `roots` list, so this is purely additive on top of single-root.

-- strip surrounding ASCII double-quotes from a trimmed value, if present.
unquote : String -> String
unquote s =
  let n = stringLength s
  if n >= 2 && stringSlice 0 1 s == "\"" && stringSlice (n - 1) n s == "\"" then
    stringSlice 1 (n - 1) s
  else
    s

-- the substring before the first `=` (trimmed); "" if there is no `=`.
keyBeforeEq : String -> String
keyBeforeEq line = keyEqGo line 0 (stringLength line)

keyEqGo : String -> Int -> Int -> String
keyEqGo line i n =
  if i >= n then
    ""
  else if stringSlice i (i + 1) line == "=" then
    stringTrim (stringSlice 0 i line)
  else
    keyEqGo line (i + 1) n

-- the substring after the first `=` (trimmed + unquoted); "" if there is no `=`.
valAfterEq : String -> String
valAfterEq line = valEqGo line 0 (stringLength line)

valEqGo : String -> Int -> Int -> String
valEqGo line i n =
  if i >= n then
    ""
  else if stringSlice i (i + 1) line == "=" then
    unquote (stringTrim (stringSlice (i + 1) n line))
  else
    valEqGo line (i + 1) n

-- scan the lines of a medaka.toml: once we cross the `[dependencies]` header,
-- collect `name = "path"` entries until the next `[section]` header (or EOF).
-- `inDeps` tracks whether we are currently inside the dependencies section.
collectDeps : String -> List String -> List (String, String)
collectDeps root [] = []
collectDeps root (line::rest) =
  let t = stringTrim line
  if t == "[dependencies]" then
    collectDepsIn root rest
  else
    collectDeps root rest

collectDepsIn : String -> List String -> List (String, String)
collectDepsIn root [] = []
collectDepsIn root (line::rest) =
  let t = stringTrim line
  if startsWith "[" t then collectDeps root (line::rest)
  else
    let k = keyBeforeEq t
    if k == "" then
      collectDepsIn root rest
    else
      (k, joinPathL root (valAfterEq t)) :: collectDepsIn root rest

-- join a project root with a (possibly `..`-relative) dep path.  An absolute dep
-- path (leading `/`) is used as-is; otherwise it is appended under root and the
-- OS resolves `..` later at fileExists/readFile time.
joinPathL : String -> String -> String
joinPathL root p =
  if startsWith "/" p then
    p
  else if root == "" then
    p
  else
    stringConcat [root, "/", p]

-- read + parse `<root>/medaka.toml`'s [dependencies]; [] if missing/none.
export readDeps : String -> <IO> List (String, String)
readDeps root =
  let tomlPath = stringConcat [root, "/medaka.toml"]
  if fileExists tomlPath then match readFile tomlPath
    Err _ => []
    Ok src => collectDeps root (splitNl src)
  else []

-- if modId's first dotted segment names a declared dependency, resolve the
-- REMAINING segments under that dep's root (existence-checked); else None so the
-- caller falls through to the normal `roots` search.  Returns (path, depRoot) so
-- the caller can REMEMBER which package the resolved module belongs to: that
-- dep's OWN intra-package (relative/bare) imports must rebase to its `depRoot`,
-- not the entry project's root (else `parsec.lib.toml`'s sibling
-- `import lib.parser` would be looked up under the entry project and fail).
resolveDepFile : List (String, String) -> String -> <IO> Option (String, String)
resolveDepFile deps modId = match splitOnChar "." modId
  [] => None
  seg0::restSegs => match lookupAssoc seg0 deps
    None => None
    Some depRoot => match restSegs
      [] => None
      _ =>
        let path = fileOfModuleId depRoot (joinDot restSegs)
        if fileExists path then Some (path, depRoot) else None

-- ── dependency extraction (mirrors loader.ml's direct_imports) ──

-- "core" is the implicit prelude — its names are already in scope, so an
-- `import core.{…}` is a no-op the loader must skip (else it duplicates).
export importModId : UsePath -> String
importModId (UseName ns) =
  if listLen ns > 1 then
    joinDot (initList ns)
  else
    lastOr "" ns
importModId (UseGroup ns _) = joinDot ns
importModId (UseWild ns) = joinDot ns
importModId (UseAlias ns _) = joinDot ns

directImports : List Decl -> List String
directImports [] = []
directImports ((DUse _ path _)::rest) =
  let m = importModId path
  if m == "core" then directImports rest else m :: directImports rest
directImports (_::rest) = directImports rest

-- ── F3 Chunk B: entry-scan for the R-MODULE-LOAD `{0,0}` diagnostic ────────
-- `readModuleProg`/`readModuleProgF` return a raw `Err "unknown module: X"`
-- string with no location (the loader's graph walk has no per-diagnostic Loc
-- channel — see the module doc-comment).  Rather than thread `Option Loc`
-- through every loader signature, the CLI/diagnostics call site re-scans the
-- ENTRY file's own (already-parsed, already-located) decls for the `DUse`
-- whose `importModId` is the failed module id and borrows its span.  Correct
-- for the common case (the entry directly imports the bad module); a bad
-- import nested in a transitive dependency degrades to no location, same as
-- before this change.

-- Extract the failed module id from a loader `Err` message of the exact shape
-- `readModuleProg`/`readModuleProgF` produce ("unknown module: <id>"); `None`
-- for any other loader error text (cycle / unreadable file) so callers only
-- special-case the one message shape they can actually re-locate.
export unknownModuleIdOf : String -> Option String
unknownModuleIdOf msg =
  let prefix = "unknown module: "
  if startsWith prefix msg then
    Some (stringSlice (stringLength prefix) (stringLength msg) msg)
  else
    None

-- The Loc of the first `DUse` (top-level or under `DAttrib`) importing module
-- id `mid`, or `None` if no such import appears in `decls`.
export findImportLoc : String -> List Decl -> Option Loc
findImportLoc _ [] = None
findImportLoc mid ((DUse _ path loc)::rest) =
  if importModId path == mid then
    Some loc
  else
    findImportLoc mid rest
findImportLoc mid ((DAttrib _ d)::rest) = findImportLoc mid (d::rest)
findImportLoc mid (_::rest) = findImportLoc mid rest

-- ── F: available-module hint enumeration ────────────────────────────────────
-- List the importable stdlib module ids — used to build the "available
-- modules: ..." hint on an `unknown module` error (see moduleLoadErrText /
-- runCheckJsonCmd in medaka_cli.mdk).  Enumerates the STDLIB DIRECTORY ONLY
-- (not the project/CWD root): the stdlib set is the stable, canonical "which
-- module did you mean" list, whereas the project root can hold loose `.mdk`
-- files (e.g. sibling test fixtures) that would pollute the suggestion and
-- churn the golden.  Only top-level entries are considered (the stdlib layout
-- is flat).  `core`/`runtime` are excluded: they are the implicit prelude,
-- never spelled in an `import`.  Deduped + sorted (`sortUniqS`) so the result
-- is deterministic regardless of `listDir`'s on-disk ordering — required for a
-- stable golden.
export availableModuleIds : String -> <IO> List String
availableModuleIds stdlibDir = match listDir stdlibDir
  Err _ => []
  Ok entries => sortUniqS (filterMap mdkBaseName entries)

-- `foo.mdk` -> `Some "foo"`; dotfiles, non-`.mdk` entries, and the two implicit
-- prelude modules are dropped.
mdkBaseName : String -> Option String
mdkBaseName name =
  if endsWith ".mdk" name && not (startsWith "." name) then
    let base = stringSlice 0 (stringLength name - 4) name
    if base == "core" || base == "runtime" then None else Some base
  else None

-- Plain "available modules: array, list, map, string" text (no leading
-- separator) — this is what feeds the structured JSON `help` field.  `[]` (no
-- stdlib dir readable) yields "".
export availableModulesText : String -> <IO> String
availableModulesText stdlibDir = match availableModuleIds stdlibDir
  [] => ""
  ids => stringConcat ["available modules: ", joinComma ids]

-- Render the hint SUFFIX appended to an `unknown module: <id>` CLI-text
-- message, e.g. " — available modules: array, list, map, string".  `[]` (no
-- stdlib dir readable) yields "" so callers can unconditionally append without
-- a conditional.
export availableModulesHint : String -> <IO> String
availableModulesHint stdlibDir = match availableModulesText stdlibDir
  "" => ""
  txt => " — " ++ txt

joinComma : List String -> String
joinComma [] = ""
joinComma [x] = x
joinComma (x::xs) = stringConcat [x, ", ", joinComma xs]

-- ── file resolution + parsing ──

-- Resolve a module ID to (filePath, owningRoot).  `owningRoot` is the package
-- root the module was found under — a declared dep's root if the import was
-- dep-prefixed, else the entry root (or stdlib root) it matched in `roots`.  The
-- caller threads `owningRoot` so the module's OWN intra-package imports rebase to
-- it (see visitMod).
findModuleFile : List (String, String) -> List String -> String -> <IO> Option (String, String)
findModuleFile deps roots modId = match resolveDepFile deps modId
  Some pathRoot => Some pathRoot
  None => findInRoots roots modId

findInRoots : List String -> String -> <IO> Option (String, String)
findInRoots [] _ = None
findInRoots (r::rs) modId =
  let path = fileOfModuleId r modId
  if fileExists path then Some (path, r) else findInRoots rs modId

-- ── the loader's error channel (issue #100) ─────────────────────────────────
--
-- A load failure is DATA, not a panic.  `LoadMsg` carries the pre-existing
-- free-text failures verbatim (unknown module / cyclic dependency / unreadable
-- file), so every caller that only wants a string is unaffected via
-- `loadErrorMessage`.  `LoadParseFailed path src err` is the structured half: a
-- parse or lex error inside a MODULE of the graph, carrying the owning module's
-- FILE PATH and the exact SOURCE that was parsed, plus the located `ParseError`.
--
-- Both extra fields are load-bearing.  The path is the whole point: before this,
-- the parser panicked and the failure lost the module it belonged to, so the
-- driver could only ever attribute it to the ENTRY file.  The source must travel
-- WITH the error rather than be re-read by the caller, because under the LSP's
-- unsaved-buffer `read` override the on-disk bytes are NOT what was parsed —
-- re-reading would render the caret against stale text.
public export data LoadError =
  | LoadMsg String
  | LoadParseFailed String String ParseError

-- Flatten a LoadError to the free-text message the pre-#100 `Result String` API
-- returned.  Keeps the ~15 callers that only report a string a one-line change,
-- and upgrades them for free: a module parse error now prints
-- `path:line:col: message` instead of a bare unlocated `parse error` panic.
export loadErrorMessage : LoadError -> String
loadErrorMessage (LoadMsg m) = m
loadErrorMessage (LoadParseFailed path _ e) =
  "\{path}:\{parseErrorLine e}:\{parseErrorCol e}: \{parseErrorMessage e}"

-- ── read-callback variant (B.10.5: unsaved-editor-buffer overrides) ──
--
-- A `String -> Option String` callback keyed by FILE PATH (mirror
-- lib/diagnostics.ml's `read : string -> string option`).  `Some src` shadows the
-- on-disk file with an editor buffer that has not been saved yet; `None` falls
-- back to `readFile`.  This lets the LSP analyse a project against the documents
-- the client currently holds rather than the (possibly stale) disk copies.  The
-- purely additive (`loadProgramFilesE` below threads the callback through the same
-- topo-sort, so there is no second graph-walk to keep in sync).  `loadProgram` is
-- now a projection of this walk too (see below) — there is exactly ONE DFS.

-- Resolve a module ID to its FILE PATH + source, consulting the override callback
-- first (so an unsaved buffer wins), then disk.  Returns (path, decls) so the
-- caller can bucket diagnostics BY FILE.  `read` is the path-keyed override;
-- `parseFn` is the NON-PANICKING parser to apply (so the located variant can carry
-- real ELoc spans via parseLocatedResult while the plain variant uses
-- placeholder-loc parseResult).  A parse failure becomes a `LoadParseFailed`
-- tagged with THIS module's path + the exact source `parseFn` saw.
readModuleProgF : (String -> Result ParseError (List Decl)) -> (String -> Option String) -> List (String, String) -> List String -> String -> <IO> Result LoadError (String, String, List Decl)
readModuleProgF parseFn read deps roots modId = match findModuleFile deps roots modId
  None => Err (LoadMsg (stringConcat ["unknown module: ", modId]))
  Some (path, owningRoot) => match read path
    Some src => parsedModule parseFn owningRoot path src
    None => match readFile path
      Err e => Err (LoadMsg e)
      Ok src => parsedModule parseFn owningRoot path src
-- unsaved editor buffer shadows disk

-- Parse one module's source, tagging a failure with the module it came from.
-- The single place a `ParseError` is promoted to a `LoadError`, so both the
-- buffer-override and the on-disk arm attribute identically.
parsedModule : (String -> Result ParseError (List Decl)) -> String -> String -> String -> Result LoadError (String, String, List Decl)
parsedModule parseFn owningRoot path src = match parseFn src
  Err e => Err (LoadParseFailed path src e)
  Ok prog => Ok (owningRoot, path, prog)

-- ── canonical module-id rewrite (F1b loader module identity) ─────────────────
--
-- A physical file reachable under two import SPELLINGS — e.g. the entry's
-- dep-prefixed `parsec.lib.parser` and a sibling module's intra-package
-- `lib.parser` — is otherwise loaded TWICE under two distinct modIds, so any
-- `export impl` it declares is double-counted → a spurious `conflicting impl`.
-- Fix: canonicalize every import to a single dep-name-prefixed modId derived from
-- WHERE the import resolves, and rewrite each `DUse` so resolve / typecheck / eval
-- (which key strictly by the literal modId string) collapse the two spellings
-- with ZERO changes — they keep reading `useModId(DUse)`, now canonical.
--
-- The canonical id is a deterministic function of the resolved file: an import
-- resolving UNDER a declared dep's root becomes `<depName>.<relIdUnderDepRoot>`;
-- one resolving under the entry / stdlib root (or unresolved) keeps its modId
-- unchanged.  Two spellings of one file → one resolved path → one owningRoot →
-- one canonical id, so both `DUse`s rewrite to the SAME string and dedup at
-- visitMod.  Single-root loads (no `[dependencies]`) are a NO-OP: no owningRoot is
-- a dep root, so every canonical id equals the original and no DUse is touched.
-- (Same-spelling identity needs no realpath: the same dep root string threads as
-- `owningRoot` to both spellings.  The remaining two-NAMES corner — one physical
-- dir declared under two dep names, e.g. entry `pc = "../parsec"` + a transitive
-- dep `parsec = "../parsec"`, whose `..`-joined roots are different literal
-- strings — is closed by realpath-canonicalizing the owning root + file path before
-- the dep-name reverse-lookup and the rel-segment computation: one physical file →
-- one canonical id regardless of the dep-name spelling.  See revLookupRoot/canonicalModId.)

splitDot : String -> List String
splitDot s = splitOnChar "." s

-- reverse-lookup a declared dependency NAME by its resolved root path, comparing
-- REALPATH-canonicalized roots.  Two spellings of one physical directory — the
-- entry's `pc = "../parsec"` and a transitive dep's `parsec = "../parsec"`,
-- which `joinPathL` produces as DIFFERENT literal `..`-bearing strings — realpath to
-- the SAME absolute path, so the SAME dep name is chosen for both.  First match wins,
-- so the canonical name is deterministic: the entry's deps lead the list (childDeps
-- appends a crossed-into package's own deps AFTER the inherited ones), so both
-- spellings pick the same first-declared name.  `cr` is the caller's already-realpath'd
-- owning root (canonicalize once, compare against each dep root's realpath).
revLookupRoot : String -> List (String, String) -> <IO> Option String
revLookupRoot _ [] = None
revLookupRoot cr ((n, dr)::rest) =
  if canonicalizePath dr == cr then
    Some n
  else
    revLookupRoot cr rest

-- the canonical modId for an import string `m`, resolved against (deps, roots).
-- Under a declared dep's root → prefix the dep name onto the module's path-
-- relative id; otherwise (entry / stdlib root, or unresolved) leave `m` as-is.
-- Both the owning root and the resolved file path are realpath-canonicalized
-- before the dep-name reverse-lookup and the relative-segment computation, so a
-- physical file reached under two dep-NAME spellings yields ONE canonical id.
canonicalModId : List (String, String) -> List String -> String -> <IO> String
canonicalModId deps roots m = match findModuleFile deps roots m
  None => m
  Some (path, owningRoot) =>
    let cOwn = canonicalizePath owningRoot
    match revLookupRoot cOwn deps
      None => m
      Some depName => stringConcat [depName, ".", moduleIdOfPath [cOwn] (canonicalizePath path)]

-- rewrite a UsePath so its `importModId` yields the canonical id `c`, preserving
-- the imported member list / wildcard / alias / single name.  (For UseName the
-- imported NAME is the last segment; the module path is the prefix — so appending
-- the original last segment onto `splitDot c` makes `importModId` recover `c`.)
rewriteUsePath : String -> UsePath -> UsePath
rewriteUsePath c (UseName ns) = UseName (splitDot c ++ [lastOr "" ns])
rewriteUsePath c (UseGroup _ ms) = UseGroup (splitDot c) ms
rewriteUsePath c (UseWild _) = UseWild (splitDot c)
rewriteUsePath c (UseAlias _ a) = UseAlias (splitDot c) a

-- rewrite one decl: a `DUse` whose import resolves under a dep root is rebased to
-- its canonical modId (core + already-canonical imports stay byte-identical).
rewriteDecl : List (String, String) -> List String -> Decl -> <IO> Decl
rewriteDecl deps roots (DUse exported path loc) =
  let m = importModId path
  if m == "core" then DUse exported path loc
  else
    let c = canonicalModId deps roots m
    if c == m then
      DUse exported path loc
    else
      DUse exported (rewriteUsePath c path) loc
rewriteDecl _ _ d = d

-- rewrite every `DUse` in a module's decls to its canonical modId.
rewriteDecls : List (String, String) -> List String -> List Decl -> <IO> List Decl
rewriteDecls _ _ [] = []
rewriteDecls deps roots (d::ds) =
  let d2 = rewriteDecl deps roots d
  d2 :: rewriteDecls deps roots ds

-- ── DFS topological sort (dependency-first; leaves before roots) ──
--
-- threads (visited, acc): visited = modules fully processed (Done); the stack
-- carries in-progress modules so a back-edge into one is reported as a cycle.
-- acc accumulates each module AFTER its dependencies → dependency-first order.

-- R2: build the full cycle chain from the in-progress stack when a back-edge to
-- `modId` is detected.  stack is most-recent-first (e.g. ["b","a"] when a→b→a).
-- We extract everything up to and including `modId`, reverse it, then append
-- `modId` again: ["b","a"] → take ["b","a"] → reverse ["a","b"] → + "a" = ["a","b","a"]
-- Mirrors lib/loader.ml's `take_until [mod_id] stack` → `List.rev` → join " → ".
cycleChain : String -> List String -> List String
cycleChain modId stack = reverseL (takeTo modId stack) ++ [modId]

takeTo : String -> List String -> List String
takeTo _ [] = []
takeTo target (x::xs) = if x == target then [x] else x :: takeTo target xs

joinArrow : List String -> String
joinArrow [] = ""
joinArrow [x] = x
joinArrow (x::xs) = stringConcat [x, " → ", joinArrow xs]

-- ── owning-package rebasing for a dep's intra-package imports ─────────────────
--
-- When a module is loaded from a dependency package (`owningRoot` ≠ the entry
-- root), its OWN imports must resolve against THAT package, not the entry
-- project:
--   * its intra-package (relative/bare) imports — `import lib.parser`,
--     `import foo` — rebase to `owningRoot` (prepended to `roots` so the dep's
--     copy is preferred over a same-named entry-project module);
--   * its OWN `[dependencies]` (a transitive dep — a dep importing ITS dep by
--     name) become visible by reading `<owningRoot>/medaka.toml`'s deps and
--     appending them.  The entry's deps stay first so the entry's view wins on a
--     name clash, and a dep's stdlib imports keep flowing through the original
--     `roots` (the stdlib root is never dropped).
-- For a module found under a root already in `roots` (entry / stdlib / a root we
-- already entered), nothing changes — this is purely additive.

childRoots : String -> List String -> List String
childRoots owningRoot roots =
  if contains owningRoot roots then
    roots
  else
    owningRoot::roots

-- The deps in effect for a module owned by `owningRoot`: the inherited `deps`
-- plus, when we've crossed into a new package (owningRoot not yet in `roots`),
-- that package's own declared dependencies (resolved against owningRoot).
childDeps : List (String, String) -> String -> List String -> <IO> List (String, String)
childDeps deps owningRoot roots =
  if contains owningRoot roots then
    deps
  else
    deps ++ readDeps owningRoot

-- Load a root file + all transitive deps, dependency-first.  roots resolves
-- module IDs to file paths (compiler: a single project dir).  Cross-project
-- dependencies declared in the entry project's medaka.toml are read here and
-- consulted before `roots` (see resolveDepFile).
-- ── internal-extern trust signal ──
--
-- The modIds among `mods` that are TRUSTED to reference internal-only externs
-- (arrayGetUnsafe, …).  `stdlibRoot` (where core.mdk/runtime.mdk live) is ALWAYS
-- trusted.  Additionally, when the entry belongs to a REAL PROJECT — i.e. a
-- `medaka.toml` exists at `findProjectRoot (parentDir entry)`, which
-- distinguishes it from `findProjectRoot`'s no-manifest fallback of returning the
-- entry's own dir — every module owned by one of the entry's OWN search `roots`
-- (the entry dir + that project root, per `entrySearchRoots`) is trusted: it is
-- part of the entry project.  A DECLARED DEPENDENCY resolves to a root OUTSIDE
-- `roots` (via `resolveDepFile`/`childRoots`, added only after we cross into the
-- dep package), so it stays UNTRUSTED.
--
-- This is the principled boundary the guard wants: your OWN project (as declared
-- by its `medaka.toml`) + the stdlib may call unsafe array kernels; a third-party
-- dep you imported may not, and a LOOSE single file with no `medaka.toml` may not
-- (pass `--allow-internal` to override either).  Gating on manifest presence is
-- what keeps a bare `medaka check foo.mdk` on a loose user file that calls
-- `arrayGetUnsafe` REJECTED (whose fallback project root == its own dir would
-- otherwise self-trust) while letting a self-hosting compiler-PROJECT file check
-- itself without `--allow-internal`.  [Previously trusted ONLY `stdlibRoot`, so
-- checking/building a compiler-project file flagged its own sibling modules'
-- legitimate kernel calls as errors unless the flag was passed every time — #42.]
--
-- Re-resolves each modId's file via the same deps/roots the load used and
-- compares the owning root against the trusted set — robust where the modId is
-- ambiguous (an `import array` yields the bare modId "array", indistinguishable
-- from a user file by name alone).  Realpath-canonicalize BOTH sides (mirrors
-- `canonicalModId`/`revLookupRoot`'s established pattern for the "two spellings,
-- one physical dir" problem — `owningRoot` may be a RELATIVE `roots` entry while
-- the physical dir is absolute) so the comparison is spelling-independent.
export projectTrustedMods : String -> List String -> String -> List (String, List Decl) -> <IO> List String
projectTrustedMods entry roots stdlibRoot mods =
  let projectRoot = findProjectRoot (parentDir entry)
  let deps = readDeps projectRoot
  let hasProject = fileExists (stringConcat [projectRoot, "/medaka.toml"])
  let trustedRoots = if hasProject then
    map canonicalizePath (stdlibRoot::roots)
  else
    [canonicalizePath stdlibRoot]
  trustedModsGo deps roots trustedRoots (map fst mods)

trustedModsGo : List (String, String) -> List String -> List String -> List String -> <IO> List String
trustedModsGo _ _ _ [] = []
trustedModsGo deps roots trustedRoots (m::ms) = match findModuleFile deps roots m
  Some (_, owningRoot) =>
    if contains (canonicalizePath owningRoot) trustedRoots then
      m :: trustedModsGo deps roots trustedRoots ms
    else
      trustedModsGo deps roots trustedRoots ms
  None => trustedModsGo deps roots trustedRoots ms

-- Load a root file + transitive deps, dependency-first, WITHOUT the file paths.
-- A projection of `loadProgramFilesE` (disk-only read, paths dropped) rather than a
-- second DFS: until #100 this had its own `visitMod`/`visitMods`/`readModuleProg`
-- twin of the walk below, which is exactly the parallel-driver shape that lets a
-- fix land in one copy and silently miss the other.  Same order, same cycle
-- detection — there is only one implementation of either now.
export loadProgram : String -> List String -> <IO> Result String (List (String, List Decl))
loadProgram entry roots = mapErr loadErrorMessage (loadProgramE entry roots)

-- `loadProgram` with the structured error retained.  The check/--json drivers use
-- this so a `LoadParseFailed` can be attributed to the module that owns it; the
-- string-only callers keep the flattened `loadProgram` above.
export loadProgramE : String -> List String -> <IO> Result LoadError (List (String, List Decl))
loadProgramE entry roots = map
  (mods => map dropPathTriple mods)
  (loadProgramFilesE (_ => None) entry roots)

dropPathTriple : (String, String, List Decl) -> (String, List Decl)
dropPathTriple (mid, _, decls) = (mid, decls)

-- ── path-carrying read-callback topo-sort (B.10.5) ──
--
-- The one dependency-first DFS: every read goes through the `read` override
-- callback (unsaved buffers win) and the accumulator carries the FILE PATH
-- alongside (modId, decls), so analyzeProject can bucket diagnostics by file.

visitModF : (String -> Result ParseError (List Decl)) -> (String -> Option String) -> List (String, String) -> List String -> List String -> List String -> List (String, String, List Decl) -> String -> <IO> Result LoadError (List String, List (String, String, List Decl))
visitModF parseFn read deps roots stack visited acc modId =
  if contains modId visited then Ok (visited, acc)
  else
    if contains modId stack then Err (LoadMsg (stringConcat ["cyclic dependency: ", joinArrow (cycleChain modId stack)]))
    else match readModuleProgF parseFn read deps roots modId
      Err e => Err e
      Ok (owningRoot, path, prog) =>
        let croots = childRoots owningRoot roots
        let cdeps = childDeps deps owningRoot roots
        let prog2 = rewriteDecls cdeps croots prog
        map
          ((visited2, acc2) => (modId::visited2, acc2 ++ [(modId, path, prog2)]))
          (visitModsF
            parseFn
            read
            cdeps
            croots
            (modId::stack)
            visited
            acc
            (directImports prog2))

visitModsF : (String -> Result ParseError (List Decl)) -> (String -> Option String) -> List (String, String) -> List String -> List String -> List String -> List (String, String, List Decl) -> List String -> <IO> Result LoadError (List String, List (String, String, List Decl))
visitModsF _ _ _ _ _ visited acc [] = Ok (visited, acc)
visitModsF parseFn read deps roots stack visited acc (d::ds) = match visitModF parseFn read deps roots stack visited acc d
  Err e => Err e
  Ok (v2, a2) => visitModsF parseFn read deps roots stack v2 a2 ds

-- Load a root file + transitive deps, dependency-first, with an unsaved-buffer
-- override and FILE PATHS in the result.  Mirrors lib/diagnostics.ml's
-- `Loader.load_program ~read` returning `(mod_id, file_path, prog)` triples.
-- A `read` of `(_ => None)` is exactly `loadProgram` (disk-only) plus paths.
-- Uses placeholder-loc `parseResult`.
export loadProgramFilesE : (String -> Option String) -> String -> List String -> <IO> Result LoadError (List (String, String, List Decl))
loadProgramFilesE read entry roots =
  let deps = readDeps (findProjectRoot (parentDir entry))
  map
    ((_, acc) => acc)
    (visitModF
      parseResult
      read
      deps
      roots
      []
      []
      []
      (moduleIdOfPath roots entry))

-- Like loadProgramFilesE but parses every module with `parseLocatedResult`, so the
-- resulting decls carry REAL ELoc spans (B.10.2b) — the LSP project path uses
-- this so type-error diagnostics get expr-level ranges, mirroring the single-doc
-- `analyzeLocated`.
export loadProgramFilesLocatedE : (String -> Option String) -> String -> List String -> <IO> Result LoadError (List (String, String, List Decl))
loadProgramFilesLocatedE read entry roots =
  let deps = readDeps (findProjectRoot (parentDir entry))
  map
    ((_, acc) => acc)
    (visitModF
      parseLocatedResult
      read
      deps
      roots
      []
      []
      []
      (moduleIdOfPath roots entry))

-- ── LSP latency: source-keyed parse memoization (per-keystroke dep reuse) ────
--
-- The LSP runs this whole loader on EVERY didChange.  Profiling showed the
-- `parseLocated` of the import graph is ~80% of an import-bearing keystroke's
-- cost: a buffer that `import json` re-parses json + list + array + string
-- (~2.3k lines) every keystroke even though ONLY the edited entry buffer
-- changed.  `parseCachedLocated` memoizes `parseLocated` by SOURCE STRING in a
-- session-lived Ref: identical dep source across keystrokes hits the cache, so
-- only the (changed) entry buffer actually re-parses.
--
-- Keying on source content (not path) is correct AND robust: `parseLocated` is a
-- pure function of its input, so equal source ⇒ equal located decls (same ELoc
-- line/col).  An edited buffer has new source ⇒ a miss ⇒ a fresh parse, and its
-- old entry is harmless dead weight (the cache is bounded below).  Bounding keeps
-- the assoc list small over a long session of edits: keep the most-recent N (one
-- per file in a typical graph + a little slack), dropping the oldest on overflow.

parseCacheLimit : Int
parseCacheLimit = 24

-- memoizing parseLocated: consult the cache by source, else parse + insert.
-- Most-recently-used moves to the front; the list is truncated to the limit so a
-- long editing session does not grow it unboundedly.
-- Only SUCCESSES are cached: a failure is cheap (the parse stopped early) and
-- caching it would widen the session-lived cache's type to a Result, which every
-- LSP caller's `Ref (List (String, List Decl))` signature would have to follow for
-- no gain.
parseCachedLocated : Ref (List (String, List Decl)) -> String -> Result ParseError (List Decl)
parseCachedLocated cacheRef src = match lookupAssoc src cacheRef.value
  Some decls => Ok decls
  None => match parseLocatedResult src
    Err e => Err e
    Ok decls =>
      let _ = setRef cacheRef (takeFirst parseCacheLimit ((src, decls) :: dropKey src cacheRef.value))
      Ok decls

-- drop any existing entry with this key (so a re-parse refreshes its position).
dropKey : String -> List (String, List Decl) -> List (String, List Decl)
dropKey _ [] = []
dropKey k ((k2, v)::rest)
  | k == k2 = dropKey k rest
  | otherwise = (k2, v) :: dropKey k rest

takeFirst : Int -> List a -> List a
takeFirst _ [] = []
takeFirst n (x::xs)
  | n <= 0 = []
  | otherwise = x :: takeFirst (n - 1) xs

-- Like loadProgramFilesLocatedE but parses each module through the source-keyed
-- memo `parseCacheRef`.  Behaviourally identical (same located decls per module);
-- only the cost differs (unchanged deps skip re-parsing).  The LSP threads a
-- session-lived cache so reuse spans didChange events.
export loadProgramFilesLocatedCached : Ref (List (String, List Decl)) -> (String -> Option String) -> String -> List String -> <IO> Result String (List (String, String, List Decl))
loadProgramFilesLocatedCached parseCacheRef read entry roots =
  mapErr
    loadErrorMessage
    (loadProgramFilesLocatedCachedE parseCacheRef read entry roots)

export loadProgramFilesLocatedCachedE : Ref (List (String, List Decl)) -> (String -> Option String) -> String -> List String -> <IO> Result LoadError (List (String, String, List Decl))
loadProgramFilesLocatedCachedE parseCacheRef read entry roots =
  let deps = readDeps (findProjectRoot (parentDir entry))
  map
    ((_, acc) => acc)
    (visitModF
      (s => parseCachedLocated parseCacheRef s)
      read
      deps
      roots
      []
      []
      []
      (moduleIdOfPath roots entry))
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DUse" false) (mem "DAttrib" false) (mem "UsePath" false) (mem "UseName" false) (mem "UseGroup" false) (mem "UseWild" false) (mem "UseAlias" false) (mem "Loc" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "parseResult" false) (mem "parseLocatedResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "reverseL" false) (mem "initList" false) (mem "startsWith" false) (mem "endsWith" false) (mem "joinDot" false) (mem "lookupAssoc" false) (mem "splitNl" false) (mem "stringTrim" false) (mem "sortUniqS" false))))
(DTypeSig false "lastOr" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyVar "a"))))
(DFunDef false "lastOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "lastOr" (PWild (PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOr" ((PVar "d") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "lastOr") (EVar "d")) (EVar "xs")))
(DTypeSig false "splitOnChar" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "splitOnChar" ((PVar "sep") (PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "sep")) (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LString ""))))
(DTypeSig false "splitGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitGo" ((PVar "sep") (PVar "s") (PVar "i") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EListLit (EVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EVar "sep")) (EBinOp "::" (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "sep")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "sep")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "++" (EVar "acc") (EVar "c"))))))))
(DTypeSig false "joinSlash" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSlash" ((PList)) (ELit (LString "")))
(DFunDef false "joinSlash" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinSlash" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString "/")) (EApp (EVar "joinSlash") (EVar "xs")))))
(DTypeSig false "slashToDot" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "slashToDot" ((PVar "s")) (EApp (EVar "joinDot") (EApp (EApp (EVar "splitOnChar") (ELit (LString "/"))) (EVar "s"))))
(DTypeSig false "dropPrefix" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dropPrefix" ((PVar "k") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "k")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig false "stripSuffixStr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripSuffixStr" ((PVar "suf") (PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (EVar "suf")) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "suf")))) (EVar "s")) (EVar "s")))
(DTypeSig false "fileOfModuleId" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "fileOfModuleId" ((PVar "root") (PVar "modId")) (EApp (EVar "stringConcat") (EListLit (EVar "root") (ELit (LString "/")) (EApp (EVar "joinSlash") (EApp (EApp (EVar "splitOnChar") (ELit (LString "."))) (EVar "modId"))) (ELit (LString ".mdk")))))
(DTypeSig false "relUnderRoots" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "relUnderRoots" ((PList) (PVar "path")) (EVar "path"))
(DFunDef false "relUnderRoots" ((PCons (PVar "r") (PVar "rs")) (PVar "path")) (EBlock (DoLet false false (PVar "pre") (EApp (EVar "stringConcat") (EListLit (EVar "r") (ELit (LString "/"))))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "pre")) (EVar "path")) (EApp (EApp (EVar "dropPrefix") (EApp (EVar "stringLength") (EVar "pre"))) (EVar "path")) (EApp (EApp (EVar "relUnderRoots") (EVar "rs")) (EVar "path"))))))
(DTypeSig false "moduleIdOfPath" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "moduleIdOfPath" ((PVar "roots") (PVar "path")) (EApp (EVar "slashToDot") (EApp (EApp (EVar "stripSuffixStr") (ELit (LString ".mdk"))) (EApp (EApp (EVar "relUnderRoots") (EVar "roots")) (EVar "path")))))
(DTypeSig true "findProjectRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "findProjectRoot" ((PVar "startDir")) (EApp (EApp (EVar "findRootGo") (EVar "startDir")) (EVar "startDir")))
(DTypeSig true "entrySearchRoots" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "entrySearchRoots" ((PVar "entryDir")) (EBlock (DoLet false false (PVar "projRoot") (EApp (EVar "findProjectRoot") (EVar "entryDir"))) (DoExpr (EIf (EBinOp "==" (EVar "projRoot") (EVar "entryDir")) (EListLit (EVar "projRoot")) (EListLit (EVar "entryDir") (EVar "projRoot"))))))
(DTypeSig false "findRootGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "findRootGo" ((PVar "cur") (PVar "fallback")) (EIf (EApp (EVar "fileExists") (EApp (EVar "stringConcat") (EListLit (EVar "cur") (ELit (LString "/medaka.toml"))))) (EVar "cur") (EBlock (DoLet false false (PVar "p") (EApp (EVar "parentDir") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "p") (EVar "cur")) (EBinOp "==" (EApp (EVar "stringLength") (EVar "p")) (ELit (LInt 0)))) (EVar "fallback") (EApp (EApp (EVar "findRootGo") (EVar "p")) (EVar "fallback")))))))
(DTypeSig false "parentDir" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parentDir" ((PVar "path")) (EApp (EApp (EVar "parentGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "parentGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "parentGo" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "parentGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "parentGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "unquote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unquote" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "\"")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "keyBeforeEq" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "keyBeforeEq" ((PVar "line")) (EApp (EApp (EApp (EVar "keyEqGo") (EVar "line")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "line"))))
(DTypeSig false "keyEqGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "keyEqGo" ((PVar "line") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (ELit (LString "="))) (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "line"))) (EApp (EApp (EApp (EVar "keyEqGo") (EVar "line")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "valAfterEq" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "valAfterEq" ((PVar "line")) (EApp (EApp (EApp (EVar "valEqGo") (EVar "line")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "line"))))
(DTypeSig false "valEqGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "valEqGo" ((PVar "line") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (ELit (LString "="))) (EApp (EVar "unquote") (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "line")))) (EApp (EApp (EApp (EVar "valEqGo") (EVar "line")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "collectDeps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "collectDeps" ((PVar "root") (PList)) (EListLit))
(DFunDef false "collectDeps" ((PVar "root") (PCons (PVar "line") (PVar "rest"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "stringTrim") (EVar "line"))) (DoExpr (EIf (EBinOp "==" (EVar "t") (ELit (LString "[dependencies]"))) (EApp (EApp (EVar "collectDepsIn") (EVar "root")) (EVar "rest")) (EApp (EApp (EVar "collectDeps") (EVar "root")) (EVar "rest"))))))
(DTypeSig false "collectDepsIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "collectDepsIn" ((PVar "root") (PList)) (EListLit))
(DFunDef false "collectDepsIn" ((PVar "root") (PCons (PVar "line") (PVar "rest"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "stringTrim") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "["))) (EVar "t")) (EApp (EApp (EVar "collectDeps") (EVar "root")) (EBinOp "::" (EVar "line") (EVar "rest"))) (EBlock (DoLet false false (PVar "k") (EApp (EVar "keyBeforeEq") (EVar "t"))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LString ""))) (EApp (EApp (EVar "collectDepsIn") (EVar "root")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EApp (EApp (EVar "joinPathL") (EVar "root")) (EApp (EVar "valAfterEq") (EVar "t")))) (EApp (EApp (EVar "collectDepsIn") (EVar "root")) (EVar "rest"))))))))))
(DTypeSig false "joinPathL" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPathL" ((PVar "root") (PVar "p")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "p")) (EVar "p") (EIf (EBinOp "==" (EVar "root") (ELit (LString ""))) (EVar "p") (EApp (EVar "stringConcat") (EListLit (EVar "root") (ELit (LString "/")) (EVar "p"))))))
(DTypeSig true "readDeps" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "readDeps" ((PVar "root")) (EBlock (DoLet false false (PVar "tomlPath") (EApp (EVar "stringConcat") (EListLit (EVar "root") (ELit (LString "/medaka.toml"))))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "tomlPath")) (EMatch (EApp (EVar "readFile") (EVar "tomlPath")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "collectDeps") (EVar "root")) (EApp (EVar "splitNl") (EVar "src"))))) (EListLit)))))
(DTypeSig false "resolveDepFile" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "resolveDepFile" ((PVar "deps") (PVar "modId")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LString "."))) (EVar "modId")) (arm (PList) () (EVar "None")) (arm (PCons (PVar "seg0") (PVar "restSegs")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "seg0")) (EVar "deps")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "depRoot")) () (EMatch (EVar "restSegs") (arm (PList) () (EVar "None")) (arm PWild () (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "fileOfModuleId") (EVar "depRoot")) (EApp (EVar "joinDot") (EVar "restSegs")))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "path")) (EApp (EVar "Some") (ETuple (EVar "path") (EVar "depRoot"))) (EVar "None")))))))))))
(DTypeSig true "importModId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "importModId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "lastOr") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "importModId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "importModId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "importModId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "directImports" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "directImports" ((PList)) (EListLit))
(DFunDef false "directImports" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "importModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "m") (ELit (LString "core"))) (EApp (EVar "directImports") (EVar "rest")) (EBinOp "::" (EVar "m") (EApp (EVar "directImports") (EVar "rest")))))))
(DFunDef false "directImports" ((PCons PWild (PVar "rest"))) (EApp (EVar "directImports") (EVar "rest")))
(DTypeSig true "unknownModuleIdOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unknownModuleIdOf" ((PVar "msg")) (EBlock (DoLet false false (PVar "prefix") (ELit (LString "unknown module: "))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "msg")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "msg"))) (EVar "msg"))) (EVar "None")))))
(DTypeSig true "findImportLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "findImportLoc" (PWild (PList)) (EVar "None"))
(DFunDef false "findImportLoc" ((PVar "mid") (PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "importModId") (EVar "path")) (EVar "mid")) (EApp (EVar "Some") (EVar "loc")) (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EVar "rest"))))
(DFunDef false "findImportLoc" ((PVar "mid") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findImportLoc" ((PVar "mid") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EVar "rest")))
(DTypeSig true "availableModuleIds" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "availableModuleIds" ((PVar "stdlibDir")) (EMatch (EApp (EVar "listDir") (EVar "stdlibDir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EVar "sortUniqS") (EApp (EApp (EVar "filterMap") (EVar "mdkBaseName")) (EVar "entries"))))))
(DTypeSig false "mdkBaseName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "mdkBaseName" ((PVar "name")) (EIf (EBinOp "&&" (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "name")))) (EBlock (DoLet false false (PVar "base") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "name")) (ELit (LInt 4)))) (EVar "name"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "base") (ELit (LString "core"))) (EBinOp "==" (EVar "base") (ELit (LString "runtime")))) (EVar "None") (EApp (EVar "Some") (EVar "base"))))) (EVar "None")))
(DTypeSig true "availableModulesText" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "availableModulesText" ((PVar "stdlibDir")) (EMatch (EApp (EVar "availableModuleIds") (EVar "stdlibDir")) (arm (PList) () (ELit (LString ""))) (arm (PVar "ids") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "available modules: ")) (EApp (EVar "joinComma") (EVar "ids")))))))
(DTypeSig true "availableModulesHint" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "availableModulesHint" ((PVar "stdlibDir")) (EMatch (EApp (EVar "availableModulesText") (EVar "stdlibDir")) (arm (PLit (LString "")) () (ELit (LString ""))) (arm (PVar "txt") () (EBinOp "++" (ELit (LString " — ")) (EVar "txt")))))
(DTypeSig false "joinComma" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinComma" ((PList)) (ELit (LString "")))
(DFunDef false "joinComma" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinComma" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString ", ")) (EApp (EVar "joinComma") (EVar "xs")))))
(DTypeSig false "findModuleFile" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "findModuleFile" ((PVar "deps") (PVar "roots") (PVar "modId")) (EMatch (EApp (EApp (EVar "resolveDepFile") (EVar "deps")) (EVar "modId")) (arm (PCon "Some" (PVar "pathRoot")) () (EApp (EVar "Some") (EVar "pathRoot"))) (arm (PCon "None") () (EApp (EApp (EVar "findInRoots") (EVar "roots")) (EVar "modId")))))
(DTypeSig false "findInRoots" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "findInRoots" ((PList) PWild) (EVar "None"))
(DFunDef false "findInRoots" ((PCons (PVar "r") (PVar "rs")) (PVar "modId")) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "fileOfModuleId") (EVar "r")) (EVar "modId"))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "path")) (EApp (EVar "Some") (ETuple (EVar "path") (EVar "r"))) (EApp (EApp (EVar "findInRoots") (EVar "rs")) (EVar "modId"))))))
(DData Public "LoadError" () ((variant "LoadMsg" (ConPos (TyCon "String"))) (variant "LoadParseFailed" (ConPos (TyCon "String") (TyCon "String") (TyCon "ParseError")))) ())
(DTypeSig true "loadErrorMessage" (TyFun (TyCon "LoadError") (TyCon "String")))
(DFunDef false "loadErrorMessage" ((PCon "LoadMsg" (PVar "m"))) (EVar "m"))
(DFunDef false "loadErrorMessage" ((PCon "LoadParseFailed" (PVar "path") PWild (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "parseErrorLine") (EVar "e")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "parseErrorCol") (EVar "e")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "parseErrorMessage") (EVar "e")))) (ELit (LString ""))))
(DTypeSig false "readModuleProgF" (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "readModuleProgF" ((PVar "parseFn") (PVar "read") (PVar "deps") (PVar "roots") (PVar "modId")) (EMatch (EApp (EApp (EApp (EVar "findModuleFile") (EVar "deps")) (EVar "roots")) (EVar "modId")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "LoadMsg") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unknown module: ")) (EVar "modId")))))) (arm (PCon "Some" (PTuple (PVar "path") (PVar "owningRoot"))) () (EMatch (EApp (EVar "read") (EVar "path")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EVar "parsedModule") (EVar "parseFn")) (EVar "owningRoot")) (EVar "path")) (EVar "src"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "LoadMsg") (EVar "e")))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EApp (EApp (EVar "parsedModule") (EVar "parseFn")) (EVar "owningRoot")) (EVar "path")) (EVar "src")))))))))
(DTypeSig false "parsedModule" (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "parsedModule" ((PVar "parseFn") (PVar "owningRoot") (PVar "path") (PVar "src")) (EMatch (EApp (EVar "parseFn") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "LoadParseFailed") (EVar "path")) (EVar "src")) (EVar "e")))) (arm (PCon "Ok" (PVar "prog")) () (EApp (EVar "Ok") (ETuple (EVar "owningRoot") (EVar "path") (EVar "prog"))))))
(DTypeSig false "splitDot" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitDot" ((PVar "s")) (EApp (EApp (EVar "splitOnChar") (ELit (LString "."))) (EVar "s")))
(DTypeSig false "revLookupRoot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "revLookupRoot" (PWild (PList)) (EVar "None"))
(DFunDef false "revLookupRoot" ((PVar "cr") (PCons (PTuple (PVar "n") (PVar "dr")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "canonicalizePath") (EVar "dr")) (EVar "cr")) (EApp (EVar "Some") (EVar "n")) (EApp (EApp (EVar "revLookupRoot") (EVar "cr")) (EVar "rest"))))
(DTypeSig false "canonicalModId" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "canonicalModId" ((PVar "deps") (PVar "roots") (PVar "m")) (EMatch (EApp (EApp (EApp (EVar "findModuleFile") (EVar "deps")) (EVar "roots")) (EVar "m")) (arm (PCon "None") () (EVar "m")) (arm (PCon "Some" (PTuple (PVar "path") (PVar "owningRoot"))) () (EBlock (DoLet false false (PVar "cOwn") (EApp (EVar "canonicalizePath") (EVar "owningRoot"))) (DoExpr (EMatch (EApp (EApp (EVar "revLookupRoot") (EVar "cOwn")) (EVar "deps")) (arm (PCon "None") () (EVar "m")) (arm (PCon "Some" (PVar "depName")) () (EApp (EVar "stringConcat") (EListLit (EVar "depName") (ELit (LString ".")) (EApp (EApp (EVar "moduleIdOfPath") (EListLit (EVar "cOwn"))) (EApp (EVar "canonicalizePath") (EVar "path"))))))))))))
(DTypeSig false "rewriteUsePath" (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyCon "UsePath"))))
(DFunDef false "rewriteUsePath" ((PVar "c") (PCon "UseName" (PVar "ns"))) (EApp (EVar "UseName") (EBinOp "++" (EApp (EVar "splitDot") (EVar "c")) (EListLit (EApp (EApp (EVar "lastOr") (ELit (LString ""))) (EVar "ns"))))))
(DFunDef false "rewriteUsePath" ((PVar "c") (PCon "UseGroup" PWild (PVar "ms"))) (EApp (EApp (EVar "UseGroup") (EApp (EVar "splitDot") (EVar "c"))) (EVar "ms")))
(DFunDef false "rewriteUsePath" ((PVar "c") (PCon "UseWild" PWild)) (EApp (EVar "UseWild") (EApp (EVar "splitDot") (EVar "c"))))
(DFunDef false "rewriteUsePath" ((PVar "c") (PCon "UseAlias" PWild (PVar "a"))) (EApp (EApp (EVar "UseAlias") (EApp (EVar "splitDot") (EVar "c"))) (EVar "a")))
(DTypeSig false "rewriteDecl" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyEffect ("IO") None (TyCon "Decl"))))))
(DFunDef false "rewriteDecl" ((PVar "deps") (PVar "roots") (PCon "DUse" (PVar "exported") (PVar "path") (PVar "loc"))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "importModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "m") (ELit (LString "core"))) (EApp (EApp (EApp (EVar "DUse") (EVar "exported")) (EVar "path")) (EVar "loc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "canonicalModId") (EVar "deps")) (EVar "roots")) (EVar "m"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EVar "m")) (EApp (EApp (EApp (EVar "DUse") (EVar "exported")) (EVar "path")) (EVar "loc")) (EApp (EApp (EApp (EVar "DUse") (EVar "exported")) (EApp (EApp (EVar "rewriteUsePath") (EVar "c")) (EVar "path"))) (EVar "loc")))))))))
(DFunDef false "rewriteDecl" (PWild PWild (PVar "d")) (EVar "d"))
(DTypeSig false "rewriteDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "rewriteDecls" (PWild PWild (PList)) (EListLit))
(DFunDef false "rewriteDecls" ((PVar "deps") (PVar "roots") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PVar "d2") (EApp (EApp (EApp (EVar "rewriteDecl") (EVar "deps")) (EVar "roots")) (EVar "d"))) (DoExpr (EBinOp "::" (EVar "d2") (EApp (EApp (EApp (EVar "rewriteDecls") (EVar "deps")) (EVar "roots")) (EVar "ds"))))))
(DTypeSig false "cycleChain" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "cycleChain" ((PVar "modId") (PVar "stack")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EVar "takeTo") (EVar "modId")) (EVar "stack"))) (EListLit (EVar "modId"))))
(DTypeSig false "takeTo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "takeTo" (PWild (PList)) (EListLit))
(DFunDef false "takeTo" ((PVar "target") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (EVar "target")) (EListLit (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeTo") (EVar "target")) (EVar "xs")))))
(DTypeSig false "joinArrow" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinArrow" ((PList)) (ELit (LString "")))
(DFunDef false "joinArrow" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinArrow" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString " → ")) (EApp (EVar "joinArrow") (EVar "xs")))))
(DTypeSig false "childRoots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "childRoots" ((PVar "owningRoot") (PVar "roots")) (EIf (EApp (EApp (EVar "contains") (EVar "owningRoot")) (EVar "roots")) (EVar "roots") (EBinOp "::" (EVar "owningRoot") (EVar "roots"))))
(DTypeSig false "childDeps" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "childDeps" ((PVar "deps") (PVar "owningRoot") (PVar "roots")) (EIf (EApp (EApp (EVar "contains") (EVar "owningRoot")) (EVar "roots")) (EVar "deps") (EBinOp "++" (EVar "deps") (EApp (EVar "readDeps") (EVar "owningRoot")))))
(DTypeSig true "projectTrustedMods" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "projectTrustedMods" ((PVar "entry") (PVar "roots") (PVar "stdlibRoot") (PVar "mods")) (EBlock (DoLet false false (PVar "projectRoot") (EApp (EVar "findProjectRoot") (EApp (EVar "parentDir") (EVar "entry")))) (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EVar "projectRoot"))) (DoLet false false (PVar "hasProject") (EApp (EVar "fileExists") (EApp (EVar "stringConcat") (EListLit (EVar "projectRoot") (ELit (LString "/medaka.toml")))))) (DoLet false false (PVar "trustedRoots") (EIf (EVar "hasProject") (EApp (EApp (EVar "map") (EVar "canonicalizePath")) (EBinOp "::" (EVar "stdlibRoot") (EVar "roots"))) (EListLit (EApp (EVar "canonicalizePath") (EVar "stdlibRoot"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "trustedModsGo") (EVar "deps")) (EVar "roots")) (EVar "trustedRoots")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "mods"))))))
(DTypeSig false "trustedModsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "trustedModsGo" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "trustedModsGo" ((PVar "deps") (PVar "roots") (PVar "trustedRoots") (PCons (PVar "m") (PVar "ms"))) (EMatch (EApp (EApp (EApp (EVar "findModuleFile") (EVar "deps")) (EVar "roots")) (EVar "m")) (arm (PCon "Some" (PTuple PWild (PVar "owningRoot"))) () (EIf (EApp (EApp (EVar "contains") (EApp (EVar "canonicalizePath") (EVar "owningRoot"))) (EVar "trustedRoots")) (EBinOp "::" (EVar "m") (EApp (EApp (EApp (EApp (EVar "trustedModsGo") (EVar "deps")) (EVar "roots")) (EVar "trustedRoots")) (EVar "ms"))) (EApp (EApp (EApp (EApp (EVar "trustedModsGo") (EVar "deps")) (EVar "roots")) (EVar "trustedRoots")) (EVar "ms")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "trustedModsGo") (EVar "deps")) (EVar "roots")) (EVar "trustedRoots")) (EVar "ms")))))
(DTypeSig true "loadProgram" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "loadProgram" ((PVar "entry") (PVar "roots")) (EApp (EApp (EVar "mapErr") (EVar "loadErrorMessage")) (EApp (EApp (EVar "loadProgramE") (EVar "entry")) (EVar "roots"))))
(DTypeSig true "loadProgramE" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "loadProgramE" ((PVar "entry") (PVar "roots")) (EApp (EApp (EVar "map") (ELam ((PVar "mods")) (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "mods")))) (EApp (EApp (EApp (EVar "loadProgramFilesE") (ELam (PWild) (EVar "None"))) (EVar "entry")) (EVar "roots"))))
(DTypeSig false "dropPathTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropPathTriple" ((PTuple (PVar "mid") PWild (PVar "decls"))) (ETuple (EVar "mid") (EVar "decls")))
(DTypeSig false "visitModF" (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))))))))
(DFunDef false "visitModF" ((PVar "parseFn") (PVar "read") (PVar "deps") (PVar "roots") (PVar "stack") (PVar "visited") (PVar "acc") (PVar "modId")) (EIf (EApp (EApp (EVar "contains") (EVar "modId")) (EVar "visited")) (EApp (EVar "Ok") (ETuple (EVar "visited") (EVar "acc"))) (EIf (EApp (EApp (EVar "contains") (EVar "modId")) (EVar "stack")) (EApp (EVar "Err") (EApp (EVar "LoadMsg") (EApp (EVar "stringConcat") (EListLit (ELit (LString "cyclic dependency: ")) (EApp (EVar "joinArrow") (EApp (EApp (EVar "cycleChain") (EVar "modId")) (EVar "stack"))))))) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "readModuleProgF") (EVar "parseFn")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EVar "modId")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "owningRoot") (PVar "path") (PVar "prog"))) () (EBlock (DoLet false false (PVar "croots") (EApp (EApp (EVar "childRoots") (EVar "owningRoot")) (EVar "roots"))) (DoLet false false (PVar "cdeps") (EApp (EApp (EApp (EVar "childDeps") (EVar "deps")) (EVar "owningRoot")) (EVar "roots"))) (DoLet false false (PVar "prog2") (EApp (EApp (EApp (EVar "rewriteDecls") (EVar "cdeps")) (EVar "croots")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "visited2") (PVar "acc2"))) (ETuple (EBinOp "::" (EVar "modId") (EVar "visited2")) (EBinOp "++" (EVar "acc2") (EListLit (ETuple (EVar "modId") (EVar "path") (EVar "prog2"))))))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModsF") (EVar "parseFn")) (EVar "read")) (EVar "cdeps")) (EVar "croots")) (EBinOp "::" (EVar "modId") (EVar "stack"))) (EVar "visited")) (EVar "acc")) (EApp (EVar "directImports") (EVar "prog2")))))))))))
(DTypeSig false "visitModsF" (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))))))))
(DFunDef false "visitModsF" (PWild PWild PWild PWild PWild (PVar "visited") (PVar "acc") (PList)) (EApp (EVar "Ok") (ETuple (EVar "visited") (EVar "acc"))))
(DFunDef false "visitModsF" ((PVar "parseFn") (PVar "read") (PVar "deps") (PVar "roots") (PVar "stack") (PVar "visited") (PVar "acc") (PCons (PVar "d") (PVar "ds"))) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModF") (EVar "parseFn")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EVar "stack")) (EVar "visited")) (EVar "acc")) (EVar "d")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "v2") (PVar "a2"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModsF") (EVar "parseFn")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EVar "stack")) (EVar "v2")) (EVar "a2")) (EVar "ds")))))
(DTypeSig true "loadProgramFilesE" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "loadProgramFilesE" ((PVar "read") (PVar "entry") (PVar "roots")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRoot") (EApp (EVar "parentDir") (EVar "entry"))))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple PWild (PVar "acc"))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModF") (EVar "parseResult")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EListLit)) (EListLit)) (EListLit)) (EApp (EApp (EVar "moduleIdOfPath") (EVar "roots")) (EVar "entry")))))))
(DTypeSig true "loadProgramFilesLocatedE" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "loadProgramFilesLocatedE" ((PVar "read") (PVar "entry") (PVar "roots")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRoot") (EApp (EVar "parentDir") (EVar "entry"))))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple PWild (PVar "acc"))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModF") (EVar "parseLocatedResult")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EListLit)) (EListLit)) (EListLit)) (EApp (EApp (EVar "moduleIdOfPath") (EVar "roots")) (EVar "entry")))))))
(DTypeSig false "parseCacheLimit" (TyCon "Int"))
(DFunDef false "parseCacheLimit" () (ELit (LInt 24)))
(DTypeSig false "parseCachedLocated" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "parseCachedLocated" ((PVar "cacheRef") (PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EFieldAccess (EVar "cacheRef") "value")) (arm (PCon "Some" (PVar "decls")) () (EApp (EVar "Ok") (EVar "decls"))) (arm (PCon "None") () (EMatch (EApp (EVar "parseLocatedResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "decls")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cacheRef")) (EApp (EApp (EVar "takeFirst") (EVar "parseCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EVar "decls")) (EApp (EApp (EVar "dropKey") (EVar "src")) (EFieldAccess (EVar "cacheRef") "value")))))) (DoExpr (EApp (EVar "Ok") (EVar "decls")))))))))
(DTypeSig false "dropKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "dropKey" (PWild (PList)) (EListLit))
(DFunDef false "dropKey" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "dropKey") (EVar "k")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v")) (EApp (EApp (EVar "dropKey") (EVar "k")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "takeFirst" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeFirst" (PWild (PList)) (EListLit))
(DFunDef false "takeFirst" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeFirst") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "loadProgramFilesLocatedCached" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "loadProgramFilesLocatedCached" ((PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots")) (EApp (EApp (EVar "mapErr") (EVar "loadErrorMessage")) (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCachedE") (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots"))))
(DTypeSig true "loadProgramFilesLocatedCachedE" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "loadProgramFilesLocatedCachedE" ((PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRoot") (EApp (EVar "parentDir") (EVar "entry"))))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple PWild (PVar "acc"))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModF") (ELam ((PVar "s")) (EApp (EApp (EVar "parseCachedLocated") (EVar "parseCacheRef")) (EVar "s")))) (EVar "read")) (EVar "deps")) (EVar "roots")) (EListLit)) (EListLit)) (EListLit)) (EApp (EApp (EVar "moduleIdOfPath") (EVar "roots")) (EVar "entry")))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DUse" false) (mem "DAttrib" false) (mem "UsePath" false) (mem "UseName" false) (mem "UseGroup" false) (mem "UseWild" false) (mem "UseAlias" false) (mem "Loc" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "parseResult" false) (mem "parseLocatedResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "reverseL" false) (mem "initList" false) (mem "startsWith" false) (mem "endsWith" false) (mem "joinDot" false) (mem "lookupAssoc" false) (mem "splitNl" false) (mem "stringTrim" false) (mem "sortUniqS" false))))
(DTypeSig false "lastOr" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyVar "a"))))
(DFunDef false "lastOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "lastOr" (PWild (PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOr" ((PVar "d") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "lastOr") (EVar "d")) (EVar "xs")))
(DTypeSig false "splitOnChar" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "splitOnChar" ((PVar "sep") (PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "sep")) (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LString ""))))
(DTypeSig false "splitGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitGo" ((PVar "sep") (PVar "s") (PVar "i") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EListLit (EVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EVar "sep")) (EBinOp "::" (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "sep")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "sep")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "++" (EVar "acc") (EVar "c"))))))))
(DTypeSig false "joinSlash" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSlash" ((PList)) (ELit (LString "")))
(DFunDef false "joinSlash" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinSlash" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString "/")) (EApp (EVar "joinSlash") (EVar "xs")))))
(DTypeSig false "slashToDot" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "slashToDot" ((PVar "s")) (EApp (EVar "joinDot") (EApp (EApp (EVar "splitOnChar") (ELit (LString "/"))) (EVar "s"))))
(DTypeSig false "dropPrefix" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dropPrefix" ((PVar "k") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "k")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig false "stripSuffixStr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripSuffixStr" ((PVar "suf") (PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (EVar "suf")) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "suf")))) (EVar "s")) (EVar "s")))
(DTypeSig false "fileOfModuleId" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "fileOfModuleId" ((PVar "root") (PVar "modId")) (EApp (EVar "stringConcat") (EListLit (EVar "root") (ELit (LString "/")) (EApp (EVar "joinSlash") (EApp (EApp (EVar "splitOnChar") (ELit (LString "."))) (EVar "modId"))) (ELit (LString ".mdk")))))
(DTypeSig false "relUnderRoots" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "relUnderRoots" ((PList) (PVar "path")) (EVar "path"))
(DFunDef false "relUnderRoots" ((PCons (PVar "r") (PVar "rs")) (PVar "path")) (EBlock (DoLet false false (PVar "pre") (EApp (EVar "stringConcat") (EListLit (EVar "r") (ELit (LString "/"))))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "pre")) (EVar "path")) (EApp (EApp (EVar "dropPrefix") (EApp (EVar "stringLength") (EVar "pre"))) (EVar "path")) (EApp (EApp (EVar "relUnderRoots") (EVar "rs")) (EVar "path"))))))
(DTypeSig false "moduleIdOfPath" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "moduleIdOfPath" ((PVar "roots") (PVar "path")) (EApp (EVar "slashToDot") (EApp (EApp (EVar "stripSuffixStr") (ELit (LString ".mdk"))) (EApp (EApp (EVar "relUnderRoots") (EVar "roots")) (EVar "path")))))
(DTypeSig true "findProjectRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "findProjectRoot" ((PVar "startDir")) (EApp (EApp (EVar "findRootGo") (EVar "startDir")) (EVar "startDir")))
(DTypeSig true "entrySearchRoots" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "entrySearchRoots" ((PVar "entryDir")) (EBlock (DoLet false false (PVar "projRoot") (EApp (EVar "findProjectRoot") (EVar "entryDir"))) (DoExpr (EIf (EBinOp "==" (EVar "projRoot") (EVar "entryDir")) (EListLit (EVar "projRoot")) (EListLit (EVar "entryDir") (EVar "projRoot"))))))
(DTypeSig false "findRootGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "findRootGo" ((PVar "cur") (PVar "fallback")) (EIf (EApp (EVar "fileExists") (EApp (EVar "stringConcat") (EListLit (EVar "cur") (ELit (LString "/medaka.toml"))))) (EVar "cur") (EBlock (DoLet false false (PVar "p") (EApp (EVar "parentDir") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "p") (EVar "cur")) (EBinOp "==" (EApp (EVar "stringLength") (EVar "p")) (ELit (LInt 0)))) (EVar "fallback") (EApp (EApp (EVar "findRootGo") (EVar "p")) (EVar "fallback")))))))
(DTypeSig false "parentDir" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parentDir" ((PVar "path")) (EApp (EApp (EVar "parentGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "parentGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "parentGo" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "parentGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "parentGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "unquote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unquote" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "\"")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "keyBeforeEq" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "keyBeforeEq" ((PVar "line")) (EApp (EApp (EApp (EVar "keyEqGo") (EVar "line")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "line"))))
(DTypeSig false "keyEqGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "keyEqGo" ((PVar "line") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (ELit (LString "="))) (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "line"))) (EApp (EApp (EApp (EVar "keyEqGo") (EVar "line")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "valAfterEq" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "valAfterEq" ((PVar "line")) (EApp (EApp (EApp (EVar "valEqGo") (EVar "line")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "line"))))
(DTypeSig false "valEqGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "valEqGo" ((PVar "line") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (ELit (LString "="))) (EApp (EVar "unquote") (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "line")))) (EApp (EApp (EApp (EVar "valEqGo") (EVar "line")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "collectDeps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "collectDeps" ((PVar "root") (PList)) (EListLit))
(DFunDef false "collectDeps" ((PVar "root") (PCons (PVar "line") (PVar "rest"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "stringTrim") (EVar "line"))) (DoExpr (EIf (EBinOp "==" (EVar "t") (ELit (LString "[dependencies]"))) (EApp (EApp (EVar "collectDepsIn") (EVar "root")) (EVar "rest")) (EApp (EApp (EVar "collectDeps") (EVar "root")) (EVar "rest"))))))
(DTypeSig false "collectDepsIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "collectDepsIn" ((PVar "root") (PList)) (EListLit))
(DFunDef false "collectDepsIn" ((PVar "root") (PCons (PVar "line") (PVar "rest"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "stringTrim") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "["))) (EVar "t")) (EApp (EApp (EVar "collectDeps") (EVar "root")) (EBinOp "::" (EVar "line") (EVar "rest"))) (EBlock (DoLet false false (PVar "k") (EApp (EVar "keyBeforeEq") (EVar "t"))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LString ""))) (EApp (EApp (EVar "collectDepsIn") (EVar "root")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EApp (EApp (EVar "joinPathL") (EVar "root")) (EApp (EVar "valAfterEq") (EVar "t")))) (EApp (EApp (EVar "collectDepsIn") (EVar "root")) (EVar "rest"))))))))))
(DTypeSig false "joinPathL" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPathL" ((PVar "root") (PVar "p")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "p")) (EVar "p") (EIf (EBinOp "==" (EVar "root") (ELit (LString ""))) (EVar "p") (EApp (EVar "stringConcat") (EListLit (EVar "root") (ELit (LString "/")) (EVar "p"))))))
(DTypeSig true "readDeps" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "readDeps" ((PVar "root")) (EBlock (DoLet false false (PVar "tomlPath") (EApp (EVar "stringConcat") (EListLit (EVar "root") (ELit (LString "/medaka.toml"))))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "tomlPath")) (EMatch (EApp (EVar "readFile") (EVar "tomlPath")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "collectDeps") (EVar "root")) (EApp (EVar "splitNl") (EVar "src"))))) (EListLit)))))
(DTypeSig false "resolveDepFile" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "resolveDepFile" ((PVar "deps") (PVar "modId")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LString "."))) (EVar "modId")) (arm (PList) () (EVar "None")) (arm (PCons (PVar "seg0") (PVar "restSegs")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "seg0")) (EVar "deps")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "depRoot")) () (EMatch (EVar "restSegs") (arm (PList) () (EVar "None")) (arm PWild () (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "fileOfModuleId") (EVar "depRoot")) (EApp (EVar "joinDot") (EVar "restSegs")))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "path")) (EApp (EVar "Some") (ETuple (EVar "path") (EVar "depRoot"))) (EVar "None")))))))))))
(DTypeSig true "importModId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "importModId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "lastOr") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "importModId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "importModId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "importModId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "directImports" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "directImports" ((PList)) (EListLit))
(DFunDef false "directImports" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "importModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "m") (ELit (LString "core"))) (EApp (EVar "directImports") (EVar "rest")) (EBinOp "::" (EVar "m") (EApp (EVar "directImports") (EVar "rest")))))))
(DFunDef false "directImports" ((PCons PWild (PVar "rest"))) (EApp (EVar "directImports") (EVar "rest")))
(DTypeSig true "unknownModuleIdOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unknownModuleIdOf" ((PVar "msg")) (EBlock (DoLet false false (PVar "prefix") (ELit (LString "unknown module: "))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "msg")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "msg"))) (EVar "msg"))) (EVar "None")))))
(DTypeSig true "findImportLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "findImportLoc" (PWild (PList)) (EVar "None"))
(DFunDef false "findImportLoc" ((PVar "mid") (PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "importModId") (EVar "path")) (EVar "mid")) (EApp (EVar "Some") (EVar "loc")) (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EVar "rest"))))
(DFunDef false "findImportLoc" ((PVar "mid") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findImportLoc" ((PVar "mid") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EVar "rest")))
(DTypeSig true "availableModuleIds" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "availableModuleIds" ((PVar "stdlibDir")) (EMatch (EApp (EVar "listDir") (EVar "stdlibDir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "filterMap") (EVar "mdkBaseName")) (EVar "entries"))))))
(DTypeSig false "mdkBaseName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "mdkBaseName" ((PVar "name")) (EIf (EBinOp "&&" (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "name")))) (EBlock (DoLet false false (PVar "base") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "name")) (ELit (LInt 4)))) (EVar "name"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "base") (ELit (LString "core"))) (EBinOp "==" (EVar "base") (ELit (LString "runtime")))) (EVar "None") (EApp (EVar "Some") (EVar "base"))))) (EVar "None")))
(DTypeSig true "availableModulesText" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "availableModulesText" ((PVar "stdlibDir")) (EMatch (EApp (EVar "availableModuleIds") (EVar "stdlibDir")) (arm (PList) () (ELit (LString ""))) (arm (PVar "ids") () (EApp (EVar "stringConcat") (EListLit (ELit (LString "available modules: ")) (EApp (EVar "joinComma") (EVar "ids")))))))
(DTypeSig true "availableModulesHint" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "availableModulesHint" ((PVar "stdlibDir")) (EMatch (EApp (EVar "availableModulesText") (EVar "stdlibDir")) (arm (PLit (LString "")) () (ELit (LString ""))) (arm (PVar "txt") () (EBinOp "++" (ELit (LString " — ")) (EVar "txt")))))
(DTypeSig false "joinComma" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinComma" ((PList)) (ELit (LString "")))
(DFunDef false "joinComma" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinComma" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString ", ")) (EApp (EVar "joinComma") (EVar "xs")))))
(DTypeSig false "findModuleFile" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "findModuleFile" ((PVar "deps") (PVar "roots") (PVar "modId")) (EMatch (EApp (EApp (EVar "resolveDepFile") (EVar "deps")) (EVar "modId")) (arm (PCon "Some" (PVar "pathRoot")) () (EApp (EVar "Some") (EVar "pathRoot"))) (arm (PCon "None") () (EApp (EApp (EVar "findInRoots") (EVar "roots")) (EVar "modId")))))
(DTypeSig false "findInRoots" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "findInRoots" ((PList) PWild) (EVar "None"))
(DFunDef false "findInRoots" ((PCons (PVar "r") (PVar "rs")) (PVar "modId")) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "fileOfModuleId") (EVar "r")) (EVar "modId"))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "path")) (EApp (EVar "Some") (ETuple (EVar "path") (EVar "r"))) (EApp (EApp (EVar "findInRoots") (EVar "rs")) (EVar "modId"))))))
(DData Public "LoadError" () ((variant "LoadMsg" (ConPos (TyCon "String"))) (variant "LoadParseFailed" (ConPos (TyCon "String") (TyCon "String") (TyCon "ParseError")))) ())
(DTypeSig true "loadErrorMessage" (TyFun (TyCon "LoadError") (TyCon "String")))
(DFunDef false "loadErrorMessage" ((PCon "LoadMsg" (PVar "m"))) (EVar "m"))
(DFunDef false "loadErrorMessage" ((PCon "LoadParseFailed" (PVar "path") PWild (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "parseErrorLine") (EVar "e")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "parseErrorCol") (EVar "e")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "parseErrorMessage") (EVar "e")))) (ELit (LString ""))))
(DTypeSig false "readModuleProgF" (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "readModuleProgF" ((PVar "parseFn") (PVar "read") (PVar "deps") (PVar "roots") (PVar "modId")) (EMatch (EApp (EApp (EApp (EVar "findModuleFile") (EVar "deps")) (EVar "roots")) (EVar "modId")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "LoadMsg") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unknown module: ")) (EVar "modId")))))) (arm (PCon "Some" (PTuple (PVar "path") (PVar "owningRoot"))) () (EMatch (EApp (EVar "read") (EVar "path")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EVar "parsedModule") (EVar "parseFn")) (EVar "owningRoot")) (EVar "path")) (EVar "src"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "LoadMsg") (EVar "e")))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EApp (EApp (EVar "parsedModule") (EVar "parseFn")) (EVar "owningRoot")) (EVar "path")) (EVar "src")))))))))
(DTypeSig false "parsedModule" (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "parsedModule" ((PVar "parseFn") (PVar "owningRoot") (PVar "path") (PVar "src")) (EMatch (EApp (EVar "parseFn") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "LoadParseFailed") (EVar "path")) (EVar "src")) (EVar "e")))) (arm (PCon "Ok" (PVar "prog")) () (EApp (EVar "Ok") (ETuple (EVar "owningRoot") (EVar "path") (EVar "prog"))))))
(DTypeSig false "splitDot" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitDot" ((PVar "s")) (EApp (EApp (EVar "splitOnChar") (ELit (LString "."))) (EVar "s")))
(DTypeSig false "revLookupRoot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "revLookupRoot" (PWild (PList)) (EVar "None"))
(DFunDef false "revLookupRoot" ((PVar "cr") (PCons (PTuple (PVar "n") (PVar "dr")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "canonicalizePath") (EVar "dr")) (EVar "cr")) (EApp (EVar "Some") (EVar "n")) (EApp (EApp (EVar "revLookupRoot") (EVar "cr")) (EVar "rest"))))
(DTypeSig false "canonicalModId" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "canonicalModId" ((PVar "deps") (PVar "roots") (PVar "m")) (EMatch (EApp (EApp (EApp (EVar "findModuleFile") (EVar "deps")) (EVar "roots")) (EVar "m")) (arm (PCon "None") () (EVar "m")) (arm (PCon "Some" (PTuple (PVar "path") (PVar "owningRoot"))) () (EBlock (DoLet false false (PVar "cOwn") (EApp (EVar "canonicalizePath") (EVar "owningRoot"))) (DoExpr (EMatch (EApp (EApp (EVar "revLookupRoot") (EVar "cOwn")) (EVar "deps")) (arm (PCon "None") () (EVar "m")) (arm (PCon "Some" (PVar "depName")) () (EApp (EVar "stringConcat") (EListLit (EVar "depName") (ELit (LString ".")) (EApp (EApp (EVar "moduleIdOfPath") (EListLit (EVar "cOwn"))) (EApp (EVar "canonicalizePath") (EVar "path"))))))))))))
(DTypeSig false "rewriteUsePath" (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyCon "UsePath"))))
(DFunDef false "rewriteUsePath" ((PVar "c") (PCon "UseName" (PVar "ns"))) (EApp (EVar "UseName") (EBinOp "++" (EApp (EVar "splitDot") (EVar "c")) (EListLit (EApp (EApp (EVar "lastOr") (ELit (LString ""))) (EVar "ns"))))))
(DFunDef false "rewriteUsePath" ((PVar "c") (PCon "UseGroup" PWild (PVar "ms"))) (EApp (EApp (EVar "UseGroup") (EApp (EVar "splitDot") (EVar "c"))) (EVar "ms")))
(DFunDef false "rewriteUsePath" ((PVar "c") (PCon "UseWild" PWild)) (EApp (EVar "UseWild") (EApp (EVar "splitDot") (EVar "c"))))
(DFunDef false "rewriteUsePath" ((PVar "c") (PCon "UseAlias" PWild (PVar "a"))) (EApp (EApp (EVar "UseAlias") (EApp (EVar "splitDot") (EVar "c"))) (EVar "a")))
(DTypeSig false "rewriteDecl" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyEffect ("IO") None (TyCon "Decl"))))))
(DFunDef false "rewriteDecl" ((PVar "deps") (PVar "roots") (PCon "DUse" (PVar "exported") (PVar "path") (PVar "loc"))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "importModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "m") (ELit (LString "core"))) (EApp (EApp (EApp (EVar "DUse") (EVar "exported")) (EVar "path")) (EVar "loc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "canonicalModId") (EVar "deps")) (EVar "roots")) (EVar "m"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EVar "m")) (EApp (EApp (EApp (EVar "DUse") (EVar "exported")) (EVar "path")) (EVar "loc")) (EApp (EApp (EApp (EVar "DUse") (EVar "exported")) (EApp (EApp (EVar "rewriteUsePath") (EVar "c")) (EVar "path"))) (EVar "loc")))))))))
(DFunDef false "rewriteDecl" (PWild PWild (PVar "d")) (EVar "d"))
(DTypeSig false "rewriteDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "rewriteDecls" (PWild PWild (PList)) (EListLit))
(DFunDef false "rewriteDecls" ((PVar "deps") (PVar "roots") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PVar "d2") (EApp (EApp (EApp (EVar "rewriteDecl") (EVar "deps")) (EVar "roots")) (EVar "d"))) (DoExpr (EBinOp "::" (EVar "d2") (EApp (EApp (EApp (EVar "rewriteDecls") (EVar "deps")) (EVar "roots")) (EVar "ds"))))))
(DTypeSig false "cycleChain" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "cycleChain" ((PVar "modId") (PVar "stack")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EVar "takeTo") (EVar "modId")) (EVar "stack"))) (EListLit (EVar "modId"))))
(DTypeSig false "takeTo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "takeTo" (PWild (PList)) (EListLit))
(DFunDef false "takeTo" ((PVar "target") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (EVar "target")) (EListLit (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeTo") (EVar "target")) (EVar "xs")))))
(DTypeSig false "joinArrow" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinArrow" ((PList)) (ELit (LString "")))
(DFunDef false "joinArrow" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinArrow" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString " → ")) (EApp (EVar "joinArrow") (EVar "xs")))))
(DTypeSig false "childRoots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "childRoots" ((PVar "owningRoot") (PVar "roots")) (EIf (EApp (EApp (EVar "contains") (EVar "owningRoot")) (EVar "roots")) (EVar "roots") (EBinOp "::" (EVar "owningRoot") (EVar "roots"))))
(DTypeSig false "childDeps" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "childDeps" ((PVar "deps") (PVar "owningRoot") (PVar "roots")) (EIf (EApp (EApp (EVar "contains") (EVar "owningRoot")) (EVar "roots")) (EVar "deps") (EBinOp "++" (EVar "deps") (EApp (EVar "readDeps") (EVar "owningRoot")))))
(DTypeSig true "projectTrustedMods" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "projectTrustedMods" ((PVar "entry") (PVar "roots") (PVar "stdlibRoot") (PVar "mods")) (EBlock (DoLet false false (PVar "projectRoot") (EApp (EVar "findProjectRoot") (EApp (EVar "parentDir") (EVar "entry")))) (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EVar "projectRoot"))) (DoLet false false (PVar "hasProject") (EApp (EVar "fileExists") (EApp (EVar "stringConcat") (EListLit (EVar "projectRoot") (ELit (LString "/medaka.toml")))))) (DoLet false false (PVar "trustedRoots") (EIf (EVar "hasProject") (EApp (EApp (EMethodRef "map") (EVar "canonicalizePath")) (EBinOp "::" (EVar "stdlibRoot") (EVar "roots"))) (EListLit (EApp (EVar "canonicalizePath") (EVar "stdlibRoot"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "trustedModsGo") (EVar "deps")) (EVar "roots")) (EVar "trustedRoots")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "mods"))))))
(DTypeSig false "trustedModsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "trustedModsGo" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "trustedModsGo" ((PVar "deps") (PVar "roots") (PVar "trustedRoots") (PCons (PVar "m") (PVar "ms"))) (EMatch (EApp (EApp (EApp (EVar "findModuleFile") (EVar "deps")) (EVar "roots")) (EVar "m")) (arm (PCon "Some" (PTuple PWild (PVar "owningRoot"))) () (EIf (EApp (EApp (EVar "contains") (EApp (EVar "canonicalizePath") (EVar "owningRoot"))) (EVar "trustedRoots")) (EBinOp "::" (EVar "m") (EApp (EApp (EApp (EApp (EVar "trustedModsGo") (EVar "deps")) (EVar "roots")) (EVar "trustedRoots")) (EVar "ms"))) (EApp (EApp (EApp (EApp (EVar "trustedModsGo") (EVar "deps")) (EVar "roots")) (EVar "trustedRoots")) (EVar "ms")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "trustedModsGo") (EVar "deps")) (EVar "roots")) (EVar "trustedRoots")) (EVar "ms")))))
(DTypeSig true "loadProgram" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "loadProgram" ((PVar "entry") (PVar "roots")) (EApp (EApp (EVar "mapErr") (EVar "loadErrorMessage")) (EApp (EApp (EVar "loadProgramE") (EVar "entry")) (EVar "roots"))))
(DTypeSig true "loadProgramE" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "loadProgramE" ((PVar "entry") (PVar "roots")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "mods")) (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "mods")))) (EApp (EApp (EApp (EVar "loadProgramFilesE") (ELam (PWild) (EVar "None"))) (EVar "entry")) (EVar "roots"))))
(DTypeSig false "dropPathTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropPathTriple" ((PTuple (PVar "mid") PWild (PVar "decls"))) (ETuple (EVar "mid") (EVar "decls")))
(DTypeSig false "visitModF" (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))))))))
(DFunDef false "visitModF" ((PVar "parseFn") (PVar "read") (PVar "deps") (PVar "roots") (PVar "stack") (PVar "visited") (PVar "acc") (PVar "modId")) (EIf (EApp (EApp (EVar "contains") (EVar "modId")) (EVar "visited")) (EApp (EVar "Ok") (ETuple (EVar "visited") (EVar "acc"))) (EIf (EApp (EApp (EVar "contains") (EVar "modId")) (EVar "stack")) (EApp (EVar "Err") (EApp (EVar "LoadMsg") (EApp (EVar "stringConcat") (EListLit (ELit (LString "cyclic dependency: ")) (EApp (EVar "joinArrow") (EApp (EApp (EVar "cycleChain") (EVar "modId")) (EVar "stack"))))))) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "readModuleProgF") (EVar "parseFn")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EVar "modId")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "owningRoot") (PVar "path") (PVar "prog"))) () (EBlock (DoLet false false (PVar "croots") (EApp (EApp (EVar "childRoots") (EVar "owningRoot")) (EVar "roots"))) (DoLet false false (PVar "cdeps") (EApp (EApp (EApp (EVar "childDeps") (EVar "deps")) (EVar "owningRoot")) (EVar "roots"))) (DoLet false false (PVar "prog2") (EApp (EApp (EApp (EVar "rewriteDecls") (EVar "cdeps")) (EVar "croots")) (EVar "prog"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "visited2") (PVar "acc2"))) (ETuple (EBinOp "::" (EVar "modId") (EVar "visited2")) (EBinOp "++" (EVar "acc2") (EListLit (ETuple (EVar "modId") (EVar "path") (EVar "prog2"))))))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModsF") (EVar "parseFn")) (EVar "read")) (EVar "cdeps")) (EVar "croots")) (EBinOp "::" (EVar "modId") (EVar "stack"))) (EVar "visited")) (EVar "acc")) (EApp (EVar "directImports") (EVar "prog2")))))))))))
(DTypeSig false "visitModsF" (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))))))))
(DFunDef false "visitModsF" (PWild PWild PWild PWild PWild (PVar "visited") (PVar "acc") (PList)) (EApp (EVar "Ok") (ETuple (EVar "visited") (EVar "acc"))))
(DFunDef false "visitModsF" ((PVar "parseFn") (PVar "read") (PVar "deps") (PVar "roots") (PVar "stack") (PVar "visited") (PVar "acc") (PCons (PVar "d") (PVar "ds"))) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModF") (EVar "parseFn")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EVar "stack")) (EVar "visited")) (EVar "acc")) (EVar "d")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "v2") (PVar "a2"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModsF") (EVar "parseFn")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EVar "stack")) (EVar "v2")) (EVar "a2")) (EVar "ds")))))
(DTypeSig true "loadProgramFilesE" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "loadProgramFilesE" ((PVar "read") (PVar "entry") (PVar "roots")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRoot") (EApp (EVar "parentDir") (EVar "entry"))))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild (PVar "acc"))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModF") (EVar "parseResult")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EListLit)) (EListLit)) (EListLit)) (EApp (EApp (EVar "moduleIdOfPath") (EVar "roots")) (EVar "entry")))))))
(DTypeSig true "loadProgramFilesLocatedE" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "loadProgramFilesLocatedE" ((PVar "read") (PVar "entry") (PVar "roots")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRoot") (EApp (EVar "parentDir") (EVar "entry"))))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild (PVar "acc"))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModF") (EVar "parseLocatedResult")) (EVar "read")) (EVar "deps")) (EVar "roots")) (EListLit)) (EListLit)) (EListLit)) (EApp (EApp (EVar "moduleIdOfPath") (EVar "roots")) (EVar "entry")))))))
(DTypeSig false "parseCacheLimit" (TyCon "Int"))
(DFunDef false "parseCacheLimit" () (ELit (LInt 24)))
(DTypeSig false "parseCachedLocated" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "parseCachedLocated" ((PVar "cacheRef") (PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EFieldAccess (EVar "cacheRef") "value")) (arm (PCon "Some" (PVar "decls")) () (EApp (EVar "Ok") (EVar "decls"))) (arm (PCon "None") () (EMatch (EApp (EVar "parseLocatedResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "decls")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cacheRef")) (EApp (EApp (EVar "takeFirst") (EVar "parseCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EVar "decls")) (EApp (EApp (EVar "dropKey") (EVar "src")) (EFieldAccess (EVar "cacheRef") "value")))))) (DoExpr (EApp (EVar "Ok") (EVar "decls")))))))))
(DTypeSig false "dropKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "dropKey" (PWild (PList)) (EListLit))
(DFunDef false "dropKey" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "dropKey") (EVar "k")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v")) (EApp (EApp (EVar "dropKey") (EVar "k")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "takeFirst" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeFirst" (PWild (PList)) (EListLit))
(DFunDef false "takeFirst" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeFirst") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "loadProgramFilesLocatedCached" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "loadProgramFilesLocatedCached" ((PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots")) (EApp (EApp (EVar "mapErr") (EVar "loadErrorMessage")) (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCachedE") (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots"))))
(DTypeSig true "loadProgramFilesLocatedCachedE" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "loadProgramFilesLocatedCachedE" ((PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRoot") (EApp (EVar "parentDir") (EVar "entry"))))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild (PVar "acc"))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "visitModF") (ELam ((PVar "s")) (EApp (EApp (EVar "parseCachedLocated") (EVar "parseCacheRef")) (EVar "s")))) (EVar "read")) (EVar "deps")) (EVar "roots")) (EListLit)) (EListLit)) (EListLit)) (EApp (EApp (EVar "moduleIdOfPath") (EVar "roots")) (EVar "entry")))))))
