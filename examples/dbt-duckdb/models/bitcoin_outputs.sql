select
    block_height,
    txid,
    web3_btc_script_type(web3_hex_decode(vout_script_pub_key)) as script_type,
    web3_btc_address('bitcoin', web3_hex_decode(vout_script_pub_key)) as address
from read_parquet('../../test_data/bitcoin_txs.parquet')
