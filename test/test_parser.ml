open Medaka_lib
open Ast

(* ── Parse helpers ───────────────────────────────────── *)

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  let prog =
    try Parser.program Lexer.token lexbuf
    with
    | Parser.Error ->
      let pos = lexbuf.Lexing.lex_curr_p in
      failwith (Printf.sprintf "Parse error at line %d col %d in:\n%s"
                  pos.Lexing.pos_lnum
                  (pos.Lexing.pos_cnum - pos.Lexing.pos_bol)
                  src)
  in
  Ast.strip_locs_program prog

let rec pp_decl d =
  match d with
  | DTypeSig (_, n, t)    -> Printf.sprintf "DTypeSig(%s, %s)" n (Ast.pp_ty t)
  | DFunDef (_, n, ps, e) -> Printf.sprintf "DFunDef(%s, [%s], %s)" n
                               (String.concat "; " (List.map Ast.pp_pat ps))
                               (Ast.pp_expr e)
  | DLetGroup (_, bs) ->
    let pp_clause n (ps, body) =
      Printf.sprintf "%s [%s] = %s" n
        (String.concat "; " (List.map Ast.pp_pat ps)) (Ast.pp_expr body) in
    let pp_b (n, cs) = String.concat "; " (List.map (pp_clause n) cs) in
    Printf.sprintf "DLetGroup([%s])" (String.concat "; " (List.map pp_b bs))
  | DData (_, n, _, _, _)    -> Printf.sprintf "DData(%s, ...)" n
  | DRecord (_, n, _, _, _)  -> Printf.sprintf "DRecord(%s, ...)" n
  | DInterface { iface_name; _ } -> Printf.sprintf "DInterface(%s)" iface_name
  | DImpl { iface_name; _ }      -> Printf.sprintf "DImpl(%s)" iface_name
  | DUse (pub, _)         -> Printf.sprintf "DUse(pub=%b, ...)" pub
  | DExtern (_, n, t)     -> Printf.sprintf "DExtern(%s, %s)" n (Ast.pp_ty t)
  | DTypeAlias (_, n, _, _) -> Printf.sprintf "DTypeAlias(%s, ...)" n
  | DNewtype (_, n, _, con, _, _) -> Printf.sprintf "DNewtype(%s, %s, ...)" n con
  | DProp { prop_name; _ } -> Printf.sprintf "DProp(%S, ...)" prop_name
  | DBench { bench_name; _ } -> Printf.sprintf "DBench(%S, ...)" bench_name
  | DAttrib (_, d) -> Printf.sprintf "DAttrib(..., %s)" (pp_decl d)

let parse_one src =
  match parse src with
  | [decl] -> decl
  | decls  ->
    failwith (Printf.sprintf "expected 1 decl, got %d:\n  %s"
                (List.length decls)
                (String.concat "\n  " (List.map pp_decl decls)))

let parse_expr src =
  match parse_one ("v = " ^ src ^ "\n") with
  | DFunDef (_, _, [], e) -> e
  | d -> failwith (Printf.sprintf "expected fun def, got: %s" (pp_decl d))

let _ = pp_decl  (* silence unused warning until tests use it *)

(* ── Type signature tests ────────────────────────────── *)

let test_typesig_simple () =
  match parse_one "add : Int -> Int -> Int\n" with
  | DTypeSig (false, "add", TyFun (TyCon "Int", TyFun (TyCon "Int", TyCon "Int"))) -> ()
  | _ -> failwith "wrong"

let test_typesig_typevar () =
  match parse_one "id : a -> a\n" with
  | DTypeSig (false, "id", TyFun (TyVar "a", TyVar "a")) -> ()
  | _ -> failwith "wrong"

let test_typesig_effect () =
  match parse_one "readFile : String -> <IO> String\n" with
  | DTypeSig (false, "readFile", TyFun (TyCon "String", TyEffect (["IO"], TyCon "String"))) -> ()
  | _ -> failwith "wrong"

let test_typesig_multieffect () =
  match parse_one "fetch : String -> <Async, IO> String\n" with
  | DTypeSig (false, "fetch", TyFun (TyCon "String", TyEffect (["Async"; "IO"], TyCon "String"))) -> ()
  | _ -> failwith "wrong"

let test_typesig_typeapp () =
  match parse_one "head : List a -> Option a\n" with
  | DTypeSig (false, "head", TyFun (TyApp (TyCon "List", TyVar "a"),
                                    TyApp (TyCon "Option", TyVar "a"))) -> ()
  | _ -> failwith "wrong"

(* ── Function definition tests ──────────────────────── *)

let test_fundef_simple () =
  match parse_one "answer = 42\n" with
  | DFunDef (false, "answer", [], ELit (LInt 42)) -> ()
  | _ -> failwith "wrong"

let test_fundef_with_arg () =
  match parse_one "double x = x + x\n" with
  | DFunDef (false, "double", [PVar "x"], EBinOp ("+", EVar "x", EVar "x")) -> ()
  | _ -> failwith "wrong"

let test_fundef_pattern_lit () =
  match parse_one "factorial 0 = 1\n" with
  | DFunDef (false, "factorial", [PLit (LInt 0)], ELit (LInt 1)) -> ()
  | _ -> failwith "wrong"

let test_fundef_wildcard () =
  match parse_one "const x _ = x\n" with
  | DFunDef (false, "const", [PVar "x"; PWild], EVar "x") -> ()
  | _ -> failwith "wrong"

let test_fundef_cons_pattern () =
  match parse_one "head (x::_) = x\n" with
  | DFunDef (false, "head", [PCons (PVar "x", PWild)], EVar "x") -> ()
  | _ -> failwith "wrong"

let test_fundef_constructor_pattern () =
  match parse_one "unwrap (Some x) = x\n" with
  | DFunDef (false, "unwrap", [PCon ("Some", [PVar "x"])], EVar "x") -> ()
  | _ -> failwith "wrong"

(* ── Expression tests ────────────────────────────────── *)

let test_expr_lambda () =
  match parse_expr "x => x + 1\n" with
  | ELam ([PVar "x"], EBinOp ("+", EVar "x", ELit (LInt 1))) -> ()
  | _ -> failwith "wrong"

let test_expr_lambda_multi_arg () =
  match parse_expr "(x, y) => x + y\n" with
  | ELam ([PTuple [PVar "x"; PVar "y"]], EBinOp ("+", EVar "x", EVar "y")) -> ()
  | _ -> failwith "wrong"

(* Constructor-pattern lambda parameter: `(Some x) => x` should parse as
   a lambda whose single parameter is the constructor pattern PCon.
   Regression test for the bug fix where `expr_to_pat`'s nested
   `collect` helper failed to strip ELoc wrappers, causing the parser
   to reject this form with "Invalid lambda parameter pattern". *)
let test_expr_lambda_ctor_pat () =
  match parse_expr "(Some x) => x\n" with
  | ELam ([PCon ("Some", [PVar "x"])], EVar "x") -> ()
  | other ->
    failwith (Printf.sprintf "wrong: got %s" (Ast.pp_expr other))

(* Two-arg constructor pattern lambda. *)
let test_expr_lambda_ctor_pat_two () =
  match parse_expr "(Ok x y) => x\n" with
  | ELam ([PCon ("Ok", [PVar "x"; PVar "y"])], EVar "x") -> ()
  | other ->
    failwith (Printf.sprintf "wrong: got %s" (Ast.pp_expr other))

(* Multi-param lambda: `x y => x + y` desugars to ELam with two PVar patterns. *)
let test_expr_lambda_two_params () =
  match parse_expr "x y => x + y\n" with
  | ELam ([PVar "x"; PVar "y"], EBinOp ("+", EVar "x", EVar "y")) -> ()
  | other ->
    failwith (Printf.sprintf "wrong: got %s" (Ast.pp_expr other))

(* Three-param lambda. *)
let test_expr_lambda_three_params () =
  match parse_expr "f a b c => f a b c\n" with
  | ELam ([PVar "f"; PVar "a"; PVar "b"; PVar "c"], _) -> ()
  | other ->
    failwith (Printf.sprintf "wrong: got %s" (Ast.pp_expr other))

(* Regression: constructor pattern still works as a single pattern. *)
let test_expr_lambda_ctor_single_pat_regression () =
  match parse_expr "Some x => x\n" with
  | ELam ([PCon ("Some", [PVar "x"])], EVar "x") -> ()
  | other ->
    failwith (Printf.sprintf "wrong: got %s" (Ast.pp_expr other))

let test_expr_let () =
  match parse_expr "let x = 5 in x + 1\n" with
  | ELet (false, false, PVar "x", ELit (LInt 5), EBinOp ("+", EVar "x", ELit (LInt 1))) -> ()
  | _ -> failwith "wrong"

