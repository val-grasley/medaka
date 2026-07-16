# META
source_lines=438
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_cache.mdk — the on-disk cache behind `medaka lint --cache` (#395).
--
-- WHY.  The pre-commit hook runs `medaka lint compiler stdlib sqlite` on every
-- commit: ~6.8 s, parse-bound.  A typical commit touches 1–2 files, so ~99% of
-- that work re-lints files that did not change.  This module lets a run skip the
-- parse + rule pass for a file whose CONTENT is unchanged.
--
-- ── THE INVARIANT (hold every change in this file to it) ──────────────────────
--   A MISS IS ALWAYS SAFE.  A WRONG HIT IS SILENT WRONGNESS.
-- Every ambiguity — unreadable shard, malformed JSON, unknown format version, a
-- foreign rule-set stamp, a path/hash mismatch, a field of the wrong shape —
-- resolves to `None` (a miss: re-lint the file).  There is no "probably fine"
-- branch and there must never be one.  A miss costs milliseconds; a wrong hit is
-- a lint that reports nothing and exits 0, which is this repo's defining failure
-- mode ("this didn't run" == "this passed").
--
-- ── WHAT IS CACHED, AND THE ONE THING THAT MUST NOT BE ───────────────────────
-- Per file, keyed by content hash: its `findings`, its `dupOccs`, its
-- `directives`.
--
-- `dupOccs` is the per-file INPUT to the cross-file duplicate-body join, and
-- caching it (rather than the join's OUTPUT) is not an optimisation detail — it
-- is the correctness argument.  A duplicate-body finding names file A *because
-- of* file B.  Cache A's findings and B's edit cannot retract them: A is
-- unchanged, so A cache-hits, and A's stale finding survives.  So the join is
-- re-run from scratch on every run (`lint.dupJoin`), from occurrences that are
-- pure functions of one file each.  This is affordable because of where the cost
-- sits: the parse + `structuralKey` is expensive, per-file and cacheable, while
-- the join measures LINEAR at occs≈10k.  Scenario 3 of
-- test/diff_compiler_lint_cache.sh fails loudly if anyone "optimises" this away.
--
-- ── SHARDS, NOT A BLOB ───────────────────────────────────────────────────────
-- One JSON file per source file, not one cache file.  Measured (#395, this
-- corpus): parsing the whole 5 MB cache costs 0.27 s against the ~6.5 s of
-- parsing it skips, but STRINGIFYING 5 MB costs 0.44–0.58 s — and every commit
-- changes ≥1 file, so a monolithic cache pays that write EVERY run.  Sharding
-- makes the write O(changed) (~25 KB, ~3 ms) while the read is unchanged (the
-- join needs every file's occurrences either way).  That is what takes the warm
-- run to ~0.35 s (~19x) and is why exact `structuralKey`s stay exact: hashing
-- them would only ever have solved a size problem that was really a write
-- problem, at the price of a ~1e-13 false-duplicate report.
--
-- Flags are deliberately NOT part of the key: `--only`/`--disable`/`--deny` are
-- pure post-filters (`applyFindingFilters`), so shards store PRE-filter findings
-- and every flag combination shares one cache.

import frontend.ast.{Loc(..)}
import driver.diagnostics.{Severity(..)}
import tools.lint.{Finding(..), Directive(..), DirScope(..)}
import support.util.{joinWith, listLen, filterList, splitOnChar, stringTrim}
import support.char.{isAlnum}
import json.{
  Json(..),
  jArray,
  jObject,
  stringify,
  parse,
  lookup,
  asString,
  asInt,
  asArray,
  at,
}

-- ── the cached unit ──────────────────────────────────────────────────────────

-- Everything a run needs about ONE file, whether freshly linted or loaded from a
-- shard.  `dirty = True` means it was computed this run and its shard needs
-- (re)writing; a cache hit is clean and writes nothing.
public export data LintEntry =
  | LintEntry {
      path : String,
      contentHash : String,
      findings : List Finding,
      dupOccs : List (String, Int, String, String),
      directives : List Directive,
      dirty : Bool,
    }

-- Bump when the shard schema changes in any way that would make an OLD shard
-- decode into something WRONG rather than fail to decode.  A version mismatch is
-- a miss, so bumping is always safe and never needs a cache purge.
cacheFormatVersion : Int
cacheFormatVersion = 1

-- ── content hashing ──────────────────────────────────────────────────────────
-- The key on which a hit is decided.  `hashString` is FNV-1a but the extern
-- MASKS its result to 30 bits (mdk_hash_string, MDK_HASH_MASK), and 30 bits is
-- too thin to bet correctness on: a ~1e-9 collision between two versions of one
-- file is a STALE HIT, i.e. the exact silent wrongness this cache must not
-- manufacture.  So the key is two independent 30-bit projections plus the byte
-- length — the second lane hashes the source minus its first character, which
-- gives FNV a different starting state and so an unrelated projection.
--
-- Measured on the real corpus (206 files, 4.6 MB): 1 lane = 12.4 ms, 2 lanes =
-- 24 ms.  ~12 ms on a ~350 ms warm run to take the collision odds from ~1e-9 to
-- ~1e-18.  Bought.
export contentHashOf : String -> String
contentHashOf src =
  let n = stringLength src
  let lane2 = if n == 0 then 0 else hashString (stringSlice 1 n src)
  "\{hashString src}.\{lane2}.\{n}"

-- ── the rule-set stamp ───────────────────────────────────────────────────────
-- Editing a rule's LOGIC (its name unchanged) must invalidate every entry, so
-- the key covers the rule set's identity as well as the file's content.  We hash
-- THE RUNNING BINARY.  Rejected alternatives, all silent-green (#395):
--   * `medaka --version` — a release string; does not move when a rule changes.
--   * a hand-bumped `lintRulesVersion` — rots the first time someone forgets.
--   * a hash of `allRules` names/severities — catches added/removed rules and
--     MISSES logic changes, i.e. exactly the dangerous half.
-- Hashing the binary is also strictly more conservative than a
-- `compiler/**/*.mdk` source stamp: it catches runtime/medaka_rt.c and clang
-- changes too.  Consequence, CORRECT not a bug: for compiler devs the cache dies
-- on every `make medaka`; for a user on a released binary it is stable.
--
-- ⚠️ `readFileBytes`, never `readFile`.  `readFile` UTF-8-DECODES, silently
-- dropping ~11% of a binary's bytes while returning `Ok` (#407).  Hashing a
-- lossy projection of the binary would be unsound in precisely the way this
-- fingerprint exists to prevent.
--
-- Kept behind this ONE function so it stays swappable.
--
-- Cost, MEASURED on the real 3.37 MB binary: ~10 ms readFileBytes + ~15 ms hash
-- = ~25 ms, paid once per run.  (#395 records 5.7–6.1 ms; that figure does not
-- reproduce — measure before quoting it.)  ~7% of a ~350 ms warm run.
export ruleSetStamp : Unit -> <IO> String
ruleSetStamp _ = match readFileBytes (executablePath ())
  Err _ => ""
  Ok bs => "\{fnv62 bs (arrayLength bs) 0 fnv62Offset}"

-- FNV-1a widened to Medaka's full Int range instead of `hashString`'s 30 bits —
-- same single pass, same measured cost (~15 ms on 3.37 MB), 62 bits instead of
-- 30.  `*` wraps at 63 bits by design (Int wraps; RNG/hashing rely on it), and
-- the mask keeps the accumulator non-negative so it renders as a stable decimal.
fnv62Mask : Int
fnv62Mask = 4611686018427387903

-- The FNV-1a 64-bit offset basis (14695981039346656037) reduced mod 2^62 — the
-- literal itself exceeds Int's max magnitude and will not lex.
fnv62Offset : Int
fnv62Offset = 860922984064492325

fnv62Prime : Int
fnv62Prime = 1099511628211

fnv62 : Array Int -> Int -> Int -> Int -> Int
fnv62 bs n i acc
  | i >= n = acc
  | otherwise = fnv62 bs n (i + 1) (bitAnd fnv62Mask (bitXor acc (arrayGetUnsafe i bs) * fnv62Prime))

-- ── shard paths ──────────────────────────────────────────────────────────────

-- The cache lives next to the project's `medaka.toml` (the caller resolves that
-- root) and is gitignored.
export cacheDirOf : String -> String
cacheDirOf root = "\{root}/.medaka/lint-cache"

-- A source path → its shard filename.  Flattened (the cache dir is flat) and
-- disambiguated by a hash of the FULL path, since sanitising alone would collide
-- `a/b.mdk` with `a_b.mdk`.  The hash is only a filename disambiguator, never a
-- correctness argument: the full path is stored INSIDE the shard and checked on
-- load, so a collision costs both files a permanent miss, never a wrong hit.
export shardPathOf : String -> String -> String
shardPathOf cacheDir srcPath =
  "\{cacheDir}/\{sanitizePath srcPath}-\{hashString srcPath}.json"

-- Map a path to [A-Za-z0-9._-]*, keeping the tail (the basename end is the
-- legible part) so shard names stay recognisable when eyeballing the dir.
sanitizePath : String -> String
sanitizePath p =
  let cs = stringToChars p
  let n = arrayLength cs
  let start = if n > 60 then n - 60 else 0
  stringFromChars (arrayFromList (sanitizeGo cs start n))

sanitizeGo : Array Char -> Int -> Int -> List Char
sanitizeGo cs i n
  | i >= n = []
  | otherwise = sanitizeChar (arrayGetUnsafe i cs) :: sanitizeGo cs (i + 1) n

sanitizeChar : Char -> Char
sanitizeChar c
  | isAlnum c || c == '.' || c == '_' || c == '-' = c
  | otherwise = '_'

-- ── encode ───────────────────────────────────────────────────────────────────

export encodeEntry : String -> LintEntry -> String
encodeEntry stamp e = stringify (jObject
  [
    ("version", JInt cacheFormatVersion),
    ("stamp", JString stamp),
    ("path", JString e.path),
    ("hash", JString e.contentHash),
    ("findings", jArray (map encFinding e.findings)),
    ("dupOccs", jArray (map encOcc e.dupOccs)),
    ("directives", jArray (map encDirective e.directives)),
  ])

encFinding : Finding -> Json
encFinding f = jObject
  [
    ("rule", JString f.rule),
    ("message", JString f.message),
    ("severity", JString (encSeverity f.severity)),
    ("loc", encLoc f.loc),
  ]

encSeverity : Severity -> String
encSeverity SevError = "error"
encSeverity SevWarning = "warning"

encLoc : Option Loc -> Json
encLoc None = JNull
encLoc (Some (Loc file l c el ec)) =
  jArray [JString file, JInt l, JInt c, JInt el, JInt ec]

-- The occurrence's file is always this shard's own file, so it is not stored;
-- `decOcc` re-stamps it from the (verified) `path` field.  One less field that
-- could disagree with itself on load.
encOcc : (String, Int, String, String) -> Json
encOcc (_, line, name, key) = jArray [JInt line, JString name, JString key]

encDirective : Directive -> Json
encDirective (Directive scope names) = jObject
  [("scope", encScope scope), ("rules", jArray (map (n => JString n) names))]

encScope : DirScope -> Json
encScope DScopeFile = JString "file"
encScope (DScopeLine l) = JInt l

-- ── decode ───────────────────────────────────────────────────────────────────
-- Every step is an `Option` and every failure is `None` (a miss).  This is the
-- half of the module the invariant is really about: `decodeEntry` is handed
-- whatever bytes are on disk, which may be a shard from a different compiler, a
-- half-written file, or something an editor mangled.

-- `path` and `hash` are checked against what the CALLER observed on disk, so a
-- shard can only ever answer for the exact file+content it was written from.
export decodeEntry : String -> String -> String -> String -> Option LintEntry
decodeEntry stamp path hash text = match parse text
  Err _ => None
  Ok j =>
    if decInt "version" j != Some cacheFormatVersion || decStr "stamp" j != Some stamp || decStr "path" j != Some path || decStr "hash" j != Some hash then
      None
    else
      map3 (fs ds dirs => LintEntry {
        path = path,
        contentHash = hash,
        findings = fs,
        dupOccs = ds,
        directives = dirs,
        dirty = False,
      }) (decList decFinding (lookup "findings" j)) (decList (decOcc path) (lookup "dupOccs" j)) (decList decDirective (lookup "directives" j))

decStr : String -> Json -> Option String
decStr k j = optBind (lookup k j) asString

decInt : String -> Json -> Option Int
decInt k j = optBind (lookup k j) asInt

-- A JArray of decodable elements → a List, all-or-nothing: one bad element
-- fails the whole shard rather than silently yielding a SHORTER list, which
-- would be a hit that quietly lost findings.
decList : (Json -> Option a) -> Option Json -> Option (List a)
decList f (Some j) =
  optBind (asArray j) (arr => decListGo f arr 0 (arrayLength arr))
decList _ None = None

decListGo : (Json -> Option a) -> Array Json -> Int -> Int -> Option (List a)
decListGo f arr i n
  | i >= n = Some []
  | otherwise = map2 (::) (f (arrayGetUnsafe i arr)) (decListGo f arr (i + 1) n)

decFinding : Json -> Option Finding
decFinding j = map4
  (r m s l => Finding { rule = r, message = m, severity = s, loc = l })
  (decStr "rule" j)
  (decStr "message" j)
  (optBind (decStr "severity" j) decSeverity)
  (decLoc (lookup "loc" j))

decSeverity : String -> Option Severity
decSeverity "error" = Some SevError
decSeverity "warning" = Some SevWarning
decSeverity _ = None

-- `loc` is `null` (no location) or a 5-element array.  A MISSING key is None
-- (malformed → miss), which is why the null case is matched explicitly rather
-- than folded in with it.
decLoc : Option Json -> Option (Option Loc)
decLoc (Some JNull) = Some None
decLoc (Some j) = map
  (l => Some l)
  (map5
    (f a b c d => Loc f a b c d)
    (optBind (at 0 j) asString)
    (optBind (at 1 j) asInt)
    (optBind (at 2 j) asInt)
    (optBind (at 3 j) asInt)
    (optBind (at 4 j) asInt))
decLoc None = None

decOcc : String -> Json -> Option (String, Int, String, String)
decOcc path j = map3
  (line name key => (path, line, name, key))
  (optBind (at 0 j) asInt)
  (optBind (at 1 j) asString)
  (optBind (at 2 j) asString)

decDirective : Json -> Option Directive
decDirective j = map2
  (scope names => Directive scope names)
  (optBind (lookup "scope" j) decScope)
  (decList asString (lookup "rules" j))

decScope : Json -> Option DirScope
decScope (JString "file") = Some DScopeFile
decScope (JInt l) = Some (DScopeLine l)
decScope _ = None

-- ── Option combinators ───────────────────────────────────────────────────────
-- Local and monomorphic: the prelude's Applicative surface would dict-pass, and
-- this is the hot decode path.  (util.mdk has no map2..map5.)

optBind : Option a -> (a -> Option b) -> Option b
optBind (Some a) f = f a
optBind None _ = None

map2 : (a -> b -> c) -> Option a -> Option b -> Option c
map2 f (Some a) (Some b) = Some (f a b)
map2 _ _ _ = None

map3 : (a -> b -> c -> d) -> Option a -> Option b -> Option c -> Option d
map3 f (Some a) (Some b) (Some c) = Some (f a b c)
map3 _ _ _ _ = None

map4 : (a -> b -> c -> d -> e) -> Option a -> Option b -> Option c -> Option d -> Option e
map4 f (Some a) (Some b) (Some c) (Some d) = Some (f a b c d)
map4 _ _ _ _ _ = None

map5 : (a -> b -> c -> d -> e -> f) -> Option a -> Option b -> Option c -> Option d -> Option e -> Option f
map5 f (Some a) (Some b) (Some c) (Some d) (Some e) = Some (f a b c d e)
map5 _ _ _ _ _ _ = None

-- ── load ─────────────────────────────────────────────────────────────────────

-- Try to answer for `path` at content `hash`.  `None` on any doubt whatsoever.
export loadEntry : String -> String -> String -> String -> <IO> Option LintEntry
loadEntry cacheDir stamp path hash = match readFile (shardPathOf cacheDir path)
  Err _ => None
  Ok text => decodeEntry stamp path hash text

-- ── store ────────────────────────────────────────────────────────────────────

-- Write every dirty entry's shard.  Best-effort THROUGHOUT: a cache that cannot
-- be written must never fail a lint, so every IO error here is swallowed and the
-- run reports its findings regardless (the next run simply misses).
--
-- ⚠️ ATOMICITY.  Each shard is staged in a per-process temp dir and `rename`d
-- into place — a reader therefore sees a shard whole or not at all, never
-- half-written, no matter how many `medaka lint --cache` runs are in flight.
-- Two traps this shape avoids:
--   * A FIXED temp name would let concurrent runs clobber each other's staging
--     and rename a torn file into place.  `medaka build` shipped exactly that
--     bug — its IR path was keyed on the output basename in global /tmp, so two
--     concurrent builds produced a stable-looking WRONG binary (19/20 runs).
--     Only a per-PROCESS temp dir is correct, and `randomInt` cannot supply one:
--     the RNG is seeded identically per process BY DESIGN, so two concurrent
--     runs would draw the SAME "random" name.  `mktemp -d` is the repo's proven
--     answer (build_cmd.mdk uses it for the same reason).
--   * The temp dir must live INSIDE the cache dir, not /tmp: rename(2) fails
--     with EXDEV across filesystems, and /tmp here is a RAM-backed tmpfs.
export storeEntries : String -> String -> List LintEntry -> <IO> Unit
storeEntries cacheDir stamp entries =
  let dirty = filterList entryDirty entries
  if listLen dirty == 0 then ()
  else match ensureCacheDir cacheDir
    Err _ => ()
    Ok _ => match makeStagingDir cacheDir
      Err _ => ()
      Ok tmp =>
        let _ = storeGo cacheDir tmp stamp dirty
        let _ = removeDir tmp
        ()

entryDirty : LintEntry -> Bool
entryDirty e = e.dirty

storeGo : String -> String -> String -> List LintEntry -> <IO> Unit
storeGo _ _ _ [] = ()
storeGo cacheDir tmp stamp (e::rest) =
  let _ = storeOne cacheDir tmp stamp e
  storeGo cacheDir tmp stamp rest

-- Stage under the temp dir, then rename ONTO the shard path (same filesystem —
-- the temp dir is inside the cache dir).  A failed write leaves the staged file
-- behind; the staging dir is removed by `storeEntries` only if empty, so a
-- failure leaks one temp dir rather than a corrupt shard.  That trade is
-- deliberate: the invariant is about never being WRONG, not never leaking.
storeOne : String -> String -> String -> LintEntry -> <IO> Unit
storeOne cacheDir tmp stamp e =
  let staged = "\{tmp}/shard.json"
  match writeFile staged (encodeEntry stamp e)
    Err _ => ()
    Ok _ => match rename staged (shardPathOf cacheDir e.path)
      Err _ =>
        let _ = removeFile staged
        ()
      Ok _ => ()

-- `mkdir -p` for the two-level cache dir (`<root>/.medaka/lint-cache`).  An
-- already-existing dir makes `makeDir` fail (EEXIST), which is success here, so
-- the result is judged by `fileExists`, not by makeDir's own status.
ensureCacheDir : String -> <IO> Result String Unit
ensureCacheDir cacheDir =
  let _ = makeDir (parentOfCacheDir cacheDir)
  let _ = makeDir cacheDir
  if fileExists cacheDir then Ok () else Err "cannot create \{cacheDir}"

parentOfCacheDir : String -> String
parentOfCacheDir cacheDir =
  joinWith "/" (dropLastSeg (splitOnChar '/' cacheDir))

dropLastSeg : List String -> List String
dropLastSeg [] = []
dropLastSeg [_] = []
dropLastSeg (x::rest) = x :: dropLastSeg rest

-- A staging dir unique to THIS process, inside the cache dir (see storeEntries).
makeStagingDir : String -> <IO> Result String String
makeStagingDir cacheDir = match runCommand "mktemp" ["-d", "\{cacheDir}/.staging_XXXXXX"]
  Err msg => Err (if msg == "" then "mktemp -d failed" else msg)
  Ok (code, out, err) => if code != 0 then Err (if err == "" then "mktemp -d failed" else err)
  else
    let dir = stringTrim out
    if dir == "" then Err "mktemp -d printed no path" else Ok dir
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint") ((mem "Finding" true) (mem "Directive" true) (mem "DirScope" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "filterList" false) (mem "splitOnChar" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false) (mem "at" false))))
(DData Public "LintEntry" () ((variant "LintEntry" (ConNamed (field "path" (TyCon "String")) (field "contentHash" (TyCon "String")) (field "findings" (TyApp (TyCon "List") (TyCon "Finding"))) (field "dupOccs" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))) (field "directives" (TyApp (TyCon "List") (TyCon "Directive"))) (field "dirty" (TyCon "Bool"))))) ())
(DTypeSig false "cacheFormatVersion" (TyCon "Int"))
(DFunDef false "cacheFormatVersion" () (ELit (LInt 1)))
(DTypeSig true "contentHashOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "contentHashOf" ((PVar "src")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "src"))) (DoLet false false (PVar "lane2") (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "hashString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "n")) (EVar "src"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "hashString") (EVar "src")))) (ELit (LString "."))) (EApp (EVar "display") (EVar "lane2"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))))
(DTypeSig true "ruleSetStamp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "ruleSetStamp" (PWild) (EMatch (EApp (EVar "readFileBytes") (EApp (EVar "executablePath") (ELit LUnit))) (arm (PCon "Err" PWild) () (ELit (LString ""))) (arm (PCon "Ok" (PVar "bs")) () (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "fnv62") (EVar "bs")) (EApp (EVar "arrayLength") (EVar "bs"))) (ELit (LInt 0))) (EVar "fnv62Offset")))) (ELit (LString ""))))))
(DTypeSig false "fnv62Mask" (TyCon "Int"))
(DFunDef false "fnv62Mask" () (ELit (LInt 4611686018427387903)))
(DTypeSig false "fnv62Offset" (TyCon "Int"))
(DFunDef false "fnv62Offset" () (ELit (LInt 860922984064492325)))
(DTypeSig false "fnv62Prime" (TyCon "Int"))
(DFunDef false "fnv62Prime" () (ELit (LInt 1099511628211)))
(DTypeSig false "fnv62" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "fnv62" ((PVar "bs") (PVar "n") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "fnv62") (EVar "bs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EVar "bitAnd") (EVar "fnv62Mask")) (EBinOp "*" (EApp (EApp (EVar "bitXor") (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bs"))) (EVar "fnv62Prime")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "cacheDirOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "cacheDirOf" ((PVar "root")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/.medaka/lint-cache"))))
(DTypeSig true "shardPathOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "shardPathOf" ((PVar "cacheDir") (PVar "srcPath")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "cacheDir"))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "sanitizePath") (EVar "srcPath")))) (ELit (LString "-"))) (EApp (EVar "display") (EApp (EVar "hashString") (EVar "srcPath")))) (ELit (LString ".json"))))
(DTypeSig false "sanitizePath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sanitizePath" ((PVar "p")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "p"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "start") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 60))) (EBinOp "-" (EVar "n") (ELit (LInt 60))) (ELit (LInt 0)))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "cs")) (EVar "start")) (EVar "n")))))))
(DTypeSig false "sanitizeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sanitizeGo" ((PVar "cs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "sanitizeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sanitizeChar" (TyFun (TyCon "Char") (TyCon "Char")))
(DFunDef false "sanitizeChar" ((PVar "c")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar ".")))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EBinOp "==" (EVar "c") (ELit (LChar "-")))) (EVar "c") (EIf (EVar "otherwise") (ELit (LChar "_")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encodeEntry" (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyCon "String"))))
(DFunDef false "encodeEntry" ((PVar "stamp") (PVar "e")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "version")) (EApp (EVar "JInt") (EVar "cacheFormatVersion"))) (ETuple (ELit (LString "stamp")) (EApp (EVar "JString") (EVar "stamp"))) (ETuple (ELit (LString "path")) (EApp (EVar "JString") (EFieldAccess (EVar "e") "path"))) (ETuple (ELit (LString "hash")) (EApp (EVar "JString") (EFieldAccess (EVar "e") "contentHash"))) (ETuple (ELit (LString "findings")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "encFinding")) (EFieldAccess (EVar "e") "findings")))) (ETuple (ELit (LString "dupOccs")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "encOcc")) (EFieldAccess (EVar "e") "dupOccs")))) (ETuple (ELit (LString "directives")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "encDirective")) (EFieldAccess (EVar "e") "directives"))))))))
(DTypeSig false "encFinding" (TyFun (TyCon "Finding") (TyCon "Json")))
(DFunDef false "encFinding" ((PVar "f")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "rule")) (EApp (EVar "JString") (EFieldAccess (EVar "f") "rule"))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EFieldAccess (EVar "f") "message"))) (ETuple (ELit (LString "severity")) (EApp (EVar "JString") (EApp (EVar "encSeverity") (EFieldAccess (EVar "f") "severity")))) (ETuple (ELit (LString "loc")) (EApp (EVar "encLoc") (EFieldAccess (EVar "f") "loc"))))))
(DTypeSig false "encSeverity" (TyFun (TyCon "Severity") (TyCon "String")))
(DFunDef false "encSeverity" ((PCon "SevError")) (ELit (LString "error")))
(DFunDef false "encSeverity" ((PCon "SevWarning")) (ELit (LString "warning")))
(DTypeSig false "encLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json")))
(DFunDef false "encLoc" ((PCon "None")) (EVar "JNull"))
(DFunDef false "encLoc" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "l") (PVar "c") (PVar "el") (PVar "ec")))) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (EVar "file")) (EApp (EVar "JInt") (EVar "l")) (EApp (EVar "JInt") (EVar "c")) (EApp (EVar "JInt") (EVar "el")) (EApp (EVar "JInt") (EVar "ec")))))
(DTypeSig false "encOcc" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Json")))
(DFunDef false "encOcc" ((PTuple PWild (PVar "line") (PVar "name") (PVar "key"))) (EApp (EVar "jArray") (EListLit (EApp (EVar "JInt") (EVar "line")) (EApp (EVar "JString") (EVar "name")) (EApp (EVar "JString") (EVar "key")))))
(DTypeSig false "encDirective" (TyFun (TyCon "Directive") (TyCon "Json")))
(DFunDef false "encDirective" ((PCon "Directive" (PVar "scope") (PVar "names"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "scope")) (EApp (EVar "encScope") (EVar "scope"))) (ETuple (ELit (LString "rules")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EVar "JString") (EVar "n")))) (EVar "names")))))))
(DTypeSig false "encScope" (TyFun (TyCon "DirScope") (TyCon "Json")))
(DFunDef false "encScope" ((PCon "DScopeFile")) (EApp (EVar "JString") (ELit (LString "file"))))
(DFunDef false "encScope" ((PCon "DScopeLine" (PVar "l"))) (EApp (EVar "JInt") (EVar "l")))
(DTypeSig true "decodeEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "LintEntry")))))))
(DFunDef false "decodeEntry" ((PVar "stamp") (PVar "path") (PVar "hash") (PVar "text")) (EMatch (EApp (EVar "parse") (EVar "text")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "j")) () (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "!=" (EApp (EApp (EVar "decInt") (ELit (LString "version"))) (EVar "j")) (EApp (EVar "Some") (EVar "cacheFormatVersion"))) (EBinOp "!=" (EApp (EApp (EVar "decStr") (ELit (LString "stamp"))) (EVar "j")) (EApp (EVar "Some") (EVar "stamp")))) (EBinOp "!=" (EApp (EApp (EVar "decStr") (ELit (LString "path"))) (EVar "j")) (EApp (EVar "Some") (EVar "path")))) (EBinOp "!=" (EApp (EApp (EVar "decStr") (ELit (LString "hash"))) (EVar "j")) (EApp (EVar "Some") (EVar "hash")))) (EVar "None") (EApp (EApp (EApp (EApp (EVar "map3") (ELam ((PVar "fs") (PVar "ds") (PVar "dirs")) (ERecordCreate "LintEntry" ((fa "path" (EVar "path")) (fa "contentHash" (EVar "hash")) (fa "findings" (EVar "fs")) (fa "dupOccs" (EVar "ds")) (fa "directives" (EVar "dirs")) (fa "dirty" (EVar "False")))))) (EApp (EApp (EVar "decList") (EVar "decFinding")) (EApp (EApp (EVar "lookup") (ELit (LString "findings"))) (EVar "j")))) (EApp (EApp (EVar "decList") (EApp (EVar "decOcc") (EVar "path"))) (EApp (EApp (EVar "lookup") (ELit (LString "dupOccs"))) (EVar "j")))) (EApp (EApp (EVar "decList") (EVar "decDirective")) (EApp (EApp (EVar "lookup") (ELit (LString "directives"))) (EVar "j"))))))))
(DTypeSig false "decStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "decStr" ((PVar "k") (PVar "j")) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "lookup") (EVar "k")) (EVar "j"))) (EVar "asString")))
(DTypeSig false "decInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "decInt" ((PVar "k") (PVar "j")) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "lookup") (EVar "k")) (EVar "j"))) (EVar "asInt")))
(DTypeSig false "decList" (TyFun (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "decList" ((PVar "f") (PCon "Some" (PVar "j"))) (EApp (EApp (EVar "optBind") (EApp (EVar "asArray") (EVar "j"))) (ELam ((PVar "arr")) (EApp (EApp (EApp (EApp (EVar "decListGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DFunDef false "decList" (PWild (PCon "None")) (EVar "None"))
(DTypeSig false "decListGo" (TyFun (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "decListGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Some") (EListLit)) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "map2") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "::" (EVar "_a") (EVar "_b")))) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EApp (EApp (EApp (EApp (EVar "decListGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "decFinding" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Finding"))))
(DFunDef false "decFinding" ((PVar "j")) (EApp (EApp (EApp (EApp (EApp (EVar "map4") (ELam ((PVar "r") (PVar "m") (PVar "s") (PVar "l")) (ERecordCreate "Finding" ((fa "rule" (EVar "r")) (fa "message" (EVar "m")) (fa "severity" (EVar "s")) (fa "loc" (EVar "l")))))) (EApp (EApp (EVar "decStr") (ELit (LString "rule"))) (EVar "j"))) (EApp (EApp (EVar "decStr") (ELit (LString "message"))) (EVar "j"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "decStr") (ELit (LString "severity"))) (EVar "j"))) (EVar "decSeverity"))) (EApp (EVar "decLoc") (EApp (EApp (EVar "lookup") (ELit (LString "loc"))) (EVar "j")))))
(DTypeSig false "decSeverity" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Severity"))))
(DFunDef false "decSeverity" ((PLit (LString "error"))) (EApp (EVar "Some") (EVar "SevError")))
(DFunDef false "decSeverity" ((PLit (LString "warning"))) (EApp (EVar "Some") (EVar "SevWarning")))
(DFunDef false "decSeverity" (PWild) (EVar "None"))
(DTypeSig false "decLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "decLoc" ((PCon "Some" (PCon "JNull"))) (EApp (EVar "Some") (EVar "None")))
(DFunDef false "decLoc" ((PCon "Some" (PVar "j"))) (EApp (EApp (EVar "map") (ELam ((PVar "l")) (EApp (EVar "Some") (EVar "l")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "map5") (ELam ((PVar "f") (PVar "a") (PVar "b") (PVar "c") (PVar "d")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 0))) (EVar "j"))) (EVar "asString"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 1))) (EVar "j"))) (EVar "asInt"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 2))) (EVar "j"))) (EVar "asInt"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 3))) (EVar "j"))) (EVar "asInt"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 4))) (EVar "j"))) (EVar "asInt")))))
(DFunDef false "decLoc" ((PCon "None")) (EVar "None"))
(DTypeSig false "decOcc" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "decOcc" ((PVar "path") (PVar "j")) (EApp (EApp (EApp (EApp (EVar "map3") (ELam ((PVar "line") (PVar "name") (PVar "key")) (ETuple (EVar "path") (EVar "line") (EVar "name") (EVar "key")))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 0))) (EVar "j"))) (EVar "asInt"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 1))) (EVar "j"))) (EVar "asString"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 2))) (EVar "j"))) (EVar "asString"))))
(DTypeSig false "decDirective" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Directive"))))
(DFunDef false "decDirective" ((PVar "j")) (EApp (EApp (EApp (EVar "map2") (ELam ((PVar "scope") (PVar "names")) (EApp (EApp (EVar "Directive") (EVar "scope")) (EVar "names")))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "lookup") (ELit (LString "scope"))) (EVar "j"))) (EVar "decScope"))) (EApp (EApp (EVar "decList") (EVar "asString")) (EApp (EApp (EVar "lookup") (ELit (LString "rules"))) (EVar "j")))))
(DTypeSig false "decScope" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "DirScope"))))
(DFunDef false "decScope" ((PCon "JString" (PLit (LString "file")))) (EApp (EVar "Some") (EVar "DScopeFile")))
(DFunDef false "decScope" ((PCon "JInt" (PVar "l"))) (EApp (EVar "Some") (EApp (EVar "DScopeLine") (EVar "l"))))
(DFunDef false "decScope" (PWild) (EVar "None"))
(DTypeSig false "optBind" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Option") (TyVar "b"))) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "optBind" ((PCon "Some" (PVar "a")) (PVar "f")) (EApp (EVar "f") (EVar "a")))
(DFunDef false "optBind" ((PCon "None") PWild) (EVar "None"))
(DTypeSig false "map2" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyVar "c"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyApp (TyCon "Option") (TyVar "c"))))))
(DFunDef false "map2" ((PVar "f") (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EVar "Some") (EApp (EApp (EVar "f") (EVar "a")) (EVar "b"))))
(DFunDef false "map2" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "map3" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyVar "d")))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "c")) (TyApp (TyCon "Option") (TyVar "d")))))))
(DFunDef false "map3" ((PVar "f") (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "Some" (PVar "c"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c"))))
(DFunDef false "map3" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "map4" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyFun (TyVar "d") (TyVar "e"))))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "c")) (TyFun (TyApp (TyCon "Option") (TyVar "d")) (TyApp (TyCon "Option") (TyVar "e"))))))))
(DFunDef false "map4" ((PVar "f") (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "Some" (PVar "c")) (PCon "Some" (PVar "d"))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d"))))
(DFunDef false "map4" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "map5" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyFun (TyVar "d") (TyFun (TyVar "e") (TyVar "f")))))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "c")) (TyFun (TyApp (TyCon "Option") (TyVar "d")) (TyFun (TyApp (TyCon "Option") (TyVar "e")) (TyApp (TyCon "Option") (TyVar "f")))))))))
(DFunDef false "map5" ((PVar "f") (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "Some" (PVar "c")) (PCon "Some" (PVar "d")) (PCon "Some" (PVar "e"))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")) (EVar "e"))))
(DFunDef false "map5" (PWild PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig true "loadEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "LintEntry"))))))))
(DFunDef false "loadEntry" ((PVar "cacheDir") (PVar "stamp") (PVar "path") (PVar "hash")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "shardPathOf") (EVar "cacheDir")) (EVar "path"))) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "text")) () (EApp (EApp (EApp (EApp (EVar "decodeEntry") (EVar "stamp")) (EVar "path")) (EVar "hash")) (EVar "text")))))
(DTypeSig true "storeEntries" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "storeEntries" ((PVar "cacheDir") (PVar "stamp") (PVar "entries")) (EBlock (DoLet false false (PVar "dirty") (EApp (EApp (EVar "filterList") (EVar "entryDirty")) (EVar "entries"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "dirty")) (ELit (LInt 0))) (ELit LUnit) (EMatch (EApp (EVar "ensureCacheDir") (EVar "cacheDir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeStagingDir") (EVar "cacheDir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "tmp")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "storeGo") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "dirty"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "tmp"))) (DoExpr (ELit LUnit)))))))))))
(DTypeSig false "entryDirty" (TyFun (TyCon "LintEntry") (TyCon "Bool")))
(DFunDef false "entryDirty" ((PVar "e")) (EFieldAccess (EVar "e") "dirty"))
(DTypeSig false "storeGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "storeGo" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "storeGo" ((PVar "cacheDir") (PVar "tmp") (PVar "stamp") (PCons (PVar "e") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "storeOne") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "storeGo") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "rest")))))
(DTypeSig false "storeOne" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "storeOne" ((PVar "cacheDir") (PVar "tmp") (PVar "stamp") (PVar "e")) (EBlock (DoLet false false (PVar "staged") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "tmp"))) (ELit (LString "/shard.json")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "staged")) (EApp (EApp (EVar "encodeEntry") (EVar "stamp")) (EVar "e"))) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "rename") (EVar "staged")) (EApp (EApp (EVar "shardPathOf") (EVar "cacheDir")) (EFieldAccess (EVar "e") "path"))) (arm (PCon "Err" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EVar "staged"))) (DoExpr (ELit LUnit)))) (arm (PCon "Ok" PWild) () (ELit LUnit))))))))
(DTypeSig false "ensureCacheDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "ensureCacheDir" ((PVar "cacheDir")) (EBlock (DoLet false false PWild (EApp (EVar "makeDir") (EApp (EVar "parentOfCacheDir") (EVar "cacheDir")))) (DoLet false false PWild (EApp (EVar "makeDir") (EVar "cacheDir"))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "cacheDir")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "cannot create ")) (EApp (EVar "display") (EVar "cacheDir"))) (ELit (LString ""))))))))
(DTypeSig false "parentOfCacheDir" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parentOfCacheDir" ((PVar "cacheDir")) (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EApp (EVar "dropLastSeg") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "cacheDir")))))
(DTypeSig false "dropLastSeg" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropLastSeg" ((PList)) (EListLit))
(DFunDef false "dropLastSeg" ((PList PWild)) (EListLit))
(DFunDef false "dropLastSeg" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropLastSeg") (EVar "rest"))))
(DTypeSig false "makeStagingDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeStagingDir" ((PVar "cacheDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "cacheDir"))) (ELit (LString "/.staging_XXXXXX"))))) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "msg")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EIf (EBinOp "!=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "err") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "err"))) (EBlock (DoLet false false (PVar "dir") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "dir")))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint") ((mem "Finding" true) (mem "Directive" true) (mem "DirScope" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "filterList" false) (mem "splitOnChar" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false) (mem "at" false))))
(DData Public "LintEntry" () ((variant "LintEntry" (ConNamed (field "path" (TyCon "String")) (field "contentHash" (TyCon "String")) (field "findings" (TyApp (TyCon "List") (TyCon "Finding"))) (field "dupOccs" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))) (field "directives" (TyApp (TyCon "List") (TyCon "Directive"))) (field "dirty" (TyCon "Bool"))))) ())
(DTypeSig false "cacheFormatVersion" (TyCon "Int"))
(DFunDef false "cacheFormatVersion" () (ELit (LInt 1)))
(DTypeSig true "contentHashOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "contentHashOf" ((PVar "src")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "src"))) (DoLet false false (PVar "lane2") (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "hashString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "n")) (EVar "src"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "hashString") (EVar "src")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "lane2"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))))
(DTypeSig true "ruleSetStamp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "ruleSetStamp" (PWild) (EMatch (EApp (EVar "readFileBytes") (EApp (EVar "executablePath") (ELit LUnit))) (arm (PCon "Err" PWild) () (ELit (LString ""))) (arm (PCon "Ok" (PVar "bs")) () (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "fnv62") (EVar "bs")) (EApp (EVar "arrayLength") (EVar "bs"))) (ELit (LInt 0))) (EVar "fnv62Offset")))) (ELit (LString ""))))))
(DTypeSig false "fnv62Mask" (TyCon "Int"))
(DFunDef false "fnv62Mask" () (ELit (LInt 4611686018427387903)))
(DTypeSig false "fnv62Offset" (TyCon "Int"))
(DFunDef false "fnv62Offset" () (ELit (LInt 860922984064492325)))
(DTypeSig false "fnv62Prime" (TyCon "Int"))
(DFunDef false "fnv62Prime" () (ELit (LInt 1099511628211)))
(DTypeSig false "fnv62" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "fnv62" ((PVar "bs") (PVar "n") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "fnv62") (EVar "bs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EVar "bitAnd") (EVar "fnv62Mask")) (EBinOp "*" (EApp (EApp (EVar "bitXor") (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bs"))) (EVar "fnv62Prime")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "cacheDirOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "cacheDirOf" ((PVar "root")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/.medaka/lint-cache"))))
(DTypeSig true "shardPathOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "shardPathOf" ((PVar "cacheDir") (PVar "srcPath")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "cacheDir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "sanitizePath") (EVar "srcPath")))) (ELit (LString "-"))) (EApp (EMethodRef "display") (EApp (EVar "hashString") (EVar "srcPath")))) (ELit (LString ".json"))))
(DTypeSig false "sanitizePath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sanitizePath" ((PVar "p")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "p"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "start") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 60))) (EBinOp "-" (EVar "n") (ELit (LInt 60))) (ELit (LInt 0)))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "cs")) (EVar "start")) (EVar "n")))))))
(DTypeSig false "sanitizeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sanitizeGo" ((PVar "cs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "sanitizeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sanitizeChar" (TyFun (TyCon "Char") (TyCon "Char")))
(DFunDef false "sanitizeChar" ((PVar "c")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar ".")))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EBinOp "==" (EVar "c") (ELit (LChar "-")))) (EVar "c") (EIf (EVar "otherwise") (ELit (LChar "_")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encodeEntry" (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyCon "String"))))
(DFunDef false "encodeEntry" ((PVar "stamp") (PVar "e")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "version")) (EApp (EVar "JInt") (EVar "cacheFormatVersion"))) (ETuple (ELit (LString "stamp")) (EApp (EVar "JString") (EVar "stamp"))) (ETuple (ELit (LString "path")) (EApp (EVar "JString") (EFieldAccess (EVar "e") "path"))) (ETuple (ELit (LString "hash")) (EApp (EVar "JString") (EFieldAccess (EVar "e") "contentHash"))) (ETuple (ELit (LString "findings")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "encFinding")) (EFieldAccess (EVar "e") "findings")))) (ETuple (ELit (LString "dupOccs")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "encOcc")) (EFieldAccess (EVar "e") "dupOccs")))) (ETuple (ELit (LString "directives")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "encDirective")) (EFieldAccess (EVar "e") "directives"))))))))
(DTypeSig false "encFinding" (TyFun (TyCon "Finding") (TyCon "Json")))
(DFunDef false "encFinding" ((PVar "f")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "rule")) (EApp (EVar "JString") (EFieldAccess (EVar "f") "rule"))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EFieldAccess (EVar "f") "message"))) (ETuple (ELit (LString "severity")) (EApp (EVar "JString") (EApp (EVar "encSeverity") (EFieldAccess (EVar "f") "severity")))) (ETuple (ELit (LString "loc")) (EApp (EVar "encLoc") (EFieldAccess (EVar "f") "loc"))))))
(DTypeSig false "encSeverity" (TyFun (TyCon "Severity") (TyCon "String")))
(DFunDef false "encSeverity" ((PCon "SevError")) (ELit (LString "error")))
(DFunDef false "encSeverity" ((PCon "SevWarning")) (ELit (LString "warning")))
(DTypeSig false "encLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json")))
(DFunDef false "encLoc" ((PCon "None")) (EVar "JNull"))
(DFunDef false "encLoc" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "l") (PVar "c") (PVar "el") (PVar "ec")))) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (EVar "file")) (EApp (EVar "JInt") (EVar "l")) (EApp (EVar "JInt") (EVar "c")) (EApp (EVar "JInt") (EVar "el")) (EApp (EVar "JInt") (EVar "ec")))))
(DTypeSig false "encOcc" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Json")))
(DFunDef false "encOcc" ((PTuple PWild (PVar "line") (PVar "name") (PVar "key"))) (EApp (EVar "jArray") (EListLit (EApp (EVar "JInt") (EVar "line")) (EApp (EVar "JString") (EVar "name")) (EApp (EVar "JString") (EVar "key")))))
(DTypeSig false "encDirective" (TyFun (TyCon "Directive") (TyCon "Json")))
(DFunDef false "encDirective" ((PCon "Directive" (PVar "scope") (PVar "names"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "scope")) (EApp (EVar "encScope") (EVar "scope"))) (ETuple (ELit (LString "rules")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EVar "JString") (EVar "n")))) (EVar "names")))))))
(DTypeSig false "encScope" (TyFun (TyCon "DirScope") (TyCon "Json")))
(DFunDef false "encScope" ((PCon "DScopeFile")) (EApp (EVar "JString") (ELit (LString "file"))))
(DFunDef false "encScope" ((PCon "DScopeLine" (PVar "l"))) (EApp (EVar "JInt") (EVar "l")))
(DTypeSig true "decodeEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "LintEntry")))))))
(DFunDef false "decodeEntry" ((PVar "stamp") (PVar "path") (PVar "hash") (PVar "text")) (EMatch (EApp (EVar "parse") (EVar "text")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "j")) () (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "!=" (EApp (EApp (EVar "decInt") (ELit (LString "version"))) (EVar "j")) (EApp (EVar "Some") (EVar "cacheFormatVersion"))) (EBinOp "!=" (EApp (EApp (EVar "decStr") (ELit (LString "stamp"))) (EVar "j")) (EApp (EVar "Some") (EVar "stamp")))) (EBinOp "!=" (EApp (EApp (EVar "decStr") (ELit (LString "path"))) (EVar "j")) (EApp (EVar "Some") (EVar "path")))) (EBinOp "!=" (EApp (EApp (EVar "decStr") (ELit (LString "hash"))) (EVar "j")) (EApp (EVar "Some") (EMethodRef "hash")))) (EVar "None") (EApp (EApp (EApp (EApp (EDictApp "map3") (ELam ((PVar "fs") (PVar "ds") (PVar "dirs")) (ERecordCreate "LintEntry" ((fa "path" (EVar "path")) (fa "contentHash" (EMethodRef "hash")) (fa "findings" (EVar "fs")) (fa "dupOccs" (EVar "ds")) (fa "directives" (EVar "dirs")) (fa "dirty" (EVar "False")))))) (EApp (EApp (EVar "decList") (EVar "decFinding")) (EApp (EApp (EVar "lookup") (ELit (LString "findings"))) (EVar "j")))) (EApp (EApp (EVar "decList") (EApp (EVar "decOcc") (EVar "path"))) (EApp (EApp (EVar "lookup") (ELit (LString "dupOccs"))) (EVar "j")))) (EApp (EApp (EVar "decList") (EVar "decDirective")) (EApp (EApp (EVar "lookup") (ELit (LString "directives"))) (EVar "j"))))))))
(DTypeSig false "decStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "decStr" ((PVar "k") (PVar "j")) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "lookup") (EVar "k")) (EVar "j"))) (EVar "asString")))
(DTypeSig false "decInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "decInt" ((PVar "k") (PVar "j")) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "lookup") (EVar "k")) (EVar "j"))) (EVar "asInt")))
(DTypeSig false "decList" (TyFun (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "decList" ((PVar "f") (PCon "Some" (PVar "j"))) (EApp (EApp (EVar "optBind") (EApp (EVar "asArray") (EVar "j"))) (ELam ((PVar "arr")) (EApp (EApp (EApp (EApp (EVar "decListGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DFunDef false "decList" (PWild (PCon "None")) (EVar "None"))
(DTypeSig false "decListGo" (TyFun (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "decListGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Some") (EListLit)) (EIf (EVar "otherwise") (EApp (EApp (EApp (EDictApp "map2") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "::" (EVar "_a") (EVar "_b")))) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EApp (EApp (EApp (EApp (EVar "decListGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "decFinding" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Finding"))))
(DFunDef false "decFinding" ((PVar "j")) (EApp (EApp (EApp (EApp (EApp (EVar "map4") (ELam ((PVar "r") (PVar "m") (PVar "s") (PVar "l")) (ERecordCreate "Finding" ((fa "rule" (EVar "r")) (fa "message" (EVar "m")) (fa "severity" (EVar "s")) (fa "loc" (EVar "l")))))) (EApp (EApp (EVar "decStr") (ELit (LString "rule"))) (EVar "j"))) (EApp (EApp (EVar "decStr") (ELit (LString "message"))) (EVar "j"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "decStr") (ELit (LString "severity"))) (EVar "j"))) (EVar "decSeverity"))) (EApp (EVar "decLoc") (EApp (EApp (EVar "lookup") (ELit (LString "loc"))) (EVar "j")))))
(DTypeSig false "decSeverity" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Severity"))))
(DFunDef false "decSeverity" ((PLit (LString "error"))) (EApp (EVar "Some") (EVar "SevError")))
(DFunDef false "decSeverity" ((PLit (LString "warning"))) (EApp (EVar "Some") (EVar "SevWarning")))
(DFunDef false "decSeverity" (PWild) (EVar "None"))
(DTypeSig false "decLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "decLoc" ((PCon "Some" (PCon "JNull"))) (EApp (EVar "Some") (EVar "None")))
(DFunDef false "decLoc" ((PCon "Some" (PVar "j"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (EApp (EVar "Some") (EVar "l")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "map5") (ELam ((PVar "f") (PVar "a") (PVar "b") (PVar "c") (PVar "d")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 0))) (EVar "j"))) (EVar "asString"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 1))) (EVar "j"))) (EVar "asInt"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 2))) (EVar "j"))) (EVar "asInt"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 3))) (EVar "j"))) (EVar "asInt"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 4))) (EVar "j"))) (EVar "asInt")))))
(DFunDef false "decLoc" ((PCon "None")) (EVar "None"))
(DTypeSig false "decOcc" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "decOcc" ((PVar "path") (PVar "j")) (EApp (EApp (EApp (EApp (EDictApp "map3") (ELam ((PVar "line") (PVar "name") (PVar "key")) (ETuple (EVar "path") (EVar "line") (EVar "name") (EVar "key")))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 0))) (EVar "j"))) (EVar "asInt"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 1))) (EVar "j"))) (EVar "asString"))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "at") (ELit (LInt 2))) (EVar "j"))) (EVar "asString"))))
(DTypeSig false "decDirective" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Directive"))))
(DFunDef false "decDirective" ((PVar "j")) (EApp (EApp (EApp (EDictApp "map2") (ELam ((PVar "scope") (PVar "names")) (EApp (EApp (EVar "Directive") (EVar "scope")) (EVar "names")))) (EApp (EApp (EVar "optBind") (EApp (EApp (EVar "lookup") (ELit (LString "scope"))) (EVar "j"))) (EVar "decScope"))) (EApp (EApp (EVar "decList") (EVar "asString")) (EApp (EApp (EVar "lookup") (ELit (LString "rules"))) (EVar "j")))))
(DTypeSig false "decScope" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "DirScope"))))
(DFunDef false "decScope" ((PCon "JString" (PLit (LString "file")))) (EApp (EVar "Some") (EVar "DScopeFile")))
(DFunDef false "decScope" ((PCon "JInt" (PVar "l"))) (EApp (EVar "Some") (EApp (EVar "DScopeLine") (EVar "l"))))
(DFunDef false "decScope" (PWild) (EVar "None"))
(DTypeSig false "optBind" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Option") (TyVar "b"))) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "optBind" ((PCon "Some" (PVar "a")) (PVar "f")) (EApp (EVar "f") (EVar "a")))
(DFunDef false "optBind" ((PCon "None") PWild) (EVar "None"))
(DTypeSig false "map2" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyVar "c"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyApp (TyCon "Option") (TyVar "c"))))))
(DFunDef false "map2" ((PVar "f") (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EVar "Some") (EApp (EApp (EVar "f") (EVar "a")) (EVar "b"))))
(DFunDef false "map2" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "map3" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyVar "d")))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "c")) (TyApp (TyCon "Option") (TyVar "d")))))))
(DFunDef false "map3" ((PVar "f") (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "Some" (PVar "c"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c"))))
(DFunDef false "map3" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "map4" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyFun (TyVar "d") (TyVar "e"))))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "c")) (TyFun (TyApp (TyCon "Option") (TyVar "d")) (TyApp (TyCon "Option") (TyVar "e"))))))))
(DFunDef false "map4" ((PVar "f") (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "Some" (PVar "c")) (PCon "Some" (PVar "d"))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d"))))
(DFunDef false "map4" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "map5" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyFun (TyVar "d") (TyFun (TyVar "e") (TyVar "f")))))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "c")) (TyFun (TyApp (TyCon "Option") (TyVar "d")) (TyFun (TyApp (TyCon "Option") (TyVar "e")) (TyApp (TyCon "Option") (TyVar "f")))))))))
(DFunDef false "map5" ((PVar "f") (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "Some" (PVar "c")) (PCon "Some" (PVar "d")) (PCon "Some" (PVar "e"))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")) (EVar "e"))))
(DFunDef false "map5" (PWild PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig true "loadEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "LintEntry"))))))))
(DFunDef false "loadEntry" ((PVar "cacheDir") (PVar "stamp") (PVar "path") (PVar "hash")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "shardPathOf") (EVar "cacheDir")) (EVar "path"))) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "text")) () (EApp (EApp (EApp (EApp (EVar "decodeEntry") (EVar "stamp")) (EVar "path")) (EMethodRef "hash")) (EVar "text")))))
(DTypeSig true "storeEntries" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "storeEntries" ((PVar "cacheDir") (PVar "stamp") (PVar "entries")) (EBlock (DoLet false false (PVar "dirty") (EApp (EApp (EVar "filterList") (EVar "entryDirty")) (EVar "entries"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "dirty")) (ELit (LInt 0))) (ELit LUnit) (EMatch (EApp (EVar "ensureCacheDir") (EVar "cacheDir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeStagingDir") (EVar "cacheDir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "tmp")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "storeGo") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "dirty"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "tmp"))) (DoExpr (ELit LUnit)))))))))))
(DTypeSig false "entryDirty" (TyFun (TyCon "LintEntry") (TyCon "Bool")))
(DFunDef false "entryDirty" ((PVar "e")) (EFieldAccess (EVar "e") "dirty"))
(DTypeSig false "storeGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "storeGo" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "storeGo" ((PVar "cacheDir") (PVar "tmp") (PVar "stamp") (PCons (PVar "e") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "storeOne") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "storeGo") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "rest")))))
(DTypeSig false "storeOne" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "storeOne" ((PVar "cacheDir") (PVar "tmp") (PVar "stamp") (PVar "e")) (EBlock (DoLet false false (PVar "staged") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "tmp"))) (ELit (LString "/shard.json")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "staged")) (EApp (EApp (EVar "encodeEntry") (EVar "stamp")) (EVar "e"))) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "rename") (EVar "staged")) (EApp (EApp (EVar "shardPathOf") (EVar "cacheDir")) (EFieldAccess (EVar "e") "path"))) (arm (PCon "Err" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EVar "staged"))) (DoExpr (ELit LUnit)))) (arm (PCon "Ok" PWild) () (ELit LUnit))))))))
(DTypeSig false "ensureCacheDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "ensureCacheDir" ((PVar "cacheDir")) (EBlock (DoLet false false PWild (EApp (EVar "makeDir") (EApp (EVar "parentOfCacheDir") (EVar "cacheDir")))) (DoLet false false PWild (EApp (EVar "makeDir") (EVar "cacheDir"))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "cacheDir")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "cannot create ")) (EApp (EMethodRef "display") (EVar "cacheDir"))) (ELit (LString ""))))))))
(DTypeSig false "parentOfCacheDir" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parentOfCacheDir" ((PVar "cacheDir")) (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EApp (EVar "dropLastSeg") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "cacheDir")))))
(DTypeSig false "dropLastSeg" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropLastSeg" ((PList)) (EListLit))
(DFunDef false "dropLastSeg" ((PList PWild)) (EListLit))
(DFunDef false "dropLastSeg" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropLastSeg") (EVar "rest"))))
(DTypeSig false "makeStagingDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeStagingDir" ((PVar "cacheDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "cacheDir"))) (ELit (LString "/.staging_XXXXXX"))))) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "msg")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EIf (EBinOp "!=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "err") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "err"))) (EBlock (DoLet false false (PVar "dir") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "dir")))))))))
