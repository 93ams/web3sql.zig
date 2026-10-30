pub const script = @import("script.zig");
pub const op_return = @import("op_return.zig");
pub const network = @import("network.zig");
pub const runes = @import("runes.zig");
pub const ordinals = @import("ordinals.zig");

test {
    _ = @import("script.zig");
    _ = @import("op_return.zig");
    _ = @import("network.zig");
    _ = @import("runes.zig");
    _ = @import("ordinals.zig");
}
