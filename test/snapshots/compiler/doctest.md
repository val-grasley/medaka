# META
source_lines=320
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted doctest extraction + running — port of lib/doctest.ml.
--
-- `medaka test <file>` runs the examples authored in comments:
--
--   -- > expr          an input line (the expression to evaluate)
--   -- result          the expected rendering of `debug (expr)`
--
-- Block comments `{- … > expr … -}` are expanded to the same line form first.
-- For each example with an expected line we synthesize one
-- `__dt_i__ = debug (expr)` binding, run the file (single-file or multi-module,
-- mirroring Phase 92's two paths), look up the binding's value, render it, and
-- compare against the expected text.  Examples without an expected line are
-- "smoke" examples: synthesized raw (`__dt_i__ = expr`) and only checked to
-- evaluate without error.
--
-- This module is pure extraction + the run plumbing (Example/RunResult types,
-- buildDetails, hasUseDecls); the comment side channel comes from
-- compiler/lexer.mdk (`collectComments`), the run drivers (single/multi) from
-- compiler/tools/test_cmd.mdk.

import frontend.lexer.{Comment, collectComments, commentLine, commentText}
import frontend.ast.{Decl, DUse}
import frontend.parser.{parse}
import frontend.desugar.{desugar}
import eval.eval.{Value(..), lookupBinding, force, ppValue}
import support.util.{listLen, reverseL, joinNl, startsWith, stringTrim}

-- ── Data ──────────────────────────────────────────────────────────────────

-- An extracted example: the input expression text, the optional expected
-- rendering, and the 1-based source line of the input line (for `loc`).
public export data Example = Example String (Option String) Int

export exampleInput : Example -> String
exampleInput (Example i _ _) = i

exampleExpected : Example -> Option String
exampleExpected (Example _ e _) = e

export exampleLine : Example -> Int
exampleLine (Example _ _ l) = l

-- The outcome of running one example.
public export data ExResult =
  | Pass
  | Fail String String
  -- expected, actual
  | Errored String  -- message

public export data RunResult =
  | RunResult Int Int Int Int (List (Example, ExResult))
-- total passed failed errors details

export runPassed : RunResult -> Int
runPassed (RunResult _ p _ _ _) = p

export runFailed : RunResult -> Int
runFailed (RunResult _ _ f _ _) = f

export runErrors : RunResult -> Int
runErrors (RunResult _ _ _ e _) = e

export runDetails : RunResult -> List (Example, ExResult)
runDetails (RunResult _ _ _ _ d) = d

-- ── small string helpers (compiler avoids the stdlib) ──────────────────────

-- length of a string
slen : String -> Int
slen s = stringLength s

-- substring [a, b)
substr3 : Int -> Int -> String -> String
substr3 a b s = stringSlice a b s

-- True if `s` starts with `p`
startsWith : String -> String -> Bool
startsWith p s =
  let lp = slen p
  if slen s < lp then False else substr3 0 lp s == p

-- trim → stringTrim (support/util.mdk, imported above).

-- Split a string on '\n' into its lines (no trailing empty unless present).
splitNl : String -> List String
splitNl s = splitNlGo (stringToChars s) (arrayLength (stringToChars s)) 0 0

splitNlGo : Array Char -> Int -> Int -> Int -> List String
splitNlGo cs n start i
  | i >= n = [substrChars cs start n]
  | arrayGetUnsafe i cs == '\n' =
    substrChars cs start i :: splitNlGo cs n (i + 1) (i + 1)
  | otherwise = splitNlGo cs n start (i + 1)

substrChars : Array Char -> Int -> Int -> String
substrChars cs a b = stringFromChars (sliceChars cs a b)

sliceChars : Array Char -> Int -> Int -> Array Char
sliceChars cs a b = arrayFromList (sliceCharsGo cs a b)

sliceCharsGo : Array Char -> Int -> Int -> List Char
sliceCharsGo cs a b
  | a >= b = []
  | otherwise = arrayGetUnsafe a cs :: sliceCharsGo cs (a + 1) b

-- ── Comment classification (mirrors lib/doctest.ml) ────────────────────────
-- We work over (line, text) pairs rather than the lexer's `Comment` type:
-- the lexer exports `Comment` abstractly (no constructor), and block-comment
-- expansion must synthesize new per-line entries.  `text` carries the FULL
-- lexeme incl. the `--` delimiter, so an input line reads `-- > expr` and an
-- expected line `-- result`.

clText : (Int, String) -> String
clText (_, t) = t

clLine : (Int, String) -> Int
clLine (l, _) = l

isInputLine : (Int, String) -> Bool
isInputLine c = startsWith "-- > " (clText c)

inputBody : (Int, String) -> String
inputBody c =
  let t = clText c
  substr3 5 (slen t) t

isExpectedLine : (Int, String) -> Bool
isExpectedLine c =
  let t = clText c
  startsWith "-- " t && not (isInputLine c)

expectedBody : (Int, String) -> String
expectedBody c =
  let t = clText c
  substr3 3 (slen t) t

isBlankComment : (Int, String) -> Bool
isBlankComment c = clText c == "--"

isBlockComment : (Int, String) -> Bool
isBlockComment c = startsWith "{-" (clText c)

-- ── Block-comment expansion ────────────────────────────────────────────────
-- A `{- … -}` lexeme is one entry with embedded newlines.  Re-shape each inner
-- line into the line-comment form the extractor understands:
--   blank inner line  → "--"
--   other inner line  → "-- <trimmed>"
-- so an inner `> expr` becomes "-- > expr".  Line numbers stay accurate: inner
-- line i sits on the opener line + i.
expandBlock : (Int, String) -> List (Int, String)
expandBlock c =
  let t = clText c
  let n = slen t
  let inner = if n >= 4 then substr3 2 (n - 2) t else ""
  expandLines (clLine c) 0 (splitNl inner)

expandLines : Int -> Int -> List String -> List (Int, String)
expandLines _ _ [] = []
expandLines baseLine i (line::rest) =
  let trimmed = stringTrim line
  let text = if trimmed == "" then "--" else "-- " ++ trimmed
  (baseLine + i, text) :: expandLines baseLine (i + 1) rest

-- ── Phase 1: split into adjacent blocks ─────────────────────────────────────
-- A `--` bare comment or a gap in line numbers ends the current block.

splitIntoBlocks : List (Int, String) -> List (List (Int, String))
splitIntoBlocks comments = reverseL (blocksGo [] [] 0 comments)

blocksGo : List (List (Int, String)) -> List (Int, String) -> Int -> List (Int, String) -> List (List (Int, String))
blocksGo acc current _ [] =
  if isEmptyL current then
    acc
  else
    reverseL current :: acc
blocksGo acc current lastLine (c::rest)
  | isBlankComment c =
    let acc2 = if isEmptyL current then acc else reverseL current :: acc
    blocksGo acc2 [] (clLine c) rest
  | isEmptyL current || clLine c == lastLine + 1 =
    blocksGo acc (c::current) (clLine c) rest
  | otherwise = blocksGo (reverseL current :: acc) [c] (clLine c) rest

isEmptyL : List a -> Bool
isEmptyL [] = True
isEmptyL _ = False

-- ── Phase 2: extract examples from one adjacent block ───────────────────────

-- Carry the in-progress example: optional (input, line) and the reversed list
-- of expected lines accumulated so far.
sealExample : Option (String, Int) -> List String -> Option Example
sealExample None _ = None
sealExample (Some (inp, ln)) expectedRev =
  let exp = match reverseL expectedRev
    [] => None
    lines => Some (joinNl lines)
  Some (Example inp exp ln)

extractFromBlock : List (Int, String) -> List Example
extractFromBlock block = reverseL (extractGo [] None [] block)

extractGo : List Example -> Option (String, Int) -> List String -> List (Int, String) -> List Example
extractGo examples curInput expectedRev [] = match sealExample curInput expectedRev
  None => examples
  Some ex => ex::examples
extractGo examples curInput expectedRev (c::rest)
  | isInputLine c =
    let examples2 = match sealExample curInput expectedRev
      None => examples
      Some ex => ex::examples
    extractGo examples2 (Some (inputBody c, clLine c)) [] rest
  | isExpectedLine c = match curInput
    None => extractGo examples None [] rest
    Some _ => extractGo examples curInput (expectedBody c :: expectedRev) rest
  | otherwise =
    let examples2 = match sealExample curInput expectedRev
      None => examples
      Some ex => ex::examples
    extractGo examples2 None [] rest

-- ── Public extraction ───────────────────────────────────────────────────────

export extractExamples : List Comment -> List Example
extractExamples comments =
  let pairs = map commentToPair comments
  let expanded = concatMapC pairs
  flatMap extractFromBlock (splitIntoBlocks expanded)

commentToPair : Comment -> (Int, String)
commentToPair c = (commentLine c, commentText c)

concatMapC : List (Int, String) -> List (Int, String)
concatMapC [] = []
concatMapC (c::rest) = (if isBlockComment c then expandBlock c else [c])
  ++ concatMapC rest

-- ── Synthesizing the per-example binding ────────────────────────────────────
-- An example with an expected line is rendered through the user-facing `debug`
-- (so the comparison is against the language's own Debug contract, matching
-- ppValue (VString s) = s); a smoke example stays raw.

export synthName : Int -> String
synthName i = "__dt_" ++ intToString i ++ "__"

-- Build the synthetic source line for example i.
synthSrc : Int -> Example -> String
synthSrc i ex =
  let rhs = match exampleExpected ex
    Some _ => "debug (" ++ exampleInput ex ++ ")"
    None => exampleInput ex
  "\{synthName i} = \{rhs}"

-- All synth decls, parsed + desugared, concatenated.  (compiler `parse` panics
-- on a malformed snippet rather than per-example Error, but stdlib doctests
-- parse cleanly; see report.)
export buildSynthDecls : List Example -> List Decl
buildSynthDecls examples = buildSynthGo 0 examples

buildSynthGo : Int -> List Example -> List Decl
buildSynthGo _ [] = []
buildSynthGo i (ex::rest) = desugar (parse (synthSrc i ex))
  ++ buildSynthGo (i + 1) rest

-- ── Compare evaluated bindings against expected ──────────────────────────────
-- env is the post-run binding environment (Ok env) or a single whole-program
-- error (Err msg) applying to every example.

export buildDetails : Result String (List (String, Value e)) -> List Example -> <Mut | e> RunResult
buildDetails envResult examples =
  let details = detailsGo envResult 0 examples
  let passed = countResult isPass details
  let failed = countResult isFail details
  let errors = countResult isErr details
  RunResult (listLen examples) passed failed errors details

detailsGo : Result String (List (String, Value e)) -> Int -> List Example -> <Mut | e> List (Example, ExResult)
detailsGo _ _ [] = []
detailsGo envResult i (ex::rest) =
  (ex, oneResult envResult i ex) :: detailsGo envResult (i + 1) rest

oneResult : Result String (List (String, Value e)) -> Int -> Example -> <Mut | e> ExResult
oneResult (Err msg) i ex = Errored msg
oneResult (Ok env) i ex = match lookupBinding (synthName i) env
  None => Errored ("could not evaluate: " ++ exampleInput ex)
  Some v => compareValue ex (ppValue (force v))

compareValue : Example -> String -> ExResult
compareValue ex actual = match exampleExpected ex
  None => Pass
  Some exp => if actual == exp then Pass else Fail exp actual

isPass : ExResult -> Bool
isPass Pass = True
isPass _ = False

isFail : ExResult -> Bool
isFail (Fail _ _) = True
isFail _ = False

isErr : ExResult -> Bool
isErr (Errored _) = True
isErr _ = False

countResult : (ExResult -> Bool) -> List (Example, ExResult) -> Int
countResult _ [] = 0
countResult p ((_, r)::rest)
  | p r = 1 + countResult p rest
  | otherwise = countResult p rest

export hasUseDecls : List Decl -> Bool
hasUseDecls decls = anyUse decls

anyUse : List Decl -> Bool
anyUse [] = False
anyUse (d::rest) = isUse d || anyUse rest

isUse : Decl -> Bool
isUse (DUse _ _ _) = True
isUse _ = False
# DESUGAR
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DUse" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "lookupBinding" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "joinNl" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DData Public "Example" () ((variant "Example" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Int")))) ())
(DTypeSig true "exampleInput" (TyFun (TyCon "Example") (TyCon "String")))
(DFunDef false "exampleInput" ((PCon "Example" (PVar "i") PWild PWild)) (EVar "i"))
(DTypeSig false "exampleExpected" (TyFun (TyCon "Example") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "exampleExpected" ((PCon "Example" PWild (PVar "e") PWild)) (EVar "e"))
(DTypeSig true "exampleLine" (TyFun (TyCon "Example") (TyCon "Int")))
(DFunDef false "exampleLine" ((PCon "Example" PWild PWild (PVar "l"))) (EVar "l"))
(DData Public "ExResult" () ((variant "Pass" (ConPos)) (variant "Fail" (ConPos (TyCon "String") (TyCon "String"))) (variant "Errored" (ConPos (TyCon "String")))) ())
(DData Public "RunResult" () ((variant "RunResult" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult")))))) ())
(DTypeSig true "runPassed" (TyFun (TyCon "RunResult") (TyCon "Int")))
(DFunDef false "runPassed" ((PCon "RunResult" PWild (PVar "p") PWild PWild PWild)) (EVar "p"))
(DTypeSig true "runFailed" (TyFun (TyCon "RunResult") (TyCon "Int")))
(DFunDef false "runFailed" ((PCon "RunResult" PWild PWild (PVar "f") PWild PWild)) (EVar "f"))
(DTypeSig true "runErrors" (TyFun (TyCon "RunResult") (TyCon "Int")))
(DFunDef false "runErrors" ((PCon "RunResult" PWild PWild PWild (PVar "e") PWild)) (EVar "e"))
(DTypeSig true "runDetails" (TyFun (TyCon "RunResult") (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult")))))
(DFunDef false "runDetails" ((PCon "RunResult" PWild PWild PWild PWild (PVar "d"))) (EVar "d"))
(DTypeSig false "slen" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "slen" ((PVar "s")) (EApp (EVar "stringLength") (EVar "s")))
(DTypeSig false "substr3" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "substr3" ((PVar "a") (PVar "b") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))
(DTypeSig false "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "p") (PVar "s")) (EBlock (DoLet false false (PVar "lp") (EApp (EVar "slen") (EVar "p"))) (DoExpr (EIf (EBinOp "<" (EApp (EVar "slen") (EVar "s")) (EVar "lp")) (EVar "False") (EBinOp "==" (EApp (EApp (EApp (EVar "substr3") (ELit (LInt 0))) (EVar "lp")) (EVar "s")) (EVar "p"))))))
(DTypeSig false "splitNl" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitNl" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EApp (EVar "stringToChars") (EVar "s"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "splitNlGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitNlGo" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "substrChars") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EApp (EApp (EVar "substrChars") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "substrChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "substrChars" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "sliceChars") (EVar "cs")) (EVar "a")) (EVar "b"))))
(DTypeSig false "sliceChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Char"))))))
(DFunDef false "sliceChars" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sliceCharsGo") (EVar "cs")) (EVar "a")) (EVar "b"))))
(DTypeSig false "sliceCharsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sliceCharsGo" ((PVar "cs") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "a")) (EVar "cs")) (EApp (EApp (EApp (EVar "sliceCharsGo") (EVar "cs")) (EBinOp "+" (EVar "a") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "clText" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "clText" ((PTuple PWild (PVar "t"))) (EVar "t"))
(DTypeSig false "clLine" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Int")))
(DFunDef false "clLine" ((PTuple (PVar "l") PWild)) (EVar "l"))
(DTypeSig false "isInputLine" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isInputLine" ((PVar "c")) (EApp (EApp (EVar "startsWith") (ELit (LString "-- > "))) (EApp (EVar "clText") (EVar "c"))))
(DTypeSig false "inputBody" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "inputBody" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "clText") (EVar "c"))) (DoExpr (EApp (EApp (EApp (EVar "substr3") (ELit (LInt 5))) (EApp (EVar "slen") (EVar "t"))) (EVar "t")))))
(DTypeSig false "isExpectedLine" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isExpectedLine" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "clText") (EVar "c"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "-- "))) (EVar "t")) (EApp (EVar "not") (EApp (EVar "isInputLine") (EVar "c")))))))
(DTypeSig false "expectedBody" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "expectedBody" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "clText") (EVar "c"))) (DoExpr (EApp (EApp (EApp (EVar "substr3") (ELit (LInt 3))) (EApp (EVar "slen") (EVar "t"))) (EVar "t")))))
(DTypeSig false "isBlankComment" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isBlankComment" ((PVar "c")) (EBinOp "==" (EApp (EVar "clText") (EVar "c")) (ELit (LString "--"))))
(DTypeSig false "isBlockComment" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isBlockComment" ((PVar "c")) (EApp (EApp (EVar "startsWith") (ELit (LString "{-"))) (EApp (EVar "clText") (EVar "c"))))
(DTypeSig false "expandBlock" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "expandBlock" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "clText") (EVar "c"))) (DoLet false false (PVar "n") (EApp (EVar "slen") (EVar "t"))) (DoLet false false (PVar "inner") (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "substr3") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "expandLines") (EApp (EVar "clLine") (EVar "c"))) (ELit (LInt 0))) (EApp (EVar "splitNl") (EVar "inner"))))))
(DTypeSig false "expandLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))))
(DFunDef false "expandLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "expandLines" ((PVar "baseLine") (PVar "i") (PCons (PVar "line") (PVar "rest"))) (EBlock (DoLet false false (PVar "trimmed") (EApp (EVar "stringTrim") (EVar "line"))) (DoLet false false (PVar "text") (EIf (EBinOp "==" (EVar "trimmed") (ELit (LString ""))) (ELit (LString "--")) (EBinOp "++" (ELit (LString "-- ")) (EVar "trimmed")))) (DoExpr (EBinOp "::" (ETuple (EBinOp "+" (EVar "baseLine") (EVar "i")) (EVar "text")) (EApp (EApp (EApp (EVar "expandLines") (EVar "baseLine")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))))
(DTypeSig false "splitIntoBlocks" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "splitIntoBlocks" ((PVar "comments")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "blocksGo") (EListLit)) (EListLit)) (ELit (LInt 0))) (EVar "comments"))))
(DTypeSig false "blocksGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))))))
(DFunDef false "blocksGo" ((PVar "acc") (PVar "current") PWild (PList)) (EIf (EApp (EVar "isEmptyL") (EVar "current")) (EVar "acc") (EBinOp "::" (EApp (EVar "reverseL") (EVar "current")) (EVar "acc"))))
(DFunDef false "blocksGo" ((PVar "acc") (PVar "current") (PVar "lastLine") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EVar "isBlankComment") (EVar "c")) (EBlock (DoLet false false (PVar "acc2") (EIf (EApp (EVar "isEmptyL") (EVar "current")) (EVar "acc") (EBinOp "::" (EApp (EVar "reverseL") (EVar "current")) (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "blocksGo") (EVar "acc2")) (EListLit)) (EApp (EVar "clLine") (EVar "c"))) (EVar "rest")))) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "current")) (EBinOp "==" (EApp (EVar "clLine") (EVar "c")) (EBinOp "+" (EVar "lastLine") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EVar "blocksGo") (EVar "acc")) (EBinOp "::" (EVar "c") (EVar "current"))) (EApp (EVar "clLine") (EVar "c"))) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "blocksGo") (EBinOp "::" (EApp (EVar "reverseL") (EVar "current")) (EVar "acc"))) (EListLit (EVar "c"))) (EApp (EVar "clLine") (EVar "c"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyL" ((PList)) (EVar "True"))
(DFunDef false "isEmptyL" (PWild) (EVar "False"))
(DTypeSig false "sealExample" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Example")))))
(DFunDef false "sealExample" ((PCon "None") PWild) (EVar "None"))
(DFunDef false "sealExample" ((PCon "Some" (PTuple (PVar "inp") (PVar "ln"))) (PVar "expectedRev")) (EBlock (DoLet false false (PVar "exp") (EMatch (EApp (EVar "reverseL") (EVar "expectedRev")) (arm (PList) () (EVar "None")) (arm (PVar "lines") () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "lines")))))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Example") (EVar "inp")) (EVar "exp")) (EVar "ln"))))))
(DTypeSig false "extractFromBlock" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Example"))))
(DFunDef false "extractFromBlock" ((PVar "block")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "extractGo") (EListLit)) (EVar "None")) (EListLit)) (EVar "block"))))
(DTypeSig false "extractGo" (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Example")))))))
(DFunDef false "extractGo" ((PVar "examples") (PVar "curInput") (PVar "expectedRev") (PList)) (EMatch (EApp (EApp (EVar "sealExample") (EVar "curInput")) (EVar "expectedRev")) (arm (PCon "None") () (EVar "examples")) (arm (PCon "Some" (PVar "ex")) () (EBinOp "::" (EVar "ex") (EVar "examples")))))
(DFunDef false "extractGo" ((PVar "examples") (PVar "curInput") (PVar "expectedRev") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EVar "isInputLine") (EVar "c")) (EBlock (DoLet false false (PVar "examples2") (EMatch (EApp (EApp (EVar "sealExample") (EVar "curInput")) (EVar "expectedRev")) (arm (PCon "None") () (EVar "examples")) (arm (PCon "Some" (PVar "ex")) () (EBinOp "::" (EVar "ex") (EVar "examples"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "extractGo") (EVar "examples2")) (EApp (EVar "Some") (ETuple (EApp (EVar "inputBody") (EVar "c")) (EApp (EVar "clLine") (EVar "c"))))) (EListLit)) (EVar "rest")))) (EIf (EApp (EVar "isExpectedLine") (EVar "c")) (EMatch (EVar "curInput") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "extractGo") (EVar "examples")) (EVar "None")) (EListLit)) (EVar "rest"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "extractGo") (EVar "examples")) (EVar "curInput")) (EBinOp "::" (EApp (EVar "expectedBody") (EVar "c")) (EVar "expectedRev"))) (EVar "rest")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "examples2") (EMatch (EApp (EApp (EVar "sealExample") (EVar "curInput")) (EVar "expectedRev")) (arm (PCon "None") () (EVar "examples")) (arm (PCon "Some" (PVar "ex")) () (EBinOp "::" (EVar "ex") (EVar "examples"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "extractGo") (EVar "examples2")) (EVar "None")) (EListLit)) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "extractExamples" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Example"))))
(DFunDef false "extractExamples" ((PVar "comments")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (EVar "commentToPair")) (EVar "comments"))) (DoLet false false (PVar "expanded") (EApp (EVar "concatMapC") (EVar "pairs"))) (DoExpr (EApp (EApp (EVar "flatMap") (EVar "extractFromBlock")) (EApp (EVar "splitIntoBlocks") (EVar "expanded"))))))
(DTypeSig false "commentToPair" (TyFun (TyCon "Comment") (TyTuple (TyCon "Int") (TyCon "String"))))
(DFunDef false "commentToPair" ((PVar "c")) (ETuple (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "commentText") (EVar "c"))))
(DTypeSig false "concatMapC" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "concatMapC" ((PList)) (EListLit))
(DFunDef false "concatMapC" ((PCons (PVar "c") (PVar "rest"))) (EBinOp "++" (EIf (EApp (EVar "isBlockComment") (EVar "c")) (EApp (EVar "expandBlock") (EVar "c")) (EListLit (EVar "c"))) (EApp (EVar "concatMapC") (EVar "rest"))))
(DTypeSig true "synthName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "synthName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "__dt_")) (EApp (EVar "intToString") (EVar "i"))) (ELit (LString "__"))))
(DTypeSig false "synthSrc" (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyCon "String"))))
(DFunDef false "synthSrc" ((PVar "i") (PVar "ex")) (EBlock (DoLet false false (PVar "rhs") (EMatch (EApp (EVar "exampleExpected") (EVar "ex")) (arm (PCon "Some" PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "debug (")) (EApp (EVar "exampleInput") (EVar "ex"))) (ELit (LString ")")))) (arm (PCon "None") () (EApp (EVar "exampleInput") (EVar "ex"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "synthName") (EVar "i")))) (ELit (LString " = "))) (EApp (EVar "display") (EVar "rhs"))) (ELit (LString ""))))))
(DTypeSig true "buildSynthDecls" (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "buildSynthDecls" ((PVar "examples")) (EApp (EApp (EVar "buildSynthGo") (ELit (LInt 0))) (EVar "examples")))
(DTypeSig false "buildSynthGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "buildSynthGo" (PWild (PList)) (EListLit))
(DFunDef false "buildSynthGo" ((PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "++" (EApp (EVar "desugar") (EApp (EVar "parse") (EApp (EApp (EVar "synthSrc") (EVar "i")) (EVar "ex")))) (EApp (EApp (EVar "buildSynthGo") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "buildDetails" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect ("Mut") (Some "e") (TyCon "RunResult")))))
(DFunDef false "buildDetails" ((PVar "envResult") (PVar "examples")) (EBlock (DoLet false false (PVar "details") (EApp (EApp (EApp (EVar "detailsGo") (EVar "envResult")) (ELit (LInt 0))) (EVar "examples"))) (DoLet false false (PVar "passed") (EApp (EApp (EVar "countResult") (EVar "isPass")) (EVar "details"))) (DoLet false false (PVar "failed") (EApp (EApp (EVar "countResult") (EVar "isFail")) (EVar "details"))) (DoLet false false (PVar "errors") (EApp (EApp (EVar "countResult") (EVar "isErr")) (EVar "details"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (EApp (EVar "listLen") (EVar "examples"))) (EVar "passed")) (EVar "failed")) (EVar "errors")) (EVar "details")))))
(DTypeSig false "detailsGo" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect ("Mut") (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult"))))))))
(DFunDef false "detailsGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "detailsGo" ((PVar "envResult") (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "ex") (EApp (EApp (EApp (EVar "oneResult") (EVar "envResult")) (EVar "i")) (EVar "ex"))) (EApp (EApp (EApp (EVar "detailsGo") (EVar "envResult")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "oneResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyEffect ("Mut") (Some "e") (TyCon "ExResult"))))))
(DFunDef false "oneResult" ((PCon "Err" (PVar "msg")) (PVar "i") (PVar "ex")) (EApp (EVar "Errored") (EVar "msg")))
(DFunDef false "oneResult" ((PCon "Ok" (PVar "env")) (PVar "i") (PVar "ex")) (EMatch (EApp (EApp (EVar "lookupBinding") (EApp (EVar "synthName") (EVar "i"))) (EVar "env")) (arm (PCon "None") () (EApp (EVar "Errored") (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EVar "exampleInput") (EVar "ex"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "compareValue") (EVar "ex")) (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))))))
(DTypeSig false "compareValue" (TyFun (TyCon "Example") (TyFun (TyCon "String") (TyCon "ExResult"))))
(DFunDef false "compareValue" ((PVar "ex") (PVar "actual")) (EMatch (EApp (EVar "exampleExpected") (EVar "ex")) (arm (PCon "None") () (EVar "Pass")) (arm (PCon "Some" (PVar "exp")) () (EIf (EBinOp "==" (EVar "actual") (EVar "exp")) (EVar "Pass") (EApp (EApp (EVar "Fail") (EVar "exp")) (EVar "actual"))))))
(DTypeSig false "isPass" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "isPass" ((PCon "Pass")) (EVar "True"))
(DFunDef false "isPass" (PWild) (EVar "False"))
(DTypeSig false "isFail" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "isFail" ((PCon "Fail" PWild PWild)) (EVar "True"))
(DFunDef false "isFail" (PWild) (EVar "False"))
(DTypeSig false "isErr" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "isErr" ((PCon "Errored" PWild)) (EVar "True"))
(DFunDef false "isErr" (PWild) (EVar "False"))
(DTypeSig false "countResult" (TyFun (TyFun (TyCon "ExResult") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult"))) (TyCon "Int"))))
(DFunDef false "countResult" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countResult" ((PVar "p") (PCons (PTuple PWild (PVar "r")) (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "r")) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "countResult") (EVar "p")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "countResult") (EVar "p")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "hasUseDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasUseDecls" ((PVar "decls")) (EApp (EVar "anyUse") (EVar "decls")))
(DTypeSig false "anyUse" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "anyUse" ((PList)) (EVar "False"))
(DFunDef false "anyUse" ((PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "isUse") (EVar "d")) (EApp (EVar "anyUse") (EVar "rest"))))
(DTypeSig false "isUse" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isUse" ((PCon "DUse" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isUse" (PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DUse" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "lookupBinding" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "joinNl" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DData Public "Example" () ((variant "Example" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Int")))) ())
(DTypeSig true "exampleInput" (TyFun (TyCon "Example") (TyCon "String")))
(DFunDef false "exampleInput" ((PCon "Example" (PVar "i") PWild PWild)) (EVar "i"))
(DTypeSig false "exampleExpected" (TyFun (TyCon "Example") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "exampleExpected" ((PCon "Example" PWild (PVar "e") PWild)) (EVar "e"))
(DTypeSig true "exampleLine" (TyFun (TyCon "Example") (TyCon "Int")))
(DFunDef false "exampleLine" ((PCon "Example" PWild PWild (PVar "l"))) (EVar "l"))
(DData Public "ExResult" () ((variant "Pass" (ConPos)) (variant "Fail" (ConPos (TyCon "String") (TyCon "String"))) (variant "Errored" (ConPos (TyCon "String")))) ())
(DData Public "RunResult" () ((variant "RunResult" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult")))))) ())
(DTypeSig true "runPassed" (TyFun (TyCon "RunResult") (TyCon "Int")))
(DFunDef false "runPassed" ((PCon "RunResult" PWild (PVar "p") PWild PWild PWild)) (EVar "p"))
(DTypeSig true "runFailed" (TyFun (TyCon "RunResult") (TyCon "Int")))
(DFunDef false "runFailed" ((PCon "RunResult" PWild PWild (PVar "f") PWild PWild)) (EVar "f"))
(DTypeSig true "runErrors" (TyFun (TyCon "RunResult") (TyCon "Int")))
(DFunDef false "runErrors" ((PCon "RunResult" PWild PWild PWild (PVar "e") PWild)) (EVar "e"))
(DTypeSig true "runDetails" (TyFun (TyCon "RunResult") (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult")))))
(DFunDef false "runDetails" ((PCon "RunResult" PWild PWild PWild PWild (PVar "d"))) (EVar "d"))
(DTypeSig false "slen" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "slen" ((PVar "s")) (EApp (EVar "stringLength") (EVar "s")))
(DTypeSig false "substr3" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "substr3" ((PVar "a") (PVar "b") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))
(DTypeSig false "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "p") (PVar "s")) (EBlock (DoLet false false (PVar "lp") (EApp (EVar "slen") (EVar "p"))) (DoExpr (EIf (EBinOp "<" (EApp (EVar "slen") (EVar "s")) (EVar "lp")) (EVar "False") (EBinOp "==" (EApp (EApp (EApp (EVar "substr3") (ELit (LInt 0))) (EVar "lp")) (EVar "s")) (EVar "p"))))))
(DTypeSig false "splitNl" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitNl" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EApp (EVar "stringToChars") (EVar "s"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "splitNlGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitNlGo" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "substrChars") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EApp (EApp (EVar "substrChars") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "substrChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "substrChars" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "sliceChars") (EVar "cs")) (EVar "a")) (EVar "b"))))
(DTypeSig false "sliceChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Char"))))))
(DFunDef false "sliceChars" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sliceCharsGo") (EVar "cs")) (EVar "a")) (EVar "b"))))
(DTypeSig false "sliceCharsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sliceCharsGo" ((PVar "cs") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "a")) (EVar "cs")) (EApp (EApp (EApp (EVar "sliceCharsGo") (EVar "cs")) (EBinOp "+" (EVar "a") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "clText" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "clText" ((PTuple PWild (PVar "t"))) (EVar "t"))
(DTypeSig false "clLine" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Int")))
(DFunDef false "clLine" ((PTuple (PVar "l") PWild)) (EVar "l"))
(DTypeSig false "isInputLine" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isInputLine" ((PVar "c")) (EApp (EApp (EVar "startsWith") (ELit (LString "-- > "))) (EApp (EVar "clText") (EVar "c"))))
(DTypeSig false "inputBody" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "inputBody" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "clText") (EVar "c"))) (DoExpr (EApp (EApp (EApp (EVar "substr3") (ELit (LInt 5))) (EApp (EVar "slen") (EVar "t"))) (EVar "t")))))
(DTypeSig false "isExpectedLine" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isExpectedLine" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "clText") (EVar "c"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "-- "))) (EVar "t")) (EApp (EVar "not") (EApp (EVar "isInputLine") (EVar "c")))))))
(DTypeSig false "expectedBody" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "expectedBody" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "clText") (EVar "c"))) (DoExpr (EApp (EApp (EApp (EVar "substr3") (ELit (LInt 3))) (EApp (EVar "slen") (EVar "t"))) (EVar "t")))))
(DTypeSig false "isBlankComment" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isBlankComment" ((PVar "c")) (EBinOp "==" (EApp (EVar "clText") (EVar "c")) (ELit (LString "--"))))
(DTypeSig false "isBlockComment" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isBlockComment" ((PVar "c")) (EApp (EApp (EVar "startsWith") (ELit (LString "{-"))) (EApp (EVar "clText") (EVar "c"))))
(DTypeSig false "expandBlock" (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "expandBlock" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "clText") (EVar "c"))) (DoLet false false (PVar "n") (EApp (EVar "slen") (EVar "t"))) (DoLet false false (PVar "inner") (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "substr3") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "expandLines") (EApp (EVar "clLine") (EVar "c"))) (ELit (LInt 0))) (EApp (EVar "splitNl") (EVar "inner"))))))
(DTypeSig false "expandLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))))
(DFunDef false "expandLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "expandLines" ((PVar "baseLine") (PVar "i") (PCons (PVar "line") (PVar "rest"))) (EBlock (DoLet false false (PVar "trimmed") (EApp (EVar "stringTrim") (EVar "line"))) (DoLet false false (PVar "text") (EIf (EBinOp "==" (EVar "trimmed") (ELit (LString ""))) (ELit (LString "--")) (EBinOp "++" (ELit (LString "-- ")) (EVar "trimmed")))) (DoExpr (EBinOp "::" (ETuple (EBinOp "+" (EVar "baseLine") (EVar "i")) (EVar "text")) (EApp (EApp (EApp (EVar "expandLines") (EVar "baseLine")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))))
(DTypeSig false "splitIntoBlocks" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "splitIntoBlocks" ((PVar "comments")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "blocksGo") (EListLit)) (EListLit)) (ELit (LInt 0))) (EVar "comments"))))
(DTypeSig false "blocksGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))))))
(DFunDef false "blocksGo" ((PVar "acc") (PVar "current") PWild (PList)) (EIf (EApp (EVar "isEmptyL") (EVar "current")) (EVar "acc") (EBinOp "::" (EApp (EVar "reverseL") (EVar "current")) (EVar "acc"))))
(DFunDef false "blocksGo" ((PVar "acc") (PVar "current") (PVar "lastLine") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EVar "isBlankComment") (EVar "c")) (EBlock (DoLet false false (PVar "acc2") (EIf (EApp (EVar "isEmptyL") (EVar "current")) (EVar "acc") (EBinOp "::" (EApp (EVar "reverseL") (EVar "current")) (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "blocksGo") (EVar "acc2")) (EListLit)) (EApp (EVar "clLine") (EVar "c"))) (EVar "rest")))) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "current")) (EBinOp "==" (EApp (EVar "clLine") (EVar "c")) (EBinOp "+" (EVar "lastLine") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EVar "blocksGo") (EVar "acc")) (EBinOp "::" (EVar "c") (EVar "current"))) (EApp (EVar "clLine") (EVar "c"))) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "blocksGo") (EBinOp "::" (EApp (EVar "reverseL") (EVar "current")) (EVar "acc"))) (EListLit (EVar "c"))) (EApp (EVar "clLine") (EVar "c"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyL" ((PList)) (EVar "True"))
(DFunDef false "isEmptyL" (PWild) (EVar "False"))
(DTypeSig false "sealExample" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Example")))))
(DFunDef false "sealExample" ((PCon "None") PWild) (EVar "None"))
(DFunDef false "sealExample" ((PCon "Some" (PTuple (PVar "inp") (PVar "ln"))) (PVar "expectedRev")) (EBlock (DoLet false false (PVar "exp") (EMatch (EApp (EVar "reverseL") (EVar "expectedRev")) (arm (PList) () (EVar "None")) (arm (PVar "lines") () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "lines")))))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Example") (EVar "inp")) (EVar "exp")) (EVar "ln"))))))
(DTypeSig false "extractFromBlock" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Example"))))
(DFunDef false "extractFromBlock" ((PVar "block")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "extractGo") (EListLit)) (EVar "None")) (EListLit)) (EVar "block"))))
(DTypeSig false "extractGo" (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Example")))))))
(DFunDef false "extractGo" ((PVar "examples") (PVar "curInput") (PVar "expectedRev") (PList)) (EMatch (EApp (EApp (EVar "sealExample") (EVar "curInput")) (EVar "expectedRev")) (arm (PCon "None") () (EVar "examples")) (arm (PCon "Some" (PVar "ex")) () (EBinOp "::" (EVar "ex") (EVar "examples")))))
(DFunDef false "extractGo" ((PVar "examples") (PVar "curInput") (PVar "expectedRev") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EVar "isInputLine") (EVar "c")) (EBlock (DoLet false false (PVar "examples2") (EMatch (EApp (EApp (EVar "sealExample") (EVar "curInput")) (EVar "expectedRev")) (arm (PCon "None") () (EVar "examples")) (arm (PCon "Some" (PVar "ex")) () (EBinOp "::" (EVar "ex") (EVar "examples"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "extractGo") (EVar "examples2")) (EApp (EVar "Some") (ETuple (EApp (EVar "inputBody") (EVar "c")) (EApp (EVar "clLine") (EVar "c"))))) (EListLit)) (EVar "rest")))) (EIf (EApp (EVar "isExpectedLine") (EVar "c")) (EMatch (EVar "curInput") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "extractGo") (EVar "examples")) (EVar "None")) (EListLit)) (EVar "rest"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "extractGo") (EVar "examples")) (EVar "curInput")) (EBinOp "::" (EApp (EVar "expectedBody") (EVar "c")) (EVar "expectedRev"))) (EVar "rest")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "examples2") (EMatch (EApp (EApp (EVar "sealExample") (EVar "curInput")) (EVar "expectedRev")) (arm (PCon "None") () (EVar "examples")) (arm (PCon "Some" (PVar "ex")) () (EBinOp "::" (EVar "ex") (EVar "examples"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "extractGo") (EVar "examples2")) (EVar "None")) (EListLit)) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "extractExamples" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Example"))))
(DFunDef false "extractExamples" ((PVar "comments")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (EVar "commentToPair")) (EVar "comments"))) (DoLet false false (PVar "expanded") (EApp (EVar "concatMapC") (EVar "pairs"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EVar "extractFromBlock")) (EApp (EVar "splitIntoBlocks") (EVar "expanded"))))))
(DTypeSig false "commentToPair" (TyFun (TyCon "Comment") (TyTuple (TyCon "Int") (TyCon "String"))))
(DFunDef false "commentToPair" ((PVar "c")) (ETuple (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "commentText") (EVar "c"))))
(DTypeSig false "concatMapC" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "concatMapC" ((PList)) (EListLit))
(DFunDef false "concatMapC" ((PCons (PVar "c") (PVar "rest"))) (EBinOp "++" (EIf (EApp (EVar "isBlockComment") (EVar "c")) (EApp (EVar "expandBlock") (EVar "c")) (EListLit (EVar "c"))) (EApp (EVar "concatMapC") (EVar "rest"))))
(DTypeSig true "synthName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "synthName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "__dt_")) (EApp (EVar "intToString") (EVar "i"))) (ELit (LString "__"))))
(DTypeSig false "synthSrc" (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyCon "String"))))
(DFunDef false "synthSrc" ((PVar "i") (PVar "ex")) (EBlock (DoLet false false (PVar "rhs") (EMatch (EApp (EVar "exampleExpected") (EVar "ex")) (arm (PCon "Some" PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "debug (")) (EApp (EVar "exampleInput") (EVar "ex"))) (ELit (LString ")")))) (arm (PCon "None") () (EApp (EVar "exampleInput") (EVar "ex"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "synthName") (EVar "i")))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EVar "rhs"))) (ELit (LString ""))))))
(DTypeSig true "buildSynthDecls" (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "buildSynthDecls" ((PVar "examples")) (EApp (EApp (EVar "buildSynthGo") (ELit (LInt 0))) (EVar "examples")))
(DTypeSig false "buildSynthGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "buildSynthGo" (PWild (PList)) (EListLit))
(DFunDef false "buildSynthGo" ((PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "++" (EApp (EVar "desugar") (EApp (EVar "parse") (EApp (EApp (EVar "synthSrc") (EVar "i")) (EVar "ex")))) (EApp (EApp (EVar "buildSynthGo") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "buildDetails" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect ("Mut") (Some "e") (TyCon "RunResult")))))
(DFunDef false "buildDetails" ((PVar "envResult") (PVar "examples")) (EBlock (DoLet false false (PVar "details") (EApp (EApp (EApp (EVar "detailsGo") (EVar "envResult")) (ELit (LInt 0))) (EVar "examples"))) (DoLet false false (PVar "passed") (EApp (EApp (EVar "countResult") (EVar "isPass")) (EVar "details"))) (DoLet false false (PVar "failed") (EApp (EApp (EVar "countResult") (EVar "isFail")) (EVar "details"))) (DoLet false false (PVar "errors") (EApp (EApp (EVar "countResult") (EVar "isErr")) (EVar "details"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (EApp (EVar "listLen") (EVar "examples"))) (EVar "passed")) (EVar "failed")) (EVar "errors")) (EVar "details")))))
(DTypeSig false "detailsGo" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect ("Mut") (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult"))))))))
(DFunDef false "detailsGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "detailsGo" ((PVar "envResult") (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "ex") (EApp (EApp (EApp (EVar "oneResult") (EVar "envResult")) (EVar "i")) (EVar "ex"))) (EApp (EApp (EApp (EVar "detailsGo") (EVar "envResult")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "oneResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyEffect ("Mut") (Some "e") (TyCon "ExResult"))))))
(DFunDef false "oneResult" ((PCon "Err" (PVar "msg")) (PVar "i") (PVar "ex")) (EApp (EVar "Errored") (EVar "msg")))
(DFunDef false "oneResult" ((PCon "Ok" (PVar "env")) (PVar "i") (PVar "ex")) (EMatch (EApp (EApp (EVar "lookupBinding") (EApp (EVar "synthName") (EVar "i"))) (EVar "env")) (arm (PCon "None") () (EApp (EVar "Errored") (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EVar "exampleInput") (EVar "ex"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "compareValue") (EVar "ex")) (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))))))
(DTypeSig false "compareValue" (TyFun (TyCon "Example") (TyFun (TyCon "String") (TyCon "ExResult"))))
(DFunDef false "compareValue" ((PVar "ex") (PVar "actual")) (EMatch (EApp (EVar "exampleExpected") (EVar "ex")) (arm (PCon "None") () (EVar "Pass")) (arm (PCon "Some" (PVar "exp")) () (EIf (EBinOp "==" (EVar "actual") (EVar "exp")) (EVar "Pass") (EApp (EApp (EVar "Fail") (EVar "exp")) (EVar "actual"))))))
(DTypeSig false "isPass" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "isPass" ((PCon "Pass")) (EVar "True"))
(DFunDef false "isPass" (PWild) (EVar "False"))
(DTypeSig false "isFail" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "isFail" ((PCon "Fail" PWild PWild)) (EVar "True"))
(DFunDef false "isFail" (PWild) (EVar "False"))
(DTypeSig false "isErr" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "isErr" ((PCon "Errored" PWild)) (EVar "True"))
(DFunDef false "isErr" (PWild) (EVar "False"))
(DTypeSig false "countResult" (TyFun (TyFun (TyCon "ExResult") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult"))) (TyCon "Int"))))
(DFunDef false "countResult" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countResult" ((PVar "p") (PCons (PTuple PWild (PVar "r")) (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "r")) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "countResult") (EVar "p")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "countResult") (EVar "p")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "hasUseDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasUseDecls" ((PVar "decls")) (EApp (EVar "anyUse") (EVar "decls")))
(DTypeSig false "anyUse" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "anyUse" ((PList)) (EVar "False"))
(DFunDef false "anyUse" ((PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "isUse") (EVar "d")) (EApp (EVar "anyUse") (EVar "rest"))))
(DTypeSig false "isUse" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isUse" ((PCon "DUse" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isUse" (PWild) (EVar "False"))
