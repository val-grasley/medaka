# META
source_lines=21
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/snap_wasm.mdk — re-export shim for the WasmGC emitter's
-- `emitProgram`.
--
-- WHY THIS FILE EXISTS: `backend.llvm_emit` and `backend.wasm_emit` both export a
-- function named `emitProgram`, and Medaka has NO import aliasing — the form
-- SYNTAX.md advertises (`import backend.wasm_emit.{emitProgram as w}`) does not
-- parse in item position ("unexpected 'as'").  So a single module cannot import
-- both.  This shim imports the WasmGC one and re-exports it under a distinct
-- name, which lets compiler/tools/snapshot.mdk drive BOTH backends from ONE
-- process over ONE lowered CProgram.
--
-- `emitProgram` is the ONLY colliding name: the WasmGC side-table installers the
-- snapshot runner needs (installDeclRetTypes / installCtorFloatFields) and its
-- gap-census switches (enableGapRecordW / resetGapsW / gapEventsW) are all
-- already distinct from their LLVM peers, so snapshot.mdk imports those direct.

import ir.core_ir.{CProgram}
import backend.wasm_emit.{emitProgram}

export wasmText : CProgram -> <Mut> String
wasmText cp = emitProgram cp
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" false))))
(DUse false (UseGroup ("backend" "wasm_emit") ((mem "emitProgram" false))))
(DTypeSig true "wasmText" (TyFun (TyCon "CProgram") (TyEffect ("Mut") None (TyCon "String"))))
(DFunDef false "wasmText" ((PVar "cp")) (EApp (EVar "emitProgram") (EVar "cp")))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" false))))
(DUse false (UseGroup ("backend" "wasm_emit") ((mem "emitProgram" false))))
(DTypeSig true "wasmText" (TyFun (TyCon "CProgram") (TyEffect ("Mut") None (TyCon "String"))))
(DFunDef false "wasmText" ((PVar "cp")) (EApp (EVar "emitProgram") (EVar "cp")))
