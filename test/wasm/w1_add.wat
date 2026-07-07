;; Slice W1 — WasmGC toolchain proof.
;; Computes 1 + 2 with i31ref immediates (the WasmGC immediate encoding per
;; RUNTIME-DESIGN §8.6) and writes the result through the host byte-IO import,
;; mirroring the `env.mdk_write_byte` IO seam (WASMGC-DESIGN §6/§10 fork e).
;; run.js migrated the host surface to a byte channel (mdk_write_byte), so the
;; sum is emitted as its ASCII decimal digit (+48 -> '3').
;; Expected program output: 3
(module
  (import "env" "mdk_write_byte" (func $mdk_write_byte (param i32)))

  (func $main
    ;; box 1 and 2 as i31ref, unbox, add, emit the sum as an ASCII digit byte
    (call $mdk_write_byte
      (i32.add
        (i32.const 48)
        (i32.add
          (i31.get_s (ref.i31 (i32.const 1)))
          (i31.get_s (ref.i31 (i32.const 2))))))
  )

  (start $main)
)
