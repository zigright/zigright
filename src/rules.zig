const std = @import("std");
const cfg_def = @import("cfg_def.zig");
const util = @import("util.zig");

pub const ParseError = error{
    UninitVarDeinited,
    LocalScopeAllocator,
    RecursiveCall,
    OutOfMemory,
    NoPtrAlias,
};

pub fn analyze_function(
    name: cfg_def.CanonicalToken,
    parsed: *cfg_def.ParsedCFG,
    gpa: std.mem.Allocator,
) !*cfg_def.BlockFlow {
    var callstack: cfg_def.Set(cfg_def.CanonicalToken) = .init(gpa);
    defer callstack.deinit();
    return try analyze_function_inner(name, parsed, &callstack, gpa);
}

fn analyze_function_inner(
    name: cfg_def.CanonicalToken,
    parsed: *cfg_def.ParsedCFG,
    callstack: *cfg_def.Set(cfg_def.CanonicalToken),
    gpa: std.mem.Allocator,
) !*cfg_def.BlockFlow {
    const analyzed = parsed.functions.getPtr(name).?;
    if (analyzed.analysis != null) {
        return &analyzed.analysis.?;
    }
    const start_node = &analyzed.func.start_node;
    var round_num: u32 = 0;

    try callstack.put(name, {});
    defer _ = callstack.remove(name);

    // Initialize the start node to have FnInput for all its arguments.
    var fninput_set: cfg_def.Set(cfg_def.SourceState) = .init(gpa);
    defer fninput_set.deinit();
    try fninput_set.put(.{ .FnInput = {} }, {});
    for (analyzed.func.decl_params) |param| {
        try start_node.*.out.sources.put(param, try fninput_set.clone());
    }

    var changed: bool = true;
    var stack: std.ArrayList(*cfg_def.CFGNode) = .empty;
    defer stack.deinit(gpa);
    while (changed) {
        // Perform a depth-first search.
        changed = false;
        try stack.append(gpa, start_node.*);
        while (stack.pop()) |node| {
            // We can skip if it has already been visited this round.
            if (node.round_visited == round_num and node.annotations_initialized) {
                continue;
            }
            const changed_round = try update_block(node, parsed, callstack, gpa);
            changed |= changed_round;
            node.round_visited = round_num;
            for (node.nodes_out) |child| {
                try stack.append(gpa, child);
            }
        }
        round_num += 1;
    }
    analyzed.analysis = analyzed.func.return_node.out;
    return &analyzed.func.return_node.out;
}

