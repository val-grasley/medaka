# META
source_lines=461
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lsp_harness.mdk — a Medaka-native test harness that drives the
-- native `medaka lsp` binary over real JSON-RPC and asserts on the framed
-- responses.  Dogfoods the language (json + strings + runCommand + file IO) and
-- mimics how Cursor/VSCode talk to the server.
--
-- BATCH model: the LSP reads stdin to EOF and emits all responses when fed a
-- complete script ending in `exit`.  So we frame the whole request sequence,
-- write it to a temp file, run `sh -c "<medaka> lsp < tmp"` (runCommand inherits
-- the parent env, so MEDAKA_ROOT reaches the child), capture stdout, and parse
-- the response frames.  No interactive pipe / new primitive needed — every
-- request fires at a known position, independent of prior responses.
--
-- The byte-accurate frame parser IS the frame-integrity check: it honors the
-- byte-counted Content-Length against codepoint-oriented strings by walking the
-- codepoint array summing each codepoint's UTF-8 width (mirror of lsp.mdk's
-- utf8CharWidth).  A Content-Length that doesn't match the real body byte length
-- (the bug that crashed Cursor) shows up as a non-byteValid frame or a desync.

import json.{
  Json,
  JNull,
  JBool,
  JInt,
  JString,
  JArray,
  JObject,
  jObject,
  jArray,
  stringify,
  parse,
  lookup,
  asString,
  asInt,
}
import support.util.{utf8Len, utf8CharWidth}
import string.{isDigit}

-- ── JSON-RPC message builders ───────────────────────────────────────────────

export initializeMsg : Int -> Json
initializeMsg idn = jObject
  [
    ("jsonrpc", JString "2.0"),
    ("id", JInt idn),
    ("method", JString "initialize"),
    ("params", jObject [("capabilities", jObject [])]),
  ]

export initializedMsg : Json
initializedMsg = jObject
  [
    ("jsonrpc", JString "2.0"),
    ("method", JString "initialized"),
    ("params", jObject []),
  ]

export didOpenMsg : String -> String -> Json
didOpenMsg uri text = jObject
  [
    ("jsonrpc", JString "2.0"),
    ("method", JString "textDocument/didOpen"),
    (
      "params",
      jObject [
        (
          "textDocument",
          jObject [
            ("uri", JString uri),
            ("languageId", JString "medaka"),
            ("version", JInt 1),
            ("text", JString text),
          ],
        )
      ],
    ),
  ]

export requestMsg : Int -> String -> Json -> Json
requestMsg idn method params = jObject
  [
    ("jsonrpc", JString "2.0"),
    ("id", JInt idn),
    ("method", JString method),
    ("params", params),
  ]

-- textDocument/didChange (Full sync): the whole document is replaced by `text`.
-- Drives the per-keystroke diagnostics path the parse-cache optimizes.
export didChangeMsg : String -> String -> Json
didChangeMsg uri text = jObject
  [
    ("jsonrpc", JString "2.0"),
    ("method", JString "textDocument/didChange"),
    (
      "params",
      jObject [
        ("textDocument", jObject [("uri", JString uri), ("version", JInt 2)]),
        ("contentChanges", jArray [jObject [("text", JString text)]]),
      ],
    ),
  ]

-- params for a text-document request carrying a cursor position (hover etc.).
export docPosParams : String -> Int -> Int -> Json
docPosParams uri line ch = jObject
  [
    ("textDocument", jObject [("uri", JString uri)]),
    ("position", jObject [("line", JInt line), ("character", JInt ch)]),
  ]

-- params for a whole-document request (documentSymbol etc.).
export docParams : String -> Json
docParams uri = jObject [("textDocument", jObject [("uri", JString uri)])]

export shutdownMsg : Int -> Json
shutdownMsg idn = jObject
  [("jsonrpc", JString "2.0"), ("id", JInt idn), ("method", JString "shutdown")]

export exitMsg : Json
exitMsg = jObject [("jsonrpc", JString "2.0"), ("method", JString "exit")]

-- ── framing (byte-counted Content-Length) ──────────────────────────────────
-- utf8Len / utf8CharWidth moved to support/util.mdk (imported above).

-- One Content-Length-framed packet.
export frame : Json -> String
frame j =
  let body = stringify j
  stringConcat
    ["Content-Length: ", intToString (utf8Len body), "\r\n\r\n", body]

-- ── session runner (batch over a temp file) ─────────────────────────────────