let test_expr_let_mut () =
  match parse_expr "let mut x = 5 in x\n" with
  | ELet (true, false, PVar "x", ELit (LInt 5), EVar "x") -> ()
  | _ -> failwith "wrong"

let test_expr_let_fn_one_arg () =
  (* let f x = x + 1 in f 5  ⇒  ELet(false, true, PVar "f", ELam..., ...) *)
  match parse_expr "let f x = x + 1 in f 5\n" with
  | ELet (false, true, PVar "f",
          ELam ([PVar "x"], EBinOp ("+", EVar "x", ELit (LInt 1))),
          EApp (EVar "f", ELit (LInt 5))) -> ()
  | _ -> failwith "wrong"

let test_expr_let_fn_multi_arg () =
  (* let g x y = x + y in g 1 2  ⇒  ELet(false, true, PVar "g", ELam..., ...) *)
  match parse_expr "let g x y = x + y in g 1 2\n" with
  | ELet (false, true, PVar "g",
          ELam ([PVar "x"],
                ELam ([PVar "y"], EBinOp ("+", EVar "x", EVar "y"))),
          EApp (EApp (EVar "g", ELit (LInt 1)), ELit (LInt 2))) -> ()
  | _ -> failwith "wrong"

let test_expr_let_rec_inline () =
  match parse_expr "let rec f = x => f x in f 0\n" with
  | ELetGroup ([("f", [([], ELam ([PVar "x"], EApp (EVar "f", EVar "x")))])],
               EApp (EVar "f", ELit (LInt 0))) -> ()
  | _ -> failwith "wrong"

let test_expr_let_rec_inline_mutual () =
  match parse_expr "let rec f = x => g x with g = x => f x in f 0\n" with
  | ELetGroup ([("f", [([], ELam _)]); ("g", [([], ELam _)])],
               EApp (EVar "f", ELit (LInt 0))) -> ()
  | _ -> failwith "wrong"

let test_decl_let_rec_top () =
  match parse "let rec fact = n => fact n\n" with
  | [DLetGroup (false, [("fact", [([], ELam ([PVar "n"], EApp (EVar "fact", EVar "n")))])])] -> ()
  | _ -> failwith "wrong"

let test_decl_let_rec_top_mutual () =
  match parse "let rec is_even = n => is_odd n\nwith is_odd = n => is_even n\n" with
  | [DLetGroup (false, [("is_even", _); ("is_odd", _)])] -> ()
  | _ -> failwith "wrong"

let test_expr_if () =
  match parse_expr "if x > 0 then x else 0\n" with
  | EIf (EBinOp (">", EVar "x", ELit (LInt 0)), EVar "x", ELit (LInt 0)) -> ()
  | _ -> failwith "wrong"

let test_expr_application () =
  match parse_expr "f x y\n" with
  | EApp (EApp (EVar "f", EVar "x"), EVar "y") -> ()
  | _ -> failwith "wrong"

let test_expr_infix_backtick () =
  match parse_expr "x `div` y\n" with
  | EInfix ("div", EVar "x", EVar "y") -> ()
  | _ -> failwith "wrong"

let test_expr_list_literal () =
  match parse_expr "[1, 2, 3]\n" with
  | EListLit [ELit (LInt 1); ELit (LInt 2); ELit (LInt 3)] -> ()
  | _ -> failwith "wrong"

let test_expr_array_literal () =
  match parse_expr "[|1, 2, 3|]\n" with
  | EArrayLit [ELit (LInt 1); ELit (LInt 2); ELit (LInt 3)] -> ()
  | _ -> failwith "wrong"

let test_expr_tuple () =
  match parse_expr "(1, \"hello\")\n" with
  | ETuple [ELit (LInt 1); ELit (LString "hello")] -> ()
  | _ -> failwith "wrong"

let test_expr_field_access () =
  match parse_expr "person.name\n" with
  | EFieldAccess (EVar "person", "name") -> ()
  | _ -> failwith "wrong"

let test_expr_question_simple () =
  (* `foo ?` ⇒ EQuestion(EVar "foo") *)
  match parse_expr "foo ?\n" with
  | EQuestion (EVar "foo") -> ()
  | _ -> failwith "wrong"

let test_expr_question_app () =
  (* `Ok 5 ?` binds looser than application: parses as `(Ok 5) ?` *)
  match parse_expr "Ok 5 ?\n" with
  | EQuestion (EApp (EVar "Ok", ELit (LInt 5))) -> ()
  | _ -> failwith "wrong"

let test_expr_record_create () =
  match parse_expr "Person { name = \"Alice\", age = 30 }\n" with
  | ERecordCreate ("Person", [("name", ELit (LString "Alice")); ("age", ELit (LInt 30))]) -> ()
  | _ -> failwith "wrong"

let test_expr_record_update () =
  match parse_expr "{ p | age = 31 }\n" with
  | ERecordUpdate (EVar "p", [("age", ELit (LInt 31))]) -> ()
  | _ -> failwith "wrong"

let test_expr_record_create_pun () =
  (* All-pun: parser emits ESetLit; Desugar.desugar_program rewrites to ERecordCreate *)
  match parse_expr "Person { name, age }\n" with
  | ESetLit ("Person", [EVar "name"; EVar "age"]) -> ()
  | _ -> failwith "wrong"

let test_expr_record_create_mixed_pun () =
  (* Mixed: at least one explicit field → parser emits ERecordCreate directly *)
  match parse_expr "Person { name = \"Alice\", age }\n" with
  | ERecordCreate ("Person", [("name", ELit (LString "Alice")); ("age", EVar "age")]) -> ()
  | _ -> failwith "wrong"

let test_expr_record_update_pun () =
  match parse_expr "{ p | age }\n" with
  | ERecordUpdate (EVar "p", [("age", EVar "age")]) -> ()
  | _ -> failwith "wrong"

let test_expr_record_update_nested () =
  (* { p | address.city = "Boston" }
     desugars to { p | address = { p.address | city = "Boston" } } *)
  match parse_expr ({|{ p | address.city = "Boston" }|} ^ "\n") with
  | ERecordUpdate (EVar "p",
      [("address", ERecordUpdate (EFieldAccess (EVar "p", "address"),
          [("city", ELit (LString "Boston"))]))]) -> ()
  | _ -> failwith "wrong"

let test_expr_record_update_nested_deep () =
  (* { p | a.b.c = 0 }
     desugars to { p | a = { p.a | b = { p.a.b | c = 0 } } } *)
  match parse_expr "{ p | a.b.c = 0 }\n" with
  | ERecordUpdate (EVar "p",
      [("a",
        ERecordUpdate (EFieldAccess (EVar "p", "a"),
          [("b",
            ERecordUpdate (EFieldAccess (EFieldAccess (EVar "p", "a"), "b"),
              [("c", ELit (LInt 0))]))]))]) -> ()
  | _ -> failwith "wrong"

let test_expr_record_update_mixed () =
  (* { p | age = 31, address.city = "Boston" } — flat and dotted in one update *)
  match parse_expr ({|{ p | age = 31, address.city = "Boston" }|} ^ "\n") with
  | ERecordUpdate (EVar "p",
      [ ("age", ELit (LInt 31))
      ; ("address", ERecordUpdate (EFieldAccess (EVar "p", "address"),
            [("city", ELit (LString "Boston"))])) ]) -> ()
  | _ -> failwith "wrong"

let test_expr_type_annot () =
  match parse_expr "x : Int\n" with
  | EAnnot (EVar "x", TyCon "Int") -> ()
  | _ -> failwith "wrong"

let test_expr_index () =
  match parse_expr "arr.[0]\n" with
  | EIndex (EVar "arr", ELit (LInt 0)) -> ()
  | _ -> failwith "wrong"

let test_expr_section () =
  (* (+5) parses to a right section; desugar.ml lowers it to \x -> x + 5 *)
  match parse_expr "(+5)\n" with
  | ESection (SecRight ("+", ELit (LInt 5))) -> ()
  | _ -> failwith "wrong"

let test_expr_left_section () =
  (* (2 * _) parses to a left section; lowered to \x -> 2 * x *)
  match parse_expr "(2 * _)\n" with
  | ESection (SecLeft (ELit (LInt 2), "*")) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_expr_left_section_minus () =
  (* (3 - _) parses to a left section; lowered to \x -> 3 - x *)
  match parse_expr "(3 - _)\n" with
  | ESection (SecLeft (ELit (LInt 3), "-")) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_expr_left_section_app () =
  (* (foo 1 * _) — application on the left *)
  match parse_expr "(foo 1 * _)\n" with
  | ESection (SecLeft (EApp (EVar "foo", ELit (LInt 1)), "*")) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_expr_bare_section_plus () =
  (* (+) parses to a bare section; lowered to \a b -> a + b *)
  match parse_expr "(+)\n" with
  | ESection (SecBare "+") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_expr_bare_section_minus () =
  match parse_expr "(-)\n" with
  | ESection (SecBare "-") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_expr_bare_section_eq () =
  match parse_expr "(==)\n" with
  | ESection (SecBare "==") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_expr_bare_section_cons () =
  match parse_expr "(::)\n" with
  | ESection (SecBare "::") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_expr_bare_section_append () =
  match parse_expr "(<>)\n" with
  | ESection (SecBare "<>") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_expr_unary_minus_paren () =
  (* (-e) still parses as unary negation, not a section *)
  match parse_expr "(-5)\n" with
  | EUnOp ("-", ELit (LInt 5)) -> ()
  | ELit (LInt (-5)) -> ()  (* lexer may fold negative literals *)
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_expr_list_arg () =
  (* f [1, 2] should parse as application, not indexing *)
  match parse_expr "f [1, 2]\n" with
  | EApp (EVar "f", EListLit [ELit (LInt 1); ELit (LInt 2)]) -> ()
  | _ -> failwith "wrong"

