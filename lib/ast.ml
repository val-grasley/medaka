type ident = string

type loc = { file: string; line: int; col: int }

type literal =
  | LInt    of int
  | LFloat  of float
  | LString of string
  | LChar   of string  (* grapheme cluster *)
  | LBool   of bool
  | LUnit

(* Types *)
type ty =
  | TyCon    of ident            (* Int, String, Bool *)
  | TyVar    of ident            (* a, b *)
  | TyApp    of ty * ty          (* List a, Option a *)
  | TyFun    of ty * ty          (* a -> b *)
  | TyTuple  of ty list          (* (Int, String) *)
  | TyEffect      of ident list * ty       (* <IO, Mut> t *)
  | TyConstrained of (ident * ty list) list * ty  (* [(Iface, args); ...] => ty *)

(* Patterns *)
type pat =
  | PVar   of ident              (* x *)
  | PWild                        (* _ *)
  | PLit   of literal            (* 1, "hello" *)
  | PCon   of ident * pat list   (* Some x, Circle r *)
  | PCons  of pat * pat          (* x::xs *)
  | PTuple of pat list           (* (x, y) *)
  | PList  of pat list           (* [x, y, z] *)
  | PAs    of ident * pat        (* x@pat *)

(* String interpolation parts *)
type interp_part =
  | InterpStr  of string
  | InterpExpr of expr

(* Do-notation statements *)
and do_stmt =
  | DoBind   of pat * expr          (* x <- e *)
  | DoExpr   of expr                (* e *)
  | DoLet    of bool * pat * expr   (* let [mut] p = e *)
  | DoAssign of ident * expr        (* x = e  (only valid when x was let mut) *)

and expr =
  | ELit          of literal
  | EVar          of ident
  | EApp          of expr * expr
  | ELam          of pat list * expr                    (* pat+ => body *)
  | ELet          of bool * pat * expr * expr           (* let [mut] p = e1 in e2 *)
  | EMatch        of expr * (pat * expr option * expr) list  (* match e; pat [if g] => e *)
  | EIf           of expr * expr * expr
  | EBinOp        of string * expr * expr
  | EUnOp         of string * expr
  | EFieldAccess  of expr * ident                       (* e.field *)
  | ERecordCreate of ident * (ident * expr) list        (* Person { name = "Alice" } *)
  | ERecordUpdate of expr * (ident * expr) list         (* { p | age = 31 } *)
  | EArrayLit     of expr list                          (* [|1, 2, 3|] *)
  | EListLit      of expr list                          (* [1, 2, 3] *)
  | EMapLit       of ident * (expr * expr) list         (* Map { k => v, ... } *)
  | ESetLit       of ident * expr list                  (* Set { e, ... } *)
  | ETuple        of expr list                          (* (1, "hello") *)
  | EIndex        of expr * expr                        (* arr[0] *)
  | EDo           of do_stmt list
  | EAnnot        of expr * ty
  | EInfix        of ident * expr * expr                (* x `div` y *)
  | EStringInterp of interp_part list                  (* "text\{expr}text" *)
  | ELoc          of loc * expr                         (* source position; transparent to semantics *)

type use_path =
  | UseName  of ident list                   (* use utils.greet *)
  | UseGroup of ident list * ident list      (* use utils.{greet, helper} *)
  | UseWild  of ident list                   (* use utils.* *)
  | UseAlias of ident list * ident           (* use utils as U *)

type data_variant = {
  con_name   : ident;
  con_fields : ty list;
}

type record_field = {
  field_name : ident;
  field_type : ty;
}

type iface_method = {
  method_name    : ident;
  method_type    : ty;
  method_default : (pat list * expr) option;
}

type decl =
  | DTypeSig   of bool * ident * ty          (* pub? name type *)
  | DExtern    of bool * ident * ty          (* pub? name type *)
  | DFunDef    of bool * ident * pat list * expr  (* pub? name pats body *)
  | DData      of bool * ident * ident list * data_variant list * ident list  (* pub? derives *)
  | DRecord    of bool * ident * ident list * record_field list * ident list  (* pub? derives *)
  | DInterface of {
      is_pub      : bool;
      is_default  : bool;
      iface_name  : ident;
      type_params : ident list;
      super       : (ident * ident list) list;
      methods     : iface_method list;
    }
  | DImpl of {
      is_pub     : bool;
      is_default : bool;
      iface_name : ident;
      type_args  : ty list;
      impl_name  : ident option;
      requires   : (ident * ty list) list;  (* e.g. requires Eq a, Ord b *)
      methods    : (ident * pat list * expr) list;
    }
  | DTypeAlias of bool * ident * ident list * ty  (* pub? name params rhs *)
  | DNewtype   of bool * ident * ident list * ident * ty * ident list  (* pub? tyname typarams conname fty derives *)
  | DUse of bool * use_path  (* pub? use path *)

type program = decl list

type repl_item = ReplDecl of decl list | ReplExpr of expr

(* Pretty-printing helpers *)
(* Precedence-aware type printer.
   0 = top level / no wrap
   1 = arrow lhs / app head (wrap arrows)
   2 = app arg (wrap arrows and applications) *)
