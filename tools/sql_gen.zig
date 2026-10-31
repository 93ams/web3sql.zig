//! Writes the warehouse deployment scripts for a built wasm bundle.
//! Usage: sql_gen <web3_sql.wasm> <web3_sql.o> <zig> <modules dir> <bigquery.sql> <bigquery_web3.js> <snowflake.sql>
//!    or: sql_gen --docs <FUNCTIONS.md>
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

fn base64(gpa: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    return std.base64.standard.Encoder.encode(out, bytes);
}

/// Links the object down to one export. `--gc-sections` then drops all the other functions.
fn linkModule(gpa: std.mem.Allocator, io: std.Io, zig: []const u8, object: []const u8, dir: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(gpa, &.{ dir, try std.fmt.allocPrint(gpa, "{s}.wasm", .{name}) });
    const result = try std.process.run(gpa, io, .{ .argv = &.{
        zig,                   "wasm-ld",            "--no-entry",              "--gc-sections",
        "--strip-all",         "--stack-first",      "-z",                      "stack-size=262144",
        "--export=web3_alloc", "--export=web3_free", "--export=web3_available", try std.fmt.allocPrint(gpa, "--export={s}", .{name}),
        object,                "-o",                 path,
    } });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("wasm-ld failed for {s}: {s}\n", .{ name, result.stderr });
        return error.LinkFailed;
    }
    return base64(gpa, try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--docs")) {
        return writeTo(io, args[2], {}, struct {
            fn f(w: *std.Io.Writer, _: void) std.Io.Writer.Error!void {
                return sqlgen.writeFunctionDocs(w, web3sql.targets.functions);
            }
        }.f);
    }
    if (args.len != 8) return error.InvalidArguments;
    const b64 = try base64(gpa, try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(16 * 1024 * 1024)));
    const modules = try gpa.alloc([]const u8, functions.len);
    for (functions, modules) |f, *m| m.* = try linkModule(gpa, io, args[3], args[2], args[4], f.name);

    try writeTo(io, args[5], modules, struct {
        fn f(w: *std.Io.Writer, m: []const []const u8) std.Io.Writer.Error!void {
            return sqlgen.writeBigQuery(w, functions, m);
        }
    }.f);
    try writeTo(io, args[6], b64, struct {
        fn f(w: *std.Io.Writer, b: []const u8) std.Io.Writer.Error!void {
            return sqlgen.writeBigQueryLibrary(w, b);
        }
    }.f);
    try writeTo(io, args[7], modules, struct {
        fn f(w: *std.Io.Writer, m: []const []const u8) std.Io.Writer.Error!void {
            return sqlgen.writeSnowflake(w, functions, m);
        }
    }.f);
}
