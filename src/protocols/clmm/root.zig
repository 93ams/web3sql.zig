pub const q64_96 = @import("q64_96.zig");
pub const q64_64 = @import("q64_64.zig");
pub const price = @import("price.zig");

test {
    _ = @import("price.zig");
    _ = @import("q64_96.zig");
    _ = @import("q64_64.zig");
}