let rec pp_ty_prec p = function
  | TyCon s         -> s
  | TyVar s         -> s
  | TyTuple ts      -> Printf.sprintf "(%s)" (String.concat ", " (List.map (pp_ty_prec 0) ts))
  | TyApp (f, x)    ->
    let s = Printf.sprintf "%s %s" (pp_ty_prec 1 f) (pp_ty_prec 2 x) in
    if p >= 2 then "(" ^ s ^ ")" else s
  | TyFun (a, b)    ->
    let s = Printf.sprintf "%s -> %s" (pp_ty_prec 1 a) (pp_ty_prec 0 b) in
    if p >= 1 then "(" ^ s ^ ")" else s
  | TyEffect (effs, t) ->
    let s = Printf.sprintf "<%s> %s" (String.concat ", " effs) (pp_ty_prec 0 t) in
    if p >= 1 then "(" ^ s ^ ")" else s
  | TyConstrained (cs, t) ->
    let pp_c (iface, args) =
      if args = [] then iface
      else Printf.sprintf "%s %s" iface (String.concat " " (List.map (pp_ty_prec 2) args))
    in
    let cs_str = match cs with
      | [c] -> pp_c c
      | _   -> Printf.sprintf "(%s)" (String.concat ", " (List.map pp_c cs))
    in
    Printf.sprintf "%s => %s" cs_str (pp_ty_prec 0 t)

let pp_ty t = pp_ty_prec 0 t

let pp_lit = function
  | LInt n    -> string_of_int n
  | LFloat f  -> string_of_float f
  | LString s -> Printf.sprintf "%S" s
  | LChar c   -> Printf.sprintf "'%s'" c
  | LBool b   -> string_of_bool b
  | LUnit     -> "()"

let rec pp_pat = function
  | PVar x          -> x
  | PWild           -> "_"
  | PLit l          -> pp_lit l
  | PCon (c, [])    -> c
  | PCon (c, ps)    -> Printf.sprintf "(%s %s)" c (String.concat " " (List.map pp_pat ps))
  | PCons (h, t)    -> Printf.sprintf "(%s::%s)" (pp_pat h) (pp_pat t)
  | PTuple ps       -> Printf.sprintf "(%s)" (String.concat ", " (List.map pp_pat ps))
  | PList ps        -> Printf.sprintf "[%s]" (String.concat ", " (List.map pp_pat ps))
  | PAs (x, p)      -> Printf.sprintf "%s@%s" x (pp_pat p)

let rec pp_expr = function
  | ELit l              -> pp_lit l
  | EVar x              -> x
  | EApp (f, x)         -> Printf.sprintf "(%s %s)" (pp_expr f) (pp_expr x)
  | ELam (ps, e)        -> Printf.sprintf "(%s => %s)" (String.concat " " (List.map pp_pat ps)) (pp_expr e)
  | ELet (mut, p, e1, e2) ->
    Printf.sprintf "(let %s%s = %s in %s)"
      (if mut then "mut " else "") (pp_pat p) (pp_expr e1) (pp_expr e2)
  | EMatch (e, arms) ->
    let pp_arm (p, g, body) =
      let guard = match g with None -> "" | Some ge -> Printf.sprintf " if %s" (pp_expr ge) in
      Printf.sprintf "%s%s => %s" (pp_pat p) guard (pp_expr body)
    in
    Printf.sprintf "(match %s %s)" (pp_expr e) (String.concat " | " (List.map pp_arm arms))
  | EIf (c, t, e)       -> Printf.sprintf "(if %s then %s else %s)" (pp_expr c) (pp_expr t) (pp_expr e)
  | EBinOp (op, l, r)   -> Printf.sprintf "(%s %s %s)" (pp_expr l) op (pp_expr r)
  | EUnOp (op, e)        -> Printf.sprintf "(%s%s)" op (pp_expr e)
  | EFieldAccess (e, f)  -> Printf.sprintf "%s.%s" (pp_expr e) f
  | ERecordCreate (n, fs) ->
    let pp_f (k, v) = Printf.sprintf "%s = %s" k (pp_expr v) in
    Printf.sprintf "%s { %s }" n (String.concat ", " (List.map pp_f fs))
  | ERecordUpdate (e, fs) ->
    let pp_f (k, v) = Printf.sprintf "%s = %s" k (pp_expr v) in
    Printf.sprintf "{ %s | %s }" (pp_expr e) (String.concat ", " (List.map pp_f fs))
  | EArrayLit es         -> Printf.sprintf "[|%s|]" (String.concat ", " (List.map pp_expr es))
  | EListLit es          -> Printf.sprintf "[%s]" (String.concat ", " (List.map pp_expr es))
  | EMapLit (n, kvs)     ->
    let pp_kv (k, v) = Printf.sprintf "%s => %s" (pp_expr k) (pp_expr v) in
    Printf.sprintf "%s { %s }" n (String.concat ", " (List.map pp_kv kvs))
  | ESetLit (n, es)      -> Printf.sprintf "%s { %s }" n (String.concat ", " (List.map pp_expr es))
  | ETuple es            -> Printf.sprintf "(%s)" (String.concat ", " (List.map pp_expr es))
  | EIndex (e, i)        -> Printf.sprintf "%s[%s]" (pp_expr e) (pp_expr i)
  | EDo stmts            -> Printf.sprintf "(do %s)" (String.concat "; " (List.map pp_do_stmt stmts))
  | EAnnot (e, t)        -> Printf.sprintf "(%s : %s)" (pp_expr e) (pp_ty t)
  | EInfix (op, l, r)    -> Printf.sprintf "(%s `%s` %s)" (pp_expr l) op (pp_expr r)
  | EStringInterp parts  ->
    let pp_part = function
      | InterpStr s  -> String.escaped s
      | InterpExpr e -> "\\{" ^ pp_expr e ^ "}"
    in
    Printf.sprintf "\"%s\"" (String.concat "" (List.map pp_part parts))
  | ELoc (_, e)          -> pp_expr e

