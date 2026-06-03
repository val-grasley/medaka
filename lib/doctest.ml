type example = {
  input    : string;
  expected : string option;
  src_line : int;
}

type doctest = {
  dt_file     : string;
  dt_examples : example list;
}

type example_result =
  | Pass
  | Fail of { expected : string; actual : string }
  | Error of string

type run_result = {
  total   : int;
  passed  : int;
  failed  : int;
  errors  : int;
  details : (example * example_result) list;
}

(* ── Comment classification ──────────────────────────────────────────────── *)

let is_input_line (c : Lexer.comment) =
  String.length c.c_text >= 5 && String.sub c.c_text 0 5 = "-- > "

let input_body (c : Lexer.comment) =
  String.sub c.c_text 5 (String.length c.c_text - 5)

let is_expected_line (c : Lexer.comment) =
  String.length c.c_text >= 3
  && String.sub c.c_text 0 3 = "-- "
  && not (is_input_line c)

let expected_body (c : Lexer.comment) =
  String.sub c.c_text 3 (String.length c.c_text - 3)

let is_blank_comment (c : Lexer.comment) = c.c_text = "--"

(* ── Block-comment expansion ────────────────────────────────────────────── *)

(* Doctests are authored line-by-line (`-- > expr` then `-- result`).  The
   lexer captures a `{- ... -}` block comment as a *single* record whose
   [c_text] carries embedded newlines, so to let doctests live inside block
   comments we expand each block into virtual per-line records shaped exactly
   like the line-comment form the extractor below already understands:

     a blank inner line   → "--"          (block separator — as the blank
                                            `--` between prose and examples)
     any other inner line → "-- <trimmed>" so an inner `> expr` becomes
                            "-- > expr" (an input line) and a bare value
                            becomes an expected-output line.

   Line comments pass straight through, so the line-comment doctest path is
   byte-for-byte unchanged. *)
let is_block_comment (c : Lexer.comment) =
  String.length c.c_text >= 2 && String.sub c.c_text 0 2 = "{-"

let expand_block (c : Lexer.comment) : Lexer.comment list =
  let n = String.length c.c_text in
  (* Strip the `{-` opener and `-}` closer; tolerate a malformed short text. *)
  let inner = if n >= 4 then String.sub c.c_text 2 (n - 4) else "" in
  String.split_on_char '\n' inner
  |> List.mapi (fun i line ->
       let trimmed = String.trim line in
       let c_text = if trimmed = "" then "--" else "-- " ^ trimmed in
       (* Line numbers stay accurate: inner line i sits on the opener line
          plus i, so adjacency in [split_into_blocks] is preserved. *)
       { c with Lexer.c_line = c.c_line + i; c_text })

(* ── Phase 1: split comment list into adjacent blocks ───────────────────── *)

(* A `--` bare comment or a gap in line numbers ends the current block. *)
let split_into_blocks (comments : Lexer.comment list) : Lexer.comment list list =
  let rec loop acc current last = function
    | [] ->
      let blocks = if current = [] then acc else List.rev current :: acc in
      List.rev blocks
    | c :: rest ->
      if is_blank_comment c then
        let blocks = if current = [] then acc else List.rev current :: acc in
        loop blocks [] c.c_line rest
      else if current = [] || c.c_line = last + 1 then
        loop acc (c :: current) c.c_line rest
      else
        loop (List.rev current :: acc) [c] c.c_line rest
  in
  loop [] [] 0 comments

(* ── Phase 2: extract examples from one adjacent block ──────────────────── *)

