(* Eval oracle for the self-hosted eval stage.
 *
 *   dev/eval_probe.exe <file.mdk>
 *
 * Parses + desugars the file (NO prelude — the file must be self-contained),
 * evaluates it via the UNTYPED engine path [Eval.eval_program ~prelude:false],
 * and prints `pp_value` of the `main` binding.  This isolates the eval ENGINE
 * (closures, env, match, arithmetic, ADTs, recursion, records, lists) from the
 * prelude/dispatch layer: the self-hosted eval renders the same value with its
 * own pp_value and we diff the two.  Fixtures aggregate their results into a
 * single `main` (a tuple/list) for one clean, unambiguous output line. *)

open Medaka_lib

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at line %d col %d"
                pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

(* The bindings alist can carry a name more than once (multi-clause functions
   install intermediates); the final installed value is the last occurrence. *)
let last_assoc name bindings =
  List.fold_left (fun acc (n, v) -> if n = name then Some v else acc) None bindings

let read_file file =
  let ic = open_in file in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic; s

let () =
  (* `eval_probe [--prelude] <file.mdk>`.  With --prelude, evaluate against the
     real (embedded) prelude via ~prelude:true — for fixtures that use prelude
     interface methods.  Without, ~prelude:false isolates the engine and we
     inject `otherwise` so prelude-free guards parse. *)
  let with_prelude = Array.length Sys.argv > 2 && Sys.argv.(1) = "--prelude" in
  let file = Sys.argv.(Array.length Sys.argv - 1) in
  let prog0 = Desugar.desugar_program (parse (read_file file)) in
  let bindings =
    if with_prelude then Eval.eval_program ~prelude:true prog0
    else
      let otherwise_decl =
        Ast.DFunDef (false, "otherwise", [], Ast.ELit (Ast.LBool true)) in
      Eval.eval_program ~prelude:false (otherwise_decl :: prog0)
  in
  match last_assoc "main" bindings with
  | Some v -> print_string (Eval.pp_value v); print_newline ()
  | None -> prerr_endline "eval_probe: no `main` binding"; exit 1
