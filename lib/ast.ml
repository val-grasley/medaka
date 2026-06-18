type ident = string

type loc = {
  file: string;
  line: int;      (* 1-based start line *)
  col: int;       (* 0-based start column *)
  end_line: int;  (* 1-based end line *)
  end_col: int;   (* 0-based end column *)
}

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
  | TyEffect      of (ident * string option) list * ident option * ty
      (* <IO, Mut | e> t — labels (each w/ optional param pattern, e.g.
         <Net "a.com/*">) + optional tail var.  param=None ⇒ atomic/⊤ label. *)
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
  | PRec   of ident * (ident * pat option) list * bool
             (* PRec("Person", [(field, None=pun | Some pat)], has_rest) *)
  | PRng   of literal * literal * bool   (* lo..hi / lo..=hi in match arms; bool=inclusive *)

(* The impl a method call site resolves to, chosen by the typechecker and
   filled in (in place) into an EMethodRef's ref.  The route tells eval how to
   pick the impl out of the method's VMulti binding:

   - [RKey (key, reqs)]: the discriminating type is *concrete* at this site
     (Phase 69).  `key` is the canonical impl key — `iface | pp_ty(type_args) |
     name` — that eval matches against the key it tags each VMulti candidate
     with, so return-position / multi-param dispatch routes to the impl the
     checker picked.  `reqs` (Phase 83/84 #5) are the routes for *that impl's
     own* `requires` constraints, recursively — so a structured runtime dict
     (`VDict (key, [...])`) can carry the nested element dicts for a recursive
     instance (`def : List (List Int)` → the `List` impl key plus a route for
     its inner `Default (List Int)` requirement, itself the `List` key plus a
     route for `Default Int`).  Empty `[]` for a t-dispatch route (where the
     requires come from `res_impl_dicts` instead) and for an impl with no
     `requires`.
   - [RDict dvar]: the discriminating type is the *enclosing function's*
     constrained type variable (Phase 69.x dictionary passing).  `dvar` is the
     name of the synthetic dictionary parameter that `dict_pass` inserts on that
     function; at runtime it holds a `VDict key`, and eval reads it then selects
     by that key.

   `None` until both passes run; an unfilled ref means eval falls back to
   arg-tag dispatch (genuinely unconstrained-but-runtime-polymorphic code). *)
type res_route =
  | RKey     of string * res_route list
                           (* concrete: select_impl_by_key the literal key; the
                              route list carries the selected impl's own
                              `requires` routes recursively (Phase 83/84 #5,
                              structured dicts), empty for a plain t-route *)
  | RDict    of ident      (* polymorphic: read this synthetic dict-param var *)
  | RHeadKey of string     (* head-concrete (Phase 69.x-c): the discriminating
                              param's head tycon is fixed but its args are free
                              (e.g. `pure x : Result e a`, or a do-block `pure`).
                              eval selects the VMulti candidate whose head tag
                              matches; emitted only for single-param interfaces
                              where the head alone disambiguates. *)
  | RLocal                 (* Phase 112: NOT a method dispatch — at this call
                              site the interface has no impl for the (concrete)
                              receiver, but an explicitly-imported/local
                              standalone function shadows the method name, so
                              eval ignores VMulti dispatch and evaluates the
                              bound name as the plain standalone (no narrowing,
                              no dicts). *)

type resolved = {
  res_iface : ident;
  res_route : res_route;
  (* Phase 69.x-e: dictionaries for the method's *own* method-level constraints
     (e.g. the `Monoid m` in `foldMap : Monoid m => …`), one route per
     constraint in slot order.  Applied by eval as leading arguments to the
     method binding, mirroring EDictApp.  Empty for methods with no method-level
     constraint, and always empty on the untyped path (no marker/typecheck), so
     eval's arg-tag fallback is preserved. *)
  res_method_dicts : res_route list;
  (* Phase 83/84: dictionaries for the *selected impl's* `requires` constraints
     (e.g. the `Arbitrary a` in `impl Arbitrary (List a) requires Arbitrary a`),
     one route per constraint in impl-local slot order.  Applied by eval as
     leading arguments *after* res_method_dicts (matching dict_pass's param
     order: method-level params first, then impl-requires).  Unlike
     res_method_dicts, the count is per-selected-impl, not per-method-name, so a
     ground call site stamps exactly the impl it committed to (e.g. `arbitrary :
     List Tagged` → `[Arbitrary Tagged]`; `arbitrary : Int` → `[]`).  Empty on
     the untyped path. *)
  res_impl_dicts : res_route list;
  (* Phase 83/84 #5: at a *forwarded* (RDict) return-position site — the inner
     `def`/`empty` ref inside a parametric impl body, whose discriminating type is
     a tyvar so the impl (and thus its requires) isn't known statically — eval
     must splice in the *runtime* dict's own `requires` (the structured element
     dicts the caller passed) as the selected impl's requires.  True only for
     return-position RDict sites; false everywhere else (arg-position methods
     dispatch by arg-tag and would be corrupted by extra leading dict args, and
     ground RKey sites carry their requires statically in res_impl_dicts). *)
  res_fwd_requires : bool;
}

(* String interpolation parts *)
type interp_part =
  | InterpStr  of string
  | InterpExpr of expr

(* List comprehension qualifiers *)
and lc_qual =
  | LCGen   of pat * expr          (* x <- xs *)
  | LCGuard of expr                (* boolean guard *)
  | LCLet   of bool * pat * expr   (* let [mut] p = e *)

(* Guard qualifiers (match arms and desugared function/where guards).
   A sequence succeeds when every qualifier does; on failure control
   falls through to the next arm. *)
and guard_qual =
  | GBool of expr                  (* boolean condition *)
  | GBind of pat * expr            (* pat <- expr *)

(* Do-notation statements *)
and do_stmt =
  | DoBind   of pat * expr          (* x <- e *)
  | DoExpr   of expr                (* e *)
  | DoLet    of bool * bool * pat * expr   (* let [mut] [is_fun_def] p = e *)
  | DoAssign      of ident * expr              (* x = e  (only valid when x was let mut) *)
  | DoFieldAssign of ident * ident list * expr (* x.f1.f2…fn = e (mutable record or Ref) *)
  | DoLetElse     of pat * expr * expr         (* let pat = e else diverge *)

and expr =
  | ELit          of literal
  | ENumLit       of int * float option ref * resolved option ref
                     (* PLAN.md #11: a *source* integer literal, polymorphic over
                        `Num a`.  The parser emits this (never `ELit (LInt)`) for
                        an integer in expression position.  typecheck infers a
                        fresh `Num`-obligated var; the post-HM defaulting pass
                        grounds an ambiguous Num-only var to Int; then a side-pass
                        stamps the float ref `Some f` iff the literal's inferred
                        type ground to Float.  `Elaborate`/`Dict_pass` rewrite the
                        node to `ELit (LFloat f)` (float ref = Some f) or
                        `ELit (LInt n)` (both refs None) before eval, so eval
                        never sees `ENumLit`.

                        Soundness fix (numlit-soundness-fromint): when the
                        literal's var survives as a still-quantified `Num a` (e.g.
                        the `1` in `inc x = x + 1`, `inc : Num a => a -> a`), it is
                        NEITHER concrete Int NOR Float — defaulting leaves it free
                        because it reaches an arg.  Then typecheck fills the third
                        `resolved option ref` with the `fromInt` route (RDict onto
                        the enclosing `Num a` dict param), and Dict_pass rewrites
                        the node to `EApp (EMethodRef (route, "fromInt"),
                        ELit (LInt n))` so the runtime Num dict (Int→identity,
                        Float→intToFloat) elaborates the literal — closing the
                        `inc 2.5 ⇒ VInt+VFloat` mixed-tag panic.

                        Rendered identically to `ELit (LInt n)` by printer/astdump
                        so it is invisible to the round-trip and the
                        OCaml↔selfhost sexp diff. *)
  | EVar          of ident
  | EApp          of expr * expr
  | ELam          of pat list * expr                    (* pat+ => body *)
  | ELet          of bool * bool * pat * expr * expr    (* let [mut] [is_fun_def] p = e1 in e2 *)
  | ELetGroup     of (ident * (pat list * expr) list) list * expr  (* mutually-recursive where group; each name has >=1 clauses *)
  | EMatch        of expr * (pat * guard_qual list * expr) list  (* match e; pat [if g1, g2, ...] => e *)
  | EIf           of expr * expr * expr
  | EBinOp        of string * expr * expr * resolved option ref
                     (* Phase 151 / Gap G: comparison/equality operators
                        (== != < > <= >=) carry a dispatch ref, filled by
                        typecheck when the operand type is a *ground non-primitive*
                        with an Eq/Ord impl.  Dict_pass then rewrites the stamped
                        node into the corresponding method application
                        (==→eq, !=→not(eq …), <→lt, …) so every backend dispatches
                        to the user/derived impl.  Stays None for primitive operands
                        and arithmetic/other operators → the structural builtin
                        EBinOp path (unchanged, no recursion). *)
  | EUnOp         of string * expr
  | EFieldAccess  of expr * ident                       (* e.field *)
  | ERecordCreate of ident * (ident * expr) list        (* Person { name = "Alice" } *)
  | ERecordUpdate of expr * (ident * expr) list         (* { p | age = 31 } *)
  | EVariantUpdate of ident * expr * (ident * expr) list (* DImpl { d | tys = ts } *)
  | EArrayLit     of expr list                          (* [|1, 2, 3|] *)
  | EListLit      of expr list                          (* [1, 2, 3] *)
  | EMapLit       of ident * (expr * expr) list         (* Map { k => v, ... } *)
  | ESetLit       of ident * expr list                  (* Set { e, ... } *)
  | ETuple        of expr list                          (* (1, "hello") *)
  | EIndex        of expr * expr                        (* arr[0] *)
  | EBlock        of do_stmt list                       (* bare sequential indented block *)
  | EDo           of string option ref * do_stmt list   (* monadic do-block *)
  | EAnnot        of expr * ty
  | EHeadAnnot    of expr * ty
    (* Phase 108: a *flexible* type pin — like EAnnot but WITHOUT the
       skolemization-by-identity check, so the annotation's type variables may
       ground (e.g. `Map _k _v` where _k/_v become Int).  Pins only the *head*
       tycon of the expression's type.  Created by Desugar.lower_container_literals
       to route `Map { … }` / `Set { … }` literals through the `FromEntries`
       interface at the named output type; never produced by the parser. *)
  | EInfix        of ident * expr * expr                (* x `div` y *)
  | EStringInterp of interp_part list                  (* "text\{expr}text" *)
  | EListComp     of expr * lc_qual list               (* [e | x <- xs, guard, ...] *)
  | EQuestion     of expr                              (* e ? — desugared to andThen in let-RHS position *)
  | ERangeList    of expr * expr * bool                 (* [lo..hi] / [lo..=hi]; bool=inclusive *)
  | ERangeArray   of expr * expr * bool                 (* [|lo..hi|] / [|lo..=hi|]; bool=inclusive *)
  | ESlice        of expr * expr * expr * bool          (* e.[lo..hi] / e.[lo..=hi]; bool=inclusive *)
  | ELoc          of loc * expr                         (* source position; transparent to semantics *)
  | EDoOrigin     of loc * expr                         (* Phase 150: transparent marker wrapping a do-lowered chain; carries the do-block loc so typecheck can emit a tailored "do requires a monad" error. Desugar-introduced, never round-tripped. *)
  | EMethodRef    of resolved option ref * ident         (* interface-method occurrence; ref filled by typecheck (Phase 69) *)
  | EDictApp      of res_route list option ref * ident   (* constrained-function occurrence; routes filled by typecheck (Phase 69.x) *)
  (* Surface-only sugar nodes.  The parser produces these so the formatter can
     round-trip the original syntax; `desugar.ml` lowers them to core nodes
     before resolve/typecheck/eval (which carry `assert false` arms). *)
  | EGuards       of (guard_qual list * expr) list       (* function/where guard arms: `| g.. = body` *)
  | EFunction     of (pat * guard_qual list * expr) list (* `function` keyword: anonymous match on one arg *)
  | ESection      of section                             (* operator section: (op) / (op e) / (e op _) *)
  | EAsPat        of ident * expr                        (* `x@subpat` in a binding LHS; the parser lowers it to PAs via expr_to_pat. Only survives in a non-binding position, where resolve rejects it. *)

