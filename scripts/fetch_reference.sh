#!/bin/sh
# Downloads upstream sources and public IDLs as data for tools/reference. Nothing here is executed.
set -eu
dir=$1
mkdir -p "$dir/idls"
raw=https://raw.githubusercontent.com
get() {
  [ -s "$dir/$1" ] || curl -sSfL --max-time 60 -o "$dir/$1" "$2"
}
get TickMath.sol $raw/Uniswap/v3-core/main/contracts/libraries/TickMath.sol
get orca_tick_math.rs $raw/orca-so/whirlpools/main/programs/whirlpool/src/math/tick_math.rs
get raydium_tick_math.rs $raw/raydium-io/raydium-clmm/master/programs/amm/src/libraries/tick_math.rs
get idls/drift.json $raw/drift-labs/protocol-v2/master/sdk/src/idl/drift.json
get idls/kamino.json $raw/Kamino-Finance/klend-sdk/master/src/idl/klend.json
get idls/mango.json $raw/blockworks-foundation/mango-v4/dev/mango_v4.json
get idls/meteora_dlmm.json $raw/MeteoraAg/dlmm-sdk/main/ts-client/src/dlmm/idl/idl.json
get idls/pump.json $raw/pump-fun/pump-public-docs/main/idl/pump.json
get idls/squads.json $raw/Squads-Protocol/v4/main/sdk/multisig/idl/squads_multisig_program.json
get idls/token_metadata.json $raw/metaplex-foundation/mpl-token-metadata/main/idls/token_metadata.json
get idls/whirlpool.json https://unpkg.com/@orca-so/whirlpools-sdk@0.22.0/dist/artifacts/whirlpool.json
