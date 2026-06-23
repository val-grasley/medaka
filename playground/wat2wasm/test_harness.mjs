// Node verification harness for the browser WAT->wasm assembler.
// Loads the SHIPPED `--target web` glue (the exact artifact the playground uses)
// by passing the wasm bytes straight to the default init (avoids fetch()).
// Run under Node >= 22 for WebAssembly GC validation.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import init, { wat2wasm } from '../vendor/wat2wasm/wat2wasm.js';

const wasmPath = fileURLToPath(new URL('../vendor/wat2wasm/wat2wasm_bg.wasm', import.meta.url));
await init({ module_or_path: await readFile(wasmPath) });

let failures = 0;

// 1. GC sample: struct.new + ref type result.
const gcWat = `
  (module
    (type $pair (struct (field i32) (field i32)))
    (func (export "mk") (result (ref $pair))
      (struct.new $pair (i32.const 1) (i32.const 2))))
`;
try {
  const bytes = wat2wasm(gcWat);
  const ok = WebAssembly.validate(bytes);
  console.log(`GC sample: assembled ${bytes.length} bytes; WebAssembly.validate = ${ok}`);
  if (!(bytes.length > 0 && ok === true)) { failures++; console.error('  FAIL: expected bytes + validate true'); }
} catch (e) {
  failures++;
  console.error('  FAIL: GC sample threw:', String(e));
}

// 2. Broader GC features: array.new + br_on_cast + ref.
const gcWat2 = `
  (module
    (type $arr (array (mut i32)))
    (type $pair (struct (field i32)))
    (func (export "f") (param $x (ref any)) (result i32)
      (block $b (result (ref $pair))
        (local.get $x)
        (br_on_cast $b (ref any) (ref $pair))
        (drop)
        (return (i32.const 0)))
      (struct.get $pair 0))
    (func (export "g") (result (ref $arr))
      (array.new $arr (i32.const 7) (i32.const 3))))
`;
try {
  const bytes = wat2wasm(gcWat2);
  const ok = WebAssembly.validate(bytes);
  console.log(`GC sample 2 (array.new/br_on_cast): assembled ${bytes.length} bytes; validate = ${ok}`);
  if (!(bytes.length > 0 && ok === true)) { failures++; console.error('  FAIL: expected bytes + validate true'); }
} catch (e) {
  failures++;
  console.error('  FAIL: GC sample 2 threw:', String(e));
}

// 3. Broken WAT -> readable JS error string (NOT a panic).
const brokenWat = `(module (func (export "x") (result i32) (i32.const)))`;
try {
  const bytes = wat2wasm(brokenWat);
  failures++;
  console.error(`  FAIL: broken WAT unexpectedly assembled ${bytes.length} bytes`);
} catch (e) {
  const msg = String(e?.message ?? e);
  console.log(`Broken WAT: returned error string -> ${JSON.stringify(msg.split('\n')[0])}`);
  if (typeof (e?.message ?? e) !== 'string' && typeof e !== 'string') {
    failures++; console.error('  FAIL: error was not a string');
  }
}

console.log(failures === 0 ? 'ALL CHECKS PASSED' : `FAILURES: ${failures}`);
process.exit(failures === 0 ? 0 : 1);
