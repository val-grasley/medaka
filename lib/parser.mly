%{
open Ast

let of_pos p =
  { file = p.Lexing.pos_fname;
    line = p.Lexing.pos_lnum;
    col  = p.Lexing.pos_cnum - p.Lexing.pos_bol }

let fold_ty_app = function
  | []      -> failwith "empty type application"
  | [t]     -> t
  | t :: ts -> List.fold_left (fun acc a -> TyApp (acc, a)) t ts

type kv_item = KV of expr * expr | Elem of expr | Field of string * expr

let stmts_to_expr = function
  | [DoExpr e] -> e
  | stmts      -> EDo stmts

(* Desugar `let f x y = body` to `let f = (x => y => body)`. *)
let curry_lam pats body =
  List.fold_right (fun pat acc -> ELam ([pat], acc)) pats body

(* Desugar `where` bindings into nested ELet expressions. *)
let desugar_where bindings main_expr =
  List.fold_right
    (fun (name, pats, rhs) acc ->
      ELet (false, PVar name, curry_lam pats rhs, acc))
    bindings main_expr

(* Convert an expression back into a pattern when used as a lambda parameter.
   Supported: identifiers, literals, tuples, lists, cons, constructor apps. *)
let rec expr_to_pat = function
  | ELoc (_, e)  -> expr_to_pat e
  | EVar x when x = "_" -> PWild  (* shouldn't normally reach here; UNDERSCORE has its own rule *)
  | EVar x       -> PVar x
  | ELit l       -> PLit l
  | ETuple es    -> PTuple (List.map expr_to_pat es)
  | EListLit es  -> PList  (List.map expr_to_pat es)
  | EBinOp ("::", a, b) -> PCons (expr_to_pat a, expr_to_pat b)
  | EApp _ as e ->
    (* Constructor application: collect head + args, head must be uppercase *)
    let rec collect acc = function
      | EApp (f, a) -> collect (a :: acc) f
      | EVar c when String.length c > 0
                  && Char.uppercase_ascii c.[0] = c.[0] ->
        PCon (c, List.map expr_to_pat acc)
      | _ -> failwith "Invalid lambda parameter pattern"
    in
    collect [] e
  | _ -> failwith "Invalid lambda parameter pattern"

(* Desugar top-level guard arms into a nested if-then-else chain.
   A missing catch-all panics at runtime, matching Haskell's behaviour. *)
let desugar_guards arms =
  List.fold_right
    (fun (cond, body) else_ -> EIf (cond, body, else_))
    arms
    (EApp (EVar "panic", ELit (LString "Non-exhaustive guards")))

(* Interpret a ty_fun as a constraint-list prefix in `ty_fun FAT_ARROW ty`.
   TyApp(TyCon iface, arg) → single constraint; TyTuple → multiple constraints. *)
let desugar_constraint lhs rhs =
  let rec extract = function
    | TyApp (TyCon iface, arg) -> [(iface, [arg])]
    | TyCon iface              -> [(iface, [])]
    | TyTuple cs               -> List.concat_map extract cs
    | t -> failwith ("invalid constraint syntax: " ^ Ast.pp_ty t)
  in
  TyConstrained (extract lhs, rhs)
%}

(* Literals *)
%token <int>    INT
%token <float>  FLOAT
%token <string> STRING
%token <string> CHAR
%token <bool>   BOOL

(* Identifiers *)
%token <string> IDENT
%token <string> UPPER
%token <string> BACKTICK_IDENT

(* Keywords *)
%token LET MUT IN IF THEN ELSE MATCH DATA RECORD INTERFACE DEFAULT IMPL
%token IMPORT EXPORT WHERE OF REQUIRES DO AS EXTERN DERIVING TYPE NEWTYPE

(* Operators *)
%token PLUS MINUS STAR SLASH MOD
%token EQ_EQ NEQ LT GT LEQ GEQ
%token AND OR
%token CONS PLUSPLUS STRAPPEND
%token PIPE_RIGHT RCOMPOSE LCOMPOSE
%token FAT_ARROW ARROW LARROW
%token AT BANG

(* Punctuation *)
%token EQUAL COLON COMMA DOT PIPE UNDERSCORE
%token LPAREN RPAREN LBRACKET RBRACKET LBRACE RBRACE
%token LARRAY RARRAY
%token DOT_LBRACE DOT_STAR

(* Indentation *)
%token NEWLINE INDENT DEDENT

%token EOF

%start <Ast.program> program
%start <Ast.expr>    repl_expr

%%

(* ═══════════════════════════════════════════════════════
   Grammar conflicts — audit notes (Phase 7)
   ═══════════════════════════════════════════════════════

   Menhir reports 3 S/R states (12 conflicts) and 7 R/R states (23 conflicts).
   Every conflict is documented below.  All default resolutions are correct for
   the intended semantics — none require restructuring.

   ── Shift/reduce conflicts ──────────────────────────────

   S/R state 108  •  lookahead: LBRACE
     Stack: … EQUAL UPPER
     Reduce: expr_atom → UPPER          (UPPER as a bare constructor reference)
     Shift:  UPPER . LBRACE … RBRACE    (start of a record-creation expression)
     Resolution: SHIFT (default).  Record creation must win.  A bare UPPER
     followed by { is unambiguously a record literal; the atom-reduce path
     would leave { to be the start of a record-update expression, which
     requires { expr | … } and won't parse correctly here anyway.

   S/R state (new, Phase 16)  •  lookahead: EQUAL
     Stack: … UPPER LBRACE IDENT
     Reduce: expr_atom → IDENT    (path toward kv_or_e → expr_no_block or expr_pipe FAT_ARROW …)
     Shift:  IDENT . EQUAL expr   (start of record_field_expr)
     Resolution: SHIFT (default).  Record field wins: `Type { field = value }`
     uses EQUAL and is unambiguous.  If the token after IDENT were FAT_ARROW
     instead, the shift/reduce conflict does not arise (record rule doesn't
     apply), so map keys that start with IDENT parse correctly via the reduce
     path.

   S/R state 138  •  lookaheads: UPPER STRING RPAREN RBRACKET LPAREN
                                  LBRACKET LBRACE INT IDENT FLOAT CONS
                                  COMMA CHAR BOOL   (14 tokens)
     Stack: … INDENT UPPER
     Explanation concentrates on UPPER:
     Reduce: expr_atom → UPPER          (first token of a DoExpr statement)
     Shift:  UPPER . nonempty_list(pat_atom)  (constructor pattern in DoBind)
     Resolution: SHIFT (default).  Attempting DoBind first is correct — if
     `<-` does not follow, the parse will fail with a helpful error.  The
     practical consequence (documented in PLAN.md §Phase 2) is that a DoExpr
     whose first token is `UPPER` followed by an atom-like token must be
     written with parens, e.g. `pure (Some 5)` instead of `Some 5`.
     The other 13 tokens for this state fall under the R/R analysis below.

   ── Reduce/reduce conflicts ─────────────────────────────

   States 138, 141, 143, 144, 147, 235  •  lookaheads: CONS COMMA RPAREN RBRACKET
     These states share the same root cause: inside a `do` block the parser
     has seen a single atom (UPPER / IDENT / lit / `()` / `[]`) and now sees
     a token that could continue either a pattern (DoBind) or an expression
     (DoExpr).  Two reductions are possible for each atom:

       expr_atom → UPPER  |  pat_atom → UPPER   (state 138)
       expr_atom → IDENT  |  pat_atom → IDENT   (states 144, 235)
       expr_atom → lit    |  pat_atom → lit      (state 147)
       expr_atom → ()     |  pat_atom → ()       (state 141)
       expr_atom → []     |  pat_atom → []       (state 143)

     Resolution: REDUCE expr_atom (default: earliest rule in the file).
     Choosing expr_atom is correct for the common case: the `stmt` rule
     tries `pat LARROW` first (state 138 S/R above), so by the time we reach
     one of these states the parser has already committed to reading the atom
     as part of an expression.  The practical limitation: a DoBind whose LHS
     is a cons pattern (`x :: xs <- list`) or a literal pattern (`42 <- xs`)
     will fail to parse because the atom is reduced as expr_atom before the
     `::` / `<-` is seen.  These patterns are unusual enough that the
     restriction is acceptable; fixing it would require an `expr_to_pat`
     pass on the entire `stmt` LHS (analogous to the lambda trick), which
     is deferred to a future grammar pass.

   State 317  •  lookaheads: RBRACE COMMA COLON   (Phase 16 — kv_or_e)
     Stack: … UPPER LBRACE expr_pipe FAT_ARROW expr_lam
     Context: inside `UPPER { kv_or_e, … }` after parsing `expr_pipe => expr_lam`.
     Two reductions are possible for the trailing expr_lam:
       expr_annot → expr_lam          (path A: complete the RHS of kv_or_e → expr_pipe FAT_ARROW expr_no_block)
       expr_lam → expr_pipe FAT_ARROW expr_lam   (path B: treat the whole thing as a lambda, part of kv_or_e → expr_no_block)
     Resolution: REDUCE expr_annot → expr_lam (default: earlier production).
     Path A is correct — it produces KV("a", 1) for `Map { "a" => 1 }`.
     Path B would produce a lambda-valued set element, which is semantically
     wrong and would type-check as a Set of function values.
   ═══════════════════════════════════════════════════════ *)

(* ── Top level ───────────────────────────────────────── *)

program:
  | option(newlines) decl_list EOF  { $2 }

repl_expr:
  | option(newlines) expr_no_block option(newlines) EOF  { $2 }

decl_list:
  |                  { [] }
  | decl decl_list   { $1 @ $2 }

decl:
  | EXPORT newlines inner_decl_body  { [$3 true]  }
  | EXPORT inner_decl_body           { [$2 true]  }
  | inner_decl_body                  { [$1 false] }
  | EXPORT IMPORT import_path newlines  { [DUse (true,  $3)] }
  | IMPORT import_path newlines         { [DUse (false, $2)] }

inner_decl_body:
  | inner_type_sig        { $1 }
  | inner_fun_def         { $1 }
  | inner_data_decl       { $1 }
  | inner_record_decl     { $1 }
  | inner_type_alias_decl   { $1 }
  | inner_type_newtype_decl { $1 }
  | inner_iface_decl        { $1 }
  | inner_impl_decl       { $1 }
  | inner_extern_decl     { $1 }

(* ── Extern declarations ─────────────────────────────── *)

inner_extern_decl:
  | EXTERN IDENT COLON ty newlines
    { fun is_pub -> DExtern (is_pub, $2, $4) }
  | EXTERN UPPER COLON ty newlines
    { fun is_pub -> DExtern (is_pub, $2, $4) }

(* ── Type signatures ─────────────────────────────────── *)

inner_type_sig:
  | IDENT COLON ty newlines
    { fun is_pub -> DTypeSig (is_pub, $1, $3) }

(* ── Function definitions ────────────────────────────── *)

inner_fun_def:
  | IDENT list(pat_atom) EQUAL fun_body newlines
    { fun is_pub -> DFunDef (is_pub, $1, $2, $4) }
  | IDENT list(pat_atom) INDENT nonempty_list(guard_arm) DEDENT newlines
    { fun is_pub -> DFunDef (is_pub, $1, $2, desugar_guards $4) }

guard_arm:
  | PIPE expr_or EQUAL fun_body newlines  { ($2, $4) }

fun_body:
  | expr_no_block                                                    { $1 }
  | expr_no_block WHERE INDENT nonempty_list(where_binding) DEDENT   { desugar_where $4 $1 }
  | INDENT nonempty_list(stmt) DEDENT                                { stmts_to_expr $2 }

where_binding:
  | IDENT list(pat_atom) EQUAL fun_body newlines  { ($1, $2, $4) }

(* ── Types ───────────────────────────────────────────── *)

ty:
  | ty_fun FAT_ARROW ty  { desugar_constraint $1 $3 }
  | ty_fun               { $1 }

ty_fun:
  | ty_app ARROW ty_fun  { TyFun ($1, $3) }
  | ty_app               { $1 }

ty_app:
  | nonempty_list(ty_atom)  { fold_ty_app $1 }

ty_atom:
  | UPPER                                   { TyCon $1 }
  | IDENT                                   { TyVar $1 }
  | LPAREN ty RPAREN                        { $2 }
  | LPAREN ty COMMA separated_nonempty_list(COMMA, ty) RPAREN
    { TyTuple ($2 :: $4) }
  | LT separated_nonempty_list(COMMA, UPPER) GT ty_atom
    { TyEffect ($2, $4) }

(* ── Patterns ────────────────────────────────────────── *)

pat:
  | pat_as  { $1 }

pat_as:
  | IDENT AT pat_cons  { PAs ($1, $3) }
  | pat_cons           { $1 }

pat_cons:
  | pat_app CONS pat_cons   { PCons ($1, $3) }
  | pat_app                 { $1 }

(* A constructor application without surrounding parens.
   Allowed wherever a full `pat` is expected (match arms, let bindings,
   do binds, etc.); function arguments still use `pat_atom` and so
   require parens for constructor patterns with args. *)
pat_app:
  | UPPER nonempty_list(pat_atom)  { PCon ($1, $2) }
  | pat_atom                       { $1 }

pat_atom:
  | IDENT                                                  { PVar $1 }
  | UNDERSCORE                                             { PWild }
  | UPPER                                                  { PCon ($1, []) }
  | lit                                                    { PLit $1 }
  | LPAREN RPAREN                                          { PLit LUnit }
  | LPAREN pat RPAREN                                      { $2 }
  | LPAREN pat COMMA separated_nonempty_list(COMMA, pat) RPAREN
    { PTuple ($2 :: $4) }
  | LBRACKET RBRACKET                                      { PList [] }
  | LBRACKET separated_nonempty_list(COMMA, pat) RBRACKET  { PList $2 }

(* ── Expressions ─────────────────────────────────────── *)

expr_no_block:
  | expr_annot  { $1 }

expr_annot:
  | expr_lam COLON ty  { EAnnot ($1, $3) }
  | expr_lam           { $1 }

(* Lambdas: parse the LHS as an expression, then reinterpret as a pattern when
   FAT_ARROW follows. This avoids the IDENT-vs-IDENT ambiguity with application. *)
expr_lam:
  | LET MUT pat EQUAL expr_no_block IN expr_lam
    { ELoc (of_pos $startpos, ELet (true,  $3, $5, $7)) }
  | LET pat EQUAL expr_no_block IN expr_lam
    { ELoc (of_pos $startpos, ELet (false, $2, $4, $6)) }
  | LET IDENT nonempty_list(pat_atom) EQUAL expr_no_block IN expr_lam
    { ELoc (of_pos $startpos, ELet (false, PVar $2, curry_lam $3 $5, $7)) }
  | IF expr_or THEN expr_lam ELSE expr_lam
    { ELoc (of_pos $startpos, EIf ($2, $4, $6)) }
  | MATCH expr_or INDENT nonempty_list(match_arm) DEDENT
    { ELoc (of_pos $startpos, EMatch ($2, $4)) }
  | DO INDENT nonempty_list(stmt) DEDENT
    { ELoc (of_pos $startpos, EDo $3) }
  | UNDERSCORE FAT_ARROW expr_lam
    { ELoc (of_pos $startpos, ELam ([PWild], $3)) }
  | expr_pipe FAT_ARROW expr_lam
    { ELoc (of_pos $startpos, ELam ([expr_to_pat $1], $3)) }
  | expr_pipe
    { $1 }

(* Pipe: x |> f  ≡  f x   (left-associative, lower than all other operators) *)
expr_pipe:
  | expr_pipe PIPE_RIGHT expr_compose  { EBinOp ("|>", $1, $3) }
  | expr_compose                       { $1 }

(* Composition: f >> g  ≡  fun x -> g (f x)
                f << g  ≡  fun x -> f (g x)  *)
expr_compose:
  | expr_compose RCOMPOSE expr_or  { EBinOp (">>", $1, $3) }
  | expr_compose LCOMPOSE expr_or  { EBinOp ("<<", $1, $3) }
  | expr_or                        { $1 }

expr_or:
  | expr_or OR expr_and   { EBinOp ("||", $1, $3) }
  | expr_and              { $1 }

expr_and:
  | expr_and AND expr_cmp  { EBinOp ("&&", $1, $3) }
  | expr_cmp               { $1 }

expr_cmp:
  | expr_cmp EQ_EQ expr_cons  { EBinOp ("==", $1, $3) }
  | expr_cmp NEQ   expr_cons  { EBinOp ("!=", $1, $3) }
  | expr_cmp LT    expr_cons  { EBinOp ("<",  $1, $3) }
  | expr_cmp GT    expr_cons  { EBinOp (">",  $1, $3) }
  | expr_cmp LEQ   expr_cons  { EBinOp ("<=", $1, $3) }
  | expr_cmp GEQ   expr_cons  { EBinOp (">=", $1, $3) }
  | expr_cons                 { $1 }

expr_cons:
  | expr_append CONS expr_cons  { EBinOp ("::", $1, $3) }
  | expr_append                 { $1 }

expr_append:
  | expr_append PLUSPLUS   expr_add  { EBinOp ("++", $1, $3) }
  | expr_append STRAPPEND  expr_add  { EBinOp ("<>", $1, $3) }
  | expr_add                         { $1 }

expr_add:
  | expr_add PLUS  expr_mul  { EBinOp ("+", $1, $3) }
  | expr_add MINUS expr_mul  { EBinOp ("-", $1, $3) }
  | expr_mul                 { $1 }

expr_mul:
  | expr_mul STAR  expr_unary  { EBinOp ("*", $1, $3) }
  | expr_mul SLASH expr_unary  { EBinOp ("/", $1, $3) }
  | expr_mul MOD   expr_unary  { EBinOp ("%", $1, $3) }
  | expr_unary                 { $1 }

(* Unary minus binds tighter than `*` / `+` but looser than application.
   This means `f -x` parses as `f - x` (binary). For `f (-x)` use parens. *)
expr_unary:
  | MINUS expr_unary   { EUnOp ("-", $2) }
  | BANG  expr_unary   { EUnOp ("!", $2) }
  | expr_infix         { $1 }

expr_infix:
  | expr_infix BACKTICK_IDENT expr_app  { EInfix ($2, $1, $3) }
  | expr_app                            { $1 }

expr_app:
  | expr_app expr_postfix  { EApp ($1, $2) }
  | expr_postfix           { $1 }

expr_postfix:
  | expr_postfix DOT IDENT                        { EFieldAccess ($1, $3) }
  | expr_postfix DOT LBRACKET expr_no_block RBRACKET  { EIndex ($1, $4) }
  | expr_atom                                     { $1 }

(* Operator sections: (+e) desugars to \x -> x + e.
   MINUS is excluded — (-e) stays as unary negation, matching Haskell's convention.
   Left sections (e+) cannot be parsed unambiguously in LR without whitespace
   tokens; use an explicit lambda instead: (x => e + x). *)
section_op:
  | PLUS       { "+" }   | STAR       { "*" }   | SLASH      { "/" }
  | EQ_EQ      { "==" }  | NEQ        { "!=" }
  | LT         { "<" }   | GT         { ">" }   | LEQ        { "<=" }  | GEQ { ">=" }
  | AND        { "&&" }  | OR         { "||" }
  | CONS       { "::" }  | PLUSPLUS   { "++" }  | STRAPPEND  { "<>" }
  | PIPE_RIGHT { "|>" }  | RCOMPOSE   { ">>" }  | LCOMPOSE   { "<<" }

expr_atom:
  | lit                                              { ELoc (of_pos $startpos, ELit $1) }
  | IDENT                                            { ELoc (of_pos $startpos, EVar $1) }
  | UPPER                                            { ELoc (of_pos $startpos, EVar $1) }
  | LPAREN RPAREN                                    { ELoc (of_pos $startpos, ELit LUnit) }
  | LPAREN section_op expr_no_block RPAREN
    { let op = $2 and e = $3 in
      ELoc (of_pos $startpos, ELam ([PVar "_s"], EBinOp (op, EVar "_s", e))) }
  | LPAREN expr_no_block RPAREN                      { $2 }
  | LPAREN expr_no_block COMMA
      separated_nonempty_list(COMMA, expr_no_block) RPAREN
    { ELoc (of_pos $startpos, ETuple ($2 :: $4)) }
  | LBRACKET RBRACKET
    { ELoc (of_pos $startpos, EListLit []) }
  | LBRACKET separated_nonempty_list(COMMA, expr_no_block) RBRACKET
    { ELoc (of_pos $startpos, EListLit $2) }
  | LARRAY RARRAY
    { ELoc (of_pos $startpos, EArrayLit []) }
  | LARRAY separated_nonempty_list(COMMA, expr_no_block) RARRAY
    { ELoc (of_pos $startpos, EArrayLit $2) }
  | UPPER LBRACE separated_list(COMMA, kv_or_e) RBRACE
    { let items = $3 and name = $1 in
      let has_field = List.exists (function Field _ -> true | _ -> false) items in
      let has_kv    = List.exists (function KV _ -> true | _ -> false) items in
      if has_field then
        (* Record creation: Elem (EVar n) items are field puns *)
        let fields = List.map (function
          | Field (k, v)  -> (k, v)
          | Elem (ELoc (_, EVar n)) | Elem (EVar n) ->
              (n, ELoc (of_pos $startpos, EVar n))
          | Elem _ ->
              failwith (Printf.sprintf "non-identifier in pun position in %s { ... }" name)
          | KV _ ->
              failwith (Printf.sprintf "map entry (=>) mixed with record fields in %s { ... }" name)
        ) items in
        ELoc (of_pos $startpos, ERecordCreate (name, fields))
      else
        let all_kv = List.for_all (function KV _ -> true | _ -> false) items in
        if has_kv && not all_kv then
          failwith (Printf.sprintf "Mixed map/set entries in %s { ... }" name)
        else if has_kv then
          ELoc (of_pos $startpos, EMapLit (name,
            List.map (function KV (k,v) -> (k,v) | _ -> assert false) items))
        else
          ELoc (of_pos $startpos, ESetLit (name,
            List.map (function Elem e -> e | _ -> assert false) items)) }
  | LBRACE expr_no_block PIPE separated_nonempty_list(COMMA, record_field_expr) RBRACE
    { ELoc (of_pos $startpos, ERecordUpdate ($2, $4)) }
  | AT UPPER
    { ELoc (of_pos $startpos, EVar ("@" ^ $2)) }

record_field_expr:
  | IDENT EQUAL expr_no_block  { ($1, $3) }
  | IDENT                      { ($1, ELoc (of_pos $startpos, EVar $1)) }

kv_or_e:
  | IDENT EQUAL expr_no_block          { Field ($1, $3) }
  | expr_pipe FAT_ARROW expr_no_block  { KV ($1, $3) }
  | expr_no_block                      { Elem $1 }

(* ── Match arms ──────────────────────────────────────── *)

match_arm:
  | pat option(guard) FAT_ARROW expr_no_block newlines  { ($1, $2, $4) }

guard:
  | IF expr_or  { $2 }

(* ── Do-notation statements ──────────────────────────── *)

stmt:
  | pat LARROW expr_no_block newlines         { DoBind ($1, $3) }
  | LET MUT pat EQUAL expr_no_block newlines  { DoLet (true,  $3, $5) }
  | LET pat EQUAL expr_no_block newlines      { DoLet (false, $2, $4) }
  | LET IDENT nonempty_list(pat_atom) EQUAL expr_no_block newlines
    { DoLet (false, PVar $2, curry_lam $3 $5) }
  | IDENT EQUAL expr_no_block newlines        { DoAssign ($1, $3) }
  | expr_no_block newlines                    { DoExpr $1 }

(* ── Deriving clause ─────────────────────────────────── *)
(* Block forms (after DEDENT): the mandatory DEDENT newlines come first, so
   deriving_clause doesn't need a leading newline; it owns its trailing newlines. *)
deriving_clause:
  | DERIVING LPAREN separated_nonempty_list(COMMA, UPPER) RPAREN newlines  { $3 }

(* Inline form (same line as variants): no surrounding newlines — the outer rule
   handles the trailing newline after the entire declaration. *)
inline_deriving:
  | DERIVING LPAREN separated_nonempty_list(COMMA, UPPER) RPAREN  { $3 }

(* ── Data declarations ───────────────────────────────── *)

inner_data_decl:
  (* Block form: DEDENT, then mandatory newlines (from handle_indent), then optional deriving *)
  | DATA UPPER list(IDENT) INDENT nonempty_list(data_variant_line) DEDENT newlines option(deriving_clause)
    { fun is_pub -> DData (is_pub, $2, $3, $5, Option.value ~default:[] $8) }
  (* Inline form: optional deriving before the terminating newlines *)
  | DATA UPPER list(IDENT) EQUAL separated_nonempty_list(PIPE, data_variant_inline) option(inline_deriving) newlines
    { fun is_pub -> DData (is_pub, $2, $3, $5, Option.value ~default:[] $6) }

data_variant_line:
  | PIPE UPPER list(ty_atom) newlines  { { con_name = $2; con_fields = $3 } }

data_variant_inline:
  | UPPER list(ty_atom)  { { con_name = $1; con_fields = $2 } }

(* ── Record declarations ─────────────────────────────── *)

inner_record_decl:
  (* Block form: same structure as block data — newlines consumed before optional deriving *)
  | RECORD UPPER list(IDENT) INDENT nonempty_list(record_field_decl) DEDENT newlines option(deriving_clause)
    { fun is_pub -> DRecord (is_pub, $2, $3, $5, Option.value ~default:[] $8) }

record_field_decl:
  | IDENT COLON ty newlines  { { field_name = $1; field_type = $3 } }

(* ── Type alias declarations ─────────────────────────── *)

inner_type_alias_decl:
  | TYPE UPPER list(IDENT) EQUAL ty newlines
    { fun is_pub -> DTypeAlias (is_pub, $2, $3, $5) }

(* ── Newtype declarations ────────────────────────────── *)

inner_type_newtype_decl:
  | NEWTYPE UPPER list(IDENT) EQUAL UPPER ty newlines
    { fun is_pub -> DNewtype (is_pub, $2, $3, $5, $6, []) }
  | NEWTYPE UPPER list(IDENT) EQUAL UPPER ty inline_deriving newlines
    { fun is_pub -> DNewtype (is_pub, $2, $3, $5, $6, $7) }

(* ── Interface declarations ──────────────────────────── *)

inner_iface_decl:
  | option(DEFAULT) INTERFACE UPPER list(IDENT) option(iface_super) WHERE
    INDENT nonempty_list(iface_member) DEDENT newlines
    { fun is_pub -> DInterface {
        is_pub;
        is_default  = $1 <> None;
        iface_name  = $3;
        type_params = $4;
        super       = Option.value ~default:[] $5;
        methods     = $8;
      }
    }

iface_super:
  | REQUIRES separated_nonempty_list(COMMA, iface_super_entry)  { $2 }

iface_super_entry:
  | UPPER list(IDENT)  { ($1, $2) }

iface_member:
  | IDENT COLON ty newlines
    { { method_name = $1; method_type = $3; method_default = None } }
  | IDENT list(pat_atom) EQUAL fun_body newlines
    { { method_name = $1; method_type = TyVar "_"; method_default = Some ($2, $4) } }

(* ── Impl declarations ───────────────────────────────── *)

inner_impl_decl:
  | option(DEFAULT) IMPL UPPER nonempty_list(ty_atom) option(impl_requires) WHERE
    INDENT nonempty_list(impl_method) DEDENT newlines
    { fun is_pub -> DImpl {
        is_pub;
        is_default = $1 <> None;
        iface_name = $3;
        type_args  = $4;
        impl_name  = None;
        requires   = Option.value ~default:[] $5;
        methods    = $8;
      }
    }
  | option(DEFAULT) IMPL IDENT OF UPPER nonempty_list(ty_atom) option(impl_requires) WHERE
    INDENT nonempty_list(impl_method) DEDENT newlines
    { fun is_pub -> DImpl {
        is_pub;
        is_default = $1 <> None;
        iface_name = $5;
        type_args  = $6;
        impl_name  = Some $3;
        requires   = Option.value ~default:[] $7;
        methods    = $10;
      }
    }

impl_requires:
  | REQUIRES separated_nonempty_list(COMMA, impl_requires_entry)  { $2 }

impl_requires_entry:
  | UPPER nonempty_list(ty_atom)  { ($1, $2) }

impl_method:
  | IDENT list(pat_atom) EQUAL fun_body newlines  { ($1, $2, $4) }

(* ── Import declarations ─────────────────────────────── *)

import_path:
  | import_qual                                       { UseName $1 }
  | import_qual AS UPPER                              { UseAlias ($1, $3) }
  | import_qual AS IDENT                              { UseAlias ($1, $3) }
  | import_qual DOT_LBRACE separated_nonempty_list(COMMA, IDENT) RBRACE
                                                      { UseGroup ($1, $3) }
  | import_qual DOT_STAR                              { UseWild $1 }

import_qual:
  | import_ident                   { [$1] }
  | import_qual DOT import_ident   { $1 @ [$3] }

import_ident:
  | IDENT  { $1 }
  | UPPER  { $1 }

(* ── Literals ────────────────────────────────────────── *)

lit:
  | INT    { LInt $1 }
  | FLOAT  { LFloat $1 }
  | STRING { LString $1 }
  | CHAR   { LChar $1 }
  | BOOL   { LBool $1 }

(* ── Newlines ────────────────────────────────────────── *)

newlines:
  | NEWLINE           { () }
  | NEWLINE newlines  { () }
