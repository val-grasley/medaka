(* Tests for the LSP server's per-request handlers.

   The server runs over stdio in production; for tests we exercise the
   handler functions directly.  Each handler reads from the
   `Lsp_server.docs` table, so we prime it via the same DidOpen path
   the client would normally trigger (sans the project-wide diagnostic
   side effect we don't care about here).

   Coverage:
   - textDocument/formatting reformats the buffer or returns [] when
     already formatted.
   - textDocument/documentSymbol returns the expected outline shape.
   - textDocument/hover returns the inferred type for a top-level name. *)

open Medaka_lib
open Lsp.Types

let uri_of_path path = DocumentUri.of_path path

(* Replace the buffer cached by the LSP server.  We don't go through
   handle_notification because that triggers project-wide diagnostics
   publishing (and writes to stdout). *)
let prime_doc uri text =
  Hashtbl.replace Lsp_server.docs (DocumentUri.to_string uri) text

(* ── Formatting ─────────────────────────────────────────────── *)

let test_format_already_formatted () =
  let uri = uri_of_path "/tmp/lsp_fmt_clean.mdk" in
  let src = "x = 1\ny = 2\n" in
  prime_doc uri src;
  let p = DocumentFormattingParams.create
    ~options:(FormattingOptions.create ~tabSize:2 ~insertSpaces:true ())
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_formatting p with
  | Some [] -> ()
  | Some _ -> Alcotest.fail "expected no edits for already-formatted source"
  | None   -> Alcotest.fail "formatting returned None for clean source"

let test_format_reformats_messy () =
  let uri = uri_of_path "/tmp/lsp_fmt_messy.mdk" in
  (* Trailing whitespace + double blank line — fmt collapses both. *)
  let src = "x   = 1\n\n\n\ny = 2\n" in
  prime_doc uri src;
  let p = DocumentFormattingParams.create
    ~options:(FormattingOptions.create ~tabSize:2 ~insertSpaces:true ())
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_formatting p with
  | Some (_ :: _) -> ()  (* at least one edit means the formatter touched it *)
  | Some [] -> Alcotest.fail "expected edits for messy source"
  | None    -> Alcotest.fail "formatting returned None"

let test_format_bad_parse_returns_none () =
  let uri = uri_of_path "/tmp/lsp_fmt_bad.mdk" in
  prime_doc uri "x = (";  (* deliberately unclosed *)
  let p = DocumentFormattingParams.create
    ~options:(FormattingOptions.create ~tabSize:2 ~insertSpaces:true ())
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_formatting p with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for source with parse error"

(* ── Document symbols ───────────────────────────────────────── *)

let symbol_names = function
  | Some (`DocumentSymbol syms) -> List.map (fun s -> s.DocumentSymbol.name) syms
  | _ -> []

let test_doc_symbols_basic () =
  let uri = uri_of_path "/tmp/lsp_sym.mdk" in
  let src =
    "record Point\n\
    \  x : Int\n\
    \  y : Int\n\
    \n\
    data Shape = Circle Int | Square Int\n\
    \n\
    area s = match s\n\
    \  Circle r => r * r\n\
    \  Square w => w * w\n"
  in
  prime_doc uri src;
  let p = DocumentSymbolParams.create
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  let result = Lsp_server.handle_document_symbol p in
  let names = symbol_names result in
  Alcotest.(check (list string)) "top-level names"
    ["Point"; "Shape"; "area"] names

let test_doc_symbols_record_children () =
  let uri = uri_of_path "/tmp/lsp_sym_rec.mdk" in
  let src = "record Point\n  x : Int\n  y : Int\n" in
  prime_doc uri src;
  let p = DocumentSymbolParams.create
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_document_symbol p with
  | Some (`DocumentSymbol [s]) ->
    Alcotest.(check string) "record name" "Point" s.name;
    let children = match s.children with Some c -> c | None -> [] in
    let child_names = List.map (fun c -> c.DocumentSymbol.name) children in
    Alcotest.(check (list string)) "field names" ["x"; "y"] child_names
  | _ -> Alcotest.fail "expected exactly one symbol for a single-record file"

(* ── Hover ──────────────────────────────────────────────────── *)

let test_hover_top_level_name () =
  let uri = uri_of_path "/tmp/lsp_hover.mdk" in
  let src = "double x = x + x\n" in
  prime_doc uri src;
  (* "double" starts at column 0 on line 0; cursor on the 'o' (col 1). *)
  let p = HoverParams.create
    ~position:(Position.create ~line:0 ~character:1)
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_hover p with
  | None -> Alcotest.fail "expected hover for a known top-level name"
  | Some h ->
    let text = match h.contents with
      | `MarkupContent m -> m.value
      | `MarkedString s -> s.value
      | `List _ -> ""
    in
    if not (String.length text > 0) then Alcotest.fail "empty hover content";
    let contains s sub =
      let ls = String.length s and lb = String.length sub in
      let rec loop i = i + lb <= ls && (String.sub s i lb = sub || loop (i+1)) in
      lb = 0 || loop 0
    in
    if not (contains text "double") then
      Alcotest.failf "hover text didn't mention name `double`:\n%s" text;
    (* `double x = x + x` is polymorphic over Num, but the rendered
       scheme always includes an arrow.  Probe loosely. *)
    if not (contains text "->") then
      Alcotest.failf "hover text didn't show a function type:\n%s" text

let test_hover_off_an_identifier () =
  let uri = uri_of_path "/tmp/lsp_hover_off.mdk" in
  prime_doc uri "double x = x + x\n";
  (* Cursor on the `=` (column 9). *)
  let p = HoverParams.create
    ~position:(Position.create ~line:0 ~character:9)
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_hover p with
  | None -> ()
  | Some _ -> Alcotest.fail "expected no hover off an identifier"

(* ── Definition ────────────────────────────────────────────── *)

let test_definition_top_level () =
  let uri = uri_of_path "/tmp/lsp_def.mdk" in
  let src = "double x = x + x\ny = double 21\n" in
  prime_doc uri src;
  (* Cursor on the `d` of `double` on line 1 (the call site). *)
  let p = DefinitionParams.create
    ~position:(Position.create ~line:1 ~character:4)
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_definition p with
  | Some (`Location [loc]) ->
    Alcotest.(check int) "lands on line 0" 0 loc.range.start.line
  | _ -> Alcotest.fail "expected exactly one definition location"

