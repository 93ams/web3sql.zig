pub const pubkey = @import("pubkey.zig");
pub const borsh = @import("borsh.zig");
pub const anchor = @import("anchor.zig");
pub const idl = @import("idl.zig");
pub const schema = @import("schema.zig");

test {
    _ = @import("pubkey.zig");
    _ = @import("borsh.zig");
    _ = @import("anchor.zig");
    _ = @import("idl.zig");
    _ = @import("schema.zig");
}
