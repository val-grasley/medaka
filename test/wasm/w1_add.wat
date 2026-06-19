;; Slice W1 — WasmGC toolchain proof.
;; Computes 1 + 2 with i31ref immediates (the WasmGC immediate encoding per
;; RUNTIME-DESIGN §8.6) and writes the result through a host import, mirroring
;; the planned `env.mdk_write` IO seam (WASMGC-DESIGN §6/§10 fork e).
;; Expected program output: 3
(module
  (import "env" "mdk_write" (func $mdk_write (param i32)))

  (func $main
    ;; box 1 and 2 as i31ref, unbox, add, write
    (call $mdk_write
      (i32.add
        (i31.get_s (ref.i31 (i32.const 1)))
        (i31.get_s (ref.i31 (i32.const 2)))))
  )

  (start $main)
)
