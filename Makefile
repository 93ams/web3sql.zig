.PHONY: all test build run duckdb wasm package data bq-deploy clean

all: build

build:
	zig build

test:
	zig build test
	python scripts/test_duckdb.py

run:
	zig build run

duckdb:
	zig build duckdb
	python scripts/package_duckdb.py
	python scripts/test_duckdb.py

wasm:
	zig build wasm

package:
	python scripts/package_duckdb.py

data:
	python scripts/fetch_test_data.py

bq-deploy:
	python scripts/deploy_bq_test_data.py

clean:
	rm -rf zig-out .zig-cache
