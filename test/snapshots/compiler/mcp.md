# META
source_lines=916
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
  asArray,
}
import io.{stripCR}
import driver.diagnostics.{
  checkJsonSingle,
  checkJsonFile,
  cjAllToJson,
  diagIsError,
  Diag,
}
import tools.lsp.{typeAtPoint, documentSymbols, definitionResult}
import frontend.parser.{
  parseResult,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
}
import tools.fmt.{formatSource}
import tools.lint.{lintFileDiagTriple, splitLintNames}
import tools.test_cmd.{runTestReport}
import tools.doctest.{
  Example,
  ExResult(..),
  RunResult,
  exampleInput,
  exampleLine,
  runPassed,
  runFailed,
  runErrors,
  runDetails,
}
import tools.prop_runner.{
  PropResult,
  propResultName,
  propResultPassed,
  propResultDetail,
}

-- ── protocol / server identity ──────────────────────────────────────────────

-- Protocol revisions this server negotiates, oldest first.  This server is a
-- basic tools-only server (no resources/prompts/sampling), so its wire shape
-- has been protocol-compatible across every revision the SDK has shipped —
-- there's nothing here that changed shape between "2024-11-05" and
-- "2025-11-25". Listed explicitly (rather than derived) per the MCP spec's
-- negotiation rule: echo the client's requested version if it's in this set,
-- else fall back to the newest.
mcpSupportedVersions : List String
mcpSupportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

-- The newest supported revision — returned when the client's requested
-- version is missing or not in `mcpSupportedVersions`.
mcpLatestVersion : String
mcpLatestVersion = "2025-11-25"

-- Negotiate the protocol version for an `initialize` request: echo the
-- client's `params.protocolVersion` back if the server supports it, else
-- fall back to `mcpLatestVersion` (also covers a missing/non-string field).
negotiateVersion : Json -> String
negotiateVersion msg =
  let params = fieldOr "params" msg
  match fieldStr "protocolVersion" params
    Some v => if elem v mcpSupportedVersions then v else mcpLatestVersion
    None => mcpLatestVersion

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

initializeResultFor : String -> Json
initializeResultFor version = jObject
  [
    ("protocolVersion", JString version),
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
  McpTool "medaka_symbols" "List a file's top-level declarations (functions, data types, interfaces, impls, …) with their source ranges — the LSP document-symbol outline, driven statelessly. Give a `file` path; parse-only (no typecheck), so it works even on a file with type errors. A multi-clause function collapses to ONE entry (its signature + all clauses), not one-per-clause. A file that fails to PARSE returns a distinct isError result — `{\"parseError\": true, \"line\", \"col\", \"message\"}` — so you can tell an empty/no-decl file (empty list) from a broken one (parseError). Ranges are line-granular (`character` is 0; #331 tracks true name-column fidelity)." medakaSymbolsSchema runSymbolsTool,
  McpTool "medaka_definition" "Find the declaration that defines the identifier at a position — the LSP go-to-definition, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style). INTRA-FILE ONLY: it scans declarations in this same file, so a use of a name defined in ANOTHER file returns an empty result rather than a wrong location. A position off any identifier also returns an empty result." medakaDefinitionSchema runDefinitionTool,
  McpTool "medaka_fmt" "Format Medaka source with the compiler's canonical formatter (`medaka fmt`), driven statelessly. Provide exactly one of `file` or `source`. NEVER writes to disk — a `file` argument is only READ, never opened for writing; apply the returned text yourself if you want it saved. Default: returns the formatted source text. Pass `check: true` to instead get a clean/dirty verdict (`{\"clean\": true|false}`) without the full text. Input that fails to PARSE returns an isError result carrying the parse diagnostic, never a crash." medakaFmtSchema runFmtTool,
  McpTool "medaka_lint" "Run the compiler's style linter (`medaka lint`) over one or more files and return structured diagnostics — the same JSON envelope `medaka_check`/`medaka lint --json` emit (stable `range`/`severity`/`source`, with the lint RULE NAME in `code`). Give `paths` (array of file paths); optionally narrow with comma-separated `deny`/`only`/`disable` rule-name lists (mirror the CLI's --deny/--only/--disable). Report-only — no autofix; apply a fix yourself if you want one." medakaLintSchema runLintTool,
  McpTool "medaka_test" "Run a file's doctests (and property tests, if any) and return structured PER-EXAMPLE results. Give a `file` path. Runs DOCTESTS and PROPERTY tests only — bare `test \"…\"` decls are NOT run here (they run under the human `medaka test` command). ⚠️ RESULTS ARE UNDER THE INTERPRETER (eval), NOT the native backend — a native-only miscompile is INVISIBLE here (a file can show every doctest green over a grammar the native binary silently mis-lowers, #81), so treat these as \"passes UNDER EVAL\", never an unqualified \"passes\". Returns `{file, engine:\"eval\", note, doctests:{total,passed,failed,errors,examples:[{line,input,status:pass|fail|error,expected?,actual?,detail?}]}, properties:[{name,status,detail}], summary:{passed,failed,ok}}`. A property's FAILING counterexample is RNG-dependent (non-portable). `isError` is true iff any doctest or property did not pass." medakaTestSchema runTestTool,
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

-- Turn resolved source into a symbols result.  Parse FIRST (via parseResult, the
-- same located-diagnostic path medaka_fmt uses) so a genuinely empty/no-decl file
-- (empty `[]`, isError:false) is DISTINGUISHABLE from one that failed to parse
-- (#300 part 1): a parse failure yields a distinct structured note
-- `{"parseError":true, line, col, message}` with isError:true, instead of the same
-- `[]` an empty file returns.  documentSymbols itself is parse-only and returns
-- `[]` on unparseable input, which is exactly the ambiguity we resolve here.
symbolsResult : String -> Json
symbolsResult src = match parseResult src
  Err e => toolTextResult (stringify (jObject [
    ("parseError", JBool True),
    ("line", JInt (parseErrorLine e)),
    ("col", JInt (parseErrorCol e)),
    ("message", JString (parseErrorMessage e)),
  ])) True
  Ok _ => toolTextResult (stringify (jArray (documentSymbols src))) False

-- medaka_symbols handler: read `file` from disk and return its top-level decl
-- symbols (tools.lsp.documentSymbols), serialized as a JSON array in a text
-- content block.  Parse-only (no typecheck) — never errors on an ill-typed
-- file, only on a missing/unreadable one.  A file that fails to PARSE returns a
-- distinct isError parseError note (symbolsResult), NOT the empty `[]` an empty
-- file returns — so a caller can tell 'no decls' from 'parser bailed' (#300 p1).
runSymbolsTool : String -> String -> String -> Json -> <IO> Json
runSymbolsTool _runtimeSrc _coreSrc _stdlibDir args = match fieldStr "file" args
  None => toolArgError "medaka_symbols: missing or invalid argument — require 'file' (string)"
  Some path => match readFile path
    Err e => toolArgError (stringConcat ["medaka_symbols: cannot read file '", path, "': ", e])
    Ok src => symbolsResult src

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

-- ── medaka_fmt tool ───────────────────────────────────────────────────────────

-- inputSchema: exactly one of `file` (path) or `source` (inline text); optional
-- `check` (boolean, default false — see medakaFmtSchema's own "check" doc).
medakaFmtSchema : Json
medakaFmtSchema = jObject
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
              JString "Path to a .mdk file to format. READ ONLY — the file is never written; the formatted text is returned for the caller to apply.",
            ),
          ],
        ),
        (
          "source",
          jObject [
            ("type", JString "string"),
            (
              "description",
              JString "Inline Medaka source to format (no file on disk).",
            ),
          ],
        ),
        (
          "check",
          jObject [
            ("type", JString "boolean"),
            (
              "description",
              JString "If true, report clean/dirty instead of returning the formatted text (default false).",
            ),
          ],
        ),
      ],
    ),
  ]