-- Drive `<medakaBin> lsp` with the framed message sequence; return raw stdout
-- (the concatenated response frames + the LSP's trailing unit print).
export runSession : String -> List Json -> <IO> Result String String
runSession medakaBin msgs =
  let req = stringConcat (map frame msgs)
  let tmp = "/tmp/medaka_lsp_harness_req.txt"
  let _ = writeFile tmp req
  map
    ((code, out, errOut) => out)
    (runCommand "sh" ["-c", stringConcat [medakaBin, " lsp < ", tmp]])

-- ── byte-accurate frame parser (this IS the integrity check) ────────────────
-- Frame declaredLen body byteValid.  byteValid = exactly `declaredLen` bytes were
-- consumed landing on a codepoint boundary.

public export data Frame = Frame Int String Bool

-- (frames, cleanlyConsumed).  cleanlyConsumed = every frame boundary landed on a
-- header and the tail held only the trailing unit-print (`0`/`()`/whitespace).
export parseFrames : String -> (List Frame, Bool)
parseFrames s =
  let arr = stringToChars s
  pfGo s arr (arrayLength arr) 0

clLabel : String
clLabel = "Content-Length:"

pfGo : String -> Array Char -> Int -> Int -> (List Frame, Bool)
pfGo s arr len i =
  if i >= len then ([], True)
  else
    if isTrailingJunk arr len i then ([], True)
    else
      if matchesAt arr len i clLabel then match parseHeader arr len i
        None => ([], False)
        Some (n, bodyStart) => match takeBytes arr len bodyStart n
          None => ([Frame n "" False], False)
          Some bodyEnd =>
            let body = stringSlice bodyStart bodyEnd s
            match pfGo s arr len bodyEnd
              (rest, clean) => (Frame n body True :: rest, clean)
      else ([], False)

-- Everything from i to end is trailing junk (the LSP's `0` unit-print + ws).
isTrailingJunk : Array Char -> Int -> Int -> Bool
isTrailingJunk arr len i
  | i >= len = True
  | isJunkChar (arrayGetUnsafe i arr) = isTrailingJunk arr len (i + 1)
  | otherwise = False

isJunkChar : Char -> Bool
isJunkChar c = c == '0'
  || c == '\n'
  || c == '\r'
  || c == ' '
  || c == '('
  || c == ')'

-- Does the codepoint run at `i` equal the literal `lit`?
matchesAt : Array Char -> Int -> Int -> String -> Bool
matchesAt arr len i lit =
  let larr = stringToChars lit
  matchesGo arr len i larr 0 (arrayLength larr)

matchesGo : Array Char -> Int -> Int -> Array Char -> Int -> Int -> Bool
matchesGo arr len i larr j llen
  | j >= llen = True
  | i + j >= len = False
  | arrayGetUnsafe (i + j) arr == arrayGetUnsafe j larr =
    matchesGo arr len i larr (j + 1) llen
  | otherwise = False

-- At `i` (== clLabel): skip label + spaces, read digits, expect "\r\n\r\n".
-- Returns (contentLength, bodyStartIndex).  Header bytes are ASCII so codepoint
-- index == byte index here.
parseHeader : Array Char -> Int -> Int -> Option (Int, Int)
parseHeader arr len i =
  let afterLabel = i + stringLength clLabel
  let numStart = skipSpaces arr len afterLabel
  match parseDigits arr len numStart 0 False
    None => None
    Some (n, afterNum) =>
      if matchesAt arr len afterNum "\r\n\r\n" then
        Some (n, afterNum + 4)
      else
        None

skipSpaces : Array Char -> Int -> Int -> Int
skipSpaces arr len i
  | i >= len = i
  | arrayGetUnsafe i arr == ' ' = skipSpaces arr len (i + 1)
  | otherwise = i

parseDigits : Array Char -> Int -> Int -> Int -> Bool -> Option (Int, Int)
parseDigits arr len i acc seen
  | i >= len = if seen then Some (acc, i) else None
  | isDigit (arrayGetUnsafe i arr) = parseDigits arr len (i + 1) (acc * 10 + (charCode (arrayGetUnsafe i arr) - 48)) True
  | otherwise = if seen then Some (acc, i) else None

-- Consume `remaining` BYTES from codepoint `i`; Some end-index on an exact
-- boundary, None if a codepoint straddles the boundary or the stream runs out.
takeBytes : Array Char -> Int -> Int -> Int -> Option Int
takeBytes arr len i remaining
  | remaining == 0 = Some i
  | i >= len = None
  | otherwise =
    let w = utf8CharWidth (charCode (arrayGetUnsafe i arr))
    if w > remaining then None else takeBytes arr len (i + 1) (remaining - w)

-- ── response accessors ──────────────────────────────────────────────────────

-- Every frame byteValid?
export allByteValid : List Frame -> Bool
allByteValid [] = True
allByteValid ((Frame _ _ ok)::rest) = ok && allByteValid rest

-- The response frame whose "id" == idn, parsed.
export responseById : Int -> List Frame -> Option Json
responseById _ [] = None
responseById idn ((Frame _ body _)::rest) = match parse body
  Ok j => match lookup "id" j
    Some v => match asInt v
      Some k => if k == idn then Some j else responseById idn rest
      None => responseById idn rest
    None => responseById idn rest
  Err _ => responseById idn rest

-- result.contents.value of hover response `idn` (the markdown ```medaka\n<name> :
-- <ty>\n``` string), or None.
export hoverValue : Int -> List Frame -> Option String
hoverValue idn frames = do
  j <- responseById idn frames
  res <- lookup "result" j
  c <- lookup "contents" res
  v <- lookup "value" c
  asString v

-- Does completion response `idn` include a CompletionItem whose label == needle?
export completionHasLabel : Int -> List Frame -> String -> Bool
completionHasLabel idn frames needle = match responseById idn frames
  None => False
  Some j => match lookup "result" j
    Some (JArray items) => anyLabelEq items 0 (arrayLength items) needle
    _ => False

anyLabelEq : Array Json -> Int -> Int -> String -> Bool
anyLabelEq items i n needle
  | i >= n = False
  | labelEq (arrayGetUnsafe i items) needle = True
  | otherwise = anyLabelEq items (i + 1) n needle

labelEq : Json -> String -> Bool
labelEq it needle = match lookup "label" it
  Some v => match asString v
    Some s => s == needle
    None => False
  None => False

-- Does `hay` contain `needle` as a substring? (reuses the module's matchesAt).
export strContains : String -> String -> Bool
strContains hay needle =
  let h = stringToChars hay
  strContainsGo h (arrayLength h) needle 0

strContainsGo : Array Char -> Int -> String -> Int -> Bool
strContainsGo h hlen needle i
  | i >= hlen = False
  | matchesAt h hlen i needle = True
  | otherwise = strContainsGo h hlen needle (i + 1)

{- ── semanticTokens/full decode ──────────────────────────────────────────────
   The response carries `result.data`: a flat int array, 5 ints per token
   (`deltaLine, deltaChar, length, tokenType, modifiers`).  We pull it out, undo
   the delta encoding back to absolute (line, char, length, tokenType) tuples,
   and assert the `List (Expr, Expr) -> Expr` fixture's three length-4 `Expr`
   tokens all share one tokenType (the reported-bug acceptance check). -}

-- result.data of response `idn` as a List Int, or None.
export semanticData : Int -> List Frame -> Option (List Int)
semanticData idn frames = match responseById idn frames
  None => None
  Some j => match lookup "result" j
    None => None
    Some res => match lookup "data" res
      Some (JArray a) => Some (jIntArrayToList a 0 (arrayLength a))
      _ => None

jIntArrayToList : Array Json -> Int -> Int -> List Int
jIntArrayToList a i n
  | i >= n = []
  | otherwise = match asInt (arrayGetUnsafe i a)
    Some k => k :: jIntArrayToList a (i + 1) n
    None => jIntArrayToList a (i + 1) n

-- A decoded absolute token: line, char, length, tokenType.
public export data DecTok = DecTok Int Int Int Int

-- Undo delta encoding: walk the flat 5-int stream, tracking prevLine/prevChar.
export decodeSemToks : List Int -> List DecTok
decodeSemToks ints = decodeGo 0 0 ints

decodeGo : Int -> Int -> List Int -> List DecTok
decodeGo prevLine prevChar (dl::dc::len::ty::_mod::rest) =
  let line = prevLine + dl
  let ch = if dl == 0 then prevChar + dc else dc
  DecTok line ch len ty :: decodeGo line ch rest
decodeGo _ _ _ = []

-- All length-`len` tokens share one tokenType AND there are at least `minCount`
-- of them.  For the fixture: the three length-4 `Expr` tokens, same type.
export lenTokensShareType : Int -> Int -> List DecTok -> Bool
lenTokensShareType len minCount toks =
  let matching = filterLen len toks
  match matching
    [] => False
    (DecTok _ _ _ ty0)::_ => countToks matching >= minCount
      && allSameType ty0 matching

filterLen : Int -> List DecTok -> List DecTok
filterLen _ [] = []
filterLen len ((DecTok l c ln ty)::rest)
  | ln == len = DecTok l c ln ty :: filterLen len rest
  | otherwise = filterLen len rest

countToks : List DecTok -> Int
countToks [] = 0
countToks (_::rest) = 1 + countToks rest

allSameType : Int -> List DecTok -> Bool
allSameType _ [] = True
allSameType ty0 ((DecTok _ _ _ ty)::rest) = ty == ty0 && allSameType ty0 rest

-- Does the decoded token stream contain at least one token of legend type `ty`?
-- Used to assert the classifier emits DISTINCT types (e.g. type=1 AND
-- enumMember=2 both present → it separates types from constructors).
export hasTokenType : Int -> List DecTok -> Bool
hasTokenType _ [] = False
hasTokenType ty ((DecTok _ _ _ t)::rest) = t == ty || hasTokenType ty rest

-- Total diagnostics across every publishDiagnostics notification for `uri`.
-- (Threshold checks — ==0 / >=1 — so summing across republishes is fine.)
export diagCountFor : String -> List Frame -> Int
diagCountFor _ [] = 0
diagCountFor uri ((Frame _ body _)::rest) = match parse body
  Ok j =>
    if isPublishFor uri j then
      jDiagLen j + diagCountFor uri rest
    else
      diagCountFor uri rest
  Err _ => diagCountFor uri rest

isPublishFor : String -> Json -> Bool
isPublishFor uri j = methodEq j "textDocument/publishDiagnostics"
  && paramUriEq j uri

-- Was a publishDiagnostics notification emitted at all for `uri`?  Guards against
-- a vacuous `diagCountFor … == 0` when the LSP never published for that file.
export diagPublishedFor : String -> List Frame -> Bool
diagPublishedFor _ [] = False
diagPublishedFor uri ((Frame _ body _)::rest) = match parse body
  Ok j => if isPublishFor uri j then True else diagPublishedFor uri rest
  Err _ => diagPublishedFor uri rest

-- The diagnostic count of the LAST publishDiagnostics for `uri` (its CONVERGED
-- state after a burst of edits).  Proves the parse-cache re-analyzed the changed
-- entry buffer each keystroke rather than serving a stale parse: the final publish
-- must reflect the final text, not an earlier cached one.  None means "never
-- published" (the caller pairs this with diagPublishedFor to reject that).
export lastDiagCountFor : String -> List Frame -> Option Int
lastDiagCountFor uri frames = lastDiagGo uri frames None

lastDiagGo : String -> List Frame -> Option Int -> Option Int
lastDiagGo _ [] acc = acc
lastDiagGo uri ((Frame _ body _)::rest) acc = match parse body
  Ok j =>
    if isPublishFor uri j then
      lastDiagGo uri rest (Some (jDiagLen j))
    else
      lastDiagGo uri rest acc
  Err _ => lastDiagGo uri rest acc

methodEq : Json -> String -> Bool
methodEq j m = match lookup "method" j
  Some v => match asString v
    Some s => s == m
    None => False
  None => False

paramUriEq : Json -> String -> Bool
paramUriEq j uri = match lookup "params" j
  Some p => match lookup "uri" p
    Some v => match asString v
      Some s => s == uri
      None => False
    None => False
  None => False

jDiagLen : Json -> Int
jDiagLen j = match lookup "params" j
  Some p => match lookup "diagnostics" p
    Some (JArray a) => arrayLength a
    _ => 0
  None => 0

-- ── assertion accumulator ───────────────────────────────────────────────────

export failCount : Ref Int
failCount = Ref 0

export check : String -> Bool -> <IO> Unit
check name ok =
  if ok then println (stringConcat ["PASS ", name])
  else
    let _ = setRef failCount (failCount.value + 1)
    println (stringConcat ["FAIL ", name])

-- Print the run summary; (passed, failed) counts derived from `total`.
export summary : Int -> <IO> Unit
summary total =
  let failed = failCount.value
  println (stringConcat
    [
      "HARNESS: ",
      intToString (total - failed),
      " passed, ",
      intToString failed,
      " failed",
    ])
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JBool" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false))))
(DUse false (UseGroup ("support" "util") ((mem "utf8Len" false) (mem "utf8CharWidth" false))))
(DUse false (UseGroup ("string") ((mem "isDigit" false))))
(DTypeSig true "initializeMsg" (TyFun (TyCon "Int") (TyCon "Json")))
(DFunDef false "initializeMsg" ((PVar "idn")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EApp (EVar "JInt") (EVar "idn"))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "initialize")))) (ETuple (ELit (LString "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit)))))))))
(DTypeSig true "initializedMsg" (TyCon "Json"))
(DFunDef false "initializedMsg" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "initialized")))) (ETuple (ELit (LString "params")) (EApp (EVar "jObject") (EListLit))))))
(DTypeSig true "didOpenMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "didOpenMsg" ((PVar "uri") (PVar "text")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "textDocument/didOpen")))) (ETuple (ELit (LString "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "languageId")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "version")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text"))))))))))))
(DTypeSig true "requestMsg" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "requestMsg" ((PVar "idn") (PVar "method") (PVar "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EApp (EVar "JInt") (EVar "idn"))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (EVar "method"))) (ETuple (ELit (LString "params")) (EVar "params")))))
(DTypeSig true "didChangeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "didChangeMsg" ((PVar "uri") (PVar "text")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "textDocument/didChange")))) (ETuple (ELit (LString "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "version")) (EApp (EVar "JInt") (ELit (LInt 2))))))) (ETuple (ELit (LString "contentChanges")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text"))))))))))))))
(DTypeSig true "docPosParams" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json")))))
(DFunDef false "docPosParams" ((PVar "uri") (PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri")))))) (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch")))))))))
(DTypeSig true "docParams" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "docParams" ((PVar "uri")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri")))))))))
(DTypeSig true "shutdownMsg" (TyFun (TyCon "Int") (TyCon "Json")))
(DFunDef false "shutdownMsg" ((PVar "idn")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EApp (EVar "JInt") (EVar "idn"))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "shutdown")))))))
(DTypeSig true "exitMsg" (TyCon "Json"))
(DFunDef false "exitMsg" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "exit")))))))
(DTypeSig true "frame" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "frame" ((PVar "j")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "stringify") (EVar "j"))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "Content-Length: ")) (EApp (EVar "intToString") (EApp (EVar "utf8Len") (EVar "body"))) (ELit (LString "\r\n\r\n")) (EVar "body"))))))
(DTypeSig true "runSession" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "runSession" ((PVar "medakaBin") (PVar "msgs")) (EBlock (DoLet false false (PVar "req") (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (EVar "frame")) (EVar "msgs")))) (DoLet false false (PVar "tmp") (ELit (LString "/tmp/medaka_lsp_harness_req.txt"))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EVar "tmp")) (EVar "req"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "code") (PVar "out") (PVar "errOut"))) (EVar "out"))) (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EApp (EVar "stringConcat") (EListLit (EVar "medakaBin") (ELit (LString " lsp < ")) (EVar "tmp")))))))))
(DData Public "Frame" () ((variant "Frame" (ConPos (TyCon "Int") (TyCon "String") (TyCon "Bool")))) ())
(DTypeSig true "parseFrames" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Bool"))))
(DFunDef false "parseFrames" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pfGo") (EVar "s")) (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (ELit (LInt 0))))))
(DTypeSig false "clLabel" (TyCon "String"))
(DFunDef false "clLabel" () (ELit (LString "Content-Length:")))
(DTypeSig false "pfGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Bool")))))))
(DFunDef false "pfGo" ((PVar "s") (PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (ETuple (EListLit) (EVar "True")) (EIf (EApp (EApp (EApp (EVar "isTrailingJunk") (EVar "arr")) (EVar "len")) (EVar "i")) (ETuple (EListLit) (EVar "True")) (EIf (EApp (EApp (EApp (EApp (EVar "matchesAt") (EVar "arr")) (EVar "len")) (EVar "i")) (EVar "clLabel")) (EMatch (EApp (EApp (EApp (EVar "parseHeader") (EVar "arr")) (EVar "len")) (EVar "i")) (arm (PCon "None") () (ETuple (EListLit) (EVar "False"))) (arm (PCon "Some" (PTuple (PVar "n") (PVar "bodyStart"))) () (EMatch (EApp (EApp (EApp (EApp (EVar "takeBytes") (EVar "arr")) (EVar "len")) (EVar "bodyStart")) (EVar "n")) (arm (PCon "None") () (ETuple (EListLit (EApp (EApp (EApp (EVar "Frame") (EVar "n")) (ELit (LString ""))) (EVar "False"))) (EVar "False"))) (arm (PCon "Some" (PVar "bodyEnd")) () (EBlock (DoLet false false (PVar "body") (EApp (EApp (EApp (EVar "stringSlice") (EVar "bodyStart")) (EVar "bodyEnd")) (EVar "s"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "pfGo") (EVar "s")) (EVar "arr")) (EVar "len")) (EVar "bodyEnd")) (arm (PTuple (PVar "rest") (PVar "clean")) () (ETuple (EBinOp "::" (EApp (EApp (EApp (EVar "Frame") (EVar "n")) (EVar "body")) (EVar "True")) (EVar "rest")) (EVar "clean")))))))))) (ETuple (EListLit) (EVar "False"))))))
(DTypeSig false "isTrailingJunk" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isTrailingJunk" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "True") (EIf (EApp (EVar "isJunkChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EVar "isTrailingJunk") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isJunkChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isJunkChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "0"))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))) (EBinOp "==" (EVar "c") (ELit (LChar "\r")))) (EBinOp "==" (EVar "c") (ELit (LChar " ")))) (EBinOp "==" (EVar "c") (ELit (LChar "(")))) (EBinOp "==" (EVar "c") (ELit (LChar ")")))))
(DTypeSig false "matchesAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "matchesAt" ((PVar "arr") (PVar "len") (PVar "i") (PVar "lit")) (EBlock (DoLet false false (PVar "larr") (EApp (EVar "stringToChars") (EVar "lit"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "matchesGo") (EVar "arr")) (EVar "len")) (EVar "i")) (EVar "larr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "larr"))))))
(DTypeSig false "matchesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "matchesGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "larr") (PVar "j") (PVar "llen")) (EIf (EBinOp ">=" (EVar "j") (EVar "llen")) (EVar "True") (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (EVar "j")) (EVar "len")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "arr")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "larr"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "matchesGo") (EVar "arr")) (EVar "len")) (EVar "i")) (EVar "larr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "llen")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseHeader" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "parseHeader" ((PVar "arr") (PVar "len") (PVar "i")) (EBlock (DoLet false false (PVar "afterLabel") (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "clLabel")))) (DoLet false false (PVar "numStart") (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EVar "len")) (EVar "afterLabel"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EVar "len")) (EVar "numStart")) (ELit (LInt 0))) (EVar "False")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "n") (PVar "afterNum"))) () (EIf (EApp (EApp (EApp (EApp (EVar "matchesAt") (EVar "arr")) (EVar "len")) (EVar "afterNum")) (ELit (LString "\r\n\r\n"))) (EApp (EVar "Some") (ETuple (EVar "n") (EBinOp "+" (EVar "afterNum") (ELit (LInt 4))))) (EVar "None")))))))
(DTypeSig false "skipSpaces" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipSpaces" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "parseDigits" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc") (PVar "seen")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EIf (EVar "seen") (EApp (EVar "Some") (ETuple (EVar "acc") (EVar "i"))) (EVar "None")) (EIf (EApp (EVar "isDigit") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LInt 48))))) (EVar "True")) (EIf (EVar "otherwise") (EIf (EVar "seen") (EApp (EVar "Some") (ETuple (EVar "acc") (EVar "i"))) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "takeBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "takeBytes" ((PVar "arr") (PVar "len") (PVar "i") (PVar "remaining")) (EIf (EBinOp "==" (EVar "remaining") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "w") (EApp (EVar "utf8CharWidth") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (DoExpr (EIf (EBinOp ">" (EVar "w") (EVar "remaining")) (EVar "None") (EApp (EApp (EApp (EApp (EVar "takeBytes") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "remaining") (EVar "w")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "allByteValid" (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Bool")))
(DFunDef false "allByteValid" ((PList)) (EVar "True"))
(DFunDef false "allByteValid" ((PCons (PCon "Frame" PWild PWild (PVar "ok")) (PVar "rest"))) (EBinOp "&&" (EVar "ok") (EApp (EVar "allByteValid") (EVar "rest"))))
(DTypeSig true "responseById" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "responseById" (PWild (PList)) (EVar "None"))
(DFunDef false "responseById" ((PVar "idn") (PCons (PCon "Frame" PWild (PVar "body") PWild) (PVar "rest"))) (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Ok" (PVar "j")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "id"))) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asInt") (EVar "v")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EVar "idn")) (EApp (EVar "Some") (EVar "j")) (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "rest"))))) (arm (PCon "None") () (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "rest"))))) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "rest")))))
(DTypeSig true "hoverValue" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "hoverValue" ((PVar "idn") (PVar "frames")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "frames"))) (ELam ((PVar "j")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "lookup") (ELit (LString "result"))) (EVar "j"))) (ELam ((PVar "res")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "lookup") (ELit (LString "contents"))) (EVar "res"))) (ELam ((PVar "c")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "lookup") (ELit (LString "value"))) (EVar "c"))) (ELam ((PVar "v")) (EApp (EVar "asString") (EVar "v")))))))))))
(DTypeSig true "completionHasLabel" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "completionHasLabel" ((PVar "idn") (PVar "frames") (PVar "needle")) (EMatch (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "frames")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "j")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "result"))) (EVar "j")) (arm (PCon "Some" (PCon "JArray" (PVar "items"))) () (EApp (EApp (EApp (EApp (EVar "anyLabelEq") (EVar "items")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "items"))) (EVar "needle"))) (arm PWild () (EVar "False"))))))
(DTypeSig false "anyLabelEq" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "anyLabelEq" ((PVar "items") (PVar "i") (PVar "n") (PVar "needle")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "False") (EIf (EApp (EApp (EVar "labelEq") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "items"))) (EVar "needle")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "anyLabelEq") (EVar "items")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "needle")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "labelEq" (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "labelEq" ((PVar "it") (PVar "needle")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "label"))) (EVar "it")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asString") (EVar "v")) (arm (PCon "Some" (PVar "s")) () (EBinOp "==" (EVar "s") (EVar "needle"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "strContains" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "strContains" ((PVar "hay") (PVar "needle")) (EBlock (DoLet false false (PVar "h") (EApp (EVar "stringToChars") (EVar "hay"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "strContainsGo") (EVar "h")) (EApp (EVar "arrayLength") (EVar "h"))) (EVar "needle")) (ELit (LInt 0))))))
(DTypeSig false "strContainsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "strContainsGo" ((PVar "h") (PVar "hlen") (PVar "needle") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "hlen")) (EVar "False") (EIf (EApp (EApp (EApp (EApp (EVar "matchesAt") (EVar "h")) (EVar "hlen")) (EVar "i")) (EVar "needle")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "strContainsGo") (EVar "h")) (EVar "hlen")) (EVar "needle")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "semanticData" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "semanticData" ((PVar "idn") (PVar "frames")) (EMatch (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "frames")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "j")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "result"))) (EVar "j")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "res")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "data"))) (EVar "res")) (arm (PCon "Some" (PCon "JArray" (PVar "a"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EVar "jIntArrayToList") (EVar "a")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "a"))))) (arm PWild () (EVar "None"))))))))
(DTypeSig false "jIntArrayToList" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "jIntArrayToList" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "asInt") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (arm (PCon "Some" (PVar "k")) () (EBinOp "::" (EVar "k") (EApp (EApp (EApp (EVar "jIntArrayToList") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "jIntArrayToList") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DData Public "DecTok" () ((variant "DecTok" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "decodeSemToks" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "DecTok"))))
(DFunDef false "decodeSemToks" ((PVar "ints")) (EApp (EApp (EApp (EVar "decodeGo") (ELit (LInt 0))) (ELit (LInt 0))) (EVar "ints")))
(DTypeSig false "decodeGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "DecTok"))))))
(DFunDef false "decodeGo" ((PVar "prevLine") (PVar "prevChar") (PCons (PVar "dl") (PCons (PVar "dc") (PCons (PVar "len") (PCons (PVar "ty") (PCons (PVar "_mod") (PVar "rest"))))))) (EBlock (DoLet false false (PVar "line") (EBinOp "+" (EVar "prevLine") (EVar "dl"))) (DoLet false false (PVar "ch") (EIf (EBinOp "==" (EVar "dl") (ELit (LInt 0))) (EBinOp "+" (EVar "prevChar") (EVar "dc")) (EVar "dc"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DecTok") (EVar "line")) (EVar "ch")) (EVar "len")) (EVar "ty")) (EApp (EApp (EApp (EVar "decodeGo") (EVar "line")) (EVar "ch")) (EVar "rest"))))))
(DFunDef false "decodeGo" (PWild PWild PWild) (EListLit))
(DTypeSig true "lenTokensShareType" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyCon "Bool")))))
(DFunDef false "lenTokensShareType" ((PVar "len") (PVar "minCount") (PVar "toks")) (EBlock (DoLet false false (PVar "matching") (EApp (EApp (EVar "filterLen") (EVar "len")) (EVar "toks"))) (DoExpr (EMatch (EVar "matching") (arm (PList) () (EVar "False")) (arm (PCons (PCon "DecTok" PWild PWild PWild (PVar "ty0")) PWild) () (EBinOp "&&" (EBinOp ">=" (EApp (EVar "countToks") (EVar "matching")) (EVar "minCount")) (EApp (EApp (EVar "allSameType") (EVar "ty0")) (EVar "matching"))))))))
(DTypeSig false "filterLen" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyApp (TyCon "List") (TyCon "DecTok")))))
(DFunDef false "filterLen" (PWild (PList)) (EListLit))
(DFunDef false "filterLen" ((PVar "len") (PCons (PCon "DecTok" (PVar "l") (PVar "c") (PVar "ln") (PVar "ty")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "ln") (EVar "len")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DecTok") (EVar "l")) (EVar "c")) (EVar "ln")) (EVar "ty")) (EApp (EApp (EVar "filterLen") (EVar "len")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterLen") (EVar "len")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "countToks" (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyCon "Int")))
(DFunDef false "countToks" ((PList)) (ELit (LInt 0)))
(DFunDef false "countToks" ((PCons PWild (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countToks") (EVar "rest"))))
(DTypeSig false "allSameType" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyCon "Bool"))))
(DFunDef false "allSameType" (PWild (PList)) (EVar "True"))
(DFunDef false "allSameType" ((PVar "ty0") (PCons (PCon "DecTok" PWild PWild PWild (PVar "ty")) (PVar "rest"))) (EBinOp "&&" (EBinOp "==" (EVar "ty") (EVar "ty0")) (EApp (EApp (EVar "allSameType") (EVar "ty0")) (EVar "rest"))))
(DTypeSig true "hasTokenType" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyCon "Bool"))))
(DFunDef false "hasTokenType" (PWild (PList)) (EVar "False"))
(DFunDef false "hasTokenType" ((PVar "ty") (PCons (PCon "DecTok" PWild PWild PWild (PVar "t")) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "t") (EVar "ty")) (EApp (EApp (EVar "hasTokenType") (EVar "ty")) (EVar "rest"))))
(DTypeSig true "diagCountFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Int"))))
(DFunDef false "diagCountFor" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "diagCountFor" ((PVar "uri") (PCons (PCon "Frame" PWild (PVar "body") PWild) (PVar "rest"))) (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Ok" (PVar "j")) () (EIf (EApp (EApp (EVar "isPublishFor") (EVar "uri")) (EVar "j")) (EBinOp "+" (EApp (EVar "jDiagLen") (EVar "j")) (EApp (EApp (EVar "diagCountFor") (EVar "uri")) (EVar "rest"))) (EApp (EApp (EVar "diagCountFor") (EVar "uri")) (EVar "rest")))) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "diagCountFor") (EVar "uri")) (EVar "rest")))))
(DTypeSig false "isPublishFor" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Bool"))))
(DFunDef false "isPublishFor" ((PVar "uri") (PVar "j")) (EBinOp "&&" (EApp (EApp (EVar "methodEq") (EVar "j")) (ELit (LString "textDocument/publishDiagnostics"))) (EApp (EApp (EVar "paramUriEq") (EVar "j")) (EVar "uri"))))
(DTypeSig true "diagPublishedFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Bool"))))
(DFunDef false "diagPublishedFor" (PWild (PList)) (EVar "False"))
(DFunDef false "diagPublishedFor" ((PVar "uri") (PCons (PCon "Frame" PWild (PVar "body") PWild) (PVar "rest"))) (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Ok" (PVar "j")) () (EIf (EApp (EApp (EVar "isPublishFor") (EVar "uri")) (EVar "j")) (EVar "True") (EApp (EApp (EVar "diagPublishedFor") (EVar "uri")) (EVar "rest")))) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "diagPublishedFor") (EVar "uri")) (EVar "rest")))))
(DTypeSig true "lastDiagCountFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lastDiagCountFor" ((PVar "uri") (PVar "frames")) (EApp (EApp (EApp (EVar "lastDiagGo") (EVar "uri")) (EVar "frames")) (EVar "None")))
(DTypeSig false "lastDiagGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "lastDiagGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lastDiagGo" ((PVar "uri") (PCons (PCon "Frame" PWild (PVar "body") PWild) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Ok" (PVar "j")) () (EIf (EApp (EApp (EVar "isPublishFor") (EVar "uri")) (EVar "j")) (EApp (EApp (EApp (EVar "lastDiagGo") (EVar "uri")) (EVar "rest")) (EApp (EVar "Some") (EApp (EVar "jDiagLen") (EVar "j")))) (EApp (EApp (EApp (EVar "lastDiagGo") (EVar "uri")) (EVar "rest")) (EVar "acc")))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EVar "lastDiagGo") (EVar "uri")) (EVar "rest")) (EVar "acc")))))
(DTypeSig false "methodEq" (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "methodEq" ((PVar "j") (PVar "m")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "method"))) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asString") (EVar "v")) (arm (PCon "Some" (PVar "s")) () (EBinOp "==" (EVar "s") (EVar "m"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "paramUriEq" (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "paramUriEq" ((PVar "j") (PVar "uri")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "params"))) (EVar "j")) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "uri"))) (EVar "p")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asString") (EVar "v")) (arm (PCon "Some" (PVar "s")) () (EBinOp "==" (EVar "s") (EVar "uri"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "jDiagLen" (TyFun (TyCon "Json") (TyCon "Int")))
(DFunDef false "jDiagLen" ((PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "params"))) (EVar "j")) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "diagnostics"))) (EVar "p")) (arm (PCon "Some" (PCon "JArray" (PVar "a"))) () (EApp (EVar "arrayLength") (EVar "a"))) (arm PWild () (ELit (LInt 0))))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "failCount" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "failCount" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig true "check" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "check" ((PVar "name") (PVar "ok")) (EIf (EVar "ok") (EApp (EVar "println") (EApp (EVar "stringConcat") (EListLit (ELit (LString "PASS ")) (EVar "name")))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "failCount")) (EBinOp "+" (EFieldAccess (EVar "failCount") "value") (ELit (LInt 1))))) (DoExpr (EApp (EVar "println") (EApp (EVar "stringConcat") (EListLit (ELit (LString "FAIL ")) (EVar "name"))))))))
(DTypeSig true "summary" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "summary" ((PVar "total")) (EBlock (DoLet false false (PVar "failed") (EFieldAccess (EVar "failCount") "value")) (DoExpr (EApp (EVar "println") (EApp (EVar "stringConcat") (EListLit (ELit (LString "HARNESS: ")) (EApp (EVar "intToString") (EBinOp "-" (EVar "total") (EVar "failed"))) (ELit (LString " passed, ")) (EApp (EVar "intToString") (EVar "failed")) (ELit (LString " failed"))))))))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JBool" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false))))
(DUse false (UseGroup ("support" "util") ((mem "utf8Len" false) (mem "utf8CharWidth" false))))
(DUse false (UseGroup ("string") ((mem "isDigit" false))))
(DTypeSig true "initializeMsg" (TyFun (TyCon "Int") (TyCon "Json")))
(DFunDef false "initializeMsg" ((PVar "idn")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EApp (EVar "JInt") (EVar "idn"))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "initialize")))) (ETuple (ELit (LString "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit)))))))))
(DTypeSig true "initializedMsg" (TyCon "Json"))
(DFunDef false "initializedMsg" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "initialized")))) (ETuple (ELit (LString "params")) (EApp (EVar "jObject") (EListLit))))))
(DTypeSig true "didOpenMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "didOpenMsg" ((PVar "uri") (PVar "text")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "textDocument/didOpen")))) (ETuple (ELit (LString "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "languageId")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "version")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text"))))))))))))
(DTypeSig true "requestMsg" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "requestMsg" ((PVar "idn") (PVar "method") (PVar "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EApp (EVar "JInt") (EVar "idn"))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (EVar "method"))) (ETuple (ELit (LString "params")) (EVar "params")))))
(DTypeSig true "didChangeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "didChangeMsg" ((PVar "uri") (PVar "text")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "textDocument/didChange")))) (ETuple (ELit (LString "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "version")) (EApp (EVar "JInt") (ELit (LInt 2))))))) (ETuple (ELit (LString "contentChanges")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text"))))))))))))))
(DTypeSig true "docPosParams" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json")))))
(DFunDef false "docPosParams" ((PVar "uri") (PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri")))))) (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch")))))))))
(DTypeSig true "docParams" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "docParams" ((PVar "uri")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri")))))))))
(DTypeSig true "shutdownMsg" (TyFun (TyCon "Int") (TyCon "Json")))
(DFunDef false "shutdownMsg" ((PVar "idn")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EApp (EVar "JInt") (EVar "idn"))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "shutdown")))))))
(DTypeSig true "exitMsg" (TyCon "Json"))
(DFunDef false "exitMsg" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (ELit (LString "exit")))))))
(DTypeSig true "frame" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "frame" ((PVar "j")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "stringify") (EVar "j"))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "Content-Length: ")) (EApp (EVar "intToString") (EApp (EVar "utf8Len") (EVar "body"))) (ELit (LString "\r\n\r\n")) (EVar "body"))))))
(DTypeSig true "runSession" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "runSession" ((PVar "medakaBin") (PVar "msgs")) (EBlock (DoLet false false (PVar "req") (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (EVar "frame")) (EVar "msgs")))) (DoLet false false (PVar "tmp") (ELit (LString "/tmp/medaka_lsp_harness_req.txt"))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EVar "tmp")) (EVar "req"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "code") (PVar "out") (PVar "errOut"))) (EVar "out"))) (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EApp (EVar "stringConcat") (EListLit (EVar "medakaBin") (ELit (LString " lsp < ")) (EVar "tmp")))))))))
(DData Public "Frame" () ((variant "Frame" (ConPos (TyCon "Int") (TyCon "String") (TyCon "Bool")))) ())
(DTypeSig true "parseFrames" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Bool"))))
(DFunDef false "parseFrames" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pfGo") (EVar "s")) (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (ELit (LInt 0))))))
(DTypeSig false "clLabel" (TyCon "String"))
(DFunDef false "clLabel" () (ELit (LString "Content-Length:")))
(DTypeSig false "pfGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Bool")))))))
(DFunDef false "pfGo" ((PVar "s") (PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (ETuple (EListLit) (EVar "True")) (EIf (EApp (EApp (EApp (EVar "isTrailingJunk") (EVar "arr")) (EVar "len")) (EVar "i")) (ETuple (EListLit) (EVar "True")) (EIf (EApp (EApp (EApp (EApp (EVar "matchesAt") (EVar "arr")) (EVar "len")) (EVar "i")) (EVar "clLabel")) (EMatch (EApp (EApp (EApp (EVar "parseHeader") (EVar "arr")) (EVar "len")) (EVar "i")) (arm (PCon "None") () (ETuple (EListLit) (EVar "False"))) (arm (PCon "Some" (PTuple (PVar "n") (PVar "bodyStart"))) () (EMatch (EApp (EApp (EApp (EApp (EVar "takeBytes") (EVar "arr")) (EVar "len")) (EVar "bodyStart")) (EVar "n")) (arm (PCon "None") () (ETuple (EListLit (EApp (EApp (EApp (EVar "Frame") (EVar "n")) (ELit (LString ""))) (EVar "False"))) (EVar "False"))) (arm (PCon "Some" (PVar "bodyEnd")) () (EBlock (DoLet false false (PVar "body") (EApp (EApp (EApp (EVar "stringSlice") (EVar "bodyStart")) (EVar "bodyEnd")) (EVar "s"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "pfGo") (EVar "s")) (EVar "arr")) (EVar "len")) (EVar "bodyEnd")) (arm (PTuple (PVar "rest") (PVar "clean")) () (ETuple (EBinOp "::" (EApp (EApp (EApp (EVar "Frame") (EVar "n")) (EVar "body")) (EVar "True")) (EVar "rest")) (EVar "clean")))))))))) (ETuple (EListLit) (EVar "False"))))))
(DTypeSig false "isTrailingJunk" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isTrailingJunk" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "True") (EIf (EApp (EVar "isJunkChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EVar "isTrailingJunk") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isJunkChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isJunkChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "0"))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))) (EBinOp "==" (EVar "c") (ELit (LChar "\r")))) (EBinOp "==" (EVar "c") (ELit (LChar " ")))) (EBinOp "==" (EVar "c") (ELit (LChar "(")))) (EBinOp "==" (EVar "c") (ELit (LChar ")")))))
(DTypeSig false "matchesAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "matchesAt" ((PVar "arr") (PVar "len") (PVar "i") (PVar "lit")) (EBlock (DoLet false false (PVar "larr") (EApp (EVar "stringToChars") (EVar "lit"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "matchesGo") (EVar "arr")) (EVar "len")) (EVar "i")) (EVar "larr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "larr"))))))
(DTypeSig false "matchesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "matchesGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "larr") (PVar "j") (PVar "llen")) (EIf (EBinOp ">=" (EVar "j") (EVar "llen")) (EVar "True") (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (EVar "j")) (EVar "len")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "arr")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "larr"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "matchesGo") (EVar "arr")) (EVar "len")) (EVar "i")) (EVar "larr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "llen")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseHeader" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "parseHeader" ((PVar "arr") (PVar "len") (PVar "i")) (EBlock (DoLet false false (PVar "afterLabel") (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "clLabel")))) (DoLet false false (PVar "numStart") (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EVar "len")) (EVar "afterLabel"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EVar "len")) (EVar "numStart")) (ELit (LInt 0))) (EVar "False")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "n") (PVar "afterNum"))) () (EIf (EApp (EApp (EApp (EApp (EVar "matchesAt") (EVar "arr")) (EVar "len")) (EVar "afterNum")) (ELit (LString "\r\n\r\n"))) (EApp (EVar "Some") (ETuple (EVar "n") (EBinOp "+" (EVar "afterNum") (ELit (LInt 4))))) (EVar "None")))))))
(DTypeSig false "skipSpaces" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipSpaces" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "parseDigits" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc") (PVar "seen")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EIf (EVar "seen") (EApp (EVar "Some") (ETuple (EVar "acc") (EVar "i"))) (EVar "None")) (EIf (EApp (EVar "isDigit") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LInt 48))))) (EVar "True")) (EIf (EVar "otherwise") (EIf (EVar "seen") (EApp (EVar "Some") (ETuple (EVar "acc") (EVar "i"))) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "takeBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "takeBytes" ((PVar "arr") (PVar "len") (PVar "i") (PVar "remaining")) (EIf (EBinOp "==" (EVar "remaining") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "w") (EApp (EVar "utf8CharWidth") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (DoExpr (EIf (EBinOp ">" (EVar "w") (EVar "remaining")) (EVar "None") (EApp (EApp (EApp (EApp (EVar "takeBytes") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "remaining") (EVar "w")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "allByteValid" (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Bool")))
(DFunDef false "allByteValid" ((PList)) (EVar "True"))
(DFunDef false "allByteValid" ((PCons (PCon "Frame" PWild PWild (PVar "ok")) (PVar "rest"))) (EBinOp "&&" (EVar "ok") (EApp (EVar "allByteValid") (EVar "rest"))))
(DTypeSig true "responseById" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "responseById" (PWild (PList)) (EVar "None"))
(DFunDef false "responseById" ((PVar "idn") (PCons (PCon "Frame" PWild (PVar "body") PWild) (PVar "rest"))) (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Ok" (PVar "j")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "id"))) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asInt") (EVar "v")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EVar "idn")) (EApp (EVar "Some") (EVar "j")) (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "rest"))))) (arm (PCon "None") () (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "rest"))))) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "rest")))))
(DTypeSig true "hoverValue" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "hoverValue" ((PVar "idn") (PVar "frames")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "frames"))) (ELam ((PVar "j")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "lookup") (ELit (LString "result"))) (EVar "j"))) (ELam ((PVar "res")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "lookup") (ELit (LString "contents"))) (EVar "res"))) (ELam ((PVar "c")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "lookup") (ELit (LString "value"))) (EVar "c"))) (ELam ((PVar "v")) (EApp (EVar "asString") (EVar "v")))))))))))
(DTypeSig true "completionHasLabel" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "completionHasLabel" ((PVar "idn") (PVar "frames") (PVar "needle")) (EMatch (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "frames")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "j")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "result"))) (EVar "j")) (arm (PCon "Some" (PCon "JArray" (PVar "items"))) () (EApp (EApp (EApp (EApp (EVar "anyLabelEq") (EVar "items")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "items"))) (EVar "needle"))) (arm PWild () (EVar "False"))))))
(DTypeSig false "anyLabelEq" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "anyLabelEq" ((PVar "items") (PVar "i") (PVar "n") (PVar "needle")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "False") (EIf (EApp (EApp (EVar "labelEq") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "items"))) (EVar "needle")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "anyLabelEq") (EVar "items")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "needle")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "labelEq" (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "labelEq" ((PVar "it") (PVar "needle")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "label"))) (EVar "it")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asString") (EVar "v")) (arm (PCon "Some" (PVar "s")) () (EBinOp "==" (EVar "s") (EVar "needle"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "strContains" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "strContains" ((PVar "hay") (PVar "needle")) (EBlock (DoLet false false (PVar "h") (EApp (EVar "stringToChars") (EVar "hay"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "strContainsGo") (EVar "h")) (EApp (EVar "arrayLength") (EVar "h"))) (EVar "needle")) (ELit (LInt 0))))))
(DTypeSig false "strContainsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "strContainsGo" ((PVar "h") (PVar "hlen") (PVar "needle") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "hlen")) (EVar "False") (EIf (EApp (EApp (EApp (EApp (EVar "matchesAt") (EVar "h")) (EVar "hlen")) (EVar "i")) (EVar "needle")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "strContainsGo") (EVar "h")) (EVar "hlen")) (EVar "needle")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "semanticData" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "semanticData" ((PVar "idn") (PVar "frames")) (EMatch (EApp (EApp (EVar "responseById") (EVar "idn")) (EVar "frames")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "j")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "result"))) (EVar "j")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "res")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "data"))) (EVar "res")) (arm (PCon "Some" (PCon "JArray" (PVar "a"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EVar "jIntArrayToList") (EVar "a")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "a"))))) (arm PWild () (EVar "None"))))))))
(DTypeSig false "jIntArrayToList" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "jIntArrayToList" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "asInt") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (arm (PCon "Some" (PVar "k")) () (EBinOp "::" (EVar "k") (EApp (EApp (EApp (EVar "jIntArrayToList") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "jIntArrayToList") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DData Public "DecTok" () ((variant "DecTok" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "decodeSemToks" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "DecTok"))))
(DFunDef false "decodeSemToks" ((PVar "ints")) (EApp (EApp (EApp (EVar "decodeGo") (ELit (LInt 0))) (ELit (LInt 0))) (EVar "ints")))
(DTypeSig false "decodeGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "DecTok"))))))
(DFunDef false "decodeGo" ((PVar "prevLine") (PVar "prevChar") (PCons (PVar "dl") (PCons (PVar "dc") (PCons (PVar "len") (PCons (PVar "ty") (PCons (PVar "_mod") (PVar "rest"))))))) (EBlock (DoLet false false (PVar "line") (EBinOp "+" (EVar "prevLine") (EVar "dl"))) (DoLet false false (PVar "ch") (EIf (EBinOp "==" (EVar "dl") (ELit (LInt 0))) (EBinOp "+" (EVar "prevChar") (EVar "dc")) (EVar "dc"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DecTok") (EVar "line")) (EVar "ch")) (EVar "len")) (EVar "ty")) (EApp (EApp (EApp (EVar "decodeGo") (EVar "line")) (EVar "ch")) (EVar "rest"))))))
(DFunDef false "decodeGo" (PWild PWild PWild) (EListLit))
(DTypeSig true "lenTokensShareType" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyCon "Bool")))))
(DFunDef false "lenTokensShareType" ((PVar "len") (PVar "minCount") (PVar "toks")) (EBlock (DoLet false false (PVar "matching") (EApp (EApp (EVar "filterLen") (EVar "len")) (EVar "toks"))) (DoExpr (EMatch (EVar "matching") (arm (PList) () (EVar "False")) (arm (PCons (PCon "DecTok" PWild PWild PWild (PVar "ty0")) PWild) () (EBinOp "&&" (EBinOp ">=" (EApp (EVar "countToks") (EVar "matching")) (EVar "minCount")) (EApp (EApp (EVar "allSameType") (EVar "ty0")) (EVar "matching"))))))))
(DTypeSig false "filterLen" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyApp (TyCon "List") (TyCon "DecTok")))))
(DFunDef false "filterLen" (PWild (PList)) (EListLit))
(DFunDef false "filterLen" ((PVar "len") (PCons (PCon "DecTok" (PVar "l") (PVar "c") (PVar "ln") (PVar "ty")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "ln") (EVar "len")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DecTok") (EVar "l")) (EVar "c")) (EVar "ln")) (EVar "ty")) (EApp (EApp (EVar "filterLen") (EVar "len")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterLen") (EVar "len")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "countToks" (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyCon "Int")))
(DFunDef false "countToks" ((PList)) (ELit (LInt 0)))
(DFunDef false "countToks" ((PCons PWild (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countToks") (EVar "rest"))))
(DTypeSig false "allSameType" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyCon "Bool"))))
(DFunDef false "allSameType" (PWild (PList)) (EVar "True"))
(DFunDef false "allSameType" ((PVar "ty0") (PCons (PCon "DecTok" PWild PWild PWild (PVar "ty")) (PVar "rest"))) (EBinOp "&&" (EBinOp "==" (EVar "ty") (EVar "ty0")) (EApp (EApp (EVar "allSameType") (EVar "ty0")) (EVar "rest"))))
(DTypeSig true "hasTokenType" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DecTok")) (TyCon "Bool"))))
(DFunDef false "hasTokenType" (PWild (PList)) (EVar "False"))
(DFunDef false "hasTokenType" ((PVar "ty") (PCons (PCon "DecTok" PWild PWild PWild (PVar "t")) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "t") (EVar "ty")) (EApp (EApp (EVar "hasTokenType") (EVar "ty")) (EVar "rest"))))
(DTypeSig true "diagCountFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Int"))))
(DFunDef false "diagCountFor" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "diagCountFor" ((PVar "uri") (PCons (PCon "Frame" PWild (PVar "body") PWild) (PVar "rest"))) (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Ok" (PVar "j")) () (EIf (EApp (EApp (EVar "isPublishFor") (EVar "uri")) (EVar "j")) (EBinOp "+" (EApp (EVar "jDiagLen") (EVar "j")) (EApp (EApp (EVar "diagCountFor") (EVar "uri")) (EVar "rest"))) (EApp (EApp (EVar "diagCountFor") (EVar "uri")) (EVar "rest")))) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "diagCountFor") (EVar "uri")) (EVar "rest")))))
(DTypeSig false "isPublishFor" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Bool"))))
(DFunDef false "isPublishFor" ((PVar "uri") (PVar "j")) (EBinOp "&&" (EApp (EApp (EVar "methodEq") (EVar "j")) (ELit (LString "textDocument/publishDiagnostics"))) (EApp (EApp (EVar "paramUriEq") (EVar "j")) (EVar "uri"))))
(DTypeSig true "diagPublishedFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyCon "Bool"))))
(DFunDef false "diagPublishedFor" (PWild (PList)) (EVar "False"))
(DFunDef false "diagPublishedFor" ((PVar "uri") (PCons (PCon "Frame" PWild (PVar "body") PWild) (PVar "rest"))) (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Ok" (PVar "j")) () (EIf (EApp (EApp (EVar "isPublishFor") (EVar "uri")) (EVar "j")) (EVar "True") (EApp (EApp (EVar "diagPublishedFor") (EVar "uri")) (EVar "rest")))) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "diagPublishedFor") (EVar "uri")) (EVar "rest")))))
(DTypeSig true "lastDiagCountFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lastDiagCountFor" ((PVar "uri") (PVar "frames")) (EApp (EApp (EApp (EVar "lastDiagGo") (EVar "uri")) (EVar "frames")) (EVar "None")))
(DTypeSig false "lastDiagGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Frame")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "lastDiagGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lastDiagGo" ((PVar "uri") (PCons (PCon "Frame" PWild (PVar "body") PWild) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Ok" (PVar "j")) () (EIf (EApp (EApp (EVar "isPublishFor") (EVar "uri")) (EVar "j")) (EApp (EApp (EApp (EVar "lastDiagGo") (EVar "uri")) (EVar "rest")) (EApp (EVar "Some") (EApp (EVar "jDiagLen") (EVar "j")))) (EApp (EApp (EApp (EVar "lastDiagGo") (EVar "uri")) (EVar "rest")) (EVar "acc")))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EVar "lastDiagGo") (EVar "uri")) (EVar "rest")) (EVar "acc")))))
(DTypeSig false "methodEq" (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "methodEq" ((PVar "j") (PVar "m")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "method"))) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asString") (EVar "v")) (arm (PCon "Some" (PVar "s")) () (EBinOp "==" (EVar "s") (EVar "m"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "paramUriEq" (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "paramUriEq" ((PVar "j") (PVar "uri")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "params"))) (EVar "j")) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "uri"))) (EVar "p")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asString") (EVar "v")) (arm (PCon "Some" (PVar "s")) () (EBinOp "==" (EVar "s") (EVar "uri"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "jDiagLen" (TyFun (TyCon "Json") (TyCon "Int")))
(DFunDef false "jDiagLen" ((PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "params"))) (EVar "j")) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "diagnostics"))) (EVar "p")) (arm (PCon "Some" (PCon "JArray" (PVar "a"))) () (EApp (EVar "arrayLength") (EVar "a"))) (arm PWild () (ELit (LInt 0))))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "failCount" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "failCount" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig true "check" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "check" ((PVar "name") (PVar "ok")) (EIf (EVar "ok") (EApp (EDictApp "println") (EApp (EVar "stringConcat") (EListLit (ELit (LString "PASS ")) (EVar "name")))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "failCount")) (EBinOp "+" (EFieldAccess (EVar "failCount") "value") (ELit (LInt 1))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "stringConcat") (EListLit (ELit (LString "FAIL ")) (EVar "name"))))))))
(DTypeSig true "summary" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "summary" ((PVar "total")) (EBlock (DoLet false false (PVar "failed") (EFieldAccess (EVar "failCount") "value")) (DoExpr (EApp (EDictApp "println") (EApp (EVar "stringConcat") (EListLit (ELit (LString "HARNESS: ")) (EApp (EVar "intToString") (EBinOp "-" (EVar "total") (EVar "failed"))) (ELit (LString " passed, ")) (EApp (EVar "intToString") (EVar "failed")) (ELit (LString " failed"))))))))
