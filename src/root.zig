//! web3sql.zig: High-performance, modular blockchain SQL & binary decoding library.
const build_options = @import("build_options");

pub const core = @import("core/root.zig");

pub const chains = if (build_options.any_chain)
    @import("chains/root.zig")
else
    struct {};

pub const protocols = if (build_options.any_protocol)
    @import("protocols/root.zig")
else
    struct {};

pub const targets = @import("targets/root.zig");

test {
    _ = @import("core/root.zig");
    if (build_options.any_chain) {
        _ = @import("chains/root.zig");
    }
    if (build_options.any_protocol) {
        _ = @import("protocols/root.zig");
    }
    _ = @import("targets/root.zig");
}
