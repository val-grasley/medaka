open Medaka_lib

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  Parser.program Lexer.token lexbuf

let try_check label src =
  Printf.printf "── %s ──\n" label;
  Printf.printf "src: %s\n" (String.escaped src);
  (try
    let prog = parse src in
    Printf.printf "Parsed %d decls\n" (List.length prog);
    List.iter (fun d ->
      Printf.printf "  decl: %s\n"
        (match d with
         | Ast.DFunDef (n, pats, body) ->
           Printf.sprintf "DFunDef(%s, [%d pats], %s)"
             n (List.length pats) (Ast.pp_expr body)
         | Ast.DTypeSig (n, _) -> Printf.sprintf "DTypeSig(%s)" n
         | _ -> "<other>")
    ) prog;
    let env = Typecheck.check_program prog in
    Printf.printf "  Inferred:\n";
    List.iter (fun (n, s) ->
      Printf.printf "    %s : %s\n" n (Typecheck.pp_scheme s)
    ) env
  with
  | Typecheck.Type_error e ->
    Printf.printf "  TYPE ERROR: %s\n" (Typecheck.pp_error e)
  | Failure msg ->
    Printf.printf "  FAILURE: %s\n" msg);
  Printf.printf "\n"

let () =
  try_check "factorial" "fact n = if n == 0 then 1 else n * fact (n - 1)\n";
  try_check "mutual"
    "isEven n = if n == 0 then True else isOdd (n - 1)\nisOdd n = if n == 0 then False else isEven (n - 1)\n";
  try_check "map" "map f xs =\n  match xs\n    [] => []\n    x :: rest => f x :: map f rest\n";
  try_check "swap" "swap p =\n  match p\n    (a, b) => (b, a)\n";
  try_check "id only" "id x = x\n";
  try_check "id used Int" "id x = x\na = id 5\n";
  try_check "id used both" "id x = x\na = id 5\nb = id \"hi\"\n"