let test_expr_modulo () =
  match parse_expr "5 % 2\n" with
  | EBinOp ("%", ELit (LInt 5), ELit (LInt 2)) -> ()
  | _ -> failwith "wrong"

(* ── Collection literal tests ────────────────────────── *)

let test_map_literal () =
  match parse_expr "Map { \"a\" => 1, \"b\" => 2 }\n" with
  | EMapLit ("Map", [(ELit (LString "a"), ELit (LInt 1));
                     (ELit (LString "b"), ELit (LInt 2))]) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_map_literal_hashmap () =
  match parse_expr "HashMap { \"x\" => True }\n" with
  | EMapLit ("HashMap", [(ELit (LString "x"), EVar "True")]) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_set_literal () =
  match parse_expr "Set { 1, 2, 3 }\n" with
  | ESetLit ("Set", [ELit (LInt 1); ELit (LInt 2); ELit (LInt 3)]) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_map_singleton () =
  match parse_expr "Map { 42 => \"answer\" }\n" with
  | EMapLit ("Map", [(ELit (LInt 42), ELit (LString "answer"))]) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_record_still_works () =
  (* Existing record creation must still parse correctly *)
  match parse_expr "Person { name = \"Alice\", age = 30 }\n" with
  | ERecordCreate ("Person", [("name", ELit (LString "Alice")); ("age", ELit (LInt 30))]) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

(* ── Char / string upgrade tests ─────────────────────── *)

let test_char_multibyte () =
  (* UTF-8 char literal: wave emoji is 4 bytes *)
  match parse_expr "'👋'\n" with
  | ELit (LChar c) when String.length c > 1 -> ()  (* multi-byte UTF-8 *)
  | ELit (LChar c) -> failwith (Printf.sprintf "char too short (%d bytes)" (String.length c))
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_char_ascii () =
  match parse_expr "'a'\n" with
  | ELit (LChar "a") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_string_escape_r () =
  match parse_expr "\"hello\\rworld\"\n" with
  | ELit (LString s) when String.contains s '\r' -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_string_escape_zero () =
  match parse_expr "\"nul\\0end\"\n" with
  | ELit (LString s) when String.contains s '\000' -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_string_escape_unicode () =
  match parse_expr "\"\\u{48}i\"\n" with
  | ELit (LString "Hi") -> ()
  | ELit (LString s) -> failwith (Printf.sprintf "wrong string: %S" s)
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_string_multiline () =
  (* Multiline string: leading newline triggers indent stripping *)
  let src = "v = \"\n  hello\n  world\n  \"\n" in
  match parse src with
  | [DFunDef (_, _, [], ELit (LString s))] ->
    if s = "hello\nworld\n" then ()
    else failwith (Printf.sprintf "wrong multiline content: %S" s)
  | _ -> failwith "wrong parse"

let test_string_no_multiline () =
  (* A string not starting with newline is unaffected *)
  match parse_expr "\"hello world\"\n" with
  | ELit (LString "hello world") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_triple_basic () =
  match parse_expr {|"""hello"""
|} with
  | ELit (LString "hello") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_triple_multiline () =
  let src = "v = \"\"\"\n  hello\n  world\n  \"\"\"\n" in
  match parse src with
  | [DFunDef (_, _, [], ELit (LString s))] ->
    if s = "hello\nworld\n" then ()
    else failwith (Printf.sprintf "wrong triple multiline content: %S" s)
  | _ -> failwith "wrong parse"

