(* Phase 60 — LSP logging.

   The LSP server runs as a long-lived child process of the editor; when
   it crashes the user just sees the connection drop with no clue what
   went wrong.  This module gives us a single place to write triage
   information that survives across crashes.

   Output goes to two sinks:

   - stderr — LSP clients (VS Code, Neovim, Helix, …) capture the
     server's stderr by convention, so this is visible without any
     extra configuration.
   - a log file — opened lazily on first write.  Path comes from
     $MEDAKA_LSP_LOG if set, otherwise ~/.cache/medaka/lsp.log. *)

let level_str = function
  | `Info  -> "INFO"
  | `Warn  -> "WARN"
  | `Error -> "ERROR"

let timestamp () =
  let t  = Unix.gettimeofday () in
  let tm = Unix.localtime t in
  let ms = int_of_float ((t -. Float.floor t) *. 1000.) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec ms

let default_log_path () =
  let home =
    try Sys.getenv "HOME"
    with Not_found -> Filename.get_temp_dir_name ()
  in
  Filename.concat (Filename.concat home ".cache/medaka") "lsp.log"

let log_path () =
  try Sys.getenv "MEDAKA_LSP_LOG"
  with Not_found -> default_log_path ()

(* Create [dir] and any missing parents.  Best-effort: any failure is
   swallowed so that logging never raises. *)
let rec mkdir_p dir =
  if dir = "" || dir = "/" || Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    | _ -> ()
  end

let file_oc : out_channel option ref = ref None
let file_oc_tried = ref false

let get_file_oc () =
  match !file_oc with
  | Some oc -> Some oc
  | None when !file_oc_tried -> None
  | None ->
    file_oc_tried := true;
    let path = log_path () in
    (try
       mkdir_p (Filename.dirname path);
       let oc = open_out_gen [Open_wronly; Open_creat; Open_append] 0o644 path in
       file_oc := Some oc;
       Some oc
     with _ -> None)

let write_line level msg =
  let line = Printf.sprintf "[%s] %s %s\n" (timestamp ()) (level_str level) msg in
  (try output_string stderr line; flush stderr with _ -> ());
  (match get_file_oc () with
   | None -> ()
   | Some oc ->
     try output_string oc line; flush oc with _ -> ())

let info  msg = write_line `Info  msg
let warn  msg = write_line `Warn  msg
let error msg = write_line `Error msg

let exn msg e =
  let bt = Printexc.get_backtrace () in
  let line = Printf.sprintf "%s: %s\n%s" msg (Printexc.to_string e) bt in
  write_line `Error line