// The return value indicates whether anything was changed.
// If this function errors out, that indicates that the analysis
// of the program is beyond the capabilities of this tool.
pub fn update_block(
    block: *cfg_def.CFGNode,
    parsed: *cfg_def.ParsedCFG,
    // We do not permit duplicates here, so we check on fncall to ensure we don't clobber.
    callstack: *cfg_def.Set(cfg_def.CanonicalToken),
    gpa: std.mem.Allocator,
) ParseError!bool {
    // The Start block doesn't need any updates.
    if (block.kind == .Start) {
        return false;
    }
    var changed: bool = false;
    // Gather and merge all input source/sink lists.
    var sources_in = try merge_dicts_in(cfg_def.SourceState, block.nodes_in, gpa);
    var sinks_in = try merge_dicts_in(cfg_def.SinkState, block.nodes_in, gpa);
    var sources_out = try cfg_def.recursive_clone(cfg_def.SourceState, &sources_in, gpa);
    var sinks_out = try cfg_def.recursive_clone(cfg_def.SinkState, &sinks_in, gpa);

    // Apparently the comptime evaluation gets to be a bit much.
    @setEvalBranchQuota(2000);
    defer cfg_def.recursive_deinit(cfg_def.SourceState, &sources_in);
    defer cfg_def.recursive_deinit(cfg_def.SourceState, &sources_out);
    defer cfg_def.recursive_deinit(cfg_def.SinkState, &sinks_in);
    defer cfg_def.recursive_deinit(cfg_def.SinkState, &sinks_out);

    if (block.mem_op == null) {
        // Easy! Leave them as-is.
    } else {
        switch (block.mem_op.?) {
            .Allocation => |*val| {
                // Mark that variable as unconditionally allocated by that allocator.
                try set_unconditional(cfg_def.SourceState, &sources_out, val.result, .{
                    .Alloc = val.allocator,
                }, gpa);
                if (sinks_out.getPtr(val.result)) |var_sinks| {
                    var_sinks.deinit();
                    _ = sinks_out.remove(val.result);
                }
            },
            .Deallocation => |*val| {
                // Mark that variable as unconditionally deallocated.
                try set_unconditional(cfg_def.SinkState, &sinks_out, val.variable, .{
                    .Dealloc = val.allocator,
                }, gpa);
            },
            .DeinitExplicit => |*val| {
                try set_unconditional(cfg_def.SinkState, &sinks_out, val.variable, .{
                    .Dealloc = val.allocator,
                }, gpa);
            },
            .Deinit => |*val| {
                // It should have the same deallocation state as allocation state.
                if (sources_out.getPtr(val.variable)) |var_sources| {
                    var var_sinks = try sinks_out.getOrPut(val.variable);
                    if (!var_sinks.found_existing) {
                        var_sinks.value_ptr.* = .init(gpa);
                    }
                    var_sinks.value_ptr.clearAndFree();
                    try source2sink(var_sources, var_sinks.value_ptr);
                } else {
                    return ParseError.UninitVarDeinited;
                }
            },
            .FunctionCall => |*val| {
                // Check: we disallow recursion.
                if (callstack.contains(val.function_name)) {
                    return ParseError.RecursiveCall;
                }
                // Okay, analyze the function and prepare to merge.
                var annotations = try analyze_function_inner(val.function_name, parsed, callstack, gpa);
                const func = parsed.functions.getPtr(val.function_name).?;
                const arg_map = try lists_to_hashmap(cfg_def.CanonicalToken, func.func.decl_params, val.arguments, gpa);

                // Loop over all the variables, and integrate them in.
                var var_iter = annotations.sinks.iterator();
                var_loop: while (var_iter.next()) |v| {
                    const translated: cfg_def.CanonicalToken = trans_if: {
                        if (arg_map.contains(v.key_ptr.*)) {
                            // If it was one of the arguments, it has a translation.
                            break :trans_if arg_map.get(v.key_ptr.*).?;
                        } else {
                            continue :var_loop;
                        }
                    };
                    // Okay, so now we have the variable translated.
                    var outer_varstate = try sinks_out.getOrPut(translated);
                    if (!outer_varstate.found_existing) {
                        outer_varstate.value_ptr.* = .init(gpa);
                    } else if (!v.value_ptr.contains(.{ .Uninit = {} })) {
                        // If the inner state array couldn't have been left unchanged,
                        // clear the outer one.
                        outer_varstate.value_ptr.clearAndFree();
                    }
                    // Alright, now we copy and translate all the sink states.
                    // We better hope the allocators are all passed in.
                    var state_iter = v.value_ptr.keyIterator();
                    state_loop: while (state_iter.next()) |state| {
                        const trans_state: cfg_def.SinkState = switch (state.*) {
                            .Uninit => {
                                continue :state_loop;
                            },
                            .FnInput => {
                                // Do a direct source-sink translation. The source set is
                                // already translated, so we don't need to use arg_map.
                                if (sources_out.getPtr(translated)) |var_sources| {
                                    try source2sink(var_sources, outer_varstate.value_ptr);
                                }
                                continue :state_loop;
                            },
                            .Maybe => |alloc| .{ .Maybe = arg_map.get(alloc) orelse {
                                return ParseError.LocalScopeAllocator;
                            } },
                            .Dealloc => |alloc| .{ .Dealloc = arg_map.get(alloc) orelse {
                                return ParseError.LocalScopeAllocator;
                            } },
                        };
                        // Append our translated state into the translated variable's set.
                        try outer_varstate.value_ptr.put(trans_state, {});
                    }
                }
                // For sources, we only need to worry about the return value. Zig
                // doesn't pass by reference unless you make an &, which we don't
                // support yet.
                if (val.result != null and func.func.return_tok != null) {
                    const inner_tok = func.func.return_tok.?;
                    const outer_tok = val.result.?;
                    // Check: do we have annotations?
                    if (annotations.sources.get(inner_tok)) |inner_sources| {
                        // Get or create the outer sources dict.
                        var outer_sources = try sources_out.getOrPut(outer_tok);
                        if (!outer_sources.found_existing) {
                            outer_sources.value_ptr.* = .init(gpa);
                        }
                        // Clear it if we don't have .FnInput as an option.
                        // I'm pretty sure we shouldn't do this.
                        // if (!inner_sources.contains(.{ .FnInput = {} })) {
                        //     outer_sources.value_ptr.clearAndFree();
                        // }
                        // Alright, translate the rest!
                        // Again, we hope the allocators are all passed in.
                        var state_iter = inner_sources.keyIterator();
                        state_loop: while (state_iter.next()) |state| {
                            const trans_state: cfg_def.SourceState = switch (state.*) {
                                .Uninit => .{ .Uninit = {} },
                                .FnInput => fninput: {
                                    // Check which function input variable this is.
                                    if (arg_map.get(inner_tok)) |translated| {
                                        if (sources_out.getPtr(translated)) |var_sources| {
                                            var source_it = var_sources.keyIterator();
                                            while (source_it.next()) |source| {
                                                switch (source.*) {
                                                    .FnInput => {
                                                        // TODO track arg index to trace this?
                                                        return ParseError.NoPtrAlias;
                                                    },
                                                    else => {
                                                        break :fninput source.*;
                                                    },
                                                }
                                            }
                                        }
                                    }
                                    continue :state_loop;
                                },
                                .Maybe => |alloc| .{ .Maybe = arg_map.get(alloc) orelse {
                                    return ParseError.LocalScopeAllocator;
                                } },
                                .Alloc => |alloc| .{ .Alloc = arg_map.get(alloc) orelse {
                                    return ParseError.LocalScopeAllocator;
                                } },
                            };
                            // Append our translated state into the translated variable's set.
                            try outer_sources.value_ptr.put(trans_state, {});
                        }
                    }
                }
            },
        }
    }
    if (!block.annotations_initialized) {
        block.annotations_initialized = true;
        changed = true;
    } else {
        changed = !(cfg_def.recursive_eq(cfg_def.SourceState, &sources_in, &block.in.sources) and
            cfg_def.recursive_eq(cfg_def.SourceState, &sources_out, &block.out.sources) and
            cfg_def.recursive_eq(cfg_def.SinkState, &sinks_in, &block.in.sinks) and
            cfg_def.recursive_eq(cfg_def.SinkState, &sinks_out, &block.out.sinks));
    }
    if (changed) {
        // Even if they're uninitialized, empty hashmaps needed an allocator.
        cfg_def.recursive_deinit(cfg_def.SourceState, &block.in.sources);
        cfg_def.recursive_deinit(cfg_def.SourceState, &block.out.sources);
        cfg_def.recursive_deinit(cfg_def.SinkState, &block.in.sinks);
        cfg_def.recursive_deinit(cfg_def.SinkState, &block.out.sinks);
        block.in.sources = try cfg_def.recursive_clone(cfg_def.SourceState, &sources_in, gpa);
        block.out.sources = try cfg_def.recursive_clone(cfg_def.SourceState, &sources_out, gpa);
        block.in.sinks = try cfg_def.recursive_clone(cfg_def.SinkState, &sinks_in, gpa);
        block.out.sinks = try cfg_def.recursive_clone(cfg_def.SinkState, &sinks_out, gpa);
    }
    return changed;
}

