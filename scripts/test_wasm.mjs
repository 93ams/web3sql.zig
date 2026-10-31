// REQ-WASM-01 / REQ-WASM-03: runs the generated BigQuery library exactly as a warehouse would: as plain script text in a fresh
// context, with the host's type mapping. Usage: node scripts/test_wasm.mjs [dist/bigquery_web3.js]
import { existsSync, readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const script = readFileSync(process.argv[2] ?? "dist/bigquery_web3.js", "utf8");
const ctx = vm.createContext({  WebAssembly, unescape, escape, encodeURIComponent, decodeURIComponent, Uint8Array, DataView, Math, Number, String, BigInt });
vm.runInContext(script, ctx);
const call = (name, args, kinds, ret) => ctx.web3_call(name, args, kinds, ret);
call("web3_sha256", [new Uint8Array(0)], "b", "b"); // forces instantiation so exports can be listed
const hex = (u) => Buffer.from(u).toString("hex");
const b = (s) => new Uint8Array(Buffer.from(s));

// Independent reference: node:crypto for hashes, literal KATs elsewhere.
import { createHash } from "node:crypto";
const data = b("web3sql wasm harness");
assert.equal(hex(call("web3_sha256", [data], "b", "b")), createHash("sha256").update(data).digest("hex"));
assert.equal(hex(call("web3_keccak256", [b("")], "b", "b")), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
assert.equal(hex(call("web3_sha256", [Buffer.from(data).toString("base64")], "b", "b")), createHash("sha256").update(data).digest("hex"), "BigQuery BYTES arrive as base64 strings");
assert.equal(call("web3_base58_encode", [b("Hello World")], "b", "t"), "JxF12TrwUP45BMd");
assert.equal(call("web3_mul_div", ["5", "7", "2"], "ttt", "t"), "17");
assert.equal(call("web3_hex_decode", ["zz"], "t", "b"), null, "malformed input maps to NULL");
assert.equal(call("web3_keccak256", [null], "b", "b"), null, "NULL in, NULL out");
assert.equal(ctx.w3B64(new Uint8Array([1, 2, 3, 4])), "AQIDBA==");
assert.equal(hex(ctx.w3Unb64("AQIDBA==")), "01020304");
// Results that alias a long argument do not fit next to it in the scratch: NULL, never a trap.
const opReturn = (n) => new Uint8Array(Buffer.concat([Buffer.from([0x6a, 0x4e]), Buffer.from(Uint32Array.of(n).buffer), Buffer.alloc(n, 7)]));
if (ctx.__web3.web3_btc_op_return) { // absent from feature-filtered builds
  assert.equal(call("web3_btc_op_return", [opReturn(30000)], "b", "b").length, 30000);
  for (const n of [31000, 33000, 59000]) assert.equal(call("web3_btc_op_return", [opReturn(n)], "b", "b"), null, `OP_RETURN of ${n} bytes`);
}
if (ctx.__web3.web3_uni_sqrt_ratio_at_tick) {
  assert.notEqual(call("web3_uni_sqrt_ratio_at_tick", [0], "i", "t"), null);
  for (const x of [NaN, Infinity, 1.5, 2 ** 64]) assert.equal(call("web3_uni_sqrt_ratio_at_tick", [x], "i", "t"), null, `INT argument ${x}`);
}
// Differential: replay every call test_duckdb.py made, each of which DuckDB already matched
// against a reference library. Functions marked native_only are absent from the bundle.
const replay = process.argv[3] ?? "dist/duckdb_calls.json";
if (existsSync(replay)) {
  const kind = { BLOB: "b", VARCHAR: "t", BIGINT: "i", BOOLEAN: "o" };
  const exported = new Set(Object.keys(ctx.__web3 ?? {}));
  const seen = new Set();
  let calls = 0;
  for (const c of JSON.parse(readFileSync(replay, "utf8"))) {
    if (!exported.has(c.name)) continue;
    const args = c.args.map((a) => (a && a.hex !== undefined ? new Uint8Array(Buffer.from(a.hex, "hex")) : a));
    let got = call(c.name, args, c.types.map((t) => kind[t]).join(""), kind[c.ret]);
    if (got instanceof Uint8Array || (got && got.constructor?.name === "Uint8Array")) got = { hex: hex(got) };
    assert.deepEqual(JSON.parse(JSON.stringify(got)), c.result, `${c.name}(${JSON.stringify(c.args).slice(0, 200)})`);
    seen.add(c.name);
    calls++;
  }
  const missing = [...exported].filter((n) => n.startsWith("web3_") && !["web3_alloc", "web3_free", "web3_available"].includes(n) && !seen.has(n));
  assert.deepEqual(missing, [], "bundle functions never replayed");
  console.log(`replayed ${calls} DuckDB calls across ${seen.size} functions`);
}
console.log("wasm harness ok");
