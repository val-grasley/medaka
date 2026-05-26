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

(* Strip common leading indentation from a multiline string (one that starts
   with '\n').  Blank lines are ignored when computing the minimum indent. *)
let strip_indent s =
  if String.length s = 0 || s.[0] <> '\n' then s
  else begin
    let rest = String.sub s 1 (String.length s - 1) in
    let lines = String.split_on_char '\n' rest in
    let indent_of line =
      let n = String.length line in
      let i = ref 0 in
      while !i < n && line.[!i] = ' ' do incr i done;
      if !i = n then max_int else !i
    in
    let raw_min = List.fold_left (fun acc l -> min acc (indent_of l)) max_int lines in
    let min_ind = if raw_min = max_int then 0 else raw_min in
    let strip line =
      let n = String.length line in
      let k = min min_ind n in
      String.sub line k (n - k)
    in
    String.concat "\n" (List.map strip lines)
  end

let strip_underscores s =
  String.concat "" (String.split_on_char '_' s)

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
  | "import"    -> IMPORT
  | "export"    -> EXPORT
  | "where"     -> WHERE
  | "of"        -> OF
  | "do"        -> DO
  | "as"        -> AS
  | "extern"    -> EXTERN
  | "requires"  -> REQUIRES
  | "deriving"  -> DERIVING
  | "type"      -> TYPE
  | "newtype"   -> NEWTYPE
  | "True"      -> BOOL true
  | "False"     -> BOOL false
  | _           -> IDENT s
}

let white     = [' ' '\t']
let newline   = '\n' | '\r' '\n'
let digit     = ['0'-'9']
let hex_digit = ['0'-'9' 'a'-'f' 'A'-'F']
let bin_digit = ['0'-'1']
let oct_digit = ['0'-'7']
let lower     = ['a'-'z']
let upper     = ['A'-'Z']
let alnum     = ['a'-'z' 'A'-'Z' '0'-'9' '_' '\'']
let int_lit   = digit (digit | '_')*
let float_lit = digit (digit | '_')* '.' digit (digit | '_')*
let hex_lit   = "0x" hex_digit (hex_digit | '_')*
let bin_lit   = "0b" bin_digit (bin_digit | '_')*
let oct_lit   = "0o" oct_digit (oct_digit | '_')*

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

  | hex_lit      { INT (int_of_string (strip_underscores (Lexing.lexeme lexbuf))) }
  | bin_lit      { INT (int_of_string (strip_underscores (Lexing.lexeme lexbuf))) }
  | oct_lit      { INT (int_of_string (strip_underscores (Lexing.lexeme lexbuf))) }
  | float_lit    { FLOAT (float_of_string (strip_underscores (Lexing.lexeme lexbuf))) }
  | int_lit      { INT (int_of_string (strip_underscores (Lexing.lexeme lexbuf))) }

  | "\"\"\""     { read_triple_string (Buffer.create 64) lexbuf }
  | '"'          { read_string (Buffer.create 64) lexbuf }
  | '\'' [^ '\'']+ '\'' {
      let lxm = Lexing.lexeme lexbuf in
      CHAR (String.sub lxm 1 (String.length lxm - 2))
    }

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
  | "<>"  { STRAPPEND }
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
  | '%'   { MOD }

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
  | '"'           { STRING (strip_indent (Buffer.contents buf)) }
  | '\\' 'n'      { Buffer.add_char buf '\n'; read_string buf lexbuf }
  | '\\' 't'      { Buffer.add_char buf '\t'; read_string buf lexbuf }
  | '\\' '"'      { Buffer.add_char buf '"';  read_string buf lexbuf }
  | '\\' '\\'     { Buffer.add_char buf '\\'; read_string buf lexbuf }
  | '\\' 'r'      { Buffer.add_char buf '\r'; read_string buf lexbuf }
  | '\\' '0'      { Buffer.add_char buf '\000'; read_string buf lexbuf }
  | '\\' 'u' '{' (['0'-'9' 'a'-'f' 'A'-'F']+ as hex) '}'
    { let cp = int_of_string ("0x" ^ hex) in
      Buffer.add_utf_8_uchar buf (Uchar.of_int cp);
      read_string buf lexbuf }
  | [^ '"' '\\']+ {
      Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_string buf lexbuf
    }
  | eof           { failwith "Unterminated string literal" }

and read_triple_string buf = parse
  | "\"\"\""  { STRING (strip_indent (Buffer.contents buf)) }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_triple_string buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_triple_string buf lexbuf }
  | '\\' '"'  { Buffer.add_char buf '"';  read_triple_string buf lexbuf }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_triple_string buf lexbuf }
  | '\\' 'r'  { Buffer.add_char buf '\r'; read_triple_string buf lexbuf }
  | '\\' '0'  { Buffer.add_char buf '\000'; read_triple_string buf lexbuf }
  | '\\' 'u' '{' (['0'-'9' 'a'-'f' 'A'-'F']+ as hex) '}'
    { let cp = int_of_string ("0x" ^ hex) in
      Buffer.add_utf_8_uchar buf (Uchar.of_int cp);
      read_triple_string buf lexbuf }
  | '\n'
    { Lexing.new_line lexbuf;
      Buffer.add_char buf '\n';
      read_triple_string buf lexbuf }
  | '"' '"'   { Buffer.add_string buf "\"\""; read_triple_string buf lexbuf }
  | '"'       { Buffer.add_char  buf '"';    read_triple_string buf lexbuf }
  | [^ '"' '\\' '\n']+
    { Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_triple_string buf lexbuf }
  | eof       { failwith "Unterminated triple-quoted string" }
