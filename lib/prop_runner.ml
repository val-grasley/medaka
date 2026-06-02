open Ast

type test_result =
  | Passed of int
  | Failed of {
      run    : int;
      shrunk : (string * Eval.value) list;
    }

(* Generate a random string of printable ASCII characters (length 0..10). *)
let gen_string () =
  let n = Random.int 11 in
  String.init n (fun _ -> Char.chr (32 + Random.int 95))

(* A user type's definition, read from the program's declarations so the
   generator can build values structurally with the type's arguments
   substituted in (so `Tree Int` generates `Int` leaves, `Tree String`
   strings).  DNewtype is modelled as a single-constructor positional data. *)
type tydef =
  | TDData   of ident list * data_variant list  (* params, variants *)
  | TDRecord of ident list * record_field list   (* params, fields *)

(* Build the type-definition map from a (post-desugar) program. *)
let build_tydefs program : (ident, tydef) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  List.iter (fun d -> match Ast.inner_decl d with
    | DData (_, name, params, variants, _) ->
      Hashtbl.replace tbl name (TDData (params, variants))
    | DRecord (_, name, params, fields, _) ->
      Hashtbl.replace tbl name (TDRecord (params, fields))
    | DNewtype (_, name, params, con, fty, _) ->
      Hashtbl.replace tbl name
        (TDData (params, [{ con_name = con; con_payload = ConPos [fty] }]))
    | _ -> ()
  ) program;
  tbl

(* Substitute type variables (from a param→arg binding) throughout a type. *)
let rec subst_ty subst = function
  | TyVar v as t -> (match List.assoc_opt v subst with Some t' -> t' | None -> t)
  | TyApp (a, b)  -> TyApp (subst_ty subst a, subst_ty subst b)
  | TyTuple ts    -> TyTuple (List.map (subst_ty subst) ts)
  | TyFun (a, b)  -> TyFun (subst_ty subst a, subst_ty subst b)
  | t -> t

(* Peel a TyApp spine into its head constructor name and argument list:
   `Pair a b` → Some ("Pair", [a; b]); `Int` → Some ("Int", []). *)
let rec ty_spine acc = function
  | TyApp (f, a) -> ty_spine (a :: acc) f
  | TyCon n      -> Some (n, acc)
  | _            -> None

(* Generate a random value for the given AST type.  `subst` maps the in-scope
   type parameters to their concrete arguments; built-ins are handled natively,
   user data/record types are generated structurally from their definitions in
   `tydefs`, and remaining nullary types fall back to arbitrary_registry. *)
let rec gen_for_type tydefs subst ty =
  match ty with
  | TyVar v ->
    (match List.assoc_opt v subst with
     | Some t -> gen_for_type tydefs subst t
     | None ->
       failwith (Printf.sprintf
         "prop_runner: cannot generate values for unbound type variable '%s'" v))
  | TyCon "Int"    -> Eval.VInt (Random.int 2001 - 1000)
  | TyCon "Bool"   -> Eval.VBool (Random.bool ())
  | TyCon "Float"  -> Eval.VFloat (Random.float 2.0 -. 1.0)
  | TyCon "Char"   -> Eval.VChar (String.make 1 (Char.chr (32 + Random.int 95)))
  | TyCon "String" -> Eval.VString (gen_string ())
  | TyCon "Unit"   -> Eval.VUnit
  | TyApp (TyCon "List", t) ->
    let n = Random.int 8 in
    Eval.VList (List.init n (fun _ -> gen_for_type tydefs subst t))
  | TyApp (TyCon "Array", t) ->
    let n = Random.int 8 in
    Eval.VArray (Array.init n (fun _ -> gen_for_type tydefs subst t))
  | TyApp (TyCon "Option", t) ->
    if Random.bool () then Eval.VCon ("None", [])
    else Eval.VCon ("Some", [gen_for_type tydefs subst t])
  | TyApp (TyCon "Result", t) ->
    if Random.bool () then Eval.VCon ("Ok",  [gen_for_type tydefs subst t])
    else Eval.VCon ("Err", [gen_for_type tydefs subst t])
  | TyTuple ts -> Eval.VTuple (List.map (gen_for_type tydefs subst) ts)
  | _ ->
    (match ty_spine [] ty with
     | Some (name, args) ->
       (match Hashtbl.find_opt tydefs name with
        | Some tydef -> gen_user tydefs subst name tydef args
        | None ->
          (* No structural definition: a nullary user type with a hand-written
             impl can still be served by the registry. *)
          (match args, Hashtbl.find_opt Eval.arbitrary_registry name with
           | [], Some gen -> gen ()
           | [], None ->
             failwith (Printf.sprintf
               "prop_runner: no Arbitrary instance for type '%s'. \
                Add 'deriving (Arbitrary)' or an explicit impl." name)
           | _ ->
             failwith (Printf.sprintf
               "prop_runner: cannot generate values for type '%s'" (pp_ty ty))))
     | None ->
       failwith (Printf.sprintf
         "prop_runner: cannot generate values for type '%s'" (pp_ty ty)))

(* Generate a value for a user data/record type, binding its parameters to the
   (resolved) type arguments before generating each field. *)