-- Boolean field accessor with a default: absent key or a non-boolean JSON
-- value both fall back to `dflt` (an argument-shape error, not a crash — the
-- caller reports it, same policy as fieldStr/fieldInt).
fieldBoolOr : String -> Bool -> Json -> Bool
fieldBoolOr key dflt j = match lookup key j
  Some (JBool b) => b
  _ => dflt

-- Format (or format-check) already-resolved source text.  `formatSource`
-- PANICS on unparseable input (`parseWithPositions`'s documented
-- panic-on-unparseable contract, compiler/frontend/parser.mdk) — a panic here
-- would crash the whole MCP server process, so parseability is checked FIRST,
-- mirroring `formattingEdits`'s `Err _ => []` short-circuit
-- (compiler/tools/lsp.mdk:236-237). Unlike that LSP path — which has a client
-- buffer to silently leave alone — an MCP caller gets an explicit isError
-- result carrying the located parse diagnostic, never a silent no-op.
fmtResult : Bool -> String -> Json
fmtResult check src = match parseResult src
  Err e =>
    let loc = stringConcat [
      "line ",
      intToString (parseErrorLine e),
      ", col ",
      intToString (parseErrorCol e),
    ]
    toolArgError (stringConcat
      ["medaka_fmt: source does not parse (", loc, "): ", parseErrorMessage e])
  Ok _ =>
    let formatted = formatSource src
    if check then
      toolTextResult (stringify (jObject [("clean", JBool (formatted == src))])) False
    else
      toolTextResult formatted False

-- medaka_fmt handler: format `file` XOR `source` and return either the
-- formatted text (default) or a `{"clean": bool}` verdict (`check: true`).
-- NEVER writes to disk: `file` is only ever passed to `readFile`, never opened
-- for writing, and no branch here shells out to `fmt --write` — the tree's
-- worst known source-destroyer (#51: a float literal ≥1e15 round-trips to a
-- form the lexer can't read back). The formatted text is returned for the
-- CALLER to apply, exactly as the issue's guardrail requires.
runFmtTool : String -> String -> String -> Json -> <IO> Json
runFmtTool _runtimeSrc _coreSrc _stdlibDir args =
  let check = fieldBoolOr "check" False args
  match (fieldStr "file" args, fieldStr "source" args)
    (Some _, Some _) => toolArgError "medaka_fmt: provide exactly one of 'file' or 'source', not both"
    (None, None) => toolArgError "medaka_fmt: missing argument — provide exactly one of 'file' or 'source'"
    (Some path, None) => match readFile path
      Err e => toolArgError (stringConcat ["medaka_fmt: cannot read file '", path, "': ", e])
      Ok src => fmtResult check src
    (None, Some src) => fmtResult check src

-- ── medaka_lint tool ──────────────────────────────────────────────────────────

-- inputSchema: `paths` (array of file path strings, required) plus the
-- lint CLI's rule-name-list flags as comma-separated strings — `deny`/`only`/
-- `disable` (mirrors --deny/--only/--disable). Report-only (#249): no `--fix`
-- equivalent — a suggesting rule must prove its fix compiles (TOOLING.md /
-- #56) and report-only sidesteps that for v1.
medakaLintSchema : Json
medakaLintSchema = jObject
  [
    ("type", JString "object"),
    (
      "properties",
      jObject [
        (
          "paths",
          jObject [
            ("type", JString "array"),
            ("items", jObject [("type", JString "string")]),
            ("description", JString "Paths to .mdk files to lint."),
          ],
        ),
        (
          "deny",
          jObject [
            ("type", JString "string"),
            (
              "description",
              JString "Comma-separated rule names to promote to error severity (mirrors --deny).",
            ),
          ],
        ),
        (
          "only",
          jObject [
            ("type", JString "string"),
            (
              "description",
              JString "Comma-separated rule names to keep, dropping findings from every other rule (mirrors --only).",
            ),
          ],
        ),
        (
          "disable",
          jObject [
            ("type", JString "string"),
            (
              "description",
              JString "Comma-separated rule names to suppress (mirrors --disable).",
            ),
          ],
        ),
      ],
    ),
    ("required", jArray [JString "paths"]),
  ]

-- Convert a JArray's backing Array into a List. arrayLength/arrayGetUnsafe are
-- core builtins (no stdlib import needed) — mirrors eval.mdk's arrayToListG,
-- duplicated here rather than pulling in the `array` stdlib module (a new
-- import surface) for this one conversion.
jsonArrToList : Array Json -> List Json
jsonArrToList arr = jsonArrToListGo arr 0 (arrayLength arr)

jsonArrToListGo : Array Json -> Int -> Int -> List Json
jsonArrToListGo arr i n
  | i >= n = []
  | otherwise = arrayGetUnsafe i arr :: jsonArrToListGo arr (i + 1) n

-- `paths` -> `List String`, or `None` if missing, not a JSON array, or
-- containing any non-string element — a malformed `paths` is reported as an
-- argument error, never silently dropped/skipped element-by-element.
pathsArg : Json -> Option (List String)
pathsArg args = match lookup "paths" args
  None => None
  Some v => match asArray v
    None => None
    Some arr => allJsonStrings (jsonArrToList arr)

allJsonStrings : List Json -> Option (List String)
allJsonStrings [] = Some []
allJsonStrings (j::rest) = match (asString j, allJsonStrings rest)
  (Some s, Some ss) => Some (s::ss)
  _ => None

-- Optional comma-separated rule-name-list argument -> `List String`. Absent or
-- empty-string -> `[]` (no filtering); reuses `tools.lint.splitLintNames` (the
-- exact splitter `parseLintFlagList` uses for the CLI's `--deny=`/`--only=`/
-- `--disable=` flags) so the CLI and MCP surfaces can never parse "a,b,c"
-- differently.
lintNameListArg : String -> Json -> List String
lintNameListArg key args = match fieldStr key args
  None => []
  Some "" => []
  Some s => splitLintNames s

-- Sequence `lintFileDiagTriple` over every target path, in order (same
-- explicit-recursion idiom `medaka_cli.mdk`'s `lintFilesToDiagTriples` uses —
-- `map` over an effectful function is not how this codebase sequences an
-- `<IO>` list traversal).
lintPathsToDiagTriples : List String -> List String -> List String -> List String -> <IO> List (String, String, List Diag)
lintPathsToDiagTriples _ _ _ [] = []
lintPathsToDiagTriples disable only deny (p::rest) =
  lintFileDiagTriple disable only deny p ::
    lintPathsToDiagTriples disable only deny rest

anyTripleHasErr : List (String, String, List Diag) -> Bool
anyTripleHasErr [] = False
anyTripleHasErr ((_, _, diags)::rest) = anyDiagErr diags || anyTripleHasErr rest

anyDiagErr : List Diag -> Bool
anyDiagErr [] = False
anyDiagErr (d::rest) = diagIsError d || anyDiagErr rest

-- medaka_lint handler: run the lint pipeline (all rules, inline
-- `-- lint-disable-*` suppression, then the `disable`/`only`/`deny` filters)
-- over every path in `paths` and return the SAME `{"files":[...]}` envelope
-- `medaka_check`/`medaka lint --json` emit (via `cjAllToJson`) — one schema
-- across all three surfaces. Each `Finding` becomes a `Diag` via
-- `findingToDiag` (inside `lintFileDiagTriple`), which stamps the lint RULE
-- NAME into the diagnostic's `code`. `isError` is true iff any diagnostic is a
-- hard error (severity 1) — only reachable via `deny` promotion, since every
-- seed rule defaults to SevWarning.
runLintTool : String -> String -> String -> Json -> <IO> Json
runLintTool _runtimeSrc _coreSrc _stdlibDir args = match pathsArg args
  None => toolArgError "medaka_lint: missing or invalid argument — require 'paths' (array of strings)"
  Some paths =>
    let disable = lintNameListArg "disable" args
    let only = lintNameListArg "only" args
    let deny = lintNameListArg "deny" args
    let triples = lintPathsToDiagTriples disable only deny paths
    toolTextResult (cjAllToJson triples) (anyTripleHasErr triples)

-- ── medaka_test tool ──────────────────────────────────────────────────────────

-- inputSchema: `file` (path), required.
medakaTestSchema : Json
medakaTestSchema = jObject
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
              JString "Path to the .mdk file whose doctests (and property tests, if any) to run.",
            ),
          ],
        )
      ],
    ),
    ("required", jArray [JString "file"]),
  ]

