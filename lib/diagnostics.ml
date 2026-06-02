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

(* Push a generic "internal error" diagnostic — used when an unexpected
   exception escapes a pipeline stage.  We log the full backtrace via
   [Lsp_log.exn] and surface a short marker in the editor so the user can
   tell the analyzer hit a bug. *)
let push_internal_error push ~file ~stage e =
  Lsp_log.exn
    (Printf.sprintf "internal error in %s for %s" stage file) e;
  push {
    severity = Error;
    loc      = dummy_loc ~file;
    message  = Printf.sprintf "Internal error in %s: %s"
                 stage (Printexc.to_string e);
  }

(* Lex+parse [source] for [file].  Returns the program AST (if any) and the
   parse-error diagnostic (if any).  Used both by [analyze] (which then
   continues with the AST) and by the last-good-source cache in
   [analyze_project] (which only needs the bool for "did it parse?"). *)
let parse_with_diag ~(file : string) ~(source : string)
  : Ast.program option * diagnostic option =
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = file };
  Lexer.reset ();
  try (Some (Parser.program Lexer.token lexbuf), None) with
  | Parser.Error ->
    let d = {
      severity = Error;
      loc      = loc_of_lex_pos lexbuf.lex_curr_p;
      message  = "Parse error";
    } in
    (None, Some d)
  | Failure msg ->
    let d = {
      severity = Error;
      loc      = loc_of_lex_pos lexbuf.lex_curr_p;
      message  = msg;
    } in
    (None, Some d)
  | e ->
    Lsp_log.exn
      (Printf.sprintf "internal error in parse for %s" file) e;
    let d = {
      severity = Error;
      loc      = dummy_loc ~file;
      message  = Printf.sprintf "Internal error in parse: %s"
                   (Printexc.to_string e);
    } in
    (None, Some d)

(* Returns [None] if [source] parses cleanly; [Some diag] otherwise. *)
let parse_only ~(file : string) ~(source : string) : diagnostic option =
  snd (parse_with_diag ~file ~source)

