(* Phase 34 — collect parse / resolve / typecheck errors from a single source
   buffer into a list of diagnostics, without ever exiting the process.

   Phase 34.5 — `analyze_project` extends this to a full module graph,
   bucketing diagnostics by file so the LSP can publish per-URI.  Disk
   reads can be overridden via a `read` callback so unsaved editor
   buffers are seen by the analyzer. *)

type severity = Error | Warning

type diagnostic = {
  severity : severity;
  loc      : Ast.loc;
  message  : string;
}

(* Synthesise a loc when nothing better is available.  Used for typecheck
   warnings (exhaustiveness etc.) which currently have no location. *)
let dummy_loc ~file = {
  Ast.file;
  line     = 1;
  col      = 0;
  end_line = 1;
  end_col  = 0;
}

(* Convert an Ast.loc option into a concrete loc, falling back to dummy_loc. *)
let loc_or_dummy ~file = function
  | Some l -> l
  | None   -> dummy_loc ~file

let pp_resolve_error = Resolve.pp_error
let pp_type_error    = Typecheck.pp_error

(* Capture a Lexing.position as a one-character range starting at that
   position.  The LSP spec requires a Range; lexer errors don't have a
   span, so we underline a single column. *)
let loc_of_lex_pos (p : Lexing.position) : Ast.loc =
  let col = p.pos_cnum - p.pos_bol in
  {
    Ast.file = p.pos_fname;
    line     = p.pos_lnum;
    col;
    end_line = p.pos_lnum;
    end_col  = col + 1;
  }

let analyze ~(file : string) ~(source : string) : diagnostic list =
  let diags = ref [] in
  let push d = diags := d :: !diags in

  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = file };
  Lexer.reset ();

  let program_opt =
    try Some (Parser.program Lexer.token lexbuf) with
    | Parser.Error ->
      push {
        severity = Error;
        loc      = loc_of_lex_pos lexbuf.lex_curr_p;
        message  = "Parse error";
      };
      None
    | Failure msg ->
      push {
        severity = Error;
        loc      = loc_of_lex_pos lexbuf.lex_curr_p;
        message  = msg;
      };
      None
  in
  match program_opt with
  | None -> List.rev !diags
  | Some prog ->
    let prog = Desugar.desugar_program prog in

    let resolve_errs = Resolve.resolve_program prog in
    List.iter (fun (err, loc_opt) ->
      push {
        severity = Error;
        loc      = loc_or_dummy ~file loc_opt;
        message  = pp_resolve_error err;
      }
    ) resolve_errs;

    (* Only run typecheck if resolve had no errors — typecheck calls into
       env state that resolve populates, and running it on an inconsistent
       AST can produce nonsense errors. *)
    if resolve_errs = [] then begin
      try
        let (_env, warnings) = Typecheck.check_program prog in
        List.iter (fun msg ->
          push { severity = Warning; loc = dummy_loc ~file; message = msg }
        ) warnings
      with Typecheck.Type_error (e, loc_opt) ->
        push {
          severity = Error;
          loc      = loc_or_dummy ~file loc_opt;
          message  = pp_type_error e;
        }
    end;

    List.rev !diags

(* Render a diagnostic the way tests print it on failure. *)
let pp_diagnostic d =
  let sev = match d.severity with Error -> "error" | Warning -> "warning" in
  Printf.sprintf "%s:%d:%d-%d:%d: %s: %s"
    d.loc.file d.loc.line d.loc.col d.loc.end_line d.loc.end_col
    sev d.message

(* ── Multi-file analysis ─────────────────────────────────────────── *)

(* Best-effort location for an `import <mod_id>` declaration in [source].
   Walks the file with the regular lexer until it sees an IMPORT token
   followed by tokens whose concatenation matches [mod_id], and returns
   a loc covering the IMPORT keyword.  Returns None if no match.  Used
   to attribute UnknownModule errors to the offending line. *)
let scan_use_loc ~(file : string) ~(source : string) ~(mod_id : string)
  : Ast.loc option =
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = file };
  Lexer.reset ();
  let mod_parts = String.split_on_char '.' mod_id in
  let found = ref None in
  let rec loop () =
    if !found <> None then () else
    match Lexer.token lexbuf with
    | Parser.EOF -> ()
    | Parser.IMPORT ->
      let import_pos = lexbuf.Lexing.lex_start_p in
      let end_pos    = lexbuf.Lexing.lex_curr_p in
      (* Read the dotted path that follows.  Accept IDENT, UPPER and DOT. *)
      let collected = ref [] in
      let rec collect () =
        match Lexer.token lexbuf with
        | Parser.IDENT s | Parser.UPPER s ->
          collected := s :: !collected;
          (* Peek for a DOT to continue, or stop. *)
          peek_dot ()
        | _ -> ()
      and peek_dot () =
        match Lexer.token lexbuf with
        | Parser.DOT -> collect ()
        | _ -> ()
      in
      collect ();
      let got = List.rev !collected in
      (* Match if the collected path either equals mod_parts or has
         mod_parts as a prefix (covers UseGroup/UseWild). *)
      let rec is_prefix a b = match a, b with
        | [], _ -> true
        | _, [] -> false
        | x :: xs, y :: ys -> x = y && is_prefix xs ys
      in
      if is_prefix mod_parts got then begin
        let l = import_pos.pos_cnum - import_pos.pos_bol in
        let e = end_pos.pos_cnum - end_pos.pos_bol in
        found := Some {
          Ast.file;
          line     = import_pos.pos_lnum;
          col      = l;
          end_line = end_pos.pos_lnum;
          end_col  = e;
        }
      end;
      loop ()
    | _ -> loop ()
  in
  (try loop () with _ -> ());
  !found

