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
    Diagnostics.analyze_project ~root_file ~project_dir ~read
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

(* ── Handlers ──────────────────────────────────────────────── *)

let handle_initialize (_p : InitializeParams.t) : InitializeResult.t =
  let sync = TextDocumentSyncKind.Full in
  let caps = ServerCapabilities.create
    ~textDocumentSync:(`TextDocumentSyncKind sync)
    ()
  in
  let info = InitializeResult.create_serverInfo
    ~name:"medaka-lsp" ~version:"0.1.0" ()
  in
  InitializeResult.create ~capabilities:caps ~serverInfo:info ()

let handle_notification (n : Client_notification.t) =
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
    Hashtbl.remove docs uri_str;
    Hashtbl.remove project_roots uri_str;
    (* Clear any squiggles the client might still be showing for this
       file.  Don't touch other URIs — other open files in the project
       will re-publish on their next change. *)
    publish_for_uri p.textDocument.uri [];
    Hashtbl.remove published_uris uri_str
  | _ -> ()

let handle_request (req : Jsonrpc.Request.t) : Jsonrpc.Response.t =
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
     | _ ->
       Jsonrpc.Response.error req.id
         (Jsonrpc.Response.Error.make
           ~code:Jsonrpc.Response.Error.Code.MethodNotFound
           ~message:(Printf.sprintf "method %s not implemented" req.method_)
           ()))

(* ── Main loop ─────────────────────────────────────────────── *)

let run () =
  set_binary_mode_in  stdin  true;
  set_binary_mode_out stdout true;
  let continue = ref true in
  while !continue do
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
  done
