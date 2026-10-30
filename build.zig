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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
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
    const duckdb_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "web3.duckdb_extension",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/duckdb_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "web3sql", .module = mod },
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });
    duckdb_lib.rdynamic = true;
    const duckdb_step = b.step("duckdb", "Build DuckDB C-API extension dynamic library");
    const install_duckdb = b.addInstallArtifact(duckdb_lib, .{});
    duckdb_step.dependOn(&install_duckdb.step);

    // WebAssembly UDF Target (wasm32-freestanding)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_artifact = b.addExecutable(.{
        .name = "web3_sql",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "web3sql", .module = mod },
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });
    wasm_artifact.entry = .disabled;
    wasm_artifact.rdynamic = true;

    const wasm_step = b.step("wasm", "Build freestanding WebAssembly UDF bundle (web3_sql.wasm)");
    const install_wasm = b.addInstallArtifact(wasm_artifact, .{});
    wasm_step.dependOn(&install_wasm.step);
}
