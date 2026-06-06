open Medaka_lib
open Doc

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let mk_comment line text : Lexer.comment =
  { c_line = line; c_col = 0; c_text = text }

(* Parse [src], returning (program, positions, comments) with side channels
   captured before any subsequent call resets them. *)
let parse_with_meta src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  let program =
    try Parser.program Lexer.token lexbuf
    with Parser.Error ->
      let pos = lexbuf.Lexing.lex_curr_p in
      failwith (Printf.sprintf "parse error at %d:%d"
                  pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))
  in
  let comments  = Lexer.take_comments () in
  let positions = Parser_state.take_decl_positions () in
  (program, positions, comments)

(* Typecheck [program] (post-desugar) via the single-file path; [] on error. *)
let typecheck_program program =
  let desugared = Desugar.desugar_program program in
  match (try
           let marked = Method_marker.mark_with_prelude desugared in
           let (sc, _) = Typecheck.check_program marked in
           Some sc
         with _ -> None)
  with
  | Some sc -> sc
  | None    -> []

(* Run the full doc pipeline on [src] and return the entries. *)
let extract src =
  let (program, positions, comments) = parse_with_meta src in
  let schemes = typecheck_program program in
  extract_entries program positions schemes comments

(* ── Comment-matching unit tests ─────────────────────────────────────────── *)

let t_find_doc_no_comment () =
  let tbl = build_comment_tbl [] in
  let result = find_doc_for_line tbl 5 in
  if result <> "" then
    failwith (Printf.sprintf "expected empty doc, got %S" result)

let t_find_doc_single_comment () =
  let comments = [mk_comment 4 "-- some doc"] in
  let tbl = build_comment_tbl comments in
  let result = find_doc_for_line tbl 5 in
  if result <> "some doc" then
    failwith (Printf.sprintf "expected 'some doc', got %S" result)

let t_find_doc_multi_comment () =
  let comments = [mk_comment 3 "-- first"; mk_comment 4 "-- second"] in
  let tbl = build_comment_tbl comments in
  let result = find_doc_for_line tbl 5 in
  if result <> "first\nsecond" then
    failwith (Printf.sprintf "expected 'first\\nsecond', got %S" result)

let t_find_doc_gap_stops_scan () =
  (* Lines 3 and 5: gap at line 4 → only line 5 is adjacent to decl at line 6 *)
  let comments = [mk_comment 3 "-- far"; mk_comment 5 "-- near"] in
  let tbl = build_comment_tbl comments in
  let result = find_doc_for_line tbl 6 in
  if result <> "near" then
    failwith (Printf.sprintf "expected 'near', got %S" result)

let t_find_doc_blank_in_block () =
  (* A blank `--` comment within a consecutive block is included as empty line *)
  let comments = [mk_comment 2 "-- para one"; mk_comment 3 "--"; mk_comment 4 "-- para two"] in
  let tbl = build_comment_tbl comments in
  let result = find_doc_for_line tbl 5 in
  (* all three are consecutive: lines 2,3,4 *)
  if result <> "para one\n\npara two" then
    failwith (Printf.sprintf "expected 'para one\\n\\npara two', got %S" result)

(* ── Entry extraction tests ──────────────────────────────────────────────── *)

let t_private_fn_excluded () =
  let src = "foo : Int -> Int\nfoo x = x\n" in
  let entries = extract src in
  if entries <> [] then
    failwith (Printf.sprintf "expected no entries for private fn, got %d" (List.length entries))

let t_public_fn_included () =
  let src = "export foo : Int -> Int\nfoo x = x\n" in
  let entries = extract src in
  match entries with
  | [e] ->
    if e.de_name <> "foo" then
      failwith (Printf.sprintf "wrong name: %S" e.de_name);
    if e.de_sig = "" then failwith "empty sig"
  | _ ->
    failwith (Printf.sprintf "expected 1 entry, got %d" (List.length entries))

let t_doc_comment_attached () =
  (* Doc comment immediately above the export decl. *)
  let src = "-- The identity function.\nexport foo : Int -> Int\nfoo x = x\n" in
  let entries = extract src in
  match entries with
  | [e] ->
    if e.de_doc <> "The identity function." then
      failwith (Printf.sprintf "wrong doc: %S" e.de_doc)
  | _ ->
    failwith (Printf.sprintf "expected 1 entry, got %d" (List.length entries))

let t_doc_comment_from_type_sig_line () =
  (* Pattern: doc comment → DTypeSig → DFunDef clauses.
     Doc must be captured at the type sig position; DFunDef is deduplicated out. *)
  let src = "-- Adds one.\nexport addOne : Int -> Int\naddOne x = x + 1\n" in
  let entries = extract src in
  match entries with
  | [e] ->
    if e.de_name <> "addOne" then
      failwith (Printf.sprintf "wrong name: %S" e.de_name);
    if e.de_doc <> "Adds one." then
      failwith (Printf.sprintf "wrong doc: %S" e.de_doc);
    if e.de_sig = "" then failwith "empty sig"
  | _ ->
    failwith (Printf.sprintf "expected 1 entry, got %d" (List.length entries))

let t_no_duplicate_for_multiclauses () =
  (* foo has two clauses; should produce only one entry. *)
  let src = "export foo : Int -> Int\nfoo 0 = 0\nfoo n = n + 1\n" in
  let entries = extract src in
  let n = List.length (List.filter (fun e -> e.de_name = "foo") entries) in
  if n <> 1 then failwith (Printf.sprintf "expected 1 'foo' entry, got %d" n)

