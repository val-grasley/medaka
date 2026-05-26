(* Name resolution: walk the AST after parsing, verify that every
   identifier reference resolves to a binding. Produces a list of errors;
   does not modify the AST. *)

open Ast

(* ── Errors ────────────────────────────────────── *)

type error =
  | UnboundVariable      of ident
  | UnknownConstructor   of ident
  | UnknownType          of ident
  | UnknownEffect        of ident
  | UnknownField         of ident          (* field name not declared in any record *)
  | FieldNotInRecord     of ident * ident  (* field, record — field exists but not in this record *)
  | DuplicateDefinition  of string * ident  (* kind, name *)
  | UnknownInterface     of ident           (* impl references an unknown interface *)
  | MethodNotInInterface of ident * ident   (* method name, interface name *)
  | ExternWithBody       of ident           (* extern name also has a fun_def *)
  | PrivateNameAccess    of ident * string  (* name, owning module *)
  | UnknownModule        of ident           (* use references a module that can't be found *)

let current_loc : Ast.loc option ref = ref None

let pp_error = function
  | UnboundVariable n      -> Printf.sprintf "Unbound variable: %s" n
  | UnknownConstructor n   -> Printf.sprintf "Unknown constructor: %s" n
  | UnknownType n          -> Printf.sprintf "Unknown type: %s" n
  | UnknownEffect n        -> Printf.sprintf "Unknown effect: %s" n
  | UnknownField n         -> Printf.sprintf "Unknown field: %s" n
  | FieldNotInRecord (f, r)-> Printf.sprintf "Field %s does not belong to record %s" f r
  | DuplicateDefinition (k, n) -> Printf.sprintf "Duplicate %s: %s" k n
  | UnknownInterface n     -> Printf.sprintf "Unknown interface: %s" n
  | MethodNotInInterface (m, iface) ->
    Printf.sprintf "Method '%s' is not part of interface %s" m iface
  | ExternWithBody n ->
    Printf.sprintf "extern '%s' must not have a definition body" n
  | PrivateNameAccess (n, m) ->
    Printf.sprintf "'%s' is private to module %s" n m
  | UnknownModule n ->
    Printf.sprintf "Unknown module: %s" n

(* ── Built-ins ─────────────────────────────────── *)

(* Until the stdlib exists, these are baked in. *)

let primitive_types = [
  "Int"; "Float"; "String"; "Char"; "Bool"; "Unit";
  "List"; "Option"; "Result"; "Ref";
  "Array"; "MutArray"; "Map"; "HashMap"; "Set"; "HashSet";
]

let primitive_constructors = [
  "True"; "False"; "Some"; "None"; "Ok"; "Err";
]

let primitive_values = Runtime.names

let built_in_effects = [
  "IO"; "Mut"; "Async"; "Panic"; "Rand"; "Time";
]

(* ── Module exports (public interface of a resolved module) ── *)

type module_exports = {
  exp_mod_id          : string;
  exp_values          : (ident, unit) Hashtbl.t;
  exp_types           : (ident, unit) Hashtbl.t;
  exp_constructors    : (ident, unit) Hashtbl.t;
  exp_fields          : (ident, unit) Hashtbl.t;
  exp_field_owners    : (ident, string) Hashtbl.t;
  exp_interfaces      : (ident, unit) Hashtbl.t;
  exp_iface_methods   : (ident, ident list) Hashtbl.t;
}

(* ── Module environment ────────────────────────── *)

type module_env = {
  values         : (ident, unit) Hashtbl.t;
  types          : (ident, unit) Hashtbl.t;
  constructors   : (ident, unit) Hashtbl.t;
  fields         : (ident, unit) Hashtbl.t;
  field_owners   : (ident, string) Hashtbl.t;  (* field name → record type name *)
  interfaces     : (ident, unit) Hashtbl.t;
  iface_methods  : (ident, ident list) Hashtbl.t;  (* iface name → method names *)
  imported       : (ident, unit) Hashtbl.t;
  (* Alias map: for `use foo as F` or qualified `use foo`, F/foo → module_exports *)
  module_aliases : (ident, module_exports) Hashtbl.t;
}

let create_env () =
  let env = {
    values         = Hashtbl.create 32;
    types          = Hashtbl.create 16;
    constructors   = Hashtbl.create 16;
    fields         = Hashtbl.create 16;
    field_owners   = Hashtbl.create 16;
    interfaces     = Hashtbl.create 8;
    iface_methods  = Hashtbl.create 8;
    imported       = Hashtbl.create 8;
    module_aliases = Hashtbl.create 4;
  } in
  List.iter (fun n -> Hashtbl.replace env.types n ()) primitive_types;
  List.iter (fun n -> Hashtbl.replace env.constructors n ()) primitive_constructors;
  List.iter (fun n -> Hashtbl.replace env.values n ()) primitive_values;
  env

(* ── Pattern utilities ─────────────────────────── *)

let rec pat_bindings = function
  | PVar x       -> [x]
  | PWild        -> []
  | PLit _       -> []
  | PCon (_, ps) -> List.concat_map pat_bindings ps
  | PCons (a, b) -> pat_bindings a @ pat_bindings b
  | PTuple ps    -> List.concat_map pat_bindings ps
  | PList ps     -> List.concat_map pat_bindings ps

(* ── Phase 1: build env from top-level decls ──── *)

(* Resolve a use_path against known module exports, returning the module_id
   that the path refers to. *)
let use_path_module_id = function
  | UseName ns ->
    (* use foo.bar → module "foo", name "bar";  use foo → module "foo" (alias) *)
    if List.length ns > 1 then
      String.concat "." (List.rev (List.tl (List.rev ns)))
    else
      List.hd ns
  | UseGroup (ns, _) -> String.concat "." ns
  | UseWild  ns      -> String.concat "." ns
  | UseAlias (ns, _) -> String.concat "." ns

(* Names introduced into scope by a use_path, given the referenced module's exports.
   Returns (values, types) lists to add. *)
let imported_names (path : use_path) (exp : module_exports)
    (report : error -> unit) =
  let add_val   n = Hashtbl.mem exp.exp_values   n in
  let add_type  n = Hashtbl.mem exp.exp_types    n in
  let add_ctor  n = Hashtbl.mem exp.exp_constructors n in
  let is_pub    n = add_val n || add_type n || add_ctor n
                    || Hashtbl.mem exp.exp_interfaces n in
  let check_pub n =
    if not (is_pub n) then
      report (PrivateNameAccess (n, exp.exp_mod_id))
  in
  match path with
  | UseName ns ->
    (* use foo.bar: bring "bar" into scope if public *)
    if List.length ns > 1 then begin
      let name = List.hd (List.rev ns) in
      check_pub name;
      [name]
    end else
      (* use foo alone: just register alias, no individual names *)
      []
  | UseGroup (_, members) ->
    List.iter check_pub members;
    members
  | UseWild _ ->
    (* bring all public names *)
    let names = ref [] in
    Hashtbl.iter (fun n () -> names := n :: !names) exp.exp_values;
    Hashtbl.iter (fun n () -> names := n :: !names) exp.exp_types;
    Hashtbl.iter (fun n () -> names := n :: !names) exp.exp_constructors;
    !names
  | UseAlias (_, alias) ->
    (* alias only; the alias itself is in module_aliases, no individual names *)
    [alias]

let build_env ?(known_modules : module_exports list = [])
    (prog : program) : module_env * (error * Ast.loc option) list =
  let env = create_env () in
  let errors = ref [] in
  let report e = errors := (e, None) :: !errors in
  let add_unique tbl kind name =
    if Hashtbl.mem tbl name then
      report (DuplicateDefinition (kind, name))
    else
      Hashtbl.replace tbl name ()
  in
  let add_or_skip tbl name = Hashtbl.replace tbl name () in
  (* Pre-collect extern names so DFunDef can check for conflicts in any order *)
  let extern_names =
    List.filter_map (function DExtern (_, n, _) -> Some n | _ -> None) prog
  in
  List.iter (fun d ->
    match d with
    | DTypeSig (_, n, _) ->
      (* Type sig pairs with later fun_def; either order works *)
      add_or_skip env.values n
    | DExtern (_, n, _) ->
      add_or_skip env.values n
    | DFunDef (_, n, _, _) ->
      if List.mem n extern_names then report (ExternWithBody n);
      (* Multi-clause definitions add the same name repeatedly *)
      add_or_skip env.values n
    | DData (_, n, _, vs, _) ->
      add_unique env.types "type" n;
      List.iter (fun v ->
        add_unique env.constructors "constructor" v.con_name
      ) vs
    | DRecord (_, n, _, fs, _) ->
      add_unique env.types "type" n;
      List.iter (fun f ->
        add_or_skip env.fields f.field_name;
        Hashtbl.replace env.field_owners f.field_name n
      ) fs
    | DInterface { iface_name; methods; _ } ->
      add_unique env.interfaces "interface" iface_name;
      List.iter (fun m -> add_or_skip env.values m.method_name) methods;
      Hashtbl.replace env.iface_methods iface_name
        (List.map (fun m -> m.method_name) methods)
    | DImpl _ ->
      ()
    | DUse (_, path) ->
      let mod_id = use_path_module_id path in
      (match List.find_opt (fun e -> e.exp_mod_id = mod_id) known_modules with
       | None ->
         if known_modules <> [] then
           (* Only report if we're in multi-module mode *)
           report (UnknownModule mod_id)
         else begin
           (* Single-file mode: stub (legacy behaviour) *)
           let names = match path with
             | UseName ns       -> [List.hd (List.rev ns)]
             | UseGroup (_, ms) -> ms
             | UseWild _        -> []
             | UseAlias (_, a)  -> [a]
           in
           List.iter (fun n ->
             add_or_skip env.imported n;
             add_or_skip env.values n;
             add_or_skip env.types n
           ) names
         end
       | Some exp ->
         (* Import names from the module's public exports *)
         let names = imported_names path exp (fun e -> report e) in
         List.iter (fun n ->
           add_or_skip env.imported n;
           (* Add to values/types/constructors as appropriate *)
           if Hashtbl.mem exp.exp_values n then add_or_skip env.values n;
           if Hashtbl.mem exp.exp_types  n then add_or_skip env.types  n;
           if Hashtbl.mem exp.exp_constructors n then
             add_or_skip env.constructors n;
           if Hashtbl.mem exp.exp_interfaces n then
             add_or_skip env.interfaces n
         ) names;
         (* Copy field ownership for imported record types *)
         Hashtbl.iter (fun field owner ->
           if Hashtbl.mem exp.exp_types owner then begin
             add_or_skip env.fields field;
             Hashtbl.replace env.field_owners field owner
           end
         ) exp.exp_field_owners;
         (* Register module alias / qualified-access name *)
         let alias = match path with
           | UseAlias (_, a)      -> Some a
           | UseName [single]     -> Some single  (* use foo → foo.x syntax *)
           | _                    -> None
         in
         (match alias with
          | Some a -> Hashtbl.replace env.module_aliases a exp
          | None   -> ()))
  ) prog;
  env, List.rev !errors

(* ── Phase 2: walk decls checking references ──── *)

let lookup_value env scope name =
  List.mem name scope
  || Hashtbl.mem env.values name
  || Hashtbl.mem env.constructors name
  || Hashtbl.mem env.imported name

let emit errors e = errors := (e, !current_loc) :: !errors

let rec check_pat env errors p =
  match p with
  | PVar _ | PWild | PLit _ -> ()
  | PCon (c, ps) ->
    if not (Hashtbl.mem env.constructors c || Hashtbl.mem env.imported c) then
      emit errors (UnknownConstructor c);
    List.iter (check_pat env errors) ps
  | PCons (a, b) ->
    check_pat env errors a;
    check_pat env errors b
  | PTuple ps | PList ps ->
    List.iter (check_pat env errors) ps

let rec check_type env errors t =
  match t with
  | TyCon n ->
    if not (Hashtbl.mem env.types n || Hashtbl.mem env.imported n) then
      emit errors (UnknownType n)
  | TyVar _ -> ()
  | TyApp (a, b) | TyFun (a, b) ->
    check_type env errors a; check_type env errors b
  | TyTuple ts ->
    List.iter (check_type env errors) ts
  | TyEffect (es, t) ->
    List.iter (fun e ->
      if not (List.mem e built_in_effects) then
        emit errors (UnknownEffect e)
    ) es;
    check_type env errors t

let rec check_expr env scope errors e =
  match e with
  | ELoc (l, e') ->
    current_loc := Some l;
    check_expr env scope errors e'
  | ELit _ -> ()
  | EVar n ->
    if not (lookup_value env scope n) then
      emit errors (UnboundVariable n)
  | EApp (f, x) ->
    check_expr env scope errors f;
    check_expr env scope errors x
  | ELam (pats, body) ->
    List.iter (check_pat env errors) pats;
    let scope' = List.concat_map pat_bindings pats @ scope in
    check_expr env scope' errors body
  | ELet (_, pat, e1, e2) ->
    check_pat env errors pat;
    check_expr env scope errors e1;     (* RHS in outer scope *)
    let scope' = pat_bindings pat @ scope in
    check_expr env scope' errors e2     (* body in extended scope *)
  | EMatch (sc, arms) ->
    check_expr env scope errors sc;
    List.iter (fun (pat, guard, body) ->
      check_pat env errors pat;
      let scope' = pat_bindings pat @ scope in
      (match guard with
       | None -> ()
       | Some g -> check_expr env scope' errors g);
      check_expr env scope' errors body
    ) arms
  | EIf (c, t, e) ->
    check_expr env scope errors c;
    check_expr env scope errors t;
    check_expr env scope errors e
  | EBinOp (_, l, r) ->
    check_expr env scope errors l;
    check_expr env scope errors r
  | EUnOp (_, e) ->
    check_expr env scope errors e
  | EFieldAccess (e, _) ->
    (* Field name validation deferred to the type checker *)
    check_expr env scope errors e
  | ERecordCreate (name, fs) ->
    if not (Hashtbl.mem env.types name || Hashtbl.mem env.imported name) then
      emit errors (UnknownType name)
    else begin
      (* Each field must belong to the named record *)
      List.iter (fun (fname, _) ->
        match Hashtbl.find_opt env.field_owners fname with
        | None -> emit errors (UnknownField fname)
        | Some owner when owner <> name ->
          emit errors (FieldNotInRecord (fname, name))
        | Some _ -> ()
      ) fs
    end;
    List.iter (fun (_, v) -> check_expr env scope errors v) fs
  | ERecordUpdate (e, fs) ->
    check_expr env scope errors e;
    (* All updated fields must belong to the same record *)
    let record_name =
      match fs with
      | [] -> None
      | (fname, _) :: _ ->
        (match Hashtbl.find_opt env.field_owners fname with
         | None ->
           emit errors (UnknownField fname); None
         | Some r -> Some r)
    in
    List.iter (fun (fname, v) ->
      check_expr env scope errors v;
      (match record_name with
       | None -> ()
       | Some r ->
         match Hashtbl.find_opt env.field_owners fname with
         | None -> emit errors (UnknownField fname)
         | Some owner when owner <> r ->
           emit errors (FieldNotInRecord (fname, r))
         | Some _ -> ())
    ) fs
  | EArrayLit es | EListLit es | ETuple es ->
    List.iter (check_expr env scope errors) es
  | EMapLit (_, kvs) ->
    List.iter (fun (k, v) -> check_expr env scope errors k; check_expr env scope errors v) kvs
  | ESetLit (_, es) ->
    List.iter (check_expr env scope errors) es
  | EIndex (e, i) ->
    check_expr env scope errors e;
    check_expr env scope errors i
  | EDo stmts ->
    let _final_scope =
      List.fold_left (fun scope stmt ->
        match stmt with
        | DoBind (pat, e) ->
          check_pat env errors pat;
          check_expr env scope errors e;
          pat_bindings pat @ scope
        | DoExpr e ->
          check_expr env scope errors e;
          scope
        | DoLet (_, pat, e) ->
          check_pat env errors pat;
          check_expr env scope errors e;
          pat_bindings pat @ scope
        | DoAssign (x, e) ->
          if not (lookup_value env scope x) then
            emit errors (UnboundVariable x);
          check_expr env scope errors e;
          scope
      ) scope stmts
    in ()
  | EAnnot (e, t) ->
    check_expr env scope errors e;
    check_type env errors t
  | EInfix (op, l, r) ->
    if not (lookup_value env scope op) then
      emit errors (UnboundVariable op);
    check_expr env scope errors l;
    check_expr env scope errors r

let check_decl env errors = function
  | DFunDef (_, _, pats, body) ->
    List.iter (check_pat env errors) pats;
    let scope = List.concat_map pat_bindings pats in
    check_expr env scope errors body
  | DTypeSig (_, _, t) ->
    check_type env errors t
  | DExtern (_, _, t) ->
    check_type env errors t
  | DData (_, _, _, vs, _) ->
    List.iter (fun v -> List.iter (check_type env errors) v.con_fields) vs
  | DRecord (_, _, _, fs, _) ->
    List.iter (fun f -> check_type env errors f.field_type) fs
  | DUse _ -> ()
  | DInterface { methods; _ } ->
    List.iter (fun m ->
      check_type env errors m.method_type;
      match m.method_default with
      | None -> ()
      | Some (pats, body) ->
        List.iter (check_pat env errors) pats;
        let scope = List.concat_map pat_bindings pats in
        check_expr env scope errors body
    ) methods
  | DImpl { iface_name; type_args; methods; _ } ->
    List.iter (check_type env errors) type_args;
    List.iter (fun (_, pats, body) ->
      List.iter (check_pat env errors) pats;
      let scope = List.concat_map pat_bindings pats in
      check_expr env scope errors body
    ) methods;
    if not (Hashtbl.mem env.interfaces iface_name) then
      emit errors (UnknownInterface iface_name)
    else begin
      let known_methods =
        try Hashtbl.find env.iface_methods iface_name with Not_found -> []
      in
      List.iter (fun (mname, _, _) ->
        if not (List.mem mname known_methods) then
          emit errors (MethodNotInInterface (mname, iface_name))
      ) methods
    end

(* ── Build module exports from a resolved env ─── *)

(* Collect all public names from a program into module_exports *)
let build_exports (mod_id : string) (prog : program) (env : module_env)
    : module_exports =
  let exp = {
    exp_mod_id        = mod_id;
    exp_values        = Hashtbl.create 16;
    exp_types         = Hashtbl.create 8;
    exp_constructors  = Hashtbl.create 8;
    exp_fields        = Hashtbl.create 8;
    exp_field_owners  = Hashtbl.create 8;
    exp_interfaces    = Hashtbl.create 4;
    exp_iface_methods = Hashtbl.create 4;
  } in
  List.iter (fun d ->
    match d with
    | DTypeSig (true, n, _) ->
      Hashtbl.replace exp.exp_values n ()
    | DExtern (true, n, _) ->
      Hashtbl.replace exp.exp_values n ()
    | DFunDef (true, n, _, _) ->
      Hashtbl.replace exp.exp_values n ()
    | DData (true, n, _, vs, _) ->
      Hashtbl.replace exp.exp_types n ();
      List.iter (fun v ->
        Hashtbl.replace exp.exp_constructors v.con_name ()
      ) vs
    | DRecord (true, n, _, fs, _) ->
      Hashtbl.replace exp.exp_types n ();
      List.iter (fun f ->
        Hashtbl.replace exp.exp_fields f.field_name ();
        Hashtbl.replace exp.exp_field_owners f.field_name n
      ) fs
    | DInterface { is_pub = true; iface_name; methods; _ } ->
      Hashtbl.replace exp.exp_interfaces iface_name ();
      Hashtbl.replace exp.exp_iface_methods iface_name
        (List.map (fun m -> m.method_name) methods)
    | DImpl { is_pub = true; _ } ->
      (* Impl declarations export their methods via the interface's methods;
         we don't need to separately export the impl itself. *)
      ()
    | _ -> ()
  ) prog;
  (* Also export interface method names whose interface is public *)
  Hashtbl.iter (fun iface_name methods ->
    if Hashtbl.mem exp.exp_interfaces iface_name then
      List.iter (fun mn ->
        if Hashtbl.mem env.values mn then
          Hashtbl.replace exp.exp_values mn ()
      ) methods
  ) exp.exp_iface_methods;
  exp

(* ── Public entry points ──────────────────────── *)

let resolve_program (prog : program) : (error * Ast.loc option) list =
  current_loc := None;
  let env, build_errors = build_env prog in
  let errors = ref build_errors in
  List.iter (check_decl env errors) prog;
  List.rev !errors

(* Multi-module entry point: resolve one module given previously-resolved exports.
   Returns (module_exports, errors). *)
let resolve_module
    (known_modules : module_exports list)
    (mod_id        : string)
    (prog          : program)
    : module_exports * (error * Ast.loc option) list =
  current_loc := None;
  let env, build_errors = build_env ~known_modules prog in
  let errors = ref build_errors in
  List.iter (check_decl env errors) prog;
  let exports = build_exports mod_id prog env in
  (exports, List.rev !errors)

(* ── REPL incremental interface ──────────────── *)

let make_repl_resolve_env () : module_env = create_env ()

(* Add declarations from `decls` into an existing `env` in place, then check
   references.  Returns any errors found. *)
let resolve_repl_item (env : module_env) (item : Ast.repl_item)
    : (error * Ast.loc option) list =
  current_loc := None;
  let errors = ref [] in
  let report e = errors := (e, None) :: !errors in
  let add_unique tbl kind name =
    if Hashtbl.mem tbl name then report (DuplicateDefinition (kind, name))
    else Hashtbl.replace tbl name ()
  in
  let add_or_skip tbl name = Hashtbl.replace tbl name () in
  let decls = match item with
    | Ast.ReplDecl ds -> ds
    | Ast.ReplExpr _ -> []
  in
  let extern_names =
    List.filter_map (function Ast.DExtern (_, n, _) -> Some n | _ -> None) decls
  in
  List.iter (fun d ->
    match d with
    | Ast.DTypeSig (_, n, _) -> add_or_skip env.values n
    | Ast.DExtern (_, n, _)  -> add_or_skip env.values n
    | Ast.DFunDef (_, n, _, _) ->
      if List.mem n extern_names then report (ExternWithBody n);
      add_or_skip env.values n
    | Ast.DData (_, n, _, vs, _) ->
      add_unique env.types "type" n;
      List.iter (fun v -> add_unique env.constructors "constructor" v.Ast.con_name) vs
    | Ast.DRecord (_, n, _, fs, _) ->
      add_unique env.types "type" n;
      List.iter (fun f ->
        add_or_skip env.fields f.Ast.field_name;
        Hashtbl.replace env.field_owners f.Ast.field_name n
      ) fs
    | Ast.DInterface { iface_name; methods; _ } ->
      add_unique env.interfaces "interface" iface_name;
      List.iter (fun m -> add_or_skip env.values m.Ast.method_name) methods;
      Hashtbl.replace env.iface_methods iface_name
        (List.map (fun m -> m.Ast.method_name) methods)
    | Ast.DImpl _ | Ast.DUse _ -> ()
  ) decls;
  (match item with
   | Ast.ReplDecl ds -> List.iter (check_decl env errors) ds
   | Ast.ReplExpr e  -> check_expr env [] errors e);
  List.rev !errors
