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
    ]
