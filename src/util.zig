const std = @import("std");
const cfg_def = @import("cfg_def.zig");

pub fn print_set(comptime T: type, set: *cfg_def.Set(T)) void {
    std.debug.print("{{ ", .{});
    var it = set.keyIterator();
    while (it.next()) |elem| {
        std.debug.print("{any} ", .{elem.*});
    }
    std.debug.print(" }}", .{});
}

pub fn print_setdict(comptime T: type, set_dict: *cfg_def.SetDict(T)) void {
    std.debug.print("{{\n", .{});
    var it = set_dict.iterator();
    while (it.next()) |entry| {
        std.debug.print("  {any}: ", .{entry.key_ptr.*});
        print_set(T, entry.value_ptr);
        std.debug.print(",\n", .{});
    }
    std.debug.print("}}\n", .{});
}

pub fn print_blockflow(flow: *cfg_def.BlockFlow) void {
    std.debug.print("source: ", .{});
    print_setdict(cfg_def.SourceState, &flow.sources);
    std.debug.print("sink: ", .{});
    print_setdict(cfg_def.SinkState, &flow.sinks);
    std.debug.print("\n", .{});
}

pub fn print_nodeflow(node: *cfg_def.CFGNode, name: []const u8) void {
    std.debug.print("\n{s}.in\n", .{name});
    print_blockflow(&node.in);
    std.debug.print("{any}\n{s}.out\n", .{ node.mem_op, name });
    print_blockflow(&node.out);
}
