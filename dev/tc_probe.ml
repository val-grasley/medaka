(* Typecheck oracle for the self-hosted typecheck stage.
 *
 *   dev/tc_probe.exe <file.mdk>
 *
 * Parses + desugars the file and type-checks it WITHOUT the prelude
 * (Typecheck.check_program_no_prelude), then prints each user binding's inferred
 * scheme as `name : <pp_scheme>`, sorted by name.  This isolates the HM engine
 * (unification, generalization, instantiation) the way eval_probe isolates the
 * evaluator: fixtures are self-contained / prelude-free, so the self-hosted
 * typechecker is validated against the same bare schemes the reference infers.
 *
 * Internal bindings ($-prefixed, __dt doctest synth) are filtered out. *)

open Medaka_lib

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at line %d col %d"
                pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

let read_file file =
  let ic = open_in file in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic; s

let is_internal n =
  String.length n = 0
  || n.[0] = '$'
  || (String.length n >= 4 && String.sub n 0 4 = "__dt")

let () =
  let file = Sys.argv.(1) in
  let prog = Desugar.desugar_program (parse (read_file file)) in
  match Typecheck.check_program_no_prelude prog with
  | (schemes, _warnings) ->
    schemes
    |> List.filter (fun (n, _) -> not (is_internal n))
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.iter (fun (n, s) -> Printf.printf "%s : %s\n" n (Typecheck.pp_scheme s))
  | exception Typecheck.Type_error (e, _) ->
    Printf.printf "TYPE ERROR: %s\n" (Typecheck.pp_error e)