and gen_user tydefs subst name tydef args =
  let args = List.map (subst_ty subst) args in
  match tydef with
  | TDData (params, variants) ->
    let subst' = if List.length params = List.length args
                 then List.combine params args else [] in
    let v = List.nth variants (Random.int (List.length variants)) in
    (match v.con_payload with
     | ConPos tys ->
       Eval.VCon (v.con_name, List.map (gen_for_type tydefs subst') tys)
     | ConNamed fields ->
       (* ConNamed data variants evaluate to VCon in field order (matching
          eval's ctor_field_order), so pattern/field access lines up. *)
       Eval.VCon (v.con_name,
         List.map (fun f -> gen_for_type tydefs subst' f.field_type) fields))
  | TDRecord (params, fields) ->
    let subst' = if List.length params = List.length args
                 then List.combine params args else [] in
    Eval.VRecord (name,
      List.map (fun f ->
        (f.field_name, gen_for_type tydefs subst' f.field_type)) fields)

(* Produce candidate smaller values for shrinking. *)
let rec shrink_value ty v =
  match ty, v with
  | TyCon "Int", Eval.VInt n ->
    List.filter_map (fun x ->
      if x = n then None else Some (Eval.VInt x)
    ) [0; n / 2; n + (if n > 0 then -1 else 1)]
  | TyCon "Bool", Eval.VBool true  -> [Eval.VBool false]
  | TyCon "Bool", Eval.VBool false -> []
  | TyCon "Float", Eval.VFloat x ->
    if x = 0.0 then [] else [Eval.VFloat 0.0; Eval.VFloat (x /. 2.0)]
  | TyCon "String", Eval.VString s ->
    if s = "" then [] else [Eval.VString (String.sub s 0 (String.length s / 2))]
  | TyApp (TyCon "List", _), Eval.VList [] -> []
  | TyApp (TyCon "List", _), Eval.VList (_ :: rest) -> [Eval.VList rest]
  | TyApp (TyCon "Array", _), Eval.VArray a ->
    if Array.length a = 0 then []
    else [Eval.VArray (Array.sub a 0 (Array.length a / 2))]
  | TyTuple ts, Eval.VTuple vs when List.length ts = List.length vs ->
    (* Vary one component at a time, keeping the others fixed. *)
    List.concat (List.mapi (fun i (t, vi) ->
      List.map (fun sv ->
        Eval.VTuple (List.mapi (fun j v0 -> if j = i then sv else v0) vs)
      ) (shrink_value t vi)
    ) (List.combine ts vs))
  | TyApp (TyCon "Option", _), Eval.VCon ("None", []) -> []
  | TyApp (TyCon "Option", _), Eval.VCon ("Some", _) -> [Eval.VCon ("None", [])]
  | _ -> []

(* Evaluate the prop body with the given param bindings; return true if it passes. *)
let check_prop eval_env _prop_params prop_body inputs =
  let base_frame = List.map (fun (k, v) -> (k, ref v)) eval_env in
  let input_frame = List.map (fun (x, v) -> (x, ref v)) inputs in
  let env = [input_frame @ base_frame] in
  (try
     match Eval.eval env prop_body with
     | Eval.VBool b -> b
     | _ -> false
   with Eval.Eval_error _ | Eval.Impl_no_match -> false)

(* Greedy shrink: try each param, try each shrunk candidate, take first improvement. *)
let rec shrink_loop eval_env prop_params prop_body candidate =
  let n = List.length candidate in
  let improved = ref false in
  let best = ref candidate in
  let i = ref 0 in
  while not !improved && !i < n do
    let (x, ty) = List.nth prop_params !i in
    let current_v = List.assoc x candidate in
    let smaller = shrink_value ty current_v in
    let tried = List.find_opt (fun sv ->
      let candidate' = List.map (fun (px, pv) ->
        if px = x then (px, sv) else (px, pv)
      ) candidate in
      not (check_prop eval_env prop_params prop_body candidate')
    ) smaller in
    (match tried with
     | Some sv ->
       best := List.map (fun (px, pv) ->
         if px = x then (px, sv) else (px, pv)
       ) candidate;
       improved := true
     | None -> ());
    incr i
  done;
  if !improved then shrink_loop eval_env prop_params prop_body !best
  else candidate

(* Run one prop declaration for up to max_tests random inputs.
   Returns Passed or Failed (with shrunk counterexample). *)
let run_prop tydefs eval_env (prop : decl) max_tests =
  match prop with
  | DProp { prop_name; prop_params; prop_body; _ } ->
    Printf.printf "Testing %S ... %!" prop_name;
    let rec find_failure run =
      if run > max_tests then Passed max_tests
      else begin
        let inputs =
          List.map (fun (x, ty) -> (x, gen_for_type tydefs [] ty)) prop_params in
        if check_prop eval_env prop_params prop_body inputs then
          find_failure (run + 1)
        else begin
          let shrunk = shrink_loop eval_env prop_params prop_body inputs in
          Failed { run; shrunk }
        end
      end
    in
    (match find_failure 1 with
     | Passed n ->
       Printf.printf "OK (%d tests)\n%!" n;
       true
     | Failed { run; shrunk } ->
       Printf.printf "FAILED after %d %s\n%!"
         run (if run = 1 then "test" else "tests");
       Printf.printf "  Counterexample:\n";
       List.iter (fun (x, v) ->
         Printf.printf "    %s = %s\n%!" x (Eval.pp_value v)
       ) shrunk;
       false)
  | _ -> true

(* Run all prop declarations in a program. Returns true if all pass. *)
let run_all eval_env program =
  let props = List.filter (function DProp _ -> true | _ -> false) program in
  if props = [] then true
  else begin
    let tydefs = build_tydefs program in
    let results = List.map (fun p -> run_prop tydefs eval_env p 100) props in
    let n_pass = List.length (List.filter Fun.id results) in
    let n_fail = List.length (List.filter (fun r -> not r) results) in
    Printf.printf "\n%d passed, %d failed\n%!" n_pass n_fail;
    n_fail = 0
  end