and section =
  | SecBare  of string          (* (op)     → \a b => a op b *)
  | SecRight of string * expr   (* (op e)   → \s => s op e   *)
  | SecLeft  of expr * string   (* (e op _) → \s => e op s   *)

type use_path =
  | UseName  of ident list                   (* use utils.greet *)
  | UseGroup of ident list * (ident * bool) list
      (* use utils.{greet, T(..)}; bool = "with all constructors" (Phase 100) *)
  | UseWild  of ident list                   (* use utils.* *)
  | UseAlias of ident list * ident           (* use utils as U *)

type record_field = {
  field_name : ident;
  field_type : ty;
}

type con_payload =
  | ConPos   of ty list
  | ConNamed of record_field list

type data_variant = {
  con_name    : ident;
  con_payload : con_payload;
}

type iface_method = {
  method_name    : ident;
  method_type    : ty;
  method_default : (pat list * expr) option;
}

type data_vis =
  | DataPrivate   (* data T = ...                -- not exported *)
  | DataAbstract  (* export data T = ...         -- type name only *)
  | DataPublic    (* public export data T = ...  -- type + constructors *)

type attr =
  | AttrDeprecated of string   (* @deprecated "reason" *)
  | AttrInline                 (* @inline *)
  | AttrMustUse                (* @must_use *)

