let () =
  let var_name = Sys.argv.(1) in
  let file     = Sys.argv.(2) in
  let ic = open_in file in
  let content = really_input_string ic (in_channel_length ic) in
  close_in ic;
  Printf.printf "let %s = {stdlib_content|\n%s\n|stdlib_content}\n" var_name content