-- The per-example fields, keyed by outcome.  A smoke example (no expected line)
-- that evaluated cleanly is `Pass` with no expected/actual; a `Fail` carries
-- both; an `Errored` carries the message under `detail`.
exResultFields : ExResult -> List (String, Json)
exResultFields Pass = [("status", JString "pass")]
exResultFields (Fail expected actual) = [
  ("status", JString "fail"),
  ("expected", JString expected),
  ("actual", JString actual),
]
exResultFields (Errored msg) =
  [("status", JString "error"), ("detail", JString msg)]

exampleJson : (Example, ExResult) -> Json
exampleJson (ex, res) =
  jObject
    ([("line", JInt (exampleLine ex)), ("input", JString (exampleInput ex))] ++ exResultFields res)

doctestsJson : RunResult -> Json
doctestsJson run = jObject
  [
    ("total", JInt (runPassed run + runFailed run + runErrors run)),
    ("passed", JInt (runPassed run)),
    ("failed", JInt (runFailed run)),
    ("errors", JInt (runErrors run)),
    ("examples", jArray (map exampleJson (runDetails run))),
  ]

propJson : PropResult -> Json
propJson p = jObject
  [
    ("name", JString (propResultName p)),
    ("status", JString (if propResultPassed p then "pass" else "fail")),
    ("detail", JString (propResultDetail p)),
  ]

allPropsPass : List PropResult -> Bool
allPropsPass [] = True
allPropsPass (p::rest) = propResultPassed p && allPropsPass rest

countPassProps : List PropResult -> Int
countPassProps [] = 0
countPassProps (p::rest) =
  (if propResultPassed p then 1 else 0) + countPassProps rest

countFailProps : List PropResult -> Int
countFailProps [] = 0
countFailProps (p::rest) =
  (if propResultPassed p then 0 else 1) + countFailProps rest

-- The run OVERALL passed iff every doctest and every property passed.  Drives
-- both the `summary.ok` field and the result's `isError` flag.
testReportOk : RunResult -> List PropResult -> Bool
testReportOk run props = runFailed run == 0
  && runErrors run == 0
  && allPropsPass props

-- The full structured result body.  `engine`/`note` carry the interpreter caveat
-- INTO the payload (not just the tool description) so a consumer that never read
-- the description is still told these results are eval-only.
testReportJson : String -> RunResult -> List PropResult -> Json
testReportJson path run props = jObject
  [
    ("file", JString path),
    ("engine", JString "eval"),
    (
      "note",
      JString "Results are under the interpreter (eval), NOT the native backend — a native-only miscompile is not observed here (see #81). Report these as passing UNDER EVAL, not unqualified.",
    ),
    ("doctests", doctestsJson run),
    ("properties", jArray (map propJson props)),
    (
      "summary",
      jObject [
        ("passed", JInt (runPassed run + countPassProps props)),
        ("failed", JInt (runFailed run + runErrors run + countFailProps props)),
        ("ok", JBool (testReportOk run props)),
      ],
    ),
  ]

