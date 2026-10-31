// Dress rehearsal for dist/snowflake_udfs.sql and the inline functions of dist/bigquery_udfs.sql: each
// generated CREATE is split the way the warehouse would split it, and its body runs as a function of
// its arguments in a stripped context, with no help from any other function's module.
// Also prints the cold start, per-row latency and memory a warehouse would see.
// Usage: node scripts/test_snowflake.mjs [dist/snowflake_udfs.sql] [dist/duckdb_calls.json] [dist/bigquery_udfs.sql] [dist/mutated_calls.json]
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const sql = readFileSync(process.argv[2] ?? "dist/snowflake_udfs.sql", "utf8");
const calls = JSON.parse(readFileSync(process.argv[3] ?? "dist/duckdb_calls.json", "utf8"));
const bigquery = readFileSync(process.argv[4] ?? "dist/bigquery_udfs.sql", "utf8");
if (process.argv[5]) calls.push(...JSON.parse(readFileSync(process.argv[5], "utf8")));
// Snowflake recommends under 100 KB, and the real limit depends on how well the code compresses.
const SNOWFLAKE_BODY_MAX = 100_000, BIGQUERY_INLINE_MAX = 32_000;
const CREATE = /^CREATE OR REPLACE FUNCTION (\w+)\(([^)]*)\) RETURNS (\w+) LANGUAGE JAVASCRIPT RETURNS NULL ON NULL INPUT AS \$\$\n([\s\S]*?)\n\$\$;$/gm;
const sandbox = () => vm.createContext({ WebAssembly, unescape, escape, encodeURIComponent, decodeURIComponent, Uint8Array, DataView, Math, Number, String });
const hex = (u) => Buffer.from(u).toString("hex");
const fromHost = (a) => (a && a.hex !== undefined ? new Uint8Array(Buffer.from(a.hex, "hex")) : a);

const bodies = new Map();
for (const m of sql.matchAll(CREATE)) {
  const params = m[2] ? m[2].split(", ").map((p) => p.split(" ")[0]) : [];
  assert.ok(!m[4].includes("$$"), `${m[1]}: $$ inside a body ends it early`);
  assert.ok(params.every((p) => p === p.toUpperCase()), `${m[1]}: Snowflake exposes arguments in upper case`);
  bodies.set(m[1], { script: new vm.Script(`(function(${params.join(",")}){${m[4]}\n})`), size: m[4].length });
}
assert.equal(bodies.size, (sql.match(/^CREATE OR REPLACE FUNCTION/gm) ?? []).length, "a CREATE did not parse");

const run = (name, args) => bodies.get(name).script.runInContext(sandbox())(...args);

const check = (name, f, c) => {
  let got = f(...c.args.map(fromHost));
  if (got && got.constructor?.name === "Uint8Array") got = { hex: hex(got) };
  assert.deepEqual(JSON.parse(JSON.stringify(got ?? null)), c.result, `${name}(${JSON.stringify(c.args).slice(0, 200)})`);
};

// Warm functions replay everything, since each one now has a module of its own to get wrong.
const seen = new Set(), warmed = new Map();
let replayed = 0;
for (const c of calls) {
  if (!bodies.has(c.name) || c.args.some((a) => a === null)) continue; // RETURNS NULL ON NULL INPUT
  if (!seen.has(c.name)) check(c.name, (...a) => run(c.name, a), c); // first call: fresh context
  seen.add(c.name);
  if (!warmed.has(c.name)) warmed.set(c.name, bodies.get(c.name).script.runInContext(sandbox()));
  check(c.name, warmed.get(c.name), c);
  replayed++;
}
assert.deepEqual([...bodies.keys()].filter((n) => !seen.has(n)), [], "bodies never run");
console.log(`${replayed} calls across ${seen.size} Snowflake bodies matched DuckDB`);

const biggest = [...bodies.entries()].sort((a, b) => b[1].size - a[1].size)[0];
assert.ok(biggest[1].size < SNOWFLAKE_BODY_MAX, `${biggest[0]} body is ${biggest[1].size} bytes`);

const noWasm = sandbox();
vm.runInContext("delete globalThis.WebAssembly", noWasm);
assert.throws(() => bodies.get("web3_keccak256").script.runInContext(noWasm)(new Uint8Array(32)), /no WebAssembly/);

// BigQuery delivers BYTES as base64 and takes them back the same way.
const BIGQUERY = /^CREATE OR REPLACE FUNCTION `__WEB3_DATASET__`\.(\w+)\(([^)]*)\) RETURNS (\w+) LANGUAGE js OPTIONS \((library=[^,]+, )?description="[^"]*"\) AS r"""([\s\S]*?)""";$/gm;
const inlined = new Map();
let library = 0, total = 0;
for (const m of bigquery.matchAll(BIGQUERY)) {
  total++;
  if (m[4]) { library++; continue; }
  assert.ok(m[5].length <= BIGQUERY_INLINE_MAX, `${m[1]} inline body is ${m[5].length} bytes`);
  const params = m[2] ? m[2].split(", ").map((p) => p.split(" ")[0]) : [];
  inlined.set(m[1], new vm.Script(`(function(${params.join(",")}){${m[5]}\n})`).runInContext(sandbox()));
}
assert.equal(total, (bigquery.match(/^CREATE OR REPLACE FUNCTION/gm) ?? []).length, "a BigQuery CREATE did not parse");
const toBigQuery = (a) => (a instanceof Uint8Array ? Buffer.from(a).toString("base64") : a);
let bigqueryCalls = 0;
for (const c of calls) {
  if (!inlined.has(c.name)) continue;
  let got = inlined.get(c.name)(...c.args.map((a) => toBigQuery(fromHost(a))));
  if (c.ret === "BLOB" && got !== null) got = { hex: Buffer.from(got, "base64").toString("hex") };
  assert.deepEqual(JSON.parse(JSON.stringify(got ?? null)), c.result, `BigQuery ${c.name}(${JSON.stringify(c.args).slice(0, 200)})`);
  bigqueryCalls++;
}
console.log(`${bigqueryCalls} calls across ${inlined.size} inline BigQuery functions matched DuckDB; ${library} of ${total} need the GCS library`);

const ms = (f, n = 1) => { const t = performance.now(); for (let i = 0; i < n; i++) f(); return (performance.now() - t) / n; };
const key = new Uint8Array(32);
const cold = [...Array(20)].map(() => ms(() => run("web3_keccak256", [key]))).sort((a, b) => a - b);
const f = bodies.get("web3_keccak256").script.runInContext(sandbox());
const warm = ms(() => f(key), 20000);
const size = [...bodies.values()].reduce((n, b) => n + b.size, 0);
console.log(`biggest body ${(biggest[1].size / 1024).toFixed(0)} KB (${biggest[0]}), ${bodies.size} bodies ${(size / 1048576).toFixed(1)} MB`);
console.log(`cold start median ${cold[10].toFixed(1)} ms, worst ${cold[19].toFixed(1)} ms; warm row ${(warm * 1000).toFixed(2)} us`);
console.log(`node rss ${(process.memoryUsage().rss / 1048576).toFixed(0)} MB`);
