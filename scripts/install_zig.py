#!/usr/bin/env python3
"""Installs the pinned Zig into .zig-toolchain/, because DuckDB's community build provides none.

Does nothing when `zig` is already on PATH. Standard library only: it runs before any venv exists.
"""
import hashlib
import io
import pathlib
import platform
import shutil
import sys
import tarfile
import urllib.request
import zipfile

VERSION = "0.17.0"
SHA256 = {
    "x86_64-linux": "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026",
    "aarch64-linux": "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8",
    "x86_64-macos": "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6",
    "aarch64-macos": "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
    "x86_64-windows": "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428",
    "aarch64-windows": "0a59d91fa1cb40cf068e9b0954434ce973500c7a2ea749f1e01af62cdab52d26",
}

repo = pathlib.Path(__file__).resolve().parent.parent
pinned = (repo / ".zigversion").read_text().strip()
if pinned != VERSION:
    sys.exit(f"install_zig.py pins {VERSION} but .zigversion says {pinned}: update both")

home = repo / ".zig-toolchain"
if shutil.which("zig") or home.exists():
    sys.exit(0)

arch = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}[platform.machine().lower()]
system = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}[platform.system()]
stem = f"zig-{arch}-{system}-{VERSION}"
archive = f"{stem}.{'zip' if system == 'windows' else 'tar.xz'}"

with urllib.request.urlopen(f"https://ziglang.org/download/{VERSION}/{archive}") as response:
    data = response.read()
digest = hashlib.sha256(data).hexdigest()
if digest != SHA256[f"{arch}-{system}"]:
    sys.exit(f"{archive}: sha256 {digest} does not match the pinned hash")

unpacked = repo / ".zig-toolchain.tmp"
shutil.rmtree(unpacked, ignore_errors=True)
if system == "windows":
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        z.extractall(unpacked)
else:
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as t:
        t.extractall(unpacked, filter="data")
(unpacked / stem).rename(home)
shutil.rmtree(unpacked)
