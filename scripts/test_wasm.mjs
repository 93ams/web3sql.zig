// Runs the generated BigQuery library exactly as a warehouse would: as plain script text in a fresh
// context, with the host's type mapping. Usage: node scripts/test_wasm.mjs [dist/bigquery_web3.js]
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const script = readFileSync(process.argv[2] ?? "dist/bigquery_web3.js", "utf8");
const ctx = vm.createContext({ WebAssembly, unescape, escape, encodeURIComponent, decodeURIComponent, Uint8Array, DataView, Math, Number, String, BigInt });
vm.runInContext(script, ctx);
const call = (name, args, kinds, ret) => ctx.web3_call(name, args, kinds, ret);
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
console.log("wasm harness ok");
