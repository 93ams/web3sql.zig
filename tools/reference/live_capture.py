#!/usr/bin/env python3
"""Captures a pinned sample of mainnet data from free public endpoints into tools/reference/live/.

live_diff.py replays the result offline, so `make verify` needs no network and cannot drift.
This is a sample to catch wrong assumptions, not a replacement for docs/HANDOFF.md H6.

Set LIVE_DIR and LIVE_SCALE for a bulk run outside the repository. Only rows that expose a bug belong
in the tracked sample, which stays small so `make verify` stays quick.

Usage: live_capture.py [evm evm_arbitrum evm_base ... svm token2022 bitcoin aptos sui cosmos]
"""
import base64
import gzip
import json
import os
import sys
import time
import urllib.request

from eth_utils import keccak

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("LIVE_DIR", os.path.join(HERE, "live"))
SCALE = int(os.environ.get("LIVE_SCALE", "1"))
HEADERS = {"content-type": "application/json", "user-agent": "web3sql-reference"}


def fetch(url, body=None, accept=None, raw=False):
    data = json.dumps(body).encode() if body is not None else None
    headers = dict(HEADERS, **({"accept": accept} if accept else {}))
    for attempt in range(6):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data, headers), timeout=60) as r:
                payload = r.read()
            time.sleep(0.15)
            return payload if raw else json.loads(payload)
        except Exception as e:
            if attempt == 5:
                raise
            print(f"  retry {url}: {e}", file=sys.stderr)
            time.sleep(2 * (attempt + 1))


def save(name, doc):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"{name}.json.gz")
    # mtime=0 keeps the file byte-stable for a given capture.
    with gzip.GzipFile(path, "wb", mtime=0) as f:
        f.write(json.dumps(doc, separators=(",", ":"), sort_keys=True).encode())
    print(f"{name}: {os.path.getsize(path) / 1024:.0f} KB")


def selector(sig):
    return keccak(text=sig)[:4].hex()


def topic(sig):
    return "0x" + keccak(text=sig).hex()


EVM_RPC = "https://ethereum-rpc.publicnode.com"
EVENTS = [
    "event Transfer(address indexed from, address indexed to, uint256 value)",
    "event Approval(address indexed owner, address indexed spender, uint256 value)",
    "event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)",
    "event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to)",
    "event Sync(uint112 reserve0, uint112 reserve1)",
    "event Deposit(address indexed dst, uint256 wad)",
    "event Withdrawal(address indexed src, uint256 wad)",
]
CALLS = [
    "function transfer(address to, uint256 amount)",
    "function approve(address spender, uint256 amount)",
    "function transferFrom(address from, address to, uint256 amount)",
    "function multicall(uint256 deadline, bytes[] data)",
    "function multicall(bytes[] data)",
    "function execute(bytes commands, bytes[] inputs, uint256 deadline)",
    "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)",
    "function swapExactETHForTokens(uint256 amountOutMin, address[] path, address to, uint256 deadline)",
    "function exactInputSingle((address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96) params)",
]
AAVE_POOL = "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2"
AAVE_ASSETS = [
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",  # USDC
    "0xdac17f958d2ee523a2206206994597c13d831ec7",  # USDT
    "0x6b175474e89094c44da98b954eedeac495271d0f",  # DAI
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",  # WETH
    "0x2260fac5e5542a773aa44fbcfedaf7c193c2c599",  # WBTC
    "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0",  # wstETH
]
UNI_POOLS = [
    "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640",
    "0x8ad599c3a0ff1de082011efddc58f1908eb6e6d8",
    "0xcbcdf9626bc03e24f779434178a73a0b4bad62ed",
    "0x4e68ccd3e89f51c3074ca5072bbac773960dfa36",
    "0x5777d92f208679db4b9778590fa3cab3ac9e2168",
]
CUSDC = "0x39aa39c021dfbae8fac545936693ac917d5e7563"


def rpc(method, *params, url=EVM_RPC):
    r = fetch(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)})
    if "error" in r:
        raise RuntimeError(f"{method}: {r['error']}")
    return r["result"]