let extract_examples_from_block block =
  let seal_example inp_opt expected_rev =
    match inp_opt with
    | None -> None
    | Some (inp, ln) ->
      let exp = match List.rev expected_rev with
        | [] -> None
        | lines -> Some (String.concat "\n" lines)
      in
      Some { input = inp; expected = exp; src_line = ln }
  in
  let rec loop examples cur_input expected_rev = function
    | [] ->
      let examples' = match seal_example cur_input expected_rev with
        | None -> examples | Some ex -> ex :: examples
      in
      List.rev examples'
    | c :: rest ->
      if is_input_line c then
        let examples' = match seal_example cur_input expected_rev with
          | None -> examples | Some ex -> ex :: examples
        in
        loop examples' (Some (input_body c, c.c_line)) [] rest
      else if is_expected_line c then
        (match cur_input with
         | None -> loop examples None [] rest
         | Some _ -> loop examples cur_input (expected_body c :: expected_rev) rest)
      else
        (* Prose comment within a block ends the current example *)
        let examples' = match seal_example cur_input expected_rev with
          | None -> examples | Some ex -> ex :: examples
        in
        loop examples' None [] rest
  in
  loop [] None [] block

(* ── Public extraction entry point ─────────────────────────────────────── *)

let extract_doctests (file : string) (comments : Lexer.comment list) : doctest list =
  let comments =
    List.concat_map
      (fun c -> if is_block_comment c then expand_block c else [c])
      comments
  in
  split_into_blocks comments
  |> List.filter_map (fun block ->
    let examples = extract_examples_from_block block in
    if examples = [] then None
    else Some { dt_file = file; dt_examples = examples })

(* ── Runner ─────────────────────────────────────────────────────────────── *)

let read_file filename =
  let ic = open_in filename in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let parse_snippet src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string (src ^ "\n") in
  Parser.program Lexer.token lexbuf

let synth_name i = Printf.sprintf "__dt_%d__" i

let has_use_decls prog =
  List.exists (function Ast.DUse _ -> true | _ -> false) prog

(* Parse each example as a synthetic top-level binding.  Examples with an
   expected line are rendered through the user-facing `debug` (Debug), à la
   GHCi/doctest, so the comparison is against the language's own rendering
   contract rather than the interpreter-internal pp_value.  The parens keep
   precedence (`ex.input` may be an application or operator expression).
   Examples with no expected line stay raw — forcing `debug` on an effectful or
   non-Debug result would turn a passing smoke example into an error (and
   needlessly enlarge the Debug-constraint surface). *)
let build_synth_results all_examples =
  List.mapi (fun i ex ->
    let name = synth_name i in
    let rhs = match ex.expected with
      | Some _ -> "debug (" ^ ex.input ^ ")"
      | None   -> ex.input
    in
    let src = name ^ " = " ^ rhs in
    try
      let raw = parse_snippet src in
      Ok (Desugar.desugar_program raw)
    with
    | Parser.Error -> Error (Printf.sprintf "could not parse: %s" ex.input)
    | Failure msg  -> Error msg
  ) all_examples

(* Evaluate [combined] with side-effect output suppressed, returning the
   top-level binding environment (or a single error string). *)
let eval_suppressed ~prelude combined =
  let buf = Buffer.create 64 in
  Eval.output_hook := Buffer.add_string buf;
  let env_result =
    (try Ok (Eval.eval_program ~prelude combined)
     with
     | Eval.Eval_error (msg, _) -> Error ("runtime error: " ^ msg)
     | Eval.Impl_no_match       -> Error "non-exhaustive match"
     | Failure msg              -> Error msg)
  in
  Eval.output_hook := print_string;
  ignore (Buffer.contents buf);
  env_result

