-- web3sql BigQuery UDFs. Generated from the function catalogue; do not edit.
-- Upload bigquery_web3.js to GCS, then replace __WEB3_DATASET__ and __WEB3_GCS_URI__.
-- Inline wasm is impossible here: BigQuery limits inline code blobs to 32 KB.
CREATE OR REPLACE FUNCTION `__WEB3_DATASET__`.web3_demo(a0 BYTES, a1 STRING, a2 FLOAT64) RETURNS BYTES LANGUAGE js OPTIONS (library=["__WEB3_GCS_URI__"], description="Demo") AS r"""var r=web3_call("web3_demo",[a0,a1,a2],"bti","b");return r===null?null:w3B64(r);""";
CREATE OR REPLACE FUNCTION `__WEB3_DATASET__`.web3_flag(a0 STRING) RETURNS BOOL LANGUAGE js OPTIONS (library=["__WEB3_GCS_URI__"], description="Flag") AS r"""return web3_call("web3_flag",[a0],"t","o");""";
