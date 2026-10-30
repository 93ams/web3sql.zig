# dbt-duckdb example

Decodes raw Bitcoin outputs into typed addresses with `web3sql`.

```sh
uv pip install dbt-duckdb
zig build duckdb
cd examples/dbt-duckdb
dbt run --profiles-dir .
```

`profiles.yml` loads the extension from `../../zig-out/bin`, and the model reads the sample Parquet file in `test_data/`.