let t_data_type_rendered () =
  let src = "-- A binary tree.\npublic export data Tree a = Leaf | Node a (Tree a) (Tree a)\n" in
  let entries = extract src in
  match entries with
  | [e] ->
    if e.de_name <> "Tree" then
      failwith (Printf.sprintf "wrong name: %S" e.de_name);
    if e.de_doc <> "A binary tree." then
      failwith (Printf.sprintf "wrong doc: %S" e.de_doc);
    if String.length e.de_sig < 4 || String.sub e.de_sig 0 4 <> "data" then
      failwith (Printf.sprintf "sig should start with 'data', got %S" e.de_sig)
  | _ ->
    failwith (Printf.sprintf "expected 1 entry, got %d" (List.length entries))

let t_private_data_excluded () =
  let src = "data Hidden = A | B\n" in
  let entries = extract src in
  if entries <> [] then
    failwith (Printf.sprintf "expected no entries for private data, got %d" (List.length entries))

let t_interface_rendered () =
  let src = "-- Size abstraction.\nexport interface Sized a where\n  size : a -> Int\n" in
  let entries = extract src in
  match entries with
  | [e] ->
    if e.de_name <> "Sized" then
      failwith (Printf.sprintf "wrong name: %S" e.de_name);
    if e.de_doc <> "Size abstraction." then
      failwith (Printf.sprintf "wrong doc: %S" e.de_doc);
    if String.length e.de_sig < 9 || String.sub e.de_sig 0 9 <> "interface" then
      failwith (Printf.sprintf "sig should start with 'interface', got %S" e.de_sig)
  | _ ->
    failwith (Printf.sprintf "expected 1 entry, got %d" (List.length entries))

let t_multiline_doc_comment () =
  let src = "-- First line.\n-- Second line.\nexport\nbaz : Int\nbaz = 42\n" in
  let entries = extract src in
  match entries with
  | [e] ->
    if e.de_doc <> "First line.\nSecond line." then
      failwith (Printf.sprintf "wrong doc: %S" e.de_doc)
  | _ ->
    failwith (Printf.sprintf "expected 1 entry, got %d" (List.length entries))

let t_gap_breaks_doc () =
  (* Section comment separated by blank line should NOT attach to the decl. *)
  let src = "-- Section header\n\nexport\nbar : Int\nbar = 0\n" in
  let entries = extract src in
  match entries with
  | [e] ->
    if e.de_doc <> "" then
      failwith (Printf.sprintf "expected empty doc (gap breaks it), got %S" e.de_doc)
  | _ ->
    failwith (Printf.sprintf "expected 1 entry, got %d" (List.length entries))

let t_type_alias_rendered () =
  let src = "-- Readability alias.\nexport type Name = String\n" in
  let entries = extract src in
  match entries with
  | [e] ->
    if e.de_name <> "Name" then
      failwith (Printf.sprintf "wrong name: %S" e.de_name);
    if String.length e.de_sig < 4 || String.sub e.de_sig 0 4 <> "type" then
      failwith (Printf.sprintf "sig should start with 'type', got %S" e.de_sig)
  | _ ->
    failwith (Printf.sprintf "expected 1 entry, got %d" (List.length entries))

(* ── Markdown rendering tests ────────────────────────────────────────────── *)

let t_render_markdown_empty () =
  let out = render_markdown "mymod" [] in
  if out <> "# mymod\n\n" then
    failwith (Printf.sprintf "unexpected output: %S" out)

let t_render_markdown_one_entry_with_doc () =
  let entries = [{ de_name = "foo"; de_sig = "foo : Int"; de_doc = "Does foo." }] in
  let out = render_markdown "mod" entries in
  let expected = "# mod\n\n## `foo`\n\n```\nfoo : Int\n```\n\nDoes foo.\n\n" in
  if out <> expected then
    failwith (Printf.sprintf "unexpected output:\n%s\nexpected:\n%s" out expected)

let t_render_markdown_one_entry_no_doc () =
  let entries = [{ de_name = "bar"; de_sig = "bar : Bool"; de_doc = "" }] in
  let out = render_markdown "mod" entries in
  let expected = "# mod\n\n## `bar`\n\n```\nbar : Bool\n```\n\n" in
  if out <> expected then
    failwith (Printf.sprintf "unexpected output:\n%s\nexpected:\n%s" out expected)

(* ── Suite wiring ────────────────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "doc" [
    "comment-matching", [
      test_case "no comment"           `Quick t_find_doc_no_comment;
      test_case "single comment"       `Quick t_find_doc_single_comment;
      test_case "multi comment"        `Quick t_find_doc_multi_comment;
      test_case "gap stops scan"       `Quick t_find_doc_gap_stops_scan;
      test_case "blank in block"       `Quick t_find_doc_blank_in_block;
    ];
    "entry-extraction", [
      test_case "private fn excluded"    `Quick t_private_fn_excluded;
      test_case "public fn included"     `Quick t_public_fn_included;
      test_case "doc comment attached"   `Quick t_doc_comment_attached;
      test_case "doc from type sig line" `Quick t_doc_comment_from_type_sig_line;
      test_case "no dup multiclauses"    `Quick t_no_duplicate_for_multiclauses;
      test_case "data type rendered"     `Quick t_data_type_rendered;
      test_case "private data excluded"  `Quick t_private_data_excluded;
      test_case "interface rendered"     `Quick t_interface_rendered;
      test_case "multiline doc"          `Quick t_multiline_doc_comment;
      test_case "gap breaks doc"         `Quick t_gap_breaks_doc;
      test_case "type alias rendered"    `Quick t_type_alias_rendered;
    ];
    "markdown-rendering", [
      test_case "empty entries"        `Quick t_render_markdown_empty;
      test_case "entry with doc"       `Quick t_render_markdown_one_entry_with_doc;
      test_case "entry no doc"         `Quick t_render_markdown_one_entry_no_doc;
    ];
  ]