(* Bucket helpers operating on a (file → diag list ref) hashtbl. *)

type buckets = (string, diagnostic list ref) Hashtbl.t

let bucket_for (b : buckets) (file : string) : diagnostic list ref =
  match Hashtbl.find_opt b file with
  | Some r -> r
  | None ->
    let r = ref [] in
    Hashtbl.add b file r;
    r

let push_into (b : buckets) (file : string) (d : diagnostic) =
  let r = bucket_for b file in
  r := d :: !r

(* Convert a load_error into one or more diagnostics, dropped into the
   right buckets.  [root_file] is used as a final fallback. *)
let attribute_load_error
    (b : buckets)
    ~(root_file : string)
    ~(read : string -> string option)
    (e : Loader.load_error)
  : unit =
  match e with
  | Loader.FileNotFound path ->
    push_into b root_file {
      severity = Error;
      loc      = dummy_loc ~file:root_file;
      message  = Printf.sprintf "File not found: %s" path;
    }
  | Loader.CyclicDependency cycle ->
    let msg =
      Printf.sprintf "Cyclic module dependency: %s"
        (String.concat " → " cycle)
    in
    (* Attribute one diagnostic per file in the cycle.  We don't have
       file paths for each module, but the LSP will look them up via
       `Loader.file_of_module_id` if needed.  For now we attach all to
       the root file as a single conservative report. *)
    let _ = cycle in
    push_into b root_file {
      severity = Error;
      loc      = dummy_loc ~file:root_file;
      message  = msg;
    }
  | Loader.UnknownModule { mod_id; importer_file } ->
    let attribute_to = match importer_file with
      | Some f -> f
      | None   -> root_file
    in
    let loc =
      match read attribute_to with
      | Some source ->
        (match scan_use_loc ~file:attribute_to ~source ~mod_id with
         | Some l -> l
         | None   -> dummy_loc ~file:attribute_to)
      | None ->
        (* Fall back to reading from disk if no override has it. *)
        (try
           let ic = open_in attribute_to in
           let n  = in_channel_length ic in
           let s  = Bytes.create n in
           really_input ic s 0 n;
           close_in ic;
           match scan_use_loc ~file:attribute_to
                   ~source:(Bytes.to_string s) ~mod_id with
           | Some l -> l
           | None   -> dummy_loc ~file:attribute_to
         with _ -> dummy_loc ~file:attribute_to)
    in
    push_into b attribute_to {
      severity = Error;
      loc;
      message  = Printf.sprintf "Unknown module: %s" mod_id;
    }
  | Loader.AmbiguousModule { mod_id; found_in } ->
    push_into b root_file {
      severity = Error;
      loc      = dummy_loc ~file:root_file;
      message  = Printf.sprintf "Ambiguous module '%s' found in: %s"
                   mod_id (String.concat ", " found_in);
    }

(* Public entry point for multi-file analysis.  Loads [root_file]'s
   import graph using [read] for buffer overrides, then runs the
   resolve + typecheck pipeline module-by-module, bucketing diagnostics
   by `loc.file`.  Returns one entry per file in the graph (including
   files with empty diagnostic lists, so callers can clear previously
   reported errors). *)
let analyze_project
    ~(root_file : string)
    ~(project_dir : string)
    ~(read : string -> string option)
  : (string * diagnostic list) list =
  let buckets : buckets = Hashtbl.create 8 in

  let modules_opt =
    try Some (Loader.load_program ~read root_file [project_dir])
    with Loader.LoadError e ->
      attribute_load_error buckets ~root_file ~read e;
      None
  in
  match modules_opt with
  | None ->
    Hashtbl.fold (fun file r acc -> (file, List.rev !r) :: acc) buckets []
  | Some modules ->
    (* Seed an empty bucket for every loaded file so they appear in the
       result (with an empty diag list if clean). *)
    List.iter (fun (_mid, fp, _prog) ->
      let _ = bucket_for buckets fp in ()
    ) modules;

    let modules =
      List.map (fun (mid, fp, prog) ->
        (mid, fp, Desugar.desugar_program prog)
      ) modules
    in

    (* Resolve all modules in dependency order, accumulating exports. *)
    let resolve_exports = ref [] in
    List.iter (fun (mod_id, file_path, prog) ->
      let (exports, errs) =
        Resolve.resolve_module !resolve_exports mod_id prog
      in
      List.iter (fun (err, loc_opt) ->
        push_into buckets (loc_or_dummy ~file:file_path loc_opt).file {
          severity = Error;
          loc      = loc_or_dummy ~file:file_path loc_opt;
          message  = pp_resolve_error err;
        }
      ) errs;
      (* Always accumulate exports — even on errors — so later modules
         don't cascade into "unknown module" noise. *)
      resolve_exports := exports :: !resolve_exports
    ) modules;

    (* Typecheck all modules in dependency order.  One Type_error per
       module max (typecheck still raises on first failure). *)
    let type_exports = ref [] in
    List.iter (fun (mod_id, file_path, prog) ->
      (try
        let (te, _schemes, warnings) =
          Typecheck.typecheck_module !type_exports mod_id prog
        in
        type_exports := te :: !type_exports;
        List.iter (fun msg ->
          push_into buckets file_path
            { severity = Warning; loc = dummy_loc ~file:file_path; message = msg }
        ) warnings
       with Typecheck.Type_error (e, loc_opt) ->
         let loc = loc_or_dummy ~file:file_path loc_opt in
         push_into buckets loc.file {
           severity = Error;
           loc;
           message  = pp_type_error e;
         })
    ) modules;

    Hashtbl.fold (fun file r acc -> (file, List.rev !r) :: acc) buckets []
