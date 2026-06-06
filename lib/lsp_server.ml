(* Phase 34 — Minimal LSP server.
   Phase 34.5 — Multi-file analysis: on every change we load the open
   document's import graph (with unsaved buffers overriding disk) and
   publish per-file diagnostics, clearing URIs that no longer have
   errors.

   Capabilities advertised: textDocumentSync = Full.  No hover,
   completion, go-to-definition, or workspace operations yet. *)

open Lsp
open Lsp.Types

(* ── Identity monad for synchronous I/O ───────────────────── *)

module Identity = struct
  type 'a t = 'a
  let return x = x
  let raise = Stdlib.raise
  module O = struct
    let ( let+ ) x f = f x
    let ( let* ) x f = f x
  end
end

module Chan = struct
  type input = in_channel
  type output = out_channel

  let read_line ic =
    try Some (input_line ic)
    with End_of_file -> None

  let read_exactly ic n =
    let buf = Bytes.create n in
    try
      really_input ic buf 0 n;
      Some (Bytes.unsafe_to_string buf)
    with End_of_file -> None

  let write oc parts =
    List.iter (output_string oc) parts;
    flush oc
end

module Rpc_io = Io.Make (Identity) (Chan)

(* ── State ─────────────────────────────────────────────────── *)

(* uri_string → source text (the latest version sent by the client) *)
let docs : (string, string) Hashtbl.t = Hashtbl.create 8

(* uri_string → project_dir (cached on first didOpen) *)
let project_roots : (string, string) Hashtbl.t = Hashtbl.create 8

(* Set of uri_strings we last published a non-empty diagnostic list for.
   Used to clear stale diagnostics in files that have since become clean. *)
let published_uris : (string, unit) Hashtbl.t = Hashtbl.create 16

