//! Deployment-script generators (REQ-WASM-03). Output is derived from the catalogue alone.
const std = @import("std");
const catalog = @import("../catalog.zig");

const Writer = std.Io.Writer;

/// ES5 so it runs in Snowflake's and BigQuery's V8 sandboxes, which lack TextEncoder and atob.
/// Each row: `web3_call(name, args, kinds, ret)`; kinds and ret use b(ytes) t(ext) i(nt) o (boolean).
const RUNTIME =
    \\var W3B="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    \\function w3Unb64(s){var n=s.length;while(n>0&&s.charAt(n-1)=="=")n--;var o=new Uint8Array(Math.floor(n*3/4)),b=0,c=0,p=0;for(var i=0;i<n;i++){b=(b<<6)|W3B.indexOf(s.charAt(i));c+=6;if(c>=8){c-=8;o[p++]=(b>>c)&255;b&=(1<<c)-1;}}return o;}
    \\function w3B64(u){var s="",i=0;for(;i+2<u.length;i+=3){var v=(u[i]<<16)|(u[i+1]<<8)|u[i+2];s+=W3B.charAt(v>>18)+W3B.charAt((v>>12)&63)+W3B.charAt((v>>6)&63)+W3B.charAt(v&63);}if(i+1==u.length){var a=u[i]<<16;s+=W3B.charAt(a>>18)+W3B.charAt((a>>12)&63)+"==";}else if(i+2==u.length){var d=(u[i]<<16)|(u[i+1]<<8);s+=W3B.charAt(d>>18)+W3B.charAt((d>>12)&63)+W3B.charAt((d>>6)&63)+"=";}return s;}
    \\function w3Utf8(s){var e=unescape(encodeURIComponent(s)),u=new Uint8Array(e.length);for(var i=0;i<e.length;i++)u[i]=e.charCodeAt(i);return u;}
    \\function w3Text(u){var s="";for(var i=0;i<u.length;i++)s+=String.fromCharCode(u[i]);return decodeURIComponent(escape(s));}
    \\function web3_call(name,args,kinds,ret){
    \\var g=typeof globalThis!="undefined"?globalThis:this;
    \\if(!g.__web3)g.__web3=new WebAssembly.Instance(new WebAssembly.Module(w3Unb64(WEB3_WASM)),{}).exports;
    \\var w=g.__web3,n=args.length;
    \\for(var i=0;i<n;i++)if(args[i]===null||args[i]===undefined)return null;
    \\w.web3_free();
    \\var argv=w.web3_alloc(8*n);if(!argv&&n)return null;
    \\for(var i=0;i<n;i++){var v=args[i],k=kinds.charAt(i),lo,hi;
    \\if(k=="i"){var x=Number(v);if(!Number.isSafeInteger(x))return null;lo=x>>>0;hi=Math.floor(x/4294967296)>>>0;}
    \\else{var u=k=="t"?w3Utf8(String(v)):(typeof v=="string"?w3Unb64(v):v);lo=u.length?w.web3_alloc(u.length):0;if(u.length&&!lo)return null;hi=u.length;new Uint8Array(w.memory.buffer,lo,u.length).set(u);}
    \\var dv=new DataView(w.memory.buffer);dv.setUint32(argv+8*i,lo,true);dv.setUint32(argv+8*i+4,hi,true);}
    \\var cap=w.web3_available(),out=w.web3_alloc(cap),len=w[name](argv,n,out,cap);
    \\if(len<0)return null;
    \\var r=new Uint8Array(w.memory.buffer,out,len);
    \\if(ret=="o")return r[0]!=0;
    \\if(ret=="i")return Number(new DataView(w.memory.buffer).getBigInt64(out,true));
    \\if(ret=="t")return w3Text(r);
    \\return new Uint8Array(r);}
    \\
;

fn signatureKinds(w: *Writer, f: *const catalog.Function) Writer.Error!void {
    for (f.args) |a| try w.writeByte(switch (a) {
        .bytes => 'b',
        .text => 't',
        .int => 'i',
    });
}

fn retKind(ret: catalog.RetType) u8 {
    return switch (ret) {
        .bytes => 'b',
        .text => 't',
        .int => 'i',
        .boolean => 'o',
    };
}

fn callBody(w: *Writer, f: *const catalog.Function, arg_prefix: []const u8, wrap_bytes_result: bool) Writer.Error!void {
    if (wrap_bytes_result and f.ret == .bytes) {
        try w.writeAll("var r=");
    } else {
        try w.writeAll("return ");
    }
    try w.print("web3_call(\"{s}\",[", .{f.name});
    for (f.args, 0..) |_, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{s}{d}", .{ arg_prefix, i });
    }
    try w.writeAll("],\"");
    try signatureKinds(w, f);
    try w.print("\",\"{c}\");", .{retKind(f.ret)});
    if (wrap_bytes_result and f.ret == .bytes) try w.writeAll("return r===null?null:w3B64(r);");
}

fn bigQueryType(kind: anytype) []const u8 {
    return switch (@tagName(kind)[0]) {
        'b' => if (@tagName(kind).len == 5) "BYTES" else "BOOL",
        't' => "STRING",
        else => "INT64",
    };
}

