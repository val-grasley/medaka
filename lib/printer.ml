(* Pretty printer for Medaka. Produces parseable source from an AST.

   Layout is built on a small Wadler/Leijen document algebra (the [doc] type
   below) rendered against a column budget, so constructs that grow too wide for
   one line split intelligently.  A [Group] renders flat when its flattened
   content fits the remaining width and breaks otherwise; [Line]/[Softline]
   become spaces/nothing when flat and newlines (at the current [Nest] indent)
   when broken; [Hardline] always breaks.

   Because Medaka is layout-sensitive, soft breaks are only introduced where a
   newline is legal: inside delimiters (`[ ]`, `[| |]`, `( )`, `{ }` — the lexer
   suppresses INDENT/DEDENT there) and before a leading continuation operator
   (`|> >> << && || ++ <>`, rescued by the lexer's continuation rule).  Bare
   positions (application chains, type arrows, `let … in`) stay flat. *)

open Ast

(* ── Document algebra ────────────────────────────── *)

type doc =
  | Nil
  | Text of string
  | Cat of doc * doc
  | Line              (* flat: " "   broken: newline + indent *)
  | Softline          (* flat: ""    broken: newline + indent *)
  | Hardline          (* always newline + indent *)
  | Nest of int * doc (* add n columns to the indent of contained breaks *)
  | Group of doc      (* flat if it fits the remaining width, else broken *)

let ( ^^ ) a b = Cat (a, b)
let text s = Text s
let group d = Group d
let nest d = Nest (2, d)               (* one 2-space indent step *)

let rec sep_by sep = function
  | []      -> Nil
  | [ x ]   -> x
  | x :: xs -> x ^^ sep ^^ sep_by sep xs

let concat ds = List.fold_left ( ^^ ) Nil ds

(* The block layout used by `match`/`do`/`where`/record/interface/impl bodies:
   a forced newline then the content indented one step.  Mirrors the old
   imperative `indented`, which emitted `\n  <content>`. *)
let indent_block d = Nest (2, Hardline ^^ d)

(* A comma-separated sequence inside `open`/`close` delimiters with no inner
   padding (lists, arrays, tuples): `[a, b]` flat, one-per-line when broken. *)
let delimited open_ close_ items =
  match items with
  | [] -> text open_ ^^ text close_
  | _ ->
    group (text open_
           ^^ nest (Softline ^^ sep_by (text "," ^^ Line) items)
           ^^ Softline ^^ text close_)

(* A brace-delimited sequence with inner padding (record literals): `{ a, b }`
   flat, one-per-line when broken. *)
let braced items =
  match items with
  | [] -> text "{}"
  | _ ->
    group (text "{"
           ^^ nest (Line ^^ sep_by (text "," ^^ Line) items)
           ^^ Line ^^ text "}")

(* ── Layout engine ───────────────────────────────── *)

type mode = Flat | Break

let default_width = 80

let render width doc =
  let buf = Buffer.create 256 in
  (* Does the flat layout of [items] fit in [w] columns before a newline? *)
  let rec fits w items =
    if w < 0 then false
    else match items with
      | [] -> true
      | (_, _, Nil)        :: z -> fits w z
      | (i, m, Cat (a, b)) :: z -> fits w ((i, m, a) :: (i, m, b) :: z)
      | (i, m, Nest (j, d)):: z -> fits w ((i + j, m, d) :: z)
      | (_, _, Text s)     :: z -> fits (w - String.length s) z
      | (_, Flat, Line)    :: z -> fits (w - 1) z
      | (_, Flat, Softline):: z -> fits w z
      | (_, Break, Line)     :: _ -> true
      | (_, Break, Softline) :: _ -> true
      | (_, Break, Hardline) :: _ -> true
      | (_, Flat, Hardline)  :: _ -> false   (* a hardline forces the group to break *)
      | (i, _, Group d)    :: z -> fits w ((i, Flat, d) :: z)
  in
  let newline i =
    Buffer.add_char buf '\n';
    for _ = 1 to i do Buffer.add_char buf ' ' done
  in
  let rec go col = function
    | [] -> ()
    | (_, _, Nil)         :: z -> go col z
    | (i, m, Cat (a, b))  :: z -> go col ((i, m, a) :: (i, m, b) :: z)
    | (i, m, Nest (j, d)) :: z -> go col ((i + j, m, d) :: z)
    | (_, _, Text s)      :: z -> Buffer.add_string buf s; go (col + String.length s) z
    | (_, Flat, Line)     :: z -> Buffer.add_char buf ' '; go (col + 1) z
    | (_, Flat, Softline) :: z -> go col z
    | (i, Break, Line)     :: z
    | (i, Break, Softline) :: z -> newline i; go i z
    | (i, _, Hardline)     :: z -> newline i; go i z
    | (i, _, Group d)      :: z ->
      let flat = (i, Flat, d) :: z in
      if fits (width - col) flat then go col flat
      else go col ((i, Break, d) :: z)
  in
  go 0 [ (0, Break, doc) ];
  Buffer.contents buf

(* ── Literals ────────────────────────────────────── *)

let print_lit = function
  | LInt n    -> text (string_of_int n)
  | LFloat f  ->
    let s = Printf.sprintf "%g" f in
    (* Force a decimal point so the lexer reads it as FLOAT, not INT *)
    text (if String.contains s '.' || String.contains s 'e' then s else s ^ ".0")
  | LString s -> text (Printf.sprintf "%S" s)
  | LChar c   -> text (Printf.sprintf "'%s'" c)
  | LBool b   -> text (if b then "True" else "False")
  | LUnit     -> text "()"

(* ── Types ───────────────────────────────────────── *)

let rec print_type t = match t with
  | TyCon n | TyVar n -> text n
  | TyApp (a, b) ->
    (* Type application is left-associative: `Result e a` = `(Result e) a`, so
       the left operand needs no parens even when it is itself a TyApp. *)
    print_type_app_lhs a ^^ text " " ^^ print_type_atom b
  | TyFun (a, b) ->
    print_type_fun_lhs a ^^ text " -> " ^^ print_type b
  | TyTuple ts ->
    text "(" ^^ sep_by (text ", ") (List.map print_type ts) ^^ text ")"
  | TyEffect (es, tail, t) ->
    let inside = match es, tail with
      | _, None    -> sep_by (text ", ") (List.map text es)
      | [], Some v -> text v
      | _,  Some v -> sep_by (text ", ") (List.map text es) ^^ text " | " ^^ text v
    in
    text "<" ^^ inside ^^ text "> " ^^ print_type_atom t
  | TyConstrained (cs, t) ->
    let pp_c (iface, args) =
      text iface ^^ concat (List.map (fun a -> text " " ^^ print_type_atom a) args)
    in
    (match cs with
     | [ c ] -> pp_c c
     | _     -> text "(" ^^ sep_by (text ", ") (List.map pp_c cs) ^^ text ")")
    ^^ text " => " ^^ print_type t

and print_type_atom t = match t with
  | TyCon _ | TyVar _ | TyTuple _ -> print_type t
  | _ -> text "(" ^^ print_type t ^^ text ")"

and print_type_fun_lhs t = match t with
  | TyFun _ -> text "(" ^^ print_type t ^^ text ")"
  | _ -> print_type t

(* Left operand of a TyApp: left-associative, so a nested TyApp prints bare
   (`Result e a`, not `(Result e) a`); anything else parenthesizes as an atom. *)
and print_type_app_lhs t = match t with
  | TyApp _ -> print_type t
  | _ -> print_type_atom t

(* ── Patterns ────────────────────────────────────── *)

let rec print_pat = function
  | PVar x -> text x
  | PWild  -> text "_"
  | PLit l -> print_lit l
  | PCon (c, []) -> text c
  | PCon (c, pats) ->
    text "(" ^^ text c
    ^^ concat (List.map (fun p -> text " " ^^ print_pat_atom p) pats)
    ^^ text ")"
  | PCons (a, b) ->
    print_pat_atom a ^^ text "::" ^^ print_pat b  (* right-assoc *)
  | PTuple ps ->
    text "(" ^^ sep_by (text ", ") (List.map print_pat ps) ^^ text ")"
  | PList ps ->
    text "[" ^^ sep_by (text ", ") (List.map print_pat ps) ^^ text "]"
  | PAs (x, inner) ->
    text x ^^ text "@" ^^ print_pat_atom inner
  | PRec (name, fields, rest) ->
    let field_docs =
      List.map (fun (k, pat_opt) ->
        match pat_opt with
        | None   -> text k
        | Some q -> text k ^^ text " = " ^^ print_pat q
      ) fields
    in
    let all = if rest then field_docs @ [ text "..." ] else field_docs in
    text name ^^ text " { " ^^ sep_by (text ", ") all ^^ text " }"
  | PRng (lo, hi, incl) ->
    print_lit lo ^^ text (if incl then "..=" else "..") ^^ print_lit hi

and print_pat_atom pat = match pat with
  (* PCon with args already self-parenthesizes in print_pat (`(Some x)`), so it
     is atom-safe at any arity; wrapping again would double up: `((Some x))`. *)
  | PVar _ | PWild | PLit _ | PCon _ | PTuple _ | PList _ | PRec _ | PRng _ ->
    print_pat pat
  | _ -> text "(" ^^ print_pat pat ^^ text ")"

(* ── Expressions ─────────────────────────────────── *)

(* Precedence: higher binds tighter. *)
let prec_top     = 0
let prec_pipe    = 1   (* |>  *)
let prec_compose = 2   (* >>  << *)
let prec_or      = 3
let prec_and     = 4
let prec_cmp     = 5
let prec_cons    = 6
let prec_append  = 7
let prec_add     = 8
let prec_mul     = 9
let prec_infix   = 10
let prec_app     = 11
let prec_unary   = 12
let prec_postfix = 13
let prec_atom    = 14

let binop_prec = function
  | "|>"          -> prec_pipe
  | ">>" | "<<"   -> prec_compose
  | "||"          -> prec_or
  | "&&"          -> prec_and
  | "==" | "!=" | "<" | ">" | "<=" | ">=" -> prec_cmp
  | "::"          -> prec_cons
  | "++" | "<>"   -> prec_append
  | "+" | "-"     -> prec_add
  | "*" | "/"     -> prec_mul
  | _             -> prec_infix

let is_right_assoc = function "::" -> true | _ -> false

(* The operators whose chains may break onto continuation lines — kept in sync
   with the lexer's leading-operator continuation rule.  A broken chain leads
   each line with its operator (`xs\n  |> f\n  |> g`), which the lexer rescues. *)
let is_continuation_op = function
  | "|>" | ">>" | "<<" | "&&" | "||" | "++" | "<>" -> true
  | _ -> false

let rec expr_prec = function
  | ELit _ | EVar _ | EMethodRef _ | EDictApp _ | ETuple _ | EArrayLit _ | EListLit _ | EListComp _
  | EMapLit _ | ESetLit _ | EStringInterp _
  | ERecordCreate _ | ERecordUpdate _
  | ERangeList _ | ERangeArray _ | ESlice _ -> prec_atom
  | EFieldAccess _ | EIndex _
  | EQuestion _                        -> prec_postfix
  | EUnOp _                            -> prec_unary
  | EApp _                             -> prec_app
  | EInfix _                           -> prec_infix
  | EBinOp (op, _, _)                  -> binop_prec op
  | ESection _                         -> prec_atom
  | EAsPat _                           -> prec_app
  | ELam _ | ELet _ | ELetGroup _ | EIf _
  | EMatch _ | EBlock _ | EDo (_, _) | EAnnot _ | EHeadAnnot _
  | EFunction _ | EGuards _            -> prec_top
  | ELoc (_, e)                        -> expr_prec e

let rec strip_loc = function ELoc (_, e) -> strip_loc e | e -> e

(* A body whose printed form spans multiple (indented) lines — used to decide
   block vs inline layout for `=` RHSs and `if`/`else` branches. *)
let rec is_block_body = function
  | EMatch _ | EBlock _ | EDo _ | EGuards _ | EFunction _ -> true
  (* An `if` whose branch is a block is itself multi-line, so a `= <if>` RHS
     must put it on its own indented line (else the `else` Hardline breaks to
     the wrong column). *)
  | EIf (_, t, e)    -> is_block_body t || is_block_body e
  | ELoc (_, e)      -> is_block_body e
  | _ -> false

let rec print_expr min_prec e =
  let ep = expr_prec e in
  let d = print_expr_raw e in
  if ep < min_prec then text "(" ^^ d ^^ text ")" else d

and print_expr_raw = function
  | ELit l -> print_lit l
  | EVar n -> text n
  | EMethodRef (_, n) -> text n
  | EDictApp (_, n) -> text n  (* marker-installed; transparent like EMethodRef *)
  | EApp (f, x) ->
    (* Grammar: `expr_app expr_postfix` — an argument is at least postfix-level,
       so a unary operand (e.g. `f (-x)`) must be parenthesized or it reparses
       as a binary operator (`f - x`). *)
    print_expr prec_app f ^^ text " " ^^ print_expr prec_postfix x
  | ELam (pats, body) ->
    sep_by (text " ") (List.map print_pat_atom pats)
    ^^ text " => " ^^ print_expr prec_top body
  | ELet (mut, true, PVar f, rhs, e2) ->
    let rec unwrap_lams acc = function
      | ELam (pats, body) -> unwrap_lams (acc @ pats) body
      | ELoc (_, e)       -> unwrap_lams acc e
      | body              -> (acc, body)
    in
    let (args, body) = unwrap_lams [] rhs in
    text (if mut then "let mut " else "let ") ^^ text f
    ^^ concat (List.map (fun p -> text " " ^^ print_pat_atom p) args)
    ^^ text " = " ^^ print_expr prec_top body
    ^^ text " in " ^^ print_expr prec_top e2
  | ELet (mut, _, pat, e1, e2) ->
    text "let " ^^ (if mut then text "mut " else Nil) ^^ print_pat pat
    ^^ text " = " ^^ print_expr prec_top e1
    ^^ text " in " ^^ print_expr prec_top e2
  | ELetGroup (bindings, body) ->
    let clause name (pats, rhs) =
      Hardline ^^ text name
      ^^ concat (List.map (fun p -> text " " ^^ print_pat_atom p) pats)
      ^^ (match strip_loc rhs with
          | EGuards arms -> print_guard_arms arms
          | _ -> text " = " ^^ print_expr prec_top rhs)
    in
    let clauses =
      concat (List.map (fun (name, cs) ->
        concat (List.map (clause name) cs)) bindings)
    in
    (* Indent clauses two levels (4 spaces at top level) so guarded/block
       bodies nest consistently beneath the `where`. *)
    print_expr prec_top body ^^ text " where" ^^ Nest (4, clauses)
  | EIf (c, t, e) ->
    (* When either branch is a multi-line block body, lay the `if` out with
       `then`/`else` each leading their own (indented) block — the inline form
       would emit an unparseable trailing block.  Mirrors `print_def_rhs`. *)
    if is_block_body t || is_block_body e then
      (* `EBlock` already self-indents (its `print_expr_raw` wraps an
         `indent_block`), so it must not be wrapped a second time — mirrors the
         `EBlock` special-case in `print_def_rhs`. *)
      let branch kw b = match strip_loc b with
        | EBlock _               -> text kw ^^ print_expr_body b
        | b' when is_block_body b' -> text kw ^^ indent_block (print_expr_body b)
        | _                      -> text kw ^^ text " " ^^ print_expr prec_top b
      in
      text "if " ^^ print_expr prec_top c ^^ text " "
      ^^ branch "then" t ^^ Hardline ^^ branch "else" e
    else
      text "if " ^^ print_expr prec_top c
      ^^ text " then " ^^ print_expr prec_top t
      ^^ text " else " ^^ print_expr prec_top e
  | EBinOp (op, l, r) ->
    let prec = binop_prec op in
    let ra = is_right_assoc op in
    print_expr (if ra then prec + 1 else prec) l
    ^^ text " " ^^ text op ^^ text " "
    ^^ print_expr (if ra then prec else prec + 1) r
  | EUnOp (op, e) -> text op ^^ print_expr prec_unary e
  | EFieldAccess (e, f) -> print_expr prec_postfix e ^^ text "." ^^ text f
  | EQuestion e -> print_expr prec_postfix e ^^ text " ?"
  | ERecordCreate (n, fs) ->
    let field (k, v) = text k ^^ text " = " ^^ print_expr prec_top v in
    text n ^^ text " " ^^ braced (List.map field fs)
  | ERecordUpdate (e, fs) ->
    let field (k, v) = text k ^^ text " = " ^^ print_expr prec_top v in
    text "{ " ^^ print_expr prec_top e ^^ text " | "
    ^^ sep_by (text ", ") (List.map field fs) ^^ text " }"
  | EArrayLit es ->
    delimited "[|" "|]" (List.map (print_expr prec_top) es)
  | EListLit es ->
    delimited "[" "]" (List.map (print_expr prec_top) es)
  | EMapLit (n, kvs) ->
    let kv (k, v) = print_expr prec_top k ^^ text " => " ^^ print_expr prec_top v in
    text n ^^ text " { " ^^ sep_by (text ", ") (List.map kv kvs) ^^ text " }"
  | ESetLit (n, es) ->
    text n ^^ text " { "
    ^^ sep_by (text ", ") (List.map (print_expr prec_top) es) ^^ text " }"
  | ETuple es ->
    delimited "(" ")" (List.map (print_expr prec_top) es)
  | EIndex (e, i) ->
    print_expr prec_postfix e ^^ text ".[" ^^ print_expr prec_top i ^^ text "]"
  | EMatch (sc, arms) ->
    text "match " ^^ print_expr prec_top sc ^^ print_match_arms arms
  | EFunction arms ->
    text "function" ^^ print_match_arms arms
  | EGuards arms -> print_guard_arms arms
  | ESection (SecBare op)       -> text "(" ^^ text op ^^ text ")"
  | ESection (SecRight (op, e)) ->
    text "(" ^^ text op ^^ text " " ^^ print_expr prec_top e ^^ text ")"
  | ESection (SecLeft (e, op))  ->
    text "(" ^^ print_expr prec_top e ^^ text " " ^^ text op ^^ text " _)"
  | EAsPat (x, e) ->
    (* Normally lowered to PAs at parse time; printed only if it survives in a
       non-binding position.  prec_atom parenthesizes compound sub-exprs, matching
       the as-pattern atom requirement so it re-parses. *)
    text x ^^ text "@" ^^ print_expr prec_atom e
  | EBlock stmts ->
    (* Bare block: no `do` prefix, just an indented stmt list. *)
    indent_block (sep_by Hardline (List.map print_do_stmt stmts))
  | EDo (_, stmts) ->
    text "do" ^^ indent_block (sep_by Hardline (List.map print_do_stmt stmts))
  | EAnnot (e, t) ->
    print_expr prec_top e ^^ text " : " ^^ print_type t
  | EHeadAnnot (e, _) ->
    (* Compiler-internal (Phase 108): only Desugar produces it, so the
       formatter never sees it — print the inner expr transparently. *)
    print_expr prec_top e
  | EInfix (op, l, r) ->
    print_expr (prec_infix + 1) l
    ^^ text " `" ^^ text op ^^ text "` "
    ^^ print_expr (prec_infix + 1) r
  | EStringInterp parts ->
    text "\""
    ^^ concat (List.map (function
        | InterpStr s  -> text (String.escaped s)
        | InterpExpr e -> text "\\{" ^^ print_expr prec_top e ^^ text "}"
      ) parts)
    ^^ text "\""
  | EListComp (body, quals) ->
    let qual = function
      | LCGen (pat, xs) -> print_pat pat ^^ text " <- " ^^ print_expr prec_top xs
      | LCGuard cond    -> print_expr prec_top cond
      | LCLet (mut, pat, e) ->
        text "let " ^^ (if mut then text "mut " else Nil)
        ^^ print_pat pat ^^ text " = " ^^ print_expr prec_top e
    in
    text "[" ^^ print_expr prec_top body ^^ text " | "
    ^^ sep_by (text ", ") (List.map qual quals) ^^ text "]"
  | ERangeList (lo, hi, incl) ->
    text "[" ^^ print_expr prec_top lo
    ^^ text (if incl then "..=" else "..")
    ^^ print_expr prec_top hi ^^ text "]"
  | ERangeArray (lo, hi, incl) ->
    text "[|" ^^ print_expr prec_top lo
    ^^ text (if incl then "..=" else "..")
    ^^ print_expr prec_top hi ^^ text "|]"
  | ESlice (e, lo, hi, incl) ->
    print_expr prec_postfix e ^^ text ".["
    ^^ print_expr prec_top lo
    ^^ text (if incl then "..=" else "..")
    ^^ print_expr prec_top hi ^^ text "]"
  | ELoc (_, e) -> print_expr_raw e

(* Tail position — the expression is the last thing on its line(s): a function
   or method body, a `let`/bind RHS, a match-arm body, a do-statement.  A
   continuation-operator chain may break here without stranding trailing tokens,
   so it does; a Match/Do uses its natural multi-line layout without parens.

   This is deliberately narrower than the lexer's continuation rule: the lexer
   *accepts* a leading operator after any of the seven triggers (so hand-written
   breaks parse), but the formatter only *introduces* a break in tail position.
   A chain buried in an `if` condition or an argument stays flat — breaking it
   there would orphan the `then …`/remaining tokens onto the operator's line. *)
and print_expr_body e = match e with
  | EMatch _ | EBlock _ | EDo _ -> print_expr_raw e
  | ELoc (_, e')     -> print_expr_body e'
  | EBinOp (op, _, _) when is_continuation_op op -> print_chain op e
  | _ -> print_expr prec_top e

(* Flatten the same-operator left-associative spine into one group so the chain
   breaks all-or-nothing, leading each continuation line with the operator
   (`head\n  |> a\n  |> b`). *)
and print_chain op e =
  let prec = binop_prec op in
  (* peel the left-associative spine: ((a op b) op c) → head a, rights [b; c] *)
  let rec collect acc e = match strip_loc e with
    | EBinOp (op', l, r) when op' = op -> collect ((op', r) :: acc) l
    | head -> (head, acc)
  in
  let (head, rights) = collect [] e in
  let tail =
    concat (List.map (fun (o, r) ->
      Line ^^ text o ^^ text " " ^^ print_expr (prec + 1) r) rights)
  in
  group (Nest (2, print_expr prec head ^^ tail))

(* Shared by EMatch and the `function` keyword: an indented block of
   `pat [if guards] => body` arms. *)
and print_match_arms arms =
  let arm (pat, guards, body) =
    print_pat pat
    ^^ (match guards with
        | [] -> Nil
        | _ ->
          text " if "
          ^^ sep_by (text ", ") (List.map (function
              | GBool g       -> print_expr prec_top g
              | GBind (gp, g) -> print_pat gp ^^ text " <- " ^^ print_expr prec_top g
            ) guards))
    ^^ text " => " ^^ print_expr_body body
  in
  indent_block (sep_by Hardline (List.map arm arms))

(* Function/where guard arms: an indented block of `| guards = body`.  Used as
   a DFunDef / where-clause body, where the `name pats` header is printed by
   the caller (no `=` separator before the arms). *)
and print_guard_arms arms =
  let arm (guards, body) =
    text "| "
    ^^ sep_by (text ", ") (List.map (function
        | GBool g       -> print_expr prec_top g
        | GBind (gp, g) -> print_pat gp ^^ text " <- " ^^ print_expr prec_top g
      ) guards)
    ^^ text " = " ^^ print_expr_body body
  in
  indent_block (sep_by Hardline (List.map arm arms))

and print_do_stmt = function
  | DoBind (pat, e) ->
    print_pat pat ^^ text " <- " ^^ print_expr prec_top e
  | DoExpr e -> print_expr_body e
  | DoLet (mut, pat, e) ->
    text "let " ^^ (if mut then text "mut " else Nil)
    ^^ print_pat pat ^^ text " = " ^^ print_expr prec_top e
  | DoAssign (x, e) ->
    text x ^^ text " = " ^^ print_expr prec_top e
  | DoFieldAssign (x, fields, e) ->
    text x ^^ text "." ^^ text (String.concat "." fields) ^^ text " = " ^^ print_expr prec_top e
  | DoLetElse (pat, e, alt) ->
    text "let " ^^ print_pat pat ^^ text " = " ^^ print_expr prec_top e
    ^^ text " else " ^^ print_expr prec_top alt

(* ── Declarations ────────────────────────────────── *)

(* The RHS of a `<header> = <body>` definition (function clause, impl method,
   prop/bench), with the `=` spaced correctly for the body shape:
   - guard arms print their own `| … = …` block, so there is no leading `=`;
   - a bare block puts `=` at the end of the header line and self-indents the
     body on the next (a trailing `" = "` here would leave a dangling space);
   - other multi-line bodies (match/do/function) need the outer indent_block;
   - a simple expression stays inline after `= `. *)
let print_def_rhs body = match strip_loc body with
  | EGuards arms -> print_guard_arms arms
  | EBlock _     -> text " =" ^^ print_expr_body body
  | _ ->
    text " ="
    ^^ (if is_block_body body then indent_block (print_expr_body body)
        else text " " ^^ print_expr_body body)

let print_use_path = function
  | UseName names -> text (String.concat "." names)
  | UseGroup (names, members) ->
    let member (n, all_ctors) =
      if all_ctors then text n ^^ text "(..)" else text n in
    text (String.concat "." names) ^^ text ".{"
    ^^ sep_by (text ", ") (List.map member members) ^^ text "}"
  | UseWild names ->
    text (String.concat "." names) ^^ text ".*"
  | UseAlias (names, alias) ->
    text (String.concat "." names) ^^ text " as " ^^ text alias

(* A single `data` variant: `Con`, `Con T1 T2`, or `Con { f : T, … }`
   (without the leading `| `). *)
let print_variant v =
  text v.con_name
  ^^ (match v.con_payload with
      | Ast.ConPos tys ->
        concat (List.map (fun t -> text " " ^^ print_type_atom t) tys)
      | Ast.ConNamed fields ->
        let field f =
          text f.Ast.field_name ^^ text " : " ^^ print_type f.Ast.field_type
        in
        text " { " ^^ sep_by (text ", ") (List.map field fields) ^^ text " }")

let print_derives = function
  | []      -> Nil
  | derives -> text "deriving (" ^^ text (String.concat ", " derives) ^^ text ")"

let rec print_decl = function
  | DTypeSig (pub, n, t) ->
    (if pub then text "export\n" else Nil) ^^ text n ^^ text " : " ^^ print_type t

  | DExtern (pub, n, t) ->
    (if pub then text "export " else Nil)
    ^^ text "extern " ^^ text n ^^ text " : " ^^ print_type t

  | DFunDef (pub, n, pats, body) ->
    let header =
      (if pub then text "export " else Nil)
      ^^ text n
      ^^ concat (List.map (fun p -> text " " ^^ print_pat_atom p) pats)
    in
    header ^^ print_def_rhs body

  | DLetGroup (pub, bindings) ->
    let clause first name (pats, body) =
      (if first then text "let rec " else Hardline ^^ text "with ")
      ^^ text name
      ^^ concat (List.map (fun p -> text " " ^^ print_pat_atom p) pats)
      ^^ text " ="
      ^^ (match strip_loc body with
          | EBlock _ -> print_expr_body body
          | _ ->
            if is_block_body body then indent_block (print_expr_body body)
            else text " " ^^ print_expr_body body)
    in
    let first = ref true in
    let docs =
      List.concat_map (fun (name, cs) ->
        List.map (fun c ->
          let d = clause !first name c in
          first := false; d) cs) bindings
    in
    (if pub then text "export " else Nil) ^^ concat docs

  | DData (vis, n, params, variants, derives) ->
    let vis_prefix = match vis with
      | Ast.DataPublic   -> text "public export "
      | Ast.DataAbstract -> text "export "
      | Ast.DataPrivate  -> Nil
    in
    let head =
      text "data " ^^ text n
      ^^ concat (List.map (fun pa -> text " " ^^ text pa) params)
    in
    (* Haskell-style: `=` introduces the first variant, `|` the rest.  All three
       breakable points (the visibility line, the variant separators, and the
       `deriving` clause) share one group, so a `data` that overflows splits
       wholesale into the one-variant-per-line form. *)
    let variant_docs = match variants with
      | [] -> Nil
      | v :: vs ->
        nest ((Line ^^ text "= " ^^ print_variant v)
              ^^ concat (List.map (fun v -> Line ^^ text "| " ^^ print_variant v) vs))
    in
    let derive_doc =
      if derives = [] then Nil else Line ^^ print_derives derives
    in
    group (vis_prefix ^^ head ^^ variant_docs ^^ derive_doc)

  | DRecord (vis, n, params, fields, derives) ->
    let vis_prefix = match vis with
      | Ast.DataPublic   -> text "public export "
      | Ast.DataAbstract -> text "export "
      | Ast.DataPrivate  -> Nil
    in
    let field f =
      text f.field_name ^^ text " : " ^^ print_type f.field_type
    in
    vis_prefix
    ^^ text "record " ^^ text n
    ^^ concat (List.map (fun pa -> text " " ^^ text pa) params)
    ^^ indent_block (sep_by Hardline (List.map field fields))
    ^^ (if derives = [] then Nil
        else Hardline ^^ text "deriving (" ^^ text (String.concat ", " derives) ^^ text ")")

  | DTypeAlias (pub, n, params, rhs) ->
    (if pub then text "export " else Nil)
    ^^ text "type " ^^ text n
    ^^ concat (List.map (fun pa -> text " " ^^ text pa) params)
    ^^ text " = " ^^ print_type rhs

  | DNewtype (pub, n, params, con, fty, derives) ->
    (if pub then text "export " else Nil)
    ^^ text "newtype " ^^ text n
    ^^ concat (List.map (fun pa -> text " " ^^ text pa) params)
    ^^ text " = " ^^ text con ^^ text " " ^^ print_type_atom fty
    ^^ (if derives = [] then Nil
        else text " deriving (" ^^ text (String.concat ", " derives) ^^ text ")")

  | DInterface { is_pub; is_default; iface_name; type_params; super; methods } ->
    let method_doc m =
      text m.method_name
      ^^ (match m.method_default with
          | None -> text " : " ^^ print_type m.method_type
          | Some (pats, body) ->
            concat (List.map (fun p -> text " " ^^ print_pat_atom p) pats)
            ^^ text " = " ^^ print_expr_body body)
    in
    (if is_pub then text "export " else Nil)
    ^^ (if is_default then text "default " else Nil)
    ^^ text "interface " ^^ text iface_name
    ^^ concat (List.map (fun pa -> text " " ^^ text pa) type_params)
    ^^ (match super with
        | [] -> Nil
        | _ ->
          text " requires "
          ^^ sep_by (text ", ") (List.map (fun (n, ps) ->
              text n ^^ concat (List.map (fun pa -> text " " ^^ text pa) ps)) super))
    ^^ text " where"
    ^^ indent_block (sep_by Hardline (List.map method_doc methods))

  | DImpl { is_pub; is_default; iface_name; type_args; impl_name; requires; methods; _ } ->
    let method_doc (n, pats, body) =
      text n
      ^^ concat (List.map (fun p -> text " " ^^ print_pat_atom p) pats)
      ^^ print_def_rhs body
    in
    (if is_pub then text "export " else Nil)
    ^^ (if is_default then text "default " else Nil)
    ^^ text "impl "
    ^^ (match impl_name with
        | None ->
          text iface_name
          ^^ concat (List.map (fun t -> text " " ^^ print_type_atom t) type_args)
        | Some name ->
          text name ^^ text " of " ^^ text iface_name
          ^^ concat (List.map (fun t -> text " " ^^ print_type_atom t) type_args))
    ^^ (match requires with
        | [] -> Nil
        | cs ->
          text " requires "
          ^^ sep_by (text ", ") (List.map (fun (iface, args) ->
              text iface
              ^^ concat (List.map (fun t -> text " " ^^ print_type_atom t) args)) cs))
    ^^ text " where"
    ^^ indent_block (sep_by Hardline (List.map method_doc methods))

  | DUse (pub, path) ->
    (if pub then text "export " else Nil) ^^ text "import " ^^ print_use_path path

  | DProp { is_pub; prop_name; prop_params; prop_body } ->
    (if is_pub then text "export " else Nil)
    ^^ text "prop " ^^ text (Printf.sprintf "%S" prop_name)
    ^^ concat (List.map (fun (x, ty) ->
        text (Printf.sprintf " (%s : %s)" x (Ast.pp_ty ty))) prop_params)
    ^^ print_def_rhs prop_body

  | DBench { is_pub; bench_name; bench_body } ->
    (if is_pub then text "export " else Nil)
    ^^ text "bench " ^^ text (Printf.sprintf "%S" bench_name)
    ^^ print_def_rhs bench_body

  | DAttrib (attrs, inner) ->
    concat (List.map (fun a ->
      (match a with
       | AttrDeprecated msg -> text (Printf.sprintf "@deprecated %S" msg)
       | AttrInline         -> text "@inline"
       | AttrMustUse        -> text "@must_use")
      ^^ text "\n") attrs)
    ^^ print_decl inner

(* ── Public entry points ─────────────────────────── *)

let program_to_string ?(width = default_width) decls =
  String.concat "" (List.map (fun d -> render width (print_decl d) ^ "\n") decls)

let expr_to_string ?(width = default_width) e =
  render width (print_expr prec_top e)

(* ── Comment-preserving formatter ────────────────── *)

(* Format a program, interleaving captured line comments at their original
   source positions.  `decl_locs` is parallel to `decls` (one location per
   top-level declaration, in source order — produced by the parser's
   side-channel; see lib/parser_state.ml).  `comments` is the lexer's
   captured comment list, also in source order.

   If `decl_locs` is empty but `decls` is not, falls back to the plain
   [program_to_string] (no position info available). *)
let format_program ?(width = default_width) decls decl_locs (comments : Lexer.comment list) =
  if List.length decl_locs <> List.length decls then
    program_to_string ~width decls
  else begin
    let buf = Buffer.create 256 in
    let cs = ref comments in
    let cursor = ref 0 in       (* last consumed source line *)
    let started = ref false in
    let blank_line_if_needed target_line =
      if !started && target_line - !cursor >= 2 then
        Buffer.add_char buf '\n'
    in
    let emit_comment (c : Lexer.comment) =
      blank_line_if_needed c.c_line;
      Buffer.add_string buf c.c_text;
      Buffer.add_char buf '\n';
      let nls = String.fold_left (fun n ch -> if ch = '\n' then n + 1 else n) 0 c.c_text in
      cursor := c.c_line + nls;
      started := true
    in
    let flush_before line =
      let rec loop () =
        match !cs with
        | c :: rest when c.c_line < line ->
          cs := rest; emit_comment c; loop ()
        | _ -> ()
      in
      loop ()
    in
    List.iter2 (fun decl (loc : Ast.loc) ->
      flush_before loc.line;
      blank_line_if_needed loc.line;
      Buffer.add_string buf (render width (print_decl decl));
      Buffer.add_char buf '\n';
      cursor := loc.end_line;
      started := true
    ) decls decl_locs;
    flush_before max_int;
    Buffer.contents buf
  end