# Harder shapes for the L2 and bulk samples: arrays, nested tuples and bytes.
BROAD_EVENTS = EVENTS + [
    "event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)",
    "event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)",
    "event Mint(address sender, address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)",
    "event Burn(address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)",
    "event Supply(address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint16 indexed referralCode)",
    "event UserOperationEvent(bytes32 indexed userOpHash, address indexed sender, address indexed paymaster, uint256 nonce, bool success, uint256 actualGasCost, uint256 actualGasUsed)",
]
BROAD_CALLS = CALLS + [
    "function aggregate3((address target, bool allowFailure, bytes callData)[] calls)",
    "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, uint256 callGasLimit, uint256 verificationGasLimit, uint256 preVerificationGas, uint256 maxFeePerGas, uint256 maxPriorityFeePerGas, bytes paymasterAndData, bytes signature)[] ops, address beneficiary)",
    "function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes data)",
    "function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures)",
]
EVM_CHAINS = {
    "evm_arbitrum": "https://arbitrum-one-rpc.publicnode.com",
    "evm_base": "https://base-rpc.publicnode.com",
    "evm_optimism": "https://optimism-rpc.publicnode.com",
    "evm_polygon": "https://polygon-bor-rpc.publicnode.com",
    "evm_bsc": "https://bsc-rpc.publicnode.com",
    "evm_ethereum": EVM_RPC,
}


def capture_chain(name, url, blocks=8, cap=120, head=None):
    """Decodable logs and calls from blocks of any EVM chain, spread out rather than adjacent."""
    head = head or int(rpc("eth_blockNumber", url=url), 16) - 128
    blocks, cap = blocks * SCALE, cap * SCALE
    wanted = {topic(canonical(e)): e for e in BROAD_EVENTS}
    selectors = {selector(canonical(c)): c for c in BROAD_CALLS}
    logs, calls, per = [], [], {}
    for number in range(head - blocks * 37, head, 37):
        block = rpc("eth_getBlockByNumber", hex(number), True, url=url)
        for r in rpc("eth_getBlockReceipts", hex(number), url=url):
            for log in r["logs"]:
                sig = wanted.get(log["topics"][0]) if log["topics"] else None
                if sig and per.get(sig, 0) < cap:
                    per[sig] = per.get(sig, 0) + 1
                    logs.append({"sig": sig, "topics": log["topics"], "data": log["data"]})
        for tx in block["transactions"]:
            sig = selectors.get(tx["input"][2:10])
            if sig and per.get(sig, 0) < cap:
                per[sig] = per.get(sig, 0) + 1
                calls.append({"sig": sig, "input": tx["input"]})
    print(f"{name}: from block {head - blocks * 37}, {len(logs)} logs, {len(calls)} calls")
    save(name, {"logs": logs, "calls": calls})