pub fn lists_to_hashmap(
    comptime T: type,
    from: []const T,
    to: []const T,
    gpa: std.mem.Allocator,
) !std.AutoHashMap(T, T) {
    var map = std.AutoHashMap(T, T).init(gpa);
    for (from, to) |k, v| {
        try map.put(k, v);
    }
    return map;
}

// For handling bare "Deinit"s or sink "FnInput"s
fn source2sink(
    var_sources: *cfg_def.Set(cfg_def.SourceState),
    var_sinks: *cfg_def.Set(cfg_def.SinkState),
) !void {
    var source_it = var_sources.keyIterator();
    source_loop: while (source_it.next()) |source| {
        const sink: cfg_def.SinkState = switch (source.*) {
            .Uninit => {
                continue :source_loop;
            },
            .Maybe => .{
                .Maybe = source.Maybe,
            },
            .Alloc => .{
                .Dealloc = source.Alloc,
            },
            .FnInput => .{ .FnInput = {} },
        };
        try var_sinks.put(sink, {});
    }
}

fn set_unconditional(
    comptime T: type,
    set_dict: *cfg_def.SetDict(T),
    key: cfg_def.CanonicalToken,
    value: T,
    gpa: std.mem.Allocator,
) !void {
    var var_entry = try set_dict.getOrPut(key);
    if (!var_entry.found_existing) {
        var_entry.value_ptr.* = .init(gpa);
    }
    var_entry.value_ptr.clearAndFree();
    try var_entry.value_ptr.put(value, {});
}

