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

and env = (string * value ref) list list

exception Eval_error of string * loc option

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

type monad_kind = MIO | MOption | MResult | MUnknown

let current_monad : monad_kind ref = ref MUnknown
let current_loc   : loc option ref = ref None

let detect_monad = function
  | VCon ("Some", _) | VCon ("None", []) -> MOption
  | VCon ("Ok", _)   | VCon ("Err", _)   -> MResult
  | _ -> MIO

(* ── Mutually recursive evaluator ───────────────────────────────────────── *)

let rec apply fn arg =
  match fn with
  | VClosure (env, [p], body) ->
    (match match_pat p arg with
     | None ->
       raise (Eval_error ("pattern match failure in function argument", !current_loc))
     | Some binds -> eval (extend env binds) body)
  | VClosure (env, p :: ps, body) ->
    (match match_pat p arg with
     | None ->
       raise (Eval_error ("pattern match failure in function argument", !current_loc))
     | Some binds -> VClosure (extend env binds, ps, body))
  | VClosure (_, [], _) ->
    raise (Eval_error ("applied closure with no parameters", !current_loc))
  | VPrim f -> f arg
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

  | ELet (_, pat, e1, e2) ->
    let v = eval env e1 in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure", !current_loc))
     | Some binds -> eval (extend env binds) e2)

  | EMatch (scrut, arms) ->
    let sv = eval env scrut in
    let rec try_arms = function
      | [] -> raise (Eval_error ("non-exhaustive match", !current_loc))
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

  | EUnOp ("not", e) ->
    (match eval env e with
     | VBool b -> VBool (not b)
     | _ -> raise (Eval_error ("'not' on non-Bool", !current_loc)))

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
    let saved = !current_monad in
    current_monad := MUnknown;
    let result = eval_do env stmts in
    current_monad := saved;
    result

  | EAnnot (e, _) -> eval env e

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
     | _ -> raise (Eval_error ("'++' requires two lists", !current_loc)))
  | "<>" ->
    (match eval env l, eval env r with
     | VString a, VString b -> VString (a ^ b)
     | _ -> raise (Eval_error ("'<>' requires two strings", !current_loc)))
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
  | "+.", VFloat a, VFloat b -> VFloat (a +. b)
  | "-.", VFloat a, VFloat b -> VFloat (a -. b)
  | "*.", VFloat a, VFloat b -> VFloat (a *. b)
  | "/.", VFloat a, VFloat b -> VFloat (a /. b)
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
  | [DoExpr e] -> eval env e
  | [DoLet (_, pat, e)] ->
    let v = eval env e in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure in do", !current_loc))
     | Some _ -> VUnit)
  | [DoAssign (_, e)] ->
    let _ = eval env e in VUnit
  | [DoBind (_, _)] ->
    raise (Eval_error ("do-block cannot end with <-", !current_loc))

  | (DoExpr e) :: rest ->
    let _ = eval env e in
    eval_do env rest

  | (DoLet (_, pat, e)) :: rest ->
    let v = eval env e in
    (match match_pat pat v with
     | None -> raise (Eval_error ("let pattern match failure in do", !current_loc))
     | Some binds -> eval_do (extend env binds) rest)

  | (DoAssign (x, e)) :: rest ->
    let v = eval env e in
    eval_do (extend env [(x, v)]) rest

  | (DoBind (pat, e)) :: rest ->
    let v = eval env e in
    if !current_monad = MUnknown then
      current_monad := detect_monad v;
    (match !current_monad, v with
     | MOption, VCon ("None", []) -> VCon ("None", [])
     | MOption, VCon ("Some", [inner]) ->
       (match match_pat pat inner with
        | None -> raise (Eval_error ("bind pattern match failure", !current_loc))
        | Some binds -> eval_do (extend env binds) rest)
     | MOption, VCon ("Some", _) ->
       raise (Eval_error ("Some with unexpected arity", !current_loc))
     | MResult, VCon ("Err", err_args) -> VCon ("Err", err_args)
     | MResult, VCon ("Ok", [inner]) ->
       (match match_pat pat inner with
        | None -> raise (Eval_error ("bind pattern match failure", !current_loc))
        | Some binds -> eval_do (extend env binds) rest)
     | MResult, VCon ("Ok", _) ->
       raise (Eval_error ("Ok with unexpected arity", !current_loc))
     | MIO, _ | MUnknown, _ ->
       (match match_pat pat v with
        | None -> raise (Eval_error ("bind pattern match failure", !current_loc))
        | Some binds -> eval_do (extend env binds) rest)
     | _ ->
       let monad_name = match !current_monad with
         | MOption -> "Option" | MResult -> "Result" | _ -> "?" in
       raise (Eval_error
                ("monad mismatch: expected " ^ monad_name
                 ^ " but got: " ^ pp_value v, !current_loc)))

(* ── Extern / primitive dispatch table ──────────────────────────────────── *)

let unwrap_list = function
  | VList vs -> vs
  | v -> raise (Eval_error ("expected list, got: " ^ pp_value v, None))

