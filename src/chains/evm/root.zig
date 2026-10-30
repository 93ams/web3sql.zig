pub const address = @import("address.zig");
pub const abi = @import("abi.zig");
pub const abi_json = @import("abi_json.zig");
pub const decoder = @import("decoder.zig");

test {
    _ = @import("address.zig");
    _ = @import("abi.zig");
    _ = @import("abi_json.zig");
    _ = @import("decoder.zig");
}
