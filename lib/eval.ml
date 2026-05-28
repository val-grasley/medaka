open Ast

(* ── Value type ──────────────────────────────────────────────────────────── *)

type value =
  | VInt    of int
  | VFloat  of float
  | VString of string
  | VChar   of string
  | VBool   of bool
  | VUnit
  | VTuple  of value list
  | VList   of value list
  | VArray  of value array
  | VCon    of string * value list
  | VRecord of string * (string * value) list
                                  (* type_name, fields.  The type name is
                                     used by runtime_type_tag so that VMulti
                                     dispatch on a method like `show` can
                                     route through to the right impl when
                                     multiple candidates exist. *)
  | VRef    of value ref
  | VClosure of env * pat list * expr
  | VPrim   of (value -> value)
  | VMulti  of value list  (* ordered impl closures for the same method; tried in sequence *)
  | VThunk  of value Lazy.t  (* deferred top-level zero-param binding; forced on first lookup *)
  | VNamedImpl of string * value  (* impl closure tagged with its declared name *)
  | VTypedImpl of string * int list * int * value
      (* impl method: (tag, dispatch_positions, args_seen, inner).
         `tag`  is the impl's head type-ctor name (e.g. "List" for Foldable List).
         `dispatch_positions` is the set of argument indices whose runtime type
            actually determines impl selection, computed from the interface
            method's type signature.  For `fold : (b -> a -> b) -> b -> t a -> b`
            of `Foldable t`, only position 2 mentions `t`, so positions = [2].
         `args_seen` is the number of args already applied to this impl method.
            VMulti's tag-filter only fires when `args_seen ∈ dispatch_positions`;
            other arg slots (like fold's accumulator) pass through untouched.
            An empty `dispatch_positions` (e.g. `pure : a -> f a`) means no
            positional dispatch is possible from arguments alone. *)

and env = (string * value ref) list list

exception Eval_error of string * loc option
(* Raised instead of Eval_error when a pattern/match fails during dispatch so
   that VMulti.apply can silently fall through to the next impl candidate. *)
exception Impl_no_match

let output_hook : (string -> unit) ref = ref print_string

let snapshot_dir    : string ref = ref "snapshots"
let snapshot_update : bool ref   = ref false

(* ── Env helpers ─────────────────────────────────────────────────────────── *)

let lookup env name =
  let rec search = function
    | [] -> raise (Eval_error ("unbound identifier: " ^ name, None))
    | frame :: rest ->
      (match List.assoc_opt name frame with
       | Some cell ->
         (match !cell with
          | VThunk t ->
            let v = Lazy.force t in
            cell := v;
            v
          | v -> v)
       | None -> search rest)
  in search env

let extend env binds =
  (List.map (fun (k, v) -> (k, ref v)) binds) :: env

(* ── Pretty-print values ─────────────────────────────────────────────────── *)

let rec pp_value = function
  | VInt n    -> string_of_int n
  | VFloat f  ->
    let s = string_of_float f in
    if String.contains s '.' || String.contains s 'e' then s else s ^ ".0"
  | VString s -> s
  | VChar c   -> c
  | VBool b   -> string_of_bool b
  | VUnit     -> "()"
  | VTuple vs -> "(" ^ String.concat ", " (List.map pp_value vs) ^ ")"
  | VList vs  -> "[" ^ String.concat ", " (List.map pp_value vs) ^ "]"
  | VArray vs ->
    "[|" ^ String.concat ", " (Array.to_list (Array.map pp_value vs)) ^ "|]"
  | VCon (name, []) -> name
  | VCon (name, vs) ->
    name ^ " " ^ String.concat " " (List.map pp_value_atom vs)
  | VRecord (name, fields) ->
    let pp_f (k, v) = k ^ " = " ^ pp_value v in
    name ^ " { " ^ String.concat ", " (List.map pp_f fields) ^ " }"
  | VRef cell -> "Ref(" ^ pp_value !cell ^ ")"
  | VClosure _ -> "<closure>"
  | VPrim _    -> "<prim>"
  | VMulti vs  -> Printf.sprintf "<dispatch/%d>" (List.length vs)
  | VThunk t   -> pp_value (Lazy.force t)
  | VNamedImpl (n, _) -> Printf.sprintf "<impl:%s>" n
  | VTypedImpl (t, _, _, inner) -> Printf.sprintf "<impl@%s:%s>" t (pp_value inner)

and pp_value_atom v = match v with
  | VCon (_, _ :: _) | VTuple _ -> "(" ^ pp_value v ^ ")"
  | _ -> pp_value v

(* Named-field constructor name → field names in declaration order.
   Populated from DData ConNamed variants at eval init. *)
let ctor_field_order : (string, string list) Hashtbl.t = Hashtbl.create 4

(* ── Pattern matching ────────────────────────────────────────────────────── *)

let rec match_pat pat value =
  match pat, value with
  | PVar x, v -> Some [(x, v)]
  | PWild, _ -> Some []
  | PLit (LInt n), VInt m when n = m -> Some []
  | PLit (LFloat f), VFloat g when f = g -> Some []
  | PLit (LString s), VString t when s = t -> Some []
  | PLit (LChar c), VChar d when c = d -> Some []
  | PLit (LBool b), VBool c when b = c -> Some []
  | PLit LUnit, VUnit -> Some []
  (* Boolean constructors: True/False match VBool *)
  | PCon ("True",  []), VBool true  -> Some []
  | PCon ("False", []), VBool false -> Some []
  | PCon (name, pats), VCon (name', vals)
    when name = name' && List.length pats = List.length vals ->
    match_pats pats vals
  | PCons (h, t), VList (x :: xs) ->
    (match match_pat h x with
     | None -> None
     | Some b1 ->
       (match match_pat t (VList xs) with
        | None -> None
        | Some b2 -> Some (b1 @ b2)))
  | PCons _, VList [] -> None
  | PTuple pats, VTuple vals when List.length pats = List.length vals ->
    match_pats pats vals
  | PList pats, VList vals when List.length pats = List.length vals ->
    match_pats pats vals
  | PList [], VList [] -> Some []
  | PAs (x, p), v ->
    (match match_pat p v with
     | None -> None
     | Some binds -> Some ((x, v) :: binds))
  | PRec (ctor, fields, _rest), VCon (ctor', vals) when ctor = ctor' ->
    (match Hashtbl.find_opt ctor_field_order ctor with
     | None -> None
     | Some field_names ->
       let field_assoc = List.combine field_names vals in
       let result = ref (Some []) in
       List.iter (fun (fname, pat_opt) ->
         if !result <> None then
           match List.assoc_opt fname field_assoc with
           | None -> result := None
           | Some v ->
             (match pat_opt with
              | None ->
                result := Option.map (fun bs -> bs @ [(fname, v)]) !result
              | Some q ->
                match match_pat q v with
                | None   -> result := None
                | Some b -> result := Option.map (fun bs -> bs @ b) !result)
       ) fields;
       !result)
  | PRec (_, fields, _rest), VRecord (_, record_fields) ->
    let result = ref (Some []) in
    List.iter (fun (fname, pat_opt) ->
      if !result <> None then
        match List.assoc_opt fname record_fields with
        | None -> result := None
        | Some v ->
          (match pat_opt with
           | None ->
             result := Option.map (fun bs -> bs @ [(fname, v)]) !result
           | Some q ->
             match match_pat q v with
             | None   -> result := None
             | Some b -> result := Option.map (fun bs -> bs @ b) !result)
    ) fields;
    !result
  | PRec _, _ -> None
  | PRng (LInt lo, LInt hi, incl), VInt v ->
    let hi' = if incl then hi else hi - 1 in
    if v >= lo && v <= hi' then Some [] else None
  | PRng (LChar lo, LChar hi, incl), VChar c ->
    let cmp = String.compare in
    if cmp c lo >= 0 && (if incl then cmp c hi <= 0 else cmp c hi < 0)
    then Some [] else None
  | PRng _, _ -> None
  | _ -> None

and match_pats pats vals =
  List.fold_left2
    (fun acc p v ->
       match acc with
       | None -> None
       | Some binds ->
         (match match_pat p v with
          | None -> None
          | Some b -> Some (binds @ b)))
    (Some []) pats vals

(* ── Monad context for do-blocks ─────────────────────────────────────────── *)

(* The current monadic context inside a do-block.  Bind itself dispatches
   through the stdlib `andThen` VMulti — this state is consulted only by the
   `pure` primitive, which needs a type name to pick the right Applicative
   impl body from `pure_impls`. *)
let current_monad_type : string option ref = ref None
let current_loc : loc option ref = ref None

(* Constructors known to belong to a Thenable impl.  Populated from the
   program's `impl Thenable T` declarations at eval init.  When a do-block
   bind sees a value whose head constructor is in this set, it dispatches
   through the `andThen` VMulti rather than falling through to direct
   pattern matching. *)
let monadic_ctors : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Constructor name → type name.  Populated from DData declarations at eval
   init.  Used by detect_monad to map a value's head constructor back to the
   type whose Applicative impl `pure` should dispatch into. *)
let ctor_to_type : (string, string) Hashtbl.t = Hashtbl.create 8

(* (iface_name, method_name) → list of argument positions whose types mention
   any of the interface's type parameters.  Populated when DInterface declarations
   are processed; consulted at DImpl registration so each impl method is wrapped
   in a VTypedImpl carrying the right dispatch metadata. *)
let iface_dispatch : (string * string, int list) Hashtbl.t = Hashtbl.create 8

(* Walk a method's declared type and find argument positions that mention any
   of the given interface type parameters.  Strips leading `TyConstrained` and
   `TyEffect` wrappers; recurses into TyApp/TyFun/TyTuple looking for matching
   TyVars. *)
let dispatch_positions_of (method_ty : Ast.ty) (iface_params : Ast.ident list)
    : int list =
  let rec mentions = function
    | Ast.TyVar n -> List.mem n iface_params
    | Ast.TyCon _ -> false
    | Ast.TyApp (a, b) | Ast.TyFun (a, b) -> mentions a || mentions b
    | Ast.TyTuple ts -> List.exists mentions ts
    | Ast.TyEffect (_, t) | Ast.TyConstrained (_, t) -> mentions t
  in
  let rec args_of = function
    | Ast.TyConstrained (_, t) -> args_of t
    | Ast.TyEffect (_, t) -> args_of t
    | Ast.TyFun (a, b) -> a :: args_of b
    | _ -> []
  in
  args_of method_ty
  |> List.mapi (fun i a -> (i, a))
  |> List.filter_map (fun (i, a) -> if mentions a then Some i else None)

let record_iface_dispatch (iface_name : string) (type_params : Ast.ident list)
    (methods : Ast.iface_method list) : unit =
  List.iter (fun (m : Ast.iface_method) ->
    let positions = dispatch_positions_of m.method_type type_params in
    Hashtbl.replace iface_dispatch (iface_name, m.method_name) positions
  ) methods

(* Look up the dispatch positions for an impl method.  Defaults to [0] when
   the interface declaration hasn't been seen yet — this matches the pre-fix
   behaviour where every arg triggered the tag filter on dispatch. *)
let lookup_dispatch_positions (iface_name : string) (method_name : string) : int list =
  try Hashtbl.find iface_dispatch (iface_name, method_name)
  with Not_found -> [0]


(* Type name → `pure` impl body.  Populated from `impl Applicative T` (and
   `impl Thenable T` if it overrides pure) declarations at eval init.  The
   `pure` primitive looks up this table using the current monad type. *)
let pure_impls : (string, value) Hashtbl.t = Hashtbl.create 4

(* Type name → arbitrary generator function.  Populated from `impl Arbitrary T`
   declarations at eval init.  Used by prop_runner to generate random values
   for user-defined types without going through VMulti dispatch. *)
let arbitrary_registry : (string, unit -> value) Hashtbl.t = Hashtbl.create 8

let detect_monad = function
  | VCon (cname, _) ->
    (match Hashtbl.find_opt ctor_to_type cname with
     | Some tname -> Some tname
     | None -> None)
  | VList _ -> Some "List"
  | _ -> None

(* Runtime "head type" tag for a value.  Used to filter VMulti candidates
   tagged via VTypedImpl when dispatching on a value of known shape. *)
let rec runtime_type_tag = function
  | VInt _    -> Some "Int"
  | VFloat _  -> Some "Float"
  | VString _ -> Some "String"
  | VChar _   -> Some "Char"
  | VBool _   -> Some "Bool"
  | VUnit     -> Some "Unit"
  | VList _   -> Some "List"
  | VArray _  -> Some "Array"
  | VCon (cname, _) -> Hashtbl.find_opt ctor_to_type cname
  | VRecord (name, _) -> Some name
  | VTypedImpl (t, _, _, _) -> Some t
  | VNamedImpl (_, inner) -> runtime_type_tag inner
  | _ -> None

(* Convert Impl_no_match → Eval_error at the boundary of user-visible code.
   Used at every eval site that is NOT inside a VMulti dispatch chain. *)
let wrap_match_errors f =
  try f ()
  with Impl_no_match ->
    raise (Eval_error ("non-exhaustive match", !current_loc))

(* ── Mutually recursive evaluator ───────────────────────────────────────── *)

let rec apply fn arg =
  match fn with
  | VClosure (env, [p], body) ->
    (match match_pat p arg with
     | None -> raise Impl_no_match
     | Some binds -> eval (extend env binds) body)
  | VClosure (env, p :: ps, body) ->
    (match match_pat p arg with
     | None -> raise Impl_no_match
     | Some binds -> VClosure (extend env binds, ps, body))
  | VClosure (_, [], _) ->
    raise (Eval_error ("applied closure with no parameters", !current_loc))
  | VPrim f -> f arg
  | VTypedImpl (t, positions, seen, inner) ->
    (* Pass through to the inner value but preserve the dispatch metadata
       across partial applications so subsequent VMulti dispatch can still
       route to the right typed candidate. *)
    let result = apply inner arg in
    (match result with
     | VClosure _ | VPrim _ | VMulti _ -> VTypedImpl (t, positions, seen + 1, result)
     | _ -> result)
  | VMulti vs ->
    (* Apply each impl to arg; collect results.
       - Terminal result (non-closure): first one wins (return immediately).
       - VClosure/VMulti result (partial application): collect ALL that succeeded;
         return as a new VMulti so the next argument can dispatch correctly.
       - If all fail: dispatch error.
       VNamedImpl/VTypedImpl entries are unwrapped before applying; the tag
       and dispatch metadata are re-attached to partial-application results
       so subsequent dispatch still sees the routing info.
       The tag-filter only fires for VTypedImpl candidates whose `args_seen`
       is in their declared `dispatch_positions` set — i.e. the arg about to
       be applied is the one that determines impl selection.  Candidates not
       at a dispatching slot (e.g. fold's accumulator) pass through unfiltered;
       candidates with empty positions (e.g. `pure : a -> f a`, where no arg
       mentions the interface type param) are never filtered positionally. *)
    let unwrap_tags = function
      | VNamedImpl (_, inner) -> inner
      | VTypedImpl (_, _, _, inner) -> inner
      | v -> v
    in
    let is_dispatching = function
      | VTypedImpl (_, positions, seen, _) -> List.mem seen positions
      | VNamedImpl (_, VTypedImpl (_, positions, seen, _)) -> List.mem seen positions
      | _ -> false
    in
    let vs =
      match runtime_type_tag arg with
      | None -> vs
      | Some tag ->
        let matches_tag = function
          | VTypedImpl (t, _, _, _) -> t = tag
          | VNamedImpl (_, VTypedImpl (t, _, _, _)) -> t = tag
          | _ -> true  (* untagged candidates always considered *)
        in
        (* Only filter candidates that are at a dispatching slot.  A
           non-dispatching candidate (e.g. a Foldable impl with `args_seen`
           still on the accumulator) gets a free pass regardless of tag. *)
        let should_filter = List.exists is_dispatching vs in
        if not should_filter then vs
        else
          let keep v = (not (is_dispatching v)) || matches_tag v in
          let filtered = List.filter keep vs in
          if filtered = [] then vs else filtered
    in
    let rec collect_partials acc = function
      | [] ->
        (match acc with
         | [] -> raise (Eval_error ("no matching impl for dispatch", !current_loc))
         | [v] -> v
         | many -> VMulti (List.rev many))
      | v :: rest ->
        (match (try Some (apply (unwrap_tags v) arg) with Impl_no_match -> None) with
         | None -> collect_partials acc rest
         | Some (VClosure _ | VPrim _ | VMulti _ as c) ->
           let wrapped = (match v with
             | VNamedImpl (n, _) -> VNamedImpl (n, c)
             | VTypedImpl (t, positions, seen, _) ->
               VTypedImpl (t, positions, seen + 1, c)
             | _ -> c) in
           collect_partials (wrapped :: acc) rest
         | Some terminal -> terminal)  (* first terminal result wins *)
    in
    collect_partials [] vs
  | _ ->
    raise (Eval_error ("applied non-function: " ^ pp_value fn, !current_loc))

and eval env expr =
  match expr with
  | ELoc (loc, e) ->
    current_loc := Some loc;
    Coverage.record_hit loc.file loc.line;
    eval env e

  | ELit (LInt n)    -> VInt n
  | ELit (LFloat f)  -> VFloat f
  | ELit (LString s) -> VString s
  | ELit (LChar c)   -> VChar c
  | ELit (LBool b)   -> VBool b
  | ELit LUnit       -> VUnit

  | EVar hint when String.length hint > 0 && hint.[0] = '@' ->
    VUnit  (* @Name as standalone expr; typechecker types it as Unit *)

  | EVar x -> lookup env x

  | EApp (f_expr, EVar hint)
  | EApp (f_expr, ELoc (_, EVar hint))
    when String.length hint > 0 && hint.[0] = '@' ->
    (* @Name hint: evaluate f, then filter VMulti to the named impl *)
    let name = String.sub hint 1 (String.length hint - 1) in
    (match eval env f_expr with
     | VMulti vs ->
       let filtered = List.filter (function
         | VNamedImpl (n, _) -> n = name | _ -> false) vs in
       (match filtered with
        | []                  -> raise (Eval_error ("no impl named '" ^ name ^ "'", !current_loc))
        | [VNamedImpl (_, v)] -> v
        | many                -> VMulti many)
     | other -> other)  (* hint on non-VMulti: ignore gracefully *)

  | EApp (f, x) ->
    let fv = eval env f in
    let xv = eval env x in
    apply fv xv

  | ELam (pats, body) -> VClosure (env, pats, body)

  | ELet (_, true, PVar f, e1, e2) ->
    (* Self-recursive: create a mutable ref cell so the closure can call itself *)
    let cell = ref VUnit in
    let rec_env = [(f, cell)] :: env in
    let v = eval rec_env e1 in
    cell := v;
    eval rec_env e2

  | ELet (_, _, pat, e1, e2) ->
    let v = eval env e1 in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure", !current_loc))
     | Some binds -> eval (extend env binds) e2)

  | ELetGroup (bindings, body) ->
    let cells = List.map (fun (name, _) -> (name, ref VUnit)) bindings in
    let env' = cells :: env in
    List.iter (fun (name, clauses) ->
      let closures = List.map (fun (pats, rhs) ->
        if pats = [] then eval env' rhs
        else VClosure (env', pats, rhs)) clauses in
      (List.assoc name cells) := (match closures with
        | [v] -> v
        | many -> VMulti many)
    ) bindings;
    eval env' body

  | EMatch (scrut, arms) ->
    let sv = eval env scrut in
    let rec try_arms = function
      | [] -> raise Impl_no_match
      | (pat, guard, body) :: rest ->
        (match match_pat pat sv with
         | None -> try_arms rest
         | Some binds ->
           let env' = extend env binds in
           let guard_ok = match guard with
             | None -> true
             | Some g -> eval env' g = VBool true
           in
           if guard_ok then eval env' body
           else try_arms rest)
    in
    try_arms arms

  | EIf (cond, thn, els) ->
    (match eval env cond with
     | VBool true | VCon ("True", [])  -> eval env thn
     | VBool false | VCon ("False", []) -> eval env els
     | _ -> raise (Eval_error ("if condition is not a Bool", !current_loc)))

  | EBinOp (op, l, r) -> eval_binop env op l r

  | EUnOp ("-", e) ->
    (match eval env e with
     | VInt n   -> VInt (-n)
     | VFloat f -> VFloat (-.f)
     | _ -> raise (Eval_error ("unary minus on non-number", !current_loc)))

  | EUnOp (("!" | "not"), e) ->
    (match eval env e with
     | VBool b -> VBool (not b)
     | _ -> raise (Eval_error ("'!' on non-Bool", !current_loc)))

  | EUnOp (op, _) ->
    raise (Eval_error ("unknown unary op: " ^ op, !current_loc))

  | EFieldAccess (e, "value") ->
    (match eval env e with
     | VRef cell -> !cell
     | VRecord (_, fields) ->
       (match List.assoc_opt "value" fields with
        | Some v -> v
        | None -> raise (Eval_error ("record has no field 'value'", !current_loc)))
     | _ -> raise (Eval_error ("field access on non-record/ref", !current_loc)))

  | EFieldAccess (e, field) ->
    (match eval env e with
     | VRecord (_, fields) ->
       (match List.assoc_opt field fields with
        | Some v -> v
        | None -> raise (Eval_error ("unknown field: " ^ field, !current_loc)))
     | _ -> raise (Eval_error ("field access on non-record", !current_loc)))

  | ERecordCreate (name, fields) ->
    (match Hashtbl.find_opt ctor_field_order name with
     | Some order ->
       let vals = List.map (fun fn ->
         match List.assoc_opt fn fields with
         | Some e -> eval env e
         | None -> raise (Eval_error ("missing field: " ^ fn, !current_loc))
       ) order in
       VCon (name, vals)
     | None ->
       VRecord (name, List.map (fun (k, e) -> (k, eval env e)) fields))

  | ERecordUpdate (base, fields) ->
    (match eval env base with
     | VRecord (name, existing) ->
       let updates = List.map (fun (k, e) -> (k, eval env e)) fields in
       let merged = List.map (fun (k, v) ->
         match List.assoc_opt k updates with
         | Some v' -> (k, v')
         | None -> (k, v)) existing
       in
       VRecord (name, merged)
     | _ -> raise (Eval_error ("record update on non-record", !current_loc)))

  | EArrayLit es -> VArray (Array.of_list (List.map (eval env) es))
  | EListLit es  -> VList (List.map (eval env) es)
  | EStringInterp parts ->
    let strs = List.map (function
      | InterpStr s  -> s
      | InterpExpr e -> (match eval env e with
          | VString s -> s
          | v -> pp_value v)
    ) parts in
    VString (String.concat "" strs)
  | EMapLit (name, kvs) ->
    (* Desugar to a constructor applied to a list of (key, value) tuples.
       Real implementation awaits the stdlib Map module. *)
    let pairs = List.map (fun (k, v) -> VTuple [eval env k; eval env v]) kvs in
    VCon (name ^ ".fromList", [VList pairs])
  | ESetLit (name, es) ->
    (* Desugar to a constructor applied to a list of elements. *)
    VCon (name ^ ".fromList", [VList (List.map (eval env) es)])
  | ETuple es    -> VTuple (List.map (eval env) es)

  | EIndex (arr, idx) ->
    let i = match eval env idx with
      | VInt n -> n
      | _ -> raise (Eval_error ("index is not an Int", !current_loc))
    in
    (match eval env arr with
     | VArray a ->
       if i < 0 || i >= Array.length a then
         raise (Eval_error (Printf.sprintf "index %d out of bounds" i, !current_loc))
       else a.(i)
     | VList vs ->
       (match List.nth_opt vs i with
        | Some v -> v
        | None ->
          raise (Eval_error (Printf.sprintf "index %d out of bounds" i, !current_loc)))
     | _ -> raise (Eval_error ("index on non-array/list", !current_loc)))

  | EBlock stmts -> eval_block env stmts

  | EDo (monad_tag_ref, stmts) ->
    let saved = !current_monad_type in
    current_monad_type := None;
    let result = eval_do env !monad_tag_ref stmts in
    current_monad_type := saved;
    result

  | EAnnot (e, _) -> eval env e

  | EListComp _ -> assert false (* eliminated by desugar_list_comps *)

  | EQuestion _ -> assert false (* eliminated by desugar_questions *)

  | ERangeList (elo, ehi, incl) ->
    let lo = match eval env elo with
      | VInt n -> n
      | _ -> raise (Eval_error ("range bound must be Int", !current_loc))
    in
    let hi = match eval env ehi with
      | VInt n -> n
      | _ -> raise (Eval_error ("range bound must be Int", !current_loc))
    in
    let hi' = if incl then hi + 1 else hi in
    VList (List.init (max 0 (hi' - lo)) (fun i -> VInt (lo + i)))

  | ERangeArray (elo, ehi, incl) ->
    let lo = match eval env elo with
      | VInt n -> n
      | _ -> raise (Eval_error ("range bound must be Int", !current_loc))
    in
    let hi = match eval env ehi with
      | VInt n -> n
      | _ -> raise (Eval_error ("range bound must be Int", !current_loc))
    in
    let hi' = if incl then hi + 1 else hi in
    VArray (Array.init (max 0 (hi' - lo)) (fun i -> VInt (lo + i)))

  | ESlice (earr, elo, ehi, incl) ->
    let lo = match eval env elo with
      | VInt n -> n
      | _ -> raise (Eval_error ("slice index must be Int", !current_loc))
    in
    let hi = match eval env ehi with
      | VInt n -> n
      | _ -> raise (Eval_error ("slice index must be Int", !current_loc))
    in
    let hi' = if incl then hi + 1 else hi in
    (match eval env earr with
     | VArray a ->
       let len = hi' - lo in
       if lo < 0 || hi' > Array.length a || len < 0 then
         raise (Eval_error (Printf.sprintf "slice [%d..%d] out of bounds" lo (hi'-1), !current_loc))
       else VArray (Array.sub a lo len)
     | VList vs ->
       VList (List.filteri (fun i _ -> i >= lo && i < hi') vs)
     | VString s ->
       let len = hi' - lo in
       if lo < 0 || hi' > String.length s || len < 0 then
         raise (Eval_error (Printf.sprintf "slice [%d..%d] out of bounds" lo (hi'-1), !current_loc))
       else VString (String.sub s lo len)
     | _ -> raise (Eval_error ("slice on non-array/list/string", !current_loc)))

  | EInfix (op, l, r) ->
    let f  = lookup env op in
    let lv = eval env l in
    let rv = eval env r in
    apply (apply f lv) rv

and eval_binop env op l r =
  match op with
  | "|>" ->
    let lv = eval env l and fv = eval env r in
    apply fv lv
  | ">>" ->
    let fv = eval env l and gv = eval env r in
    VPrim (fun x -> apply gv (apply fv x))
  | "<<" ->
    let fv = eval env l and gv = eval env r in
    VPrim (fun x -> apply fv (apply gv x))
  | "&&" ->
    (match eval env l with
     | VBool false | VCon ("False", []) -> VBool false
     | VBool true  | VCon ("True", [])  -> eval env r
     | _ -> raise (Eval_error ("'&&' on non-Bool", !current_loc)))
  | "||" ->
    (match eval env l with
     | VBool true  | VCon ("True", [])  -> VBool true
     | VBool false | VCon ("False", []) -> eval env r
     | _ -> raise (Eval_error ("'||' on non-Bool", !current_loc)))
  | "::" ->
    let hv = eval env l and tv = eval env r in
    (match tv with
     | VList xs -> VList (hv :: xs)
     | _ -> raise (Eval_error ("cons (::) rhs is not a list", !current_loc)))
  | "++" ->
    let lv = eval env l and rv = eval env r in
    (* If one operand is a VMulti of differently-typed candidates (e.g. the
       polymorphic `empty` of Monoid), ground it using the other operand's
       runtime type tag.  This is what lets `acc ++ f x` in a polymorphic
       body work when acc started life as `empty`. *)
    let resolve other v = match v with
      | VMulti vs ->
        (match runtime_type_tag other with
         | None -> v
         | Some tag ->
           (match List.filter_map (function
              | VTypedImpl (t, _, _, inner) when t = tag -> Some inner
              | _ -> None) vs with
            | [single] -> single
            | _ -> v))
      | _ -> v
    in
    let lv = resolve rv lv in
    let rv = resolve lv rv in
    (match lv, rv with
     | VList xs, VList ys -> VList (xs @ ys)
     | VString a, VString b -> VString (a ^ b)
     | lv, rv ->
       (try apply (apply (lookup env "append") lv) rv
        with Eval_error _ ->
          raise (Eval_error ("'++' requires Semigroup (List, String, or a type with append)", !current_loc))))
  | _ ->
    let lv = eval env l and rv = eval env r in
    eval_arith op lv rv

and eval_arith op lv rv =
  match op, lv, rv with
  | "+",  VInt a,   VInt b   -> VInt (a + b)
  | "-",  VInt a,   VInt b   -> VInt (a - b)
  | "*",  VInt a,   VInt b   -> VInt (a * b)
  | "/",  VInt _,   VInt 0   -> raise (Eval_error ("division by zero", !current_loc))
  | "/",  VInt a,   VInt b   -> VInt (a / b)
  | "%",  VInt _,   VInt 0   -> raise (Eval_error ("modulo by zero", !current_loc))
  | "%",  VInt a,   VInt b   -> VInt (a mod b)
  | "+",  VFloat a, VFloat b -> VFloat (a +. b)
  | "-",  VFloat a, VFloat b -> VFloat (a -. b)
  | "*",  VFloat a, VFloat b -> VFloat (a *. b)
  | "/",  VFloat a, VFloat b -> VFloat (a /. b)
  | "==", a, b -> VBool (a = b)
  | "!=", a, b -> VBool (a <> b)
  | "<",  a, b -> VBool (compare a b < 0)
  | ">",  a, b -> VBool (compare a b > 0)
  | "<=", a, b -> VBool (compare a b <= 0)
  | ">=", a, b -> VBool (compare a b >= 0)
  | _ ->
    raise (Eval_error
             (Printf.sprintf "unknown op '%s' for %s, %s"
                op (pp_value lv) (pp_value rv), !current_loc))

and eval_block env stmts =
  (* Bare sequential block: no monadic dispatch.  Value of the last stmt is
     the block's result. *)
  match stmts with
  | [] -> VUnit
  | [DoExpr e] -> wrap_match_errors (fun () -> eval env e)
  | [DoLet (_, pat, e)] ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure in block", !current_loc))
     | Some _ -> VUnit)
  | [DoAssign (_, e)] ->
    let _ = wrap_match_errors (fun () -> eval env e) in VUnit
  | [DoFieldAssign (x, field, e)] ->
    let new_val = wrap_match_errors (fun () -> eval env e) in
    (match lookup env x with
     | VRef cell when field = "value" -> cell := new_val; VUnit
     | VRecord (_, _) -> VUnit
     | _ -> raise (Eval_error ("field assignment on non-record/ref: " ^ x, !current_loc)))
  | [DoLetElse _] ->
    raise (Eval_error ("block cannot end with a let-else binding", !current_loc))
  | [DoBind _] ->
    raise (Eval_error ("`<-` is only allowed inside a `do` block", !current_loc))
  | (DoExpr e) :: rest ->
    let _ = wrap_match_errors (fun () -> eval env e) in
    eval_block env rest
  | (DoLet (_, pat, e)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure in block", !current_loc))
     | Some binds -> eval_block (extend env binds) rest)
  | (DoAssign (x, e)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    eval_block (extend env [(x, v)]) rest
  | (DoFieldAssign (x, field, e)) :: rest ->
    let new_val = wrap_match_errors (fun () -> eval env e) in
    (match lookup env x with
     | VRef cell when field = "value" ->
       cell := new_val;
       eval_block env rest
     | VRecord (name, fields) ->
       let updated = VRecord (name, List.map (fun (k, v) ->
         if k = field then (k, new_val) else (k, v)) fields) in
       eval_block (extend env [(x, updated)]) rest
     | _ -> raise (Eval_error ("field assignment on non-record/ref: " ^ x, !current_loc)))
  | (DoLetElse (pat, e, alt)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> eval env alt
     | Some binds -> eval_block (extend env binds) rest)
  | (DoBind _) :: _ ->
    raise (Eval_error ("`<-` is only allowed inside a `do` block", !current_loc))

and eval_do env monad_tag stmts =
  (* If the typechecker resolved the monad type, seed current_monad_type now
     so `pure` dispatches correctly even before the first DoBind is evaluated. *)
  (match monad_tag with
   | Some _ -> current_monad_type := monad_tag
   | None   -> ());
  match stmts with
  | [] -> VUnit
  | [DoExpr e] -> wrap_match_errors (fun () -> eval env e)
  | [DoLet (_, pat, e)] ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure in do", !current_loc))
     | Some _ -> VUnit)
  | [DoAssign (_, e)] ->
    let _ = wrap_match_errors (fun () -> eval env e) in VUnit
  | [DoFieldAssign (x, field, e)] ->
    let new_val = wrap_match_errors (fun () -> eval env e) in
    (match lookup env x with
     | VRef cell when field = "value" -> cell := new_val; VUnit
     | VRecord (_, _) -> VUnit  (* last stmt: shadow would be discarded anyway *)
     | _ -> raise (Eval_error ("field assignment on non-record/ref: " ^ x, !current_loc)))
  | [DoBind (_, _)] ->
    raise (Eval_error ("do-block cannot end with <-", !current_loc))

  | (DoExpr e) :: rest ->
    let _ = wrap_match_errors (fun () -> eval env e) in
    eval_do env monad_tag rest

  | (DoLet (_, pat, e)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure in do", !current_loc))
     | Some binds -> eval_do (extend env binds) monad_tag rest)

  | (DoAssign (x, e)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    eval_do (extend env [(x, v)]) monad_tag rest

  | (DoFieldAssign (x, field, e)) :: rest ->
    let new_val = wrap_match_errors (fun () -> eval env e) in
    (match lookup env x with
     | VRef cell when field = "value" ->
       cell := new_val;
       eval_do env monad_tag rest
     | VRecord (name, fields) ->
       let updated = VRecord (name, List.map (fun (k, v) ->
         if k = field then (k, new_val) else (k, v)) fields) in
       eval_do (extend env [(x, updated)]) monad_tag rest
     | _ -> raise (Eval_error ("field assignment on non-record/ref: " ^ x, !current_loc)))

  | [DoLetElse _] ->
    raise (Eval_error ("do-block cannot end with a let-else binding", !current_loc))

  | (DoLetElse (pat, e, alt)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> eval env alt
     | Some binds -> eval_do (extend env binds) monad_tag rest)

  | (DoBind (pat, e)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    if !current_monad_type = None then
      current_monad_type := detect_monad v;
    (* If `v`'s head constructor belongs to a Thenable impl, dispatch the bind
       through the stdlib `andThen` VMulti.  The Thenable impl's clauses do
       the short-circuiting (e.g. `andThen None _ = None`).  Otherwise fall
       through to direct pattern matching — same shape as the old MIO mode. *)
    let dispatch_via_thenable () =
      let and_then = lookup env "andThen" in
      let continuation = VPrim (fun bound_v ->
        match match_pat pat bound_v with
        | None ->
          raise (Eval_error ("bind pattern match failure", !current_loc))
        | Some binds -> eval_do (extend env binds) monad_tag rest
      ) in
      apply (apply and_then v) continuation
    in
    (match v with
     | VCon (cname, _) when Hashtbl.mem monadic_ctors cname ->
       dispatch_via_thenable ()
     | VList _ when Hashtbl.mem monadic_ctors "Cons" ->
       (* VList is its own OCaml value (not VCon ("Cons", ...) or
          VCon ("Nil", [])) but it has a Thenable impl in the stdlib.
          Dispatch through andThen so List acts as a monad in do-blocks
          (concat-map semantics). *)
       dispatch_via_thenable ()
     | _ ->
       (match match_pat pat v with
        | None -> raise (Eval_error ("bind pattern match failure", !current_loc))
        | Some binds -> eval_do (extend env binds) monad_tag rest))

(* ── Extern / primitive dispatch table ──────────────────────────────────── *)

let unwrap_list = function
  | VList vs -> vs
  | v -> raise (Eval_error ("expected list, got: " ^ pp_value v, None))

let primitives : (string * value) list =
  [
    ("print",   VPrim (fun v -> !output_hook (pp_value v); VUnit));
    ("println", VPrim (fun v -> !output_hook (pp_value v); !output_hook "\n"; VUnit));
    (* `pure` dispatches through the user-written Applicative impl body for
       the current monad type, which the do-block records in
       `current_monad_type` when a bind sees a known monadic constructor.
       Outside that context (or for monads with no `pure` impl loaded yet),
       fall through unchanged — matches the previous MIO/MUnknown branch. *)
    ("pure",    VPrim (fun v ->
      match !current_monad_type with
      | Some tname when Hashtbl.mem pure_impls tname ->
        apply (Hashtbl.find pure_impls tname) v
      | _ -> v));
    ("Ref",     VPrim (fun v -> VRef (ref v)));
    ("set_ref", VPrim (fun r ->
      VPrim (fun v ->
        match r with
        | VRef cell -> cell := v; VUnit
        | _ -> raise (Eval_error ("set_ref: not a Ref", None)))));
    (* `map`, `filter`, and `fold` are no longer primitives — they are
       defined in stdlib/core.mdk as regular Medaka functions. *)
    ("pi",      VFloat Float.pi);
    ("e",       VFloat (exp 1.0));
    ("readLine", VPrim (fun _ -> VString (input_line stdin)));
    ("readFile", VPrim (fun path ->
      match path with
      | VString p ->
        (try
           let ic = open_in p in
           let s = really_input_string ic (in_channel_length ic) in
           close_in ic;
           VCon ("Ok", [VString s])
         with Sys_error msg -> VCon ("Err", [VString msg]))
      | _ -> raise (Eval_error ("readFile: expected String", None))));
    ("writeFile", VPrim (fun path ->
      VPrim (fun content ->
        match path, content with
        | VString p, VString s ->
          (try
             let oc = open_out p in
             output_string oc s;
             close_out oc;
             VCon ("Ok", [VUnit])
           with Sys_error msg -> VCon ("Err", [VString msg]))
        | _ -> raise (Eval_error ("writeFile: expected String String", None)))));
    ("exit", VPrim (fun code ->
      match code with
      | VInt n -> Stdlib.exit n
      | _ -> raise (Eval_error ("exit: expected Int", None))));
    ("panic", VPrim (fun msg ->
      match msg with
      | VString s -> raise (Eval_error ("panic: " ^ s, !current_loc))
      | _ -> raise (Eval_error ("panic", !current_loc))));
    ("randomInt", VPrim (fun lo ->
      VPrim (fun hi ->
        match lo, hi with
        | VInt lo', VInt hi' ->
          let range = hi' - lo' + 1 in
          VInt (if range <= 0 then lo' else lo' + Random.int range)
        | _ -> raise (Eval_error ("randomInt: expected Int Int", None)))));
    ("randomBool", VPrim (fun _ -> VBool (Random.bool ())));
    ("randomFloat", VPrim (fun _ -> VFloat (Random.float 2.0 -. 1.0)));
    ("randomChar", VPrim (fun _ ->
      VChar (String.make 1 (Char.chr (32 + Random.int 95)))));
    ("setSeed", VPrim (fun n ->
      match n with
      | VInt seed -> Random.init seed; VUnit
      | _ -> raise (Eval_error ("setSeed: expected Int", None))));
    ("charToStr", VPrim (fun c ->
      match c with
      | VChar s -> VString s
      | _ -> raise (Eval_error ("charToStr: expected Char", None))));
    ("intToFloat", VPrim (fun v ->
      match v with
      | VInt n -> VFloat (Float.of_int n)
      | _ -> raise (Eval_error ("intToFloat: expected Int", None))));
    ("floatToInt", VPrim (fun v ->
      match v with
      | VFloat f -> VInt (Int.of_float f)
      | _ -> raise (Eval_error ("floatToInt: expected Float", None))));
    ("assert_snapshot", VPrim (fun name_v ->
      VPrim (fun value_v ->
        match name_v, value_v with
        | VString name, VString value ->
          let safe = String.map (fun c ->
            if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
               (c >= '0' && c <= '9') || c = '-' then c else '_') name in
          let dir  = !snapshot_dir in
          let path = Filename.concat dir (safe ^ ".snap") in
          let ensure_dir () =
            (try Unix.mkdir dir 0o755
             with Unix.Unix_error (Unix.EEXIST, _, _) -> ()) in
          if !snapshot_update then begin
            ensure_dir ();
            let oc = open_out path in
            output_string oc value; close_out oc; VUnit
          end else begin
            match (try Some (In_channel.input_all (open_in path))
                   with Sys_error _ -> None) with
            | None ->
              ensure_dir ();
              let oc = open_out path in
              output_string oc value; close_out oc; VUnit
            | Some stored ->
              if stored = value then VUnit
              else raise (Eval_error (
                Printf.sprintf
                  "snapshot mismatch for '%s':\n  stored: %s\n  actual: %s"
                  name stored value, None))
          end
        | _ -> raise (Eval_error ("assert_snapshot: expected String String", None)))));
  ]

let () =
  let dispatch_names = List.map fst primitives in
  List.iter (fun n ->
    if not (List.mem n dispatch_names) then
      failwith ("runtime.mdk extern '" ^ n ^ "' has no OCaml impl in eval.ml")
  ) Runtime.names

(* ── Specificity helpers for impl dispatch ordering ─────────────────────── *)

(* Count free type variables in a type.  Fewer = more specific = higher priority
   in VMulti dispatch.  E.g. TyCon "List" → 0; TyApp(TyCon "Result", TyVar "e") → 1. *)
let rec count_tyvars_ty = function
  | TyVar _          -> 1
  | TyApp (a, b)     -> count_tyvars_ty a + count_tyvars_ty b
  | TyFun (a, b)     -> count_tyvars_ty a + count_tyvars_ty b
  | TyTuple ts       -> List.fold_left (fun n t -> n + count_tyvars_ty t) 0 ts
  | TyEffect (_, t)  -> count_tyvars_ty t
  | TyConstrained (_, t) -> count_tyvars_ty t
  | TyCon _          -> 0

let tyvars_in_args args =
  List.fold_left (fun n t -> n + count_tyvars_ty t) 0 args

(* ── Constructor thunks for data declarations ────────────────────────────── *)

let make_ctor name arity =
  if arity = 0 then VCon (name, [])
  else
    let rec build collected remaining =
      if remaining = 0 then VCon (name, List.rev collected)
      else VPrim (fun v -> build (v :: collected) (remaining - 1))
    in
    build [] arity

(* ── Evaluate a full program ─────────────────────────────────────────────── *)

let eval_program program =
  let top_frame : (string * value ref) list ref = ref [] in

  let add_to_frame name v =
    top_frame := (name, ref v) :: !top_frame
  in

  (* Seed True/False: these are lexed as BOOL literals (not UPPER tokens) and
     stored as VBool, but a few code paths look them up by name as plain
     values.  Option / Result / Ordering constructors are now bound via the
     prelude's DData declarations in Pass 1 below — no need to pre-seed. *)
  add_to_frame "True"  (VBool true);
  add_to_frame "False" (VBool false);

  (* Seed with primitives *)
  List.iter (fun (name, v) -> add_to_frame name v) (List.rev primitives);

  (* Prepend stdlib/core.mdk so its data types, interfaces, and impl bodies
     are bound for the user program.  Mirrors what Typecheck.check_program
     does on the type-checking side.  Do-block bind dispatches through the
     prelude's `andThen` VMulti, so this is what makes Step 3 work.
     Skip when the program IS core (avoid duplicates). *)
  let is_core =
    let has_ordering = List.exists (fun d -> match Ast.inner_decl d with
      | DData (_, "Ordering", _, _, _) -> true | _ -> false) program in
    let has_foldable = List.exists (fun d -> match Ast.inner_decl d with
      | DInterface { iface_name = "Foldable"; _ } -> true | _ -> false) program in
    has_ordering && has_foldable
  in
  let program = if is_core then program else Prelude.program @ program in

  (* Record constructor names that belong to a Thenable impl, so DoBind can
     decide whether to dispatch via `andThen` or fall through; and the
     reverse mapping ctor → type used by detect_monad to flag `pure`'s
     target for impl lookup. *)
  Hashtbl.clear monadic_ctors;
  Hashtbl.clear ctor_to_type;
  Hashtbl.clear ctor_field_order;
  Hashtbl.clear arbitrary_registry;
  let type_ctors : (string, string list) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun d -> match Ast.inner_decl d with
    | DData (_, n, _, vs, _) ->
      let cnames = List.map (fun v -> v.con_name) vs in
      Hashtbl.replace type_ctors n cnames;
      List.iter (fun v ->
        Hashtbl.replace ctor_to_type v.con_name n;
        (match v.con_payload with
         | ConNamed fields ->
           Hashtbl.replace ctor_field_order v.con_name
             (List.map (fun f -> f.field_name) fields)
         | ConPos _ -> ())
      ) vs
    | DNewtype (_, type_name, _, con_name, _, _) ->
      Hashtbl.replace ctor_to_type con_name type_name
    | _ -> ()
  ) program;
  (* Built-in types whose constructors are seeded in OCaml. *)
  Hashtbl.replace type_ctors "List" ["Cons"; "Nil"];
  let rec head_tycon = function
    | Ast.TyCon n          -> Some n
    | Ast.TyApp (a, _)     -> head_tycon a
    | Ast.TyConstrained (_, t) | Ast.TyEffect (_, t) -> head_tycon t
    | _ -> None
  in
  List.iter (fun d -> match Ast.inner_decl d with
    | DImpl { iface_name = "Thenable"; type_args; _ } ->
      List.iter (fun ta ->
        match head_tycon ta with
        | Some tn ->
          (match Hashtbl.find_opt type_ctors tn with
           | Some ctors ->
             List.iter (fun c -> Hashtbl.replace monadic_ctors c ()) ctors
           | None -> ())
        | None -> ()
      ) type_args
    | _ -> ()
  ) program;

  (* Externs that use OCaml runtime context and must NOT be shadowed by
     impl definitions.  Everything else (map, filter, fold, …) CAN be
     overridden so that typeclass impls take effect. *)
  let context_dependent_externs = ["pure"] in

  (* Pass 1: collect DData constructors and DFunDef/DImpl method names *)
  List.iter (fun decl ->
    match Ast.inner_decl decl with
    | DNewtype (_, _, _, con, _, _) ->
      add_to_frame con (make_ctor con 1)
    | DData (_, _, _, variants, _) ->
      List.iter (fun v ->
        let arity = match v.con_payload with
          | ConPos tys   -> List.length tys
          | ConNamed fls -> List.length fls
        in
        add_to_frame v.con_name (make_ctor v.con_name arity)
      ) variants
    | DFunDef (_, name, _, _) ->
      add_to_frame name VUnit
    | DLetGroup (_, bindings) ->
      List.iter (fun (name, _) -> add_to_frame name VUnit) bindings
    | DImpl { methods; _ } ->
      List.iter (fun (name, _, _) ->
        if not (List.mem name context_dependent_externs) then
          add_to_frame name VUnit
      ) methods
    | DInterface { methods; _ } ->
      List.iter (fun m ->
        match m.method_default with
        | None -> ()
        | Some _ -> add_to_frame m.method_name VUnit
      ) methods
    | _ -> ()
  ) program;

  let env : env = [!top_frame] in

  let fill_cell name v =
    match List.assoc_opt name !top_frame with
    | Some cell -> cell := v
    | None -> ()
  in

  (* Pass 2: evaluate all declaration bodies in declaration order.
     For DImpl, closures are accumulated per method name with their specificity
     score so that a sorted VMulti is built and installed immediately — before
     any later DFunDef body that calls the method is evaluated. *)
  (* method name → accumulated (score, closure) list in insertion order *)
  let impl_acc : (string, (int * value) list) Hashtbl.t = Hashtbl.create 16 in
  (* top-level function name → accumulated clause closures, so multi-clause
     `f pat1 = ...` / `f pat2 = ...` at the top level dispatches via VMulti
     just like impl methods. *)
  let fundef_acc : (string, value list) Hashtbl.t = Hashtbl.create 16 in
  (* Zero-param DFunDef names in source order; thunks are forced after all
     DImpl methods are installed so forward impl references resolve correctly. *)
  let deferred_zero_params : string list ref = ref [] in

  Hashtbl.clear pure_impls;
  Hashtbl.clear iface_dispatch;
  (* Pre-pass: record dispatch positions for every interface method, so that
     DImpl declarations encountered later can look up the right positions
     regardless of source order. *)
  List.iter (fun decl ->
    match Ast.inner_decl decl with
    | DInterface { iface_name; type_params; methods; _ } ->
      record_iface_dispatch iface_name type_params methods
    | _ -> ()
  ) program;
  List.iter (fun decl ->
    match Ast.inner_decl decl with
    | DFunDef (_, name, pats, body) ->
      let v = if pats = [] then begin
        deferred_zero_params := name :: !deferred_zero_params;
        VThunk (lazy (wrap_match_errors (fun () -> eval env body)))
      end else wrap_match_errors (fun () -> VClosure (env, pats, body)) in
      let prev = try Hashtbl.find fundef_acc name with Not_found -> [] in
      let updated = prev @ [v] in
      Hashtbl.replace fundef_acc name updated;
      fill_cell name (match updated with [v] -> v | many -> VMulti many)
    | DLetGroup (_, bindings) ->
      (* All group names already have VUnit cells installed by Pass 1, so
         each clause's body can reference any group name through env.
         Mirrors the ELetGroup expression case. *)
      List.iter (fun (name, clauses) ->
        let closures = List.map (fun (pats, rhs) ->
          if pats = [] then wrap_match_errors (fun () -> eval env rhs)
          else VClosure (env, pats, rhs)) clauses in
        let v = match closures with
          | [v] -> v
          | many -> VMulti many
        in
        fill_cell name v
      ) bindings
    | DImpl { iface_name; type_args; methods; impl_name; _ } ->
      let score = tyvars_in_args type_args in
      (* If this is an Applicative impl, record its `pure` body in pure_impls
         keyed by the impl type's head TyCon name.  The `pure` primitive
         consults this table once the do-block has identified its monad. *)
      if iface_name = "Applicative" then begin
        match type_args, List.find_opt (fun (n, _, _) -> n = "pure") methods with
        | [t], Some (_, pats, body) ->
          (match head_tycon t with
           | Some tname ->
             let v = if pats = [] then wrap_match_errors (fun () -> eval env body)
                     else VClosure (env, pats, body) in
             Hashtbl.replace pure_impls tname v
           | None -> ())
        | _ -> ()
      end;
      (* For Arbitrary impls: register in arbitrary_registry so prop_runner can
         look up generators for user-defined types by type name. *)
      if iface_name = "Arbitrary" then begin
        match List.find_opt (fun (n, _, _) -> n = "arbitrary") methods with
        | Some (_, pats, body) ->
          let type_key = match type_args with
            | [t] -> (match head_tycon t with Some n -> Some n | None -> None)
            | _ -> None
          in
          (match type_key with
           | Some tname ->
             let v = if pats = [] then wrap_match_errors (fun () -> eval env body)
                     else VClosure (env, pats, body) in
             Hashtbl.replace arbitrary_registry tname
               (fun () -> apply v VUnit)
           | None -> ())
        | None -> ()
      end;
      let impl_type_tag = match type_args with
        | t :: _ -> head_tycon t
        | [] -> None
      in
      List.iter (fun (name, pats, body) ->
        (* `pure` stays a primitive (it consults current_monad_type to pick
           the right impl from pure_impls); everything else, including
           interface methods like `map`/`fold`, is collected here so the
           regular VMulti dispatch path picks it up. *)
        if not (List.mem name context_dependent_externs) then begin
          let new_v = if pats = [] then wrap_match_errors (fun () -> eval env body)
                      else VClosure (env, pats, body) in
          let positions = lookup_dispatch_positions iface_name name in
          let typed_v = match impl_type_tag with
            | Some t -> VTypedImpl (t, positions, 0, new_v)
            | None   -> new_v
          in
          let tagged_v = match impl_name with
            | Some n -> VNamedImpl (n, typed_v)
            | None   -> typed_v
          in
          let prev = try Hashtbl.find impl_acc name with Not_found -> [] in
          let updated = prev @ [(score, tagged_v)] in
          Hashtbl.replace impl_acc name updated;
          (* Re-sort and install immediately so subsequent DFunDef bodies that
             call this method see the correct VMulti binding. *)
          let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
          let closures = List.map snd sorted in
          fill_cell name (match closures with [v] -> v | many -> VMulti many)
        end
      ) methods
    | DInterface { type_params; methods; _ } ->
      (* Register default method bodies as fallbacks.  Score = number of type
         params (more params = more generic) so concrete impls always win. *)
      let score = List.length type_params in
      List.iter (fun m ->
        match m.method_default with
        | None -> ()
        | Some (pats, body) ->
          let name = m.method_name in
          let new_v = if pats = [] then wrap_match_errors (fun () -> eval env body)
                      else VClosure (env, pats, body) in
          let prev = try Hashtbl.find impl_acc name with Not_found -> [] in
          let updated = prev @ [(score, new_v)] in
          Hashtbl.replace impl_acc name updated;
          let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
          let closures = List.map snd sorted in
          fill_cell name (match closures with [v] -> v | many -> VMulti many)
      ) methods
    | _ -> ()
  ) program;

  (* Force all deferred zero-param thunks in source order now that every DImpl
     has been installed.  Transitive thunk dependencies resolve automatically
     via the memoising lookup. *)
  List.iter (fun name -> ignore (lookup env name))
    (List.rev !deferred_zero_params);

  List.map (fun (k, cell) -> (k, !cell)) !top_frame

(* ── REPL incremental interface ─────────────────────────────────────────── *)

type repl_state = {
  top_frame : (string * value ref) list ref;
  eval_env  : env ref;
}

let rec eval_repl_decl (rs : repl_state) (decl : decl) : unit =
  let add name v = rs.top_frame := (name, ref v) :: !(rs.top_frame) in
  let fill name v =
    match List.assoc_opt name !(rs.top_frame) with
    | Some cell -> cell := v
    | None -> add name v
  in
  rs.eval_env := [!(rs.top_frame)];
  (match decl with
   | DData (_, type_name, _, variants, _) ->
     List.iter (fun v ->
       let arity = match v.con_payload with
         | ConPos tys   -> List.length tys
         | ConNamed fls -> List.length fls
       in
       add v.con_name (make_ctor v.con_name arity);
       Hashtbl.replace ctor_to_type v.con_name type_name;
       (match v.con_payload with
        | ConNamed fields ->
          Hashtbl.replace ctor_field_order v.con_name
            (List.map (fun f -> f.field_name) fields)
        | ConPos _ -> ())
     ) variants
   | DFunDef (_, name, pats, body) ->
     add name VUnit;
     rs.eval_env := [!(rs.top_frame)];
     let v = wrap_match_errors (fun () ->
       if pats = [] then eval !(rs.eval_env) body
       else VClosure (!(rs.eval_env), pats, body)) in
     (* Multi-clause `f pat1 = ...` / `f pat2 = ...` entered separately at the
        REPL should dispatch via VMulti, mirroring eval_program. A value
        binding (pats = []) replaces any prior binding. *)
     let merged =
       if pats = [] then v
       else match List.assoc_opt name !(rs.top_frame) with
         | Some cell ->
           (match !cell with
            | VMulti vs        -> VMulti (vs @ [v])
            | VClosure _ as c  -> VMulti [c; v]
            | _                -> v)
         | None -> v
     in
     fill name merged
   | DImpl { iface_name; type_args; methods; impl_name; _ } ->
     let score = tyvars_in_args type_args in
     let context_dependent_externs = ["pure"] in
     (* Reserve slots for overridable impl methods before evaluating bodies. *)
     List.iter (fun (name, _, _) ->
       if not (List.mem name context_dependent_externs) then
         (match List.assoc_opt name !(rs.top_frame) with
          | None -> add name VUnit
          | Some _ -> ())
     ) methods;
     rs.eval_env := [!(rs.top_frame)];
     (* Mirror eval_program's bookkeeping: for Applicative impls, record
        the `pure` body keyed by the impl type's head TyCon name; for
        Thenable impls, add the type's constructors to monadic_ctors. *)
     let rec head_tycon = function
       | Ast.TyCon n      -> Some n
       | Ast.TyApp (a, _) -> head_tycon a
       | Ast.TyConstrained (_, t) | Ast.TyEffect (_, t) -> head_tycon t
       | _ -> None
     in
     let tname_opt = match type_args with
       | [t] -> head_tycon t
       | _ -> None
     in
     (if iface_name = "Applicative" then
        match List.find_opt (fun (n, _, _) -> n = "pure") methods, tname_opt with
        | Some (_, pats, body), Some tname ->
          let v = wrap_match_errors (fun () ->
            if pats = [] then eval !(rs.eval_env) body
            else VClosure (!(rs.eval_env), pats, body)) in
          Hashtbl.replace pure_impls tname v
        | _ -> ());
     (if iface_name = "Thenable" then
        match tname_opt with
        | Some tname ->
          (* All of `tname`'s constructors should dispatch via andThen. *)
          Hashtbl.iter (fun cname tn ->
            if tn = tname then Hashtbl.replace monadic_ctors cname ()
          ) ctor_to_type
        | None -> ());
     let impl_type_tag = match type_args with
       | t :: _ -> head_tycon t
       | [] -> None
     in
     List.iter (fun (name, pats, body) ->
       if not (List.mem name context_dependent_externs) then begin
         let new_v = wrap_match_errors (fun () ->
           if pats = [] then eval !(rs.eval_env) body
           else VClosure (!(rs.eval_env), pats, body)) in
         let positions = lookup_dispatch_positions iface_name name in
         let typed_v = match impl_type_tag with
           | Some t -> VTypedImpl (t, positions, 0, new_v)
           | None   -> new_v
         in
         let tagged_v = match impl_name with
           | Some n -> VNamedImpl (n, typed_v)
           | None   -> typed_v
         in
         (* Merge with existing binding: extend VMulti (score-sorted) or set fresh. *)
         let merged =
           match List.assoc_opt name !(rs.top_frame) with
           | Some cell ->
             let existing = match !cell with
               | VMulti vs -> List.map (fun v -> (0, v)) vs  (* existing scores unknown; keep order *)
               | VUnit     -> []
               | old_v     -> [(0, old_v)]
             in
             let updated = existing @ [(score, tagged_v)] in
             let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
             VMulti (List.map snd sorted)
           | None -> tagged_v
         in
         fill name merged
       end
     ) methods
   | DNewtype (_, _, _, con, _, _) ->
     add con (make_ctor con 1)
   | DInterface { iface_name; type_params; methods; _ } ->
     record_iface_dispatch iface_name type_params methods;
     let score = List.length type_params in
     List.iter (fun m ->
       match m.method_default with
       | None -> ()
       | Some (pats, body) ->
         let name = m.method_name in
         (match List.assoc_opt name !(rs.top_frame) with
          | None -> add name VUnit
          | Some _ -> ());
         rs.eval_env := [!(rs.top_frame)];
         let new_v = if pats = [] then wrap_match_errors (fun () -> eval !(rs.eval_env) body)
                     else VClosure (!(rs.eval_env), pats, body) in
         let merged =
           match List.assoc_opt name !(rs.top_frame) with
           | Some cell ->
             let existing = match !cell with
               | VMulti vs -> List.map (fun v -> (0, v)) vs
               | VUnit     -> []
               | old_v     -> [(0, old_v)]
             in
             let updated = existing @ [(score, new_v)] in
             let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
             VMulti (List.map snd sorted)
           | None -> new_v
         in
         fill name merged
     ) methods
   | DLetGroup (_, bindings) ->
     (* Pre-allocate VUnit cells so each clause body can reference any
        group name; then fill them with closures or evaluated values. *)
     List.iter (fun (name, _) ->
       (match List.assoc_opt name !(rs.top_frame) with
        | None   -> add name VUnit
        | Some _ -> ())
     ) bindings;
     rs.eval_env := [!(rs.top_frame)];
     List.iter (fun (name, clauses) ->
       let closures = List.map (fun (pats, rhs) ->
         if pats = [] then wrap_match_errors (fun () -> eval !(rs.eval_env) rhs)
         else VClosure (!(rs.eval_env), pats, rhs)) clauses in
       let v = match closures with
         | [v] -> v
         | many -> VMulti many
       in
       fill name v
     ) bindings
   | DRecord _ | DTypeSig _ | DExtern _ | DUse _ | DTypeAlias _ | DProp _
   | DBench _ -> ()
   | DAttrib (_, d) ->
     eval_repl_decl rs d)

let eval_repl_expr (rs : repl_state) (e : expr) : value =
  rs.eval_env := [!(rs.top_frame)];
  wrap_match_errors (fun () -> eval !(rs.eval_env) e)

let make_repl_eval_state () : repl_state =
  (* Seed from a full eval_program run with an empty user program: that
     gives us the prelude's data types, interface methods, and impl bodies
     bound after eval_program's two-pass forward-reference handling, which
     the strictly incremental eval_repl_decl couldn't do on its own.
     True/False are pre-seeded separately because they're lexed as BOOL
     literals — they have no declaration in stdlib/core.mdk. *)
  let initial_bindings = eval_program [] in
  let top_frame : (string * value ref) list ref =
    ref (List.map (fun (k, v) -> (k, ref v)) initial_bindings) in
  let add name v = top_frame := (name, ref v) :: !top_frame in
  add "True"  (VBool true);
  add "False" (VBool false);
  let eval_env = ref [!top_frame] in
  { top_frame; eval_env }