and pp_do_stmt = function
  | DoBind (p, e)       -> Printf.sprintf "%s <- %s" (pp_pat p) (pp_expr e)
  | DoExpr e            -> pp_expr e
  | DoLet (mut, p, e)   ->
    Printf.sprintf "let %s%s = %s" (if mut then "mut " else "") (pp_pat p) (pp_expr e)
  | DoAssign (x, e)     -> Printf.sprintf "%s = %s" x (pp_expr e)

(* Strip all ELoc annotations from an expression/program — used by round-trip
   tests so that position metadata doesn't break structural equality. *)
let rec strip_locs_expr = function
  | ELoc (_, e)            -> strip_locs_expr e
  | EApp (f, x)            -> EApp (strip_locs_expr f, strip_locs_expr x)
  | ELam (ps, e)           -> ELam (ps, strip_locs_expr e)
  | ELet (m, p, e1, e2)   -> ELet (m, p, strip_locs_expr e1, strip_locs_expr e2)
  | EMatch (e, arms)       ->
    EMatch (strip_locs_expr e,
            List.map (fun (p, g, b) -> (p, Option.map strip_locs_expr g, strip_locs_expr b)) arms)
  | EIf (c, t, e)         -> EIf (strip_locs_expr c, strip_locs_expr t, strip_locs_expr e)
  | EBinOp (op, l, r)     -> EBinOp (op, strip_locs_expr l, strip_locs_expr r)
  | EUnOp (op, e)         -> EUnOp (op, strip_locs_expr e)
  | EFieldAccess (e, f)   -> EFieldAccess (strip_locs_expr e, f)
  | ERecordCreate (n, fs) -> ERecordCreate (n, List.map (fun (k, v) -> (k, strip_locs_expr v)) fs)
  | ERecordUpdate (e, fs) -> ERecordUpdate (strip_locs_expr e, List.map (fun (k, v) -> (k, strip_locs_expr v)) fs)
  | EArrayLit es          -> EArrayLit (List.map strip_locs_expr es)
  | EListLit es           -> EListLit (List.map strip_locs_expr es)
  | EMapLit (n, kvs)      -> EMapLit (n, List.map (fun (k, v) -> (strip_locs_expr k, strip_locs_expr v)) kvs)
  | ESetLit (n, es)       -> ESetLit (n, List.map strip_locs_expr es)
  | ETuple es             -> ETuple (List.map strip_locs_expr es)
  | EIndex (e, i)         -> EIndex (strip_locs_expr e, strip_locs_expr i)
  | EDo stmts             -> EDo (List.map strip_locs_do stmts)
  | EAnnot (e, t)         -> EAnnot (strip_locs_expr e, t)
  | EInfix (op, l, r)    -> EInfix (op, strip_locs_expr l, strip_locs_expr r)
  | EStringInterp parts  ->
    EStringInterp (List.map (function
      | InterpStr s  -> InterpStr s
      | InterpExpr e -> InterpExpr (strip_locs_expr e)
    ) parts)
  | e                     -> e  (* ELit, EVar *)

and strip_locs_do = function
  | DoBind (p, e)     -> DoBind (p, strip_locs_expr e)
  | DoExpr e          -> DoExpr (strip_locs_expr e)
  | DoLet (m, p, e)  -> DoLet (m, p, strip_locs_expr e)
  | DoAssign (x, e)  -> DoAssign (x, strip_locs_expr e)

let strip_locs_iface_method m =
  match m.method_default with
  | None -> m
  | Some (ps, e) -> { m with method_default = Some (ps, strip_locs_expr e) }

let strip_locs_decl = function
  | DFunDef (pub, n, ps, e) -> DFunDef (pub, n, ps, strip_locs_expr e)
  | DInterface d ->
    DInterface { d with methods = List.map strip_locs_iface_method d.methods }
  | DImpl d ->
    DImpl { d with methods = List.map (fun (n, ps, e) -> (n, ps, strip_locs_expr e)) d.methods }
  | d -> d

let strip_locs_program = List.map strip_locs_decl
