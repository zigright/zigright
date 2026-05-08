const std = @import("std");
const cfg_def = @import("cfg_def.zig");
const rules = @import("rules.zig");
const expect = std.testing.expect;

var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
const gpa = debug_alloc.allocator();

test "allocation" {
    //
    // fn foo(gpa: std.mem.Allocator) void {
    // var f = gpa.alloc();
    // <DUMMY_STATEMENT_THAT_DOESNT_INVOLVE_MEM>
    // }
    //
    //
    // Two nodes, check if allocation propagates
    var parent: cfg_def.CFGNode = .init(gpa);
    var child: cfg_def.CFGNode = .init(gpa);
    defer {
        parent.deinit();
        child.deinit();
    }
    // Dummy vars
    parent.ast_nodes = &[_]std.zig.Ast.Node.Index{};
    child.ast_nodes = &[_]std.zig.Ast.Node.Index{};
    // Parent doesn't have any inputs
    parent.nodes_in = &[_]*cfg_def.CFGNode{};
    var parent_outs = [_]*cfg_def.CFGNode{&child};
    parent.nodes_out = &parent_outs;
    var child_ins = [_]*cfg_def.CFGNode{&parent};
    child.nodes_in = &child_ins;
    // Child doesn't have any outputs
    child.nodes_out = &[_]*cfg_def.CFGNode{};
    // var f = gpa.alloc();
    parent.mem_op = .{ .Allocation = .{ .allocator = 3, .result = 14 } };

    // Dummy vars to satisfy the function signature
    var parsed: cfg_def.ParsedCFG = undefined;
    var callstack: cfg_def.Set(cfg_def.CanonicalToken) = .init(gpa);

    // These should be null as we didn't initialize anything
    try expect(parent.in.sources.get(14) == null);
    try expect(parent.out.sources.get(14) == null);
    var changed = try rules.update_block(&parent, &parsed, &callstack, gpa);
    try expect(changed);
    try expect(parent.in.sources.get(14) == null);
    try expect(parent.out.sources.get(14).?.contains(.{ .Alloc = 3 }) and parent.out.sources.get(14).?.count() == 1);

    try expect(child.in.sources.get(14) == null);
    try expect(child.out.sources.get(14) == null);
    changed = try rules.update_block(&child, &parsed, &callstack, gpa);
    try expect(changed);

    // Child inherits
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &parent.out.sources, &child.in.sources));
    // Child propogates without change
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &child.in.sources, &child.out.sources));

    // Child inherits
    try expect(cfg_def.recursive_eq(cfg_def.SinkState, &parent.out.sinks, &child.in.sinks));
    // Child propogates without change
    try expect(cfg_def.recursive_eq(cfg_def.SinkState, &parent.out.sinks, &child.out.sinks));

    // The second update should not change it.
    changed = try rules.update_block(&child, &parsed, &callstack, gpa);
    try expect(!changed);
}