def capture_evm():
    head = int(rpc("eth_blockNumber"), 16) - 64
    logs, calls, creates = [], [], []
    wanted = {topic(canonical(e)): e for e in EVENTS}
    selectors = {selector(canonical(c)): c for c in CALLS}
    per = {}
    for number in range(head - 40, head):
        block = rpc("eth_getBlockByNumber", hex(number), True)
        receipts = rpc("eth_getBlockReceipts", hex(number))
        for r in receipts:
            for log in r["logs"]:
                sig = wanted.get(log["topics"][0]) if log["topics"] else None
                if sig and per.get(sig, 0) < 2500:
                    per[sig] = per.get(sig, 0) + 1
                    logs.append({"sig": sig, "topics": log["topics"], "data": log["data"]})
            if r["contractAddress"]:
                tx = next(t for t in block["transactions"] if t["hash"] == r["transactionHash"])
                creates.append({"from": tx["from"], "nonce": int(tx["nonce"], 16), "address": r["contractAddress"]})
        for tx in block["transactions"]:
            sig = selectors.get(tx["input"][2:10])
            if sig and per.get(sig, 0) < 500:
                per[sig] = per.get(sig, 0) + 1
                calls.append({"sig": sig, "input": tx["input"]})
    block = head
    timestamp = int(rpc("eth_getBlockByNumber", hex(block), False)["timestamp"], 16)

    def call(to, sig, *words):
        data = "0x" + selector(sig) + "".join(w[2:].rjust(64, "0") for w in words)
        return rpc("eth_call", {"to": to, "data": data}, hex(block))

    aave = [{
        "asset": a,
        "reserve": call(AAVE_POOL, "getReserveData(address)", a),
        "income": call(AAVE_POOL, "getReserveNormalizedIncome(address)", a),
        "debt": call(AAVE_POOL, "getReserveNormalizedVariableDebt(address)", a),
    } for a in AAVE_ASSETS]
    uni = [{"pool": p, "slot0": call(p, "slot0()")} for p in UNI_POOLS]
    compound = {k: call(CUSDC, k + "()") for k in ("getCash", "totalBorrows", "totalReserves", "totalSupply", "exchangeRateStored")}
    print(f"evm: block {block}, {len(logs)} logs, {len(calls)} calls, {len(creates)} creates")
    save("evm", {"block": block, "timestamp": timestamp, "logs": logs, "calls": calls, "creates": creates, "aave": aave, "uni": uni, "compound": compound})


def canonical(sig):
    """`event Foo(address indexed a, (uint8 b) c)` -> `Foo(address,(uint8))`."""
    name, rest = sig.split(" ", 1)[1].split("(", 1)
    out, word, depth = [], "", 0
    types = []
    for ch in rest[:-1]:
        if ch in "(":
            depth += 1
        if ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            types.append(word)
            word = ""
        else:
            word += ch
    if word:
        types.append(word)

    def strip(t):
        t = t.strip()
        if t.startswith("("):
            inner = t[1 : t.rindex(")")]
            parts, cur, d = [], "", 0
            for c in inner:
                d += c == "("
                d -= c == ")"
                if c == "," and d == 0:
                    parts.append(cur)
                    cur = ""
                else:
                    cur += c
            parts.append(cur)
            return "(" + ",".join(strip(p) for p in parts) + ")" + t[t.rindex(")") + 1 :].split(" ")[0]
        return t.split(" ")[0]

    return f"{name}({','.join(strip(t) for t in types)})"


SOL_RPC = "https://api.mainnet-beta.solana.com"
SPL_TOKEN = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
SOL_PROGRAMS = {
    "drift": "dRiftyHA39MWEi3m9aunc5MzRF1JYuBsbn6VPcn33UH",
    "pump": "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P",
    "meteora_dlmm": "LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo",
    "kamino": "KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD",
    "squads": "SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf",
    "mango": "4MangoMjqJ2firMokCjjGgoK8d4MXcrgL7XJaL3w6fVg",
    "token_metadata": "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s",
}
WHIRLPOOL = "whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc"
RAYDIUM_CLMM = "CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK"


def sol(method, *params):
    time.sleep(3)  # the free endpoint rate-limits hard
    r = fetch(SOL_RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)})
    if "error" in r:
        raise RuntimeError(f"{method}: {r['error']}")
    return r["result"]


