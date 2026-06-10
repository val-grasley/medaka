(* Stage 3 — `medaka build <file.mdk>` — native-compile a user program via the
   LLVM backend.

   Invocation:
     medaka build [--output <bin>] <file.mdk>

   Pipeline:
     1. Locate the repo root from the running binary's path (ascending until
        selfhost/llvm_emit_modules_main.mdk exists).
     2. Emit LLVM IR:
          medaka run selfhost/llvm_emit_modules_main.mdk \
            stdlib/runtime.mdk <core.mdk> <file.mdk> <dir> > <tmp>.ll
     3. Compile + link:
          clang [stack] <tmp>.ll runtime/medaka_rt.c [GC flags] -o <output>
     4. Print the output path on success; propagate non-zero exit on any failure.

   This is the first user-facing entry point to the LLVM backend; it is
   intentionally simple (no caching, no parallel modules, no cross-module DCE).
   A reachable emitter gap is a hard error — the gap-tolerant bootstrap path is
   NOT used here.

   Prelude status (Stage 3 item 2a): `core.mdk` is not yet passed as the real
   prelude because `maximum`/`minimum` in core.mdk trigger the `max`/`min`
   arg-tag dispatch gap (EMITTER-GAPS.md gap #12 note, census A residual 2 events)
   even for programs that never call them — the emitter processes all of core.mdk
   including unreachable code.  Until that gap is closed (Stage 3 item 2b D3b, or
   a DCE pass prunes the unreachable bodies), we pass an EMPTY core so programs
   that use the runtime externs directly (putStrLn / putStr / arithmetic) can be
   built natively.  The flip to real core.mdk is a one-line change here once D3b
   lands (`empty_core` → `core_mdk` in the emit_cmd below).

   Gap policy: the emitter (`emitProgram`) runs with recording OFF, so any
   unsupported construct panics immediately and the error propagates.
*)

(* ── root resolution ─────────────────────────────────────────────────────── *)

(** Walk up from [path] until a directory containing [sentinel] exists.
    Returns [Some dir] on success, [None] if we reach the filesystem root. *)
let rec find_root_from path sentinel =
  let probe = Filename.concat path sentinel in
  if Sys.file_exists probe then Some path
  else
    let parent = Filename.dirname path in
    if parent = path then None   (* filesystem root *)
    else find_root_from parent sentinel

(** Resolve the medaka repo root.  Strategy (first that works):
    1. $MEDAKA_HOME env var.
    2. Walk up from the running binary's absolute path.
    3. Walk up from cwd.
    Sentinel: selfhost/llvm_emit_modules_main.mdk (present in the repo). *)
let find_root () =
  let sentinel = Filename.concat "selfhost" "llvm_emit_modules_main.mdk" in
  match Sys.getenv_opt "MEDAKA_HOME" with
  | Some v -> Some v
  | None ->
    (* abs path to this binary *)
    let exe =
      let raw = Sys.argv.(0) in
      if Filename.is_relative raw then
        Filename.concat (Sys.getcwd ()) raw
      else raw
    in
    let exe_dir = Filename.dirname exe in
    (match find_root_from exe_dir sentinel with
     | Some r -> Some r
     | None   -> find_root_from (Sys.getcwd ()) sentinel)

(* ── GC location ─────────────────────────────────────────────────────────── *)

(** Try to locate the Boehm GC (bdw-gc).
    Returns [(cflags, libs)] suitable for passing to clang. *)
let find_gc () =
  (* pkg-config first *)
  let try_pkg () =
    let c = Unix.system "pkg-config --exists bdw-gc 2>/dev/null" in
    if c = Unix.WEXITED 0 then begin
      let cflags =
        let ic = Unix.open_process_in "pkg-config --cflags bdw-gc 2>/dev/null" in
        let s = try input_line ic with End_of_file -> "" in
        let _ = Unix.close_process_in ic in
        String.trim s
      in
      let libs =
        let ic = Unix.open_process_in "pkg-config --libs bdw-gc 2>/dev/null" in
        let s = try input_line ic with End_of_file -> "" in
        let _ = Unix.close_process_in ic in
        String.trim s
      in
      Some (cflags, libs)
    end else None
  in
  (* brew keg fallback *)
  let try_brew () =
    let ic = Unix.open_process_in "brew --prefix bdw-gc 2>/dev/null" in
    let prefix = try input_line ic with End_of_file -> "" in
    let _ = Unix.close_process_in ic in
    let prefix = String.trim prefix in
    if prefix <> "" && Sys.file_exists (Filename.concat prefix "include/gc.h") then
      Some
        (Printf.sprintf "-I%s/include" prefix,
         Printf.sprintf "-L%s/lib -lgc" prefix)
    else None
  in
  (* bare -lgc fallback *)
  let try_bare () =
    let probe = "printf '#include <gc.h>\\nint main(void){return 0;}\\n' \
                 | cc -x c - -lgc -o /dev/null 2>/dev/null" in
    if Unix.system probe = Unix.WEXITED 0 then Some ("", "-lgc")
    else None
  in
  match try_pkg () with
  | Some r -> Ok r
  | None ->
    match try_brew () with
    | Some r -> Ok r
    | None ->
      match try_bare () with
      | Some r -> Ok r
      | None ->
        Error "libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) \
               or set GC_PREFIX"

(* ── subprocess helpers ───────────────────────────────────────────────────── *)

let read_command_output cmd =
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 256 in
  (try while true do
      Buffer.add_string buf (input_line ic);
      Buffer.add_char buf '\n'
    done
   with End_of_file -> ());
  let _ = Unix.close_process_in ic in
  Buffer.contents buf

