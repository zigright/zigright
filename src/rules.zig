fn analyze_function(
    name: cfg_def.CanonicalToken,
    parsed: *cfg_def.ParsedCFG,
    callstack: *cfg_def.Set(cfg_def.CanonicalToken),
    gpa: std.mem.Allocator,
) !*cfg_def.BlockFlow {
    const analyzed = parsed.functions.getPtr(name).?;
    if (analyzed.analysis != null) {
        return &analyzed.analysis.?;
    }
}

// The return value indicates whether anything was changed.
// If this function errors out, that indicates that the analysis
// of the program is beyond the capabilities of this tool.
fn update_block(
    block: *cfg_def.CFGNode,
    parsed: *cfg_def.ParsedCFG,
    // We do not permit duplicates here, so we check on fncall to ensure we don't clobber.
    callstack: *cfg_def.Set(cfg_def.CanonicalToken),
    gpa: std.mem.Allocator,
) !bool {
    // The Start block doesn't need any updates.
    if (block.kind == .Start) {
        return false;
    }
    var changed: bool = false;
    // Gather and merge all input source/sink lists.
    const sources_in = merge_dicts_in(cfg_def.SourceState, block.nodes_in, gpa);
    const sinks_in = merge_dicts_in(cfg_def.SinkState, block.nodes_in, gpa);
    var sources_out = recursive_clone(cfg_def.SourceState, sources_in, gpa);
    var sinks_out = recursive_clone(cfg_def.SinkState, sinks_in, gpa);
    defer recursive_deinit(cfg_def.SourceState, sources_in);
    defer recursive_deinit(cfg_def.SourceState, sources_out);
    defer recursive_deinit(cfg_def.SinkState, sinks_in);
    defer recursive_deinit(cfg_def.SinkState, sinks_out);

    if (block.mem_op == null) {
        // Easy! Leave them as-is.
    } else {
        switch (block.mem_op.?) {
            .Allocation => |*val| {
                // Mark that variable as unconditionally allocated by that allocator.
                set_unconditional(cfg_def.SourceState, &sources_out, val.result, .{
                    .Alloc = val.allocator,
                }, gpa);
            },
            .Deallocation => |*val| {
                // Mark that variable as unconditionally deallocated.
                set_unconditional(cfg_def.SinkDict, &sinks_out, val.variable, .{
                    .Dealloc = val.allocator,
                }, gpa);
            },
            .DeinitExplicit => |*val| {
                set_unconditional(cfg_def.SinkDict, &sinks_out, val.variable, .{
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
                    source2sink(var_sources, var_sinks.value_ptr);
                } else {
                    return error{UninitVarDeinited};
                }
            },
            .FunctionCall => |*val| {
                // Check: we disallow recursion.
                if (callstack.contains(val.function_name)) {
                    return error{RecursiveCall};
                }
                // Okay, analyze the function and prepare to merge.
                var annotations = try analyze_function(val.function_name, parsed, callstack, gpa);
                const func = parsed.functions.getPtr(val.function_name).?;
                const arg_map = lists_to_hashmap(cfg_def.CanonicalToken, func.func.arguments, val.arguments, gpa);

                // Loop over all the variables, and integrate them in.
                var var_iter = annotations.sinks.iterator();
                var_loop: while (var_iter.next()) |v| {
                    const translated: cfg_def.CanonicalToken =
                        if (arg_map.contains(v.key_ptr.*)) {
                            // If it was one of the arguments, it has a translation.
                            break arg_map.get(v.key_ptr.*).?;
                        } else {
                            continue :var_loop;
                        };
                    // Okay, so now we have the variable translated.
                    var outer_varstate = try sinks_out.getOrPut(translated);
                    if (!outer_varstate.found_existing) {
                        outer_varstate.value_ptr.* = .init(gpa);
                    } else if (!v.value_ptr.contains(.{.Uninit})) {
                        // If the inner state array couldn't have been left unchanged,
                        // clear the outer one.
                        outer_varstate.value_ptr.clearAndFree();
                    }
                    // Alright, now we copy and translate all the allocation states.
                    // We better hope the allocators are all passed in.
                    var state_iter = v.value_ptr.keyIterator();
                    state_loop: while (state_iter.next()) |state| {
                        const trans_state: cfg_def.SourceState = switch (state.*) {
                            .Uninit => {
                                continue :state_loop;
                            },
                            .FnInput => {
                                continue :state_loop;
                            },
                            .Maybe => |alloc| .{ .Maybe = arg_map.get(alloc) orelse {
                                return error{LocalScopeAllocator};
                            } },
                            .Dealloc => |alloc| .{ .Dealloc = arg_map.get(alloc) orelse {
                                return error{LocalScopeAllocator};
                            } },
                        };
                        // Append our translated state into the translated variable's set.
                        outer_varstate.value_ptr.put(trans_state, {});
                    }
                }
                // For sources, we only need to worry about the return value. Zig
                // doesn't pass by reference unless you make an &, which we don't
                // support yet.
                if (val.result != null and func.func.return_tok != null) {
                    // Check: do we have annotations?
                    if (annotations.sources.contains(func.func.return_tok.?)) {
                        var var_sources = try sources_out.getOrPut(val.result.?);
                        if (!var_sources.found_existing) {
                            var_sources.value_ptr.* = .init(gpa);
                        }
                        // Great! Translate that.
                        var_sources.put(arg_map.get(annotations.sources.get(func.func.return_tok.?).?) orelse {
                            return error{LocalScopeAllocator};
                        }, {});
                    }
                }
            },
        }
    }
    if (!block.annotations_initialized) {
        block.annotations_initialized = true;
        changed = true;
    } else {
        changed = !(recursive_eq(cfg_def.SourceState, sources_in, block.sources_in) and
            recursive_eq(cfg_def.SourceState, sources_out, block.sources_out) and
            recursive_eq(cfg_def.SinkState, sinks_in, block.sinks_in) and
            recursive_eq(cfg_def.SinkState, sinks_out, block.sinks_out));
    }
    if (changed) {
        // Even if they're uninitialized, empty hashmaps needed an allocator.
        recursive_deinit(cfg_def.SourceState, block.sources_in);
        recursive_deinit(cfg_def.SourceState, block.sources_out);
        recursive_deinit(cfg_def.SinkState, block.sinks_in);
        recursive_deinit(cfg_def.SinkState, block.sinks_out);
        block.sources_in = recursive_clone(cfg_def.SourceState, sources_in, gpa);
        block.sources_out = recursive_clone(cfg_def.SourceState, sources_out, gpa);
        block.sinks_in = recursive_clone(cfg_def.SinkState, sinks_in, gpa);
        block.sinks_out = recursive_clone(cfg_def.SinkState, sinks_out, gpa);
    }
    return changed;
}

fn lists_to_hashmap(comptime T: type, from: []T, to: []T, gpa: std.mem.Allocator) std.AutoHashMap(T, T) {
    var map = std.AutoHashMap(T, T).init(gpa);
    for (from, to) |k, v| {
        map.put(k, v);
    }
    return map;
}

// For handling bare "deinit"s
fn source2sink(
    var_sources: *cfg_def.Set(cfg_def.SourceState),
    var_sinks: *cfg_def.Set(cfg_def.SinkState),
) void {
    var source_it = var_sources.keyIterator();
    source_loop: while (source_it.next()) |source| {
        const sink: cfg_def.SinkState = switch (source) {
            .Uninit => {
                continue :source_loop;
            },
            .Maybe => .{
                .Maybe = source.Maybe,
            },
            .Alloc => .{
                .Dealloc = source.Alloc,
            },
            .FnInput => .{.FnInput},
        };
        var_sinks.put(sink, {});
    }
}

fn set_unconditional(
    comptime T: type,
    set_dict: *cfg_def.SetDict(T),
    key: cfg_def.CanonicalToken,
    value: T,
    gpa: std.mem.Allocator,
) void {
    var var_entry = try set_dict.getOrPut(key);
    if (!var_entry.found_existing) {
        var_entry.value_ptr.* = .init(gpa);
    }
    var_entry.value_ptr.clearAndFree();
    var_entry.value_ptr.put(value, {});
}

fn recursive_clone(
    comptime T: type,
    set_dict: *cfg_def.SetDict(T),
    gpa: std.mem.Allocator,
) cfg_def.SetDict(T) {
    var new = cfg_def.SetDict(T).init(gpa);
    var it = set_dict.iterator();
    while (it.next()) |entry| {
        new.put(entry.key_ptr.*, entry.value_ptr.cloneWithAllocator(gpa));
    }
    return new;
}

fn recursive_deinit(comptime T: type, set_dict: cfg_def.SetDict(T)) void {
    var it = set_dict.valueIterator();
    while (it.next()) |set| {
        set.deinit();
    }
    set_dict.deinit();
}

fn recursive_eq(comptime T: type, sd1: *cfg_def.SetDict(T), sd2: *cfg_def.SetDict(T)) bool {
    if (sd1.count() != sd2.count()) {
        return false;
    }
    var it1 = sd1.iterator();
    while (it1.next()) |entry1| {
        const set2 = sd2.get(entry1.key_ptr.*);
        if (set2 == null or set2.?.count() != entry1.value_ptr.count()) {
            return false;
        }
        var it_set1 = entry1.value_ptr.keyIterator();
        while (it_set1.next()) |state| {
            if (!set2.?.contains(state.*)) {
                return false;
            }
        }
    }
    return true;
}

fn merge_dicts_in(
    comptime T: type,
    nodes: []*cfg_def.CFGNode,
    gpa: std.mem.Allocator,
) cfg_def.SetDict(T) {
    var retval = cfg_def.SetDict(T).init(gpa);
    // Track which keys we've seen.
    var keys = cfg_def.Set(cfg_def.CanonicalToken).init(gpa);
    defer keys.deinit();
    // For each input node...
    for (nodes) |ptr| {
        // For each variable referenced in each input node...
        var it = if (T == cfg_def.SourceState) ptr.sources_out.iterator() else if (T == cfg_def.SinkState) ptr.sinks_out.iterator() else {
            // This is a statically-computable branch, so this will happen on the first node.
            // retval will still be empty, so we can just return.
            return retval;
        };
        while (it.next()) |var_entry| {
            keys.put(var_entry.key_ptr.*, {});
            var combined_var_entry = try retval.getOrPut(var_entry.key_ptr.*);
            if (!combined_var_entry.found_existing) {
                combined_var_entry.value_ptr.* = .init(gpa);
            }
            // For each possible state that variable could be in...
            var elem_it = var_entry.value_ptr.keyIterator();
            while (elem_it.next()) |elem| {
                // Make sure we include that state.
                combined_var_entry.value_ptr.put(elem.*, {});
            }
        }
    }
    // Alright, now we have everything except the implicit Uninits.
    // Loop over all the variables we've seen, and insert the implicit bits.
    var key_it = keys.keyIterator();
    keyloop: while (key_it.next()) |varname| {
        // If we already have uninit for this variable, don't bother looking for implicit ones.
        if (retval.getPtr(varname).?.contains(.Uninit)) {
            continue :keyloop;
        }
        // Check if the relevant variable is missing from any input node's dictionary.
        nodeloop: for (nodes) |ptr| {
            // Skip nodes that haven't been initialized, they're empty for other reasons.
            if (!ptr.annotations_initialized) {
                continue :nodeloop;
            }
            // Get the relevant dictionary from the node, check if it has the variable, and add Uninit if it doesn't.
            if (!(if (T == cfg_def.SourceState) ptr.sources_out else if (T == cfg_def.SinkState) ptr.sinks_out else {
                // We would've returned on the first node. If there were no nodes, we wouldn't have any keys
                // to iterate over. In either case, we can't be here.
                unreachable;
                // Okay, now that we've gotten the right dict, does it have our variable?
            }).contains(varname.*)) {
                // We found an implicit Uninit! Make it so.
                retval.getPtr(varname).?.put(.Uninit, {});
                // No need to keep looking now.
                break :nodeloop;
            }
        }
    }
    return retval;
}

const cfg_def = @import("cfg_def.zig");
const std = @import("std");