def capture_svm():
    slot = sol("getSlot", {"commitment": "finalized"}) - 32
    spl, instructions, events, seen_accounts, pdas = [], {}, {}, {}, []
    taken = 0
    opts = {"maxSupportedTransactionVersion": 1, "rewards": False, "transactionDetails": "full"}
    for _ in range(40):
        if taken == 3:
            break
        slot -= 7
        try:
            raw = sol("getBlock", slot, dict(opts, encoding="json"))
            parsed = sol("getBlock", slot, dict(opts, encoding="jsonParsed"))
        except RuntimeError as e:
            if "skipped" not in str(e).lower() and "not available" not in str(e).lower():
                raise
            continue
        taken += 1
        for tx, ptx in zip(raw["transactions"], parsed["transactions"]):
            if tx["meta"]["err"]:
                continue
            msg = tx["transaction"]["message"]
            keys = msg["accountKeys"] + tx["meta"].get("loadedAddresses", {}).get("writable", []) + tx["meta"].get("loadedAddresses", {}).get("readonly", [])
            outer = list(zip(msg["instructions"], ptx["transaction"]["message"]["instructions"]))
            for a, b in zip(tx["meta"].get("innerInstructions", []), ptx["meta"].get("innerInstructions", [])):
                outer += list(zip(a["instructions"], b["instructions"]))
            for ins, pins in outer:
                program = keys[ins["programIdIndex"]]
                if program == SPL_TOKEN and "parsed" in pins and len(spl) < 4000:
                    spl.append({"data": ins["data"], "parsed": pins["parsed"]})
                for name, pid in SOL_PROGRAMS.items():
                    if program == pid and len(instructions.setdefault(name, [])) < 1500:
                        instructions[name].append(ins["data"])
                if program in (WHIRLPOOL, RAYDIUM_CLMM) or program in SOL_PROGRAMS.values():
                    for i in ins["accounts"][:12]:
                        seen_accounts[keys[i]] = program
            for line in tx["meta"].get("logMessages") or []:
                if line.startswith("Program data: ") and len(events.setdefault("all", [])) < 3000:
                    events["all"].append(line[len("Program data: ") :])
    # Busy programs dominate a block, so also ask for the quieter ones by name.
    for name, pid in list(SOL_PROGRAMS.items()) + [("whirlpool", WHIRLPOOL)]:
        for sig in sol("getSignaturesForAddress", pid, {"limit": 12}):
            if sig["err"]:
                continue
            tx = sol("getTransaction", sig["signature"], {"encoding": "json", "maxSupportedTransactionVersion": 1})
            if not tx:
                continue
            msg = tx["transaction"]["message"]
            loaded = tx["meta"].get("loadedAddresses", {})
            keys = msg["accountKeys"] + loaded.get("writable", []) + loaded.get("readonly", [])
            inner = [i for group in tx["meta"].get("innerInstructions", []) for i in group["instructions"]]
            for ins in msg["instructions"] + inner:
                if keys[ins["programIdIndex"]] == pid:
                    instructions.setdefault(name, []).append(ins["data"])
                    for i in ins["accounts"][:12]:
                        seen_accounts[keys[i]] = pid
            for line in tx["meta"].get("logMessages") or []:
                if line.startswith("Program data: "):
                    events.setdefault("all", []).append(line[len("Program data: ") :])
    addresses = list(seen_accounts)[:2400]
    accounts = []
    for i in range(0, len(addresses), 100):
        batch = addresses[i : i + 100]
        for key, info in zip(batch, sol("getMultipleAccounts", batch, {"encoding": "base64"})["value"]):
            if not info or len(base64.b64decode(info["data"][0])) > 12288:
                continue
            if info["owner"] in SOL_PROGRAMS.values() or info["owner"] in (WHIRLPOOL, RAYDIUM_CLMM):
                accounts.append({"key": key, "owner": info["owner"], "data": info["data"][0]})
    # Metadata accounts of well-known mints, and their PDAs, which the chain itself confirms.
    mints = ["EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", "So11111111111111111111111111111111111111112", "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN", "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263"]
    print(f"svm: {len(spl)} spl, {sum(map(len, instructions.values()))} instructions, {len(events.get('all', []))} events, {len(accounts)} accounts")
    save("svm", {"slot": slot, "spl": spl, "instructions": instructions, "events": events.get("all", []), "accounts": accounts, "mints": mints})


TOKEN_2022 = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"