let test_definition_record_field () =
  let uri = uri_of_path "/tmp/lsp_def_field.mdk" in
  let src = "record P\n  x : Int\n  y : Int\ntotal p = p.x + p.y\n" in
  prime_doc uri src;
  (* Cursor on `P` at line 3 column 0 (the def of `total` mentions P
     transitively via the record).  Probe via the type name itself: on
     line 0 column 7 the cursor is in `P`. *)
  let p = DefinitionParams.create
    ~position:(Position.create ~line:3 ~character:0)  (* `t` of total *)
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_definition p with
  | Some (`Location [loc]) ->
    Alcotest.(check int) "self-definition lines up at decl start"
      3 loc.range.start.line
  | _ -> Alcotest.fail "expected a definition for `total`"

let test_definition_unknown_returns_none () =
  let uri = uri_of_path "/tmp/lsp_def_unk.mdk" in
  prime_doc uri "x = 1\n";
  (* Cursor in whitespace, which is not on an identifier. *)
  let p = DefinitionParams.create
    ~position:(Position.create ~line:0 ~character:4)
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_definition p with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None when cursor isn't on a name"

(* ── Document highlight ────────────────────────────────────── *)

let test_highlight_three_uses () =
  let uri = uri_of_path "/tmp/lsp_hi.mdk" in
  let src = "double x = x + x\ntriple y = y + y + y\n" in
  prime_doc uri src;
  (* Cursor on the second `x` on line 0 (column 11, the LHS of +). *)
  let p = DocumentHighlightParams.create
    ~position:(Position.create ~line:0 ~character:11)
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_highlight p with
  | None -> Alcotest.fail "expected highlights for `x`"
  | Some hs ->
    Alcotest.(check int) "three occurrences of x" 3 (List.length hs);
    (* All highlights must be on line 0 — line 1 references y, not x. *)
    List.iter (fun (h : DocumentHighlight.t) ->
      Alcotest.(check int) "x highlight on line 0" 0 h.range.start.line
    ) hs

let test_highlight_boundaries () =
  let uri = uri_of_path "/tmp/lsp_hi_b.mdk" in
  (* `is` appears as an identifier on line 0 col 0 and as a substring
     inside `isOdd` on line 1.  Boundary check must reject the
     substring match. *)
  let src = "is = True\nisOdd n = if n == 0 then False else True\n" in
  prime_doc uri src;
  let p = DocumentHighlightParams.create
    ~position:(Position.create ~line:0 ~character:0)
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  match Lsp_server.handle_highlight p with
  | Some hs ->
    Alcotest.(check int) "only the standalone `is` matches" 1
      (List.length hs)
  | None -> Alcotest.fail "expected at least one highlight"

(* ── Completion ────────────────────────────────────────────── *)

let item_labels = function
  | Some (`List items) -> List.map (fun (i : CompletionItem.t) -> i.label) items
  | Some (`CompletionList cl) ->
    List.map (fun (i : CompletionItem.t) -> i.label) cl.CompletionList.items
  | None -> []

let test_completion_prefix_filters_env () =
  let uri = uri_of_path "/tmp/lsp_cmp.mdk" in
  (* The buffer must still parse for the typechecker to run.  We embed
     the full identifier `double` on a third line and query just after
     its first four characters — the prefix-extractor returns "doub". *)
  let src = "double x = x + x\ntriple x = x * 3\nresult = double 5\n" in
  prime_doc uri src;
  (* Line 2 = "result = double 5"; cursor right after the 4th char of
     `double` (after the column-prefix `result = `, which is 9 chars,
     so col 9+4 = 13). *)
  let p = CompletionParams.create
    ~position:(Position.create ~line:2 ~character:13)
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  let labels = item_labels (Lsp_server.handle_completion p) in
  if not (List.mem "double" labels) then
    Alcotest.failf "expected `double` in completions, got: %s"
      (String.concat ", " labels);
  if List.mem "triple" labels then
    Alcotest.fail "did not expect `triple` for prefix `doub`"

let test_completion_no_prefix_returns_env () =
  let uri = uri_of_path "/tmp/lsp_cmp2.mdk" in
  let src = "alpha = 1\nbeta = 2\n" in
  prime_doc uri src;
  let p = CompletionParams.create
    ~position:(Position.create ~line:2 ~character:0)
    ~textDocument:(TextDocumentIdentifier.create ~uri) ()
  in
  let labels = item_labels (Lsp_server.handle_completion p) in
  Alcotest.(check bool) "alpha in completions" true (List.mem "alpha" labels);
  Alcotest.(check bool) "beta in completions"  true (List.mem "beta" labels)

(* ── Entry ──────────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "LSP handlers"
    [ "formatting",
      [ test_case "no edits when already formatted" `Quick test_format_already_formatted
      ; test_case "edits for messy source"          `Quick test_format_reformats_messy
      ; test_case "None on parse error"             `Quick test_format_bad_parse_returns_none
      ]
    ; "documentSymbol",
      [ test_case "top-level names"   `Quick test_doc_symbols_basic
      ; test_case "record children"   `Quick test_doc_symbols_record_children
      ]
    ; "hover",
      [ test_case "top-level name"          `Quick test_hover_top_level_name
      ; test_case "off-identifier returns None" `Quick test_hover_off_an_identifier
      ]
    ; "definition",
      [ test_case "top-level call site"   `Quick test_definition_top_level
      ; test_case "decl self-definition"  `Quick test_definition_record_field
      ; test_case "off-identifier None"   `Quick test_definition_unknown_returns_none
      ]
    ; "highlight",
      [ test_case "three uses of x"       `Quick test_highlight_three_uses
      ; test_case "respects word boundaries" `Quick test_highlight_boundaries
      ]
    ; "completion",
      [ test_case "prefix filters env"    `Quick test_completion_prefix_filters_env
      ; test_case "no prefix lists env"   `Quick test_completion_no_prefix_returns_env
      ]
    ]
