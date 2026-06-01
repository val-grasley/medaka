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

    (* Parse each example as a synthetic top-level binding.  Examples with an
       expected line are rendered through the user-facing `show` (Show), à la
       GHCi/doctest, so the comparison is against the language's own rendering
       contract rather than the interpreter-internal pp_value.  The parens keep
       precedence (`ex.input` may be an application or operator expression).
       Examples with no expected line stay raw — forcing `show` on an
       effectful or non-Show result would turn a passing smoke example into an
       error (and needlessly enlarge the Show-constraint surface). *)
    let synth_results = List.mapi (fun i ex ->
      let name = synth_name i in
      let rhs = match ex.expected with
        | Some _ -> "show (" ^ ex.input ^ ")"
        | None   -> ex.input
      in
      let src = name ^ " = " ^ rhs in
      try
        let raw = parse_snippet src in
        Ok (Desugar.desugar_program raw)
      with
      | Parser.Error -> Error (Printf.sprintf "could not parse: %s" ex.input)
      | Failure msg  -> Error msg
    ) all_examples in

    let synth_decls =
      List.concat_map (function Ok d -> d | Error _ -> []) synth_results
    in
    let combined = base_decls @ synth_decls in

    (* Phase 70: run the marker + typecheck before eval so return-position and
       multi-parameter interface dispatch resolves to the impl the checker
       chose (the marker fills each EMethodRef's impl-key ref *in place*, and
       eval reads it).  Without this, doctests fell back to arg-tag "first impl
       wins".  Mirror the run-mode pipeline (mark_with_prelude → check_program →
       Dict_pass.run).  If typecheck fails, fall back to evaluating the original
       (unmarked) program so a doctest's own type error doesn't mask its result
       — eval then degrades to the old arg-tag dispatch. *)
    (* Phase 69.x-c: on a successful typecheck, dict-pass the marked prelude with
       the marked program and eval without re-prepending; on failure, fall back
       to the original (unmarked) program with the legacy raw-prelude prepend. *)
    let (combined, prepend_prelude) =
      let marked = Method_marker.mark_with_prelude combined in
      match (try Some (Typecheck.check_program marked) with _ -> None) with
      | Some _ -> (Dict_pass.run (Method_marker.marked_prelude @ marked), false)
      | None   -> (combined, true)
    in

    (* Suppress side-effect output during doctest evaluation *)
    let buf = Buffer.create 64 in
    Eval.output_hook := Buffer.add_string buf;
    let env_result =
      (try Ok (Eval.eval_program ~prelude:prepend_prelude combined)
       with
       | Eval.Eval_error (msg, _) -> Error ("runtime error: " ^ msg)
       | Eval.Impl_no_match       -> Error "non-exhaustive match"
       | Failure msg              -> Error msg)
    in
    Eval.output_hook := print_string;
    ignore (Buffer.contents buf);

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
                (* For comparison examples the synth binding is `show (...)`, so
                   `v` is the VString that `show` produced; pp_value (VString s)
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
    { total; passed; failed; errors; details }
  end
