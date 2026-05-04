const std = @import("std");

pub fn branched_alloc(gpa1: std.mem.Allocator, gpa2: std.mem.Allocator, a: bool) !void {
    var arr: [5]u8 = undefined;
    if (a) {
        arr = gpa1.alloc(u8, 5);
    } else {
        arr = gpa2.alloc(u8, 5);
    }
    // State here?
}

pub fn branched_alloc2(gpa1: std.mem.Allocator, gpa2: std.mem.Allocator, a: bool) !void {
    var arr: [5]u8 = undefined;
    if (a) {
        arr = gpa1.alloc(u8, 5);
    }
    if (!a) {
        arr = gpa2.alloc(u8, 5);
    }
}

pub fn something_and_free(thing: []u8, alloc: std.mem.Allocator) void {
    defer alloc.free(thing);
    // And do something interesting, maybe.
}
