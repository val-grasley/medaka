{
open Parser

(* Indentation state *)
let indent_stack : int list ref = ref [0]
let pending : token Queue.t = Queue.create ()

(* Paren-grouping depth.  Incremented on `(`, `[`, `{`, `[|` and
   decremented on the matching close tokens.  While > 0, the
   indentation-driven tokens (NEWLINE, INDENT, DEDENT) are
   suppressed so multi-line expressions inside groupers like
   `(1, \n  2)`, `[1, \n  2]`, `P { x = 1, \n y = 2 }` parse
   regardless of how the line is broken. *)
let paren_depth : int ref = ref 0

(* String interpolation state *)
let interp_depth     : int ref  = ref 0
let interp_buf       : Buffer.t = Buffer.create 64
(* true when the active interpolation started inside a triple-quoted string *)
let interp_in_triple : bool ref = ref false

(* Comment side channel.  Lexer drops `--` line comments from the token
   stream (parser stays untouched) but records them here so tools such as
   `medaka fmt` can re-emit them at faithful positions. *)
type comment = {
  c_line : int;          (* 1-based start line *)
  c_col  : int;          (* 0-based start column *)
  c_text : string;       (* full lexeme including the `--` prefix *)
}
let comments : comment list ref = ref []

let record_comment lexbuf =
  let sp = lexbuf.Lexing.lex_start_p in
  let text = Lexing.lexeme lexbuf in
  comments := { c_line = sp.Lexing.pos_lnum;
                c_col  = sp.Lexing.pos_cnum - sp.Lexing.pos_bol;
                c_text = text } :: !comments

(* Block comments span several tokens, so the start position must be captured
   at the `{-` opener rather than derived from [lex_start_p] (which would point
   at the closing `-}`). *)
let record_comment_at line col text =
  comments := { c_line = line; c_col = col; c_text = text } :: !comments

let take_comments () = List.rev !comments


let push_pending t = Queue.push t pending

let handle_indent col =
  (* When inside `(...)`/`[...]`/`{...}`, ignore indentation changes
     — the grouping characters carry the structure, not whitespace. *)
  if !paren_depth > 0 then ()
  else
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
  Queue.clear pending;
  paren_depth := 0;
  interp_depth := 0;
  interp_in_triple := false;
  Buffer.clear interp_buf;
  comments := [];
  Parser_state.reset ()

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

let parse_int s =
  match int_of_string_opt s with
  | Some n -> n
  | None ->
    failwith (Printf.sprintf
      "integer literal '%s' overflows OCaml int \
       (max = 4611686018427387903 on this platform)" s)

let keyword_or_ident s =
  match s with
  | "let"       -> LET
  | "rec"       -> REC
  | "with"      -> WITH
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
  | "public"    -> PUBLIC
  | "where"     -> WHERE
  | "of"        -> OF
  | "do"        -> DO
  | "as"        -> AS
  | "extern"    -> EXTERN
  | "requires"  -> REQUIRES
  | "deriving"  -> DERIVING
  | "type"      -> TYPE
  | "newtype"   -> NEWTYPE
  | "prop"      -> PROP
  | "bench"     -> BENCH
  | "function"  -> FUNCTION
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
  | "--" [^ '\n']* { record_comment lexbuf; read lexbuf }
  | "{-" {
      let sp   = lexbuf.Lexing.lex_start_p in
      let line = sp.Lexing.pos_lnum in
      let col  = sp.Lexing.pos_cnum - sp.Lexing.pos_bol in
      let buf  = Buffer.create 64 in
      Buffer.add_string buf "{-";
      read_block_comment buf 1 line col lexbuf;
      read lexbuf
    }
  | (newline white*)+ {
      (* Consume one or more (newline + optional indent) sequences so that
         blank lines inside a block do not trigger spurious DEDENT tokens.
         Only the indent of the final non-blank line is used for INDENT/DEDENT. *)
      let s = Lexing.lexeme lexbuf in
      let n = String.length s in
      let indent = ref 0 in
      let i = ref 0 in
      while !i < n do
        if s.[!i] = '\r' && !i + 1 < n && s.[!i + 1] = '\n' then begin
          Lexing.new_line lexbuf;
          indent := 0;
          i := !i + 2
        end else if s.[!i] = '\n' then begin
          Lexing.new_line lexbuf;
          indent := 0;
          incr i
        end else begin
          (match s.[!i] with
           | ' '  -> incr indent
           | '\t' -> indent := (!indent / 8 + 1) * 8
           | _    -> ());
          incr i
        end
      done;
      handle_indent !indent;
      token lexbuf
    }

  | hex_lit      { INT (parse_int (strip_underscores (Lexing.lexeme lexbuf))) }
  | bin_lit      { INT (parse_int (strip_underscores (Lexing.lexeme lexbuf))) }
  | oct_lit      { INT (parse_int (strip_underscores (Lexing.lexeme lexbuf))) }
  | float_lit    { FLOAT (float_of_string (strip_underscores (Lexing.lexeme lexbuf))) }
  | int_lit      { INT (parse_int (strip_underscores (Lexing.lexeme lexbuf))) }

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
  | "[|"  { incr paren_depth; LARRAY }
  | "|]"  { decr paren_depth; RARRAY }
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
  | "..."  { ELLIPSIS }
  | "..=" { DOTDOT_EQ }
  | ".."  { DOTDOT }
  | '.'   { DOT }
  | '|'   { PIPE }
  | '('   { incr paren_depth; LPAREN }
  | ')'   { decr paren_depth; RPAREN }
  | '['   { incr paren_depth; LBRACKET }
  | ']'   { decr paren_depth; RBRACKET }
  | '{'   {
      if !interp_depth > 0 then incr interp_depth
      else incr paren_depth;
      LBRACE
    }
  | '}'   {
      if !interp_depth > 0 then begin
        decr interp_depth;
        if !interp_depth = 0 then begin
          Buffer.clear interp_buf;
          if !interp_in_triple then
            read_interp_triple_continue interp_buf lexbuf
          else
            read_interp_continue interp_buf lexbuf
        end else
          RBRACE
      end else begin
        decr paren_depth;
        RBRACE
      end
    }
  | '!'   { BANG }
  | '?'   { QUESTION }
  | '%'   { MOD }

  | eof   {
      (* Terminate the final statement even when the file has no trailing
         newline.  Every top-level decl rule ends in `newlines`, so the last
         binding needs a NEWLINE; emit one before unwinding the indent stack,
         mirroring the dedent path in [handle_indent] (leading NEWLINE, then
         DEDENT/NEWLINE pairs).  Without it, a file lacking a trailing newline
         runs its last decl straight into EOF and fails to parse.  `newlines`
         collapses runs of NEWLINE, so the well-formed case is unaffected. *)
      push_pending NEWLINE;
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
  | '\\' '{'      { interp_in_triple := false; interp_depth := 1; INTERP_OPEN (Buffer.contents buf) }
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
  | '\\' '{'  { interp_in_triple := true; interp_depth := 1; INTERP_OPEN (Buffer.contents buf) }
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

and read_interp_continue buf = parse
  | '"'       { INTERP_END (Buffer.contents buf) }
  | '\\' '{'  { interp_in_triple := false; interp_depth := 1; INTERP_MID (Buffer.contents buf) }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_interp_continue buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_interp_continue buf lexbuf }
  | '\\' '"'  { Buffer.add_char buf '"';  read_interp_continue buf lexbuf }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_interp_continue buf lexbuf }
  | '\\' 'r'  { Buffer.add_char buf '\r'; read_interp_continue buf lexbuf }
  | '\\' '0'  { Buffer.add_char buf '\000'; read_interp_continue buf lexbuf }
  | '\\' 'u' '{' (['0'-'9' 'a'-'f' 'A'-'F']+ as hex) '}'
    { let cp = int_of_string ("0x" ^ hex) in
      Buffer.add_utf_8_uchar buf (Uchar.of_int cp);
      read_interp_continue buf lexbuf }
  | [^ '"' '\\']+ {
      Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_interp_continue buf lexbuf
    }
  | eof { failwith "Unterminated interpolated string" }

