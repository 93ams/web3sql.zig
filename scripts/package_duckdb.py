#!/usr/bin/env python3
"""
scripts/package_duckdb.py

Appends the mandatory DuckDB 512-byte metadata footer to the compiled shared library,
producing the final 'web3.duckdb_extension' loadable binary.
Detects platform (windows_amd64, linux_amd64, osx_arm64, etc.) dynamically or via flag.
"""

import os
import sys
import platform
import argparse

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN_DIR = os.path.join(REPO_ROOT, "zig-out", "bin")

def get_default_platform():
    system = platform.system().lower()
    machine = platform.machine().lower()

    os_tag = "linux"
    if system == "windows":
        os_tag = "windows"
    elif system == "darwin":
        os_tag = "osx"

    arch_tag = "amd64"
    if machine in ("arm64", "aarch64"):
        arch_tag = "arm64"
    elif machine in ("x86_64", "amd64"):
        arch_tag = "amd64"

    return f"{os_tag}_{arch_tag}"

def package_extension(input_lib=None, output_path=None, target_platform=None):
    target_platform = target_platform or get_default_platform()
    output_path = output_path or os.path.join(BIN_DIR, "web3.duckdb_extension")

    # Locate input dynamic library if not provided
    if not input_lib:
        candidates = [
            os.path.join(BIN_DIR, "web3.duckdb_extension.dll"),
            os.path.join(BIN_DIR, "libweb3.duckdb_extension.so"),
            os.path.join(BIN_DIR, "web3.duckdb_extension.so"),
            os.path.join(BIN_DIR, "libweb3.duckdb_extension.dylib"),
            os.path.join(BIN_DIR, "web3.duckdb_extension.dylib"),
        ]
        for c in candidates:
            if os.path.exists(c):
                input_lib = c
                break

    if not input_lib or not os.path.exists(input_lib):
        print("[!] Input shared library not found. Please run 'zig build duckdb' first.")
        sys.exit(1)

    with open(input_lib, "rb") as f:
        lib_bytes = f.read()

    # Construct 512-byte DuckDB metadata footer
    footer = bytearray(512)

    def write_field(text, offset):
        raw = text.encode("ascii")
        footer[offset : offset + len(raw)] = raw

    write_field("C_STRUCT", 96)        # Field 3: ABI Type
    write_field("0.1.0", 128)           # Field 4: Extension Version
    write_field("v1.5.6", 160)          # Field 5: DuckDB Version
    write_field(target_platform, 192)   # Field 6: Platform tag
    write_field("4", 224)               # Field 7: Magic byte '4'

    with open(output_path, "wb") as f:
        f.write(lib_bytes)
        f.write(footer)

    print(f"[SUCCESS] Packaged DuckDB extension ({target_platform}) to: {output_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Package DuckDB extension binary with 512-byte metadata footer.")
    parser.add_argument("--input", type=str, default=None, help="Path to input shared library (.dll/.so/.dylib)")
    parser.add_argument("--output", type=str, default=None, help="Path to output .duckdb_extension file")
    parser.add_argument("--platform", type=str, default=None, help="Target platform tag (e.g. windows_amd64, linux_amd64)")
    args = parser.parse_args()

    package_extension(args.input, args.output, args.platform)