fn merge_dicts_in(
    comptime T: type,
    nodes: []*cfg_def.CFGNode,
    gpa: std.mem.Allocator,
) !cfg_def.SetDict(T) {
    var retval = cfg_def.SetDict(T).init(gpa);
    // Track which keys we've seen.
    var keys = cfg_def.Set(cfg_def.CanonicalToken).init(gpa);
    defer keys.deinit();
    // For each input node...
    for (nodes) |ptr| {
        // For each variable referenced in each input node...
        var it = if (T == cfg_def.SourceState) ptr.out.sources.iterator() else if (T == cfg_def.SinkState) ptr.out.sinks.iterator() else {
            // This is a statically-computable branch, so this will happen on the first node.
            // retval will still be empty, so we can just return.
            return retval;
        };
        while (it.next()) |var_entry| {
            try keys.put(var_entry.key_ptr.*, {});
            var combined_var_entry = try retval.getOrPut(var_entry.key_ptr.*);
            if (!combined_var_entry.found_existing) {
                combined_var_entry.value_ptr.* = .init(gpa);
            }
            // For each possible state that variable could be in...
            var elem_it = var_entry.value_ptr.keyIterator();
            while (elem_it.next()) |elem| {
                // Make sure we include that state.
                try combined_var_entry.value_ptr.put(elem.*, {});
            }
        }
    }
    // Alright, now we have everything except the implicit Uninits.
    // Loop over all the variables we've seen, and insert the implicit bits.
    var key_it = keys.keyIterator();
    keyloop: while (key_it.next()) |varname| {
        // If we already have uninit for this variable, don't bother looking for implicit ones.
        if (retval.getPtr(varname.*).?.contains(.Uninit)) {
            continue :keyloop;
        }
        // Check if the relevant variable is missing from any input node's dictionary.
        nodeloop: for (nodes) |ptr| {
            // Skip nodes that haven't been initialized, they're empty for other reasons.
            if (!ptr.annotations_initialized) {
                continue :nodeloop;
            }
            // Get the relevant dictionary from the node, check if it has the variable, and add Uninit if it doesn't.
            if (!(if (T == cfg_def.SourceState) ptr.out.sources else if (T == cfg_def.SinkState) ptr.out.sinks else {
                // We would've returned on the first node. If there were no nodes, we wouldn't have any keys
                // to iterate over. In either case, we can't be here.
                unreachable;
                // Okay, now that we've gotten the right dict, does it have our variable?
            }).contains(varname.*)) {
                // We found an implicit Uninit! Make it so.
                try retval.getPtr(varname.*).?.put(.Uninit, {});
                // No need to keep looking now.
                break :nodeloop;
            }
        }
    }
    return retval;
}