type decl =
  | DTypeSig   of bool * ident * ty          (* pub? name type *)
  | DExtern    of bool * ident * ty          (* pub? name type *)
  | DFunDef    of bool * ident * pat list * expr  (* pub? name pats body *)
  | DLetGroup  of bool * (ident * (pat list * expr) list) list
                  (* pub? mutually-recursive top-level group from `let rec ... with ...` *)
  | DData      of data_vis * ident * ident list * data_variant list * ident list  (* vis derives *)
  | DRecord    of data_vis * ident * ident list * record_field list * ident list  (* vis derives *)
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
      impl_loc   : loc option;  (* source loc of the impl decl (Phase 68 coherence
                                   errors); None for desugar-synthesized impls *)
    }
  | DTypeAlias of bool * ident * ident list * ty  (* pub? name params rhs *)
  | DNewtype   of bool * ident * ident list * ident * ty * ident list  (* pub? tyname typarams conname fty derives *)
  | DUse of bool * use_path  (* pub? use path *)
  | DEffect of bool * ident * ident option * bool
      (* pub? name domain? internal?  `effect Foo` (atomic security capability),
         `effect Net Prefix` (domain-carrying), `internal effect Mut`
         (purity-tracking, never granted/parameterized).  v2 Stage 2a:
         domain is Some "Prefix" or None (atomic = Unit). *)
  | DProp of {
      is_pub      : bool;
      prop_name   : string;
      prop_params : (ident * ty) list;
      prop_body   : expr;
    }
  | DTest of {
      is_pub    : bool;
      test_name : string;
      test_body : expr;
    }
  | DBench of {
      is_pub     : bool;
      bench_name : string;
      bench_body : expr;
    }
  | DAttrib of attr list * decl   (* @attr… annotations wrapping the next decl *)

