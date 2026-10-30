pub const address = @import("address.zig");
pub const typetag = @import("typetag.zig");
pub const bcs = @import("bcs.zig");
pub const schema = @import("schema.zig");

test {
    _ = @import("address.zig");
    _ = @import("typetag.zig");
    _ = @import("bcs.zig");
    _ = @import("schema.zig");
    _ = @import("out.zig");
}
