// Cases encoded by the real SDKs, for sdk_diff.py to decode. Usage: node gen.mjs <out.json> [cases] [seed]
import { writeFileSync } from "node:fs";
import { bcs } from "@mysten/bcs";
import { fromBech32, toBech32 } from "@cosmjs/encoding";
import { sha256 } from "@cosmjs/crypto";

const cases = Number(process.argv[3] ?? 20000);
let state = BigInt(process.argv[4] ?? 1);
const next = () => (state = (state * 6364136223846793005n + 1442695040888963407n) & (2n ** 64n - 1n));
const int = (n) => Number((next() >> 33n) % BigInt(n));
const pick = (xs) => xs[int(xs.length)];
const big = (bits) => {
  let v = 0n;
  for (let i = 0; i < bits; i += 32) v = (v << 32n) | (next() >> 32n);
  return pick([0n, 1n, 255n, 2n ** 53n + 1n, 2n ** BigInt(bits) - 1n, v]) & (2n ** BigInt(bits) - 1n);
};
const bytes = (n) => Uint8Array.from({ length: n }, () => int(256));
const hex = (b) => "0x" + Buffer.from(b).toString("hex");
const text = ["", "a", "héllo", 'q"uo\\te', "new\nline", "😀😀"];

// Each generator returns { schema, type, sample() -> [value for the SDK, expected JSON] }.
const uint = (bits) => ({
  schema: `u${bits}`,
  type: bcs[`u${bits}`](),
  sample() { const v = big(bits); return [bits > 32 ? v : Number(v), String(v)]; },
});
const prims = [
  ...[8, 16, 32, 64, 128, 256].map(uint),
  { schema: "bool", type: bcs.bool(), sample() { const v = int(2) === 1; return [v, v]; } },
  { schema: "string", type: bcs.string(), sample() { const v = pick(text); return [v, v]; } },
  { schema: "address", type: bcs.bytes(32), sample() { const v = bytes(32); return [v, hex(v)]; } },
];
const list = (depth) => Array.from({ length: 1 + int(3) }, () => gen(depth + 1));
function gen(depth = 0) {
  const roll = int(100);
  if (depth < 3 && roll < 18) {
    const t = gen(depth + 1);
    return {
      schema: `vector<${t.schema}>`,
      type: bcs.vector(t.type),
      sample() {
        const items = Array.from({ length: int(4) }, () => t.sample());
        const want = t.schema === "u8" ? "0x" + items.map((i) => (+i[1]).toString(16).padStart(2, "0")).join("") : items.map((i) => i[1]);
        return [items.map((i) => i[0]), want];
      },
    };
  }
  if (depth < 3 && roll < 30) {
    const t = gen(depth + 1);
    return { schema: `option<${t.schema}>`, type: bcs.option(t.type), sample: () => (int(2) ? [null, null] : t.sample()) };
  }
  if (depth < 3 && roll < 42) {
    const ts = list(depth);
    return {
      schema: `enum<${ts.map((t) => t.schema).join("|")}>`,
      type: bcs.enum("E", Object.fromEntries(ts.map((t, i) => [`v${i}`, t.type]))),
      sample() { const i = int(ts.length); const [v, want] = ts[i].sample(); return [{ [`v${i}`]: v }, { variant: i, value: want }]; },
    };
  }
  if (depth < 3 && roll < 52) {
    const ts = list(depth);
    return {
      schema: `(${ts.map((t) => t.schema).join(",")})`,
      type: bcs.tuple(ts.map((t) => t.type)),
      sample() { const s = ts.map((t) => t.sample()); return [s.map((x) => x[0]), s.map((x) => x[1])]; },
    };
  }
  if (depth < 3 && roll < 64) {
    const ts = list(depth);
    return {
      schema: `{${ts.map((t, i) => `f${i}:${t.schema}`).join(",")}}`,
      type: bcs.struct("S", Object.fromEntries(ts.map((t, i) => [`f${i}`, t.type]))),
      sample() {
        const s = ts.map((t) => t.sample());
        return [Object.fromEntries(s.map((x, i) => [`f${i}`, x[0]])), Object.fromEntries(s.map((x, i) => [`f${i}`, x[1]]))];
      },
    };
  }
  return pick(prims);
}

const out = { bcs: [], bech32: [], ibc: [] };
for (let i = 0; i < cases; i++) {
  const t = gen();
  const [value, want] = t.sample();
  out.bcs.push({ schema: t.schema, hex: Buffer.from(t.type.serialize(value).toBytes()).toString("hex"), want });
}
// The explicit limit matters: the default of Infinity makes @scure/base throw on every address.
const valid = (a) => { try { fromBech32(a, 1023); return true; } catch { return false; } };
const alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
for (let i = 0; i < cases; i++) {
  const prefix = pick(["cosmos", "osmo", "cosmosvaloper", "juno", "a"]);
  const to = pick(["cosmos", "osmo", "stars", "celestia"]);
  const data = bytes(pick([20, 32]));
  const address = toBech32(prefix, data);
  const at = prefix.length + 1 + int(address.length - prefix.length - 1);
  const typo = address.slice(0, at) + pick([...alphabet]) + address.slice(at + 1);
  out.bech32.push({ address, to, converted: toBech32(to, data), typo, typo_valid: valid(typo) });
}
for (let i = 0; i < 2000; i++) {
  const trace = `transfer/channel-${int(5000)}/${pick(["uatom", "uosmo", "gamm/pool/1", "cw20:juno1abc", "transfer/channel-7/uusdc"])}`;
  out.ibc.push({ trace, denom: "ibc/" + Buffer.from(sha256(new TextEncoder().encode(trace))).toString("hex").toUpperCase() });
}
writeFileSync(process.argv[2], JSON.stringify(out));
