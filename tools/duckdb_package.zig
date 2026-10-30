//! Appends DuckDB's extension metadata section to a shared library.
//! Layout from duckdb/extension-ci-tools scripts/append_extension_metadata.py.
//! Usage: duckdb_package <input> <output> <platform> <c-api-version> <extension-version>
const std = @import("std");

const FIELD_LEN = 32;

fn field(w: *std.Io.Writer, value: []const u8) !void {
    if (value.len > FIELD_LEN) return error.FieldTooLong;
    try w.writeAll(value);
    try w.splatByteAll(0, FIELD_LEN - value.len);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) return error.InvalidArguments;
    const io = init.io;
    const lib = try std.Io.Dir.cwd().readFileAlloc(io, args[1], init.arena.allocator(), .limited(256 * 1024 * 1024));

    const out_file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer out_file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = out_file.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll(lib);
    // WebAssembly custom section header, so the same footer stays valid on wasm extensions.
    try w.writeAll(&.{ 0, 147, 4, 16 });
    try w.writeAll("duckdb_signature");
    try w.writeAll(&.{ 128, 4 });
    for (0..3) |_| try field(w, ""); // fields 8..6 are unused
    try field(w, "C_STRUCT");
    try field(w, args[5]);
    try field(w, args[4]);
    try field(w, args[3]);
    try field(w, "4"); // magic value identifying a DuckDB extension
    try w.splatByteAll(0, 256); // signature slot
    try w.flush();
}
