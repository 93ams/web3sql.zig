const std = @import("std");

const ChainsConfig = struct {
    evm: bool = false,
    svm: bool = false,
    move: bool = false,
    utxo: bool = false,
    cosmos: bool = false,
};

const ProtocolsConfig = struct {
    clmm: bool = false,
    tokens: bool = false,
    lending: bool = false,
};

/// Parses a comma-delimited feature list ("all", "none", or names of `Config` fields).
/// Unknown names are a hard error so a typo can never silently produce an empty build.
fn parseFeatures(b: *std.Build, comptime Config: type, name: []const u8, desc: []const u8) Config {
    const str = b.option([]const u8, name, desc) orelse "all";
    var cfg: Config = .{};
    if (std.mem.eql(u8, str, "none")) return cfg;
    if (std.mem.eql(u8, str, "all")) {
        inline for (comptime std.meta.fieldNames(Config)) |f| @field(cfg, f) = true;
        return cfg;
    }
    var it = std.mem.splitScalar(u8, str, ',');
    outer: while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " ");
        if (trimmed.len == 0) continue;
        inline for (comptime std.meta.fieldNames(Config)) |f| {
            if (std.mem.eql(u8, trimmed, f)) {
                @field(cfg, f) = true;
                continue :outer;
            }
        }
        std.process.fatal("unknown -D{s} value '{s}'", .{ name, trimmed });
    }
    return cfg;
}

fn anyEnabled(cfg: anytype) bool {
    inline for (comptime std.meta.fieldNames(@TypeOf(cfg))) |f| if (@field(cfg, f)) return true;
    return false;
}

/// Stable DuckDB C-API version; matches src/targets/duckdb_ext/vendor and API_VERSION in duckdb_main.zig.
const DUCKDB_API_VERSION = "v1.5.6";
const VERSION = "0.1.0";