/// The GCS library: BigQuery caps inline code at 32 KB, but external code resources at 1 MB.
pub fn writeBigQueryLibrary(w: *Writer, wasm_base64: []const u8) Writer.Error!void {
    try w.print("var WEB3_WASM=\"{s}\";\n", .{wasm_base64});
    try w.writeAll(RUNTIME);
}

pub fn writeBigQuery(w: *Writer, functions: []const catalog.Function) Writer.Error!void {
    try w.writeAll(
        \\-- web3sql BigQuery UDFs. Generated from the function catalogue; do not edit.
        \\-- Upload bigquery_web3.js to GCS, then replace __WEB3_DATASET__ and __WEB3_GCS_URI__.
        \\-- Inline wasm is impossible here: BigQuery limits inline code blobs to 32 KB.
        \\
    );
    for (functions) |*f| {
        try w.print("CREATE OR REPLACE FUNCTION `__WEB3_DATASET__`.{s}(", .{f.name});
        for (f.args, 0..) |a, i| {
            if (i != 0) try w.writeAll(", ");
            // BigQuery rejects INT64 as a JavaScript UDF input.
            try w.print("a{d} {s}", .{ i, if (a == .int) "FLOAT64" else bigQueryType(a) });
        }
        try w.print(") RETURNS {s} LANGUAGE js OPTIONS (library=[\"__WEB3_GCS_URI__\"], description=\"{s}\") AS r\"\"\"", .{ bigQueryType(f.ret), f.doc });
        try callBody(w, f, "a", true);
        try w.writeAll("\"\"\";\n");
    }
}

fn snowflakeType(kind: anytype) []const u8 {
    return switch (@tagName(kind)[0]) {
        'b' => if (@tagName(kind).len == 5) "BINARY" else "BOOLEAN",
        't' => "VARCHAR",
        else => "DOUBLE",
    };
}

pub fn writeSnowflake(w: *Writer, functions: []const catalog.Function, wasm_base64: []const u8) Writer.Error!void {
    try w.writeAll(
        \\-- web3sql Snowflake UDFs. Generated from the function catalogue; do not edit.
        \\-- UNVERIFIED on a live account: Snowflake does not document WebAssembly in JavaScript UDFs,
        \\-- and recommends bodies under 100 KB. Run one CREATE and one SELECT before deploying all.
        \\
    );
    for (functions) |*f| {
        try w.print("CREATE OR REPLACE FUNCTION {s}(", .{f.name});
        for (f.args, 0..) |a, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("A{d} {s}", .{ i, snowflakeType(a) });
        }
        try w.print(") RETURNS {s} LANGUAGE JAVASCRIPT RETURNS NULL ON NULL INPUT AS $$\n", .{snowflakeType(f.ret)});
        try w.print("var WEB3_WASM=\"{s}\";\n", .{wasm_base64});
        try w.writeAll(RUNTIME);
        try callBody(w, f, "A", false);
        try w.writeAll("\n$$;\n");
    }
}

fn typeName(kind: anytype) []const u8 {
    return switch (@tagName(kind)[0]) {
        'b' => if (@tagName(kind).len == 5) "BLOB" else "BOOLEAN",
        't' => "VARCHAR",
        else => "BIGINT",
    };
}

/// docs/FUNCTIONS.md, so the reference cannot drift from the catalogue.
pub fn writeFunctionDocs(w: *Writer, functions: []const catalog.Function) Writer.Error!void {
    try w.writeAll(
        \\# SQL functions
        \\
        \\Generated from the function catalogue by `zig build docs`. Any malformed row returns `NULL`, and so does a valid row whose result exceeds 64 KB in DuckDB, or the 60 KB shared by arguments and result in WASM.
        \\Types are DuckDB's. Functions marked *DuckDB only* parse JSON, and are left out of the WASM bundle to fit its size budget.
        \\
        \\| Function | Returns | Description |
        \\|---|---|---|
        \\
    );
    for (functions) |f| {
        try w.print("| `{s}(", .{f.name});
        for (f.args, 0..) |a, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(typeName(a));
        }
        try w.print(")` | {s} | {s}{s} |\n", .{ typeName(f.ret), f.doc, if (f.native_only) " *DuckDB only*" else "" });
    }
}

const SAMPLE = [_]catalog.Function{
    catalog.func("web3_demo", "Demo", &.{ .bytes, .text, .int }, .bytes, struct {
        fn f(_: []const u8, _: []const u8, _: i64, dest: []u8) []const u8 {
            return dest[0..0];
        }
    }.f),
    catalog.func("web3_flag", "Flag", &.{.text}, .boolean, struct {
        fn f(_: []const u8) bool {
            return true;
        }
    }.f),
};

test "function docs list every signature" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeFunctionDocs(&w, &SAMPLE);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "| `web3_demo(BLOB, VARCHAR, BIGINT)` | BLOB | Demo |") != null);
}

test "REQ-WASM-03 BigQuery golden file" {
    var buf: [4096]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeBigQuery(&w, &SAMPLE);
    try std.testing.expectEqualStrings(@embedFile("golden/bigquery.sql"), w.buffered());
}

test "REQ-WASM-03 Snowflake golden file" {
    var buf: [16 * 1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeSnowflake(&w, SAMPLE[1..], "QUJD");
    try std.testing.expectEqualStrings(@embedFile("golden/snowflake.sql"), w.buffered());
}
