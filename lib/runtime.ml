open Ast

(* Parse extern declarations from the embedded stdlib/runtime.mdk content.
   This is the canonical source of truth for primitive type signatures. *)
let entries : (string * ty) list =
  let lexbuf = Lexing.from_string Stdlib_content.runtime_mdk in
  let prog = Parser.program Lexer.token lexbuf in
  List.filter_map (function DExtern (_, n, ty) -> Some (n, ty) | _ -> None) prog

let names : string list = List.map fst entries
