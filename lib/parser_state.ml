(* Parser/lexer side channels.
   Lives in its own module so both `lexer.mll` (which opens Parser) and
   `parser.mly` (whose preamble cannot reference Lexer without creating a
   build cycle) can populate and read it. *)

(* Top-level declaration positions, in source order. *)
let decl_positions : Ast.loc list ref = ref []

let record_decl_pos (loc : Ast.loc) =
  decl_positions := loc :: !decl_positions

(* Remove the most recently recorded position.  Used by the attribute `decl`
   production to replace the inner decl's position with the outer span. *)
let pop_decl_pos () =
  match !decl_positions with
  | _ :: rest -> decl_positions := rest
  | [] -> ()

let take_decl_positions () = List.rev !decl_positions

(* Line number of the most recently consumed non-trivia content.  The
   lexer updates this in the newlines rule, capturing the line where the
   preceding content ended; this is more useful for `medaka fmt` than the
   post-newlines $endpos that a parser rule would otherwise see. *)
let last_content_line : int ref = ref 0

let reset () =
  decl_positions := [];
  last_content_line := 0
