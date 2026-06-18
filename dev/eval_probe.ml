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

let parse_desugar file = Desugar.desugar_program (parse (read_file file))

let () =
  (* Three modes (last arg is always the target .mdk):
       eval_probe <file>                     engine only (~prelude:false), inject `otherwise`
       eval_probe --prelude <file>           against the embedded core prelude (~prelude:true)
       eval_probe --prepend <f1>..<fn> <file> parse+desugar f1..fn, prepend, eval ~prelude:false
     The --prepend form lets the oracle match the self-host loading core.mdk +
     list.mdk + … (parsed fresh) rather than the embedded core. *)
  let argv = Sys.argv in
  let n = Array.length argv in
  let target = argv.(n - 1) in
  let bindings =
    match (if n > 1 then argv.(1) else "") with
    | "--prelude" -> Eval.eval_program ~prelude:true (parse_desugar target)
    | "--prepend" ->
      let prepend =
        Array.to_list (Array.sub argv 2 (n - 3))
        |> List.concat_map parse_desugar in
      Eval.eval_program ~prelude:false (prepend @ parse_desugar target)
    | _ ->
      let otherwise_decl =
        Ast.DFunDef (false, "otherwise", [], Ast.ELit (Ast.LBool true)) in
      Eval.eval_program ~prelude:false (otherwise_decl :: parse_desugar target)
  in
  (* A `main` whose result is Unit prints nothing — matching `main.exe run` /
     native, which suppress the Unit-main auto-print (d0a99a9): a Unit main is an
     effect sequence, its `()` result is not a value to render.  Value mains still
     print their result via pp_value. *)
  match last_assoc "main" bindings with
  | Some Eval.VUnit -> ()
  | Some v -> print_string (Eval.pp_value v); print_newline ()
  | None -> prerr_endline "eval_probe: no `main` binding"; exit 1