let primitives : (string * value) list =
  [
    ("print",   VPrim (fun v -> !output_hook (pp_value v); VUnit));
    ("println", VPrim (fun v -> !output_hook (pp_value v); !output_hook "\n"; VUnit));
    ("pure",    VPrim (fun v ->
      match !current_monad with
      | MOption        -> VCon ("Some", [v])
      | MResult        -> VCon ("Ok", [v])
      | MIO | MUnknown -> v));
    ("Ref",     VPrim (fun v -> VRef (ref v)));
    ("set_ref", VPrim (fun r ->
      VPrim (fun v ->
        match r with
        | VRef cell -> cell := v; VUnit
        | _ -> raise (Eval_error ("set_ref: not a Ref", None)))));
    ("map",     VPrim (fun f ->
      VPrim (fun lst -> VList (List.map (apply f) (unwrap_list lst)))));
    ("filter",  VPrim (fun f ->
      VPrim (fun lst ->
        VList (List.filter
                 (fun v -> match apply f v with
                    | VBool b -> b
                    | _ -> raise (Eval_error ("filter: predicate not Bool", None)))
                 (unwrap_list lst)))));
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
  ]

let () =
  let dispatch_names = List.map fst primitives in
  List.iter (fun n ->
    if not (List.mem n dispatch_names) then
      failwith ("runtime.mdk extern '" ^ n ^ "' has no OCaml impl in eval.ml")
  ) Runtime.names

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

  (* Seed with built-in constructors that don't come from DData *)
  add_to_frame "True"  (VBool true);
  add_to_frame "False" (VBool false);
  add_to_frame "None"  (VCon ("None", []));
  add_to_frame "Some"  (make_ctor "Some" 1);
  add_to_frame "Ok"    (make_ctor "Ok" 1);
  add_to_frame "Err"   (make_ctor "Err" 1);

  (* Seed with primitives *)
  List.iter (fun (name, v) -> add_to_frame name v) (List.rev primitives);

  (* Pass 1: collect DData constructors and DFunDef/DImpl method names *)
  List.iter (fun decl ->
    match decl with
    | DData (_, _, _, variants, _) ->
      List.iter (fun v ->
        add_to_frame v.con_name (make_ctor v.con_name (List.length v.con_fields))
      ) variants
    | DFunDef (_, name, _, _) ->
      add_to_frame name VUnit
    | DImpl { methods; _ } ->
      List.iter (fun (name, _, _) -> add_to_frame name VUnit) methods
    | _ -> ()
  ) program;

  let env : env = [!top_frame] in

  let fill_cell name v =
    match List.assoc_opt name !top_frame with
    | Some cell -> cell := v
    | None -> ()
  in

  (* Pass 2: evaluate DFunDef and DImpl bodies *)
  List.iter (fun decl ->
    match decl with
    | DFunDef (_, name, pats, body) ->
      let v = if pats = [] then eval env body
              else VClosure (env, pats, body) in
      fill_cell name v
    | DImpl { methods; _ } ->
      List.iter (fun (name, pats, body) ->
        let v = if pats = [] then eval env body
                else VClosure (env, pats, body) in
        fill_cell name v
      ) methods
    | _ -> ()
  ) program;

  List.map (fun (k, cell) -> (k, !cell)) !top_frame

(* ── REPL incremental interface ─────────────────────────────────────────── *)

type repl_state = {
  top_frame : (string * value ref) list ref;
  eval_env  : env ref;
}

let make_repl_eval_state () : repl_state =
  let top_frame : (string * value ref) list ref = ref [] in
  let add name v = top_frame := (name, ref v) :: !top_frame in
  add "True"  (VBool true);
  add "False" (VBool false);
  add "None"  (VCon ("None", []));
  add "Some"  (make_ctor "Some" 1);
  add "Ok"    (make_ctor "Ok" 1);
  add "Err"   (make_ctor "Err" 1);
  List.iter (fun (name, v) -> add name v) (List.rev primitives);
  let eval_env = ref [!top_frame] in
  { top_frame; eval_env }

let eval_repl_decl (rs : repl_state) (decl : decl) : unit =
  let add name v = rs.top_frame := (name, ref v) :: !(rs.top_frame) in
  let fill name v =
    match List.assoc_opt name !(rs.top_frame) with
    | Some cell -> cell := v
    | None -> add name v
  in
  rs.eval_env := [!(rs.top_frame)];
  (match decl with
   | DData (_, _, _, variants, _) ->
     List.iter (fun v ->
       add v.con_name (make_ctor v.con_name (List.length v.con_fields))
     ) variants
   | DFunDef (_, name, pats, body) ->
     add name VUnit;
     rs.eval_env := [!(rs.top_frame)];
     let v = if pats = [] then eval !(rs.eval_env) body
             else VClosure (!(rs.eval_env), pats, body) in
     fill name v
   | DImpl { methods; _ } ->
     List.iter (fun (name, _, _) -> add name VUnit) methods;
     rs.eval_env := [!(rs.top_frame)];
     List.iter (fun (name, pats, body) ->
       let v = if pats = [] then eval !(rs.eval_env) body
               else VClosure (!(rs.eval_env), pats, body) in
       fill name v
     ) methods
   | DRecord _ | DInterface _ | DTypeSig _ | DExtern _ | DUse _ -> ())

let eval_repl_expr (rs : repl_state) (e : expr) : value =
  rs.eval_env := [!(rs.top_frame)];
  eval !(rs.eval_env) e
