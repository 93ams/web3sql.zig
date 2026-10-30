//! Writes the warehouse deployment scripts for a built wasm bundle.
//! Usage: sql_gen <web3_sql.wasm> <bigquery.sql> <bigquery_web3.js> <snowflake.sql>
const std = @import("std");
const web3sql = @import("web3sql");

const sqlgen = web3sql.targets.wasm_udf.sqlgen;
const functions = web3sql.targets.wasm_functions;

fn writeTo(io: std.Io, path: []const u8, ctx: anytype, comptime body: fn (*std.Io.Writer, @TypeOf(ctx)) std.Io.Writer.Error!void) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    try body(&fw.interface, ctx);
    try fw.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 5) return error.InvalidArguments;
    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(16 * 1024 * 1024));
    const b64 = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(wasm.len));
    _ = std.base64.standard.Encoder.encode(b64, wasm);

    try writeTo(io, args[2], {}, struct {
        fn f(w: *std.Io.Writer, _: void) std.Io.Writer.Error!void {
            return sqlgen.writeBigQuery(w, functions);
        }
    }.f);
    try writeTo(io, args[3], b64, struct {
        fn f(w: *std.Io.Writer, b: []const u8) std.Io.Writer.Error!void {
            return sqlgen.writeBigQueryLibrary(w, b);
        }
    }.f);
    try writeTo(io, args[4], b64, struct {
        fn f(w: *std.Io.Writer, b: []const u8) std.Io.Writer.Error!void {
            return sqlgen.writeSnowflake(w, functions, b);
        }
    }.f);
}
