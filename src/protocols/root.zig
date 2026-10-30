const build_options = @import("build_options");

pub const clmm = if (build_options.protocol_clmm) @import("clmm/root.zig") else struct {};
pub const tokens = if (build_options.protocol_tokens) @import("tokens/root.zig") else struct {};
pub const lending = if (build_options.protocol_lending) @import("lending/root.zig") else struct {};

test {
    if (build_options.protocol_clmm) _ = @import("clmm/root.zig");
    if (build_options.protocol_tokens) _ = @import("tokens/root.zig");
    if (build_options.protocol_lending) _ = @import("lending/root.zig");
}
