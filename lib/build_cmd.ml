(* medaka build — Stage 3 sequence item 1.

   Compile a user `.mdk` program to a native binary via the existing
   Medaka-hosted LLVM emitter (`selfhost/llvm_emit_modules_main.mdk`) + clang.

   This is the *wiring* only — the backend is unchanged.  The pipeline mirrors
   the proven self-host harnesses (test/diff_selfhost_llvm_modules.sh,
   test/selfcompile_lex.sh):

     1. emit  = medaka run selfhost/llvm_emit_modules_main.mdk \
                  <runtime.mdk> <stdlib/core.mdk> <entry.mdk> <entry-dir> <selfhost> > out.ll
     2. trim a trailing "()\n" the native runtime auto-print convention would add
        (the emitter's `main : <IO,Mut> Unit` produces it through the interpreter)
     3. clang out.ll runtime/medaka_rt.c <gc-flags> -Wl,-stack_size,0x20000000 -o <bin>

   IMPLEMENTATION = SHELL-OUT.  We invoke this same executable recursively
   (`<self> run <emitter> …`) as a subprocess and capture its stdout, rather
   than driving the emitter in-process.  Reasons (and why the guardrail blesses
   this for the MVP): the emitter is a Medaka program whose IR reaches stdout via
   `putStr`, and it carries heavy global `Ref` state (gap log, arg-stamp tables);
   capturing the interpreter's stdout in-process and guaranteeing no Ref bleed
   across invocations is fragile.  The subprocess gives a clean stdout pipe and a
   fresh process per build — exactly what every working harness does.

   PRELUDE.  `medaka build` passes the real `stdlib/core.mdk` prelude (Stage 3
   #2a complete).  Two emitter blockers were cleared before this flip:
   (1) DCE (`selfhost/dce.mdk`, wired into `llvm_emit_modules_main.mdk`'s
   `runEmit`) drops unreachable plain prelude functions `maximum`/`minimum`/`clamp`
   that hit the open `max`/`min` arg-tag gap; (2) the unit-head emitter gap (E20)
   was closed so core.mdk's `Arbitrary` impls (`arbitrary () = …`) emit correctly.
   With DCE + E20, the full prelude compiles cleanly.  The buildable surface now
   includes `println`/`show`/`Debug`, `Eq`/`Ord`, `Foldable`/`Mappable`, and
   `data … deriving (Eq, Debug)` in addition to all the previously-available
   constructs (runtime externs, arithmetic, ADTs + match, recursion, closures,
   tuples, records, arrays, cross-module data). *)

let read_file filename =
  let ic = open_in_bin filename in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* Walk up from the executable's directory looking for the marker asset that
   pins the repo root.  Mirrors the harness scripts' `ROOT=…/..` but robust to
   where the exe is invoked from. *)
let find_repo_root () =
  let marker = Filename.concat "selfhost" "llvm_emit_modules_main.mdk" in
  let exists_at dir = Sys.file_exists (Filename.concat dir marker) in
  let rec walk dir =
    if exists_at dir then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else walk parent
  in
  (* Start from the real executable location, then fall back to cwd. *)
  let start =
    let exe =
      try
        let e = Sys.executable_name in
        if Filename.is_relative e then Filename.concat (Sys.getcwd ()) e else e
      with _ -> Sys.getcwd ()
    in
    Filename.dirname exe
  in
  match walk start with
  | Some r -> Some r
  | None -> walk (Sys.getcwd ())

(* Run a command, capturing stdout to [out_path] and stderr to a string.
   Returns (exit_code, stderr_text).  Uses a temp file for stderr so we can
   surface emitter/clang diagnostics cleanly. *)
let run_capture ~argv ~out_path =
  let err_path = Filename.temp_file "medaka_build_" ".err" in
  let out_fd = Unix.openfile out_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
  let err_fd = Unix.openfile err_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
  let pid =
    Unix.create_process argv.(0) argv Unix.stdin out_fd err_fd
  in
  Unix.close out_fd;
  Unix.close err_fd;
  let (_, status) = Unix.waitpid [] pid in
  let code = match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED s -> 128 + s
    | Unix.WSTOPPED s -> 128 + s
  in
  let err_text = (try read_file err_path with _ -> "") in
  (try Sys.remove err_path with _ -> ());
  (code, err_text)

(* The native runtime auto-prints `main`'s Unit as a trailing "()\n".  The
   emitter's own `main : <IO,Mut> Unit` writes the IR via putStr, then the
   interpreter would NOT add it — but to stay byte-identical with the harness
   convention (and be safe if that ever changes), strip a trailing "()\n" if the
   captured IR ends with exactly those 3 bytes.  Returns the trimmed string. *)
let strip_trailing_unit s =
  let n = String.length s in
  if n >= 3 && String.sub s (n - 3) 3 = "()\n" then String.sub s 0 (n - 3) else s

(* Detect the Boehm GC compile/link flags exactly as the harness scripts do:
   pkg-config bdw-gc → brew --prefix bdw-gc → bare -lgc.  Returns
   (cflags_list, libs_list) or None if libgc can't be found. *)
let detect_gc cc =
  let read_cmd cmd =
    try
      let ic = Unix.open_process_in cmd in
      let line = (try input_line ic with End_of_file -> "") in
      let _ = Unix.close_process_in ic in
      String.trim line
    with _ -> ""
  in
  let split_ws s =
    List.filter (fun x -> x <> "") (String.split_on_char ' ' s)
  in
  let cmd_ok cmd = (try Sys.command (cmd ^ " >/dev/null 2>&1") = 0 with _ -> false) in
  if cmd_ok "pkg-config --exists bdw-gc" then
    let cflags = read_cmd "pkg-config --cflags bdw-gc" in
    let libs   = read_cmd "pkg-config --libs bdw-gc" in
    Some (split_ws cflags, split_ws libs)
  else begin
    let prefix = read_cmd "brew --prefix bdw-gc 2>/dev/null" in
    if prefix <> "" && Sys.file_exists (Filename.concat prefix "include/gc.h") then
      Some ([ "-I" ^ Filename.concat prefix "include" ],
            [ "-L" ^ Filename.concat prefix "lib"; "-lgc" ])
    else
      (* Bare -lgc on the default search path. *)
      let probe =
        Printf.sprintf
          "printf '#include <gc.h>\\nint main(void){return 0;}\\n' | %s -x c - -lgc -o /dev/null"
          (Filename.quote cc)
      in
      if cmd_ok probe then Some ([], [ "-lgc" ]) else None
  end

let usage () =
  prerr_endline
    "usage: medaka build <file.mdk> [-o <out>]\n\
     \n\
     Compile a Medaka program to a native binary (LLVM emitter + clang).\n\
     The output defaults to the input's basename (sans .mdk).";
  ()

(* argv layout passed in: everything AFTER "build". *)
let run (args : string array) : int =
  let argl = Array.to_list args in
  (* Parse a single optional -o <out>; first remaining positional is the input. *)
  let rec parse acc out = function
    | [] -> (List.rev acc, out)
    | "-o" :: v :: rest -> parse acc (Some v) rest
    | "-o" :: [] -> prerr_endline "error: -o requires an argument"; ([], None)
    | x :: rest -> parse (x :: acc) out rest
  in
  let (positionals, out_opt) = parse [] None argl in
  match positionals with
  | [] -> usage (); 1
  | _ :: _ :: _ ->
    prerr_endline "error: medaka build takes exactly one input file"; 1
  | [ input ] ->
    if not (Sys.file_exists input) then begin
      Printf.eprintf "error: no such file: %s\n" input; 1
    end else begin
      let repo_root =
        match find_repo_root () with
        | Some r -> r
        | None ->
          prerr_endline
            "error: could not locate the Medaka repo root (selfhost/llvm_emit_modules_main.mdk).\n\
             medaka build currently resolves backend assets relative to the source checkout.";
          exit 1
      in
      let self = Sys.executable_name in
      let emitter   = Filename.concat repo_root "selfhost/llvm_emit_modules_main.mdk" in
      let runtime   = Filename.concat repo_root "stdlib/runtime.mdk" in
      let prelude   = Filename.concat repo_root "stdlib/core.mdk" in
      let rt_c      = Filename.concat repo_root "runtime/medaka_rt.c" in
      let selfhost  = Filename.concat repo_root "selfhost" in
      let stdlib_dir = Filename.concat repo_root "stdlib" in
      let input_abs =
        if Filename.is_relative input then Filename.concat (Sys.getcwd ()) input else input
      in
      let input_dir = Filename.dirname input_abs in
      let out_path =
        match out_opt with
        | Some o -> o
        | None ->
          let base = Filename.basename input in
          (try Filename.chop_extension base with Invalid_argument _ -> base)
      in
      let cc = try Sys.getenv "CC" with Not_found -> "clang" in

      let ll_path = Filename.temp_file "medaka_build_" ".ll" in
      let cleanup () =
        (try Sys.remove ll_path with _ -> ())
      in

      (* ---- STEP 1: emit LLVM IR via the self-hosted emitter (shell-out) ---- *)
      (* Roots: input_dir first (user modules shadow stdlib), then selfhost,
         then stdlib_dir so stdlib modules (list, array, string, map, set, io,
         …) resolve without requiring them to sit next to the user's file.
         This mirrors the loader's root-ordered search in lib/loader.ml. *)
      let emit_argv =
        [| self; "run"; emitter; runtime; prelude; input_abs; input_dir; selfhost; stdlib_dir |]
      in
      let (emit_code, emit_err) = run_capture ~argv:emit_argv ~out_path:ll_path in
      if emit_code <> 0 then begin
        Printf.eprintf "error: emitter failed compiling %s\n" input;
        (* Surface the emitter's own diagnostic — often a clean
           `panic: … gap …` for an unsupported construct (MVP hard-error). *)
        if String.trim emit_err <> "" then prerr_string emit_err;
        cleanup (); exit 1
      end;

      (* Trim the trailing "()\n" auto-print convention if present, in place. *)
      let ir = read_file ll_path in
      let ir = strip_trailing_unit ir in
      if String.length ir = 0 then begin
        Printf.eprintf "error: emitter produced empty IR for %s\n" input;
        if String.trim emit_err <> "" then prerr_string emit_err;
        cleanup (); exit 1
      end;
      (let oc = open_out_bin ll_path in output_string oc ir; close_out oc);

      (* ---- STEP 2: clang the IR + C runtime + Boehm GC into a native binary ---- *)
      (match detect_gc cc with
       | None ->
         prerr_endline
           "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config.";
         cleanup (); exit 1
       | Some (gc_cflags, gc_libs) ->
         let clang_argv =
           Array.of_list
             ([ cc; "-Wl,-stack_size,0x20000000" ]
              @ gc_cflags
              @ [ ll_path; rt_c ]
              @ gc_libs
              @ [ "-o"; out_path ])
         in
         let clang_err_path = Filename.temp_file "medaka_build_cc_" ".err" in
         let err_fd = Unix.openfile clang_err_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
         let pid = Unix.create_process clang_argv.(0) clang_argv Unix.stdin Unix.stdout err_fd in
         Unix.close err_fd;
         let (_, status) = Unix.waitpid [] pid in
         let clang_err = (try read_file clang_err_path with _ -> "") in
         (try Sys.remove clang_err_path with _ -> ());
         (match status with
          | Unix.WEXITED 0 -> ()
          | _ ->
            Printf.eprintf "error: clang failed linking %s\n" input;
            prerr_string clang_err;
            cleanup (); exit 1);
         cleanup ();
         Printf.printf "built %s -> %s\n" input out_path);
      0
    end