(** Run [cmd] in a shell, returning exit code. *)
let sh cmd = match Unix.system cmd with
  | Unix.WEXITED c -> c
  | _ -> 127

(* ── main entry ──────────────────────────────────────────────────────────── *)

let run (argv : string array) : int =
  let argc = Array.length argv in
  (* Parse options: --output <bin>, then <file.mdk> *)
  let output_opt = ref None in
  let file_opt   = ref None in
  let i = ref 0 in
  while !i < argc do
    (match argv.(!i) with
     | "--output" | "-o" ->
       if !i + 1 < argc then begin
         output_opt := Some argv.(!i + 1); incr i
       end else begin
         Printf.eprintf "error: --output requires an argument\n"; exit 1
       end
     | f -> file_opt := Some f);
    incr i
  done;
  let entry =
    match !file_opt with
    | Some f -> f
    | None ->
      Printf.eprintf "usage: medaka build [--output <bin>] <file.mdk>\n";
      exit 1
  in
  (* Locate repo root *)
  let root =
    match find_root () with
    | Some r -> r
    | None ->
      Printf.eprintf
        "error: cannot find medaka repo root (selfhost/ dir) from binary path \
         or cwd.\nSet MEDAKA_HOME to the repo root.\n";
      exit 1
  in
  let runtime_mdk  = Filename.concat root "stdlib/runtime.mdk" in
  let _core_mdk    = Filename.concat root "stdlib/core.mdk" in   (* flip when max/min gap closed *)
  let emit_driver  = Filename.concat root "selfhost/llvm_emit_modules_main.mdk" in
  let runtime_c    = Filename.concat root "runtime/medaka_rt.c" in
  let medaka_bin   =
    (* Use the running binary itself — guaranteed to exist. *)
    let raw = Sys.argv.(0) in
    if Filename.is_relative raw then Filename.concat (Sys.getcwd ()) raw
    else raw
  in
  (* Sanity-check the repo files exist *)
  List.iter (fun f ->
    if not (Sys.file_exists f) then begin
      Printf.eprintf "error: expected file %s not found (MEDAKA_HOME=%s)\n" f root;
      exit 1
    end
  ) [runtime_mdk; emit_driver; runtime_c];
  (* Determine entry directory (for multi-module root) *)
  let entry_abs =
    if Filename.is_relative entry then Filename.concat (Sys.getcwd ()) entry
    else entry
  in
  let entry_dir = Filename.dirname entry_abs in
  (* Determine output path *)
  let output =
    match !output_opt with
    | Some o -> o
    | None ->
      let base = Filename.basename entry in
      let stem =
        if Filename.check_suffix base ".mdk" then
          Filename.chop_suffix base ".mdk"
        else base
      in
      stem
  in
  (* Locate GC *)
  let gc_cflags, gc_libs =
    match find_gc () with
    | Ok (cf, ls) -> cf, ls
    | Error msg ->
      Printf.eprintf "error: %s\n" msg;
      exit 1
  in
  (* ── Step 1: emit LLVM IR ── *)
  let tmp_ll   = Filename.temp_file "medaka_build_" ".ll" in
  let tmp_core = Filename.temp_file "medaka_build_" "_core.mdk" in  (* empty prelude placeholder *)
  let tmp_err  = Filename.temp_file "medaka_build_" ".err" in
  at_exit (fun () ->
    (try Sys.remove tmp_ll   with _ -> ());
    (try Sys.remove tmp_core with _ -> ());
    (try Sys.remove tmp_err  with _ -> ()));
  (* Write empty core: flip to _core_mdk when max/min gap is closed (Stage 3 item 2b). *)
  (let oc = open_out tmp_core in close_out oc);
  let emit_cmd =
    Printf.sprintf
      "%s run %s %s %s %s %s > %s 2> %s"
      (Filename.quote medaka_bin)
      (Filename.quote emit_driver)
      (Filename.quote runtime_mdk)
      (Filename.quote tmp_core)
      (Filename.quote entry_abs)
      (Filename.quote entry_dir)
      (Filename.quote tmp_ll)
      (Filename.quote tmp_err)
  in
  let emit_rc = sh emit_cmd in
  if emit_rc <> 0 then begin
    let err = read_command_output (Printf.sprintf "cat %s" (Filename.quote tmp_err)) in
    Printf.eprintf "medaka build: emit failed:\n%s" err;
    emit_rc
  end else begin
    (* ── Step 2: compile + link ── *)
    let cc = try Sys.getenv "CC" with Not_found -> "clang" in
    (* Large stack for the emitted code (matches the selfcompile harnesses). *)
    let stack_flag =
      (* arm64 macOS: pass via linker; other platforms skip *)
      let uname_m = String.trim (read_command_output "uname -m 2>/dev/null") in
      let uname_s = String.trim (read_command_output "uname -s 2>/dev/null") in
      if uname_s = "Darwin" && uname_m = "arm64" then
        "-Wl,-stack_size,0x20000000"
      else ""
    in
    let cc_cmd =
      Printf.sprintf
        "%s %s %s %s %s %s -o %s"
        (Filename.quote cc)
        stack_flag
        gc_cflags
        (Filename.quote tmp_ll)
        (Filename.quote runtime_c)
        gc_libs
        (Filename.quote output)
    in
    let cc_rc = sh cc_cmd in
    if cc_rc <> 0 then begin
      Printf.eprintf "medaka build: clang link failed (exit %d)\n" cc_rc;
      cc_rc
    end else begin
      Printf.printf "medaka build: %s\n" output;
      0
    end
  end
