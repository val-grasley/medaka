{
open Parser

(* Indentation state *)
let indent_stack : int list ref = ref [0]
let pending : token Queue.t = Queue.create ()

(* One-token lookahead buffer for the `else`-continuation filter (see [token]
   at the bottom of the file).  Stores the buffered token together with its
   source positions so they can be restored when it is finally returned. *)
let look : (token * Lexing.position * Lexing.position) option ref = ref None

(* Absolute end offset of the most recently lexed IDENT.  Used to make `@`
   adjacency-sensitive: an `@` whose start offset equals this (i.e. it
   immediately follows an identifier with no intervening space/comment) is the
   as-pattern operator (`x@rest`); otherwise it is the impl-hint prefix
   (`fn @Impl`).  -1 = no preceding identifier. *)
let last_ident_end : int ref = ref (-1)

(* Paren-grouping depth.  Incremented on `(`, `[`, `{`, `[|` and
   decremented on the matching close tokens.  While > 0, the
   indentation-driven tokens (NEWLINE, INDENT, DEDENT) are
   suppressed so multi-line expressions inside groupers like
   `(1, \n  2)`, `[1, \n  2]`, `P { x = 1, \n y = 2 }` parse
   regardless of how the line is broken. *)
let paren_depth : int ref = ref 0

(* ── Phase 137: expression-RHS continuation lines ──────────────────────────
   A more-indented line may continue an unfinished application instead of
   starting a new statement:

     parseCmp = chainl1 parseCons
       (choice [...])            -- continues `chainl1 parseCons`

   The lexer normally emits an INDENT for such a line, which the grammar only
   accepts where a *block* is expected, so the line was a parse error.  We now
   suppress that INDENT (leaving the indent stack at the statement's base
   column, exactly like the leading-operator rule) when it is a continuation
   rather than a block.

   [prev_significant] is the last non-layout token emitted.  An INDENT opens a
   block iff (a) it follows the `match`/`record` header — the only two openers
   whose INDENT is preceded by an expression atom (handled by the one-shot
   flags below), or (b) the previous token cannot end an expression (`=`,
   `then`, `=>`, `where`, `do`, … — these introduce every other block).  When
   neither holds the INDENT is a candidate continuation; the final decision
   needs the deeper line's first token, so it is deferred via [pending_indent]
   and resolved in [token] (see [resolve_pending]). *)
let prev_significant : token option ref = ref None
let match_pending    : bool ref = ref false
let record_pending   : bool ref = ref false
let pending_indent   : int option ref = ref None

(* Whether [t] can syntactically *end* an expression (an atom-ender).  A
   whitelist: a token absent here defaults to "blocks continuation", the safe
   direction (a new token will not silently start rescuing layouts). *)
let can_end_expr = function
  | IDENT _ | UPPER _ | INT _ | FLOAT _ | STRING _ | CHAR _ | BOOL _
  | INTERP_END _ | RPAREN | RBRACKET | RBRACE | RARRAY | UNDERSCORE
  | QUESTION -> true
  | _ -> false

(* Whether [t] can *start* an application-argument atom (the first token of
   `expr_aspat` in parser.mly).  A deeper line beginning with one of these
   continues the previous application; anything else (`|` guards, `where`,
   `data`'s `=`, a leading operator, …) is left to open its own block. *)
let can_start_atom = function
  | INT _ | FLOAT _ | STRING _ | CHAR _ | BOOL _
  | IDENT _ | UPPER _ | UNDERSCORE
  | LPAREN | LBRACKET | LARRAY | LBRACE | AT | INTERP_OPEN _ -> true
  | _ -> false

(* String interpolation state *)
let interp_depth     : int ref  = ref 0
let interp_buf       : Buffer.t = Buffer.create 64
(* true when the active interpolation started inside a triple-quoted string *)
let interp_in_triple : bool ref = ref false

(* True once the current string literal's first content character was a *raw*
   source newline (not an escaped `\n`).  Multiline indent-stripping fires only
   for raw-newline-led literals, so `"\n"` stays a one-char newline and
   `"\n  foo"` keeps its spaces, while a literal written across source lines is
   still dedented.  Reset at every opening quote (see [token]). *)
let string_raw_leading_nl : bool ref = ref false

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
  else begin
    (* The match/record header (if any) is now complete; snapshot and clear the
       one-shots so the *next* indent decides afresh. *)
    let was_block_opener = !match_pending || !record_pending in
    match_pending := false;
    record_pending := false;
    let current = List.hd !indent_stack in
    if col > current then begin
      let opens_block =
        was_block_opener
        || not (match !prev_significant with
                | Some t -> can_end_expr t
                | None -> false)
      in
      if opens_block then begin
        indent_stack := col :: !indent_stack;
        push_pending INDENT
      end else
        (* Candidate continuation: resolved in [token] once the deeper line's
           first token is known.  The indent stack is left untouched. *)
        pending_indent := Some col
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
  end

(* After matching a multi-line lexeme [s] whose match ends at the current
   position, fix up pos_lnum/pos_bol so column reporting on the lexeme's final
   line stays correct.  ocamllex advances pos_cnum automatically but leaves
   line/bol to the lexer, so a rule that swallows newlines (the leading-operator
   continuation rule below) must call this or downstream locations drift. *)
let advance_over lexbuf s =
  let p = lexbuf.Lexing.lex_curr_p in
  let start_cnum = p.Lexing.pos_cnum - String.length s in
  let nls = ref 0 and last_nl = ref (-1) in
  String.iteri (fun i c -> if c = '\n' then (incr nls; last_nl := i)) s;
  if !nls > 0 then
    lexbuf.Lexing.lex_curr_p <-
      { p with
        Lexing.pos_lnum = p.Lexing.pos_lnum + !nls;
        Lexing.pos_bol  = start_cnum + !last_nl + 1 }

let reset () =
  indent_stack := [0];
  Queue.clear pending;
  look := None;
  last_ident_end := -1;
  paren_depth := 0;
  prev_significant := None;
  match_pending := false;
  record_pending := false;
  pending_indent := None;
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
  | "test"      -> TEST
  | "bench"     -> BENCH
  | "function"  -> FUNCTION
  | "True"      -> BOOL true
  | "False"     -> BOOL false
  | _           -> IDENT s

(* Return the token, and if it is an IDENT record its end offset so a directly
   adjacent `@` lexes as the as-pattern operator (see `last_ident_end`). *)
let record_ident lexbuf t =
  (match t with IDENT _ -> last_ident_end := Lexing.lexeme_end lexbuf | _ -> ());
  t
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

rule raw_token = parse
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
  | (newline white*)+ (("|>" | ">>" | "<<" | "&&" | "||" | "++" | "<>") as op) {
      (* Leading-operator line continuation: a line break immediately before one
         of these infix operators is *not* a statement boundary — the operator
         continues the previous expression.  We emit the operator token directly
         and skip all layout (no NEWLINE/INDENT/DEDENT, indent_stack untouched),
         exactly as if the break had happened inside parentheses.

         Safe because every operator here is infix-only: none can legally begin a
         declaration or statement, so any program that parsed before still parses
         identically — we only rescue layouts that were previously parse errors.
         `|` is deliberately excluded (it opens guard arms / data variants).

         A comment physically between the operand and the operator defeats this
         (the newline run stops at the comment); that case was already a parse
         error, so it stays one. *)
      advance_over lexbuf (Lexing.lexeme lexbuf);
      (match op with
       | "|>" -> PIPE_RIGHT
       | ">>" -> RCOMPOSE
       | "<<" -> LCOMPOSE
       | "&&" -> AND
       | "||" -> OR
       | "++" -> PLUSPLUS
       | "<>" -> STRAPPEND
       | _    -> assert false)
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
      raw_token lexbuf
    }

  | hex_lit      { INT (parse_int (strip_underscores (Lexing.lexeme lexbuf))) }
  | bin_lit      { INT (parse_int (strip_underscores (Lexing.lexeme lexbuf))) }
  | oct_lit      { INT (parse_int (strip_underscores (Lexing.lexeme lexbuf))) }
  | float_lit    { FLOAT (float_of_string (strip_underscores (Lexing.lexeme lexbuf))) }
  | int_lit      { INT (parse_int (strip_underscores (Lexing.lexeme lexbuf))) }

  | "\"\"\""     { string_raw_leading_nl := false; read_triple_string (Buffer.create 64) lexbuf }
  | '"'          { string_raw_leading_nl := false; read_string (Buffer.create 64) lexbuf }
  | '\''  { read_char lexbuf }

  (* Identifiers — order matters: longer matches win, ties go to earlier rule *)
  | lower alnum*           { record_ident lexbuf (keyword_or_ident (Lexing.lexeme lexbuf)) }
  | '_' alnum+             { record_ident lexbuf (keyword_or_ident (Lexing.lexeme lexbuf)) }
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
  | ".{"  { incr paren_depth; DOT_LBRACE }
  | ".*"  { DOT_STAR }
  | "@"   { if Lexing.lexeme_start lexbuf = !last_ident_end then AS_AT else AT }

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
      raw_token lexbuf
    }

  | _ as c {
      failwith (Printf.sprintf "Unexpected character: %c" c)
    }

and read_string buf = parse
  (* Dedent only when the literal *opened* with a raw source newline; an escaped
     `\n` must survive verbatim.  Pre-fix [strip_indent] keyed on the first byte
     being '\n', conflating the two, so `"\n"` collapsed to `""`. *)
  | '"'           { let s = Buffer.contents buf in
                    STRING (if !string_raw_leading_nl then strip_indent s else s) }
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
      let lx = Lexing.lexeme lexbuf in
      if Buffer.length buf = 0 && lx.[0] = '\n' then string_raw_leading_nl := true;
      Buffer.add_string buf lx;
      read_string buf lexbuf
    }
  | eof           { failwith "Unterminated string literal" }

and read_triple_string buf = parse
  | "\"\"\""  { let s = Buffer.contents buf in
                STRING (if !string_raw_leading_nl then strip_indent s else s) }
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
      if Buffer.length buf = 0 then string_raw_leading_nl := true;
      Buffer.add_char buf '\n';
      read_triple_string buf lexbuf }
  | '"' '"'   { Buffer.add_string buf "\"\""; read_triple_string buf lexbuf }
  | '"'       { Buffer.add_char  buf '"';    read_triple_string buf lexbuf }
  | [^ '"' '\\' '\n']+
    { Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_triple_string buf lexbuf }
  | eof       { failwith "Unterminated triple-quoted string" }