/// DuckDB's platform tag for a resolved target, e.g. linux_amd64.
fn duckdbPlatform(b: *std.Build, t: std.Target) []const u8 {
    const os = switch (t.os.tag) {
        .macos => "osx",
        .windows => "windows",
        else => "linux",
    };
    const arch = switch (t.cpu.arch) {
        .aarch64 => "arm64",
        else => "amd64",
    };
    return b.fmt("{s}_{s}", .{ os, arch });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const duckdb_platform = b.option([]const u8, "duckdb_platform", "DuckDB platform tag for the extension footer [default: from target]") orelse
        duckdbPlatform(b, target.result);

    // Compile-time feature flags
    const chains_cfg = parseFeatures(b, ChainsConfig, "chains", "Comma-delimited chains (evm,svm,move,utxo,cosmos), 'all' or 'none' [default: all]");
    const protocols_cfg = parseFeatures(b, ProtocolsConfig, "protocols", "Comma-delimited protocols (clmm,tokens,lending), 'all' or 'none' [default: all]");

    const options = b.addOptions();
    options.addOption(bool, "chain_evm", chains_cfg.evm);
    options.addOption(bool, "chain_svm", chains_cfg.svm);
    options.addOption(bool, "chain_move", chains_cfg.move);
    options.addOption(bool, "chain_utxo", chains_cfg.utxo);
    options.addOption(bool, "chain_cosmos", chains_cfg.cosmos);
    options.addOption(bool, "protocol_clmm", protocols_cfg.clmm);
    options.addOption(bool, "protocol_tokens", protocols_cfg.tokens);
    options.addOption(bool, "protocol_lending", protocols_cfg.lending);
    options.addOption(bool, "any_chain", anyEnabled(chains_cfg));
    options.addOption(bool, "any_protocol", anyEnabled(protocols_cfg));

    const options_mod = options.createModule();

    // Primary Library Module
    const mod = b.addModule("web3sql", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
        },
    });

    // CLI Tool Executable
    const exe = b.addExecutable(.{
        .name = "web3sql",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "web3sql", .module = mod },
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the web3sql CLI tool");
    run_step.dependOn(&run_cmd.step);

    // Tests Step
    // `--fuzz` needs LLVM's coverage instrumentation; the self-hosted backend reports zero PCs.
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .use_llvm = true,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .use_llvm = true,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Benchmarks always run optimized, whatever -Doptimize says for the rest of the build.
    const bench_exe = b.addExecutable(.{
        .name = "web3sql-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{
                    .name = "web3sql",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/root.zig"),
                        .target = target,
                        .optimize = .ReleaseFast,
                        .imports = &.{.{ .name = "build_options", .module = options_mod }},
                    }),
                },
            },
        }),
    });
    const bench_step = b.step("bench", "Run throughput benchmarks (ReleaseFast)");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    // DuckDB Extension Target
    const duckdb_header = b.addTranslateC(.{
        .root_source_file = b.path("src/targets/duckdb_ext/vendor/duckdb_extension.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const duckdb_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "web3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/duckdb_main.zig"),
            .target = target,
            .optimize = if (optimize == .debug) .ReleaseFast else optimize,
            .strip = true,
            .imports = &.{
                .{ .name = "web3sql", .module = mod },
                .{ .name = "duckdb_c", .module = duckdb_header.createModule() },
            },
        }),
    });
    duckdb_lib.rdynamic = true;

    const packager = b.addExecutable(.{
        .name = "duckdb_package",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/duckdb_package.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const package = b.addRunArtifact(packager);
    package.addArtifactArg(duckdb_lib);
    const packaged = package.addOutputFileArg("web3.duckdb_extension");
    package.addArgs(&.{ duckdb_platform, DUCKDB_API_VERSION, VERSION });
    const duckdb_step = b.step("duckdb", "Build and package web3.duckdb_extension (-Dduckdb_platform=...)");
    duckdb_step.dependOn(&b.addInstallBinFile(packaged, "web3.duckdb_extension").step);

    // WebAssembly UDF Target (wasm32-freestanding, SIMD128). A separate library module because
    // `mod` is compiled for the host.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });
    const wasm_artifact = b.addExecutable(.{
        .name = "web3_sql",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .imports = &.{.{
                .name = "web3sql",
                .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = wasm_target,
                    .optimize = .ReleaseSmall,
                    .imports = &.{.{ .name = "build_options", .module = options_mod }},
                }),
            }},
        }),
    });
    wasm_artifact.entry = .disabled;
    wasm_artifact.rdynamic = true;
    wasm_artifact.stack_size = 256 * 1024;

    const wasm_size = b.addRunArtifact(b.addExecutable(.{
        .name = "wasm_size",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wasm_size.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));
    wasm_size.addArtifactArg(wasm_artifact);
    b.step("wasm-size", "Fail if web3_sql.wasm reaches 250 KB").dependOn(&wasm_size.step);

    const sql_gen_exe = b.addExecutable(.{
        .name = "sql_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sql_gen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "web3sql", .module = mod }},
        }),
    });
    const docs_gen = b.addRunArtifact(sql_gen_exe);
    docs_gen.addArg("--docs");
    const docs_out = b.addUpdateSourceFiles();
    docs_out.addCopyFileToSource(docs_gen.addOutputFileArg("FUNCTIONS.md"), "docs/FUNCTIONS.md");
    b.step("docs", "Regenerate docs/FUNCTIONS.md from the catalogue").dependOn(&docs_out.step);

    const sql_gen = b.addRunArtifact(sql_gen_exe);
    sql_gen.addArtifactArg(wasm_artifact);
    const bigquery_sql = sql_gen.addOutputFileArg("bigquery_udfs.sql");
    const bigquery_js = sql_gen.addOutputFileArg("bigquery_web3.js");
    const snowflake_sql = sql_gen.addOutputFileArg("snowflake_udfs.sql");
    const dist = b.addUpdateSourceFiles();
    dist.addCopyFileToSource(bigquery_sql, "dist/bigquery_udfs.sql");
    dist.addCopyFileToSource(bigquery_js, "dist/bigquery_web3.js");
    dist.addCopyFileToSource(snowflake_sql, "dist/snowflake_udfs.sql");

    const wasm_step = b.step("wasm", "Build web3_sql.wasm and dist/ warehouse deployment scripts");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_artifact, .{}).step);
    wasm_step.dependOn(&dist.step);
}