(* Phase 110: like [eval_suppressed] but evaluates each module in its own name
   scope via [Eval.eval_modules] (which dict-passes the marked prelude + modules
   internally), so cross-module same-named functions don't mis-dispatch.
   Returns the root module's bindings (carrying the synth `__dt_i__` names). *)
let eval_suppressed_modules marked_modules =
  let buf = Buffer.create 64 in
  Eval.output_hook := Buffer.add_string buf;
  let env_result =
    (try Ok (Eval.eval_modules marked_modules)
     with
     | Eval.Eval_error (msg, _) -> Error ("runtime error: " ^ msg)
     | Eval.Impl_no_match       -> Error "non-exhaustive match"
     | Failure msg              -> Error msg)
  in
  Eval.output_hook := print_string;
  ignore (Buffer.contents buf);
  env_result

(* Look up each example's evaluated synth binding and compare against expected.
   [env_result] is either the shared eval environment (Ok env) or a single
   error that applies to every example (Error msg) — e.g. a whole-program
   typecheck or load failure, which makes every example ERROR at once. *)
let build_details
    (env_result : ((string * Eval.value) list, string) result)
    (synth_results : (Ast.program, string) result list) all_examples
    : run_result =
  let details = List.mapi (fun i ex ->
    let result =
      match List.nth synth_results i with
      | Error msg -> Error msg
      | Ok _ ->
        (match env_result with
         | Error msg -> Error msg
         | Ok env ->
           (match List.assoc_opt (synth_name i) env with
            | None -> Error (Printf.sprintf "could not evaluate: %s" ex.input)
            | Some v ->
              (* For comparison examples the synth binding is `debug (...)`, so
                 `v` is the VString that `debug` produced; pp_value (VString s)
                 = s extracts it verbatim.  Smoke examples (expected = None)
                 are unwrapped, and their actual value is never compared. *)
              let actual = Eval.pp_value v in
              (match ex.expected with
               | None     -> Pass
               | Some exp ->
                 if actual = exp then Pass
                 else Fail { expected = exp; actual })))
    in
    (ex, result)
  ) all_examples in
  let count f = List.length (List.filter (fun (_, r) -> f r) details) in
  let passed = count (fun r -> r = Pass) in
  let failed = count (function Fail _ -> true | _ -> false) in
  let errors = count (function Error _ -> true | _ -> false) in
  { total = List.length all_examples; passed; failed; errors; details }

(* Phase 92: doctests in a file with `import`/`use` declarations are
   type-checked and evaluated through the *multi-module* pipeline (mirrors the
   multi-file path of `medaka run`/`check` in bin/main.ml), so a doctest sees
   the instances and values its file imports from sibling modules — without
   flattening the modules into one (which would merge their deliberately-reused
   top-level names like `find`/`map` and corrupt dispatch).  The synthetic
   `__dt_i__` bindings are injected into the *root* module (the file under test)
   so they resolve and type-check in its import scope.  On any load/resolve
   failure we `failwith` (the CLI's run_one catches it); on a typecheck failure
   every example honestly reports the type error rather than degrading to
   arg-tag dispatch.

   Returns [None] when the loader resolved no real sibling module (every import
   was the implicit prelude `core`, which the loader filters): there is then
   nothing cross-module to reach, so the caller uses the single-file path — which
   shadow-drops prelude names via `prelude_for` and so avoids the
   prelude/standalone name collision (e.g. a module redefining `count`) that the
   full `marked_prelude` of this path would hit. *)
(* Load [filename] + its transitive deps and run them through the multi-module
   pipeline (desugar → resolve → mark → two-pass typecheck), yielding the marked
   modules ready for [Eval.eval_modules].  [inject fp prog] lets a caller append
   synthetic declarations to a chosen module (doctest appends its `__dt_i__`
   bindings to the root; the prop phase passes the default identity).

   Returns [None] when ≤1 module loaded — the caller should fall back to the
   single-file path.  On success returns [Some (marked_modules, tc_err)] where
   [marked_modules] is in dependency-first order (root last) and [tc_err] is any
   deferred typecheck-error message (surfaced as data, not raised, so callers
   choose how to report it).  Raises [Failure] on load / resolve errors.

   Factored out of [run_file_multi] (Phase 126) so the `medaka test` prop phase
   can drive import-bearing files through the same path doctests use. *)
let assemble_marked_modules
      ?(inject = fun _fp prog -> prog)
      (filename : string)
    : ((string * string * Ast.program) list * string option) option =
  let project_dir =
    match Project_config.find_project_root filename with
    | Some d -> d
    | None   -> Filename.dirname filename
  in
  let loaded =
    try Loader.load_program filename [ project_dir ]
    with Loader.LoadError e ->
      let msg = match e with
        | Loader.FileNotFound f -> Printf.sprintf "file not found: %s" f
        | Loader.CyclicDependency cycle ->
          Printf.sprintf "cyclic dependency: %s" (String.concat " -> " cycle)
        | Loader.UnknownModule { mod_id; _ } ->
          Printf.sprintf "unknown module: %s" mod_id
        | Loader.AmbiguousModule { mod_id; found_in } ->
          Printf.sprintf "ambiguous module '%s' found in: %s" mod_id
            (String.concat ", " found_in)
        | Loader.ParseError { file; line; col; message } ->
          Printf.sprintf "%s:%d:%d: %s" file line col message
      in
      failwith msg
  in
  if List.length loaded <= 1 then None
  else
  (* Desugar every module; let the caller inject synthetic decls into a chosen
     module (keyed by file_path — the root is the entry under test). *)
  let modules =
    List.map (fun (mid, fp, prog) ->
      let prog = Desugar.desugar_program prog in
      let prog = inject fp prog in
      (mid, fp, prog)
    ) loaded
  in
  (* Resolve in dependency order, accumulating exports. *)
  let resolve_exports = ref [] in
  let resolve_err = ref None in
  List.iter (fun (mod_id, _fp, prog) ->
    if !resolve_err = None then begin
      let (exports, errs) = Resolve.resolve_module !resolve_exports mod_id prog in
      (match errs with
       | (err, _loc) :: _ -> resolve_err := Some (Resolve.pp_error err)
       | [] -> ());
      resolve_exports := exports :: !resolve_exports
    end
  ) modules;
  match !resolve_err with
  | Some msg -> failwith msg
  | None ->
    (* Mark interface methods + constrained fns across every module + the
       prelude (so cross-module references and `when`/`unless` route). *)
    let method_names =
      Method_marker.interface_method_names
        (Prelude.program :: List.map (fun (_, _, p) -> p) modules)
    in
    let constrained_names =
      Method_marker.constrained_fn_names
        (Prelude.program :: List.map (fun (_, _, p) -> p) modules)
    in
    let base_modules = modules in
    (* One typecheck sweep over the module chain; returns the marked modules,
       any promotable do-block constraints discovered, and the first type
       error (if any). *)
    let typecheck_all ~constrained ?promoted () =
      let marked = List.map (fun (mid, fp, prog) ->
        (mid, fp, Method_marker.mark_program method_names constrained prog)
      ) base_modules in
      let type_exports = ref [] in
      let promoted_out = Hashtbl.create 8 in
      let err = ref None in
      List.iter (fun (mod_id, _fp, prog) ->
        if !err = None then
          (try
            let (te, _schemes, _warnings) =
              Typecheck.typecheck_module ?promoted ~promoted_out
                !type_exports mod_id prog
            in
            type_exports := te :: !type_exports
          with Typecheck.Type_error (e, _loc) ->
            err := Some (Typecheck.pp_error e))
      ) marked;
      (marked, promoted_out, !err)
    in
    let (modules1, promoted, err1) =
      typecheck_all ~constrained:constrained_names () in
    (* Phase 88 two-pass: if pass 1 found a promotable unsignatured do-block,
       re-mark + re-check with those names constrained so return-position
       methods like `pure` route by the caller's monad. *)
    let (marked_modules, tc_err) =
      match err1 with
      | Some _ -> (modules1, err1)
      | None ->
        if Hashtbl.length promoted = 0 then (modules1, None)
        else begin
          let constrained2 = Hashtbl.copy constrained_names in
          Hashtbl.iter (fun k () -> Hashtbl.replace constrained2 k ()) promoted;
          let (m2, _p2, err2) =
            typecheck_all ~constrained:constrained2 ~promoted () in
          (m2, err2)
        end
    in
    Some (marked_modules, tc_err)

let run_file_multi filename all_examples synth_results synth_decls
    : run_result option =
  match
    assemble_marked_modules
      ~inject:(fun fp prog -> if fp = filename then prog @ synth_decls else prog)
      filename
  with
  | None -> None
  | Some (marked_modules, tc_err) ->
    let env_result : ((string * Eval.value) list, string) result =
      match tc_err with
      | Some msg -> Error msg
      | None     -> eval_suppressed_modules marked_modules
    in
    Some (build_details env_result synth_results all_examples)

(* Single-file path: type-check the file flattened with the prepended prelude
   (which `prelude_for` shadow-drops names the file redefines), then eval.  Used
   for files with no imports, and as the fallback when a file's only imports were
   the implicit prelude (so the loader found no real sibling to reach). *)
let run_file_single base_decls synth_results synth_decls all_examples
    : run_result =
  let combined = base_decls @ synth_decls in

  (* Phase 70: run the marker + typecheck before eval so return-position and
     multi-parameter interface dispatch resolves to the impl the checker chose
     (the marker fills each EMethodRef's impl-key ref *in place*, and eval reads
     it).  Without this, doctests fell back to arg-tag "first impl wins".  Mirror
     the run-mode pipeline (mark_with_prelude → check_program → Dict_pass.run).
     If typecheck fails, fall back to evaluating the original (unmarked) program
     so a doctest's own type error doesn't mask its result — eval then degrades
     to the old arg-tag dispatch. *)
  (* Phase 69.x-c: on a successful typecheck, dict-pass the marked prelude with
     the marked program and eval without re-prepending; on failure, fall back to
     the original (unmarked) program with the legacy raw-prelude prepend.

     When the file under test *is* the prelude (`medaka test stdlib/core.mdk`),
     it already declares everything the prelude provides, so prepending the
     prelude here would duplicate every top-level decl — two `Debug (List a)`
     impls, etc. — which corrupts dispatch (a duplicated constrained helper can
     send `++` into an infinite `append` loop).  `Typecheck.check_program`
     already skips its internal prelude prepend via `program_is_core`; mirror
     that on the eval side so both stay symmetric. *)
  let is_core = Typecheck.program_is_core base_decls in
  let (combined, prepend_prelude) =
    let marked = Method_marker.mark_with_prelude combined in
    match (try Some (Typecheck.check_program marked) with _ -> None) with
    | Some _ ->
      let dict_passed =
        if is_core then Dict_pass.run marked
        else Dict_pass.run (Method_marker.prelude_for marked @ marked)
      in
      (dict_passed, false)
    | None -> (combined, not is_core)
  in
  let env_result = eval_suppressed ~prelude:prepend_prelude combined in
  build_details env_result synth_results all_examples

let run_file (filename : string) : run_result =
  let source = read_file filename in
  Lexer.reset ();
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  let decls =
    try Parser.program Lexer.token lexbuf
    with Parser.Error ->
      let pos = lexbuf.Lexing.lex_curr_p in
      failwith (Printf.sprintf "%s:%d:%d: parse error" filename
                  pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))
  in
  (* Must capture comments before any parse_snippet calls reset the side-channel *)
  let comments = Lexer.take_comments () in
  let doctests = extract_doctests filename comments in
  let all_examples = List.concat_map (fun dt -> dt.dt_examples) doctests in
  let total = List.length all_examples in
  if total = 0 then
    { total = 0; passed = 0; failed = 0; errors = 0; details = [] }
  else begin
    let base_decls = Desugar.desugar_program decls in
    let synth_results = build_synth_results all_examples in
    let synth_decls =
      List.concat_map (function Ok d -> d | Error _ -> []) synth_results
    in
    (* Phase 92: a file that imports real sibling modules reaches their instances
       through the multi-module pipeline; a file with no imports (or whose only
       imports were the implicit prelude) takes the single-file path. *)
    let multi =
      if has_use_decls base_decls then
        run_file_multi filename all_examples synth_results synth_decls
      else None
    in
    match multi with
    | Some r -> r
    | None -> run_file_single base_decls synth_results synth_decls all_examples
  end