and read_interp_triple_continue buf = parse
  | "\"\"\""  { INTERP_END (strip_indent (Buffer.contents buf)) }
  | '\\' '{'  { interp_in_triple := true; interp_depth := 1; INTERP_MID (Buffer.contents buf) }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_interp_triple_continue buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_interp_triple_continue buf lexbuf }
  | '\\' '"'  { Buffer.add_char buf '"';  read_interp_triple_continue buf lexbuf }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_interp_triple_continue buf lexbuf }
  | '\\' 'r'  { Buffer.add_char buf '\r'; read_interp_triple_continue buf lexbuf }
  | '\\' '0'  { Buffer.add_char buf '\000'; read_interp_triple_continue buf lexbuf }
  | '\\' 'u' '{' (['0'-'9' 'a'-'f' 'A'-'F']+ as hex) '}'
    { let cp = int_of_string ("0x" ^ hex) in
      Buffer.add_utf_8_uchar buf (Uchar.of_int cp);
      read_interp_triple_continue buf lexbuf }
  | '\n'
    { Lexing.new_line lexbuf;
      Buffer.add_char buf '\n';
      read_interp_triple_continue buf lexbuf }
  | '"' '"'   { Buffer.add_string buf "\"\""; read_interp_triple_continue buf lexbuf }
  | '"'       { Buffer.add_char  buf '"';    read_interp_triple_continue buf lexbuf }
  | [^ '"' '\\' '\n']+
    { Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_interp_triple_continue buf lexbuf }
  | eof { failwith "Unterminated interpolated triple-quoted string" }

(* Haskell-style nested block comment.  `depth` tracks `{-`/`-}` nesting;
   `line`/`col` are the opener position carried through for the side channel. *)
and read_block_comment buf depth line col = parse
  | "{-"  { Buffer.add_string buf "{-"; read_block_comment buf (depth + 1) line col lexbuf }
  | "-}"  { Buffer.add_string buf "-}";
            if depth = 1 then record_comment_at line col (Buffer.contents buf)
            else read_block_comment buf (depth - 1) line col lexbuf }
  | '\n'  { Lexing.new_line lexbuf; Buffer.add_char buf '\n';
            read_block_comment buf depth line col lexbuf }
  | [^ '{' '-' '\n']+ { Buffer.add_string buf (Lexing.lexeme lexbuf);
                        read_block_comment buf depth line col lexbuf }
  | _ as c { Buffer.add_char buf c; read_block_comment buf depth line col lexbuf }
  | eof   { failwith "Unterminated block comment" }
