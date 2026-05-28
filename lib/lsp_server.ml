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
     with e ->
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
