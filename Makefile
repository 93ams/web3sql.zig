.PHONY: all test build duckdb wasm docs bench data bq-deploy clean

# Builds on a Windows-mounted filesystem hang unless the cache lives elsewhere.
export ZIG_LOCAL_CACHE_DIR ?= $(HOME)/.cache/web3sql-zig/main

all: build

build:
	zig build

test: duckdb wasm
	zig build test
	zig build test -Dchains=none -Dprotocols=none
	sh scripts/req_coverage.sh
	python scripts/test_duckdb.py
	node scripts/test_wasm.mjs

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
	rm -rf zig-out .zig-cache dist