def capture_token2022():
    slot = sol("getSlot", {"commitment": "finalized"}) - 900
    rows, taken = {}, 0
    opts = {"maxSupportedTransactionVersion": 1, "rewards": False, "transactionDetails": "full"}
    for _ in range(40):
        if taken == 8:
            break
        slot -= 11
        try:
            raw = sol("getBlock", slot, dict(opts, encoding="json"))
            parsed = sol("getBlock", slot, dict(opts, encoding="jsonParsed"))
        except RuntimeError as e:
            if "skipped" not in str(e).lower() and "not available" not in str(e).lower():
                raise
            continue
        taken += 1
        for tx, ptx in zip(raw["transactions"], parsed["transactions"]):
            if tx["meta"]["err"]:
                continue
            msg = tx["transaction"]["message"]
            loaded = tx["meta"].get("loadedAddresses", {})
            keys = msg["accountKeys"] + loaded.get("writable", []) + loaded.get("readonly", [])
            pairs = list(zip(msg["instructions"], ptx["transaction"]["message"]["instructions"]))
            for x, y in zip(tx["meta"].get("innerInstructions", []), ptx["meta"].get("innerInstructions", [])):
                pairs += list(zip(x["instructions"], y["instructions"]))
            for ins, pins in pairs:
                if keys[ins["programIdIndex"]] != TOKEN_2022 or "parsed" not in pins:
                    continue
                kind = pins["parsed"]["type"] if isinstance(pins["parsed"], dict) else "unparsed"
                group = rows.setdefault(kind, [])
                if len(group) < 200:  # a sample of each kind, not thousands of transfers
                    group.append({"data": ins["data"], "parsed": pins["parsed"]})
    print("token2022:", {k: len(v) for k, v in rows.items()})
    save("token2022", {"slot": slot, "rows": [r for group in rows.values() for r in group]})


BTC = "https://mempool.space/api"


def capture_bitcoin():
    tip = int(fetch(f"{BTC}/blocks/tip/height")) - 6
    # Recent blocks, the 2023 inscription peak, and the Runes launch block.
    heights = [(tip, 8 * SCALE), (tip - 1000, 4 * SCALE), (780000, 8 * SCALE), (800000, 4 * SCALE), (840000, 8 * SCALE), (850000, 4 * SCALE)]
    outs, tapscripts, opret = {}, [], []
    for height, pages in heights:
        block = fetch(f"{BTC}/block-height/{height}", raw=True).decode()
        for page in range(pages):
            for tx in fetch(f"{BTC}/block/{block}/txs/{page * 25}"):
                for out in tx["vout"]:
                    spk = out["scriptpubkey"]
                    if spk not in outs:
                        outs[spk] = {"script": spk, "type": out["scriptpubkey_type"], "address": out.get("scriptpubkey_address")}
                    if spk.startswith("6a") and len(opret) < 3000 * SCALE:
                        opret.append(spk)
                for vin in tx["vin"]:
                    w = vin.get("witness") or []
                    if (vin.get("prevout") or {}).get("scriptpubkey_type") == "v1_p2tr" and len(w) >= 2 and "0063036f7264" in "".join(w[-3:]):
                        script = w[-3] if w[-1].startswith("50") and len(w) >= 3 else w[-2]
                        if len(script) < 8000:
                            tapscripts.append(script)
    print(f"bitcoin: {len(outs)} scripts, {len(opret)} OP_RETURN, {len(tapscripts)} tapscripts")
    save("bitcoin", {"heights": [h for h, _ in heights], "outputs": list(outs.values()), "op_returns": opret, "tapscripts": tapscripts})


APTOS = "https://fullnode.mainnet.aptoslabs.com/v1"
APTOS_RESOURCES = [
    ("0x1::coin::CoinInfo<0x1::aptos_coin::AptosCoin>", "{name:string,symbol:string,decimals:u8,supply:option<{aggregator:option<{handle:address,key:address,limit:u128}>,integer:option<{value:u128,limit:u128}>}>}"),
    ("0x1::timestamp::CurrentTimeMicroseconds", "{microseconds:u64}"),
    ("0x1::chain_id::ChainId", "{id:u8}"),
    ("0x1::version::Version", "{major:u64}"),
    ("0x1::staking_config::StakingConfig", "{minimum_stake:u64,maximum_stake:u64,recurring_lockup_duration_secs:u64,allow_validator_set_change:bool,rewards_rate:u64,rewards_rate_denominator:u64,voting_power_increase_limit:u64}"),
    ("0x1::reconfiguration::Configuration", "{epoch:u64,last_reconfiguration_time:u64,events:{counter:u64,guid:{id:{creation_num:u64,addr:address}}}}"),
]


