const std = @import("std");
const cfg = @import("cfg_def.zig");
const rules = @import("rules.zig");

pub const AlertKind = enum {
    DoubleFree,
    CrossFree,
    MemoryLeakDrop,
    MemoryLeakClobber,
};

pub const AnalysisAlert = struct {
    variable: cfg.CanonicalToken,
    location: std.zig.Ast.Node.Index,
    kind: AlertKind,
};

pub fn generate_alerts(
    fn_name: cfg.CanonicalToken,
    parsed: *cfg.ParsedCFG,
    gpa: std.mem.Allocator,
) ![]AnalysisAlert {
    const analyzed = parsed.functions.getPtr(fn_name).?;
    const start_node = &analyzed.func.start_node;
    const round_num: u32 = std.math.maxInt(u32);

    var alerts: std.ArrayList(AnalysisAlert) = .empty;

    var stack: std.ArrayList(*cfg.CFGNode) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, start_node);
    while (stack.pop()) |node| {
        // We can skip if it has already been visited this round.
        if (node.round_visited == round_num) {
            continue;
        }
        var varnames = try collect_varnames(node, gpa);
        defer varnames.deinit();
        var name_it = varnames.keyIterator();
        while (name_it.next()) |varname| {
            if (try double_free(node, varname.*, parsed, gpa)) |alert| {
                try append_alert(&alerts, node, varname.*, alert, gpa);
            }
            if (try memory_leak_clobber(node, varname.*, parsed, gpa)) |alert| {
                try append_alert(&alerts, node, varname.*, alert, gpa);
            }
            if (try memory_leak_drop(analyzed.func.return_tok, node, varname.*, gpa)) |alert| {
                try append_alert(&alerts, node, varname.*, alert, gpa);
            }
        }

        node.round_visited = round_num;
        for (node.nodes_out) |child| {
            try stack.append(gpa, child);
        }
    }
    return try alerts.toOwnedSlice(gpa);
}

fn append_alert(
    alerts: *std.ArrayList(AnalysisAlert),
    block: *cfg.CFGNode,
    varname: cfg.CanonicalToken,
    kind: AlertKind,
    gpa: std.mem.Allocator,
) !void {
    try alerts.append(gpa, .{
        .variable = varname,
        .kind = kind,
        .location = if (block.ast_nodes.len > 0) block.ast_nodes[0] else .root,
    });
}

// Detects: if this block certainly frees varname AND varname has certainly been freed already.
fn double_free(block: *cfg.CFGNode, varname: cfg.CanonicalToken, parsed: *cfg.ParsedCFG, gpa: std.mem.Allocator) !?AlertKind {
    if (block.mem_op) |mem_op| {
        // Check: do we certainly free the variable in this block?
        const affected = switch (mem_op) {
            .Allocation => {
                // alloc() can't free, so no risk of double free.
                return null;
            },
            .FunctionCall => |op| swcase: {
                // All the functions should be analyzed by now.
                const annotations = parsed.functions.get(op.function_name).?.analysis.?;
                if (annotations.sinks.get(varname)) |states| {
                    var collapsed = try collapse(cfg.SinkState, &states, gpa);
                    defer collapsed.deinit();
                    // Note: even though FnInput could "contain" non-alloc-ed states in the outer scope,
                    // we'll always flag it as bad: it means that somebody called var.deinit().
                    if (collapsed.contains(.{ .Uninit = {} }) or collapsed.contains(.{ .Maybe = 0 })) {
                        // There might be a path that doesn't free, so skip!
                        return null;
                    }
                    break :swcase varname;
                } else {
                    // If the annotations don't mention this variable, great!
                    return null;
                }
            },
            .Deallocation => |op| op.variable,
            .DeinitExplicit => |op| op.variable,
            .Deinit => |op| op.variable,
        };
        if (affected != varname) {
            // Ah, the freed variable is a different one.
            return null;
        }

        // Now: is the variable certainly already freed?
        if (block.in.sinks.get(varname)) |states| {
            const collapsed = try collapse(cfg.SinkState, &states, gpa);
            if (collapsed.contains(.{ .Uninit = {} }) or collapsed.contains(.{ .Maybe = 0 })) {
                // It might not have been freed yet.
                return null;
            }
        }
        // Okay. So here we are. A variable is definitely freed, and it is also definitely already freed.
        return .DoubleFree;
    }
    // No memory operation? No frees.
    return null;
}

