%{
open Ast

let of_pos sp ep =
  { file     = sp.Lexing.pos_fname;
    line     = sp.Lexing.pos_lnum;
    col      = sp.Lexing.pos_cnum - sp.Lexing.pos_bol;
    end_line = ep.Lexing.pos_lnum;
    end_col  = ep.Lexing.pos_cnum - ep.Lexing.pos_bol }

(* Record the position of a top-level declaration on the shared
   `Parser_state.decl_positions` list.  When the lexer is wrapped by
   `Fmt.tracking_token`, the `last_content_line` side channel holds the
   line where the decl's last non-trivia token sat — preferable to
   `$endpos` for the formatter because $endpos spans trailing
   newlines/indentation that the parser already consumed.  Other callers
   (the LSP, the CLI) use the plain `Lexer.token` and leave the side
   channel at 0; in that case we just keep `ep.pos_lnum`. *)
let record_decl_pos sp ep =
  let loc = of_pos sp ep in
  let lcl = !Parser_state.last_content_line in
  let loc =
    if lcl >= sp.Lexing.pos_lnum && lcl <= ep.Lexing.pos_lnum
    then { loc with end_line = lcl }
    else loc
  in
  Parser_state.record_decl_pos loc

let fold_ty_app = function
  | []      -> failwith "empty type application"
  | [t]     -> t
  | t :: ts -> List.fold_left (fun acc a -> TyApp (acc, a)) t ts

(* Desugar a dotted-path field update into a flat (field, expr) pair.
   { base | a.b.c = v }  →  ("a", { base.a | b = { base.a.b | c = v } }) *)
let desugar_dotted_field base path value =
  match path with
  | [field] -> (field, value)
  | field :: rest ->
    let rec go base = function
      | [f]     -> ERecordUpdate (base, [(f, value)])
      | f :: fs -> ERecordUpdate (base, [(f, go (EFieldAccess (base, f)) fs)])
      | []      -> assert false
    in
    (field, go (EFieldAccess (base, field)) rest)
  | [] -> assert false

type kv_item = KV of expr * expr | Elem of expr | Field of string * expr

let stmts_to_expr = function
  | [DoExpr e] -> e
  | stmts      -> EBlock stmts

(* Desugar `let f x y = body` to `let f = (x => y => body)`. *)
let curry_lam pats body =
  List.fold_right (fun pat acc -> ELam ([pat], acc)) pats body

(* Coalesce same-named bindings into multi-clause entries, preserving
   first-appearance order across distinct names.  Shared by `where`-clauses,
   inline `let rec`, and top-level `let rec`. *)
let coalesce_clauses bindings =
  let order = ref [] and groups = Hashtbl.create 8 in
  List.iter (fun (name, pats, rhs) ->
    if not (Hashtbl.mem groups name) then order := name :: !order;
    let prev = try Hashtbl.find groups name with Not_found -> [] in
    Hashtbl.replace groups name (prev @ [(pats, rhs)])
  ) bindings;
  List.rev_map (fun n -> (n, Hashtbl.find groups n)) !order

(* Desugar `where` bindings into a mutually-recursive ELetGroup. *)
let desugar_where bindings main_expr =
  ELetGroup (coalesce_clauses bindings, main_expr)

(* A bare identifier names a constructor iff it starts with an uppercase ASCII
   letter. NB: `Char.uppercase_ascii c = c` is WRONG here — it is also true for
   `_` and digits, which mis-classifies a leading-underscore lambda parameter as
   a constructor (Phase 104). *)
let is_ctor_name s = String.length s > 0 && s.[0] >= 'A' && s.[0] <= 'Z'

(* Convert an expression back into a pattern when used as a lambda parameter.
   Supported: identifiers, literals, tuples, lists, cons, constructor apps. *)
let rec expr_to_pat = function
  | ELoc (_, e)  -> expr_to_pat e
  | EVar x when x = "_" -> PWild  (* shouldn't normally reach here; UNDERSCORE has its own rule *)
  | EVar x when is_ctor_name x -> PCon (x, [])  (* bare nullary constructor, e.g. `None` *)
  | EVar x       -> PVar x
  | ELit l       -> PLit l
  | ETuple es    -> PTuple (List.map expr_to_pat es)
  | EListLit es  -> PList  (List.map expr_to_pat es)
  | EBinOp ("::", a, b) -> PCons (expr_to_pat a, expr_to_pat b)
  | ESection (SecLeft (a, "::")) -> PCons (expr_to_pat a, PWild)  (* `(x :: _)` in a binding LHS: the `_` was eaten by the left-section rewrite — recover it *)
  | EAsPat (x, e) -> PAs (x, expr_to_pat e)  (* `x@subpat` in a binding LHS *)
  | EApp _ as e ->
    (* Constructor application: collect head + args, head must be uppercase.
       Strip ELoc wrappers along the way — both the head and each arg come
       out of the parser wrapped in ELoc. *)
    let rec strip = function ELoc (_, e) -> strip e | e -> e in
    let rec collect acc e = match strip e with
      | EApp (f, a) -> collect (a :: acc) f
      | EVar c when is_ctor_name c ->
        PCon (c, List.map expr_to_pat acc)
      | _ -> failwith "Invalid lambda parameter pattern"
    in
    collect [] e
  | _ -> failwith "Invalid lambda parameter pattern"

(* Flatten an assignment LHS into (base_var, field_path).
   `a`        → Some ("a", [])
   `a.b.c`    → Some ("a", ["b"; "c"])
   anything not rooted in a bare variable → None.
   The LHS arrives stripped of ELoc wrappers (via strip_locs_expr). *)
let rec flatten_field_path = function
  | EVar x -> Some (x, [])
  | EFieldAccess (inner, f) ->
    (match flatten_field_path inner with
     | Some (x, fs) -> Some (x, fs @ [f])
     | None -> None)
  | _ -> None

(* Convert a lambda LHS expression to a list of patterns.
   - EApp chain with a lowercase/wild/literal head → multiple patterns (multi-arg lambda)
   - EApp chain with an uppercase head → single constructor pattern via expr_to_pat
   - Anything else → single pattern via expr_to_pat *)
and expr_to_pats e =
  let rec strip = function ELoc (_, e) -> strip e | e -> e in
  let rec spine acc e = match strip e with
    | EApp (f, a) -> spine (a :: acc) f
    | head        -> (head, acc)
  in
  match strip e with
  | EApp _ as app ->
    let (head, args) = spine [] app in
    (match strip head with
     | EVar c when is_ctor_name c ->
       [expr_to_pat app]
     | _ ->
       List.map expr_to_pat (head :: args))
  | e -> [expr_to_pat e]

(* Guard arms (`| g.. = body`) are kept as an `EGuards` node so the formatter
   can round-trip them; `desugar.ml` lowers them to a nested if/match chain. *)

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

(* Parse an attribute name + optional string argument into an Ast.attr.
   Raises Failure for unknown or ill-formed attributes. *)
let parse_attr name msg_opt =
  match name, msg_opt with
  | "deprecated", Some msg -> Ast.AttrDeprecated msg
  | "deprecated", None     -> failwith "@deprecated requires a message: @deprecated \"reason\""
  | "inline",     None     -> Ast.AttrInline
  | "must_use",   None     -> Ast.AttrMustUse
  | n, _                   -> failwith (Printf.sprintf "Unknown attribute: @%s" n)
%}

(* Literals *)
%token <int>    INT
%token <float>  FLOAT
%token <string> STRING
%token <string> CHAR
%token <bool>   BOOL

(* String interpolation *)
%token <string> INTERP_OPEN
%token <string> INTERP_MID
%token <string> INTERP_END

(* Identifiers *)
%token <string> IDENT
%token <string> UPPER
%token <string> BACKTICK_IDENT

(* Keywords *)
%token LET REC WITH MUT IN IF THEN ELSE MATCH DATA RECORD INTERFACE DEFAULT IMPL
%token IMPORT EXPORT PUBLIC WHERE OF REQUIRES DO AS EXTERN DERIVING TYPE NEWTYPE PROP TEST BENCH FUNCTION

(* Operators *)
%token PLUS MINUS STAR SLASH MOD
%token EQ_EQ NEQ LT GT LEQ GEQ
%token AND OR
%token CONS PLUSPLUS STRAPPEND
%token PIPE_RIGHT RCOMPOSE LCOMPOSE
%token FAT_ARROW ARROW LARROW
%token AT BANG QUESTION
%token AS_AT  (* `@` lexed immediately after an identifier: as-pattern operator (`x@p`); distinct from the space-separated prefix-hint AT (`fn @Impl`) *)

(* Punctuation *)
%token EQUAL COLON COMMA DOT PIPE UNDERSCORE
%token LPAREN RPAREN LBRACKET RBRACKET LBRACE RBRACE
%token LARRAY RARRAY
%token DOT_LBRACE DOT_STAR
%token ELLIPSIS
%token DOTDOT DOTDOT_EQ

(* Indentation *)
%token NEWLINE INDENT DEDENT

%token EOF

%start <Ast.program> program
%start <Ast.expr>    repl_expr

%%

(* ═══════════════════════════════════════════════════════
   Grammar conflicts — audit notes
   ═══════════════════════════════════════════════════════

   `menhir --explain` emits a witness for 4 S/R + 1 R/R = 5 conflict states
   (`lib/parser.conflicts`), all resolved by menhir's defaults and all intended.
   This is down from 8 S/R + 6 R/R = 14 at Phase 60: Phase 81 eliminated the
   entire pat-vs-expr conflict family (see "History" below).  Phase 122 added the
   two dangling-else conflicts (states 464/470) when else-less `if` landed.

   ── How binding LHSs are parsed (the key design rule) ──────
   Every position that accepts both a pattern-bind and a bare expression —
   the do-block `stmt`, the list-comprehension `lc_qual` generator, and the
   `guard_qual` bind — parses its LHS as an `expr_no_block`/`expr_or` and
   converts it to a pattern in the semantic action via `expr_to_pat` (and
   `expr_to_pats` for lambda parameters).  A `pat`-LHS would share its
   `[`/`(`/UPPER/lit/`::` prefix with the bare-expression production, producing
   reduce/reduce conflicts between `pat_atom` and `expr_atom`; parsing the
   expression first and letting the `LARROW`/`=>` lookahead alone decide
   bind-vs-expression removes `pat_atom` from those start positions entirely.
   Practical consequences of the expression-first parse:
     • A constructor/cons/literal LHS works (`Some x <- m`, `h::t <- m`,
       `42 <- m`); `expr_to_pat` recovers the pattern.
     • A do-block's last statement may start with an uppercase constructor
       (`Some x` parses as a trailing DoExpr).
     • `_` after an operator inside a binding LHS is parsed as a left section,
       not a wildcard: `(x :: _) <- m` is `(x :: _)` the section, so it fails to
       convert.  Use a named tail (`(x :: rest) <- m`) or a match.  (Pattern
       positions proper — function params, match arms — are unaffected; they use
       the `pat` grammar directly.)

   ── As-patterns and the `@` token ─────────────────────────
   `@` is whitespace-sensitive (see `lexer.mll`): adjacent to an identifier it
   lexes as AS_AT (the as-pattern operator, `x@p`); separated by a space it is
   AT (the impl-disambiguation prefix, `fn @Impl`).  AS_AT appears only in
   `pat_as` (`IDENT AS_AT pat_cons`) and `expr_aspat` (`IDENT AS_AT
   expr_postfix`, lowered to PAs by `expr_to_pat`), so it never collides with
   the prefix-hint AT.  Compound as-pattern sub-patterns are parenthesised in
   binding LHSs (`x@(a, b)`, `x@(h::t)`), matching how the formatter prints PAs.

   ── The 5 remaining conflicts — all SHIFT/earlier-rule, all intended ──
     | State | Kind | Lookahead   | Reduce vs Shift / competing reductions      | Intended       |
     |-------|------|-------------|---------------------------------------------|----------------|
     | 134   | S/R  | LBRACE      | expr_atom->UPPER / `UPPER {…}` record literal | record creation|
     | 136   | S/R  | FAT_ARROW   | expr_atom->UNDERSCORE / `_ =>` lambda        | wildcard lambda|
     | 464   | S/R  | ELSE        | else-less block-`if` / `else` continues it    | bind to nearest|
     | 470   | S/R  | ELSE        | else-less inline-`if` / `else` continues it   | bind to nearest|
     | 589   | R/R  | RBRACE COMMA COLON | expr_annot->expr_lam / lambda inside `UPPER { k => v }` | KV (path A) |
   Rationale:
     • 134 — a bare `UPPER` followed by `{` is unambiguously a record literal.
     • 136 — `_` followed by `=>` is a wildcard lambda.
     • 464/470 — the classic dangling-else (Phase 122): with an else-less `if`,
       a nested `if a then if b then e . ELSE …` can attach the `else` to the
       inner `if` (shift) or treat the inner as else-less and bind `else` to the
       outer (reduce).  Shift wins → `else` binds to the nearest `if`, the
       universal convention.  In layout code the block DEDENT closes an inner
       else-less `if` before the `else` is seen, so indentation already picks the
       intended `if`; the conflict only bites the same-line nested form, where
       nearest-`if` is also what a reader expects.  (The `else`-continuation
       lexer filter — see `lexer.mll` — removes the NEWLINE before `else`, so
       these are pure ELSE-lookahead conflicts, NOT the NEWLINE-shift hazard a
       naive else-less rule would create.)
     • 589 — keeps `Map { k => v }` parsing as a key/value entry (path A: the
       earlier `expr_annot -> expr_lam` reduction) rather than a lambda-valued
       set element.
   State numbers are current menhir ids and drift as the grammar evolves; the
   resolutions do not.  Re-measure after any grammar change with
   `grep -c '^\*\* Conflict' _build/default/lib/parser.conflicts` (expect 5).

   ── History ────────────────────────────────────────────────
   Phase 7 started at 8 S/R + 8 R/R; later phases (record literals, left
   sections `_`, record patterns, range literals, kv_or_e, `@`-hints) grew it to
   8 S/R + 6 R/R explained witnesses by Phase 60, the bulk being do-block /
   guard / list-comp `pat_atom`-vs-`expr_atom` reduce/reduce conflicts.  A
   pre-Phase-81 fix moved the do-block `stmt` LHS to the expression-first form;
   Phase 81 finished the job by doing the same for `lc_qual` and `guard_qual`
   (and adding the AS_AT as-pattern operator), which removed that whole family
   and dropped the count to the 3 above.
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
  (* Declaration attributes: @deprecated "msg", @inline, @must_use.
     The inner `decl` production has already called record_decl_pos for its own
     span; we pop that entry and replace it with the outer attribute-inclusive span
     so `decl_positions` stays parallel to the returned `decl list`. *)
  | AT IDENT STRING newlines decl
    { Parser_state.pop_decl_pos ();
      record_decl_pos $startpos $endpos;
      let attr = parse_attr $2 (Some $3) in
      match $5 with d :: rest -> DAttrib ([attr], d) :: rest | [] -> assert false }
  | AT IDENT newlines decl
    { Parser_state.pop_decl_pos ();
      record_decl_pos $startpos $endpos;
      let attr = parse_attr $2 None in
      match $4 with d :: rest -> DAttrib ([attr], d) :: rest | [] -> assert false }
  (* public export data/record — DataPublic: type + constructors visible *)
  | PUBLIC EXPORT newlines inner_data_or_record  { record_decl_pos $startpos $endpos; [$4 DataPublic]   }
  | PUBLIC EXPORT inner_data_or_record           { record_decl_pos $startpos $endpos; [$3 DataPublic]   }
  (* export data/record — DataAbstract: type name only *)
  | EXPORT newlines inner_data_or_record         { record_decl_pos $startpos $endpos; [$3 DataAbstract] }
  | EXPORT inner_data_or_record                  { record_decl_pos $startpos $endpos; [$2 DataAbstract] }
  (* export non-data/record — normal bool pub *)
  | EXPORT newlines inner_non_data_decl          { record_decl_pos $startpos $endpos; [$3 true]  }
  | EXPORT inner_non_data_decl                   { record_decl_pos $startpos $endpos; [$2 true]  }
  (* bare data/record — DataPrivate *)
  | inner_data_or_record                         { record_decl_pos $startpos $endpos; [$1 DataPrivate]  }
  (* bare non-data/record — private *)
  | inner_non_data_decl                          { record_decl_pos $startpos $endpos; [$1 false] }
  | EXPORT IMPORT import_path newlines           { record_decl_pos $startpos $endpos; [DUse (true,  $3)] }
  | IMPORT import_path newlines                  { record_decl_pos $startpos $endpos; [DUse (false, $2)] }

(* data_vis -> decl: data and record declarations only *)
inner_data_or_record:
  | inner_data_decl    { $1 }
  | inner_record_decl  { $1 }

(* bool -> decl: everything except data and record *)
inner_non_data_decl:
  | inner_type_sig          { $1 }
  | inner_fun_def           { $1 }
  | inner_let_rec_decl      { $1 }
  | inner_type_alias_decl   { $1 }
  | inner_type_newtype_decl { $1 }
  | inner_iface_decl        { $1 }
  | inner_impl_decl         { $1 }
  | inner_extern_decl       { $1 }
  | inner_prop_decl         { $1 }
  | inner_test_decl         { $1 }
  | inner_bench_decl        { $1 }

(* ── Property declarations ───────────────────────────── *)

prop_param:
  | LPAREN IDENT COLON ty RPAREN  { ($2, $4) }

inner_prop_decl:
  | PROP STRING nonempty_list(prop_param) EQUAL fun_body newlines
    { fun is_pub ->
        DProp { is_pub; prop_name = $2;
                prop_params = $3; prop_body = $5 } }

(* ── Test declarations ──────────────────────────────── *)

inner_test_decl:
  | TEST STRING EQUAL fun_body newlines
    { fun is_pub -> DTest { is_pub; test_name = $2; test_body = $4 } }

(* ── Benchmark declarations ──────────────────────────── *)

inner_bench_decl:
  | BENCH STRING EQUAL fun_body newlines
    { fun is_pub -> DBench { is_pub; bench_name = $2; bench_body = $4 } }

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
    { fun is_pub -> DFunDef (is_pub, $1, $2, EGuards $4) }
  (* Haskell-style `where` scoping over ALL guard arms: the `where` sits at the
     same indentation as the guards (one level under the function name), so in
     the token stream it follows the last guard arm's NEWLINE *inside* the guard
     INDENT block — `INDENT guards WHERE INDENT bindings DEDENT NEWLINE DEDENT`.
     Lowers to `ELetGroup (bindings, EGuards arms)` so the where group scopes the
     whole guard set.  Lookahead (WHERE vs PIPE vs DEDENT) keeps it conflict-free. *)
  | IDENT list(pat_atom) INDENT nonempty_list(guard_arm) WHERE
    INDENT nonempty_list(where_binding) DEDENT newlines DEDENT newlines
    { fun is_pub -> DFunDef (is_pub, $1, $2, desugar_where $7 (EGuards $4)) }
  (* Phase 91 (3): inline single guard arm — `f n | n <= 0 = []` on one line.
     Lookahead after the pattern list distinguishes PIPE (this) from EQUAL
     (plain) and INDENT (block guards), so this adds no parser conflicts. *)
  | IDENT list(pat_atom) PIPE separated_nonempty_list(COMMA, guard_qual) EQUAL fun_body newlines
    { fun is_pub -> DFunDef (is_pub, $1, $2, EGuards [($4, $6)]) }

guard_arm:
  | PIPE separated_nonempty_list(COMMA, guard_qual) EQUAL fun_body newlines  { ($2, $4) }

guard_qual:
  (* Bind LHS parsed as an expression and converted to a pattern in the action
     (like the do-block `stmt` and `lc_qual` rules), so a `pat`-start bind does
     not reduce/reduce-conflict with the bare-expression guard.  The `LARROW`
     lookahead alone decides bind-vs-guard. *)
  | expr_or LARROW expr_or  { GBind (expr_to_pat $1, $3) }
  | expr_or                 { GBool $1 }

fun_body:
  | expr_no_block                                                    { $1 }
  | expr_no_block WHERE INDENT nonempty_list(where_binding) DEDENT   { desugar_where $4 $1 }
  (* Haskell-style: `where` on its own line, indented under the body.
     Token stream: expr INDENT WHERE INDENT bindings DEDENT NEWLINE DEDENT *)
  | expr_no_block INDENT WHERE INDENT nonempty_list(where_binding) DEDENT newlines DEDENT
    { desugar_where $5 $1 }
  | INDENT nonempty_list(stmt) DEDENT                                { stmts_to_expr $2 }

where_binding:
  | IDENT list(pat_atom) EQUAL fun_body newlines
    { ($1, $2, $4) }
  | IDENT list(pat_atom) INDENT nonempty_list(guard_arm) DEDENT newlines
    { ($1, $2, EGuards $4) }
  (* Phase 91 (3): inline single guard arm in a where-binding. *)
  | IDENT list(pat_atom) PIPE separated_nonempty_list(COMMA, guard_qual) EQUAL fun_body newlines
    { ($1, $2, EGuards [($4, $6)]) }

(* ── `let rec ... with ...` (Phase 57) ────────────────────
   Inline form: `let rec f x = e1 with g x = e2 in body`.
   Each clause is `IDENT pat-atoms = expr_no_block`.  WITH separates
   clauses without consuming a newline, so the inline form fits on one
   or more visually contiguous lines bracketed by LET REC ... IN. *)
let_rec_inline_clause:
  | IDENT list(pat_atom) EQUAL expr_no_block      { ($1, $2, $4) }

let_rec_inline_clauses:
  | let_rec_inline_clause                                          { [$1] }
  | let_rec_inline_clause WITH let_rec_inline_clauses              { $1 :: $3 }

(* Top-level form: each clause is terminated by `newlines`, and `WITH`
   begins the next clause at the same indentation as `LET REC`. *)
inner_let_rec_decl:
  | LET REC let_rec_decl_clauses
    { fun is_pub -> DLetGroup (is_pub, coalesce_clauses $3) }

let_rec_decl_clause:
  | IDENT list(pat_atom) EQUAL fun_body newlines  { ($1, $2, $4) }

let_rec_decl_clauses:
  | let_rec_decl_clause                                            { [$1] }
  | let_rec_decl_clause WITH let_rec_decl_clauses                  { $1 :: $3 }

(* ── Types ───────────────────────────────────────────── *)

ty:
  | ty_fun FAT_ARROW ty  { desugar_constraint $1 $3 }
  | ty_fun               { $1 }

ty_fun:
  | ty_app ARROW ty_fun  { TyFun ($1, $3) }
  | ty_app               { $1 }

ty_app:
  | nonempty_list(ty_atom)  { fold_ty_app $1 }
  | LT eff_row GT ty_app
    { let (labels, tail) = $2 in TyEffect (labels, tail, $4) }

ty_atom:
  | UPPER                                   { TyCon $1 }
  | IDENT                                   { TyVar $1 }
  | LPAREN ty RPAREN                        { $2 }
  | LPAREN ty COMMA separated_nonempty_list(COMMA, ty) RPAREN
    { TyTuple ($2 :: $4) }

(* An effect row: concrete labels (uppercase), optionally followed by a
   lowercase tail variable after `|` (`<IO | e>`), or a bare tail variable
   (`<e>`) for a pure-but-open row.  Phase 79. *)
eff_row:
  | separated_nonempty_list(COMMA, UPPER)               { ($1, None) }
  | separated_nonempty_list(COMMA, UPPER) PIPE IDENT    { ($1, Some $3) }
  | IDENT                                               { ([], Some $1) }

(* ── Patterns ────────────────────────────────────────── *)

pat:
  | pat_as  { $1 }

pat_as:
  (* As-patterns are written with `@` adjacent to the name (`x@p`), which the
     lexer tokenises as AS_AT.  A spaced `x @ p` lexes the `@` as the prefix-hint
     AT and is not a valid pattern — consistent with the whitespace-sensitive `@`
     rule, and the formatter always prints as-patterns adjacent. *)
  | IDENT AS_AT pat_cons  { PAs ($1, $3) }
  | pat_cons              { $1 }

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

(* Record pattern fields.  Returns (field_list, has_rest). *)
record_pat_field:
  | IDENT EQUAL pat  { ($1, Some $3) }
  | IDENT            { ($1, None) }

(* Tail of a record_pat_fields list: either "..." or another field [, ...]. *)
record_pat_rest:
  | ELLIPSIS                                  { ([], true) }
  | record_pat_field                          { ([$1], false) }
  | record_pat_field COMMA record_pat_rest    { let (fs, r) = $3 in ($1 :: fs, r) }

record_pat_fields:
  | ELLIPSIS                                  { ([], true) }
  | record_pat_field COMMA record_pat_rest    { let (fs, r) = $3 in ($1 :: fs, r) }
  | record_pat_field                          { ([$1], false) }

pat_atom:
  | IDENT                                                  { PVar $1 }
  | UNDERSCORE                                             { PWild }
  | UPPER                                                  { PCon ($1, []) }
  | UPPER LBRACE record_pat_fields RBRACE
    { let (fs, r) = $3 in PRec ($1, fs, r) }
  | INT  DOTDOT    INT   { PRng (LInt $1,  LInt $3,  false) }
  | INT  DOTDOT_EQ INT   { PRng (LInt $1,  LInt $3,  true) }
  | CHAR DOTDOT    CHAR  { PRng (LChar $1, LChar $3, false) }
  | CHAR DOTDOT_EQ CHAR  { PRng (LChar $1, LChar $3, true) }
  (* Negative integer literals in range patterns.  Permit `MINUS INT`
     wherever an `INT` bound is expected, in all four combinations. *)
  | MINUS INT DOTDOT INT       { PRng (LInt (-$2), LInt $4, false) }
  | MINUS INT DOTDOT_EQ INT    { PRng (LInt (-$2), LInt $4, true) }
  | INT DOTDOT MINUS INT       { PRng (LInt $1, LInt (-$4), false) }
  | INT DOTDOT_EQ MINUS INT    { PRng (LInt $1, LInt (-$4), true) }
  | MINUS INT DOTDOT MINUS INT { PRng (LInt (-$2), LInt (-$5), false) }
  | MINUS INT DOTDOT_EQ MINUS INT { PRng (LInt (-$2), LInt (-$5), true) }
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
    { ELoc (of_pos $startpos $endpos, ELet (true,  false, $3, $5, $7)) }
  | LET pat EQUAL expr_no_block IN expr_lam
    { ELoc (of_pos $startpos $endpos, ELet (false, false, $2, $4, $6)) }
  | LET IDENT nonempty_list(pat_atom) EQUAL expr_no_block IN expr_lam
    { ELoc (of_pos $startpos $endpos, ELet (false, true, PVar $2, curry_lam $3 $5, $7)) }
  | LET REC let_rec_inline_clauses IN expr_lam
    { ELoc (of_pos $startpos $endpos, ELetGroup (coalesce_clauses $3, $5)) }
  (* Phase 45.11: annotated let-in.  `let x : T = e in rest` wraps the
     RHS in an EAnnot so the typechecker pins the binding's type. *)
  | LET IDENT COLON ty EQUAL expr_no_block IN expr_lam
    { ELoc (of_pos $startpos $endpos,
            ELet (false, false, PVar $2, EAnnot ($6, $4), $8)) }
  | LET MUT IDENT COLON ty EQUAL expr_no_block IN expr_lam
    { ELoc (of_pos $startpos $endpos,
            ELet (true, false, PVar $3, EAnnot ($7, $5), $9)) }
  (* if/then/else.  Phase 122: the lexer's `else`-continuation filter drops the
     NEWLINE before any `else`, so no rule needs a `newlines ELSE` separator —
     the four with-else shapes below cover inline/block × inline/block, and an
     `else`-less `if` (defaulting to `()`) is unambiguous because a NEWLINE after
     a `then` branch can now only mean "end of the if".  The two `else`-bearing
     productions per then-shape create the standard dangling-else shift/reduce
     conflict, resolved (correctly) toward shift — `else` binds to the nearest
     `if`. *)
  | IF LET pat EQUAL expr_or THEN expr_lam ELSE expr_lam
    { ELoc (of_pos $startpos $endpos, EMatch ($5, [($3, [], $7); (PWild, [], $9)])) }
  | IF expr_or THEN expr_lam ELSE expr_lam
    { ELoc (of_pos $startpos $endpos, EIf ($2, $4, $6)) }
  | IF expr_or THEN INDENT nonempty_list(stmt) DEDENT ELSE INDENT nonempty_list(stmt) DEDENT
    { ELoc (of_pos $startpos $endpos,
            EIf ($2, stmts_to_expr $5, stmts_to_expr $9)) }
  | IF expr_or THEN INDENT nonempty_list(stmt) DEDENT ELSE expr_lam
    { ELoc (of_pos $startpos $endpos,
            EIf ($2, stmts_to_expr $5, $8)) }
  | IF expr_or THEN expr_lam ELSE INDENT nonempty_list(stmt) DEDENT
    { ELoc (of_pos $startpos $endpos,
            EIf ($2, $4, stmts_to_expr $7)) }
  (* Phase 122: else-less `if … then …` (inline or indented-block then).  The
     missing branch defaults to the unit value `()`, so the `if` types as Unit
     and the `then` branch must be Unit too — natural for side-effecting <Mut>
     code. *)
  | IF expr_or THEN expr_lam
    { ELoc (of_pos $startpos $endpos, EIf ($2, $4, ELit LUnit)) }
  | IF expr_or THEN INDENT nonempty_list(stmt) DEDENT
    { ELoc (of_pos $startpos $endpos, EIf ($2, stmts_to_expr $5, ELit LUnit)) }
  | MATCH expr_or INDENT nonempty_list(match_arm) DEDENT
    { ELoc (of_pos $startpos $endpos, EMatch ($2, $4)) }
  | FUNCTION INDENT nonempty_list(match_arm) DEDENT
    { ELoc (of_pos $startpos $endpos, EFunction $3) }
  | DO INDENT nonempty_list(stmt) DEDENT
    { ELoc (of_pos $startpos $endpos, EDo (ref None, $3)) }
  | UNDERSCORE FAT_ARROW expr_lam
    { ELoc (of_pos $startpos $endpos, ELam ([PWild], $3)) }
  | expr_pipe FAT_ARROW expr_lam
    { ELoc (of_pos $startpos $endpos, ELam (expr_to_pats $1, $3)) }
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
  | expr_infix BACKTICK_IDENT expr_question  { EInfix ($2, $1, $3) }
  | expr_question                            { $1 }

(* Postfix `?` binds looser than function application: `Ok 5 ?` is `(Ok 5) ?`.
   This level sits between `expr_infix` and `expr_app` so the whole call is
   what gets `?`-applied. *)
expr_question:
  | expr_question QUESTION  { EQuestion $1 }
  | expr_app                { $1 }

expr_app:
  | expr_app expr_aspat  { EApp ($1, $2) }
  | expr_aspat           { $1 }

(* As-pattern operator (`x@subpat`).  AS_AT is emitted by the lexer only when `@`
   directly follows an identifier (no space), so this never collides with the
   space-separated prefix-hint `AT` (`fn @Impl`).  The RHS is an `expr_postfix`
   atom; compound sub-patterns are parenthesised (`x@(a, b)`, `x@(h::t)`),
   matching how the formatter prints `PAs`.  `expr_to_pat`/`expr_to_pats` lower
   EAsPat to `PAs` at the lambda / do-bind boundary; elsewhere resolve rejects it. *)
expr_aspat:
  | IDENT AS_AT expr_postfix  { ELoc (of_pos $startpos $endpos, EAsPat ($1, $3)) }
  | expr_postfix             { $1 }

expr_postfix:
  | expr_postfix DOT IDENT                        { EFieldAccess ($1, $3) }
  | expr_postfix DOT LBRACKET expr_no_block RBRACKET  { EIndex ($1, $4) }
  | expr_postfix DOT LBRACKET expr_no_block DOTDOT    expr_no_block RBRACKET  { ESlice ($1, $4, $6, false) }
  | expr_postfix DOT LBRACKET expr_no_block DOTDOT_EQ expr_no_block RBRACKET  { ESlice ($1, $4, $6, true) }
  | expr_atom                                     { $1 }

(* Operator sections.
   Right section (+e) desugars to \x -> x + e.  MINUS is excluded: (-e) stays
   as unary negation, matching Haskell's convention.
   Left section (e op _) desugars to \x -> e op x.  The _ placeholder makes
   the syntax unambiguous in LALR(1): (2 * _) parses as EBinOp("*",2,EVar"_")
   and the semantic action on LPAREN expr_no_block RPAREN converts it to a
   lambda.  MINUS works too: (3 - _) = \x -> 3 - x. *)
section_op:
  | PLUS       { "+" }   | STAR       { "*" }   | SLASH      { "/" }
  | EQ_EQ      { "==" }  | NEQ        { "!=" }
  | LT         { "<" }   | GT         { ">" }   | LEQ        { "<=" }  | GEQ { ">=" }
  | AND        { "&&" }  | OR         { "||" }
  | CONS       { "::" }  | PLUSPLUS   { "++" }  | STRAPPEND  { "<>" }
  | PIPE_RIGHT { "|>" }  | RCOMPOSE   { ">>" }  | LCOMPOSE   { "<<" }

(* Bare operator sections (op) — like section_op but also allows MINUS.
   MINUS is excluded from section_op above because (-e) means unary
   negation, but (- ) has no such ambiguity and means subtraction. *)
section_op_bare:
  | section_op { $1 }
  | MINUS      { "-" }

expr_atom:
  | lit                                              { ELoc (of_pos $startpos $endpos, ELit $1) }
  | IDENT                                            { ELoc (of_pos $startpos $endpos, EVar $1) }
  | UPPER                                            { ELoc (of_pos $startpos $endpos, EVar $1) }
  | UNDERSCORE                                       { ELoc (of_pos $startpos $endpos, EVar "_") }
  | LPAREN RPAREN                                    { ELoc (of_pos $startpos $endpos, ELit LUnit) }
  | LPAREN section_op_bare RPAREN
    { ELoc (of_pos $startpos $endpos, ESection (SecBare $2)) }
  | LPAREN section_op expr_no_block RPAREN
    { ELoc (of_pos $startpos $endpos, ESection (SecRight ($2, $3))) }
  | LPAREN expr_no_block RPAREN
    { (* Left section (e op _) becomes ESection (SecLeft ...); a plain
         parenthesised expression just unwraps to its inner expr. *)
      let rec strip = function ELoc (_, e) -> strip e | e -> e in
      match strip $2 with
      | EBinOp (op, lhs, rhs) when (match strip rhs with EVar "_" -> true | _ -> false) ->
          ELoc (of_pos $startpos $endpos, ESection (SecLeft (lhs, op)))
      | _ -> $2 }
  | LPAREN expr_no_block COMMA
      separated_nonempty_list(COMMA, expr_no_block) RPAREN
    { ELoc (of_pos $startpos $endpos, ETuple ($2 :: $4)) }
  | LBRACKET RBRACKET
    { ELoc (of_pos $startpos $endpos, EListLit []) }
  | LBRACKET expr_no_block PIPE separated_nonempty_list(COMMA, lc_qual) RBRACKET
    { ELoc (of_pos $startpos $endpos, EListComp ($2, $4)) }
  | LBRACKET separated_nonempty_list(COMMA, expr_no_block) RBRACKET
    { ELoc (of_pos $startpos $endpos, EListLit $2) }
  | LARRAY RARRAY
    { ELoc (of_pos $startpos $endpos, EArrayLit []) }
  | LARRAY separated_nonempty_list(COMMA, expr_no_block) RARRAY
    { ELoc (of_pos $startpos $endpos, EArrayLit $2) }
  | LBRACKET expr_no_block DOTDOT    expr_no_block RBRACKET
    { ELoc (of_pos $startpos $endpos, ERangeList ($2, $4, false)) }
  | LBRACKET expr_no_block DOTDOT_EQ expr_no_block RBRACKET
    { ELoc (of_pos $startpos $endpos, ERangeList ($2, $4, true)) }
  | LARRAY   expr_no_block DOTDOT    expr_no_block RARRAY
    { ELoc (of_pos $startpos $endpos, ERangeArray ($2, $4, false)) }
  | LARRAY   expr_no_block DOTDOT_EQ expr_no_block RARRAY
    { ELoc (of_pos $startpos $endpos, ERangeArray ($2, $4, true)) }
  | UPPER LBRACE separated_list(COMMA, kv_or_e) RBRACE
    { let items = $3 and name = $1 in
      let has_field = List.exists (function Field _ -> true | _ -> false) items in
      let has_kv    = List.exists (function KV _ -> true | _ -> false) items in
      if has_field then
        (* Record creation: Elem (EVar n) items are field puns *)
        let fields = List.map (function
          | Field (k, v)  -> (k, v)
          | Elem (ELoc (_, EVar n)) | Elem (EVar n) ->
              (n, ELoc (of_pos $startpos $endpos, EVar n))
          | Elem _ ->
              failwith (Printf.sprintf "non-identifier in pun position in %s { ... }" name)
          | KV _ ->
              failwith (Printf.sprintf "map entry (=>) mixed with record fields in %s { ... }" name)
        ) items in
        ELoc (of_pos $startpos $endpos, ERecordCreate (name, fields))
      else
        let all_kv = List.for_all (function KV _ -> true | _ -> false) items in
        if has_kv && not all_kv then
          failwith (Printf.sprintf "Mixed map/set entries in %s { ... }" name)
        else if has_kv then
          ELoc (of_pos $startpos $endpos, EMapLit (name,
            List.map (function KV (k,v) -> (k,v) | _ -> assert false) items))
        else
          ELoc (of_pos $startpos $endpos, ESetLit (name,
            List.map (function Elem e -> e | _ -> assert false) items)) }
  | LBRACE expr_no_block PIPE separated_nonempty_list(COMMA, record_field_expr) RBRACE
    { let base = $2 in
      let fields = List.map (fun (path, v) -> desugar_dotted_field base path v) $4 in
      ELoc (of_pos $startpos $endpos, ERecordUpdate (base, fields)) }
  | AT UPPER
    { ELoc (of_pos $startpos $endpos, EVar ("@" ^ $2)) }
  | AT IDENT
    { ELoc (of_pos $startpos $endpos, EVar ("@" ^ $2)) }
  | interp_string
    { ELoc (of_pos $startpos $endpos, EStringInterp $1) }

record_field_expr:
  | separated_nonempty_list(DOT, IDENT) EQUAL expr_no_block  { ($1, $3) }
  | IDENT                      { ([$1], ELoc (of_pos $startpos $endpos, EVar $1)) }

kv_or_e:
  | IDENT EQUAL expr_no_block          { Field ($1, $3) }
  | expr_pipe FAT_ARROW expr_no_block  { KV ($1, $3) }
  | expr_no_block                      { Elem $1 }

(* ── Match arms ──────────────────────────────────────── *)

match_arm:
  | pat guard_opt FAT_ARROW expr_no_block newlines  { ($1, $2, $4) }
  | pat guard_opt FAT_ARROW expr_no_block WHERE INDENT nonempty_list(where_binding) DEDENT newlines
    { ($1, $2, desugar_where $7 $4) }
  (* Haskell-style `where` on its own indented line within a match arm. *)
  | pat guard_opt FAT_ARROW expr_no_block INDENT WHERE INDENT nonempty_list(where_binding) DEDENT newlines DEDENT newlines
    { ($1, $2, desugar_where $8 $4) }
  (* Phase 45.8: indented-block body for a match arm.  Lowers to EDo
     so the existing do-handling (let-chain, sequencing) applies.  The
     EDo path also gives free monadic-bind dispatch if any stmt is a
     `<-` bind. *)
  | pat guard_opt FAT_ARROW INDENT nonempty_list(stmt) DEDENT newlines
    { ($1, $2, stmts_to_expr $5) }

(* Guard qualifier sequence for a match arm; empty list = unguarded. *)
guard_opt:
  | (* empty *)                                       { [] }
  | IF separated_nonempty_list(COMMA, guard_qual)     { $2 }

(* ── List comprehension qualifiers ──────────────────── *)

lc_qual:
  (* Generator LHS is parsed as an expression and converted to a pattern in the
     action (like the do-block `stmt` rule), so a `pat`-start generator does not
     reduce/reduce-conflict with the bare-expression guard production.  The
     `LARROW` lookahead alone decides generator-vs-guard. *)
  | expr_no_block LARROW expr_no_block   { LCGen (expr_to_pat $1, $3) }
  | LET pat EQUAL expr_no_block          { LCLet (false, $2, $4) }
  | LET MUT pat EQUAL expr_no_block      { LCLet (true,  $3, $5) }
  | expr_no_block                        { LCGuard $1 }

(* ── Do-notation statements ──────────────────────────── *)

stmt:
  (* DoBind LHS is parsed as an expression and converted to a pattern in the
     action — NOT as a `pat`.  A `pat`-LHS here shares its `[`/`(`/UPPER/lit
     prefix with the DoExpr `expr_no_block` production, and the resulting
     reduce/reduce conflict (expr_atom vs pat_atom on COMMA/RBRACKET/CONS/…)
     was resolved toward the pattern, so any list/tuple/ctor/cons *expression*
     in statement position failed to parse (it committed to the pattern path,
     then died for lack of a `<-`).  Parsing an `expr_no_block` first and
     letting the `LARROW` lookahead decide bind-vs-expr removes `pat_atom` from
     statement start entirely, killing the conflict.  Mirrors the assignment
     production below, which already converts its expression LHS by hand. *)
  | expr_no_block LARROW expr_no_block newlines { DoBind (expr_to_pat $1, $3) }
  | LET MUT pat EQUAL expr_no_block newlines  { DoLet (true,  $3, $5) }
  | LET pat EQUAL expr_no_block ELSE expr_no_block newlines { DoLetElse ($2, $4, $6) }
  | LET pat EQUAL expr_no_block newlines      { DoLet (false, $2, $4) }
  | LET IDENT nonempty_list(pat_atom) EQUAL expr_no_block newlines
    { DoLet (false, PVar $2, curry_lam $3 $5) }
  | expr_no_block EQUAL expr_no_block newlines {
      match flatten_field_path (strip_locs_expr $1) with
      | Some (x, []) -> DoAssign (x, $3)
      | Some (x, (_ :: _ as fields)) -> DoFieldAssign (x, fields, $3)
      | None -> failwith "invalid assignment target in do-block"
    }
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
  (* Block form (Haskell-style): the first variant is introduced by `=`, the
     rest by `|`, one per indented line:
         data Rep
           = RCon String (List Rep)
           | RInt Int
     DEDENT is followed by mandatory newlines (from handle_indent), then
     optional deriving. *)
  | DATA UPPER list(IDENT) INDENT data_variant_head list(data_variant_line) DEDENT newlines option(deriving_clause)
    { fun vis -> DData (vis, $2, $3, $5 :: $6, Option.value ~default:[] $9) }
  (* Inline form: optional deriving before the terminating newlines *)
  | DATA UPPER list(IDENT) EQUAL separated_nonempty_list(PIPE, data_variant_inline) option(inline_deriving) newlines
    { fun vis -> DData (vis, $2, $3, $5, Option.value ~default:[] $6) }

(* First variant of the block form, introduced by `=`. *)
data_variant_head:
  | EQUAL UPPER list(ty_atom) newlines
    { { con_name = $2; con_payload = Ast.ConPos $3 } }
  | EQUAL UPPER LBRACE separated_nonempty_list(COMMA, inline_field_decl) RBRACE newlines
    { { con_name = $2; con_payload = Ast.ConNamed $4 } }

(* Subsequent variants of the block form, introduced by `|`. *)
data_variant_line:
  | PIPE UPPER list(ty_atom) newlines
    { { con_name = $2; con_payload = Ast.ConPos $3 } }
  | PIPE UPPER LBRACE separated_nonempty_list(COMMA, inline_field_decl) RBRACE newlines
    { { con_name = $2; con_payload = Ast.ConNamed $4 } }

data_variant_inline:
  | UPPER list(ty_atom)
    { { con_name = $1; con_payload = Ast.ConPos $2 } }
  | UPPER LBRACE separated_nonempty_list(COMMA, inline_field_decl) RBRACE
    { { con_name = $1; con_payload = Ast.ConNamed $3 } }

inline_field_decl:
  | IDENT COLON ty  { { Ast.field_name = $1; field_type = $3 } }

(* ── Record declarations ─────────────────────────────── *)

inner_record_decl:
  (* Block form: same structure as block data — newlines consumed before optional deriving *)
  | RECORD UPPER list(IDENT) INDENT nonempty_list(record_field_decl) DEDENT newlines option(deriving_clause)
    { fun vis -> DRecord (vis, $2, $3, $5, Option.value ~default:[] $8) }

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
  (* Phase 45.12: marker interface — no methods.  WHERE keyword optional. *)
  | option(DEFAULT) INTERFACE UPPER list(IDENT) option(iface_super) option(WHERE) newlines
    { fun is_pub -> DInterface {
        is_pub;
        is_default  = $1 <> None;
        iface_name  = $3;
        type_params = $4;
        super       = Option.value ~default:[] $5;
        methods     = [];
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
        impl_loc   = Some (of_pos $startpos $endpos);
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
        impl_loc   = Some (of_pos $startpos $endpos);
        iface_name = $5;
        type_args  = $6;
        impl_name  = Some $3;
        requires   = Option.value ~default:[] $7;
        methods    = $10;
      }
    }
  | option(DEFAULT) IMPL UPPER OF UPPER nonempty_list(ty_atom) option(impl_requires) WHERE
    INDENT nonempty_list(impl_method) DEDENT newlines
    { fun is_pub -> DImpl {
        is_pub;
        is_default = $1 <> None;
        impl_loc   = Some (of_pos $startpos $endpos);
        iface_name = $5;
        type_args  = $6;
        impl_name  = Some $3;
        requires   = Option.value ~default:[] $7;
        methods    = $10;
      }
    }
  (* Empty impl bodies: when every method has a default in the
     interface, the user can write just `impl Foo X` (no methods).
     The `WHERE` keyword is optional in this form. *)
  | option(DEFAULT) IMPL UPPER nonempty_list(ty_atom) option(impl_requires) option(WHERE) newlines
    { fun is_pub -> DImpl {
        is_pub;
        is_default = $1 <> None;
        impl_loc   = Some (of_pos $startpos $endpos);
        iface_name = $3;
        type_args  = $4;
        impl_name  = None;
        requires   = Option.value ~default:[] $5;
        methods    = [];
      }
    }
  | option(DEFAULT) IMPL IDENT OF UPPER nonempty_list(ty_atom) option(impl_requires) option(WHERE) newlines
    { fun is_pub -> DImpl {
        is_pub;
        is_default = $1 <> None;
        impl_loc   = Some (of_pos $startpos $endpos);
        iface_name = $5;
        type_args  = $6;
        impl_name  = Some $3;
        requires   = Option.value ~default:[] $7;
        methods    = [];
      }
    }
  | option(DEFAULT) IMPL UPPER OF UPPER nonempty_list(ty_atom) option(impl_requires) option(WHERE) newlines
    { fun is_pub -> DImpl {
        is_pub;
        is_default = $1 <> None;
        impl_loc   = Some (of_pos $startpos $endpos);
        iface_name = $5;
        type_args  = $6;
        impl_name  = Some $3;
        requires   = Option.value ~default:[] $7;
        methods    = [];
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
  | import_qual DOT_LBRACE separated_nonempty_list(COMMA, import_member) RBRACE
                                                      { UseGroup ($1, $3) }
  | import_qual DOT_STAR                              { UseWild $1 }

import_qual:
  | import_ident                   { [$1] }
  | import_qual DOT import_ident   { $1 @ [$3] }

import_ident:
  | IDENT  { $1 }
  | UPPER  { $1 }
  | TEST   { "test" }   (* allow `import test.{…}` despite TEST being a keyword *)

(* A `{…}` group member: a bare name, or `T(..)` for "T and all its
   exported constructors" (Phase 100). The bool marks the (..) form. *)
import_member:
  | import_ident                 { ($1, false) }
  | UPPER LPAREN DOTDOT RPAREN    { ($1, true) }

(* ── String interpolation ────────────────────────────── *)

interp_string:
  | INTERP_OPEN expr_no_block INTERP_END
      { [InterpStr $1; InterpExpr $2; InterpStr $3] }
  | INTERP_OPEN expr_no_block interp_tail
      { InterpStr $1 :: InterpExpr $2 :: $3 }

interp_tail:
  | INTERP_MID expr_no_block INTERP_END
      { [InterpStr $1; InterpExpr $2; InterpStr $3] }
  | INTERP_MID expr_no_block interp_tail
      { InterpStr $1 :: InterpExpr $2 :: $3 }

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