type program = decl list

(* Strip DAttrib wrappers: return the innermost non-DAttrib decl *)
let rec inner_decl = function
  | DAttrib (_, d) -> inner_decl d
  | d -> d

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
  | TyEffect (effs, tail, t) ->
    let pp_atom (l, p) = match p with
      | None -> l
      | Some "_" -> Printf.sprintf "%s _" l   (* v2 Stage 2b inferred hole *)
      | Some s -> Printf.sprintf "%s %S" l s in
    let labs = List.map pp_atom effs in
    let inside = match effs, tail with
      | _, None        -> String.concat ", " labs
      | [], Some v     -> v
      | _,  Some v     -> String.concat ", " labs ^ " | " ^ v
    in
    let s = Printf.sprintf "<%s> %s" inside (pp_ty_prec 0 t) in
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

(* Canonical key identifying one impl, shared by typecheck (which stamps it on
   each resolved [RKey] route) and eval (which tags every VMulti candidate
   with it).  Built from the same source — the impl's AST [type_args] — on both
   sides, so the strings agree by construction.  The optional impl name keeps
   distinct named impls of the same iface/type apart. *)
let impl_key ~(iface : ident) ~(type_args : ty list) ~(name : ident option) : string =
  let tys = String.concat " " (List.map (pp_ty_prec 2) type_args) in
  let nm = match name with Some n -> n | None -> "" in
  iface ^ "|" ^ tys ^ "|" ^ nm

