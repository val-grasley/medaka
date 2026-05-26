(* Parse and desugar the embedded stdlib/core.mdk exactly once.
   The resulting program is prepended to user programs in the type checker
   and evaluator so that built-in interfaces, data types, and helper
   functions are available without an explicit import. *)

let program : Ast.program =
  let lexbuf = Lexing.from_string Prelude_content.core_mdk in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = "core.mdk" };
  Lexer.reset ();
  let parsed =
    try Parser.program Lexer.token lexbuf
    with Parser.Error ->
      let pos = lexbuf.Lexing.lex_curr_p in
      failwith (Printf.sprintf
        "core.mdk: parse error at line %d col %d"
        pos.Lexing.pos_lnum
        (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))
  in
  Desugar.desugar_program parsed