let test_triple_embedded_quotes () =
  match parse_expr {|"""say "hi" to me"""
|} with
  | ELit (LString {|say "hi" to me|}) -> ()
  | ELit (LString s) -> failwith (Printf.sprintf "wrong string: %S" s)
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_triple_escape () =
  match parse_expr {|"""hello\tworld"""
|} with
  | ELit (LString "hello\tworld") -> ()
  | ELit (LString s) -> failwith (Printf.sprintf "wrong string: %S" s)
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_triple_unterminated () =
  try
    ignore (parse_expr {|"""hello
|});
    failwith "expected exception"
  with Failure _ -> ()

(* ── String interpolation tests ─────────────────────── *)

let test_interp_single () =
  match parse_expr "\"hello \\{name}!\"\n" with
  | EStringInterp [InterpStr "hello "; InterpExpr (EVar "name"); InterpStr "!"] -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_interp_two_segments () =
  match parse_expr "\"\\{a} and \\{b}\"\n" with
  | EStringInterp [InterpStr ""; InterpExpr (EVar "a");
                   InterpStr " and "; InterpExpr (EVar "b"); InterpStr ""] -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))

let test_interp_expression () =
  match parse_expr "\"result: \\{1 + 2}\"\n" with
  | EStringInterp [InterpStr "result: ";
                   InterpExpr (EBinOp ("+", ELit (LInt 1), ELit (LInt 2)));
                   InterpStr ""] -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (Ast.pp_expr e))
(* ── Match expression tests ──────────────────────────── *)

let test_match_basic () =
  let src = {|
f x =
  match x
    0 => "zero"
    _ => "nonzero"
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "x"],
      EMatch (EVar "x", [
        (PLit (LInt 0), [], ELit (LString "zero"));
        (PWild, [], ELit (LString "nonzero"));
      ])) -> ()
  | _ -> failwith "wrong"

let test_match_with_guard () =
  let src = {|
sign x =
  match x
    n if n > 0 => 1
    n if n < 0 => -1
    _ => 0
|} in
  match parse_one src with
  | DFunDef (false, "sign", [PVar "x"],
      EMatch (EVar "x", [
        (PVar "n", [GBool (EBinOp (">", EVar "n", ELit (LInt 0)))], ELit (LInt 1));
        (PVar "n", [GBool (EBinOp ("<", EVar "n", ELit (LInt 0)))], EUnOp ("-", ELit (LInt 1)));
        (PWild, [], ELit (LInt 0));
      ])) -> ()
  | _ -> failwith "wrong"

(* ── As-pattern tests ───────────────────────────────────── *)

let test_as_pattern_cons () =
  let src = {|
f xs =
  match xs
    ys@(x::_) => x
    _ => 0
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "xs"],
      EMatch (EVar "xs", [
        (PAs ("ys", PCons (PVar "x", PWild)), [], EVar "x");
        (PWild, [], ELit (LInt 0));
      ])) -> ()
  | _ -> failwith "wrong"

let test_as_pattern_var () =
  let src = {|
f xs =
  match xs
    ys@x => x
    _ => 0
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "xs"],
      EMatch (EVar "xs", [
        (PAs ("ys", PVar "x"), [], EVar "x");
        (PWild, [], ELit (LInt 0));
      ])) -> ()
  | _ -> failwith "wrong"

(* ── Top-level function guard tests ─────────────────── *)

(* Guards are kept as an EGuards node by the parser; desugar.ml lowers them
   to the nested if/match chain. *)
let test_guard_single () =
  let src = {|
f x
  | x > 0 = 1
  | otherwise = 0
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "x"],
      EGuards [ ([GBool (EBinOp (">", EVar "x", ELit (LInt 0)))], ELit (LInt 1))
              ; ([GBool (EVar "otherwise")], ELit (LInt 0)) ]) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_guard_multi () =
  let src = {|
classify n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | otherwise = "zero"
|} in
  match parse_one src with
  | DFunDef (false, "classify", [PVar "n"],
      EGuards [ ([GBool (EBinOp ("<", EVar "n", ELit (LInt 0)))], ELit (LString "neg"))
              ; ([GBool (EBinOp (">", EVar "n", ELit (LInt 0)))], ELit (LString "pos"))
              ; ([GBool (EVar "otherwise")], ELit (LString "zero")) ]) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_guard_no_params () =
  let src = {|
r
  | True = 42
  | otherwise = 0
|} in
  match parse_one src with
  | DFunDef (false, "r", [],
      EGuards [ ([GBool (EVar "True")], ELit (LInt 42))
              ; ([GBool (EVar "otherwise")], ELit (LInt 0)) ]) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

(* A pattern-bind qualifier (`Some y <- o`) is preserved as a GBind in the arm. *)
let test_guard_pattern_bind () =
  let src = {|
f o
  | Some y <- o = y
  | otherwise = 0
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "o"],
      EGuards [ ([GBind (PCon ("Some", [PVar "y"]), EVar "o")], EVar "y")
              ; ([GBool (EVar "otherwise")], ELit (LInt 0)) ]) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

(* Comma-separated qualifiers: a pattern bind followed by a boolean test. *)
let test_guard_bind_then_bool () =
  let src = {|
f o
  | Some y <- o, y > 0 = y
  | otherwise = 0
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "o"],
      EGuards [ ([ GBind (PCon ("Some", [PVar "y"]), EVar "o")
                 ; GBool (EBinOp (">", EVar "y", ELit (LInt 0))) ], EVar "y")
              ; ([GBool (EVar "otherwise")], ELit (LInt 0)) ]) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

(* Pattern-bind qualifier inside a match-arm guard. *)
let test_match_arm_pattern_bind () =
  let src = {|
describe o =
  match o
    n if Some y <- n, y > 0 => 1
    _ => 0
|} in
  match parse_one src with
  | DFunDef (false, "describe", [PVar "o"],
      EMatch (EVar "o",
        [ (PVar "n",
           [ GBind (PCon ("Some", [PVar "y"]), EVar "n")
           ; GBool (EBinOp (">", EVar "y", ELit (LInt 0))) ],
           ELit (LInt 1))
        ; (PWild, [], ELit (LInt 0)) ])) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

(* ── Data type tests ─────────────────────────────────── *)

let test_data_inline () =
  match parse_one "data Bool = True | False\n" with
  | DData (DataPrivate, "Bool", [], [
      { con_name = "True";  con_payload = ConPos [] };
      { con_name = "False"; con_payload = ConPos [] };
    ], []) -> ()
  | _ -> failwith "wrong"

let test_data_with_fields () =
  match parse_one "data Option a = Some a | None\n" with
  | DData (DataPrivate, "Option", ["a"], [
      { con_name = "Some"; con_payload = ConPos [TyVar "a"] };
      { con_name = "None"; con_payload = ConPos [] };
    ], []) -> ()
  | _ -> failwith "wrong"

let test_data_block () =
  let src = {|
data Shape
  = Circle Float
  | Rectangle Float Float
|} in
  match parse_one src with
  | DData (DataPrivate, "Shape", [], [
      { con_name = "Circle";    con_payload = ConPos [TyCon "Float"] };
      { con_name = "Rectangle"; con_payload = ConPos [TyCon "Float"; TyCon "Float"] };
    ], []) -> ()
  | _ -> failwith "wrong"

(* ── Record type tests ───────────────────────────────── *)

let test_record_decl () =
  let src = {|
record Person
  name : String
  age : Int
|} in
  match parse_one src with
  | DRecord (DataPrivate, "Person", [], [
      { field_name = "name"; field_type = TyCon "String" };
      { field_name = "age";  field_type = TyCon "Int" };
    ], []) -> ()
  | _ -> failwith "wrong"

(* ── Do notation tests ───────────────────────────────── *)

let test_do_basic () =
  let src = {|
result =
  do
    x <- foo
    y <- bar x
    pure (x + y)
|} in
  match parse_one src with
  | DFunDef (false, "result", [], EDo (_, [
      DoBind (PVar "x", EVar "foo");
      DoBind (PVar "y", EApp (EVar "bar", EVar "x"));
      DoExpr (EApp (EVar "pure", EBinOp ("+", EVar "x", EVar "y")));
    ])) -> ()
  | _ -> failwith "wrong"

let test_do_field_assign () =
  let src = {|
go p =
  do
    p.age = 31
    p.name = "Bob"
    pure p
|} in
  match parse_one src with
  | DFunDef (false, "go", [PVar "p"], EDo (_, [
      DoFieldAssign ("p", "age", ELit (LInt 31));
      DoFieldAssign ("p", "name", ELit (LString "Bob"));
      DoExpr (EApp (EVar "pure", EVar "p"));
    ])) -> ()
  | _ -> failwith "wrong shape for field assign do-block"

let test_do_ref_value_assign () =
  let src = {|
go r =
  do
    r.value = 42
    pure r.value
|} in
  match parse_one src with
  | DFunDef (false, "go", [PVar "r"], EDo (_, [
      DoFieldAssign ("r", "value", ELit (LInt 42));
      DoExpr (EApp (EVar "pure", EFieldAccess (EVar "r", "value")));
    ])) -> ()
  | _ -> failwith "wrong"

(* ── Import/export declaration tests ─────────────────── *)

let test_use_simple () =
  match parse_one "import utils.greet\n" with
  | DUse (false, UseName ["utils"; "greet"]) -> ()
  | _ -> failwith "wrong"

let test_use_group () =
  match parse_one "import utils.{greet, helper}\n" with
  | DUse (false, UseGroup (["utils"], ["greet"; "helper"])) -> ()
  | _ -> failwith "wrong"

let test_use_pub () =
  match parse_one "export import list.{map, filter}\n" with
  | DUse (true, UseGroup (["list"], ["map"; "filter"])) -> ()
  | _ -> failwith "wrong"

let test_use_alias () =
  match parse_one "import collections.HashMap as HM\n" with
  | DUse (false, UseAlias (["collections"; "HashMap"], "HM")) -> ()
  | _ -> failwith "wrong"

let test_use_wildcard () =
  match parse_one "import utils.*\n" with
  | DUse (false, UseWild ["utils"]) -> ()
  | _ -> failwith "wrong"

let test_export_standalone_type_sig () =
  match parse_one "export\ntoList : Int -> Int\n" with
  | DTypeSig (true, "toList", _) -> ()
  | _ -> failwith "wrong"

let test_export_standalone_fun_def () =
  match parse_one "export\nfoo x = x\n" with
  | DFunDef (true, "foo", _, _) -> ()
  | _ -> failwith "wrong"

let test_export_data_abstract () =
  (* export data → DataAbstract: type name only *)
  match parse_one "export data Color = Red | Green | Blue\n" with
  | DData (DataAbstract, "Color", [], _, []) -> ()
  | _ -> failwith "wrong"

let test_public_export_data () =
  (* public export data → DataPublic: type + constructors *)
  match parse_one "public export data Color = Red | Green | Blue\n" with
  | DData (DataPublic, "Color", [], _, []) -> ()
  | _ -> failwith "wrong"

let test_private_data () =
  (* bare data → DataPrivate *)
  match parse_one "data Color = Red | Green | Blue\n" with
  | DData (DataPrivate, "Color", [], _, []) -> ()
  | _ -> failwith "wrong"

let test_public_export_record () =
  let src = "public export record Point\n  x : Int\n  y : Int\n" in
  match parse_one src with
  | DRecord (DataPublic, "Point", [], _, []) -> ()
  | _ -> failwith "wrong"

let test_export_record_abstract () =
  let src = "export record Point\n  x : Int\n  y : Int\n" in
  match parse_one src with
  | DRecord (DataAbstract, "Point", [], _, []) -> ()
  | _ -> failwith "wrong"

(* ── Multi-declaration tests ─────────────────────────── *)

(* ── Pipe and compose ────────────────────────────────── *)

let test_pipe () =
  match parse_expr "x |> f" with
  | EBinOp ("|>", EVar "x", EVar "f") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_pipe_chain () =
  (* left-associative: x |> f |> g  =  (x |> f) |> g *)
  match parse_expr "x |> f |> g" with
  | EBinOp ("|>", EBinOp ("|>", EVar "x", EVar "f"), EVar "g") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_compose_right () =
  match parse_expr "f >> g" with
  | EBinOp (">>", EVar "f", EVar "g") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_compose_left () =
  match parse_expr "f << g" with
  | EBinOp ("<<", EVar "f", EVar "g") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_pipe_lower_than_or () =
  (* x |> f  should not capture the `||` inside f — `||` binds tighter *)
  match parse_expr "a || b |> f" with
  | EBinOp ("|>", EBinOp ("||", EVar "a", EVar "b"), EVar "f") -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

let test_compose_lower_than_or () =
  match parse_expr "f >> a || b" with
  | EBinOp (">>", EVar "f", EBinOp ("||", EVar "a", EVar "b")) -> ()
  | e -> failwith (Printf.sprintf "wrong: %s" (pp_expr e))

(* ── Leading-operator line continuation ──────────────── *)

(* A line break immediately before |> >> << && || ++ <> continues the previous
   expression rather than ending the statement.  Because continuation only
   *removes* layout tokens that a one-line form never had, every continued form
   must parse to exactly the same AST as its one-line equivalent. *)
let same_ast one_line continued () =
  let a = parse one_line and b = parse continued in
  if a <> b then
    failwith (Printf.sprintf
                "continuation changed the AST.\none-line:\n%s\ncontinued:\n%s"
                one_line continued)

let test_cont_pipe =
  same_ast
    "f x = x |> g |> h\n"
    "f x =\n  x\n  |> g\n  |> h\n"

let test_cont_logical =
  same_ast
    "f a b c = a && b || c\n"
    "f a b c =\n  a\n  && b\n  || c\n"

let test_cont_all_ops =
  same_ast
    "f a b = a |> b >> b << b && b || b ++ b <> b\n"
    "f a b =\n  a\n  |> b\n  >> b\n  << b\n  && b\n  || b\n  ++ b\n  <> b\n"

let test_cont_dedented =
  (* the continuation line may sit at any indent — even left of the enclosing
     block — without triggering a premature dedent *)
  same_ast
    "f x = x && True\n"
    "f x =\n  x\n&& True\n"

let test_cont_blank_line =
  (* blank lines before the operator are swallowed too *)
  same_ast
    "f x = x |> g\n"
    "f x =\n  x\n\n  |> g\n"

let test_cont_comment_not_rescued () =
  (* a comment physically between the operand and the operator stops the
     newline run, so continuation does not apply; this was a parse error before
     the rule existed and remains one (documented limitation) *)
  match
    (try ignore (parse "f x =\n  x\n  -- note\n  && True\n"); `Parsed
     with Failure _ -> `Error)
  with
  | `Error  -> ()
  | `Parsed -> failwith "expected comment-between-operand-and-operator to error"

let test_multi_decl () =
  let src = "x : Int\nx = 42\n" in
  match parse src with
  | [DTypeSig (false, "x", TyCon "Int"); DFunDef (false, "x", [], ELit (LInt 42))] -> ()
  | _ -> failwith "wrong"

let test_multi_clause () =
  let src = "factorial 0 = 1\nfactorial n = n * factorial n\n" in
  match parse src with
  | [DFunDef (false, "factorial", [PLit (LInt 0)], ELit (LInt 1));
     DFunDef (false, "factorial", [PVar "n"], _)] -> ()
  | _ -> failwith "wrong"

(* ── Extern declaration tests ───────────────────────── *)

let test_extern_simple () =
  match parse_one "extern foo : Int -> String\n" with
  | DExtern (false, "foo", TyFun (TyCon "Int", TyCon "String")) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_extern_typevar () =
  match parse_one "extern id : a -> a\n" with
  | DExtern (false, "id", TyFun (TyVar "a", TyVar "a")) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_extern_effect () =
  match parse_one "extern print : a -> <IO> Unit\n" with
  | DExtern (false, "print", TyFun (TyVar "a", TyEffect (["IO"], TyCon "Unit"))) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_extern_constant () =
  match parse_one "extern pi : Float\n" with
  | DExtern (false, "pi", TyCon "Float") -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

let test_extern_multiarg () =
  match parse_one "extern set_ref : Ref a -> a -> <Mut> Unit\n" with
  | DExtern (false, "set_ref", TyFun (TyApp (TyCon "Ref", TyVar "a"),
                                 TyFun (TyVar "a", TyEffect (["Mut"], TyCon "Unit")))) -> ()
  | d -> failwith (Printf.sprintf "wrong: %s" (pp_decl d))

(* ── Constraint type signature tests ────────────────── *)

let test_constraint_single () =
  match parse_one "neq : Eq a => a -> a -> Bool\n" with
  | DTypeSig (false, "neq",
      TyConstrained (
        [("Eq", [TyVar "a"])],
        TyFun (TyVar "a", TyFun (TyVar "a", TyCon "Bool")))) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_constraint_multi () =
  match parse_one "f : (Eq a, Ord b) => a -> b -> Bool\n" with
  | DTypeSig (false, "f",
      TyConstrained (
        [("Eq", [TyVar "a"]); ("Ord", [TyVar "b"])],
        TyFun (TyVar "a", TyFun (TyVar "b", TyCon "Bool")))) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_constraint_no_args () =
  match parse_one "f : Show a => a -> String\n" with
  | DTypeSig (false, "f",
      TyConstrained (
        [("Show", [TyVar "a"])],
        TyFun (TyVar "a", TyCon "String"))) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_constraint_type_app_arg () =
  match parse_one "f : Eq (List a) => List a -> Bool\n" with
  | DTypeSig (false, "f",
      TyConstrained (
        [("Eq", [TyApp (TyCon "List", TyVar "a")])],
        TyFun (TyApp (TyCon "List", TyVar "a"), TyCon "Bool"))) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* ── Type alias tests ───────────────────────────────── *)

let test_type_alias_simple () =
  match parse_one "type Name = String\n" with
  | DTypeAlias (false, "Name", [], TyCon "String") -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_type_alias_param () =
  match parse_one "type Wrapper a = Option a\n" with
  | DTypeAlias (false, "Wrapper", ["a"], TyApp (TyCon "Option", TyVar "a")) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_type_alias_fun () =
  match parse_one "type Parser a = String -> Option a\n" with
  | DTypeAlias (false, "Parser", ["a"],
      TyFun (TyCon "String", TyApp (TyCon "Option", TyVar "a"))) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_type_alias_export () =
  match parse_one "export type Name = String\n" with
  | DTypeAlias (true, "Name", [], TyCon "String") -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_newtype_simple () =
  match parse_one "newtype UserId = UserId Int\n" with
  | DNewtype (false, "UserId", [], "UserId", TyCon "Int", []) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_newtype_param () =
  match parse_one "newtype Wrapper a = Wrap a\n" with
  | DNewtype (false, "Wrapper", ["a"], "Wrap", TyVar "a", []) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_newtype_export () =
  match parse_one "export newtype UserId = UserId Int\n" with
  | DNewtype (true, "UserId", [], "UserId", TyCon "Int", []) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_newtype_deriving () =
  match parse_one "newtype Age = Age Int deriving (Eq)\n" with
  | DNewtype (false, "Age", [], "Age", TyCon "Int", ["Eq"]) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* ── Named impl declarations ────────────────────────── *)

let test_named_impl_upper () =
  match parse_one "impl Additive of Monoid Int where\n  mempty = 0\n" with
  | DImpl { impl_name = Some "Additive"; iface_name = "Monoid"; is_default = false; _ } -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_named_impl_default () =
  match parse_one "default impl Additive of Monoid Int where\n  mempty = 0\n" with
  | DImpl { impl_name = Some "Additive"; iface_name = "Monoid"; is_default = true; _ } -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* ── Numeric literal extensions ──────────────────────── *)

let test_hex_literal () =
  match parse_expr "0xFF" with
  | ELit (LInt 255) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_hex_literal_upper () =
  match parse_expr "0xDEAD" with
  | ELit (LInt 57005) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_hex_with_underscores () =
  match parse_expr "0xFF_00" with
  | ELit (LInt 65280) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_bin_literal () =
  match parse_expr "0b1010" with
  | ELit (LInt 10) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_oct_literal () =
  match parse_expr "0o17" with
  | ELit (LInt 15) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_int_with_underscores () =
  match parse_expr "1_000_000" with
  | ELit (LInt 1000000) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_float_with_underscores () =
  match parse_expr "3.141_592" with
  | ELit (LFloat f) when Float.equal f 3.141592 -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

(* ── Record pattern tests ────────────────────────────── *)

let test_record_pat_pun () =
  let src = {|
f p =
  match p
    Person { name } => name
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "p"],
      EMatch (EVar "p", [
        (PRec ("Person", [("name", None)], false), [], EVar "name");
      ])) -> ()
  | _ -> failwith "wrong"

let test_record_pat_explicit () =
  let src = {|
f p =
  match p
    Person { name = "Alice", age } => age
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "p"],
      EMatch (EVar "p", [
        (PRec ("Person", [("name", Some (PLit (LString "Alice"))); ("age", None)], false),
         [], EVar "age");
      ])) -> ()
  | _ -> failwith "wrong"

let test_record_pat_rest_only () =
  let src = {|
f p =
  match p
    Person { ... } => 0
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "p"],
      EMatch (EVar "p", [
        (PRec ("Person", [], true), [], ELit (LInt 0));
      ])) -> ()
  | _ -> failwith "wrong"

let test_record_pat_with_rest () =
  let src = {|
f p =
  match p
    Person { name, ... } => name
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "p"],
      EMatch (EVar "p", [
        (PRec ("Person", [("name", None)], true), [], EVar "name");
      ])) -> ()
  | _ -> failwith "wrong"

(* ── Phase 39: Named-field variant tests ─────────────── *)

let test_data_named_inline () =
  match parse_one "data Point = Pt { x : Int, y : Int }\n" with
  | DData (DataPrivate, "Point", [], [
      { con_name = "Pt"; con_payload = ConNamed [
        { field_name = "x"; field_type = TyCon "Int" };
        { field_name = "y"; field_type = TyCon "Int" };
      ] }
    ], []) -> ()
  | _ -> failwith "wrong"

let test_data_named_block () =
  let src = {|
data Event
  = Click { x : Int, y : Int }
  | Scroll Int
|} in
  match parse_one src with
  | DData (DataPrivate, "Event", [], [
      { con_name = "Click"; con_payload = ConNamed [
        { field_name = "x"; field_type = TyCon "Int" };
        { field_name = "y"; field_type = TyCon "Int" };
      ] };
      { con_name = "Scroll"; con_payload = ConPos [TyCon "Int"] };
    ], []) -> ()
  | _ -> failwith "wrong"

let test_named_ctor_pat () =
  let src = {|
f e =
  match e
    Click { x, y } => x
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "e"],
      EMatch (EVar "e", [
        (PRec ("Click", [("x", None); ("y", None)], false), [], EVar "x");
      ])) -> ()
  | _ -> failwith "wrong"

let test_named_ctor_create () =
  let src = "v = Click { x = 1, y = 2 }\n" in
  match parse_one src with
  | DFunDef (false, "v", [],
      ERecordCreate ("Click", [("x", ELit (LInt 1)); ("y", ELit (LInt 2))])) -> ()
  | _ -> failwith "wrong"

(* ── Interface default where ─────────────────────────── *)

let test_iface_default_where () =
  let src = {|interface Greeter a where
  greet x = prefix ++ x where
    prefix = "Hello, "
|} in
  match parse_one src with
  | DInterface { iface_name = "Greeter"; methods = [m]; _ } ->
    (match m with
     | { method_name = "greet";
         method_default = Some ([PVar "x"],
           ELetGroup (["prefix", [([], ELit (LString "Hello, "))]],
             EBinOp ("++", EVar "prefix", EVar "x"))); _ } -> ()
     | _ -> failwith (Printf.sprintf "wrong method shape: name=%s, default=%s"
              m.method_name
              (match m.method_default with
               | None -> "None"
               | Some (_, e) -> Ast.pp_expr e)))
  | d -> failwith ("wrong decl: " ^ pp_decl d)

(* ── where bindings: guards and multi-clause ─────────── *)

(* Single clause + guards in a where binding (count-style). *)
let test_where_binding_guards () =
  let src = {|countPos f xs = fold g 0 xs where
    g acc x
        | f x = acc + 1
        | otherwise = acc
|} in
  match parse_one src with
  | DFunDef (_, "countPos", _, ELetGroup ([("g", [([PVar "acc"; PVar "x"], _body)])], _)) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* Multi-clause where binding (find-style). *)
let test_where_binding_multi_clause () =
  let src = {|findFirst f xs = fold g None xs where
    g (Some a) _ = Some a
    g None x = if f x then Some x else None
|} in
  match parse_one src with
  | DFunDef (_, "findFirst", _,
      ELetGroup ([("g", [_; _])], _)) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* Multi-clause + guards combined (the full find pattern). *)
let test_where_binding_multi_clause_with_guards () =
  let src = {|find f xs = fold g None xs where
    g (acc@Some _) _ = acc
    g None x
        | f x = Some x
        | otherwise = None
|} in
  match parse_one src with
  | DFunDef (_, "find", _,
      ELetGroup ([("g", [_; _])], _)) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* Haskell-style: `where` on its own indented line below the body. *)
let test_where_on_new_line () =
  let src = {|find f xs = fold g None xs
    where
        g (acc@Some _) _ = acc
        g None x
            | f x = Some x
            | otherwise = None
|} in
  match parse_one src with
  | DFunDef (_, "find", _,
      ELetGroup ([("g", [_; _])], _)) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* ── if let / let else (Phase 38) ───────────────────── *)

let test_if_let_some () =
  match parse_expr "if let Some x = opt then x else 0\n" with
  | EMatch (EVar "opt", [
      (PCon ("Some", [PVar "x"]), [], EVar "x");
      (PWild, [], ELit (LInt 0));
    ]) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_if_let_tuple () =
  match parse_expr "if let (a, b) = pair then a else 0\n" with
  | EMatch (EVar "pair", [
      (PTuple [PVar "a"; PVar "b"], [], EVar "a");
      (PWild, [], ELit (LInt 0));
    ]) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_let_else_do () =
  let src = {|
f opt =
  do
    let Some x = opt else pure 0
    pure x
|} in
  match parse_one src with
  | DFunDef (false, "f", [PVar "opt"], EDo (_, [
      DoLetElse (PCon ("Some", [PVar "x"]), EVar "opt",
                 EApp (EVar "pure", ELit (LInt 0)));
      DoExpr (EApp (EVar "pure", EVar "x"));
    ])) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_if_let_nested () =
  match parse_expr "if let Some x = f y then x + 1 else 0\n" with
  | EMatch (EApp (EVar "f", EVar "y"), [
      (PCon ("Some", [PVar "x"]), [], EBinOp ("+", EVar "x", ELit (LInt 1)));
      (PWild, [], ELit (LInt 0));
    ]) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

(* ── Range literal tests (Phase 40) ──────────────────── *)

let test_range_list_half_open () =
  match parse_expr "[1..10]" with
  | ERangeList (ELit (LInt 1), ELit (LInt 10), false) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_range_list_inclusive () =
  match parse_expr "[1..=10]" with
  | ERangeList (ELit (LInt 1), ELit (LInt 10), true) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_range_array_inclusive () =
  match parse_expr "[|1..=100|]" with
  | ERangeArray (ELit (LInt 1), ELit (LInt 100), true) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_range_array_half_open () =
  match parse_expr "[|0..5|]" with
  | ERangeArray (ELit (LInt 0), ELit (LInt 5), false) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_slice_half_open () =
  match parse_expr "arr.[2..5]" with
  | ESlice (EVar "arr", ELit (LInt 2), ELit (LInt 5), false) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_slice_inclusive () =
  match parse_expr "arr.[0..=3]" with
  | ESlice (EVar "arr", ELit (LInt 0), ELit (LInt 3), true) -> ()
  | e -> failwith ("wrong: " ^ Ast.pp_expr e)

let test_range_pat_int_half_open () =
  let src = {|
classify n =
  match n
    1..9 => "single"
    _ => "other"
|} in
  match parse_one src with
  | DFunDef (false, "classify", [PVar "n"],
      EMatch (EVar "n", [
        (PRng (LInt 1, LInt 9, false), [], ELit (LString "single"));
        (PWild, [], ELit (LString "other"));
      ])) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_range_pat_char_inclusive () =
  let src = {|
isLower c =
  match c
    'a'..='z' => True
    _ => False
|} in
  match parse_one src with
  | DFunDef (false, "isLower", [PVar "c"],
      EMatch (EVar "c", [
        (PRng (LChar "a", LChar "z", true), [], EVar "True");
        (PWild, [], EVar "False");
      ])) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* ── prop declarations (Phase 42) ───────────────────── *)

let test_prop_single_param () =
  match parse_one {|prop "commutative" (x : Int) = x + 0 == x
|} with
  | DProp { prop_name = "commutative"; prop_params = [("x", TyCon "Int")]; _ } -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_prop_multi_param () =
  match parse_one {|prop "add_comm" (x : Int) (y : Int) = x + y == y + x
|} with
  | DProp { prop_name = "add_comm";
            prop_params = [("x", TyCon "Int"); ("y", TyCon "Int")]; _ } -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_prop_list_param () =
  match parse_one {|prop "nonempty" (xs : List Int) = length xs >= 0
|} with
  | DProp { prop_name = "nonempty";
            prop_params = [("xs", TyApp (TyCon "List", TyCon "Int"))]; _ } -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* ── bench declarations (Phase 48) ─────────────────────── *)

let test_bench_basic () =
  match parse_one {|bench "identity" = 42
|} with
  | DBench { bench_name = "identity"; is_pub = false; _ } -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_bench_expr () =
  match parse_one {|bench "add" = 1 + 2
|} with
  | DBench { bench_name = "add"; bench_body = EBinOp ("+", ELit (LInt 1), ELit (LInt 2)); _ } -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_bench_export () =
  match parse_one {|export bench "exported" = 0
|} with
  | DBench { bench_name = "exported"; is_pub = true; _ } -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* ── function keyword (Phase 44) ────────────────────────── *)

let test_function_basic () =
  let src = {|
classify =
  function
    0 => "zero"
    _ => "nonzero"
|} in
  (* The parser keeps `function` as an EFunction node; desugar.ml lowers it
     to \__fn_arg => match __fn_arg ... *)
  match parse_one src with
  | DFunDef (false, "classify", [],
      EFunction [
        (PLit (LInt 0), [], ELit (LString "zero"));
        (PWild, [], ELit (LString "nonzero"));
      ]) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_function_guard () =
  let src = {|
sign =
  function
    n if n > 0 => 1
    n if n < 0 => -1
    _ => 0
|} in
  match parse_one src with
  | DFunDef (false, "sign", [],
      EFunction [
        (PVar "n", [GBool (EBinOp (">", EVar "n", ELit (LInt 0)))], ELit (LInt 1));
        (PVar "n", [GBool (EBinOp ("<", EVar "n", ELit (LInt 0)))], EUnOp ("-", ELit (LInt 1)));
        (PWild, [], ELit (LInt 0));
      ]) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

(* ── Declaration attributes (Phase 49) ──────────────── *)

let test_attr_deprecated () =
  match parse_one "@deprecated \"use bar\"\nfoo x = x\n" with
  | DAttrib ([AttrDeprecated "use bar"], DFunDef (false, "foo", [PVar "x"], EVar "x")) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_attr_inline () =
  match parse_one "@inline\nfoo x = x\n" with
  | DAttrib ([AttrInline], DFunDef (false, "foo", [PVar "x"], EVar "x")) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_attr_must_use () =
  match parse_one "@must_use\nextern foo : Int -> Int\n" with
  | DAttrib ([AttrMustUse], DExtern (false, "foo", _)) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_attr_unknown () =
  match parse "@badattr\nfoo x = x\n" with
  | exception Failure msg when String.length msg > 0 -> ()
  | _ -> failwith "expected parse failure for unknown attribute"

(* ── Block comments ──────────────────────────────────── *)
(* Block comments are lexed as whitespace and never reach the parser. *)

let test_block_comment_inline () =
  match parse_one "x = {- c -} 1\n" with
  | DFunDef (false, "x", [], ELit (LInt 1)) -> ()
  | d -> failwith ("wrong: " ^ pp_decl d)

let test_block_comment_spanning () =
  match parse "x = 1\n{- multi\nline -}\ny = 2\n" with
  | [DFunDef (false, "x", [], ELit (LInt 1));
     DFunDef (false, "y", [], ELit (LInt 2))] -> ()
  | ds -> failwith ("wrong: " ^ String.concat "; " (List.map pp_decl ds))

let test_block_comment_nested () =
  match parse "{- a {- b -} c -}\nx = 1\n" with
  | [DFunDef (false, "x", [], ELit (LInt 1))] -> ()
  | ds -> failwith ("wrong: " ^ String.concat "; " (List.map pp_decl ds))

let test_block_comment_trailing_code () =
  match parse "x = 1 {- note\nmore -}\ny = 2\n" with
  | [DFunDef (false, "x", [], ELit (LInt 1));
     DFunDef (false, "y", [], ELit (LInt 2))] -> ()
  | ds -> failwith ("wrong: " ^ String.concat "; " (List.map pp_decl ds))

(* A file with no trailing newline must still parse: the lexer emits a
   terminating NEWLINE at EOF so the final decl's `newlines` is satisfied.
   Note the source string deliberately has no '\n' at the end. *)
let test_no_trailing_newline () =
  match parse "x = 1\ny = 2" with
  | [DFunDef (false, "x", [], ELit (LInt 1));
     DFunDef (false, "y", [], ELit (LInt 2))] -> ()
  | ds -> failwith ("wrong: " ^ String.concat "; " (List.map pp_decl ds))

(* Same, but the final binding ends inside an indented block — the EOF
   handler must emit NEWLINE *then* the DEDENT to close the block. *)
let test_no_trailing_newline_indented () =
  match parse "foo =\n  let x = 1\n  x" with
  | [DFunDef (false, "foo", [], _)] -> ()
  | ds -> failwith ("wrong: " ^ String.concat "; " (List.map pp_decl ds))

(* ── Test runner ─────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Medaka Parser" [
    "type signatures", [
      test_case "simple arrow"     `Quick test_typesig_simple;
      test_case "type variable"    `Quick test_typesig_typevar;
      test_case "effect"           `Quick test_typesig_effect;
      test_case "multi-effect"     `Quick test_typesig_multieffect;
      test_case "type application" `Quick test_typesig_typeapp;
    ];
    "function definitions", [
      test_case "constant"           `Quick test_fundef_simple;
      test_case "one argument"       `Quick test_fundef_with_arg;
      test_case "literal pattern"    `Quick test_fundef_pattern_lit;
      test_case "wildcard pattern"   `Quick test_fundef_wildcard;
      test_case "cons pattern"       `Quick test_fundef_cons_pattern;
      test_case "constructor pattern" `Quick test_fundef_constructor_pattern;
    ];
    "expressions", [
      test_case "lambda"            `Quick test_expr_lambda;
      test_case "lambda multi-arg"  `Quick test_expr_lambda_multi_arg;
      test_case "lambda ctor pat"   `Quick test_expr_lambda_ctor_pat;
      test_case "lambda ctor pat 2 args" `Quick test_expr_lambda_ctor_pat_two;
      test_case "lambda two params"  `Quick test_expr_lambda_two_params;
      test_case "lambda three params" `Quick test_expr_lambda_three_params;
      test_case "lambda ctor single pat regression" `Quick test_expr_lambda_ctor_single_pat_regression;
      test_case "let"               `Quick test_expr_let;
      test_case "let mut"           `Quick test_expr_let_mut;
      test_case "let fn one arg"    `Quick test_expr_let_fn_one_arg;
      test_case "let fn multi arg"  `Quick test_expr_let_fn_multi_arg;
      test_case "let rec inline"    `Quick test_expr_let_rec_inline;
      test_case "let rec inline mutual" `Quick test_expr_let_rec_inline_mutual;
      test_case "let rec top-level"        `Quick test_decl_let_rec_top;
      test_case "let rec top-level mutual" `Quick test_decl_let_rec_top_mutual;
      test_case "if-then-else"      `Quick test_expr_if;
      test_case "application"       `Quick test_expr_application;
      test_case "infix backtick"    `Quick test_expr_infix_backtick;
      test_case "list literal"      `Quick test_expr_list_literal;
      test_case "array literal"     `Quick test_expr_array_literal;
      test_case "tuple"             `Quick test_expr_tuple;
      test_case "field access"      `Quick test_expr_field_access;
      test_case "? postfix simple"  `Quick test_expr_question_simple;
      test_case "? postfix on app"  `Quick test_expr_question_app;
      test_case "record create"     `Quick test_expr_record_create;
      test_case "record update"     `Quick test_expr_record_update;
      test_case "record create pun (all)"    `Quick test_expr_record_create_pun;
      test_case "record create pun (mixed)"  `Quick test_expr_record_create_mixed_pun;
      test_case "record update pun"          `Quick test_expr_record_update_pun;
      test_case "record update nested"       `Quick test_expr_record_update_nested;
      test_case "record update nested deep"  `Quick test_expr_record_update_nested_deep;
      test_case "record update nested mixed" `Quick test_expr_record_update_mixed;
      test_case "type annotation"   `Quick test_expr_type_annot;
      test_case "array index"       `Quick test_expr_index;
      test_case "operator section"       `Quick test_expr_section;
      test_case "left section (2 * _)"  `Quick test_expr_left_section;
      test_case "left section (3 - _)"  `Quick test_expr_left_section_minus;
      test_case "left section app lhs"  `Quick test_expr_left_section_app;
      test_case "bare section (+)"      `Quick test_expr_bare_section_plus;
      test_case "bare section (-)"      `Quick test_expr_bare_section_minus;
      test_case "bare section (==)"     `Quick test_expr_bare_section_eq;
      test_case "bare section (::)"     `Quick test_expr_bare_section_cons;
      test_case "bare section (<>)"     `Quick test_expr_bare_section_append;
      test_case "(-5) unary negation"   `Quick test_expr_unary_minus_paren;
      test_case "list as arg"       `Quick test_expr_list_arg;
      test_case "modulo"            `Quick test_expr_modulo;
    ];
    "collection literals", [
      test_case "map literal"          `Quick test_map_literal;
      test_case "hashmap literal"      `Quick test_map_literal_hashmap;
      test_case "set literal"          `Quick test_set_literal;
      test_case "map singleton"        `Quick test_map_singleton;
      test_case "record still works"   `Quick test_record_still_works;
    ];
    "char and string upgrades", [
      test_case "char multibyte"         `Quick test_char_multibyte;
      test_case "char ascii"             `Quick test_char_ascii;
      test_case "string escape \\r"      `Quick test_string_escape_r;
      test_case "string escape \\0"      `Quick test_string_escape_zero;
      test_case "string escape \\u{}"    `Quick test_string_escape_unicode;
      test_case "multiline string"       `Quick test_string_multiline;
      test_case "non-multiline unchanged"`Quick test_string_no_multiline;
      test_case "triple basic"           `Quick test_triple_basic;
      test_case "triple multiline"       `Quick test_triple_multiline;
      test_case "triple embedded quotes" `Quick test_triple_embedded_quotes;
      test_case "triple escape"          `Quick test_triple_escape;
      test_case "triple unterminated"    `Quick test_triple_unterminated;
    ];
    "match", [
      test_case "basic match"       `Quick test_match_basic;
      test_case "match with guard"  `Quick test_match_with_guard;
    ];
    "as-patterns", [
      test_case "cons as-pattern"   `Quick test_as_pattern_cons;
      test_case "var as-pattern"    `Quick test_as_pattern_var;
    ];
    "top-level function guards", [
      test_case "single guard"   `Quick test_guard_single;
      test_case "multi guards"   `Quick test_guard_multi;
      test_case "no-param guard" `Quick test_guard_no_params;
      test_case "pattern-bind guard"     `Quick test_guard_pattern_bind;
      test_case "bind-then-bool guard"   `Quick test_guard_bind_then_bool;
      test_case "match-arm pattern bind" `Quick test_match_arm_pattern_bind;
    ];
    "data types", [
      test_case "inline variants"     `Quick test_data_inline;
      test_case "parametric variant"  `Quick test_data_with_fields;
      test_case "block variants"      `Quick test_data_block;
    ];
    "records", [
      test_case "record declaration"  `Quick test_record_decl;
    ];
    "do notation", [
      test_case "basic do"            `Quick test_do_basic;
      test_case "field assign"        `Quick test_do_field_assign;
      test_case "ref value assign"    `Quick test_do_ref_value_assign;
    ];
    "import declarations", [
      test_case "simple"                   `Quick test_use_simple;
      test_case "group"                    `Quick test_use_group;
      test_case "export import (re-export)" `Quick test_use_pub;
      test_case "alias"                    `Quick test_use_alias;
      test_case "wildcard"                 `Quick test_use_wildcard;
      test_case "export standalone type sig" `Quick test_export_standalone_type_sig;
      test_case "export standalone fun def"  `Quick test_export_standalone_fun_def;
      test_case "export data abstract"       `Quick test_export_data_abstract;
      test_case "public export data"         `Quick test_public_export_data;
      test_case "private data"               `Quick test_private_data;
      test_case "public export record"       `Quick test_public_export_record;
      test_case "export record abstract"     `Quick test_export_record_abstract;
    ];
    "pipe and compose", [
      test_case "pipe"                  `Quick test_pipe;
      test_case "pipe chain"            `Quick test_pipe_chain;
      test_case "compose >>"           `Quick test_compose_right;
      test_case "compose <<"           `Quick test_compose_left;
      test_case "pipe lower than ||"    `Quick test_pipe_lower_than_or;
      test_case "compose lower than ||" `Quick test_compose_lower_than_or;
    ];
    "leading-operator continuation", [
      test_case "pipe across lines"      `Quick test_cont_pipe;
      test_case "logical across lines"   `Quick test_cont_logical;
      test_case "all trigger operators"  `Quick test_cont_all_ops;
      test_case "dedented continuation"  `Quick test_cont_dedented;
      test_case "blank line before op"   `Quick test_cont_blank_line;
      test_case "comment not rescued"    `Quick test_cont_comment_not_rescued;
    ];
    "multiple declarations", [
      test_case "sig + def"       `Quick test_multi_decl;
      test_case "multi-clause fn" `Quick test_multi_clause;
    ];
    "extern declarations", [
      test_case "simple arrow"    `Quick test_extern_simple;
      test_case "type variable"   `Quick test_extern_typevar;
      test_case "effect"          `Quick test_extern_effect;
      test_case "constant"        `Quick test_extern_constant;
      test_case "multi-arg"       `Quick test_extern_multiarg;
    ];
    "constraint type signatures", [
      test_case "single constraint"        `Quick test_constraint_single;
      test_case "multiple constraints"     `Quick test_constraint_multi;
      test_case "zero-arg constraint"      `Quick test_constraint_no_args;
      test_case "type-app constraint arg"  `Quick test_constraint_type_app_arg;
    ];
    "type aliases", [
      test_case "simple alias"     `Quick test_type_alias_simple;
      test_case "parametric alias" `Quick test_type_alias_param;
      test_case "function alias"   `Quick test_type_alias_fun;
      test_case "export alias"     `Quick test_type_alias_export;
    ];
    "newtype declarations", [
      test_case "simple newtype"     `Quick test_newtype_simple;
      test_case "parametric newtype" `Quick test_newtype_param;
      test_case "export newtype"     `Quick test_newtype_export;
      test_case "newtype deriving"   `Quick test_newtype_deriving;
    ];
    "named impl declarations", [
      test_case "UPPER named impl"         `Quick test_named_impl_upper;
      test_case "default UPPER named impl" `Quick test_named_impl_default;
    ];
    "numeric literal extensions", [
      test_case "hex literal"            `Quick test_hex_literal;
      test_case "hex upper"              `Quick test_hex_literal_upper;
      test_case "hex with underscores"   `Quick test_hex_with_underscores;
      test_case "binary literal"         `Quick test_bin_literal;
      test_case "octal literal"          `Quick test_oct_literal;
      test_case "int with underscores"   `Quick test_int_with_underscores;
      test_case "float with underscores" `Quick test_float_with_underscores;
    ];
    "string interpolation", [
      test_case "single hole"        `Quick test_interp_single;
      test_case "two holes"          `Quick test_interp_two_segments;
      test_case "expression hole"    `Quick test_interp_expression;
    ];
    "record patterns", [
      test_case "field pun"          `Quick test_record_pat_pun;
      test_case "explicit + pun"     `Quick test_record_pat_explicit;
      test_case "rest only"          `Quick test_record_pat_rest_only;
      test_case "field with rest"    `Quick test_record_pat_with_rest;
    ];
    "named-field variants (Phase 39)", [
      test_case "inline declaration"  `Quick test_data_named_inline;
      test_case "block declaration"   `Quick test_data_named_block;
      test_case "pattern"             `Quick test_named_ctor_pat;
      test_case "construction"        `Quick test_named_ctor_create;
    ];
    "interface default where", [
      test_case "where in default body" `Quick test_iface_default_where;
    ];
    "where bindings (guards + multi-clause)", [
      test_case "guards in where binding"          `Quick test_where_binding_guards;
      test_case "multi-clause where binding"       `Quick test_where_binding_multi_clause;
      test_case "multi-clause + guards combined"   `Quick test_where_binding_multi_clause_with_guards;
      test_case "where on its own line (Haskell-style)" `Quick test_where_on_new_line;
    ];
    "if let / let else (Phase 38)", [
      test_case "if let Some"      `Quick test_if_let_some;
      test_case "if let tuple"     `Quick test_if_let_tuple;
      test_case "let else do"      `Quick test_let_else_do;
      test_case "if let nested"    `Quick test_if_let_nested;
    ];
    "range literals (Phase 40)", [
      test_case "list half-open [lo..hi]"       `Quick test_range_list_half_open;
      test_case "list inclusive [lo..=hi]"      `Quick test_range_list_inclusive;
      test_case "array inclusive [|lo..=hi|]"   `Quick test_range_array_inclusive;
      test_case "array half-open [|lo..hi|]"    `Quick test_range_array_half_open;
      test_case "slice half-open e.[lo..hi]"    `Quick test_slice_half_open;
      test_case "slice inclusive e.[lo..=hi]"   `Quick test_slice_inclusive;
      test_case "pattern int half-open lo..hi"  `Quick test_range_pat_int_half_open;
      test_case "pattern char inclusive 'a'..='z'" `Quick test_range_pat_char_inclusive;
    ];
    "prop declarations (Phase 42)", [
      test_case "single param"  `Quick test_prop_single_param;
      test_case "multi param"   `Quick test_prop_multi_param;
      test_case "list param"    `Quick test_prop_list_param;
    ];
    "bench declarations (Phase 48)", [
      test_case "basic literal"  `Quick test_bench_basic;
      test_case "expr body"      `Quick test_bench_expr;
      test_case "export"         `Quick test_bench_export;
    ];
    "function keyword (Phase 44)", [
      test_case "basic two arms"   `Quick test_function_basic;
      test_case "arms with guards" `Quick test_function_guard;
    ];
    "declaration attributes (Phase 49)", [
      test_case "@deprecated"  `Quick test_attr_deprecated;
      test_case "@inline"      `Quick test_attr_inline;
      test_case "@must_use"    `Quick test_attr_must_use;
      test_case "unknown attr" `Quick test_attr_unknown;
    ];
    "block comments", [
      test_case "inline"         `Quick test_block_comment_inline;
      test_case "spanning lines" `Quick test_block_comment_spanning;
      test_case "nested"         `Quick test_block_comment_nested;
      test_case "trailing code"  `Quick test_block_comment_trailing_code;
    ];
    "trailing newline", [
      test_case "missing at EOF"          `Quick test_no_trailing_newline;
      test_case "missing at EOF, indented" `Quick test_no_trailing_newline_indented;
    ];
  ]
