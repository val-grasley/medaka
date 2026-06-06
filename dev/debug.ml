open Medaka_lib
open Ast

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try
    let p = Parser.program Lexer.token lexbuf in
    Ok p
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    Error (Printf.sprintf "Parse error at line %d col %d"
             pos.Lexing.pos_lnum
             (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

let rec pp_decl d =
  match d with
  | DTypeSig (_, n, t)    -> Printf.sprintf "DTypeSig(%s, %s)" n (pp_ty t)
  | DFunDef (_, n, ps, e) -> Printf.sprintf "DFunDef(%s, [%s], %s)" n
                               (String.concat "; " (List.map pp_pat ps))
                               (pp_expr e)
  | DLetGroup (_, bs) ->
    let pp_clause n (ps, body) =
      Printf.sprintf "%s [%s] = %s" n
        (String.concat "; " (List.map pp_pat ps)) (pp_expr body) in
    let pp_b (n, cs) = String.concat "; " (List.map (pp_clause n) cs) in
    Printf.sprintf "DLetGroup([%s])" (String.concat "; " (List.map pp_b bs))
  | DData (_, n, ps, vs, _)  ->
    let pv v =
      let fields_str = match v.con_payload with
        | Ast.ConPos tys   -> String.concat ", " (List.map pp_ty tys)
        | Ast.ConNamed fls -> "{" ^ String.concat ", " (List.map (fun f -> f.Ast.field_name ^ " : " ^ pp_ty f.Ast.field_type) fls) ^ "}"
      in
      Printf.sprintf "%s [%s]" v.con_name fields_str
    in
    Printf.sprintf "DData(%s, [%s], [%s])" n (String.concat " " ps)
      (String.concat " | " (List.map pv vs))
  | DRecord (_, n, ps, fs, _) ->
    let pf f = Printf.sprintf "%s : %s" f.field_name (pp_ty f.field_type) in
    Printf.sprintf "DRecord(%s, [%s], {%s})" n (String.concat " " ps)
      (String.concat ", " (List.map pf fs))
  | DInterface { iface_name; _ } -> Printf.sprintf "DInterface(%s)" iface_name
  | DImpl { iface_name; _ }      -> Printf.sprintf "DImpl(%s)" iface_name
  | DExtern (_, n, t) -> Printf.sprintf "DExtern(%s, %s)" n (pp_ty t)
  | DTypeAlias (_, n, ps, rhs) ->
    Printf.sprintf "DTypeAlias(%s, [%s], %s)" n (String.concat " " ps) (pp_ty rhs)
  | DUse (pub, p) ->
    let pp_use = function
      | UseName  ns -> "UseName " ^ String.concat "." ns
      | UseGroup (ns, ms) -> Printf.sprintf "UseGroup(%s, {%s})" (String.concat "." ns)
          (String.concat ", " (List.map (fun (n, all) -> if all then n ^ "(..)" else n) ms))
      | UseWild  ns -> "UseWild " ^ String.concat "." ns
      | UseAlias (ns, a) -> Printf.sprintf "UseAlias(%s as %s)" (String.concat "." ns) a
    in
    Printf.sprintf "DUse(pub=%b, %s)" pub (pp_use p)
  | DNewtype (_, n, _, con, _, _) -> Printf.sprintf "DNewtype(%s, %s)" n con
  | DProp { prop_name; _ } -> Printf.sprintf "DProp(%S, ...)" prop_name
  | DTest { test_name; _ } -> Printf.sprintf "DTest(%S, ...)" test_name
  | DBench { bench_name; _ } -> Printf.sprintf "DBench(%S, ...)" bench_name
  | DEffect (_, n) -> Printf.sprintf "DEffect(%s)" n
  | DAttrib (_, d) -> Printf.sprintf "DAttrib(..., %s)" (pp_decl d)

let show label src =
  Printf.printf "── %s ──\n" label;
  Printf.printf "src: %s\n" (String.escaped src);
  (match parse src with
   | Ok decls -> List.iter (fun d -> Printf.printf "  %s\n" (pp_decl d)) decls
   | Error e  -> Printf.printf "  ERROR: %s\n" e);
  Printf.printf "\n"

let () =
  show "wildcard"       "const x _ = x\n";
  show "cons"           "head (x::_) = x\n";
  show "app"            "v = f x y\n";
  show "list"           "v = [1, 2, 3]\n";
  show "array"          "v = [|1, 2, 3|]\n";
  show "tuple"          "v = (1, 2)\n";
  show "record_create"  "v = Person { name = \"Alice\", age = 30 }\n";
  show "array_index"    "v = arr[0]\n";
  show "use_group"      "use utils.{greet, helper}\n";
  show "use_pub"        "pub use list.{map, filter}\n";
  show "use_alias"      "use collections.HashMap as HM\n";
  show "use_wild"       "use utils.*\n";
  show "block_data"     "data Shape\n  | Circle Float\n  | Rectangle Float Float\n";
  show "record_decl"    "record Person\n  name : String\n  age : Int\n";
  show "match"          "f x =\n  match x\n    0 => \"zero\"\n    _ => \"nonzero\"\n";
  show "do"             "result =\n  do\n    x <- foo\n    pure x\n"
