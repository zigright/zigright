const std = @import("std");
const cfg_def = @import("cfg_def.zig");
const rules = @import("rules.zig");
const expect = std.testing.expect;

var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
const gpa = debug_alloc.allocator();

test "passthrough" {
    // One node in, check outputs are the same as inputs
    var parent: cfg_def.CFGNode = .init(gpa);
    var child: cfg_def.CFGNode = .init(gpa);
    defer {
        parent.deinit();
        child.deinit();
    }
    parent.ast_nodes = &[_]std.zig.Ast.Node.Index{};
    child.ast_nodes = &[_]std.zig.Ast.Node.Index{};
    parent.nodes_in = &[_]*cfg_def.CFGNode{};
    var parent_outs = [_]*cfg_def.CFGNode{&child};
    parent.nodes_out = &parent_outs;
    var child_ins = [_]*cfg_def.CFGNode{&parent};
    child.nodes_in = &child_ins;
    child.nodes_out = &[_]*cfg_def.CFGNode{};
    parent.annotations_initialized = true;

    var map: cfg_def.Set(cfg_def.SourceState) = .init(gpa);
    try map.put(.{ .Alloc = 3 }, {});
    try map.put(.{ .FnInput = {} }, {});
    try parent.out.sources.put(1, map);
    var parsed: cfg_def.ParsedCFG = undefined;
    var callstack: cfg_def.Set(cfg_def.CanonicalToken) = .init(gpa);

    // The first update should change it.
    const changed = try rules.update_block(&child, &parsed, &callstack, gpa);
    try expect(changed);
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &parent.out.sources, &child.out.sources));
    try expect(cfg_def.recursive_eq(cfg_def.SinkState, &parent.out.sinks, &child.out.sinks));
    // The second update should not change it.
    const changed2 = try rules.update_block(&child, &parsed, &callstack, gpa);
    try expect(!changed2);
    // std.debug.print("{any}\n{any}\n", .{ child.in, child.out });
}

test "implicit uninit" {
    // Two nodes in, one without anything specified for a variable.
    var parent1: cfg_def.CFGNode = .init(gpa);
    var parent2: cfg_def.CFGNode = .init(gpa);
    var child: cfg_def.CFGNode = .init(gpa);
    defer {
        parent1.deinit();
        parent2.deinit();
        child.deinit();
    }
    parent1.ast_nodes = &[_]std.zig.Ast.Node.Index{};
    parent2.ast_nodes = &[_]std.zig.Ast.Node.Index{};
    child.ast_nodes = &[_]std.zig.Ast.Node.Index{};
    parent1.nodes_in = &[_]*cfg_def.CFGNode{};
    parent2.nodes_in = &[_]*cfg_def.CFGNode{};
    var parent_outs = [_]*cfg_def.CFGNode{&child};
    parent1.nodes_out = &parent_outs;
    parent2.nodes_out = &parent_outs;
    var child_ins = [_]*cfg_def.CFGNode{ &parent1, &parent2 };
    child.nodes_in = &child_ins;
    child.nodes_out = &[_]*cfg_def.CFGNode{};
    parent1.annotations_initialized = true;
    parent2.annotations_initialized = true;

    var map: cfg_def.Set(cfg_def.SourceState) = .init(gpa);
    try map.put(.{ .Alloc = 3 }, {});
    try map.put(.{ .FnInput = {} }, {});
    try parent1.out.sources.put(1, map);
    var parsed: cfg_def.ParsedCFG = undefined;
    var callstack: cfg_def.Set(cfg_def.CanonicalToken) = .init(gpa);

    // The first update should change it.
    const changed = try rules.update_block(&child, &parsed, &callstack, gpa);
    try expect(changed);
    try expect(!cfg_def.recursive_eq(cfg_def.SourceState, &parent1.out.sources, &child.out.sources));
    try expect(child.out.sources.get(1).?.contains(.{ .Uninit = {} }));
    try expect(child.out.sources.get(1).?.contains(.{ .Alloc = 3 }));
    try expect(child.out.sources.get(1).?.contains(.{ .FnInput = {} }));
}

// test "function call" {
//     //
// }

// test ""
