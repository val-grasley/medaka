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
  | VRecord of (string * value) list
  | VRef    of value ref
  | VClosure of env * pat list * expr
  | VPrim   of (value -> value)
  | VMulti  of value list  (* ordered impl closures for the same method; tried in sequence *)

and env = (string * value ref) list list

exception Eval_error of string * loc option
(* Raised instead of Eval_error when a pattern/match fails during dispatch so
   that VMulti.apply can silently fall through to the next impl candidate. *)
exception Impl_no_match

let output_hook : (string -> unit) ref = ref print_string

(* ── Env helpers ─────────────────────────────────────────────────────────── *)

let lookup env name =
  let rec search = function
    | [] -> raise (Eval_error ("unbound identifier: " ^ name, None))
    | frame :: rest ->
      (match List.assoc_opt name frame with
       | Some cell -> !cell
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
  | VRecord fields ->
    let pp_f (k, v) = k ^ " = " ^ pp_value v in
    "{ " ^ String.concat ", " (List.map pp_f fields) ^ " }"
  | VRef cell -> "Ref(" ^ pp_value !cell ^ ")"
  | VClosure _ -> "<closure>"
  | VPrim _    -> "<prim>"
  | VMulti vs  -> Printf.sprintf "<dispatch/%d>" (List.length vs)

and pp_value_atom v = match v with
  | VCon (_, _ :: _) | VTuple _ -> "(" ^ pp_value v ^ ")"
  | _ -> pp_value v

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

(* Type name → `pure` impl body.  Populated from `impl Applicative T` (and
   `impl Thenable T` if it overrides pure) declarations at eval init.  The
   `pure` primitive looks up this table using the current monad type. *)
let pure_impls : (string, value) Hashtbl.t = Hashtbl.create 4

let detect_monad = function
  | VCon (cname, _) ->
    (match Hashtbl.find_opt ctor_to_type cname with
     | Some tname -> Some tname
     | None -> None)
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
  | VMulti vs ->
    (* Apply each impl to arg; collect results.
       - Terminal result (non-closure): first one wins (return immediately).
       - VClosure/VMulti result (partial application): collect ALL that succeeded;
         return as a new VMulti so the next argument can dispatch correctly.
       - If all fail: dispatch error. *)
    let rec collect_partials acc = function
      | [] ->
        (match acc with
         | [] -> raise (Eval_error ("no matching impl for dispatch", !current_loc))
         | [v] -> v
         | many -> VMulti (List.rev many))
      | v :: rest ->
        (match (try Some (apply v arg) with Impl_no_match -> None) with
         | None -> collect_partials acc rest
         | Some (VClosure _ as c) -> collect_partials (c :: acc) rest
         | Some (VMulti _ as m) -> collect_partials (m :: acc) rest
         | Some terminal -> terminal)  (* first terminal result wins *)
    in
    collect_partials [] vs
  | _ ->
    raise (Eval_error ("applied non-function: " ^ pp_value fn, !current_loc))

and eval env expr =
  match expr with
  | ELoc (loc, e) ->
    current_loc := Some loc;
    eval env e

  | ELit (LInt n)    -> VInt n
  | ELit (LFloat f)  -> VFloat f
  | ELit (LString s) -> VString s
  | ELit (LChar c)   -> VChar c
  | ELit (LBool b)   -> VBool b
  | ELit LUnit       -> VUnit

  | EVar x -> lookup env x

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
    List.iter (fun (name, rhs) ->
      (List.assoc name cells) := eval env' rhs
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
     | VRecord fields ->
       (match List.assoc_opt "value" fields with
        | Some v -> v
        | None -> raise (Eval_error ("record has no field 'value'", !current_loc)))
     | _ -> raise (Eval_error ("field access on non-record/ref", !current_loc)))

  | EFieldAccess (e, field) ->
    (match eval env e with
     | VRecord fields ->
       (match List.assoc_opt field fields with
        | Some v -> v
        | None -> raise (Eval_error ("unknown field: " ^ field, !current_loc)))
     | _ -> raise (Eval_error ("field access on non-record", !current_loc)))

  | ERecordCreate (_, fields) ->
    VRecord (List.map (fun (k, e) -> (k, eval env e)) fields)

  | ERecordUpdate (base, fields) ->
    (match eval env base with
     | VRecord existing ->
       let updates = List.map (fun (k, e) -> (k, eval env e)) fields in
       let merged = List.map (fun (k, v) ->
         match List.assoc_opt k updates with
         | Some v' -> (k, v')
         | None -> (k, v)) existing
       in
       VRecord merged
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

  | EDo stmts ->
    let saved = !current_monad_type in
    current_monad_type := None;
    let result = eval_do env stmts in
    current_monad_type := saved;
    result

  | EAnnot (e, _) -> eval env e

  | EListComp _ -> assert false (* eliminated by desugar_list_comps *)

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
    (match eval env l, eval env r with
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

and eval_do env stmts =
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
     | VRecord _ -> VUnit  (* last stmt: shadow would be discarded anyway *)
     | _ -> raise (Eval_error ("field assignment on non-record/ref: " ^ x, !current_loc)))
  | [DoBind (_, _)] ->
    raise (Eval_error ("do-block cannot end with <-", !current_loc))

  | (DoExpr e) :: rest ->
    let _ = wrap_match_errors (fun () -> eval env e) in
    eval_do env rest

  | (DoLet (_, pat, e)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure in do", !current_loc))
     | Some binds -> eval_do (extend env binds) rest)

  | (DoAssign (x, e)) :: rest ->
    let v = wrap_match_errors (fun () -> eval env e) in
    eval_do (extend env [(x, v)]) rest

  | (DoFieldAssign (x, field, e)) :: rest ->
    let new_val = wrap_match_errors (fun () -> eval env e) in
    (match lookup env x with
     | VRef cell when field = "value" ->
       cell := new_val;
       eval_do env rest
     | VRecord fields ->
       let updated = VRecord (List.map (fun (k, v) ->
         if k = field then (k, new_val) else (k, v)) fields) in
       eval_do (extend env [(x, updated)]) rest
     | _ -> raise (Eval_error ("field assignment on non-record/ref: " ^ x, !current_loc)))

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
        | Some binds -> eval_do (extend env binds) rest
      ) in
      apply (apply and_then v) continuation
    in
    (match v with
     | VCon (cname, _) when Hashtbl.mem monadic_ctors cname ->
       dispatch_via_thenable ()
     | _ ->
       (match match_pat pat v with
        | None -> raise (Eval_error ("bind pattern match failure", !current_loc))
        | Some binds -> eval_do (extend env binds) rest))

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
    (* `map` and `filter` are no longer primitives — they are defined in
       stdlib/core.mdk as regular Medaka functions. *)
    ("fold",    VPrim (fun f ->
      VPrim (fun acc ->
        VPrim (fun lst ->
          List.fold_left
            (fun a v -> apply (apply f a) v)
            acc
            (unwrap_list lst)))));
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
    let has_ordering = List.exists (function
      | DData (_, "Ordering", _, _, _) -> true | _ -> false) program in
    let has_foldable = List.exists (function
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
  let type_ctors : (string, string list) Hashtbl.t = Hashtbl.create 8 in
  List.iter (function
    | DData (_, n, _, vs, _) ->
      let cnames = List.map (fun v -> v.con_name) vs in
      Hashtbl.replace type_ctors n cnames;
      List.iter (fun c -> Hashtbl.replace ctor_to_type c n) cnames
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
  List.iter (function
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
    match decl with
    | DNewtype (_, _, _, con, _, _) ->
      add_to_frame con (make_ctor con 1)
    | DData (_, _, _, variants, _) ->
      List.iter (fun v ->
        add_to_frame v.con_name (make_ctor v.con_name (List.length v.con_fields))
      ) variants
    | DFunDef (_, name, _, _) ->
      add_to_frame name VUnit
    | DImpl { methods; _ } ->
      List.iter (fun (name, _, _) ->
        if not (List.mem name context_dependent_externs) then
          add_to_frame name VUnit
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

  Hashtbl.clear pure_impls;
  List.iter (fun decl ->
    match decl with
    | DFunDef (_, name, pats, body) ->
      let v = wrap_match_errors (fun () ->
        if pats = [] then eval env body
        else VClosure (env, pats, body)) in
      fill_cell name v
    | DImpl { iface_name; type_args; methods; _ } ->
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
      List.iter (fun (name, pats, body) ->
        (* `pure` stays a primitive (it consults current_monad_type to pick
           the right impl from pure_impls); everything else, including
           interface methods like `map`/`fold`, is collected here so the
           regular VMulti dispatch path picks it up. *)
        if not (List.mem name context_dependent_externs) then begin
          let new_v = if pats = [] then wrap_match_errors (fun () -> eval env body)
                      else VClosure (env, pats, body) in
          let prev = try Hashtbl.find impl_acc name with Not_found -> [] in
          let updated = prev @ [(score, new_v)] in
          Hashtbl.replace impl_acc name updated;
          (* Re-sort and install immediately so subsequent DFunDef bodies that
             call this method see the correct VMulti binding. *)
          let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
          let closures = List.map snd sorted in
          fill_cell name (match closures with [v] -> v | many -> VMulti many)
        end
      ) methods
    | _ -> ()
  ) program;

  List.map (fun (k, cell) -> (k, !cell)) !top_frame

(* ── REPL incremental interface ─────────────────────────────────────────── *)

type repl_state = {
  top_frame : (string * value ref) list ref;
  eval_env  : env ref;
}

let eval_repl_decl (rs : repl_state) (decl : decl) : unit =
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
       add v.con_name (make_ctor v.con_name (List.length v.con_fields));
       Hashtbl.replace ctor_to_type v.con_name type_name
     ) variants
   | DFunDef (_, name, pats, body) ->
     add name VUnit;
     rs.eval_env := [!(rs.top_frame)];
     let v = wrap_match_errors (fun () ->
       if pats = [] then eval !(rs.eval_env) body
       else VClosure (!(rs.eval_env), pats, body)) in
     fill name v
   | DImpl { iface_name; type_args; methods; _ } ->
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
     List.iter (fun (name, pats, body) ->
       if not (List.mem name context_dependent_externs) then begin
         let new_v = wrap_match_errors (fun () ->
           if pats = [] then eval !(rs.eval_env) body
           else VClosure (!(rs.eval_env), pats, body)) in
         (* Merge with existing binding: extend VMulti (score-sorted) or set fresh. *)
         let merged =
           match List.assoc_opt name !(rs.top_frame) with
           | Some cell ->
             let existing = match !cell with
               | VMulti vs -> List.map (fun v -> (0, v)) vs  (* existing scores unknown; keep order *)
               | VUnit     -> []
               | old_v     -> [(0, old_v)]
             in
             let updated = existing @ [(score, new_v)] in
             let sorted  = List.stable_sort (fun (s1,_) (s2,_) -> compare s1 s2) updated in
             VMulti (List.map snd sorted)
           | None -> new_v
         in
         fill name merged
       end
     ) methods
   | DNewtype (_, _, _, con, _, _) ->
     add con (make_ctor con 1)
   | DRecord _ | DInterface _ | DTypeSig _ | DExtern _ | DUse _ | DTypeAlias _ -> ())

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
