# META
source_lines=477
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/mcp.mdk — the `medaka mcp` MCP (Model Context Protocol) server.
--
-- Foundation for the `medaka mcp` workstream (#246 / #247): a JSON-RPC 2.0
-- server over stdio that exposes the compiler to coding agents.  Everything a
-- later tool needs bolts onto the TOOL REGISTRY seam near the bottom of this file.
--
-- Framing (deliberately NOT lsp.mdk's Content-Length):
--   MCP stdio transport is **newline-delimited JSON** — exactly one JSON object
--   per line, no embedded newlines within a message.  We rely on json.stringify
--   emitting single-line output (it escapes '\n' → \n inside strings and uses
--   only `,`/`{}`/`[]` separators, so a value can never straddle two lines) and
--   read one line at a time with readLineOpt.
--
-- Channels:
--   stdout is the EXCLUSIVE protocol channel — every byte written there must be
--   a framed JSON-RPC message.  All logging goes to stderr via `logMcp`; a stray
--   stdout write corrupts the stream.
--
-- The json layer (parse/stringify/ctors) IS imported — it is already exported
-- and drags no new type surface.  A few tiny helpers are instead COPIED from
-- lsp.mdk (responseMsg + the fieldOr/fieldStr accessors): lsp.mdk does not export
-- them, and copying keeps the cross-module surface small (no edit to lsp.mdk, no
-- new shared type/instance surface).  Each copy carries its own scoped
-- rule-duplicate-body disable.  `errorMsg` is ORIGINAL to this file — LSP never
-- emits a JSON-RPC error object over its transport, so there is nothing to copy.

import json.{
  Json,
  JNull,
  JInt,
  JString,
  JBool,
  jObject,
  jArray,
  stringify,
  parse,
  lookup,
  asString,
  asInt,
}
import io.{stripCR}
import driver.diagnostics.{checkJsonSingle, checkJsonFile}
import tools.lsp.{typeAtPoint, documentSymbols, definitionResult}

-- ── protocol / server identity ──────────────────────────────────────────────

-- The MCP protocol revision this server implements.  Date-stamped per the MCP
-- spec's versioning; bump when adopting a newer revision.
mcpProtocolVersion : String
mcpProtocolVersion = "2024-11-05"

-- Mirrors medakaVersion in compiler/driver/medaka_cli.mdk (kept in sync by hand;
-- medaka_cli is the top of the graph and cannot be imported here).
mcpServerVersion : String
mcpServerVersion = "0.1.0-preview"

-- ── JSON-RPC envelopes (copied from lsp.mdk; see header) ─────────────────────

-- A JSON-RPC success envelope: { jsonrpc, id, result }.
responseMsg : Json -> Json -> Json
-- Intentional cross-file duplicate of lsp.mdk's responseMsg; lsp.mdk doesn't export it and importing it here would widen the cross-module surface.
-- lint-disable-next-line rule-duplicate-body
responseMsg idJson result =
  jObject [("jsonrpc", JString "2.0"), ("id", idJson), ("result", result)]

-- A JSON-RPC error envelope: { jsonrpc, id, error: { code, message } }.
errorMsg : Json -> Int -> String -> Json
errorMsg idJson code message = jObject
  [
    ("jsonrpc", JString "2.0"),
    ("id", idJson),
    ("error", jObject [("code", JInt code), ("message", JString message)]),
  ]

-- ── field accessors (copied from lsp.mdk) ────────────────────────────────────

fieldOr : String -> Json -> Json
-- Intentional cross-file duplicate of lsp.mdk's fieldOr; lsp.mdk doesn't export it and importing it here would widen the cross-module surface.
-- lint-disable-next-line rule-duplicate-body
fieldOr key j = match lookup key j
  Some v => v
  None => JNull

fieldStr : String -> Json -> Option String
-- Intentional cross-file duplicate of lsp.mdk's fieldStr; lsp.mdk doesn't export it and importing it here would widen the cross-module surface.
-- lint-disable-next-line rule-duplicate-body
fieldStr key j = match lookup key j
  Some v => asString v
  None => None

methodOf : Json -> Option String
methodOf msg = fieldStr "method" msg

-- Integer field accessor (for tool args like `line`/`col`).  None when absent or
-- not a JInt — the caller reports the missing/invalid argument as an isError result.
fieldInt : String -> Json -> Option Int
fieldInt key j = match lookup key j
  Some v => asInt v
  None => None

-- ── stdio transport ──────────────────────────────────────────────────────────

-- Write one JSON-RPC message as a single newline-terminated line to stdout, then
-- flush (buffered stdout would otherwise strand the response).  `stringify` is
-- single-line, so this is exactly one MCP frame.
writeMessage : Json -> <IO> Unit
writeMessage j =
  let _ = putStr (stringify j)
  let _ = putStr "\n"
  flushStdout ()

-- All diagnostics go to stderr — stdout is protocol-only.
logMcp : String -> <IO> Unit
logMcp s = ePutStrLn (stringConcat ["[mcp] ", s])

-- ── handshake result values ──────────────────────────────────────────────────

initializeResult : Json
initializeResult = jObject
  [
    ("protocolVersion", JString mcpProtocolVersion),
    ("capabilities", jObject [("tools", jObject [])]),
    (
      "serverInfo",
      jObject [("name", JString "medaka"), ("version", JString mcpServerVersion)],
    ),
  ]

-- tools/list response: { tools: [ {name,description,inputSchema}, ... ] } — the
-- descriptor array is DERIVED from `mcpTools`, never hand-maintained.
toolsListResult : Json
toolsListResult = jObject [("tools", jArray (map toolDescriptor mcpTools))]

-- ═══ TOOL REGISTRY ═══════════════════════════════════════════════════════════
-- ONE record per tool — no more two-lists-kept-in-sync-by-a-comment.  Each
-- `McpTool` carries name, description, inputSchema, AND handler, and BOTH the
-- `tools/list` descriptor array (via `toolDescriptor`) and the `tools/call`
-- dispatch (via `callTool`/`lookupTool`) are DERIVED from `mcpTools` — so a
-- descriptor and its handler can never drift.
--
-- To add a tool (#249/#250/#251/#252/#255): write its handler, then add ONE
-- `McpTool` record below.  A handler is
--   runtimeSrc -> coreSrc -> stdlibDir -> args -> <IO> resultJson
-- (the prelude sources + stdlib dir are threaded from the driver so a handler can
-- run the compiler pipeline), and returns the tool result Json — typically
-- `{ content: [ { type: "text", text } ], isError }`.

data McpTool =
  | McpTool String String Json (String -> String -> String -> Json -> <IO> Json)
--        name   desc   schema  handler(runtimeSrc coreSrc stdlibDir args)

mcpTools : List McpTool
mcpTools = [
  McpTool "medaka_check" "Type-check Medaka source and return structured diagnostics — the same JSON `medaka check --json` emits (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available). Provide exactly one of `file` or `source`." medakaCheckSchema runCheckTool,
  McpTool "medaka_type_at" "Infer the type/scheme at a position — the LSP hover, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style); returns the `<name> : <type>` at that point, resolving imported names against the project on disk. A position off any identifier returns a clean \"no symbol\" note, not an error." medakaTypeAtSchema runTypeAtTool,
  McpTool "medaka_symbols" "List a file's top-level declarations (functions, data types, interfaces, impls, …) with their source ranges — the LSP document-symbol outline, driven statelessly. Give a `file` path; parse-only (no typecheck), so it works even on a file with type errors." medakaSymbolsSchema runSymbolsTool,
  McpTool "medaka_definition" "Find the declaration that defines the identifier at a position — the LSP go-to-definition, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style). INTRA-FILE ONLY: it scans declarations in this same file, so a use of a name defined in ANOTHER file returns an empty result rather than a wrong location. A position off any identifier also returns an empty result." medakaDefinitionSchema runDefinitionTool,
]

-- The `tools/list` descriptor for one tool: { name, description, inputSchema }.
toolDescriptor : McpTool -> Json
toolDescriptor (McpTool name desc schema _) = jObject
  [
    ("name", JString name),
    ("description", JString desc),
    ("inputSchema", schema),
  ]

-- Dispatch a tools/call by tool name against `mcpTools`.  `None` ⇒ no such tool
-- (caller emits JSON-RPC -32601).  `Some result` ⇒ the tool's result Json.
callTool : String -> String -> String -> String -> Json -> <IO> Option Json
callTool runtimeSrc coreSrc stdlibDir name args = map
  ((McpTool _ _ _ handler) => handler runtimeSrc coreSrc stdlibDir args)
  (lookupTool name mcpTools)

lookupTool : String -> List McpTool -> Option McpTool
lookupTool _ [] = None
lookupTool name (t::ts) = match t
  McpTool n _ _ _ => if n == name then Some t else lookupTool name ts

-- ── medaka_check tool ─────────────────────────────────────────────────────────

-- inputSchema: exactly one of `file` (path) or `source` (inline text).
medakaCheckSchema : Json
medakaCheckSchema = jObject
  [
    ("type", JString "object"),
    (
      "properties",
      jObject [
        (
          "file",
          jObject [
            ("type", JString "string"),
            ("description", JString "Path to a .mdk file to check."),
          ],
        ),
        (
          "source",
          jObject [
            ("type", JString "string"),
            (
              "description",
              JString "Inline Medaka source to check (no file on disk).",
            ),
          ],
        ),
      ],
    ),
  ]

-- Stable synthetic filename for inline `source` checks — never a temp path, so a
-- transcript golden over a `source` call is path-free and portable.
syntheticSourceName : String
syntheticSourceName = "<source>"

-- Wrap a text payload as an MCP tool result: { content:[{type:text,text}], isError }.
toolTextResult : String -> Bool -> Json
toolTextResult text isErr = jObject
  [
    (
      "content",
      jArray [jObject [("type", JString "text"), ("text", JString text)]],
    ),
    ("isError", JBool isErr),
  ]

-- An argument-validation failure, surfaced as an isError:true tool result (NOT a
-- crash, NOT a JSON-RPC error — the call was well-formed, its arguments weren't).
toolArgError : String -> Json
toolArgError msg = toolTextResult msg True

-- medaka_check handler: run the check pipeline over `file` XOR `source` and return
-- the {"files":[...]} JSON in a text content block.  isError=true iff any
-- diagnostic is a hard error.  Inline `source` is checked WITHOUT touching disk
-- (checkJsonSingle), its diagnostics carrying the stable synthetic filename
-- "<source>".  `file` goes through checkJsonFile (full import resolution).
runCheckTool : String -> String -> String -> Json -> <IO> Json
runCheckTool runtimeSrc coreSrc stdlibDir args = match (fieldStr "file" args, fieldStr "source" args)
  (Some _, Some _) => toolArgError "medaka_check: provide exactly one of 'file' or 'source', not both"
  (None, None) => toolArgError "medaka_check: missing argument — provide exactly one of 'file' or 'source'"
  (Some path, None) =>
    let (json, hasErr) = checkJsonFile False runtimeSrc coreSrc path stdlibDir
    toolTextResult json hasErr
  (None, Some src) =>
    let (json, hasErr) = checkJsonSingle False runtimeSrc coreSrc syntheticSourceName src
    toolTextResult json hasErr

-- ── medaka_type_at tool ───────────────────────────────────────────────────────

-- inputSchema: `file` (path) plus `line`/`col`, the 0-based LSP-style position.
-- All three are required.
medakaTypeAtSchema : Json
medakaTypeAtSchema = jObject
  [
    ("type", JString "object"),
    (
      "properties",
      jObject [
        (
          "file",
          jObject [
            ("type", JString "string"),
            ("description", JString "Path to the .mdk file to query."),
          ],
        ),
        (
          "line",
          jObject [
            ("type", JString "integer"),
            (
              "description",
              JString "0-based line of the position (LSP-style, first line is 0).",
            ),
          ],
        ),
        (
          "col",
          jObject [
            ("type", JString "integer"),
            (
              "description",
              JString "0-based column of the position (LSP-style, first column is 0).",
            ),
          ],
        ),
      ],
    ),
    ("required", jArray [JString "file", JString "line", JString "col"]),
  ]

-- medaka_type_at handler: read `file` from disk and infer the type at (line, col)
-- via the stateless hover harness (tools.lsp.typeAtPoint), returning the
-- `<name> : <type>` text.  Off any identifier / not in scope ⇒ a CLEAN "no symbol"
-- result (isError=false, never a crash).  A missing file or bad arguments ⇒ an
-- isError result (the arguments were malformed, not the call).  The response text
-- is the type only (path-free), so a transcript golden over it is portable.
runTypeAtTool : String -> String -> String -> Json -> <IO> Json
runTypeAtTool runtimeSrc coreSrc _stdlibDir args = match (fieldStr "file" args, fieldInt "line" args, fieldInt "col" args)
  (Some path, Some line, Some col) => match readFile path
    Err e => toolArgError (stringConcat ["medaka_type_at: cannot read file '", path, "': ", e])
    Ok src => match typeAtPoint runtimeSrc coreSrc path src line col
      None => toolTextResult "no symbol at this position" False
      Some ty => toolTextResult ty False
  _ => toolArgError "medaka_type_at: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"

-- ── medaka_symbols tool ───────────────────────────────────────────────────────

-- inputSchema: `file` (path), required.
medakaSymbolsSchema : Json
medakaSymbolsSchema = jObject
  [
    ("type", JString "object"),
    (
      "properties",
      jObject [
        (
          "file",
          jObject [
            ("type", JString "string"),
            (
              "description",
              JString "Path to the .mdk file to list symbols for.",
            ),
          ],
        )
      ],
    ),
    ("required", jArray [JString "file"]),
  ]

-- medaka_symbols handler: read `file` from disk and return its top-level decl
-- symbols (tools.lsp.documentSymbols), serialized as a JSON array in a text
-- content block.  Parse-only (no typecheck) — never errors on an ill-typed
-- file, only on a missing/unreadable one.  A file that fails to PARSE returns
-- an empty array, same as an empty file (documentSymbols makes no distinction;
-- use medaka_check to diagnose a parse failure).
runSymbolsTool : String -> String -> String -> Json -> <IO> Json
runSymbolsTool _runtimeSrc _coreSrc _stdlibDir args = match fieldStr "file" args
  None => toolArgError "medaka_symbols: missing or invalid argument — require 'file' (string)"
  Some path => match readFile path
    Err e => toolArgError (stringConcat ["medaka_symbols: cannot read file '", path, "': ", e])
    Ok src => toolTextResult (stringify (jArray (documentSymbols src))) False

-- ── medaka_definition tool ───────────────────────────────────────────────────

-- inputSchema: `file` (path) plus `line`/`col`, the 0-based LSP-style position.
-- All three are required.
medakaDefinitionSchema : Json
medakaDefinitionSchema = jObject
  [
    ("type", JString "object"),
    (
      "properties",
      jObject [
        (
          "file",
          jObject [
            ("type", JString "string"),
            ("description", JString "Path to the .mdk file to query."),
          ],
        ),
        (
          "line",
          jObject [
            ("type", JString "integer"),
            (
              "description",
              JString "0-based line of the position (LSP-style, first line is 0).",
            ),
          ],
        ),
        (
          "col",
          jObject [
            ("type", JString "integer"),
            (
              "description",
              JString "0-based column of the position (LSP-style, first column is 0).",
            ),
          ],
        ),
      ],
    ),
    ("required", jArray [JString "file", JString "line", JString "col"]),
  ]

-- Synthesize a `{ position: { line, character } }` params Json — the shape
-- `tools.lsp.definitionResult` expects (it reads position.line/character via
-- positionLine/positionChar, the same accessors the real LSP request handler
-- uses).
positionParams : Int -> Int -> Json
positionParams line col = jObject
  [("position", jObject [("line", JInt line), ("character", JInt col)])]

-- medaka_definition handler: read `file` from disk and resolve the identifier
-- at (line, col) to its defining declaration's range via the stateless,
-- INTRA-FILE-ONLY harness (tools.lsp.definitionResult).  `uri` is passed as
-- the caller's own `file` string, UNCHANGED (no `uriOfPath`/`file://`
-- wrapping) — a relative request path stays relative in the echoed result, so
-- a transcript golden over it is path-stable.  Off any identifier, or a name
-- not defined in THIS file (e.g. an imported name — definition is intra-file
-- only, see #254 for cross-file), returns an empty `[]` result — never a
-- crash, and never a wrong same-file location.
runDefinitionTool : String -> String -> String -> Json -> <IO> Json
runDefinitionTool _runtimeSrc _coreSrc _stdlibDir args = match (fieldStr "file" args, fieldInt "line" args, fieldInt "col" args)
  (Some path, Some line, Some col) => match readFile path
    Err e => toolArgError (stringConcat ["medaka_definition: cannot read file '", path, "': ", e])
    Ok src => toolTextResult (stringify (definitionResult path src (positionParams line col))) False
  _ => toolArgError "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"

-- ── tools/call handler ───────────────────────────────────────────────────────

handleToolsCall : String -> String -> String -> Json -> Json -> <IO> Unit
handleToolsCall runtimeSrc coreSrc stdlibDir idJson params = match fieldStr "name" params
  None =>
    writeMessage (errorMsg idJson (0 - 32602) "tools/call: missing 'name'")
  Some name => match callTool runtimeSrc coreSrc stdlibDir name (fieldOr "arguments" params)
    None => writeMessage (errorMsg idJson (0 - 32601) (stringConcat ["Unknown tool: ", name]))
    Some result => writeMessage (responseMsg idJson result)

-- ── request dispatch ─────────────────────────────────────────────────────────

-- Handle one decoded JSON-RPC message.  Requests carry an `id` and get a
-- response; notifications have no `id` and get none.  An unrecognized *request*
-- returns method-not-found (-32601); an unrecognized *notification* is ignored.
dispatchMsg : String -> String -> String -> Json -> <IO> Unit
dispatchMsg runtimeSrc coreSrc stdlibDir msg = match methodOf msg
  None => logMcp "ignored: message has no string 'method' field"
  Some meth =>
    let idJson = fieldOr "id" msg
    let params = fieldOr "params" msg
    if meth == "initialize" then writeMessage (responseMsg idJson initializeResult)
    else
      if meth == "notifications/initialized" then unit
      else
        if meth == "ping" then writeMessage (responseMsg idJson (jObject []))
        else
          if meth == "shutdown" then writeMessage (responseMsg idJson (jObject []))
          else
            if meth == "tools/list" then writeMessage (responseMsg idJson toolsListResult)
            else
              if meth == "tools/call" then handleToolsCall runtimeSrc coreSrc stdlibDir idJson params
              else match idJson
                JNull => unit
                _ => writeMessage (errorMsg idJson (0 - 32601) (stringConcat ["Method not found: ", meth]))

-- ── read loop ────────────────────────────────────────────────────────────────

-- Parse and dispatch one input line.  Blank lines and malformed JSON are logged
-- to stderr and skipped, never crashing the stream.
handleLine : String -> String -> String -> String -> <IO> Unit
handleLine runtimeSrc coreSrc stdlibDir raw =
  let line = stripCR raw
  if line == "" then unit
  else match parse line
    Err e => logMcp (stringConcat ["parse error (skipped): ", e])
    Ok msg => dispatchMsg runtimeSrc coreSrc stdlibDir msg

-- The session loop: one JSON object per line until stdin EOF (clean shutdown).
serveLoop : String -> String -> String -> <IO> Unit
serveLoop runtimeSrc coreSrc stdlibDir = match readLineOpt ()
  None => unit
  Some raw =>
    let _ = handleLine runtimeSrc coreSrc stdlibDir raw
    serveLoop runtimeSrc coreSrc stdlibDir

-- Public entry point for the driver (`runMcpCmd` in medaka_cli.mdk).  The prelude
-- sources + stdlib dir are threaded in so tools can run the compiler pipeline
-- (e.g. medaka_check resolves a `file` target's imports against stdlibDir).
export runMcpServer : String -> String -> String -> <IO> Unit
runMcpServer runtimeSrc coreSrc stdlibDir =
  let _ = logMcp "medaka mcp server start"
  serveLoop runtimeSrc coreSrc stdlibDir

unit : Unit
unit = ()
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JInt" false) (mem "JString" false) (mem "JBool" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false))))
(DUse false (UseGroup ("io") ((mem "stripCR" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "checkJsonSingle" false) (mem "checkJsonFile" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "typeAtPoint" false) (mem "documentSymbols" false) (mem "definitionResult" false))))
(DTypeSig false "mcpProtocolVersion" (TyCon "String"))
(DFunDef false "mcpProtocolVersion" () (ELit (LString "2024-11-05")))
(DTypeSig false "mcpServerVersion" (TyCon "String"))
(DFunDef false "mcpServerVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "errorMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "errorMsg" ((PVar "idJson") (PVar "code") (PVar "message")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EVar "code"))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message")))))))))
(DTypeSig false "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DTypeSig false "fieldInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "fieldInt" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "stringify") (EVar "j")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "logMcp" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logMcp" ((PVar "s")) (EApp (EVar "ePutStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "[mcp] ")) (EVar "s")))))
(DTypeSig false "initializeResult" (TyCon "Json"))
(DFunDef false "initializeResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "protocolVersion")) (EApp (EVar "JString") (EVar "mcpProtocolVersion"))) (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jObject") (EListLit)))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (EVar "mcpServerVersion")))))))))
(DTypeSig false "toolsListResult" (TyCon "Json"))
(DFunDef false "toolsListResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "toolDescriptor")) (EVar "mcpTools")))))))
(DData Private "McpTool" () ((variant "McpTool" (ConPos (TyCon "String") (TyCon "String") (TyCon "Json") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json"))))))))) ())
(DTypeSig false "mcpTools" (TyApp (TyCon "List") (TyCon "McpTool")))
(DFunDef false "mcpTools" () (EListLit (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_check"))) (ELit (LString "Type-check Medaka source and return structured diagnostics — the same JSON `medaka check --json` emits (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available). Provide exactly one of `file` or `source`."))) (EVar "medakaCheckSchema")) (EVar "runCheckTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_type_at"))) (ELit (LString "Infer the type/scheme at a position — the LSP hover, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style); returns the `<name> : <type>` at that point, resolving imported names against the project on disk. A position off any identifier returns a clean \"no symbol\" note, not an error."))) (EVar "medakaTypeAtSchema")) (EVar "runTypeAtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_symbols"))) (ELit (LString "List a file's top-level declarations (functions, data types, interfaces, impls, …) with their source ranges — the LSP document-symbol outline, driven statelessly. Give a `file` path; parse-only (no typecheck), so it works even on a file with type errors."))) (EVar "medakaSymbolsSchema")) (EVar "runSymbolsTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_definition"))) (ELit (LString "Find the declaration that defines the identifier at a position — the LSP go-to-definition, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style). INTRA-FILE ONLY: it scans declarations in this same file, so a use of a name defined in ANOTHER file returns an empty result rather than a wrong location. A position off any identifier also returns an empty result."))) (EVar "medakaDefinitionSchema")) (EVar "runDefinitionTool"))))
(DTypeSig false "toolDescriptor" (TyFun (TyCon "McpTool") (TyCon "Json")))
(DFunDef false "toolDescriptor" ((PCon "McpTool" (PVar "name") (PVar "desc") (PVar "schema") PWild)) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (EVar "desc"))) (ETuple (ELit (LString "inputSchema")) (EVar "schema")))))
(DTypeSig false "callTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Json")))))))))
(DFunDef false "callTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "name") (PVar "args")) (EApp (EApp (EVar "map") (ELam ((PCon "McpTool" PWild PWild PWild (PVar "handler"))) (EApp (EApp (EApp (EApp (EVar "handler") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "args")))) (EApp (EApp (EVar "lookupTool") (EVar "name")) (EVar "mcpTools"))))
(DTypeSig false "lookupTool" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "McpTool")) (TyApp (TyCon "Option") (TyCon "McpTool")))))
(DFunDef false "lookupTool" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTool" ((PVar "name") (PCons (PVar "t") (PVar "ts"))) (EMatch (EVar "t") (arm (PCon "McpTool" (PVar "n") PWild PWild PWild) () (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "t")) (EApp (EApp (EVar "lookupTool") (EVar "name")) (EVar "ts"))))))
(DTypeSig false "medakaCheckSchema" (TyCon "Json"))
(DFunDef false "medakaCheckSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to check."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to check (no file on disk).")))))))))))))
(DTypeSig false "syntheticSourceName" (TyCon "String"))
(DFunDef false "syntheticSourceName" () (ELit (LString "<source>")))
(DTypeSig false "toolTextResult" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Json"))))
(DFunDef false "toolTextResult" ((PVar "text") (PVar "isErr")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "content")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "text")))) (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text")))))))) (ETuple (ELit (LString "isError")) (EApp (EVar "JBool") (EVar "isErr"))))))
(DTypeSig false "toolArgError" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "toolArgError" ((PVar "msg")) (EApp (EApp (EVar "toolTextResult") (EVar "msg")) (EVar "True")))
(DTypeSig false "runCheckTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runCheckTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "stdlibDir"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingle") (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "syntheticSourceName")) (EVar "src"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr")))))))
(DTypeSig false "medakaTypeAtSchema" (TyCon "Json"))
(DFunDef false "medakaTypeAtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column of the position (LSP-style, first column is 0).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "runTypeAtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTypeAtTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (ELit (LString "no symbol at this position"))) (EVar "False"))) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EVar "toolTextResult") (EVar "ty")) (EVar "False"))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "medakaSymbolsSchema" (TyCon "Json"))
(DFunDef false "medakaSymbolsSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to list symbols for.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "runSymbolsTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runSymbolsTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_symbols: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src"))))) (EVar "False")))))))
(DTypeSig false "medakaDefinitionSchema" (TyCon "Json"))
(DFunDef false "medakaDefinitionSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column of the position (LSP-style, first column is 0).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "positionParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "positionParams" ((PVar "line") (PVar "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))))))
(DTypeSig false "runDefinitionTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runDefinitionTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_definition: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EVar "definitionResult") (EVar "path")) (EVar "src")) (EApp (EApp (EVar "positionParams") (EVar "line")) (EVar "col"))))) (EVar "False"))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "handleToolsCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleToolsCall" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "idJson") (PVar "params")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "name"))) (EVar "params")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32602)))) (ELit (LString "tools/call: missing 'name'"))))) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "callTool") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "name")) (EApp (EApp (EVar "fieldOr") (ELit (LString "arguments"))) (EVar "params"))) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Unknown tool: ")) (EVar "name")))))) (arm (PCon "Some" (PVar "result")) () (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))))
(DTypeSig false "dispatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "dispatchMsg" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "msg")) (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EVar "logMcp") (ELit (LString "ignored: message has no string 'method' field")))) (arm (PCon "Some" (PVar "meth")) () (EBlock (DoLet false false (PVar "idJson") (EApp (EApp (EVar "fieldOr") (ELit (LString "id"))) (EVar "msg"))) (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "initializeResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "notifications/initialized"))) (EVar "unit") (EIf (EBinOp "==" (EVar "meth") (ELit (LString "ping"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/list"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "toolsListResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EApp (EApp (EApp (EApp (EApp (EVar "handleToolsCall") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "idJson")) (EVar "params")) (EMatch (EVar "idJson") (arm (PCon "JNull") () (EVar "unit")) (arm PWild () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Method not found: ")) (EVar "meth"))))))))))))))))))
(DTypeSig false "handleLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "handleLine" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "raw")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EVar "unit") (EMatch (EApp (EVar "parse") (EVar "line")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "parse error (skipped): ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "msg")) () (EApp (EApp (EApp (EApp (EVar "dispatchMsg") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "msg"))))))))
(DTypeSig false "serveLoop" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "serveLoop" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "handleLine") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "raw"))) (DoExpr (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")))))))
(DTypeSig true "runMcpServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "runMcpServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir")) (EBlock (DoLet false false PWild (EApp (EVar "logMcp") (ELit (LString "medaka mcp server start")))) (DoExpr (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JInt" false) (mem "JString" false) (mem "JBool" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false))))
(DUse false (UseGroup ("io") ((mem "stripCR" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "checkJsonSingle" false) (mem "checkJsonFile" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "typeAtPoint" false) (mem "documentSymbols" false) (mem "definitionResult" false))))
(DTypeSig false "mcpProtocolVersion" (TyCon "String"))
(DFunDef false "mcpProtocolVersion" () (ELit (LString "2024-11-05")))
(DTypeSig false "mcpServerVersion" (TyCon "String"))
(DFunDef false "mcpServerVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "errorMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "errorMsg" ((PVar "idJson") (PVar "code") (PVar "message")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EVar "code"))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message")))))))))
(DTypeSig false "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DTypeSig false "fieldInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "fieldInt" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "stringify") (EVar "j")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "logMcp" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logMcp" ((PVar "s")) (EApp (EVar "ePutStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "[mcp] ")) (EVar "s")))))
(DTypeSig false "initializeResult" (TyCon "Json"))
(DFunDef false "initializeResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "protocolVersion")) (EApp (EVar "JString") (EVar "mcpProtocolVersion"))) (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jObject") (EListLit)))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (EVar "mcpServerVersion")))))))))
(DTypeSig false "toolsListResult" (TyCon "Json"))
(DFunDef false "toolsListResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "toolDescriptor")) (EVar "mcpTools")))))))
(DData Private "McpTool" () ((variant "McpTool" (ConPos (TyCon "String") (TyCon "String") (TyCon "Json") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json"))))))))) ())
(DTypeSig false "mcpTools" (TyApp (TyCon "List") (TyCon "McpTool")))
(DFunDef false "mcpTools" () (EListLit (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_check"))) (ELit (LString "Type-check Medaka source and return structured diagnostics — the same JSON `medaka check --json` emits (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available). Provide exactly one of `file` or `source`."))) (EVar "medakaCheckSchema")) (EVar "runCheckTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_type_at"))) (ELit (LString "Infer the type/scheme at a position — the LSP hover, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style); returns the `<name> : <type>` at that point, resolving imported names against the project on disk. A position off any identifier returns a clean \"no symbol\" note, not an error."))) (EVar "medakaTypeAtSchema")) (EVar "runTypeAtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_symbols"))) (ELit (LString "List a file's top-level declarations (functions, data types, interfaces, impls, …) with their source ranges — the LSP document-symbol outline, driven statelessly. Give a `file` path; parse-only (no typecheck), so it works even on a file with type errors."))) (EVar "medakaSymbolsSchema")) (EVar "runSymbolsTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_definition"))) (ELit (LString "Find the declaration that defines the identifier at a position — the LSP go-to-definition, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style). INTRA-FILE ONLY: it scans declarations in this same file, so a use of a name defined in ANOTHER file returns an empty result rather than a wrong location. A position off any identifier also returns an empty result."))) (EVar "medakaDefinitionSchema")) (EVar "runDefinitionTool"))))
(DTypeSig false "toolDescriptor" (TyFun (TyCon "McpTool") (TyCon "Json")))
(DFunDef false "toolDescriptor" ((PCon "McpTool" (PVar "name") (PVar "desc") (PVar "schema") PWild)) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (EVar "desc"))) (ETuple (ELit (LString "inputSchema")) (EVar "schema")))))
(DTypeSig false "callTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Json")))))))))
(DFunDef false "callTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "name") (PVar "args")) (EApp (EApp (EMethodRef "map") (ELam ((PCon "McpTool" PWild PWild PWild (PVar "handler"))) (EApp (EApp (EApp (EApp (EVar "handler") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "args")))) (EApp (EApp (EVar "lookupTool") (EVar "name")) (EVar "mcpTools"))))
(DTypeSig false "lookupTool" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "McpTool")) (TyApp (TyCon "Option") (TyCon "McpTool")))))
(DFunDef false "lookupTool" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTool" ((PVar "name") (PCons (PVar "t") (PVar "ts"))) (EMatch (EVar "t") (arm (PCon "McpTool" (PVar "n") PWild PWild PWild) () (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "t")) (EApp (EApp (EVar "lookupTool") (EVar "name")) (EVar "ts"))))))
(DTypeSig false "medakaCheckSchema" (TyCon "Json"))
(DFunDef false "medakaCheckSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to check."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to check (no file on disk).")))))))))))))
(DTypeSig false "syntheticSourceName" (TyCon "String"))
(DFunDef false "syntheticSourceName" () (ELit (LString "<source>")))
(DTypeSig false "toolTextResult" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Json"))))
(DFunDef false "toolTextResult" ((PVar "text") (PVar "isErr")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "content")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "text")))) (ETuple (ELit (LString "text")) (EApp (EVar "JString") (EVar "text")))))))) (ETuple (ELit (LString "isError")) (EApp (EVar "JBool") (EVar "isErr"))))))
(DTypeSig false "toolArgError" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "toolArgError" ((PVar "msg")) (EApp (EApp (EVar "toolTextResult") (EVar "msg")) (EVar "True")))
(DTypeSig false "runCheckTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runCheckTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_check: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "stdlibDir"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingle") (EVar "False")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "syntheticSourceName")) (EVar "src"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EVar "json")) (EVar "hasErr")))))))
(DTypeSig false "medakaTypeAtSchema" (TyCon "Json"))
(DFunDef false "medakaTypeAtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column of the position (LSP-style, first column is 0).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "runTypeAtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTypeAtTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_type_at: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EApp (EApp (EVar "toolTextResult") (ELit (LString "no symbol at this position"))) (EVar "False"))) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EVar "toolTextResult") (EVar "ty")) (EVar "False"))))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_type_at: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "medakaSymbolsSchema" (TyCon "Json"))
(DFunDef false "medakaSymbolsSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to list symbols for.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "runSymbolsTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runSymbolsTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_symbols: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src"))))) (EVar "False")))))))
(DTypeSig false "medakaDefinitionSchema" (TyCon "Json"))
(DFunDef false "medakaDefinitionSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column of the position (LSP-style, first column is 0).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "positionParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "positionParams" ((PVar "line") (PVar "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))))))
(DTypeSig false "runDefinitionTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runDefinitionTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_definition: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EVar "definitionResult") (EVar "path")) (EVar "src")) (EApp (EApp (EVar "positionParams") (EVar "line")) (EVar "col"))))) (EVar "False"))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "handleToolsCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleToolsCall" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "idJson") (PVar "params")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "name"))) (EVar "params")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32602)))) (ELit (LString "tools/call: missing 'name'"))))) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "callTool") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "name")) (EApp (EApp (EVar "fieldOr") (ELit (LString "arguments"))) (EVar "params"))) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Unknown tool: ")) (EVar "name")))))) (arm (PCon "Some" (PVar "result")) () (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))))
(DTypeSig false "dispatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "dispatchMsg" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "msg")) (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EVar "logMcp") (ELit (LString "ignored: message has no string 'method' field")))) (arm (PCon "Some" (PVar "meth")) () (EBlock (DoLet false false (PVar "idJson") (EApp (EApp (EVar "fieldOr") (ELit (LString "id"))) (EVar "msg"))) (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "initializeResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "notifications/initialized"))) (EVar "unit") (EIf (EBinOp "==" (EVar "meth") (ELit (LString "ping"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/list"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "toolsListResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EApp (EApp (EApp (EApp (EApp (EVar "handleToolsCall") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "idJson")) (EVar "params")) (EMatch (EVar "idJson") (arm (PCon "JNull") () (EVar "unit")) (arm PWild () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Method not found: ")) (EVar "meth"))))))))))))))))))
(DTypeSig false "handleLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "handleLine" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "raw")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EVar "unit") (EMatch (EApp (EVar "parse") (EVar "line")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "parse error (skipped): ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "msg")) () (EApp (EApp (EApp (EApp (EVar "dispatchMsg") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "msg"))))))))
(DTypeSig false "serveLoop" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "serveLoop" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "handleLine") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "raw"))) (DoExpr (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")))))))
(DTypeSig true "runMcpServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "runMcpServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir")) (EBlock (DoLet false false PWild (EApp (EVar "logMcp") (ELit (LString "medaka mcp server start")))) (DoExpr (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
