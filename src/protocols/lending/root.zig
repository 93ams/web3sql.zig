pub const ray_wad = @import("ray_wad.zig");
pub const health_factor = @import("health_factor.zig");
pub const interest = @import("interest.zig");
pub const compound = @import("compound.zig");

test {
    _ = @import("ray_wad.zig");
    _ = @import("health_factor.zig");
    _ = @import("interest.zig");
    _ = @import("compound.zig");
}
