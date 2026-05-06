// The return value indicates whether anything was changed.
fn update_block(
    block: *cfg_def.CFGNode,
    ast: std.zig.Ast,
    // We do not permit duplicates here, so we check on fncall to ensure we don't clobber.
    callstack: cfg_def.Set(cfg_def.CanonicalToken),
    gpa: std.mem.Allocator,
) !bool {
    // The Start block doesn't need any updates.
    if (block.kind == .Start) {
        return false;
    }
    var changed: bool = false;
    // Gather and merge all input source/sink lists.
    var sources_in = merge_dicts_in(cfg_def.SourceState, block.nodes_in, gpa);
    var sinks_in = merge_dicts_in(cfg_def.SinkState, block.nodes_in, gpa);
    if (block.mem_op == null) {
        // Easy!
    } else {
        switch (block.mem_op.?) {
            .Allocation => |*val| {
                // Mark that variable as unconditionally allocated by that allocator.
                var var_entry = try sources_in.getOrPut(val.result);
                if (!var_entry.found_existing) {
                    var_entry.value_ptr.* = .init(gpa);
                }
                var_entry.value_ptr.clearAndFree();
                var_entry.value_ptr.put(.{ .Alloc = val.allocator }, {});
            },
            // TODO: everything else
        }
    }
}

fn merge_dicts_in(
    comptime T: type,
    nodes: []*cfg_def.CFGNode,
    gpa: std.mem.Allocator,
) cfg_def.SetDict(T) {
    var retval = cfg_def.SetDict(T).init(gpa);
    // For each input node...
    for (nodes) |ptr| {
        // For each variable referenced in each input node...
        var it = if (T == cfg_def.SourceState) ptr.sources_out.iterator() else if (T == cfg_def.SinkState) ptr.sinks_out.iterator() else {
            return retval;
        };
        while (it.next()) |var_entry| {
            var ret_entry = try retval.getOrPut(var_entry.key_ptr.*);
            if (!ret_entry.found_existing) {
                ret_entry.value_ptr.* = .init(gpa);
            }
            // For each possible state that variable could be in...
            var elem_it = var_entry.value_ptr.keyIterator();
            while (elem_it.next()) |elem| {
                // Make sure we include that state.
                ret_entry.value_ptr.put(elem.*, {});
            }
        }
    }
    return retval;
}

const cfg_def = @import("cfg_def.zig");
const std = @import("std");