// Detects: if this block sets the allocation state of a variable and the allocation state only contains .Alloc = ...
fn memory_leak_clobber(block: *cfg.CFGNode, varname: cfg.CanonicalToken, parsed: *cfg.ParsedCFG, gpa: std.mem.Allocator) !?AlertKind {
    if (block.mem_op) |mem_op| {
        // Check: do we certainly allocate the variable in this block?
        const affected = switch (mem_op) {
            .Allocation => |val| val.result,
            .FunctionCall => |op| swcase: {
                // All the functions should be analyzed by now.
                const annotations = parsed.functions.get(op.function_name).?.analysis.?;
                if (annotations.sources.get(varname)) |states| {
                    var collapsed = try collapse(cfg.SourceState, &states, gpa);
                    defer collapsed.deinit();
                    // Note: even though FnInput could "contain" non-alloc-ed states in the outer scope,
                    // we'll always flag it as bad: it means that somebody called var.deinit().
                    if (collapsed.contains(.{ .Uninit = {} }) or collapsed.contains(.{ .Maybe = 0 })) {
                        // There might be a path that doesn't allocate, so skip!
                        // Note that it's not allowed to contain FnInput.
                        return null;
                    }
                    break :swcase varname;
                } else {
                    // If the annotations don't mention this variable, great!
                    return null;
                }
            },
            .Deallocation, .DeinitExplicit, .Deinit => {
                return null;
            },
        };
        if (affected != varname) {
            // Ah, the allocated variable is a different one.
            return null;
        }

        // Now: is the variable certainly already allocated?
        if (block.in.sources.get(varname)) |states| {
            var collapsed = try collapse(cfg.SourceState, &states, gpa);
            defer collapsed.deinit();
            if (collapsed.count() == 1 and collapsed.contains(.{ .Alloc = 0 })) {
                // Okay. So here we are. A variable is definitely allocated, and it is also definitely already allocated.
                return .MemoryLeakClobber;
            }
        }
        // No allocation state?
    }
    // No memory operation? No allocation.
    return null;
}

// Detects: if this function, at the end, has only Uninit in its sinks (and is not returned) but has only Alloc in its sources.
fn memory_leak_drop(ret_token: ?cfg.CanonicalToken, block: *cfg.CFGNode, varname: cfg.CanonicalToken, gpa: std.mem.Allocator) !?AlertKind {
    if (block.kind != .Return) {
        return null;
    }
    // If this is the return value, don't bother checking its sink state.
    if (ret_token != null and varname == ret_token) {
        return null;
    }
    // Does this only have Uninit in its sinks?
    if (block.out.sinks.get(varname)) |sinks| {
        if (sinks.count() != 1 or !sinks.contains(.{ .Uninit = {} })) {
            return null;
        }
    }
    // Does this only have alloc in its sources?
    if (block.out.sources.get(varname)) |sources| {
        var collapsed = try collapse(cfg.SourceState, &sources, gpa);
        defer collapsed.deinit();
        if (collapsed.count() == 1 and collapsed.contains(.{ .Alloc = 0 })) {
            // Alright, we have an error!
            return .MemoryLeakDrop;
        }
    }
    return null;
}

// Collapse down to the "types" of things
fn collapse(comptime T: type, set: *const cfg.Set(T), gpa: std.mem.Allocator) !cfg.Set(T) {
    var collapsed: cfg.Set(T) = .init(gpa);
    var state_it = set.keyIterator();
    while (state_it.next()) |state| {
        if (T == cfg.SourceState) {
            try collapsed.put(switch (state.*) {
                .Alloc => .{ .Alloc = 0 },
                .Maybe => .{ .Maybe = 0 },
                .FnInput => .{ .FnInput = {} },
                .Uninit => .{ .Uninit = {} },
            }, {});
        } else if (T == cfg.SinkState) {
            try collapsed.put(switch (state.*) {
                .Dealloc => .{ .Dealloc = 0 },
                .Maybe => .{ .Maybe = 0 },
                .FnInput => .{ .FnInput = {} },
                .Uninit => .{ .Uninit = {} },
            }, {});
        } else {
            return collapsed;
        }
    }
    return collapsed;
}

fn collect_varnames(node: *cfg.CFGNode, gpa: std.mem.Allocator) !cfg.Set(cfg.CanonicalToken) {
    var varnames: cfg.Set(cfg.CanonicalToken) = .init(gpa);
    var key_it1 = node.out.sources.keyIterator();
    while (key_it1.next()) |key| {
        try varnames.put(key.*, {});
    }
    var key_it2 = node.out.sinks.keyIterator();
    while (key_it2.next()) |key| {
        try varnames.put(key.*, {});
    }
    return varnames;
}
