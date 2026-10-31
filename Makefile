.PHONY: all test verify reference soak release build duckdb wasm docs bench data bq-deploy clean

# Builds on a Windows-mounted filesystem hang unless the cache lives elsewhere.
export ZIG_LOCAL_CACHE_DIR ?= $(HOME)/.cache/web3sql-zig/main

# An interpreter with scripts/requirements-dev.txt installed, for the targets that need one.
PYTHON ?= python
REFERENCE ?= $(HOME)/.cache/web3sql-zig/reference

all: build

build:
	zig build

test: duckdb wasm
	zig build test
	zig build test -Dchains=none -Dprotocols=none
	sh scripts/req_coverage.sh
	$(PYTHON) scripts/test_duckdb.py
	node scripts/test_wasm.mjs
	node scripts/test_snowflake.mjs

# Everything provable on one machine. docs/HANDOFF.md lists what is left.
verify: test reference
	zig fmt --check src bench tools build.zig
	if command -v actionlint >/dev/null; then actionlint .github/workflows/*.yml; else echo "actionlint not installed, workflows unchecked"; fi

reference: duckdb
	sh scripts/fetch_reference.sh $(REFERENCE)
	$(PYTHON) tools/reference/evm_diff.py zig-out/bin/web3.duckdb_extension 20000
	$(PYTHON) tools/reference/utxo_diff.py zig-out/bin/web3.duckdb_extension 100000
	$(PYTHON) tools/reference/math_diff.py $(REFERENCE) zig-out/bin/web3.duckdb_extension 100000
	$(PYTHON) tools/reference/schema_diff.py zig-out/bin/web3.duckdb_extension 5000
	$(PYTHON) tools/reference/idl_corpus.py $(REFERENCE)/idls zig-out/bin/web3.duckdb_extension
	REFERENCE=$(REFERENCE) $(PYTHON) tools/reference/live_diff.py zig-out/bin/web3.duckdb_extension
	REFERENCE=$(REFERENCE) $(PYTHON) scripts/test_recipes.py
	cd tools/reference/sdk && npm ci --ignore-scripts
	$(PYTHON) tools/reference/sdk_diff.py zig-out/bin/web3.duckdb_extension 20000
	$(PYTHON) tools/reference/wasm_diff.py zig-out/bin/web3.duckdb_extension 3 dist/mutated_calls.json
	node scripts/test_wasm.mjs dist/bigquery_web3.js dist/mutated_calls.json
	node scripts/test_snowflake.mjs dist/snowflake_udfs.sql dist/duckdb_calls.json dist/bigquery_udfs.sql dist/mutated_calls.json

soak: duckdb
	$(PYTHON) tools/reference/soak.py zig-out/bin/web3.duckdb_extension 1800

release:
	PYTHON=$(PYTHON) sh scripts/release.sh

duckdb:
	zig build duckdb

wasm:
	zig build wasm
	zig build wasm-size

docs:
	zig build docs

bench:
	zig build bench

data:
	python scripts/fetch_test_data.py

bq-deploy:
	python scripts/deploy_bq_test_data.py

clean:
	rm -rf zig-out .zig-cache dist release
