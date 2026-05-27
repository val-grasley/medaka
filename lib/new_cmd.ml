(* `medaka new <name>` — scaffold a new project. *)

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let toml_template name =
  Printf.sprintf
{|[package]
name = "%s"
version = "0.1.0"
entry = "main.mdk"
|}
    name

let main_template =
{|main : <IO> Unit
main = println "Hello, Medaka!"
|}

let gitignore_template =
{|_build/
|}

let readme_template name =
  Printf.sprintf "# %s\n\nA new Medaka project.\n" name

let invalid_name name =
  name = "" || name = "." || name = ".."
  || String.contains name '/'
  || String.contains name '\\'

let usage () =
  prerr_endline "Usage: medaka new <name>"

let run argv =
  match Array.to_list argv with
  | [name] ->
    if invalid_name name then begin
      Printf.eprintf "medaka new: invalid project name: %S\n" name;
      2
    end else if Sys.file_exists name then begin
      Printf.eprintf "medaka new: path already exists: %s\n" name;
      1
    end else begin
      Unix.mkdir name 0o755;
      write_file (Filename.concat name "medaka.toml") (toml_template name);
      write_file (Filename.concat name "main.mdk") main_template;
      write_file (Filename.concat name ".gitignore") gitignore_template;
      write_file (Filename.concat name "README.md") (readme_template name);
      Printf.printf "Created %s/\n" name;
      0
    end
  | _ ->
    usage ();
    2