and read_char = parse
  | '\\' '\'' '\''  { CHAR "'" }
  | '\\' '\\' '\''  { CHAR "\\" }
  | '\\' 'n'  '\''  { CHAR "\n" }
  | '\\' 't'  '\''  { CHAR "\t" }
  | '\\' 'r'  '\''  { CHAR "\r" }
  | '\\' '0'  '\''  { CHAR "\000" }
  | '\\' 'u' '{' (['0'-'9' 'a'-'f' 'A'-'F']+ as hex) '}' '\''
      { let cp = int_of_string ("0x" ^ hex) in
        let b = Buffer.create 4 in
        Buffer.add_utf_8_uchar b (Uchar.of_int cp);
        CHAR (Buffer.contents b) }
  | [^ '\'' '\\']+ '\''
      { let lx = Lexing.lexeme lexbuf in
        CHAR (String.sub lx 0 (String.length lx - 1)) }
  | '\''  { failwith "Empty char literal ''" }
  | eof   { failwith "Unterminated char literal" }
  | _     { failwith "Malformed char literal" }

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

{
(* Phase 122: `else`-continuation filter.  The indentation lexer emits a layout
   NEWLINE before an `else` that begins a line (and a DEDENT first if the `then`
   branch was an indented block).  That NEWLINE is indistinguishable, at LR(1),
   from a statement-terminating NEWLINE — which is exactly what blocks an
   else-less `if` (the parser cannot tell `if c then e <NL> else …` from
   `if c then e <NL> nextStmt`).  We resolve it here, upstream of the grammar:
   drop any NEWLINE token that is immediately followed by ELSE (keeping the
   DEDENT).  With that, no grammar rule ever sees `newlines ELSE`, so a NEWLINE
   after a `then` branch unambiguously means "else-less, reduce".

   Source positions are preserved: the byte offsets ocamllex scans by are never
   touched, only the [Lexing.position] *records*, which we save per raw token
   and restore so menhir reads each returned token's true position. *)
(* Record the last non-layout token the parser actually received, and arm the
   one-shot flags on a `match`/`record` header (Phase 137). *)
let note (t : token) : token =
  (match t with
   | NEWLINE | INDENT | DEDENT -> ()
   | MATCH  -> match_pending := true;  prev_significant := Some t
   | RECORD -> record_pending := true; prev_significant := Some t
   | _      -> prev_significant := Some t);
  t

let rec token (lexbuf : Lexing.lexbuf) : token =
  match !look with
  | Some (t, sp, ep) ->
    look := None;
    lexbuf.Lexing.lex_start_p <- sp;
    lexbuf.Lexing.lex_curr_p  <- ep;
    note t
  | None ->
    let t = raw_token lexbuf in
    (match !pending_indent with
     | Some col -> resolve_pending col t lexbuf
     | None     -> filter_newline t lexbuf)

(* Resolve a deferred would-be INDENT (Phase 137) now that [t] — the deeper
   line's first token — is known.  An atom-starter continues the previous
   expression (swallow the indent); a layout boundary (NEWLINE/EOF: the deeper
   run was trailing whitespace) drops it; anything else really does open a
   block (guards, block-`where`, `data`'s `=`, a leading operator, …) so the
   INDENT is committed and [t] replayed. *)
and resolve_pending col t lexbuf =
  pending_indent := None;
  if can_start_atom t then
    note t
  else if t = NEWLINE || t = EOF then
    filter_newline t lexbuf
  else begin
    let sp = lexbuf.Lexing.lex_start_p and ep = lexbuf.Lexing.lex_curr_p in
    indent_stack := col :: !indent_stack;
    look := Some (t, sp, ep);
    (* zero-width INDENT positioned just before [t] *)
    lexbuf.Lexing.lex_curr_p <- sp;
    INDENT
  end

(* Phase 122 `else`-continuation filter: drop a layout NEWLINE immediately
   before ELSE (keeping any DEDENT), so the grammar never sees `newlines ELSE`. *)
and filter_newline t lexbuf =
  if t <> NEWLINE then note t
  else begin
    let nl_sp = lexbuf.Lexing.lex_start_p and nl_ep = lexbuf.Lexing.lex_curr_p in
    let next = raw_token lexbuf in
    if next = ELSE then note next       (* drop the NEWLINE; ELSE positions are current *)
    else begin
      (* keep the NEWLINE; buffer `next` with its positions; restore the
         NEWLINE's positions for this return *)
      look := Some (next, lexbuf.Lexing.lex_start_p, lexbuf.Lexing.lex_curr_p);
      lexbuf.Lexing.lex_start_p <- nl_sp;
      lexbuf.Lexing.lex_curr_p  <- nl_ep;
      t
    end
  end

(* ── Phase 131: token-stream dump for the differential-testing harness ───
   Renders each [Parser.token] to a stable string and produces the full token
   stream for a source string.  The match is intentionally exhaustive (no
   wildcard) so adding a grammar token surfaces a non-exhaustive-match warning
   here. *)
let token_to_string : token -> string = function
  (* Literals *)
  | INT n            -> Printf.sprintf "INT %d" n
  | FLOAT f          -> Printf.sprintf "FLOAT %g" f
  | STRING s         -> Printf.sprintf "STRING %S" s
  | CHAR s           -> Printf.sprintf "CHAR %S" s
  | BOOL b           -> Printf.sprintf "BOOL %b" b
  (* String interpolation *)
  | INTERP_OPEN s    -> Printf.sprintf "INTERP_OPEN %S" s
  | INTERP_MID s     -> Printf.sprintf "INTERP_MID %S" s
  | INTERP_END s     -> Printf.sprintf "INTERP_END %S" s
  (* Identifiers *)
  | IDENT s          -> Printf.sprintf "IDENT %S" s
  | UPPER s          -> Printf.sprintf "UPPER %S" s
  | BACKTICK_IDENT s -> Printf.sprintf "BACKTICK_IDENT %S" s
  (* Keywords *)
  | LET -> "LET" | REC -> "REC" | WITH -> "WITH" | MUT -> "MUT" | IN -> "IN"
  | IF -> "IF" | THEN -> "THEN" | ELSE -> "ELSE" | MATCH -> "MATCH"
  | DATA -> "DATA" | RECORD -> "RECORD" | INTERFACE -> "INTERFACE"
  | DEFAULT -> "DEFAULT" | IMPL -> "IMPL" | IMPORT -> "IMPORT"
  | EXPORT -> "EXPORT" | PUBLIC -> "PUBLIC" | WHERE -> "WHERE" | OF -> "OF"
  | REQUIRES -> "REQUIRES" | DO -> "DO" | AS -> "AS" | EXTERN -> "EXTERN"
  | DERIVING -> "DERIVING" | TYPE -> "TYPE" | NEWTYPE -> "NEWTYPE"
  | PROP -> "PROP" | TEST -> "TEST" | BENCH -> "BENCH" | FUNCTION -> "FUNCTION"
  (* Operators *)
  | PLUS -> "PLUS" | MINUS -> "MINUS" | STAR -> "STAR" | SLASH -> "SLASH"
  | MOD -> "MOD" | EQ_EQ -> "EQ_EQ" | NEQ -> "NEQ" | LT -> "LT" | GT -> "GT"
  | LEQ -> "LEQ" | GEQ -> "GEQ" | AND -> "AND" | OR -> "OR" | CONS -> "CONS"
  | PLUSPLUS -> "PLUSPLUS" | STRAPPEND -> "STRAPPEND"
  | PIPE_RIGHT -> "PIPE_RIGHT" | RCOMPOSE -> "RCOMPOSE" | LCOMPOSE -> "LCOMPOSE"
  | FAT_ARROW -> "FAT_ARROW" | ARROW -> "ARROW" | LARROW -> "LARROW"
  | AT -> "AT" | BANG -> "BANG" | QUESTION -> "QUESTION" | AS_AT -> "AS_AT"
  (* Punctuation *)
  | EQUAL -> "EQUAL" | COLON -> "COLON" | COMMA -> "COMMA" | DOT -> "DOT"
  | PIPE -> "PIPE" | UNDERSCORE -> "UNDERSCORE" | LPAREN -> "LPAREN"
  | RPAREN -> "RPAREN" | LBRACKET -> "LBRACKET" | RBRACKET -> "RBRACKET"
  | LBRACE -> "LBRACE" | RBRACE -> "RBRACE" | LARRAY -> "LARRAY"
  | RARRAY -> "RARRAY" | DOT_LBRACE -> "DOT_LBRACE" | DOT_STAR -> "DOT_STAR"
  | ELLIPSIS -> "ELLIPSIS" | DOTDOT -> "DOTDOT" | DOTDOT_EQ -> "DOTDOT_EQ"
  (* Indentation + EOF *)
  | NEWLINE -> "NEWLINE" | INDENT -> "INDENT" | DEDENT -> "DEDENT"
  | EOF -> "EOF"

let tokenize_string (src : string) : string list =
  reset ();
  let lb = Lexing.from_string src in
  let acc = ref [] in
  let rec loop () =
    let t = token lb in
    acc := token_to_string t :: !acc;
    if t <> EOF then loop ()
  in
  loop ();
  List.rev !acc
}
