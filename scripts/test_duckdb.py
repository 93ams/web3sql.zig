#!/usr/bin/env python3
"""
scripts/test_duckdb.py

Cross-platform integration test for the DuckDB extension.
Loads 'zig-out/bin/web3.duckdb_extension' using DuckDB and executes validation queries.
Works across Windows, macOS, and Linux without platform-specific shell scripts.
"""

import os
import sys
import subprocess

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT_PATH = os.path.join(REPO_ROOT, "zig-out", "bin", "web3.duckdb_extension").replace("\\", "/")

def test_via_python_duckdb():
    try:
        import duckdb
        con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
        con.execute(f"LOAD '{EXT_PATH}';")
        rows = con.execute("SELECT 'DuckDB Extension Loaded Successfully via Python API!' AS verification;").fetchall()
        print(f"    [+] Python DuckDB: {rows[0][0]}")
        return True
    except Exception as e:
        print(f"    [-] Python DuckDB load failed: {e}")
        return False

def test_via_cli_duckdb():
    import shutil
    duckdb_bin = shutil.which("duckdb")
    if not duckdb_bin:
        winget_path = os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Links\duckdb.exe")
        if os.path.exists(winget_path):
            duckdb_bin = winget_path
        else:
            duckdb_bin = "duckdb"

    try:
        sql = f"LOAD '{EXT_PATH}'; SELECT 'DuckDB Extension Loaded Successfully via CLI!' AS verification;"
        cmd = [duckdb_bin, "-unsigned", "-c", sql]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        print(f"    [+] DuckDB CLI:\n{res.stdout.strip()}")
        return True
    except Exception as e:
        print(f"    [-] DuckDB CLI execution failed: {e}")
        return False

def main():
    print(f"[*] Testing DuckDB extension at: {EXT_PATH}")
    if not os.path.exists(EXT_PATH):
        print(f"[!] Extension file not found: {EXT_PATH}")
        print("    Please run: zig build duckdb && python scripts/package_duckdb.py")
        sys.exit(1)

    py_ok = test_via_python_duckdb()
    cli_ok = test_via_cli_duckdb()

    if not py_ok and not cli_ok:
        sys.exit(1)
    print("[SUCCESS] DuckDB extension integration tests passed.")

if __name__ == "__main__":
    main()