def capture_aptos():
    ledger = int(fetch(APTOS)["ledger_version"]) - 1000
    resources = []
    for tag, schema in APTOS_RESOURCES:
        url = f"{APTOS}/accounts/0x1/resource/{tag}?ledger_version={ledger}"
        resources.append({
            "tag": tag,
            "schema": schema,
            "json": fetch(url)["data"],
            "bcs": fetch(url, accept="application/x-bcs", raw=True).hex(),
        })
    print(f"aptos: ledger {ledger}, {len(resources)} resources")
    save("aptos", {"ledger": ledger, "resources": resources})


SUI = "https://graphql.mainnet.sui.io/graphql"
CETUS_POOL_TYPE = "0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb::pool::Pool"


def sui(query):
    r = fetch(SUI, {"query": query})
    if r.get("errors"):
        raise RuntimeError(r["errors"])
    return r["data"]


def capture_sui():
    objects = """contents { type { repr } json bcs }"""
    coins = sui("{ objects(filter: { type: \"0x2::coin::Coin<0x2::sui::SUI>\" }, first: 40) { nodes { asMoveObject { %s } } } }" % objects)
    pools = sui("{ objects(filter: { type: \"%s\" }, first: 40) { nodes { asMoveObject { %s } } } }" % (CETUS_POOL_TYPE, objects))
    def nodes(d):
        return [n["asMoveObject"]["contents"] for n in d["objects"]["nodes"] if n["asMoveObject"]]
    coin_rows = [{"type": c["type"]["repr"], "json": c["json"], "bcs": c["bcs"]} for c in nodes(coins)]
    pool_rows = [{"sqrt_price": p["json"]["current_sqrt_price"], "tick": p["json"]["current_tick_index"]} for p in nodes(pools)]
    print(f"sui: {len(coin_rows)} coins, {len(pool_rows)} Cetus pools")
    save("sui", {"coins": coin_rows, "cetus_pools": pool_rows})


COSMOS = "https://rest.cosmos.directory/osmosis"


def capture_cosmos():
    traces = fetch(f"{COSMOS}/ibc/apps/transfer/v1/denom_traces?pagination.limit=120")["denom_traces"]
    denoms = []
    for t in traces:
        full = f"{t['path']}/{t['base_denom']}"
        try:  # the node computes this hash itself
            denoms.append({"trace": full, "hash": fetch(f"{COSMOS}/ibc/apps/transfer/v1/denom_hashes/{full}")["hash"]})
        except Exception as e:
            print(f"  skipped {full}: {e}", file=sys.stderr)
    validators = fetch("https://rest.cosmos.directory/cosmoshub/cosmos/staking/v1beta1/validators?pagination.limit=100")["validators"]
    print(f"cosmos: {len(denoms)} denoms, {len(validators)} validators")
    save("cosmos", {"denoms": denoms, "valopers": [v["operator_address"] for v in validators]})


# Older contracts are likelier to bend the standards.
EVM_HISTORY = {"evm_2018": 6_000_000, "evm_2021": 12_500_000, "evm_2023": 17_000_000}
CAPTURES = {**{n: (lambda n=n, h=h: capture_chain(n, "https://eth.drpc.org", head=h)) for n, h in EVM_HISTORY.items()},
            **{n: (lambda n=n, u=u: capture_chain(n, u)) for n, u in EVM_CHAINS.items()}, "evm": capture_evm, "svm": capture_svm, "token2022": capture_token2022, "bitcoin": capture_bitcoin, "aptos": capture_aptos, "sui": capture_sui, "cosmos": capture_cosmos}

if __name__ == "__main__":
    failed = []
    for name in sys.argv[1:] or CAPTURES:
        try:
            CAPTURES[name]()
        except Exception as e:
            print(f"{name}: FAILED {e!r}", file=sys.stderr)
            failed.append(name)
    sys.exit(1 if failed else 0)
