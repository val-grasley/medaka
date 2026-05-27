(* Probe: Phase 45.6 fix verification *)

open Medaka_lib
open Eval

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at line %d col %d in:\n%s"
                pos.Lexing.pos_lnum
                (pos.Lexing.pos_cnum - pos.Lexing.pos_bol)
                src)

let try_eval label src =
  Printf.printf "[%s]\n" label;
  (try
     let prog = Desugar.desugar_program (parse src) in
     let env = eval_program prog in
     List.iter (fun (n, v) ->
       if List.mem n ["r"; "intShow"; "recShow"; "p"] then
         Printf.printf "  %s = %s\n" n (pp_value v)) env
   with
   | Eval_error (m, _) -> Printf.printf "  ERR: %s\n" m
   | Failure m -> Printf.printf "  PARSE: %s\n" m);
  print_endline ""

let () =
  (* The Phase 45.6 reproduction: Show on Int collides with Show on Point.
     With the fix, show should dispatch correctly to each impl. *)
  try_eval "Phase 45.6 fix" {|impl Show Int where
  show x = "I"
record Point
  x : Int
  y : Int
deriving (Show)
p = Point { x = 3, y = 4 }
intShow = show 5
recShow = show p
|};

  (* Should print the new pp_value format. *)
  try_eval "pp_value with name" {|record P
  x : Int
p = P { x = 5 }
r = p
|};
  ()
