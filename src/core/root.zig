pub const math = @import("math/root.zig");
pub const encodings = @import("encodings/root.zig");
pub const crypto = @import("crypto/root.zig");
pub const reader = @import("reader.zig");
pub const fuzz = @import("fuzz.zig");

test {
    _ = @import("math/root.zig");
    _ = @import("encodings/root.zig");
    _ = @import("crypto/root.zig");
    _ = @import("reader.zig");
    _ = @import("fuzz.zig");
}
