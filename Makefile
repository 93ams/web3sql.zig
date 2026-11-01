.PHONY: all test verify reference soak artifacts build duckdb wasm docs bench data bq-deploy clean install_zig configure release test_release

# Builds on a Windows-mounted filesystem hang unless the cache lives elsewhere.
ifneq ($(filter /mnt/%,$(CURDIR)),)
export ZIG_LOCAL_CACHE_DIR ?= $(HOME)/.cache/web3sql-zig/main
endif

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

artifacts:
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
	rm -rf zig-out .zig-cache dist release build configure .zig-toolchain

# DuckDB's community build runs `make configure_ci`, `make release` and `make test_release`,
# so those names keep the meanings base.Makefile gives them. That CI checks out extension-ci-tools here.
EXTENSION_NAME = web3
-include extension-ci-tools/makefiles/c_api_extensions/base.Makefile

ZIG = $(shell which zig 2>/dev/null || echo $(CURDIR)/.zig-toolchain/zig)
ZIG_TARGET_linux_amd64 = x86_64-linux-gnu
ZIG_TARGET_linux_arm64 = aarch64-linux-gnu
ZIG_TARGET_linux_amd64_musl = x86_64-linux-musl
ZIG_TARGET_linux_arm64_musl = aarch64-linux-musl
ZIG_TARGET_osx_amd64 = x86_64-macos
ZIG_TARGET_osx_arm64 = aarch64-macos
ZIG_TARGET_windows_amd64 = x86_64-windows-gnu
ZIG_TARGET_windows_arm64 = aarch64-windows-gnu
ZIG_TARGET = $(ZIG_TARGET_$(DUCKDB_PLATFORM))

install_zig:
	$(PYTHON_BIN) scripts/install_zig.py

configure: install_zig venv platform

release: check_configure
	$(ZIG) build duckdb -Doptimize=fast -Dcpu=baseline $(if $(ZIG_TARGET),-Dtarget=$(ZIG_TARGET))
	mkdir -p build/release/extension/web3
	cp zig-out/bin/web3.duckdb_extension build/release/web3.duckdb_extension
	cp zig-out/bin/web3.duckdb_extension build/release/extension/web3/web3.duckdb_extension

test_release: test_extension_release
