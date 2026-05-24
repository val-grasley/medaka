{
open Parser

(* Indentation state *)
let indent_stack : int list ref = ref [0]
let pending : token Queue.t = Queue.create ()

let push_pending t = Queue.push t pending

let handle_indent col =
  let current = List.hd !indent_stack in
  if col > current then begin
    indent_stack := col :: !indent_stack;
    push_pending INDENT
  end else if col < current then begin
    (* Emit NEWLINE for end-of-previous-stmt, then NEWLINE+DEDENT pairs
       so every enclosing block sees a terminator before its DEDENT. *)
    push_pending NEWLINE;
    let rec pop () =
      match !indent_stack with
      | top :: rest when top > col ->
        indent_stack := rest;
        push_pending DEDENT;
        push_pending NEWLINE;
        pop ()
      | _ -> ()
    in
    pop ()
  end else
    push_pending NEWLINE

let reset () =
  indent_stack := [0];
  Queue.clear pending

let keyword_or_ident s =
  match s with
  | "let"       -> LET
  | "mut"       -> MUT
  | "in"        -> IN
  | "if"        -> IF
  | "then"      -> THEN
  | "else"      -> ELSE
  | "match"     -> MATCH
  | "data"      -> DATA
  | "record"    -> RECORD
  | "interface" -> INTERFACE
  | "default"   -> DEFAULT
  | "impl"      -> IMPL
  | "use"       -> USE
  | "pub"       -> PUB
  | "where"     -> WHERE
  | "of"        -> OF
  | "do"        -> DO
  | "as"        -> AS
  | "True"      -> BOOL true
  | "False"     -> BOOL false
  | _           -> IDENT s
}

let white     = [' ' '\t']
let newline   = '\n' | '\r' '\n'
let digit     = ['0'-'9']
let lower     = ['a'-'z']
let upper     = ['A'-'Z']
let alnum     = ['a'-'z' 'A'-'Z' '0'-'9' '_' '\'']
let int_lit   = digit+
let float_lit = digit+ '.' digit+

rule token = parse
  | "" {
      if not (Queue.is_empty pending) then Queue.pop pending
      else read lexbuf
    }

and read = parse
  | white+         { read lexbuf }
  | "--" [^ '\n']* { read lexbuf }
  | newline white* {
      Lexing.new_line lexbuf;
      let s = Lexing.lexeme lexbuf in
      (* Skip the leading newline char(s) to count only the indent *)
      let nl_len =
        if String.length s > 0 && s.[0] = '\r' then 2 else 1
      in
      let indent =
        let i = ref 0 in
        for k = nl_len to String.length s - 1 do
          match s.[k] with
          | ' '  -> incr i
          | '\t' -> i := (!i / 8 + 1) * 8
          | _    -> ()
        done;
        !i
      in
      handle_indent indent;
      token lexbuf
    }

  | int_lit      { INT (int_of_string (Lexing.lexeme lexbuf)) }
  | float_lit    { FLOAT (float_of_string (Lexing.lexeme lexbuf)) }

  | '"'          { read_string (Buffer.create 64) lexbuf }
  | '\'' ([^ '\''] as c) '\'' { CHAR (String.make 1 c) }

  (* Identifiers — order matters: longer matches win, ties go to earlier rule *)
  | lower alnum*           { keyword_or_ident (Lexing.lexeme lexbuf) }
  | '_' alnum+             { keyword_or_ident (Lexing.lexeme lexbuf) }
  | '_'                    { UNDERSCORE }
  | upper alnum*           { UPPER (Lexing.lexeme lexbuf) }

  (* Backtick infix: `name` *)
  | '`' (lower alnum*) '`' {
      let s = Lexing.lexeme lexbuf in
      BACKTICK_IDENT (String.sub s 1 (String.length s - 2))
    }

  (* Compound tokens — must come before single-char rules *)
  | "[|"  { LARRAY }
  | "|]"  { RARRAY }
  | "=>"  { FAT_ARROW }
  | "->"  { ARROW }
  | "<-"  { LARROW }
  | "::"  { CONS }
  | "++"  { PLUSPLUS }
  | "=="  { EQ_EQ }
  | "!="  { NEQ }
  | "<="  { LEQ }
  | ">="  { GEQ }
  | "&&"  { AND }
  | "||"  { OR }
  | "|>"  { PIPE_RIGHT }
  | ">>"  { RCOMPOSE }
  | "<<"  { LCOMPOSE }
  | ".{"  { DOT_LBRACE }
  | ".*"  { DOT_STAR }
  | "@"   { AT }

  | '+'   { PLUS }
  | '-'   { MINUS }
  | '*'   { STAR }
  | '/'   { SLASH }
  | '<'   { LT }
  | '>'   { GT }
  | '='   { EQUAL }
  | ':'   { COLON }
  | ','   { COMMA }
  | '.'   { DOT }
  | '|'   { PIPE }
  | '('   { LPAREN }
  | ')'   { RPAREN }
  | '['   { LBRACKET }
  | ']'   { RBRACKET }
  | '{'   { LBRACE }
  | '}'   { RBRACE }
  | '!'   { BANG }

  | eof   {
      let rec close_all () =
        match !indent_stack with
        | [0] -> ()
        | _ :: rest ->
          indent_stack := rest;
          push_pending DEDENT;
          push_pending NEWLINE;
          close_all ()
        | [] -> ()
      in
      close_all ();
      push_pending EOF;
      token lexbuf
    }

  | _ as c {
      failwith (Printf.sprintf "Unexpected character: %c" c)
    }

and read_string buf = parse
  | '"'           { STRING (Buffer.contents buf) }
  | '\\' 'n'      { Buffer.add_char buf '\n'; read_string buf lexbuf }
  | '\\' 't'      { Buffer.add_char buf '\t'; read_string buf lexbuf }
  | '\\' '"'      { Buffer.add_char buf '"';  read_string buf lexbuf }
  | '\\' '\\'     { Buffer.add_char buf '\\'; read_string buf lexbuf }
  | [^ '"' '\\']+ {
      Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_string buf lexbuf
    }
  | eof           { failwith "Unterminated string literal" }
