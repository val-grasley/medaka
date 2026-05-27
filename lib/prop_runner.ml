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

(* Generate a random value for the given AST type.
   For user-defined types, looks up arbitrary_registry. *)
let rec gen_for_type ty =
  match ty with
  | TyCon "Int"    -> Eval.VInt (Random.int 2001 - 1000)
  | TyCon "Bool"   -> Eval.VBool (Random.bool ())
  | TyCon "Float"  -> Eval.VFloat (Random.float 2.0 -. 1.0)
  | TyCon "Char"   -> Eval.VChar (String.make 1 (Char.chr (32 + Random.int 95)))
  | TyCon "String" -> Eval.VString (gen_string ())
  | TyCon "Unit"   -> Eval.VUnit
  | TyApp (TyCon "List", t) ->
    let n = Random.int 8 in
    Eval.VList (List.init n (fun _ -> gen_for_type t))
  | TyApp (TyCon "Option", t) ->
    if Random.bool () then Eval.VCon ("None", [])
    else Eval.VCon ("Some", [gen_for_type t])
  | TyApp (TyCon "Result", t) ->
    if Random.bool () then Eval.VCon ("Ok",  [gen_for_type t])
    else Eval.VCon ("Err", [gen_for_type t])
  | TyCon custom ->
    (match Hashtbl.find_opt Eval.arbitrary_registry custom with
     | Some gen -> gen ()
     | None ->
       failwith (Printf.sprintf
         "prop_runner: no Arbitrary instance for type '%s'. \
          Add 'deriving (Arbitrary)' or an explicit impl." custom))
  | _ ->
    failwith (Printf.sprintf
      "prop_runner: cannot generate values for type '%s'"
      (pp_ty ty))

(* Produce candidate smaller values for shrinking. *)
let shrink_value ty v =
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
let run_prop eval_env (prop : decl) max_tests =
  match prop with
  | DProp { prop_name; prop_params; prop_body; _ } ->
    Printf.printf "Testing %S ... %!" prop_name;
    let rec find_failure run =
      if run > max_tests then Passed max_tests
      else begin
        let inputs = List.map (fun (x, ty) -> (x, gen_for_type ty)) prop_params in
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

(* Run all prop declarations in a program. Exits 1 if any fail. *)
let run_all eval_env program =
  let props = List.filter (function DProp _ -> true | _ -> false) program in
  if props = [] then begin
    Printf.printf "No prop declarations found.\n%!";
    exit 0
  end;
  let results = List.map (fun p -> run_prop eval_env p 100) props in
  let n_pass = List.length (List.filter Fun.id results) in
  let n_fail = List.length (List.filter (fun r -> not r) results) in
  Printf.printf "\n%d passed, %d failed\n%!" n_pass n_fail;
  if n_fail > 0 then exit 1 else exit 0