let analyze ~(file : string) ~(source : string) : diagnostic list =
  let diags = ref [] in
  let push d = diags := d :: !diags in

  let (program_opt, parse_err) = parse_with_diag ~file ~source in
  (match parse_err with Some d -> push d | None -> ());
  (match program_opt with
   | None -> ()
   | Some prog ->
     (* Phase 91 (2): guard-exhaustiveness warnings run on the *raw* program
        (function-clause guards are gone after desugar). *)
     (try
        List.iter (fun msg ->
          push { severity = Warning; loc = dummy_loc ~file; message = msg })
          (Exhaust.check_guard_exhaustiveness prog)
      with e -> push_internal_error push ~file ~stage:"guard-exhaustiveness" e);
     let prog_opt =
       try Some (Desugar.desugar_program prog) with e ->
         push_internal_error push ~file ~stage:"desugar" e; None
     in
     (match prog_opt with
      | None -> ()
      | Some prog ->
        let resolve_errs_opt =
          try Some (Resolve.resolve_program prog) with e ->
            push_internal_error push ~file ~stage:"resolve" e; None
        in
        (match resolve_errs_opt with
         | None -> ()
         | Some resolve_errs ->
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
             with
             | Typecheck.Type_error (e, loc_opt) ->
               push {
                 severity = Error;
                 loc      = loc_or_dummy ~file loc_opt;
                 message  = pp_type_error e;
               }
             | e ->
               push_internal_error push ~file ~stage:"typecheck" e
           end)));
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
  | Loader.ParseError { file; line; col; message } ->
    push_into b file {
      severity = Error;
      loc      = {
        Ast.file;
        line;
        col;
        end_line = line;
        end_col  = col + 1;
      };
      message;
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
    ?(last_good_source : (string, string) Hashtbl.t option)
    ()
  : (string * diagnostic list) list =
  let buckets : buckets = Hashtbl.create 8 in

  let push_module_internal_error ~file_path ~stage e =
    Lsp_log.exn
      (Printf.sprintf "internal error in %s for %s" stage file_path) e;
    push_into buckets file_path {
      severity = Error;
      loc      = dummy_loc ~file:file_path;
      message  = Printf.sprintf "Internal error in %s: %s"
                   stage (Printexc.to_string e);
    }
  in

  (* Last-good-source substitution.  When the editor buffer for [path]
     currently has a parse error but the cache has a prior version that
     parses, swap it in so Loader can still build the import graph and
     downstream stages (resolve/typecheck) produce useful diagnostics for
     the rest of the project.  Files that go stale this round get their
     real parse-error diagnostic appended after analysis runs. *)
  let cache =
    match last_good_source with
    | Some c -> c
    | None   -> Hashtbl.create 0  (* throwaway; never read elsewhere *)
  in
  let stale : (string, diagnostic) Hashtbl.t = Hashtbl.create 4 in
  let wrapped_read path =
    match read path with
    | None -> None
    | Some src ->
      (match parse_only ~file:path ~source:src with
       | None ->
         Hashtbl.replace cache path src;
         Some src
       | Some parse_err ->
         Hashtbl.replace stale path parse_err;
         (match Hashtbl.find_opt cache path with
          | Some good -> Some good
          | None      -> Some src))
  in

  let modules_opt =
    try Some (Loader.load_program ~read:wrapped_read root_file [project_dir])
    with
    | Loader.LoadError e ->
      attribute_load_error buckets ~root_file ~read:wrapped_read e;
      None
    | e ->
      push_module_internal_error ~file_path:root_file ~stage:"loader" e;
      None
  in
  (match modules_opt with
  | None -> ()
  | Some modules ->
    (* Seed an empty bucket for every loaded file so they appear in the
       result (with an empty diag list if clean). *)
    List.iter (fun (_mid, fp, _prog) ->
      let _ = bucket_for buckets fp in ()
    ) modules;

    (* Desugar per-module so a bug on one file doesn't kill the rest.
       Modules that fail to desugar are dropped from the downstream
       pipeline (resolve/typecheck) and replaced with None. *)
    let modules =
      List.map (fun (mid, fp, prog) ->
        (* Phase 91 (2): guard-exhaustiveness warnings on the raw program. *)
        (try
           List.iter (fun msg ->
             push_into buckets fp
               { severity = Warning; loc = dummy_loc ~file:fp; message = msg })
             (Exhaust.check_guard_exhaustiveness prog)
         with e -> push_module_internal_error ~file_path:fp ~stage:"guard-exhaustiveness" e);
        try Some (mid, fp, Desugar.desugar_program prog) with e ->
          push_module_internal_error ~file_path:fp ~stage:"desugar" e;
          None
      ) modules
    in
    let modules = List.filter_map (fun x -> x) modules in

    (* Resolve all modules in dependency order, accumulating exports. *)
    let resolve_exports = ref [] in
    List.iter (fun (mod_id, file_path, prog) ->
      try
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
      with e ->
        push_module_internal_error ~file_path ~stage:"resolve" e
    ) modules;

    (* Typecheck all modules in dependency order.  One Type_error per
       module max (typecheck still raises on first failure). *)
    let type_exports = ref [] in
    List.iter (fun (mod_id, file_path, prog) ->
      try
        let (te, _schemes, warnings) =
          Typecheck.typecheck_module !type_exports mod_id prog
        in
        type_exports := te :: !type_exports;
        List.iter (fun msg ->
          push_into buckets file_path
            { severity = Warning; loc = dummy_loc ~file:file_path; message = msg }
        ) warnings
      with
      | Typecheck.Type_error (e, loc_opt) ->
        let loc = loc_or_dummy ~file:file_path loc_opt in
        push_into buckets loc.file {
          severity = Error;
          loc;
          message  = pp_type_error e;
        }
      | e ->
        push_module_internal_error ~file_path ~stage:"typecheck" e
    ) modules);

  (* Surface the real parse-error diagnostic for any file we substituted
     a cached source for, so the user still sees the squiggle in the
     buffer they're typing in. *)
  Hashtbl.iter (fun path diag ->
    push_into buckets path diag;
    let _ = bucket_for buckets path in ()
  ) stale;

  Hashtbl.fold (fun file r acc -> (file, List.rev !r) :: acc) buckets []