(* Name of the synthetic dictionary parameter that dict_pass prepends to a
   constrained function for its [slot]-th constraint (Phase 69.x).  Shared by
   typecheck (which stamps it as the [RDict] route on polymorphic method/dict
   occurrences inside that function) and dict_pass (which binds it).  Keyed by
   function name + slot so it is unique within a function and never shadows an
   enclosing function's dict param; the `$` prefix can't appear in user source. *)
let dict_param_name (fname : ident) (slot : int) : string =
  Printf.sprintf "$dict_%s_%d" fname slot

let pp_lit = function
  | LInt n    -> string_of_int n
  | LFloat f  ->
    let s = Printf.sprintf "%.12g" f in
    if String.exists (fun c -> c='.'||c='e'||c='E'||c='n'||c='i') s then s else s ^ ".0"
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
  | PRec (name, fields, rest) ->
    let pp_field (k, opt) = match opt with
      | None   -> k
      | Some p -> k ^ " = " ^ pp_pat p
    in
    let parts = List.map pp_field fields @ (if rest then ["..."] else []) in
    Printf.sprintf "%s { %s }" name (String.concat ", " parts)
  | PRng (lo, hi, incl) ->
    Printf.sprintf "%s%s%s" (pp_lit lo) (if incl then "..=" else "..") (pp_lit hi)

