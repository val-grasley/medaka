use wasm_bindgen::prelude::*;

/// Assemble a WebAssembly text (WAT) string into wasm bytes.
///
/// Wraps the `wat` crate (wasm-tools 1.252.0 lineage). GC + function-references
/// are enabled by default in current `wat`, so the finalized WebAssembly 3.0 GC
/// proposal (`struct.new`, `array.new`, ref types, `br_on_cast`, ...) assembles
/// without any feature flags.
///
/// On a parse/assemble error, returns the rendered error message as a `JsValue`
/// string so the browser surfaces a readable assembler diagnostic instead of a
/// trap/panic.
#[wasm_bindgen]
pub fn wat2wasm(src: &str) -> Result<Vec<u8>, JsValue> {
    wat::parse_str(src).map_err(|e| JsValue::from_str(&e.to_string()))
}
