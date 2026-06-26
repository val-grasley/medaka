# compiler/ generic-helper census

READ-ONLY analysis (no `.mdk` changed). Input to the planned
`support/`-centralization refactor. The compiler deliberately does **not** import
`stdlib/`, so each stage hand-rolls small list/string/option/assoc helpers. This
file enumerates every duplicated *generic* helper (one that could live in a
stdlib), clusters by semantic equivalence (not name), and marks
**IDENTICAL**/**DRIFTED** copies.

Method: a strict type filter (signature purely over
`List`/`String`/`Option`/`Int`/`Bool`/`Char`/tuples/type-vars) produced 706
candidates across the tree; bodies were then read and classified. Domain-plumbing
that merely *looks* generic is split out in the EXCLUDE section.

Already-centralized baseline — `support/util.mdk` exports: `contains`,
`concatMapList`, `listLen`, `reverseL`, `anyList`, `allList`, `lookupAssoc`,
`joinWith` (the *canonical* O(n) `stringConcat (intersperseStr …)`), `joinNl`,
`escStr` + the `fallthroughName`/`noneHeadTag` cross-stage constants.
`support/ordmap.mdk` exports the weight-balanced `OrdMap` (om*). `support/timer.mdk`
is perf-only (not in scope here).

---

## 1. Summary counts

| Metric | Count |
|--------|-------|
| Generic-helper **clusters** (distinct stdlib-shaped functions) | ~38 |
| Clusters **duplicated across ≥2 files** | 23 |
| Clusters whose canonical **already lives in `support/` but still has local copies** | 6 (`contains`, `concatMapList`, `listLen`, `reverseL`, `anyList`/`allList`, `joinWith`/`joinNl`) |
| **DRIFTED** clusters (divergent impl, same result) | 5 (`joinWith`, `joinNl`/`joinDot`, `reverseL`, `concatList`, the `dedup`/`nub` family) |
| Files defining ≥1 generic helper | 28 |

Highest-value finding: **`joinWith` has drifted to the slow O(n²) form in BOTH
`types/typecheck.mdk` AND `eval/eval.mdk`** (`x ++ sep ++ joinWith sep rest`),
even though `support/util.mdk:54` already holds the O(n) `stringConcat
(intersperseStr …)` canonical with a comment explaining exactly why the recursive
`++` is quadratic. Same quadratic pattern recurs in `eval.concatList`,
`eval.joinDots`, `desugar.concatLists`, `loader.reverseL`. These are
correctness-neutral but perf bugs-in-waiting, and the canonical already exists.

---

## 2. Duplicate-cluster table

Sorted by impact (most copies first; drifted first). "canonical" = which existing
copy (or `support/`) should become the single definition. File:line is the
**definition** site.

| Proposed canonical | Copies (file:line — local name) | Status | Recommended canonical impl | Note |
|---|---|---|---|---|
| **`joinWith`** (sep-join) | util.mdk:54 `joinWith` (canonical) · typecheck.mdk:1316 `joinWith` · eval.mdk:144 `joinWith` · doctest.mdk:232 `joinWithLocal` · sexp.mdk via `joinSp` | **DRIFTED** | `support/util.mdk` (`stringConcat (intersperseStr sep xs)`, O(n)) | typecheck + eval copies are the **slow O(n²)** `x ++ sep ++ …`. Pure win: delete 3 locals, import support. |
| **`joinNl`** = `joinWith "\n"` | util.mdk:64 `joinNl` (canonical) · typecheck.mdk:6887 `joinNl` · diagnostics.mdk:140 `joinNl` · doctest.mdk:229 `joinNlLocal` | **DRIFTED** | `support/util.mdk` | typecheck/diagnostics/doctest copies inline the O(n²) `x ++ "\n" ++ joinNl xs`. |
| **`joinDot`** = `joinWith "."` | typecheck.mdk:6707 `joinDot` · resolve.mdk:613 `joinDot` · loader.mdk:36 `joinDot` · private_mangle.mdk:399 `joinDotU` · eval.mdk:2144 `joinDots` | **DRIFTED** | new `support` `joinDot = joinWith "."` | 5 copies, 3 different names. loader's uses `stringConcat`; typecheck/eval/resolve use O(n²) `++`. |
| **`contains`/member** (`String -> List String -> Bool`) | util.mdk:7 `contains` (canonical) · typecheck.mdk:2605 `containsName` · llvm_emit.mdk:894 `containsStr` · private_mangle.mdk:802 `containsPM` · loader.mdk:18 `memStr` · repl.mdk:189 `containsName` | IDENTICAL | `support/util.mdk` `contains` | 6 copies, 5 names. All linear `x==y || …`. Highest copy-count after joins. |
| **`reverseL`** (`List a -> List a`) | util.mdk:22 `reverseL` (canonical, accumulator) · typecheck.mdk:5323 `revLL` · fmt.mdk:117 `reverseList` · private_mangle.mdk:821 `reverseLPM` · loader.mdk:219 `reverseL` · core_ir_sexp_parse.mdk:91 `reverseL` | **DRIFTED** | `support/util.mdk` (tail-recursive accumulator) | loader.mdk:219 is **O(n²)** `reverseL xs ++ [x]` — the only non-tail copy. Others identical to canonical. |
| **`concatMap`** (`(a -> List b) -> List a -> List b`) | util.mdk:12 `concatMapList` (canonical) · typecheck.mdk:1003 `concatMapL` · doctest.mdk:276 `concatMapL` · private_mangle.mdk:798 `concatMapPM` | IDENTICAL | `support/util.mdk` `concatMapList` | 4 copies, 3 names. All `f x ++ concatMapList f xs`. |
| **`length`** (`List a -> Int`) | util.mdk:17 `listLen` (canonical) · typecheck.mdk:983 `lengthL` · core_ir_lower.mdk:1035 `lengthL` · loader.mdk:22 `lenL` · fmt.mdk:149 `lenL` · fuzz_gen_main.mdk:65 `lenL` | IDENTICAL | `support/util.mdk` `listLen` | 6 copies, 3 names. Trivial `1 + …`. |
| **`filter`** (`(a -> Bool) -> List a -> List a`) | typecheck.mdk:5486 `filterList` · eval.mdk:900 `filterList` · prop_runner.mdk:218 `filterList` · fmt.mdk:187 `filterL` · private_mangle.mdk:435 `filterStr` (`String` only) | IDENTICAL | promote typecheck's `filterList` → `support/util.mdk` | Not yet in support. 5 copies. `filterStr` is the String monomorphization. |
| **`isEmpty`/null** (`List a -> Bool`) | typecheck.mdk:3331 `isEmptyL` · typecheck.mdk:3577 `isEmptyList` (self-dup!) · printer.mdk:1002 `isEmptyL` · fmt.mdk:65 `isEmptyL` · core_ir_lower.mdk:908 `isEmptyList` · core_ir_lower.mdk:412 `nullL` · core_ir_eval.mdk:427 `cNullList` · prop_runner.mdk:367 `isEmpty` · eval.mdk:1472 `nullList` · private_mangle.mdk:828 `isEmptyPM` | IDENTICAL | new `support` `isEmptyL`/`nullL` pair | **10 copies, 6 names.** typecheck defines it TWICE (`isEmptyL`@3331 + `isEmptyList`@3577). Trivial `[] → True`. Biggest naming sprawl. |
| **`splitLast`** (`List a -> Option (List a, a)`) | argstamp_parity_probe.mdk:35 + 9 entries (core_ir_dict_pp_main:30, core_ir_prelude_main:27, core_ir_run_main:30, core_ir_typed_main:34, eval_dict_main:27, eval_prelude_main:21, eval_run_main:19, eval_typed_main:25, llvm_emit_typed_main:52) | IDENTICAL | promote to `support/util.mdk` | **10 byte-identical copies** across entry mains. Pure mechanical dedup. |
| **`rootsOrDefault`/`dirOf`/`dirGo` trio** | check_all_main:20, check_modules_main:20, core_ir_modules_main:28, diagnostics_project_main:25, eval_modules_main:23, eval_typed_modules_main:31, profile_modules_main:41 (+ llvm_bootstrap_lex_main:63, llvm_emit_modules_main:65 — style drift `_ 0` vs `path 0`) | IDENTICAL (2 style-only) | promote trio to a `support` project-roots helper | **9 copies of a 3-function trio.** The 2 llvm_* copies differ only in an ignored-param underscore. |
| **`init`/dropLast** (`List a -> List a`) | typecheck.mdk:6697 `dropLast` (String) · eval.mdk:2149 `initList` · resolve.mdk:618 `initList` · loader.mdk:26 `initL` · private_mangle.mdk:385 `initListU` | IDENTICAL | new `support` `initList` | 5 copies, 4 names. private_mangle/resolve are O(n²)-ish via append in mirror. |
| **`anyList`/`allList`** | util.mdk:30/35 (canonical) · typecheck.mdk:1134/1128 | IDENTICAL | `support/util.mdk` | typecheck still keeps both local copies despite support export. |
| **`lookupAssoc`** (String key) | util.mdk:41 `lookupAssoc` (canonical) · typecheck.mdk:987 `lookupAssocS` · private_mangle.mdk:806 `lookupPM` · diagnostics.mdk:216 `cacheLookup` | IDENTICAL | `support/util.mdk` `lookupAssoc` | linear assoc scan. (Int-key variant `lookupAssocI` is a separate small cluster.) |
| **`dedup`/nub** (first-occurrence dedup) | typecheck.mdk:1333 `dedupS` (**OrdMap, O(n·log n)**) · eval.mdk:1533 `nub` (O(n²)) · resolve.mdk:697 `findDups` · private_mangle.mdk:810 `dedupPM` (O(n²)) · typecheck.mdk:1188 `dedupI` (Int, O(n²)) | **DRIFTED** | **promote typecheck's OrdMap `dedupS`** | typecheck's is the fast one (uses `support.ordmap`); all others are naive O(n²) list-scan. High-value perf promotion. |
| **`sortUniqS`** (sorted+dedup String) | typecheck.mdk:145 `sortUniqS` (+`sortUniqSGo`/`sortInsertS`) | (singleton, but stdlib-shaped) | leave or move | O(n²) insertion sort; candidate to move to support proactively. |
| **`zipL`** (`List a -> List b -> List (a,b)`) | typecheck.mdk:1007 `zipL` · prop_runner.mdk:180 `zipL` | IDENTICAL | promote to `support/util.mdk` | 2 copies, same name. |
| **`maxI`/`minI`** (`Int -> Int -> Int`) | lsp.mdk:191 `maxI` · fuzz_gen_main.mdk:369 `maxI` · typecheck.mdk:5320 `minI` | IDENTICAL | promote `maxI`/`minI` to support | trivial. |
| **`lastOf`/firstOr** (head/last-with-default) | typecheck.mdk:2002 `headL` + :6702 `lastComponent` · eval.mdk:2154 `lastOfList` + :2159 `firstOrEmpty` · resolve.mdk:623 `lastOf` + :628 `firstOr` · loader.mdk:31 `lastOr` · private_mangle.mdk:390 `firstOrU` + :394 `lastOfPM` · repl.mdk:153 `lastLine` | IDENTICAL | new `support` `headOr`/`lastOr` | ~9 copies across head-or-default / last-or-default. Many names. |
| **startsWith/endsWith/prefix** | doctest.mdk:86 `startsWithStr` · loader.mdk:66 `startsWith` + :71 `endsWith` · repl.mdk:354 `startsWith` · lsp.mdk:591 `hasPrefix` · typecheck.mdk:6247 `endsWithStr` | IDENTICAL | new `support` `startsWith`/`endsWith` | 6 copies, 4 names. All `stringSlice` prefix/suffix compares. |
| **trim/whitespace** | build_cmd.mdk:42 `trimWS` (+trimLeft/trimRight) · repl.mdk:422 `stringTrim` (+Left/Right) · doctest.mdk:92 `trimStr` | DRIFTED (build_cmd O(n²) slice-recursion vs repl array-scan) | promote repl's array-scan version | repl's `stringTrim` scans the char array (O(n)); build_cmd recurses on `stringSlice` (O(n²)). |
| **`utf8Len`/`utf8CharWidth`** | lsp.mdk:778/790 · lsp_harness.mdk:134/124 | IDENTICAL | promote pair to support | 2 copies each, byte-identical. |
| **`isSome`/`mapOption`/`orElseOpt`** (Option) | typecheck.mdk:2491 `isSome` · eval.mdk:1637 `mapOption` · exhaust.mdk:278 `orElseOpt` | IDENTICAL | promote to support Option helpers | each a singleton today but obviously stdlib. |

---

## 3. Already-centralized-but-still-copied (pure wins)

These clusters have their canonical **already exported from `support/util.mdk`**,
yet stages still define local copies. Deleting the local + importing support is a
behavior-preserving (and in the joinWith/joinNl/reverseL cases, **perf-improving**)
change:

| support canonical | Local copies to delete |
|---|---|
| `joinWith` (O(n)) | `typecheck.mdk:1316` (O(n²)), `eval.mdk:144` (O(n²)), `doctest.mdk:232 joinWithLocal` |
| `joinNl` | `typecheck.mdk:6887`, `diagnostics.mdk:140`, `doctest.mdk:229 joinNlLocal` |
| `contains` | `typecheck.mdk:2605 containsName`, `llvm_emit.mdk:894 containsStr`, `private_mangle.mdk:802 containsPM`, `loader.mdk:18 memStr`, `repl.mdk:189 containsName` |
| `concatMapList` | `typecheck.mdk:1003 concatMapL`, `doctest.mdk:276 concatMapL`, `private_mangle.mdk:798 concatMapPM` |
| `listLen` | `typecheck.mdk:983 lengthL`, `core_ir_lower.mdk:1035 lengthL`, `loader.mdk:22 lenL`, `fmt.mdk:149 lenL`, `fuzz_gen_main.mdk:65 lenL` |
| `reverseL` | `typecheck.mdk:5323 revLL`, `fmt.mdk:117 reverseList`, `private_mangle.mdk:821 reverseLPM`, `loader.mdk:219 reverseL` (O(n²)!), `core_ir_sexp_parse.mdk:91 reverseL` |
| `anyList`/`allList` | `typecheck.mdk:1134/1128` |
| `lookupAssoc` | `typecheck.mdk:987 lookupAssocS`, `private_mangle.mdk:806 lookupPM` |

---

## 4. Divergent-name map (rename churn for centralization)

Counts are `grep -ac <name> <file>` (occurrences = def + sig + call sites; treat
as a churn upper bound, subtract ~3 for def/sig/comment to estimate call sites).

| Canonical | Local name → file (occurrences) |
|---|---|
| `listLen` | `lengthL`→typecheck (31), `lengthL`→core_ir_lower (5), `lenL`→loader (4), `lenL`→fmt (6), `lenL`→fuzz_gen_main (4) |
| `concatMapList` | `concatMapL`→typecheck (86), `concatMapL`→doctest (4), `concatMapPM`→private_mangle (22) |
| `lookupAssoc` | `lookupAssocS`→typecheck (46), `lookupPM`→private_mangle (7), `cacheLookup`→diagnostics (5) |
| `contains` | `containsName`→typecheck (38), `containsStr`→llvm_emit (37), `containsPM`→private_mangle (8), `memStr`→loader (7), `containsName`→repl (4) |
| `reverseL` | `revLL`→typecheck (13), `reverseList`→fmt (10), `reverseLPM`→private_mangle (3), `reverseL`→loader (4), `reverseL`→core_ir_sexp_parse (4) |
| `filterList` | `filterList`→typecheck (15), eval (6), prop_runner (6); `filterL`→fmt (4); `filterStr`→private_mangle (6) |
| `joinWith` | `joinWith`→typecheck (13), eval (7); `joinWithLocal`→doctest (5); (`intercalateS`→typecheck (9) is a same-semantics alias) |
| `joinNl` | `joinNl`→typecheck (13), diagnostics (6); `joinNlLocal`→doctest (3) |
| `joinDot` | `joinDot`→typecheck (8), resolve (8), loader (9); `joinDotU`→private_mangle (8); `joinDots`→eval (8) |
| `isEmptyL` | `isEmptyL`→typecheck (11)+printer (8)+fmt (4); `isEmptyList`→typecheck (4)+core_ir_lower (4); `nullL`→core_ir_lower (5); `nullList`→eval (4); `isEmpty`→prop_runner (4); `isNonEmpty`→resolve (4, negated) |
| `dedup` | `dedupS`→typecheck (31, OrdMap), `dedupI`→typecheck (9), `nub`→eval (9), `findDups`→resolve (8), `dedupPM`→private_mangle (6), `sortUniqS`→typecheck (12) |
| `initList` | `dropLast`→typecheck (5), `initList`→eval (5)+resolve (5), `initL`→loader (5), `initListU`→private_mangle (5) |
| `maxI`/`minI` | `maxI`→lsp (4)+fuzz_gen_main (4); `minI`→typecheck (6) |
| `anyList`/`allList` | `anyList`→typecheck (6), `allList`→typecheck (9) |
| `splitLast` | 10 identical copies (all `splitLast`, no rename needed — just dedup) |

---

## 5. EXCLUDE — domain plumbing that *looks* generic (do NOT fold into util)

| Function (file) | Why excluded |
|---|---|
| `lookupReturnsSelf` / `lookupSelfFnParams` (llvm_emit) | `List ((String,String), Bool/List Int)` — the tuple-key encodes the interface-method → dispatch-metadata table. |
| `ctorsOfTypeIn` (llvm_emit) | `List (String,String)` is the type-constructor table; ADT-codegen specific. |
| `lookupAssocSL2` / `hasKeySL2` / `hasAssocSL2` (typecheck) | `List (String, List Int)` constraint-id assoc shape; compiler-internal. |
| `promotedConstraints` / `inferredConstraintIds` / `methodConstrainedIds` (typecheck) | Constraint-id set manipulation over the dispatch metadata shape. |
| `lookupReqCount` / `lookupMethodReqCount` / `lookupPositions` / `ctorFieldOrderFor` / `receiverParam` (eval) | Dispatch-metadata assoc lookups over compiler-specific tuple shapes. |
| `binopMethod` / `binopPrimitiveHead` / `innerDefaultMethod` / `memberSuffix` (typecheck) | Operator→method routing tables / naming conventions. |
| `methodDictArityOf` / `implDictNames` / `dictArityOf` / `dictParamName` / `tupleHeadTagTc` (typecheck), `tupleHeadTag` (eval), `tupleCtorName` (exhaust) | Dict/tuple dispatch naming + arity — compiler ABI, not stdlib. |
| `tjLowOf` / `tjIndexOf` / `tjOnStack` (typecheck) | Tarjan SCC state accessors. |
| `fieldOwnerNames` / `removeAllS` (typecheck) | Record-field ownership / tyvar-set filtering tied to inference. |
| all `*Msg` / `*Warning` / `effStr` / `typeErrorLines` (typecheck), `stripWarnPrefix` (diagnostics) | Diagnostic-message construction. |
| `isXxxExtern` family + `defaultFnName`/`implFnName` + `strBytes`/`utf8Bytes`/`escBytes`/`hex2`/`hexDigit` (llvm_emit), most of `private_mangle` | Backend IR encoding / symbol mangling. |
| `keepIn` / `keepNotIn` / `subName` (marker), `filterIfaceMethods` / `ownersForTypes` / `filterContains` (resolve) | Filters over compiler-specific list/pair shapes; phase plumbing. |
| `allCovered` / `presentIn` / `orElseOpt` (exhaust) | Exhaustiveness-oracle predicates. |
| LSP doc/URI/framing helpers (`docsLookup`, `offsetOfLineCol`, `identifierAt`, `parseContentLength`, `pathOfUri`, …) (lsp, lsp_harness) | JSON-RPC protocol + text-position navigation. |
| `letters` / `dispatchTyparams` (typecheck), `startsWithAt` (eval/repl), `isCtorName`/`isCtorChars` (parser) | Constants / language-syntax classifiers (uppercase-ctor rule). |
| path helpers `dirOf`/`baseOf`/`chopExt`/`joinPath`/`stripMdk`/`modIdOf`/`baseName` (build_cmd, test_cmd, loader, resolve_modules_main) | Filesystem-path string ops — borderline; keep as a separate `support/path.mdk` if centralized, NOT in util. |
| `Ref`-accumulator globals (`recordsRef`, `promotedRef`, `sigMapRef`, …) | Mutable state, not helpers. |

NOTE: lexer's ASCII char predicates (`isDigit`/`isLower`/`isUpper`/`isAlnum`/
`isHexDigit`/`isSpace`/…@lexer.mdk:238-277) and `isIdentChar` (lsp/repl/parser) are
genuinely generic (`Char -> Bool` over ASCII ranges) and DO duplicate across
lexer/parser/lsp/repl — a borderline cluster worth a `support/char.mdk`, but kept
out of util because they're a self-contained family.

---

## 6. Per-file rollup (cleanup sequencing)

Sorted settled-files-first (low risk → high risk). "dups" = generic helpers that
are copies of a cluster canonical.

| File | generic helpers | dups | Sequence note |
|---|---|---|---|
| entries/*_main, *_batch | ~1–3 each | ~all | **First.** `splitLast` (10×) + `rootsOrDefault/dirOf/dirGo` (9×) + `envOr` (2×, identical) are mechanical, isolated, low-risk. |
| `support/*` | — | — | Add the new canonicals (`filterList`, `isEmptyL`, `zipL`, `maxI`/`minI`, `splitLast`, `initList`, `headOr`/`lastOr`, Option helpers, promote OrdMap `dedupS`). |
| `ir/core_ir_sexp_parse.mdk`, `ir/sexp.mdk`, `ir/core_ir_eval.mdk`, `ir/dce.mdk` | 1–2 | 1–2 | Settled; small. `reverseL`, `nullL`. |
| `driver/diagnostics.mdk`, `driver/build_cmd.mdk`, `driver/loader.mdk` | 5–12 | most | loader.mdk:219 `reverseL` is **O(n²)** — fix while here. |
| `tools/{fmt,prop_runner,check,repl,printer,doctest,lsp,lsp_harness}.mdk` | 2–10 | many | Settled tools. `utf8Len`/`utf8CharWidth` dedup across lsp/lsp_harness; trim-family dedup. |
| `frontend/{resolve,desugar,exhaust,marker}.mdk` | 4–10 | several | `joinDot`, `initList`, `findDups`, `concatLists` (O(n²)). |
| `ir/core_ir_lower.mdk` | 5 | 3 | `lengthL`, `isEmptyList`, `nullL`. |
| `backend/private_mangle.mdk` | ~15 | ~13 | Heavy duplication (`*PM` suffix family) but isolated module — the `PM` suffix makes renames mechanical. |
| `backend/llvm_emit.mdk` | 2 generic (`nthName`, `containsStr`) | 1 | Mostly backend-domain; only `containsStr` is a real dup of `contains`. |
| `eval/eval.mdk` | ~23 | many | DRIFTED `joinWith`/`concatList`/`joinDots`/`nub`. Mid-risk (eval ordering sensitivity) — do after tools/drivers. |
| **`types/typecheck.mdk`** | ~45 | ~25 | **LAST.** ~744 top-level defs, the most divergent names (`lengthL`/`revLL`/`concatMapL`/`lookupAssocS`/`containsName`/`isEmptyL`+`isEmptyList` self-dup), AND the highest call-site counts (`concatMapL`=86, `lookupAssocS`=46, `containsName`=38). **PROMOTE its OrdMap `dedupS` UP to support before deleting the naive copies elsewhere** — it is the fast canonical. Sheer churn + the eval-driver sensitivity make this the riskiest file. |

---

## 7. Singletons (stdlib-shaped, defined in exactly one file)

Lower-priority "move to support proactively" candidates — no current duplication,
but obviously generic:

- `sortUniqS`/`sortUniqSGo`/`sortInsertS` (typecheck) — sorted-dedup.
- `intSeq` (eval:158), `rangeFromCount` (typecheck:4371), `zerosL` (typecheck:6765) — int-range builders.
- `takeN` (eval:259), `nthName` (llvm_emit:480), `nthList` (prop_runner:185), `nthL` (fuzz_gen_main:61) — index/take (the nth* are a latent 3-copy cluster: `nthName`/`nthList`/`nthL`).
- `arrayToListG`/`arrayToListGo` (eval:150) — `Array a -> List a`.
- `mapOption` (eval:1637), `isSome` (typecheck:2491), `orElseOpt` (exhaust:278) — Option helpers.
- `splitOnChar`/`splitNl`/`stringSplitNewlines` (loader/doctest/repl) — string split (latent cluster, divergent impl).
- `spaces`/`newlineStr` (printer:177) — indent builders (O(n) naive `++`; could use a repeat).
- `boolToInt`/`boolEq`/`ordLt`/`ordGt` (eval) — tiny ADT projections; leave (trivial).
- `listInit`/`times`/`mapMut` (fuzz_gen_main) — fuzzer-local combinators; leave.

Leave (too trivial or too tied to one call site to be worth a cross-module import):
`subClampZero`, `wrapIf`, `identityPM`, `slen`, `substr3`, `charToStr`.