(* file path → most recent source that parsed cleanly.
   Passed into [Diagnostics.analyze_project] so the analyzer can keep
   producing useful resolve/typecheck diagnostics even while a buffer
   is mid-edit and has a transient parse error.  Keyed by path (not URI)
   to match the [read] callback's argument type. *)
let last_good_source : (string, string) Hashtbl.t = Hashtbl.create 8

(* ── Project root inference ──────────────────────────────────

   Prefer the canonical `medaka.toml` marker (shared with the CLI via
   [Project_config.find_project_root]).  Fall back to `.git` or `core/`
   so projects without a toml still get analyzed sensibly. *)

let dir_has_fallback_marker dir =
  Sys.file_exists (Filename.concat dir ".git")
  || Sys.file_exists (Filename.concat dir "core")

let find_project_root (file_path : string) : string =
  match Project_config.find_project_root file_path with
  | Some d -> d
  | None ->
    let start = Filename.dirname file_path in
    let rec walk dir =
      if dir_has_fallback_marker dir then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then start
        else walk parent
    in
    walk start

let project_root_for ~(uri_str : string) ~(file_path : string) : string =
  match Hashtbl.find_opt project_roots uri_str with
  | Some d -> d
  | None ->
    let d = find_project_root file_path in
    Hashtbl.replace project_roots uri_str d;
    d

(* ── Diagnostic conversion ─────────────────────────────────── *)

let range_of_loc (l : Ast.loc) : Range.t =
  let start = Position.create ~line:(l.line - 1) ~character:l.col in
  let end_  = Position.create ~line:(l.end_line - 1) ~character:l.end_col in
  Range.create ~start ~end_

let severity_of (s : Diagnostics.severity) : DiagnosticSeverity.t =
  match s with
  | Diagnostics.Error   -> DiagnosticSeverity.Error
  | Diagnostics.Warning -> DiagnosticSeverity.Warning

let lsp_diag_of (d : Diagnostics.diagnostic) : Diagnostic.t =
  Diagnostic.create
    ~message:(`String d.message)
    ~range:(range_of_loc d.loc)
    ~severity:(severity_of d.severity)
    ~source:"medaka"
    ()

(* Render a diagnostic list as the LSP publish shape, for `medaka check --json`.
   Each element is the exact `Diagnostic` shape the LSP server publishes (range
   with 0-based start/end positions, integer severity, message, source), wrapped
   in a top-level object carrying the file path. *)
let diagnostics_to_json ~(file : string) (diags : Diagnostics.diagnostic list) : string =
  let arr = List.map (fun d -> Diagnostic.yojson_of_t (lsp_diag_of d)) diags in
  let obj = `Assoc [ ("file", `String file); ("diagnostics", `List arr) ] in
  Yojson.Safe.to_string obj

(* Render a whole multi-file `analyze_project` result as JSON, for `medaka check
   --json` on a file with imports.  Each element is the same per-file object
   `diagnostics_to_json` emits, collected under a top-level "files" array so the
   output is a single parseable document regardless of how many modules the
   import graph spans. *)
let all_diagnostics_to_json
    (results : (string * Diagnostics.diagnostic list) list) : string =
  let files =
    List.map (fun (file, diags) ->
      let arr = List.map (fun d -> Diagnostic.yojson_of_t (lsp_diag_of d)) diags in
      `Assoc [ ("file", `String file); ("diagnostics", `List arr) ])
      results
  in
  Yojson.Safe.to_string (`Assoc [ ("files", `List files) ])

let publish_for_uri (uri : DocumentUri.t) (diags : Diagnostics.diagnostic list) =
  let params = PublishDiagnosticsParams.create
    ~diagnostics:(List.map lsp_diag_of diags) ~uri ()
  in
  let notif = Server_notification.PublishDiagnostics params in
  let jsonrpc_notif = Server_notification.to_jsonrpc notif in
  Rpc_io.write stdout (Jsonrpc.Packet.Notification jsonrpc_notif)

(* ── Multi-file publish ────────────────────────────────────── *)

(* Run analyze_project rooted at [root_uri] and publish per-file.
   Clears any URIs that previously had diagnostics but no longer do. *)
let publish_project_diagnostics ~(root_uri : DocumentUri.t) =
  let root_uri_str = DocumentUri.to_string root_uri in
  let root_file    = DocumentUri.to_path root_uri in
  let project_dir  = project_root_for ~uri_str:root_uri_str ~file_path:root_file in

  let read (path : string) : string option =
    let uri = DocumentUri.of_path path in
    Hashtbl.find_opt docs (DocumentUri.to_string uri)
  in

  let results =
    Diagnostics.analyze_project
      ~root_file ~project_dir ~read ~last_good_source ()
  in

  let this_round : (string, unit) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun (file, diags) ->
    let uri = DocumentUri.of_path file in
    publish_for_uri uri diags;
    if diags <> [] then
      Hashtbl.replace this_round (DocumentUri.to_string uri) ()
  ) results;

  (* Clear URIs we previously reported errors for that are now clean
     AND not in this round (e.g., dropped from the graph entirely). *)
  Hashtbl.iter (fun uri_str () ->
    if not (Hashtbl.mem this_round uri_str) then begin
      let uri = DocumentUri.of_string uri_str in
      publish_for_uri uri []
    end
  ) published_uris;

  Hashtbl.reset published_uris;
  Hashtbl.iter (fun u () -> Hashtbl.replace published_uris u ()) this_round

(* ── Helpers shared by request handlers ────────────────────── *)

(* Range covering the whole document: from (0,0) to one-past-the-last-line.
   Using `~end_:(N, 0)` where N = line_count covers every line without
   needing to know the trailing line's length, and clients accept it. *)
let full_document_range (src : string) : Range.t =
  let lines = ref 0 in
  String.iter (fun c -> if c = '\n' then incr lines) src;
  let nl = !lines + 1 in
  let start = Position.create ~line:0 ~character:0 in
  let end_  = Position.create ~line:nl ~character:0 in
  Range.create ~start ~end_

(* Parse a buffer purely (no diagnostics, no exceptions).  Returns the
   program plus the parser-side-channel decl positions, or None on a
   parse error.  Used by all language-feature handlers. *)
let parse_buffer (src : string) (uri : DocumentUri.t)
  : (Ast.program * Ast.loc list) option =
  Lexer.reset ();
  Parser_state.reset ();
  let lexbuf = Lexing.from_string src in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with
      Lexing.pos_fname = DocumentUri.to_path uri };
  try
    let prog = Parser.program Lexer.token lexbuf in
    let locs = Parser_state.take_decl_positions () in
    Some (prog, locs)
  with _ -> None

(* ── Handlers ──────────────────────────────────────────────── *)

let handle_initialize (_p : InitializeParams.t) : InitializeResult.t =
  let sync = TextDocumentSyncKind.Full in
  let caps = ServerCapabilities.create
    ~textDocumentSync:(`TextDocumentSyncKind sync)
    ~documentFormattingProvider:(`Bool true)
    ~documentSymbolProvider:(`Bool true)
    ~hoverProvider:(`Bool true)
    ~definitionProvider:(`Bool true)
    ~documentHighlightProvider:(`Bool true)
    ~completionProvider:(CompletionOptions.create ())
    ~inlayHintProvider:(`Bool true)
    ()
  in
  let info = InitializeResult.create_serverInfo
    ~name:"medaka-lsp" ~version:"0.1.0" ()
  in
  InitializeResult.create ~capabilities:caps ~serverInfo:info ()

let notification_label (n : Client_notification.t) : string =
  match n with
  | Client_notification.TextDocumentDidOpen _   -> "textDocument/didOpen"
  | Client_notification.TextDocumentDidChange _ -> "textDocument/didChange"
  | Client_notification.TextDocumentDidClose _  -> "textDocument/didClose"
  | Client_notification.Initialized             -> "initialized"
  | Client_notification.Exit                    -> "exit"
  | _                                           -> "<other>"

let handle_notification_unsafe (n : Client_notification.t) =
  match n with
  | Client_notification.TextDocumentDidOpen p ->
    let uri_str = DocumentUri.to_string p.textDocument.uri in
    Hashtbl.replace docs uri_str p.textDocument.text;
    publish_project_diagnostics ~root_uri:p.textDocument.uri
  | Client_notification.TextDocumentDidChange p ->
    let uri_str = DocumentUri.to_string p.textDocument.uri in
    (* Full sync: each change has no range and replaces the whole document.
       If the client misbehaves and sends an incremental change, we skip
       it (text without a range is still treated as full-replacement). *)
    let final_text =
      List.fold_left (fun _acc (ch : TextDocumentContentChangeEvent.t) ->
        match ch.range with
        | None   -> ch.text
        | Some _ ->
          (* Incremental edit — shouldn't happen with our advertised sync,
             but be defensive: keep the cached text unchanged. *)
          (try Hashtbl.find docs uri_str with Not_found -> ch.text)
      ) "" p.contentChanges
    in
    Hashtbl.replace docs uri_str final_text;
    publish_project_diagnostics ~root_uri:p.textDocument.uri
  | Client_notification.TextDocumentDidClose p ->
    let uri_str = DocumentUri.to_string p.textDocument.uri in
    let path    = DocumentUri.to_path p.textDocument.uri in
    Hashtbl.remove docs uri_str;
    Hashtbl.remove project_roots uri_str;
    Hashtbl.remove last_good_source path;
    (* Clear any squiggles the client might still be showing for this
       file.  Don't touch other URIs — other open files in the project
       will re-publish on their next change. *)
    publish_for_uri p.textDocument.uri [];
    Hashtbl.remove published_uris uri_str
  | _ -> ()

(* ── Document formatting ───────────────────────────────────── *)

(* Run [Fmt.format_source] on the buffer's current text and return a
   single TextEdit that replaces the entire document.  If formatting
   fails (parse error, formatter bug, etc.) we return None so the
   client just keeps its buffer unchanged. *)
let handle_formatting (p : DocumentFormattingParams.t) : TextEdit.t list option =
  let uri = p.textDocument.uri in
  let uri_str = DocumentUri.to_string uri in
  match Hashtbl.find_opt docs uri_str with
  | None -> None
  | Some src ->
    let filename = DocumentUri.to_path uri in
    (try
       let formatted = Fmt.format_source ~filename src in
       if formatted = src then Some []
       else
         let edit =
           TextEdit.create ~newText:formatted ~range:(full_document_range src)
         in
         Some [edit]
     with
     | Failure msg ->
       (* Source doesn't parse — normal user state, not a server bug. *)
       Lsp_log.info (Printf.sprintf "formatting skipped (unparseable): %s" msg);
       None
     | e ->
       Lsp_log.exn "formatting failed" e;
       None)

(* ── Document symbols ──────────────────────────────────────── *)

(* Map a Medaka decl into a flat DocumentSymbol entry.  We use the
   parser-recorded location for the symbol range and selectionRange.
   Children (record fields, data variants, interface methods, impl
   methods) get nested so the outline view collapses neatly. *)

(* Strip the optional `decl` wrapping that DAttrib introduces and the
   `pub?` flag of public decls so the switch below is unambiguous. *)
let symbol_of_decl (d : Ast.decl) (loc : Ast.loc) : DocumentSymbol.t option =
  let open Ast in
  let range = range_of_loc loc in
  let mk ?(children : DocumentSymbol.t list option) name kind detail =
    Some
      (DocumentSymbol.create ~name ~kind ~range ~selectionRange:range
         ?detail ?children ())
  in
  match inner_decl d with
  | DTypeSig (_, name, ty) ->
    mk name SymbolKind.Variable (Some (pp_ty ty))
  | DExtern (_, name, ty) ->
    mk name SymbolKind.Function (Some (pp_ty ty))
  | DFunDef (_, name, _, _) ->
    mk name SymbolKind.Function None
  | DLetGroup (_, binds) ->
    (* Surface every name in a `let rec x = ... with y = ...` group. *)
    (match binds with
     | [] -> None
     | (n, _) :: _ ->
       let children =
         List.filter_map (fun (n', _) ->
           Some (DocumentSymbol.create ~name:n' ~kind:SymbolKind.Function
                   ~range ~selectionRange:range ()))
           binds
       in
       mk ~children n SymbolKind.Function None)
  | DData (_, name, params, variants, _) ->
    let detail =
      if params = [] then None
      else Some (String.concat " " (name :: params))
    in
    let children = List.map (fun v ->
      DocumentSymbol.create ~name:v.con_name
        ~kind:SymbolKind.EnumMember ~range ~selectionRange:range ()) variants
    in
    mk ~children name SymbolKind.Enum detail
  | DRecord (_, name, params, fields, _) ->
    let detail =
      if params = [] then None
      else Some (String.concat " " (name :: params))
    in
    let children = List.map (fun (f : record_field) ->
      DocumentSymbol.create ~name:f.field_name ~kind:SymbolKind.Field
        ~range ~selectionRange:range
        ~detail:(pp_ty f.field_type) ()) fields
    in
    mk ~children name SymbolKind.Struct detail
  | DInterface { iface_name; methods; _ } ->
    let children = List.map (fun m ->
      DocumentSymbol.create ~name:m.method_name ~kind:SymbolKind.Method
        ~range ~selectionRange:range
        ~detail:(pp_ty m.method_type) ()) methods
    in
    mk ~children iface_name SymbolKind.Interface None
  | DImpl { iface_name; type_args; impl_name; methods; _ } ->
    let label =
      let tag = match impl_name with
        | Some n -> Printf.sprintf "%s of " n
        | None -> ""
      in
      Printf.sprintf "%simpl %s%s" tag iface_name
        (if type_args = [] then ""
         else " " ^ String.concat " " (List.map pp_ty type_args))
    in
    let children = List.map (fun (n, _, _) ->
      DocumentSymbol.create ~name:n ~kind:SymbolKind.Method
        ~range ~selectionRange:range ()) methods
    in
    mk ~children label SymbolKind.Class None
  | DTypeAlias (_, name, params, rhs) ->
    let detail =
      Printf.sprintf "%s = %s"
        (if params = [] then name else String.concat " " (name :: params))
        (pp_ty rhs)
    in
    mk name SymbolKind.TypeParameter (Some detail)
  | DNewtype (_, name, _, con, ty, _) ->
    mk name SymbolKind.Struct (Some (Printf.sprintf "%s %s" con (pp_ty ty)))
  | DUse _ -> None  (* import directives clutter the outline *)
  | DProp { prop_name; _ } ->
    mk prop_name SymbolKind.Function (Some "prop")
  | DTest { test_name; _ } ->
    mk test_name SymbolKind.Function (Some "test")
  | DBench { bench_name; _ } ->
    mk bench_name SymbolKind.Function (Some "bench")
  | DAttrib _ -> None  (* unreachable via inner_decl *)

let handle_document_symbol (p : DocumentSymbolParams.t)
  : [ `DocumentSymbol of DocumentSymbol.t list
    | `SymbolInformation of SymbolInformation.t list ] option =
  let uri = p.textDocument.uri in
  let uri_str = DocumentUri.to_string uri in
  match Hashtbl.find_opt docs uri_str with
  | None -> None
  | Some src ->
    (match parse_buffer src uri with
     | None -> None
     | Some (prog, locs) ->
       (* Pair each decl with its source position.  When a DAttrib wraps
          a decl, the parser pops the inner position and records the outer
          span, so the lists should match 1:1.  Defensive: zip the shorter
          of the two so a length mismatch falls back to a partial outline
          rather than crashing. *)
       let rec zip ds ls = match ds, ls with
         | d :: dr, l :: lr -> (d, l) :: zip dr lr
         | _ -> []
       in
       let symbols =
         zip prog locs
         |> List.filter_map (fun (d, l) -> symbol_of_decl d l)
       in
       Some (`DocumentSymbol symbols))

(* ── Hover ─────────────────────────────────────────────────── *)

(* Whole-buffer hover: type-check the document, then look up the name
   directly under the cursor in the result env.  We scan the source text
   to extract the identifier under the cursor (cheaper than re-walking
   the AST for now) and probe the typecheck env.  Falls back to None on
   any failure. *)

let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9') || c = '_' || c = '\''

(* Given source text and a 0-based (line, column), return the identifier
   spanning that position along with its absolute byte offsets, or None
   if the cursor is not on an identifier. *)
let identifier_at (src : string) ~(line : int) ~(col : int)
  : (string * int * int) option =
  let len = String.length src in
  let cur_line = ref 0 and line_start = ref 0 in
  let i = ref 0 in
  while !cur_line < line && !i < len do
    if src.[!i] = '\n' then begin
      incr cur_line;
      line_start := !i + 1
    end;
    incr i
  done;
  if !cur_line < line then None
  else begin
    let pos = !line_start + col in
    if pos < 0 || pos >= len then None
    else
      let c = src.[pos] in
      if not (is_ident_char c) then None
      else
        let start = ref pos in
        while !start > 0 && is_ident_char src.[!start - 1] do decr start done;
        let stop = ref pos in
        while !stop + 1 < len && is_ident_char src.[!stop + 1] do incr stop done;
        let s = String.sub src !start (!stop - !start + 1) in
        Some (s, !start, !stop + 1)
  end

let handle_hover (p : HoverParams.t) : Hover.t option =
  let uri = p.textDocument.uri in
  let uri_str = DocumentUri.to_string uri in
  match Hashtbl.find_opt docs uri_str with
  | None -> None
  | Some src ->
    let line = p.position.line and col = p.position.character in
    (match identifier_at src ~line ~col with
     | None -> None
     | Some (name, _, _) ->
       (match parse_buffer src uri with
        | None -> None
        | Some (prog, _) ->
          let prog = Desugar.desugar_program prog in
          (* Resolver may legitimately reject; skip if so since the
             typechecker would fail too. *)
          if Resolve.resolve_program prog <> [] then None
          else
            try
              let (env, _) = Typecheck.check_program prog in
              match List.assoc_opt name env with
              | None -> None
              | Some sch ->
                let value =
                  MarkupContent.create ~kind:MarkupKind.Markdown
                    ~value:(Printf.sprintf "```medaka\n%s : %s\n```"
                              name (Typecheck.pp_scheme sch))
                in
                Some (Hover.create ~contents:(`MarkupContent value) ())
            with _ -> None))

(* ── Go-to-definition ──────────────────────────────────────── *)

(* Names a decl introduces into the top-level scope.  Used to match
   the identifier at the cursor against a declaration site.  We don't
   surface type-level names (data/record/interface/newtype) here
   because go-to-definition on a *type* would normally be served by
   typeDefinition, but we still include them so jumping to e.g.
   `Point` in a constructor call lands somewhere useful. *)
let decl_defines (d : Ast.decl) (name : Ast.ident) : bool =
  let open Ast in
  match inner_decl d with
  | DTypeSig (_, n, _)        -> n = name
  | DExtern  (_, n, _)        -> n = name
  | DFunDef  (_, n, _, _)     -> n = name
  | DLetGroup (_, binds)      -> List.exists (fun (n, _) -> n = name) binds
  | DData (_, n, _, vs, _)    ->
    n = name || List.exists (fun (v : data_variant) -> v.con_name = name) vs
  | DRecord (_, n, _, fs, _)  ->
    n = name
    || List.exists (fun (f : record_field) -> f.field_name = name) fs
  | DInterface { iface_name; methods; _ } ->
    iface_name = name
    || List.exists (fun (m : iface_method) -> m.method_name = name) methods
  | DImpl { methods; _ } ->
    List.exists (fun (n, _, _) -> n = name) methods
  | DTypeAlias (_, n, _, _)   -> n = name
  | DNewtype (_, n, _, c, _, _) -> n = name || c = name
  | DUse _                    -> false
  | DProp { prop_name; _ }    -> prop_name = name
  | DTest { test_name; _ }    -> test_name = name
  | DBench { bench_name; _ }  -> bench_name = name
  | DAttrib _                 -> false

(* Return the location of the first decl that defines [name], if any. *)
let find_definition_loc
    (prog : Ast.program) (locs : Ast.loc list) (name : Ast.ident)
  : Ast.loc option =
  let rec walk ds ls = match ds, ls with
    | d :: dr, l :: lr ->
      if decl_defines d name then Some l else walk dr lr
    | _ -> None
  in
  walk prog locs

let handle_definition (p : DefinitionParams.t) : Locations.t option =
  let uri = p.textDocument.uri in
  let uri_str = DocumentUri.to_string uri in
  match Hashtbl.find_opt docs uri_str with
  | None -> None
  | Some src ->
    let line = p.position.line and col = p.position.character in
    (match identifier_at src ~line ~col with
     | None -> None
     | Some (name, _, _) ->
       (match parse_buffer src uri with
        | None -> None
        | Some (prog, locs) ->
          (match find_definition_loc prog locs name with
           | None -> None
           | Some loc ->
             let location =
               Location.create ~uri ~range:(range_of_loc loc)
             in
             Some (`Location [location]))))

(* ── Document highlight ────────────────────────────────────── *)

(* Textual highlight: find every occurrence of the identifier under the
   cursor in the buffer, with identifier-boundary checks so a search
   for `is` doesn't match the substring inside `isOdd`.  This is a
   pragmatic baseline — scope-aware (semantic) highlight would require
   re-walking the AST against the resolver's symbol table, which can
   be a follow-up. *)

(* Convert a byte offset into the source string into a 0-based
   (line, column) pair.  Used to map [identifier_at]'s offsets back
   into Position.t values for the highlight result range. *)
let offset_to_position (src : string) (off : int) : Position.t =
  let line = ref 0 and last_nl = ref (-1) in
  let i = ref 0 in
  while !i < off do
    if src.[!i] = '\n' then begin
      incr line;
      last_nl := !i
    end;
    incr i
  done;
  Position.create ~line:!line ~character:(off - !last_nl - 1)

let find_all_occurrences (src : string) (name : string) : Range.t list =
  let len = String.length src and nlen = String.length name in
  if nlen = 0 then [] else
    let acc = ref [] in
    let i = ref 0 in
    while !i + nlen <= len do
      let matches =
        String.sub src !i nlen = name
        && (!i = 0 || not (is_ident_char src.[!i - 1]))
        && (!i + nlen = len || not (is_ident_char src.[!i + nlen]))
      in
      if matches then begin
        let start = offset_to_position src !i in
        let end_  = offset_to_position src (!i + nlen) in
        acc := Range.create ~start ~end_ :: !acc;
        i := !i + nlen
      end else
        incr i
    done;
    List.rev !acc

let handle_highlight (p : DocumentHighlightParams.t)
  : DocumentHighlight.t list option =
  let uri = p.textDocument.uri in
  let uri_str = DocumentUri.to_string uri in
  match Hashtbl.find_opt docs uri_str with
  | None -> None
  | Some src ->
    let line = p.position.line and col = p.position.character in
    (match identifier_at src ~line ~col with
     | None -> None
     | Some (name, _, _) ->
       let ranges = find_all_occurrences src name in
       Some (List.map (fun range ->
         DocumentHighlight.create ~range ()) ranges))

(* ── Completion ───────────────────────────────────────────── *)

(* Compute the identifier prefix immediately before the cursor — i.e.,
   the longest run of identifier characters ending at column [col-1].
   Returns "" when the cursor sits after a non-identifier character. *)
let prefix_before (src : string) ~(line : int) ~(col : int) : string =
  let len = String.length src in
  let cur_line = ref 0 and line_start = ref 0 in
  let i = ref 0 in
  while !cur_line < line && !i < len do
    if src.[!i] = '\n' then begin
      incr cur_line;
      line_start := !i + 1
    end;
    incr i
  done;
  if !cur_line < line then ""
  else
    let pos = !line_start + col - 1 in
    if pos < !line_start then ""
    else
      let stop = pos in
      let start = ref stop in
      while !start >= !line_start
            && !start >= 0
            && !start < len
            && is_ident_char src.[!start]
      do decr start done;
      let first = !start + 1 in
      if first > stop then ""
      else String.sub src first (stop - first + 1)

(* Filter names by prefix, deduplicating to keep the list small. *)
let filter_completions (names : (string * Typecheck.scheme) list)
    (prefix : string) : (string * Typecheck.scheme) list =
  let plen = String.length prefix in
  let seen = Hashtbl.create 32 in
  List.filter (fun (n, _) ->
    let n_ok =
      plen = 0
      || (String.length n >= plen && String.sub n 0 plen = prefix)
    in
    if n_ok && not (Hashtbl.mem seen n) then begin
      Hashtbl.add seen n ();
      true
    end else false
  ) names

let completion_kind_for_scheme (_sch : Typecheck.scheme) : CompletionItemKind.t =
  (* Without poking at the inferred ty we can't easily distinguish
     function vs. value here.  Defaulting to Function is the right
     guess for most identifiers a user would complete. *)
  CompletionItemKind.Function

let handle_completion (p : CompletionParams.t)
  : [ `CompletionList of CompletionList.t
    | `List of CompletionItem.t list ] option =
  let uri = p.textDocument.uri in
  let uri_str = DocumentUri.to_string uri in
  match Hashtbl.find_opt docs uri_str with
  | None -> None
  | Some src ->
    let line = p.position.line and col = p.position.character in
    let prefix = prefix_before src ~line ~col in
    (match parse_buffer src uri with
     | None -> None
     | Some (prog, _) ->
       let prog = Desugar.desugar_program prog in
       if Resolve.resolve_program prog <> [] then None
       else
         try
           let (env, _) = Typecheck.check_program prog in
           let items =
             filter_completions env prefix
             |> List.map (fun (name, sch) ->
               CompletionItem.create
                 ~label:name
                 ~kind:(completion_kind_for_scheme sch)
                 ~detail:(Typecheck.pp_scheme sch) ())
           in
           Some (`List items)
         with _ -> None)

(* ── Inlay hints ───────────────────────────────────────────── *)

(* Return the column right after the declaration's name in the source
   line that starts at [loc.line].  Concretely: starting at
   [loc.col], scan forward while we're still inside the identifier;
   that gives us the position immediately following the name where
   a `: Type` hint reads cleanly.  Returns None if the line/column
   is out of bounds (defensive — the parser side channel should
   keep us honest). *)
let column_after_name (src : string) (loc : Ast.loc) : int option =
  let lines = String.split_on_char '\n' src in
  match List.nth_opt lines (loc.line - 1) with
  | None -> None
  | Some line ->
    let len = String.length line in
    let i = ref loc.col in
    while !i < len && is_ident_char line.[!i] do incr i done;
    if !i = loc.col then None else Some !i

(* For inlay hints, we want only top-level decls that:
   - bind a value (DFunDef or zero-arg, etc.)
   - have no accompanying DTypeSig in the program
   - whose name appears in the typecheck env
   This keeps the noise low — already-annotated code stays clean. *)
let decl_binding_name (d : Ast.decl) : Ast.ident option =
  let open Ast in
  match inner_decl d with
  | DFunDef (_, n, _, _)         -> Some n
  | DLetGroup (_, (n, _) :: _)   -> Some n  (* hint on the first name *)
  | _                            -> None

let has_explicit_sig (prog : Ast.program) (name : Ast.ident) : bool =
  List.exists (fun d -> match Ast.inner_decl d with
    | Ast.DTypeSig (_, n, _) -> n = name
    | _ -> false
  ) prog

let handle_inlay_hint (p : InlayHintParams.t) : InlayHint.t list option =
  let uri = p.textDocument.uri in
  let uri_str = DocumentUri.to_string uri in
  match Hashtbl.find_opt docs uri_str with
  | None -> None
  | Some src ->
    (match parse_buffer src uri with
     | None -> None
     | Some (prog, locs) ->
       let prog_d = Desugar.desugar_program prog in
       if Resolve.resolve_program prog_d <> [] then None
       else
         try
           let (env, _) = Typecheck.check_program prog_d in
           (* Pair each parse-side decl with its source position.
              Filter to bindings with no explicit signature, then turn
              each into a hint placed after the name. *)
           let rec zip ds ls = match ds, ls with
             | d :: dr, l :: lr -> (d, l) :: zip dr lr
             | _ -> []
           in
           let hints =
             zip prog locs
             |> List.filter_map (fun (d, loc) ->
               match decl_binding_name d with
               | None -> None
               | Some name when has_explicit_sig prog name -> None
               | Some name ->
                 match List.assoc_opt name env with
                 | None -> None
                 | Some sch ->
                   (match column_after_name src loc with
                    | None -> None
                    | Some col ->
                      let pos =
                        Position.create ~line:(loc.line - 1) ~character:col
                      in
                      let label =
                        Printf.sprintf ": %s" (Typecheck.pp_scheme sch)
                      in
                      Some (InlayHint.create
                              ~position:pos
                              ~paddingLeft:true
                              ~label:(`String label) ())))
           in
           Some hints
         with _ -> None)

(* Top-level catch-all: any exception from a notification handler is logged
   and swallowed.  Notifications have no response, so the client never
   learns about the failure — but the server stays alive. *)
let handle_notification (n : Client_notification.t) =
  try handle_notification_unsafe n with e ->
    Lsp_log.exn
      (Printf.sprintf "uncaught exception in notification handler (%s)"
        (notification_label n)) e

let handle_request_unsafe (req : Jsonrpc.Request.t) : Jsonrpc.Response.t =
  match Client_request.of_jsonrpc req with
  | Error msg ->
    Jsonrpc.Response.error req.id
      (Jsonrpc.Response.Error.make
        ~code:Jsonrpc.Response.Error.Code.InvalidRequest
        ~message:msg ())
  | Ok (Client_request.E r) ->
    (match r with
     | Client_request.Initialize p ->
       let result = handle_initialize p in
       Jsonrpc.Response.ok req.id (InitializeResult.yojson_of_t result)
     | Client_request.Shutdown ->
       Jsonrpc.Response.ok req.id `Null
     | Client_request.TextDocumentFormatting p as cr ->
       let result = handle_formatting p in
       Jsonrpc.Response.ok req.id
         (Client_request.yojson_of_result cr result)
     | Client_request.DocumentSymbol p as cr ->
       let result = handle_document_symbol p in
       Jsonrpc.Response.ok req.id
         (Client_request.yojson_of_result cr result)
     | Client_request.TextDocumentHover p as cr ->
       let result = handle_hover p in
       Jsonrpc.Response.ok req.id
         (Client_request.yojson_of_result cr result)
     | Client_request.TextDocumentDefinition p as cr ->
       let result = handle_definition p in
       Jsonrpc.Response.ok req.id
         (Client_request.yojson_of_result cr result)
     | Client_request.TextDocumentHighlight p as cr ->
       let result = handle_highlight p in
       Jsonrpc.Response.ok req.id
         (Client_request.yojson_of_result cr result)
     | Client_request.TextDocumentCompletion p as cr ->
       let result = handle_completion p in
       Jsonrpc.Response.ok req.id
         (Client_request.yojson_of_result cr result)
     | Client_request.InlayHint p as cr ->
       let result = handle_inlay_hint p in
       Jsonrpc.Response.ok req.id
         (Client_request.yojson_of_result cr result)
     | _ ->
       Jsonrpc.Response.error req.id
         (Jsonrpc.Response.Error.make
           ~code:Jsonrpc.Response.Error.Code.MethodNotFound
           ~message:(Printf.sprintf "method %s not implemented" req.method_)
           ()))

(* Top-level catch-all: any exception is logged with a backtrace and turned
   into an InternalError response, so the client gets a clean reply and the
   server stays alive. *)
let handle_request (req : Jsonrpc.Request.t) : Jsonrpc.Response.t =
  try handle_request_unsafe req with e ->
    Lsp_log.exn
      (Printf.sprintf "uncaught exception handling request %s" req.method_) e;
    Jsonrpc.Response.error req.id
      (Jsonrpc.Response.Error.make
        ~code:Jsonrpc.Response.Error.Code.InternalError
        ~message:(Printf.sprintf "internal error: %s" (Printexc.to_string e))
        ())

(* ── Main loop ─────────────────────────────────────────────── *)

let run () =
  Printexc.record_backtrace true;
  set_binary_mode_in  stdin  true;
  set_binary_mode_out stdout true;
  Lsp_log.info "LSP starting";
  let continue = ref true in
  while !continue do
    (* Wrap the per-iteration body so a single bad frame doesn't kill the
       loop.  Genuine EOF / broken-pipe conditions still end the session
       (see the End_of_file / Sys_error arms below). *)
    try
      match Rpc_io.read stdin with
      | None -> continue := false
      | Some (Jsonrpc.Packet.Request req) ->
        let resp = handle_request req in
        Rpc_io.write stdout (Jsonrpc.Packet.Response resp)
      | Some (Jsonrpc.Packet.Notification jsonrpc_notif) ->
        (match Client_notification.of_jsonrpc jsonrpc_notif with
         | Ok Client_notification.Exit -> continue := false
         | Ok n -> handle_notification n
         | Error _ -> ())
      | Some _ -> ()  (* Responses/batches not expected from clients we target. *)
    with
    | End_of_file ->
      continue := false
    | Sys_error msg ->
      (* Broken pipe / closed stdout: nothing we can do, exit cleanly. *)
      Lsp_log.error (Printf.sprintf "I/O error, exiting: %s" msg);
      continue := false
    | e ->
      Lsp_log.exn "uncaught exception in main loop iteration" e
  done;
  Lsp_log.info "LSP exiting"