let rec pp_expr = function
  | ELit l              -> pp_lit l
  | ENumLit (n, _, _)   -> string_of_int n
  | EVar x              -> x
  | EApp (f, x)         -> Printf.sprintf "(%s %s)" (pp_expr f) (pp_expr x)
  | ELam (ps, e)        -> Printf.sprintf "(%s => %s)" (String.concat " " (List.map pp_pat ps)) (pp_expr e)
  | ELet (mut, _, p, e1, e2) ->
    Printf.sprintf "(let %s%s = %s in %s)"
      (if mut then "mut " else "") (pp_pat p) (pp_expr e1) (pp_expr e2)
  | ELetGroup (bs, e2) ->
    let pp_clause n (pats, body) =
      let ps = if pats = [] then "" else " " ^ String.concat " " (List.map pp_pat pats) in
      Printf.sprintf "%s%s = %s" n ps (pp_expr body) in
    let pp_b (n, clauses) = String.concat "; " (List.map (pp_clause n) clauses) in
    Printf.sprintf "(where [%s] in %s)" (String.concat "; " (List.map pp_b bs)) (pp_expr e2)
  | EMatch (e, arms) ->
    let pp_qual = function
      | GBool ge      -> pp_expr ge
      | GBind (p, ge) -> Printf.sprintf "%s <- %s" (pp_pat p) (pp_expr ge)
    in
    let pp_arm (p, gs, body) =
      let guard = match gs with
        | [] -> ""
        | _  -> Printf.sprintf " if %s" (String.concat ", " (List.map pp_qual gs)) in
      Printf.sprintf "%s%s => %s" (pp_pat p) guard (pp_expr body)
    in
    Printf.sprintf "(match %s %s)" (pp_expr e) (String.concat " | " (List.map pp_arm arms))
  | EIf (c, t, e)       -> Printf.sprintf "(if %s then %s else %s)" (pp_expr c) (pp_expr t) (pp_expr e)
  | EBinOp (op, l, r, _) -> Printf.sprintf "(%s %s %s)" (pp_expr l) op (pp_expr r)
  | EUnOp (op, e)        -> Printf.sprintf "(%s%s)" op (pp_expr e)
  | EFieldAccess (e, f)  -> Printf.sprintf "%s.%s" (pp_expr e) f
  | ERecordCreate (n, fs) ->
    let pp_f (k, v) = Printf.sprintf "%s = %s" k (pp_expr v) in
    Printf.sprintf "%s { %s }" n (String.concat ", " (List.map pp_f fs))
  | ERecordUpdate (e, fs) ->
    let pp_f (k, v) = Printf.sprintf "%s = %s" k (pp_expr v) in
    Printf.sprintf "{ %s | %s }" (pp_expr e) (String.concat ", " (List.map pp_f fs))
  | EVariantUpdate (c, e, fs) ->
    let pp_f (k, v) = Printf.sprintf "%s = %s" k (pp_expr v) in
    Printf.sprintf "%s { %s | %s }" c (pp_expr e) (String.concat ", " (List.map pp_f fs))
  | EArrayLit es         -> Printf.sprintf "[|%s|]" (String.concat ", " (List.map pp_expr es))
  | EListLit es          -> Printf.sprintf "[%s]" (String.concat ", " (List.map pp_expr es))
  | EMapLit (n, kvs)     ->
    let pp_kv (k, v) = Printf.sprintf "%s => %s" (pp_expr k) (pp_expr v) in
    Printf.sprintf "%s { %s }" n (String.concat ", " (List.map pp_kv kvs))
  | ESetLit (n, es)      -> Printf.sprintf "%s { %s }" n (String.concat ", " (List.map pp_expr es))
  | ETuple es            -> Printf.sprintf "(%s)" (String.concat ", " (List.map pp_expr es))
  | EIndex (e, i)        -> Printf.sprintf "%s[%s]" (pp_expr e) (pp_expr i)
  | EBlock stmts         -> Printf.sprintf "(block %s)" (String.concat "; " (List.map pp_do_stmt stmts))
  | EDo (_, stmts)       -> Printf.sprintf "(do %s)" (String.concat "; " (List.map pp_do_stmt stmts))
  | EAnnot (e, t)        -> Printf.sprintf "(%s : %s)" (pp_expr e) (pp_ty t)
  | EHeadAnnot (e, t)    -> Printf.sprintf "(%s :~ %s)" (pp_expr e) (pp_ty t)
  | EInfix (op, l, r)    -> Printf.sprintf "(%s `%s` %s)" (pp_expr l) op (pp_expr r)
  | EStringInterp parts  ->
    let pp_part = function
      | InterpStr s  -> String.escaped s
      | InterpExpr e -> "\\{" ^ pp_expr e ^ "}"
    in
    Printf.sprintf "\"%s\"" (String.concat "" (List.map pp_part parts))
  | EListComp (body, quals) ->
    let pp_qual = function
      | LCGen (p, e)    -> Printf.sprintf "%s <- %s" (pp_pat p) (pp_expr e)
      | LCGuard e       -> pp_expr e
      | LCLet (m, p, e) -> Printf.sprintf "let %s%s = %s" (if m then "mut " else "") (pp_pat p) (pp_expr e)
    in
    Printf.sprintf "[%s | %s]" (pp_expr body) (String.concat ", " (List.map pp_qual quals))
  | EQuestion e          -> Printf.sprintf "(%s ?)" (pp_expr e)
  | ERangeList (lo, hi, incl) ->
    Printf.sprintf "[%s%s%s]" (pp_expr lo) (if incl then "..=" else "..") (pp_expr hi)
  | ERangeArray (lo, hi, incl) ->
    Printf.sprintf "[|%s%s%s|]" (pp_expr lo) (if incl then "..=" else "..") (pp_expr hi)
  | ESlice (e, lo, hi, incl) ->
    Printf.sprintf "%s.[%s%s%s]" (pp_expr e) (pp_expr lo) (if incl then "..=" else "..") (pp_expr hi)
  | ELoc (_, e)          -> pp_expr e
  | EDoOrigin (_, e)     -> pp_expr e
  | EMethodRef (_, x)    -> x
  | EDictApp (_, x)      -> x
  | EGuards arms ->
    let pp_qual = function
      | GBool ge      -> pp_expr ge
      | GBind (p, ge) -> Printf.sprintf "%s <- %s" (pp_pat p) (pp_expr ge)
    in
    let pp_arm (gs, body) =
      Printf.sprintf "| %s = %s"
        (String.concat ", " (List.map pp_qual gs)) (pp_expr body)
    in
    Printf.sprintf "(guards %s)" (String.concat " " (List.map pp_arm arms))
  | EFunction arms ->
    let pp_qual = function
      | GBool ge      -> pp_expr ge
      | GBind (p, ge) -> Printf.sprintf "%s <- %s" (pp_pat p) (pp_expr ge)
    in
    let pp_arm (p, gs, body) =
      let guard = match gs with
        | [] -> ""
        | _  -> Printf.sprintf " if %s" (String.concat ", " (List.map pp_qual gs)) in
      Printf.sprintf "%s%s => %s" (pp_pat p) guard (pp_expr body)
    in
    Printf.sprintf "(function %s)" (String.concat " | " (List.map pp_arm arms))
  | ESection (SecBare op)       -> Printf.sprintf "(%s)" op
  | ESection (SecRight (op, e)) -> Printf.sprintf "(%s %s)" op (pp_expr e)
  | ESection (SecLeft (e, op))  -> Printf.sprintf "(%s %s _)" (pp_expr e) op
  | EAsPat (x, e)               -> Printf.sprintf "%s@%s" x (pp_expr e)