-- medaka_test handler: read `file`, run its doctests + props through the
-- non-printing structured reporter (tools.test_cmd.runTestReport), and return
-- the per-example/per-property JSON.  isError=true iff any example/property
-- failed (mirrors medaka_check's convention: isError flags a bad OUTCOME, with
-- the detail in the structured content).  A missing/unreadable file is an
-- argument error, not a crash.  Results are eval-only — see the tool
-- description and the payload's `note`.
runTestTool : String -> String -> String -> Json -> <IO> Json
runTestTool runtimeSrc coreSrc stdlibDir args = match fieldStr "file" args
  None => toolArgError "medaka_test: missing or invalid argument — require 'file' (string)"
  Some path => match readFile path
    Err e => toolArgError (stringConcat ["medaka_test: cannot read file '", path, "': ", e])
    Ok tsrc =>
      let (run, props) = runTestReport runtimeSrc coreSrc path tsrc stdlibDir
      toolTextResult
        (stringify (testReportJson path run props))
        (not (testReportOk run props))

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
-- response; notifications have no `id` and get none — detected by whether the
-- `id` KEY IS PRESENT at all (`lookup`), not by `fieldOr`'s JNull default,
-- which can't tell "absent" from "explicitly null".  This id-presence check
-- gates EVERY recognized method uniformly (a no-id `ping`/`tools/call`/
-- `initialize` gets no reply, exactly like a no-id unrecognized method would).
-- An unrecognized *request* returns method-not-found (-32601); an unrecognized
-- *notification* is ignored.  A top-level batch array (`[{...},{...}]`) is not
-- a supported transport shape here — it gets one Invalid Request error rather
-- than being silently dropped.
dispatchMsg : String -> String -> String -> Json -> <IO> Unit
dispatchMsg runtimeSrc coreSrc stdlibDir msg = match asArray msg
  Some _ => writeMessage
    (errorMsg JNull (0 - 32600) "Invalid Request: batch requests are not supported")
  None => match methodOf msg
    None => logMcp "ignored: message has no string 'method' field"
    Some meth =>
      let params = fieldOr "params" msg
      if meth == "notifications/initialized" then unit
      else match lookup "id" msg
        None => unit -- notification: no response for ANY method
        Some idJson =>
          if meth == "initialize" then
            writeMessage (responseMsg idJson (initializeResultFor (negotiateVersion msg)))
          else
            if meth == "ping" then writeMessage (responseMsg idJson (jObject []))
            else
              if meth == "shutdown" then writeMessage (responseMsg idJson (jObject []))
              else
                if meth == "tools/list" then writeMessage (responseMsg idJson toolsListResult)
                else
                  if meth == "tools/call" then
                    handleToolsCall runtimeSrc coreSrc stdlibDir idJson params
                  else writeMessage
                    (errorMsg idJson (0 - 32601) (stringConcat ["Method not found: ", meth]))

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
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JInt" false) (mem "JString" false) (mem "JBool" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false))))
(DUse false (UseGroup ("io") ((mem "stripCR" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "checkJsonSingle" false) (mem "checkJsonFile" false) (mem "cjAllToJson" false) (mem "diagIsError" false) (mem "Diag" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "typeAtPoint" false) (mem "documentSymbols" false) (mem "definitionResult" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "lintFileDiagTriple" false) (mem "splitLintNames" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTestReport" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "runDetails" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" false) (mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false))))
(DTypeSig false "mcpSupportedVersions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mcpSupportedVersions" () (EListLit (ELit (LString "2024-11-05")) (ELit (LString "2025-03-26")) (ELit (LString "2025-06-18")) (ELit (LString "2025-11-25"))))
(DTypeSig false "mcpLatestVersion" (TyCon "String"))
(DFunDef false "mcpLatestVersion" () (ELit (LString "2025-11-25")))
(DTypeSig false "negotiateVersion" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "negotiateVersion" ((PVar "msg")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "protocolVersion"))) (EVar "params")) (arm (PCon "Some" (PVar "v")) () (EIf (EApp (EApp (EVar "elem") (EVar "v")) (EVar "mcpSupportedVersions")) (EVar "v") (EVar "mcpLatestVersion"))) (arm (PCon "None") () (EVar "mcpLatestVersion"))))))
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
(DTypeSig false "initializeResultFor" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "initializeResultFor" ((PVar "version")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "protocolVersion")) (EApp (EVar "JString") (EVar "version"))) (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jObject") (EListLit)))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (EVar "mcpServerVersion")))))))))
(DTypeSig false "toolsListResult" (TyCon "Json"))
(DFunDef false "toolsListResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "toolDescriptor")) (EVar "mcpTools")))))))
(DData Private "McpTool" () ((variant "McpTool" (ConPos (TyCon "String") (TyCon "String") (TyCon "Json") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json"))))))))) ())
(DTypeSig false "mcpTools" (TyApp (TyCon "List") (TyCon "McpTool")))
(DFunDef false "mcpTools" () (EListLit (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_check"))) (ELit (LString "Type-check Medaka source and return structured diagnostics — the same JSON `medaka check --json` emits (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available). Provide exactly one of `file` or `source`."))) (EVar "medakaCheckSchema")) (EVar "runCheckTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_type_at"))) (ELit (LString "Infer the type/scheme at a position — the LSP hover, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style); returns the `<name> : <type>` at that point, resolving imported names against the project on disk. A position off any identifier returns a clean \"no symbol\" note, not an error."))) (EVar "medakaTypeAtSchema")) (EVar "runTypeAtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_symbols"))) (ELit (LString "List a file's top-level declarations (functions, data types, interfaces, impls, …) with their source ranges — the LSP document-symbol outline, driven statelessly. Give a `file` path; parse-only (no typecheck), so it works even on a file with type errors. A multi-clause function collapses to ONE entry (its signature + all clauses), not one-per-clause. A file that fails to PARSE returns a distinct isError result — `{\"parseError\": true, \"line\", \"col\", \"message\"}` — so you can tell an empty/no-decl file (empty list) from a broken one (parseError). Ranges are line-granular (`character` is 0; #331 tracks true name-column fidelity)."))) (EVar "medakaSymbolsSchema")) (EVar "runSymbolsTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_definition"))) (ELit (LString "Find the declaration that defines the identifier at a position — the LSP go-to-definition, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style). INTRA-FILE ONLY: it scans declarations in this same file, so a use of a name defined in ANOTHER file returns an empty result rather than a wrong location. A position off any identifier also returns an empty result."))) (EVar "medakaDefinitionSchema")) (EVar "runDefinitionTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_fmt"))) (ELit (LString "Format Medaka source with the compiler's canonical formatter (`medaka fmt`), driven statelessly. Provide exactly one of `file` or `source`. NEVER writes to disk — a `file` argument is only READ, never opened for writing; apply the returned text yourself if you want it saved. Default: returns the formatted source text. Pass `check: true` to instead get a clean/dirty verdict (`{\"clean\": true|false}`) without the full text. Input that fails to PARSE returns an isError result carrying the parse diagnostic, never a crash."))) (EVar "medakaFmtSchema")) (EVar "runFmtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_lint"))) (ELit (LString "Run the compiler's style linter (`medaka lint`) over one or more files and return structured diagnostics — the same JSON envelope `medaka_check`/`medaka lint --json` emit (stable `range`/`severity`/`source`, with the lint RULE NAME in `code`). Give `paths` (array of file paths); optionally narrow with comma-separated `deny`/`only`/`disable` rule-name lists (mirror the CLI's --deny/--only/--disable). Report-only — no autofix; apply a fix yourself if you want one."))) (EVar "medakaLintSchema")) (EVar "runLintTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_test"))) (ELit (LString "Run a file's doctests (and property tests, if any) and return structured PER-EXAMPLE results. Give a `file` path. Runs DOCTESTS and PROPERTY tests only — bare `test \"…\"` decls are NOT run here (they run under the human `medaka test` command). ⚠️ RESULTS ARE UNDER THE INTERPRETER (eval), NOT the native backend — a native-only miscompile is INVISIBLE here (a file can show every doctest green over a grammar the native binary silently mis-lowers, #81), so treat these as \"passes UNDER EVAL\", never an unqualified \"passes\". Returns `{file, engine:\"eval\", note, doctests:{total,passed,failed,errors,examples:[{line,input,status:pass|fail|error,expected?,actual?,detail?}]}, properties:[{name,status,detail}], summary:{passed,failed,ok}}`. A property's FAILING counterexample is RNG-dependent (non-portable). `isError` is true iff any doctest or property did not pass."))) (EVar "medakaTestSchema")) (EVar "runTestTool"))))
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
(DTypeSig false "symbolsResult" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "symbolsResult" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "parseError")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "parseErrorLine") (EVar "e")))) (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EApp (EVar "parseErrorCol") (EVar "e")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (EVar "True"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src"))))) (EVar "False")))))
(DTypeSig false "runSymbolsTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runSymbolsTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_symbols: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "symbolsResult") (EVar "src")))))))
(DTypeSig false "medakaDefinitionSchema" (TyCon "Json"))
(DFunDef false "medakaDefinitionSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column of the position (LSP-style, first column is 0).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "positionParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "positionParams" ((PVar "line") (PVar "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))))))
(DTypeSig false "runDefinitionTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runDefinitionTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_definition: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EVar "definitionResult") (EVar "path")) (EVar "src")) (EApp (EApp (EVar "positionParams") (EVar "line")) (EVar "col"))))) (EVar "False"))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "medakaFmtSchema" (TyCon "Json"))
(DFunDef false "medakaFmtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to format. READ ONLY — the file is never written; the formatted text is returned for the caller to apply."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to format (no file on disk)."))))))) (ETuple (ELit (LString "check")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "If true, report clean/dirty instead of returning the formatted text (default false).")))))))))))))
(DTypeSig false "fieldBoolOr" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Json") (TyCon "Bool")))))
(DFunDef false "fieldBoolOr" ((PVar "key") (PVar "dflt") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "dflt"))))
(DTypeSig false "fmtResult" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "fmtResult" ((PVar "check") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "loc") (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EApp (EVar "parseErrorLine") (EVar "e"))) (ELit (LString ", col ")) (EApp (EVar "intToString") (EApp (EVar "parseErrorCol") (EVar "e")))))) (DoExpr (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: source does not parse (")) (EVar "loc") (ELit (LString "): ")) (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EIf (EVar "check") (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "clean")) (EApp (EVar "JBool") (EBinOp "==" (EVar "formatted") (EVar "src")))))))) (EVar "False")) (EApp (EApp (EVar "toolTextResult") (EVar "formatted")) (EVar "False"))))))))
(DTypeSig false "runFmtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runFmtTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EBlock (DoLet false false (PVar "check") (EApp (EApp (EApp (EVar "fieldBoolOr") (ELit (LString "check"))) (EVar "False")) (EVar "args"))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_fmt: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_fmt: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "fmtResult") (EVar "check")) (EVar "src"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EApp (EApp (EVar "fmtResult") (EVar "check")) (EVar "src")))))))
(DTypeSig false "medakaLintSchema" (TyCon "Json"))
(DFunDef false "medakaLintSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "paths")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "array")))) (ETuple (ELit (LString "items")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string"))))))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Paths to .mdk files to lint."))))))) (ETuple (ELit (LString "deny")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to promote to error severity (mirrors --deny)."))))))) (ETuple (ELit (LString "only")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to keep, dropping findings from every other rule (mirrors --only)."))))))) (ETuple (ELit (LString "disable")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to suppress (mirrors --disable).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "paths")))))))))
(DTypeSig false "jsonArrToList" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "jsonArrToList" ((PVar "arr")) (EApp (EApp (EApp (EVar "jsonArrToListGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "jsonArrToListGo" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "jsonArrToListGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EApp (EApp (EApp (EVar "jsonArrToListGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pathsArg" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pathsArg" ((PVar "args")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "paths"))) (EVar "args")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asArray") (EVar "v")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "arr")) () (EApp (EVar "allJsonStrings") (EApp (EVar "jsonArrToList") (EVar "arr"))))))))
(DTypeSig false "allJsonStrings" (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "allJsonStrings" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "allJsonStrings" ((PCons (PVar "j") (PVar "rest"))) (EMatch (ETuple (EApp (EVar "asString") (EVar "j")) (EApp (EVar "allJsonStrings") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "s")) (PCon "Some" (PVar "ss"))) () (EApp (EVar "Some") (EBinOp "::" (EVar "s") (EVar "ss")))) (arm PWild () (EVar "None"))))
(DTypeSig false "lintNameListArg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintNameListArg" ((PVar "key") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (EVar "key")) (EVar "args")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PLit (LString ""))) () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "splitLintNames") (EVar "s")))))
(DTypeSig false "lintPathsToDiagTriples" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "lintPathsToDiagTriples" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintPathsToDiagTriples" ((PVar "disable") (PVar "only") (PVar "deny") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagTriples") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "rest"))))
(DTypeSig false "anyTripleHasErr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Bool")))
(DFunDef false "anyTripleHasErr" ((PList)) (EVar "False"))
(DFunDef false "anyTripleHasErr" ((PCons (PTuple PWild PWild (PVar "diags")) (PVar "rest"))) (EBinOp "||" (EApp (EVar "anyDiagErr") (EVar "diags")) (EApp (EVar "anyTripleHasErr") (EVar "rest"))))
(DTypeSig false "anyDiagErr" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Bool")))
(DFunDef false "anyDiagErr" ((PList)) (EVar "False"))
(DFunDef false "anyDiagErr" ((PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "diagIsError") (EVar "d")) (EApp (EVar "anyDiagErr") (EVar "rest"))))
(DTypeSig false "runLintTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runLintTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EVar "pathsArg") (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_lint: missing or invalid argument — require 'paths' (array of strings)")))) (arm (PCon "Some" (PVar "paths")) () (EBlock (DoLet false false (PVar "disable") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "disable"))) (EVar "args"))) (DoLet false false (PVar "only") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "only"))) (EVar "args"))) (DoLet false false (PVar "deny") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "deny"))) (EVar "args"))) (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagTriples") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "paths"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "cjAllToJson") (EVar "triples"))) (EApp (EVar "anyTripleHasErr") (EVar "triples"))))))))
(DTypeSig false "medakaTestSchema" (TyCon "Json"))
(DFunDef false "medakaTestSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file whose doctests (and property tests, if any) to run.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "exResultFields" (TyFun (TyCon "ExResult") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "exResultFields" ((PCon "Pass")) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "pass"))))))
(DFunDef false "exResultFields" ((PCon "Fail" (PVar "expected") (PVar "actual"))) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "fail")))) (ETuple (ELit (LString "expected")) (EApp (EVar "JString") (EVar "expected"))) (ETuple (ELit (LString "actual")) (EApp (EVar "JString") (EVar "actual")))))
(DFunDef false "exResultFields" ((PCon "Errored" (PVar "msg"))) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "error")))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "msg")))))
(DTypeSig false "exampleJson" (TyFun (TyTuple (TyCon "Example") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "exampleJson" ((PTuple (PVar "ex") (PVar "res"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "exampleLine") (EVar "ex")))) (ETuple (ELit (LString "input")) (EApp (EVar "JString") (EApp (EVar "exampleInput") (EVar "ex"))))) (EApp (EVar "exResultFields") (EVar "res")))))
(DTypeSig false "doctestsJson" (TyFun (TyCon "RunResult") (TyCon "Json")))
(DFunDef false "doctestsJson" ((PVar "run")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "total")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "runFailed") (EVar "run"))) (EApp (EVar "runErrors") (EVar "run"))))) (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EApp (EVar "runPassed") (EVar "run")))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EApp (EVar "runFailed") (EVar "run")))) (ETuple (ELit (LString "errors")) (EApp (EVar "JInt") (EApp (EVar "runErrors") (EVar "run")))) (ETuple (ELit (LString "examples")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "exampleJson")) (EApp (EVar "runDetails") (EVar "run"))))))))
(DTypeSig false "propJson" (TyFun (TyCon "PropResult") (TyCon "Json")))
(DFunDef false "propJson" ((PVar "p")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "p")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LString "pass")) (ELit (LString "fail"))))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "p")))))))
(DTypeSig false "allPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool")))
(DFunDef false "allPropsPass" ((PList)) (EVar "True"))
(DFunDef false "allPropsPass" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "propResultPassed") (EVar "p")) (EApp (EVar "allPropsPass") (EVar "rest"))))
(DTypeSig false "countPassProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "countPassProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countPassProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "countPassProps") (EVar "rest"))))
(DTypeSig false "countFailProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "countFailProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countFailProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "countFailProps") (EVar "rest"))))
(DTypeSig false "testReportOk" (TyFun (TyCon "RunResult") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool"))))
(DFunDef false "testReportOk" ((PVar "run") (PVar "props")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "run")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "run")) (ELit (LInt 0)))) (EApp (EVar "allPropsPass") (EVar "props"))))
(DTypeSig false "testReportJson" (TyFun (TyCon "String") (TyFun (TyCon "RunResult") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Json")))))
(DFunDef false "testReportJson" ((PVar "path") (PVar "run") (PVar "props")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (ELit (LString "eval")))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (ELit (LString "Results are under the interpreter (eval), NOT the native backend — a native-only miscompile is not observed here (see #81). Report these as passing UNDER EVAL, not unqualified.")))) (ETuple (ELit (LString "doctests")) (EApp (EVar "doctestsJson") (EVar "run"))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "propJson")) (EVar "props")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "countPassProps") (EVar "props"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EVar "run")) (EApp (EVar "runErrors") (EVar "run"))) (EApp (EVar "countFailProps") (EVar "props"))))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EVar "testReportOk") (EVar "run")) (EVar "props"))))))))))
(DTypeSig false "runTestTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTestTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_test: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_test: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "tsrc")) () (EBlock (DoLet false false (PTuple (PVar "run") (PVar "props")) (EApp (EApp (EApp (EApp (EApp (EVar "runTestReport") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "tsrc")) (EVar "stdlibDir"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EVar "testReportJson") (EVar "path")) (EVar "run")) (EVar "props")))) (EApp (EVar "not") (EApp (EApp (EVar "testReportOk") (EVar "run")) (EVar "props")))))))))))
(DTypeSig false "handleToolsCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleToolsCall" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "idJson") (PVar "params")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "name"))) (EVar "params")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32602)))) (ELit (LString "tools/call: missing 'name'"))))) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "callTool") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "name")) (EApp (EApp (EVar "fieldOr") (ELit (LString "arguments"))) (EVar "params"))) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Unknown tool: ")) (EVar "name")))))) (arm (PCon "Some" (PVar "result")) () (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))))
(DTypeSig false "dispatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "dispatchMsg" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "msg")) (EMatch (EApp (EVar "asArray") (EVar "msg")) (arm (PCon "Some" PWild) () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "JNull")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32600)))) (ELit (LString "Invalid Request: batch requests are not supported"))))) (arm (PCon "None") () (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EVar "logMcp") (ELit (LString "ignored: message has no string 'method' field")))) (arm (PCon "Some" (PVar "meth")) () (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EIf (EBinOp "==" (EVar "meth") (ELit (LString "notifications/initialized"))) (EVar "unit") (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "id"))) (EVar "msg")) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "idJson")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "initializeResultFor") (EApp (EVar "negotiateVersion") (EVar "msg"))))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "ping"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/list"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "toolsListResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EApp (EApp (EApp (EApp (EApp (EVar "handleToolsCall") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "idJson")) (EVar "params")) (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Method not found: ")) (EVar "meth"))))))))))))))))))))
(DTypeSig false "handleLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "handleLine" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "raw")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EVar "unit") (EMatch (EApp (EVar "parse") (EVar "line")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "parse error (skipped): ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "msg")) () (EApp (EApp (EApp (EApp (EVar "dispatchMsg") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "msg"))))))))
(DTypeSig false "serveLoop" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "serveLoop" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "handleLine") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "raw"))) (DoExpr (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")))))))
(DTypeSig true "runMcpServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "runMcpServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir")) (EBlock (DoLet false false PWild (EApp (EVar "logMcp") (ELit (LString "medaka mcp server start")))) (DoExpr (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JInt" false) (mem "JString" false) (mem "JBool" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false))))
(DUse false (UseGroup ("io") ((mem "stripCR" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "checkJsonSingle" false) (mem "checkJsonFile" false) (mem "cjAllToJson" false) (mem "diagIsError" false) (mem "Diag" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "typeAtPoint" false) (mem "documentSymbols" false) (mem "definitionResult" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "lintFileDiagTriple" false) (mem "splitLintNames" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTestReport" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "runDetails" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" false) (mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false))))
(DTypeSig false "mcpSupportedVersions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mcpSupportedVersions" () (EListLit (ELit (LString "2024-11-05")) (ELit (LString "2025-03-26")) (ELit (LString "2025-06-18")) (ELit (LString "2025-11-25"))))
(DTypeSig false "mcpLatestVersion" (TyCon "String"))
(DFunDef false "mcpLatestVersion" () (ELit (LString "2025-11-25")))
(DTypeSig false "negotiateVersion" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "negotiateVersion" ((PVar "msg")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "protocolVersion"))) (EVar "params")) (arm (PCon "Some" (PVar "v")) () (EIf (EApp (EApp (EDictApp "elem") (EVar "v")) (EVar "mcpSupportedVersions")) (EVar "v") (EVar "mcpLatestVersion"))) (arm (PCon "None") () (EVar "mcpLatestVersion"))))))
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
(DTypeSig false "initializeResultFor" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "initializeResultFor" ((PVar "version")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "protocolVersion")) (EApp (EVar "JString") (EVar "version"))) (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jObject") (EListLit)))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (EVar "mcpServerVersion")))))))))
(DTypeSig false "toolsListResult" (TyCon "Json"))
(DFunDef false "toolsListResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tools")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "toolDescriptor")) (EVar "mcpTools")))))))
(DData Private "McpTool" () ((variant "McpTool" (ConPos (TyCon "String") (TyCon "String") (TyCon "Json") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json"))))))))) ())
(DTypeSig false "mcpTools" (TyApp (TyCon "List") (TyCon "McpTool")))
(DFunDef false "mcpTools" () (EListLit (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_check"))) (ELit (LString "Type-check Medaka source and return structured diagnostics — the same JSON `medaka check --json` emits (stable `code`, `range`, `severity`, `help`, and a machine-applicable `fix` where available). Provide exactly one of `file` or `source`."))) (EVar "medakaCheckSchema")) (EVar "runCheckTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_type_at"))) (ELit (LString "Infer the type/scheme at a position — the LSP hover, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style); returns the `<name> : <type>` at that point, resolving imported names against the project on disk. A position off any identifier returns a clean \"no symbol\" note, not an error."))) (EVar "medakaTypeAtSchema")) (EVar "runTypeAtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_symbols"))) (ELit (LString "List a file's top-level declarations (functions, data types, interfaces, impls, …) with their source ranges — the LSP document-symbol outline, driven statelessly. Give a `file` path; parse-only (no typecheck), so it works even on a file with type errors. A multi-clause function collapses to ONE entry (its signature + all clauses), not one-per-clause. A file that fails to PARSE returns a distinct isError result — `{\"parseError\": true, \"line\", \"col\", \"message\"}` — so you can tell an empty/no-decl file (empty list) from a broken one (parseError). Ranges are line-granular (`character` is 0; #331 tracks true name-column fidelity)."))) (EVar "medakaSymbolsSchema")) (EVar "runSymbolsTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_definition"))) (ELit (LString "Find the declaration that defines the identifier at a position — the LSP go-to-definition, driven statelessly. Give a `file` path plus a 0-based `line` and `col` (LSP-style). INTRA-FILE ONLY: it scans declarations in this same file, so a use of a name defined in ANOTHER file returns an empty result rather than a wrong location. A position off any identifier also returns an empty result."))) (EVar "medakaDefinitionSchema")) (EVar "runDefinitionTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_fmt"))) (ELit (LString "Format Medaka source with the compiler's canonical formatter (`medaka fmt`), driven statelessly. Provide exactly one of `file` or `source`. NEVER writes to disk — a `file` argument is only READ, never opened for writing; apply the returned text yourself if you want it saved. Default: returns the formatted source text. Pass `check: true` to instead get a clean/dirty verdict (`{\"clean\": true|false}`) without the full text. Input that fails to PARSE returns an isError result carrying the parse diagnostic, never a crash."))) (EVar "medakaFmtSchema")) (EVar "runFmtTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_lint"))) (ELit (LString "Run the compiler's style linter (`medaka lint`) over one or more files and return structured diagnostics — the same JSON envelope `medaka_check`/`medaka lint --json` emit (stable `range`/`severity`/`source`, with the lint RULE NAME in `code`). Give `paths` (array of file paths); optionally narrow with comma-separated `deny`/`only`/`disable` rule-name lists (mirror the CLI's --deny/--only/--disable). Report-only — no autofix; apply a fix yourself if you want one."))) (EVar "medakaLintSchema")) (EVar "runLintTool")) (EApp (EApp (EApp (EApp (EVar "McpTool") (ELit (LString "medaka_test"))) (ELit (LString "Run a file's doctests (and property tests, if any) and return structured PER-EXAMPLE results. Give a `file` path. Runs DOCTESTS and PROPERTY tests only — bare `test \"…\"` decls are NOT run here (they run under the human `medaka test` command). ⚠️ RESULTS ARE UNDER THE INTERPRETER (eval), NOT the native backend — a native-only miscompile is INVISIBLE here (a file can show every doctest green over a grammar the native binary silently mis-lowers, #81), so treat these as \"passes UNDER EVAL\", never an unqualified \"passes\". Returns `{file, engine:\"eval\", note, doctests:{total,passed,failed,errors,examples:[{line,input,status:pass|fail|error,expected?,actual?,detail?}]}, properties:[{name,status,detail}], summary:{passed,failed,ok}}`. A property's FAILING counterexample is RNG-dependent (non-portable). `isError` is true iff any doctest or property did not pass."))) (EVar "medakaTestSchema")) (EVar "runTestTool"))))
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
(DTypeSig false "symbolsResult" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "symbolsResult" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "parseError")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "parseErrorLine") (EVar "e")))) (ETuple (ELit (LString "col")) (EApp (EVar "JInt") (EApp (EVar "parseErrorCol") (EVar "e")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (EVar "True"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src"))))) (EVar "False")))))
(DTypeSig false "runSymbolsTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runSymbolsTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_symbols: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_symbols: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "symbolsResult") (EVar "src")))))))
(DTypeSig false "medakaDefinitionSchema" (TyCon "Json"))
(DFunDef false "medakaDefinitionSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file to query."))))))) (ETuple (ELit (LString "line")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based line of the position (LSP-style, first line is 0)."))))))) (ETuple (ELit (LString "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "integer")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "0-based column of the position (LSP-style, first column is 0).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file"))) (EApp (EVar "JString") (ELit (LString "line"))) (EApp (EVar "JString") (ELit (LString "col")))))))))
(DTypeSig false "positionParams" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "positionParams" ((PVar "line") (PVar "col")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col")))))))))
(DTypeSig false "runDefinitionTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runDefinitionTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "line"))) (EVar "args")) (EApp (EApp (EVar "fieldInt") (ELit (LString "col"))) (EVar "args"))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_definition: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EVar "definitionResult") (EVar "path")) (EVar "src")) (EApp (EApp (EVar "positionParams") (EVar "line")) (EVar "col"))))) (EVar "False"))))) (arm PWild () (EApp (EVar "toolArgError") (ELit (LString "medaka_definition: missing or invalid argument — require 'file' (string), 'line' (integer), and 'col' (integer)"))))))
(DTypeSig false "medakaFmtSchema" (TyCon "Json"))
(DFunDef false "medakaFmtSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to a .mdk file to format. READ ONLY — the file is never written; the formatted text is returned for the caller to apply."))))))) (ETuple (ELit (LString "source")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Inline Medaka source to format (no file on disk)."))))))) (ETuple (ELit (LString "check")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "boolean")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "If true, report clean/dirty instead of returning the formatted text (default false).")))))))))))))
(DTypeSig false "fieldBoolOr" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Json") (TyCon "Bool")))))
(DFunDef false "fieldBoolOr" ((PVar "key") (PVar "dflt") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "dflt"))))
(DTypeSig false "fmtResult" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "fmtResult" ((PVar "check") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "loc") (EApp (EVar "stringConcat") (EListLit (ELit (LString "line ")) (EApp (EVar "intToString") (EApp (EVar "parseErrorLine") (EVar "e"))) (ELit (LString ", col ")) (EApp (EVar "intToString") (EApp (EVar "parseErrorCol") (EVar "e")))))) (DoExpr (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: source does not parse (")) (EVar "loc") (ELit (LString "): ")) (EApp (EVar "parseErrorMessage") (EVar "e")))))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EIf (EVar "check") (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "clean")) (EApp (EVar "JBool") (EBinOp "==" (EVar "formatted") (EVar "src")))))))) (EVar "False")) (EApp (EApp (EVar "toolTextResult") (EVar "formatted")) (EVar "False"))))))))
(DTypeSig false "runFmtTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runFmtTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EBlock (DoLet false false (PVar "check") (EApp (EApp (EApp (EVar "fieldBoolOr") (ELit (LString "check"))) (EVar "False")) (EVar "args"))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (EApp (EApp (EVar "fieldStr") (ELit (LString "source"))) (EVar "args"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" PWild)) () (EApp (EVar "toolArgError") (ELit (LString "medaka_fmt: provide exactly one of 'file' or 'source', not both")))) (arm (PTuple (PCon "None") (PCon "None")) () (EApp (EVar "toolArgError") (ELit (LString "medaka_fmt: missing argument — provide exactly one of 'file' or 'source'")))) (arm (PTuple (PCon "Some" (PVar "path")) (PCon "None")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_fmt: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "fmtResult") (EVar "check")) (EVar "src"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "src"))) () (EApp (EApp (EVar "fmtResult") (EVar "check")) (EVar "src")))))))
(DTypeSig false "medakaLintSchema" (TyCon "Json"))
(DFunDef false "medakaLintSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "paths")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "array")))) (ETuple (ELit (LString "items")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string"))))))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Paths to .mdk files to lint."))))))) (ETuple (ELit (LString "deny")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to promote to error severity (mirrors --deny)."))))))) (ETuple (ELit (LString "only")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to keep, dropping findings from every other rule (mirrors --only)."))))))) (ETuple (ELit (LString "disable")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Comma-separated rule names to suppress (mirrors --disable).")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "paths")))))))))
(DTypeSig false "jsonArrToList" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "jsonArrToList" ((PVar "arr")) (EApp (EApp (EApp (EVar "jsonArrToListGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "jsonArrToListGo" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "jsonArrToListGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EApp (EApp (EApp (EVar "jsonArrToListGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pathsArg" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pathsArg" ((PVar "args")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "paths"))) (EVar "args")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EVar "asArray") (EVar "v")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "arr")) () (EApp (EVar "allJsonStrings") (EApp (EVar "jsonArrToList") (EVar "arr"))))))))
(DTypeSig false "allJsonStrings" (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "allJsonStrings" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "allJsonStrings" ((PCons (PVar "j") (PVar "rest"))) (EMatch (ETuple (EApp (EVar "asString") (EVar "j")) (EApp (EVar "allJsonStrings") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "s")) (PCon "Some" (PVar "ss"))) () (EApp (EVar "Some") (EBinOp "::" (EVar "s") (EVar "ss")))) (arm PWild () (EVar "None"))))
(DTypeSig false "lintNameListArg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintNameListArg" ((PVar "key") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (EVar "key")) (EVar "args")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PLit (LString ""))) () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "splitLintNames") (EVar "s")))))
(DTypeSig false "lintPathsToDiagTriples" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "lintPathsToDiagTriples" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintPathsToDiagTriples" ((PVar "disable") (PVar "only") (PVar "deny") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagTriples") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "rest"))))
(DTypeSig false "anyTripleHasErr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Bool")))
(DFunDef false "anyTripleHasErr" ((PList)) (EVar "False"))
(DFunDef false "anyTripleHasErr" ((PCons (PTuple PWild PWild (PVar "diags")) (PVar "rest"))) (EBinOp "||" (EApp (EVar "anyDiagErr") (EVar "diags")) (EApp (EVar "anyTripleHasErr") (EVar "rest"))))
(DTypeSig false "anyDiagErr" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Bool")))
(DFunDef false "anyDiagErr" ((PList)) (EVar "False"))
(DFunDef false "anyDiagErr" ((PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "diagIsError") (EVar "d")) (EApp (EVar "anyDiagErr") (EVar "rest"))))
(DTypeSig false "runLintTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runLintTool" ((PVar "_runtimeSrc") (PVar "_coreSrc") (PVar "_stdlibDir") (PVar "args")) (EMatch (EApp (EVar "pathsArg") (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_lint: missing or invalid argument — require 'paths' (array of strings)")))) (arm (PCon "Some" (PVar "paths")) () (EBlock (DoLet false false (PVar "disable") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "disable"))) (EVar "args"))) (DoLet false false (PVar "only") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "only"))) (EVar "args"))) (DoLet false false (PVar "deny") (EApp (EApp (EVar "lintNameListArg") (ELit (LString "deny"))) (EVar "args"))) (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EVar "lintPathsToDiagTriples") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "paths"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "cjAllToJson") (EVar "triples"))) (EApp (EVar "anyTripleHasErr") (EVar "triples"))))))))
(DTypeSig false "medakaTestSchema" (TyCon "Json"))
(DFunDef false "medakaTestSchema" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "object")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "type")) (EApp (EVar "JString") (ELit (LString "string")))) (ETuple (ELit (LString "description")) (EApp (EVar "JString") (ELit (LString "Path to the .mdk file whose doctests (and property tests, if any) to run.")))))))))) (ETuple (ELit (LString "required")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JString") (ELit (LString "file")))))))))
(DTypeSig false "exResultFields" (TyFun (TyCon "ExResult") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "exResultFields" ((PCon "Pass")) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "pass"))))))
(DFunDef false "exResultFields" ((PCon "Fail" (PVar "expected") (PVar "actual"))) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "fail")))) (ETuple (ELit (LString "expected")) (EApp (EVar "JString") (EVar "expected"))) (ETuple (ELit (LString "actual")) (EApp (EVar "JString") (EVar "actual")))))
(DFunDef false "exResultFields" ((PCon "Errored" (PVar "msg"))) (EListLit (ETuple (ELit (LString "status")) (EApp (EVar "JString") (ELit (LString "error")))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "msg")))))
(DTypeSig false "exampleJson" (TyFun (TyTuple (TyCon "Example") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "exampleJson" ((PTuple (PVar "ex") (PVar "res"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "exampleLine") (EVar "ex")))) (ETuple (ELit (LString "input")) (EApp (EVar "JString") (EApp (EVar "exampleInput") (EVar "ex"))))) (EApp (EVar "exResultFields") (EVar "res")))))
(DTypeSig false "doctestsJson" (TyFun (TyCon "RunResult") (TyCon "Json")))
(DFunDef false "doctestsJson" ((PVar "run")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "total")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "runFailed") (EVar "run"))) (EApp (EVar "runErrors") (EVar "run"))))) (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EApp (EVar "runPassed") (EVar "run")))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EApp (EVar "runFailed") (EVar "run")))) (ETuple (ELit (LString "errors")) (EApp (EVar "JInt") (EApp (EVar "runErrors") (EVar "run")))) (ETuple (ELit (LString "examples")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "exampleJson")) (EApp (EVar "runDetails") (EVar "run"))))))))
(DTypeSig false "propJson" (TyFun (TyCon "PropResult") (TyCon "Json")))
(DFunDef false "propJson" ((PVar "p")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "p")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LString "pass")) (ELit (LString "fail"))))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "p")))))))
(DTypeSig false "allPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool")))
(DFunDef false "allPropsPass" ((PList)) (EVar "True"))
(DFunDef false "allPropsPass" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "propResultPassed") (EVar "p")) (EApp (EVar "allPropsPass") (EVar "rest"))))
(DTypeSig false "countPassProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "countPassProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countPassProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "countPassProps") (EVar "rest"))))
(DTypeSig false "countFailProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "countFailProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "countFailProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "countFailProps") (EVar "rest"))))
(DTypeSig false "testReportOk" (TyFun (TyCon "RunResult") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool"))))
(DFunDef false "testReportOk" ((PVar "run") (PVar "props")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "run")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "run")) (ELit (LInt 0)))) (EApp (EVar "allPropsPass") (EVar "props"))))
(DTypeSig false "testReportJson" (TyFun (TyCon "String") (TyFun (TyCon "RunResult") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Json")))))
(DFunDef false "testReportJson" ((PVar "path") (PVar "run") (PVar "props")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (ELit (LString "eval")))) (ETuple (ELit (LString "note")) (EApp (EVar "JString") (ELit (LString "Results are under the interpreter (eval), NOT the native backend — a native-only miscompile is not observed here (see #81). Report these as passing UNDER EVAL, not unqualified.")))) (ETuple (ELit (LString "doctests")) (EApp (EVar "doctestsJson") (EVar "run"))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "propJson")) (EVar "props")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "countPassProps") (EVar "props"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EVar "run")) (EApp (EVar "runErrors") (EVar "run"))) (EApp (EVar "countFailProps") (EVar "props"))))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EVar "testReportOk") (EVar "run")) (EVar "props"))))))))))
(DTypeSig false "runTestTool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "runTestTool" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "args")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "file"))) (EVar "args")) (arm (PCon "None") () (EApp (EVar "toolArgError") (ELit (LString "medaka_test: missing or invalid argument — require 'file' (string)")))) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "toolArgError") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka_test: cannot read file '")) (EVar "path") (ELit (LString "': ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "tsrc")) () (EBlock (DoLet false false (PTuple (PVar "run") (PVar "props")) (EApp (EApp (EApp (EApp (EApp (EVar "runTestReport") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "path")) (EVar "tsrc")) (EVar "stdlibDir"))) (DoExpr (EApp (EApp (EVar "toolTextResult") (EApp (EVar "stringify") (EApp (EApp (EApp (EVar "testReportJson") (EVar "path")) (EVar "run")) (EVar "props")))) (EApp (EVar "not") (EApp (EApp (EVar "testReportOk") (EVar "run")) (EVar "props")))))))))))
(DTypeSig false "handleToolsCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleToolsCall" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "idJson") (PVar "params")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "name"))) (EVar "params")) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32602)))) (ELit (LString "tools/call: missing 'name'"))))) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "callTool") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "name")) (EApp (EApp (EVar "fieldOr") (ELit (LString "arguments"))) (EVar "params"))) (arm (PCon "None") () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Unknown tool: ")) (EVar "name")))))) (arm (PCon "Some" (PVar "result")) () (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))))
(DTypeSig false "dispatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "dispatchMsg" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "msg")) (EMatch (EApp (EVar "asArray") (EVar "msg")) (arm (PCon "Some" PWild) () (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "JNull")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32600)))) (ELit (LString "Invalid Request: batch requests are not supported"))))) (arm (PCon "None") () (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EVar "logMcp") (ELit (LString "ignored: message has no string 'method' field")))) (arm (PCon "Some" (PVar "meth")) () (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (DoExpr (EIf (EBinOp "==" (EVar "meth") (ELit (LString "notifications/initialized"))) (EVar "unit") (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "id"))) (EVar "msg")) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "idJson")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "initializeResultFor") (EApp (EVar "negotiateVersion") (EVar "msg"))))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "ping"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EApp (EVar "jObject") (EListLit)))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/list"))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "toolsListResult"))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "tools/call"))) (EApp (EApp (EApp (EApp (EApp (EVar "handleToolsCall") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "idJson")) (EVar "params")) (EApp (EVar "writeMessage") (EApp (EApp (EApp (EVar "errorMsg") (EVar "idJson")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 32601)))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Method not found: ")) (EVar "meth"))))))))))))))))))))
(DTypeSig false "handleLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "handleLine" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "raw")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EVar "unit") (EMatch (EApp (EVar "parse") (EVar "line")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "logMcp") (EApp (EVar "stringConcat") (EListLit (ELit (LString "parse error (skipped): ")) (EVar "e"))))) (arm (PCon "Ok" (PVar "msg")) () (EApp (EApp (EApp (EApp (EVar "dispatchMsg") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "msg"))))))))
(DTypeSig false "serveLoop" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "serveLoop" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "unit")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "handleLine") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "raw"))) (DoExpr (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")))))))
(DTypeSig true "runMcpServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "runMcpServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir")) (EBlock (DoLet false false PWild (EApp (EVar "logMcp") (ELit (LString "medaka mcp server start")))) (DoExpr (EApp (EApp (EApp (EVar "serveLoop") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
