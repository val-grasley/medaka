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

let pp_decl d =
  match d with
  | DTypeSig (n, t)    -> Printf.sprintf "DTypeSig(%s, %s)" n (pp_ty t)
  | DFunDef (n, ps, e) -> Printf.sprintf "DFunDef(%s, [%s], %s)" n
                            (String.concat "; " (List.map pp_pat ps))
                            (pp_expr e)
  | DData (n, ps, vs)  ->
    let pv v = Printf.sprintf "%s [%s]" v.con_name (String.concat ", " (List.map pp_ty v.con_fields)) in
    Printf.sprintf "DData(%s, [%s], [%s])" n (String.concat " " ps)
      (String.concat " | " (List.map pv vs))
  | DRecord (n, ps, fs) ->
    let pf f = Printf.sprintf "%s : %s" f.field_name (pp_ty f.field_type) in
    Printf.sprintf "DRecord(%s, [%s], {%s})" n (String.concat " " ps)
      (String.concat ", " (List.map pf fs))
  | DInterface { iface_name; _ } -> Printf.sprintf "DInterface(%s)" iface_name
  | DImpl { iface_name; _ }      -> Printf.sprintf "DImpl(%s)" iface_name
  | DExtern (n, t) -> Printf.sprintf "DExtern(%s, %s)" n (pp_ty t)
  | DUse (pub, p) ->
    let pp_use = function
      | UseName  ns -> "UseName " ^ String.concat "." ns
      | UseGroup (ns, ms) -> Printf.sprintf "UseGroup(%s, {%s})" (String.concat "." ns) (String.concat ", " ms)
      | UseWild  ns -> "UseWild " ^ String.concat "." ns
      | UseAlias (ns, a) -> Printf.sprintf "UseAlias(%s as %s)" (String.concat "." ns) a
    in
    Printf.sprintf "DUse(pub=%b, %s)" pub (pp_use p)

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