and pp_do_stmt = function
  | DoBind (p, e)       -> Printf.sprintf "%s <- %s" (pp_pat p) (pp_expr e)
  | DoExpr e            -> pp_expr e
  | DoLet (mut, _, p, e)   ->
    Printf.sprintf "let %s%s = %s" (if mut then "mut " else "") (pp_pat p) (pp_expr e)
  | DoAssign (x, e)          -> Printf.sprintf "%s = %s" x (pp_expr e)
  | DoFieldAssign (x, fs, e) -> Printf.sprintf "%s.%s = %s" x (String.concat "." fs) (pp_expr e)
  | DoLetElse (p, e, alt)   -> Printf.sprintf "let %s = %s else %s" (pp_pat p) (pp_expr e) (pp_expr alt)

(* Strip all ELoc annotations from an expression/program — used by round-trip
   tests so that position metadata doesn't break structural equality. *)
let rec strip_locs_expr = function
  | ELoc (_, e)            -> strip_locs_expr e
  | EDoOrigin (_, e)       -> strip_locs_expr e
  | EApp (f, x)            -> EApp (strip_locs_expr f, strip_locs_expr x)
  | ELam (ps, e)           -> ELam (ps, strip_locs_expr e)
  | ELet (m, f, p, e1, e2) -> ELet (m, f, p, strip_locs_expr e1, strip_locs_expr e2)
  | ELetGroup (bs, e)     ->
    ELetGroup (List.map (fun (n, clauses) ->
      (n, List.map (fun (ps, body) -> (ps, strip_locs_expr body)) clauses)) bs,
      strip_locs_expr e)
  | EMatch (e, arms)       ->
    let strip_qual = function
      | GBool ge      -> GBool (strip_locs_expr ge)
      | GBind (p, ge) -> GBind (p, strip_locs_expr ge)
    in
    EMatch (strip_locs_expr e,
            List.map (fun (p, gs, b) -> (p, List.map strip_qual gs, strip_locs_expr b)) arms)
  | EIf (c, t, e)         -> EIf (strip_locs_expr c, strip_locs_expr t, strip_locs_expr e)
  | EBinOp (op, l, r, dr) -> EBinOp (op, strip_locs_expr l, strip_locs_expr r, dr)
  | EUnOp (op, e)         -> EUnOp (op, strip_locs_expr e)
  | EFieldAccess (e, f)   -> EFieldAccess (strip_locs_expr e, f)
  | ERecordCreate (n, fs) -> ERecordCreate (n, List.map (fun (k, v) -> (k, strip_locs_expr v)) fs)
  | ERecordUpdate (e, fs) -> ERecordUpdate (strip_locs_expr e, List.map (fun (k, v) -> (k, strip_locs_expr v)) fs)
  | EVariantUpdate (c, e, fs) -> EVariantUpdate (c, strip_locs_expr e, List.map (fun (k, v) -> (k, strip_locs_expr v)) fs)
  | EArrayLit es          -> EArrayLit (List.map strip_locs_expr es)
  | EListLit es           -> EListLit (List.map strip_locs_expr es)
  | EMapLit (n, kvs)      -> EMapLit (n, List.map (fun (k, v) -> (strip_locs_expr k, strip_locs_expr v)) kvs)
  | ESetLit (n, es)       -> ESetLit (n, List.map strip_locs_expr es)
  | ETuple es             -> ETuple (List.map strip_locs_expr es)
  | EIndex (e, i)         -> EIndex (strip_locs_expr e, strip_locs_expr i)
  | EBlock stmts          -> EBlock (List.map strip_locs_do stmts)
  | EDo (_, stmts)        -> EDo (ref None, List.map strip_locs_do stmts)
  | EAnnot (e, t)         -> EAnnot (strip_locs_expr e, t)
  | EHeadAnnot (e, t)     -> EHeadAnnot (strip_locs_expr e, t)
  | EInfix (op, l, r)    -> EInfix (op, strip_locs_expr l, strip_locs_expr r)
  | EStringInterp parts  ->
    EStringInterp (List.map (function
      | InterpStr s  -> InterpStr s
      | InterpExpr e -> InterpExpr (strip_locs_expr e)
    ) parts)
  | EListComp (body, quals) ->
    EListComp (strip_locs_expr body, List.map (function
      | LCGen (p, e)    -> LCGen (p, strip_locs_expr e)
      | LCGuard e       -> LCGuard (strip_locs_expr e)
      | LCLet (m, p, e) -> LCLet (m, p, strip_locs_expr e)
    ) quals)
  | EQuestion e           -> EQuestion (strip_locs_expr e)
  | ERangeList  (lo, hi, incl) -> ERangeList  (strip_locs_expr lo, strip_locs_expr hi, incl)
  | ERangeArray (lo, hi, incl) -> ERangeArray (strip_locs_expr lo, strip_locs_expr hi, incl)
  | ESlice      (e, lo, hi, incl) -> ESlice (strip_locs_expr e, strip_locs_expr lo, strip_locs_expr hi, incl)
  | EGuards arms ->
    let strip_qual = function
      | GBool ge      -> GBool (strip_locs_expr ge)
      | GBind (p, ge) -> GBind (p, strip_locs_expr ge)
    in
    EGuards (List.map (fun (gs, b) ->
      (List.map strip_qual gs, strip_locs_expr b)) arms)
  | EFunction arms ->
    let strip_qual = function
      | GBool ge      -> GBool (strip_locs_expr ge)
      | GBind (p, ge) -> GBind (p, strip_locs_expr ge)
    in
    EFunction (List.map (fun (p, gs, b) ->
      (p, List.map strip_qual gs, strip_locs_expr b)) arms)
  | ESection (SecRight (op, e)) -> ESection (SecRight (op, strip_locs_expr e))
  | ESection (SecLeft (e, op))  -> ESection (SecLeft (strip_locs_expr e, op))
  | ESection (SecBare _) as e   -> e
  | EAsPat (x, e)               -> EAsPat (x, strip_locs_expr e)
  | e                     -> e  (* ELit, EVar *)

and strip_locs_do = function
  | DoBind (p, e)     -> DoBind (p, strip_locs_expr e)
  | DoExpr e          -> DoExpr (strip_locs_expr e)
  | DoLet (m, r, p, e)  -> DoLet (m, r, p, strip_locs_expr e)
  | DoAssign (x, e)         -> DoAssign (x, strip_locs_expr e)
  | DoFieldAssign (x, fs, e) -> DoFieldAssign (x, fs, strip_locs_expr e)
  | DoLetElse (p, e, alt)   -> DoLetElse (p, strip_locs_expr e, strip_locs_expr alt)

let strip_locs_iface_method m =
  match m.method_default with
  | None -> m
  | Some (ps, e) -> { m with method_default = Some (ps, strip_locs_expr e) }

let rec strip_locs_decl = function
  | DFunDef (pub, n, ps, e) -> DFunDef (pub, n, ps, strip_locs_expr e)
  | DLetGroup (pub, bs) ->
    DLetGroup (pub, List.map (fun (n, clauses) ->
      (n, List.map (fun (ps, body) -> (ps, strip_locs_expr body)) clauses)) bs)
  | DInterface d ->
    DInterface { d with methods = List.map strip_locs_iface_method d.methods }
  | DImpl d ->
    DImpl { d with
            impl_loc = None;  (* source position; not part of structural identity *)
            methods = List.map (fun (n, ps, e) -> (n, ps, strip_locs_expr e)) d.methods }
  | DProp d -> DProp { d with prop_body = strip_locs_expr d.prop_body }
  | DTest d -> DTest { d with test_body = strip_locs_expr d.test_body }
  | DBench d -> DBench { d with bench_body = strip_locs_expr d.bench_body }
  | DAttrib (attrs, d) -> DAttrib (attrs, strip_locs_decl d)
  | d -> d

let strip_locs_program = List.map strip_locs_decl
