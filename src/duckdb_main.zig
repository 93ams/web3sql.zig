const std = @import("std");
const web3sql = @import("web3sql");

pub export fn web3_init_c_api(info: ?*anyopaque) callconv(.c) bool {
    _ = info;
    return true;
}

pub export fn web3_version() callconv(.c) [*:0]const u8 {
    return "0.1.0";
}
