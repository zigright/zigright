const std = @import("std");
const cfg_def = @import("cfg_def.zig");
const rules = @import("rules.zig");
const analysis = @import("analysis.zig");
const util = @import("util.zig");
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

test "deallocation" {
    //
    // fn foo(v: anytype, gpa: std.mem.Allocator) void {
    // gpa.dealloc(v);
    // v = v + 1;
    // }
    // Two nodes, check if dealloc propagates
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

    parent.mem_op = .{ .Deallocation = .{ .variable = 3, .allocator = 7 } };

    // Dummy vars to satisfy the function signature
    var parsed: cfg_def.ParsedCFG = undefined;
    var callstack: cfg_def.Set(cfg_def.CanonicalToken) = .init(gpa);

    // These should be null as we didn't initialize anything
    try expect(parent.in.sinks.get(3) == null);
    try expect(parent.out.sinks.get(3) == null);
    var changed = try rules.update_block(&parent, &parsed, &callstack, gpa);
    try expect(changed);
    try expect(parent.in.sinks.get(3) == null);
    try expect(parent.out.sinks.get(3).?.contains(.{ .Dealloc = 7 }) and parent.out.sinks.get(3).?.count() == 1);

    try expect(child.in.sinks.get(3) == null);
    try expect(child.out.sinks.get(3) == null);
    changed = try rules.update_block(&child, &parsed, &callstack, gpa);
    try expect(changed);

    // Child inherits
    try expect(cfg_def.recursive_eq(cfg_def.SinkState, &parent.out.sinks, &child.in.sinks));
    // Child propogates without change
    try expect(cfg_def.recursive_eq(cfg_def.SinkState, &child.in.sinks, &child.out.sinks));

    // Child inherits
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &parent.out.sources, &child.in.sources));
    // Child propogates without change
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &parent.out.sources, &child.out.sources));

    // The second update should not change it.
    changed = try rules.update_block(&child, &parsed, &callstack, gpa);
    try expect(!changed);
}

fn CFGNodeCreate() cfg_def.CFGNode {
    var ret: cfg_def.CFGNode = .init(gpa);
    ret.ast_nodes = &[_]std.zig.Ast.Node.Index{};
    ret.nodes_in = &[_]*cfg_def.CFGNode{};
    ret.nodes_out = &[_]*cfg_def.CFGNode{};
    return ret;
}

fn addChild(target: *cfg_def.CFGNode, childToBeAdded: *cfg_def.CFGNode) !void {
    if (target.nodes_out.len > 0) {
        var nodes_out = try gpa.alloc(*cfg_def.CFGNode, target.nodes_out.len + 1);
        @memcpy(nodes_out, target.nodes_out);
        nodes_out[target.nodes_out.len] = childToBeAdded;
        gpa.free(target.nodes_out);
        target.nodes_out = nodes_out;
        return;
    } else {
        var nodes_out = try gpa.alloc(*cfg_def.CFGNode, 1);
        nodes_out[target.nodes_out.len] = childToBeAdded;
        target.nodes_out = nodes_out;
        return;
    }
}

fn addParent(target: *cfg_def.CFGNode, parentToBeAdded: *cfg_def.CFGNode) !void {
    if (target.nodes_in.len > 0) {
        var nodes_in = try gpa.alloc(*cfg_def.CFGNode, target.nodes_in.len + 1);
        @memcpy(nodes_in, target.nodes_in);
        nodes_in[target.nodes_in.len] = parentToBeAdded;
        gpa.free(target.nodes_in);
        target.nodes_in = nodes_in;
        return;
    } else {
        var nodes_in = try gpa.alloc(*cfg_def.CFGNode, 1);
        nodes_in[target.nodes_in.len] = parentToBeAdded;
        target.nodes_in = nodes_in;
        return;
    }
}

fn connectNodes(predecessor: *cfg_def.CFGNode, successor: *cfg_def.CFGNode) !void {
    try addChild(predecessor, successor);
    try addParent(successor, predecessor);
}

test "deinit" {
    //
    // fn foo(v: anytype, gpa: std.mem.Allocator) void {
    // v = .init(gpa);
    // v.deinit();
    // v = v + 1;
    // }
    // Two nodes, check if dealloc propagates
    var node1 = CFGNodeCreate();
    var node2 = CFGNodeCreate();
    var node3 = CFGNodeCreate();

    defer {
        node1.deinit();
        node2.deinit();
        node3.deinit();
    }

    try connectNodes(&node1, &node2);
    try connectNodes(&node2, &node3);

    node1.mem_op = .{ .Allocation = .{ .allocator = 7, .result = 3 } };
    node2.mem_op = .{ .Deinit = .{ .variable = 3 } };

    // Dummy vars to satisfy the function signature
    var parsed: cfg_def.ParsedCFG = undefined;
    var callstack: cfg_def.Set(cfg_def.CanonicalToken) = .init(gpa);

    // These should be null as we didn't initialize anything
    try expect(node1.in.sinks.get(3) == null);
    try expect(node1.out.sinks.get(3) == null);
    try expect(node1.in.sources.get(3) == null);
    try expect(node1.out.sources.get(3) == null);

    var changed = try rules.update_block(&node1, &parsed, &callstack, gpa);
    try expect(changed);
    try expect(node1.in.sinks.get(3) == null);
    // Source should change
    try expect(node1.out.sources.get(3).?.contains(.{ .Alloc = 7 }) and node1.out.sources.get(3).?.count() == 1);

    try expect(node2.in.sinks.get(3) == null);
    try expect(node2.out.sinks.get(3) == null);
    changed = try rules.update_block(&node2, &parsed, &callstack, gpa);
    try expect(changed);
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &node1.out.sources, &node2.in.sources));
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &node2.in.sources, &node2.out.sources));
    // Update sink
    try expect(node2.out.sinks.get(3).?.contains(.{ .Dealloc = 7 }) and node2.out.sinks.get(3).?.count() == 1);

    changed = try rules.update_block(&node3, &parsed, &callstack, gpa);
    try expect(changed);
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &node2.out.sources, &node3.in.sources));
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &node3.in.sources, &node3.out.sources));

    try expect(cfg_def.recursive_eq(cfg_def.SinkState, &node2.out.sinks, &node3.in.sinks));
    try expect(cfg_def.recursive_eq(cfg_def.SinkState, &node3.in.sinks, &node3.out.sinks));
}

test "deinitExplicit" {
    // fn foo(v: anytype, gpa: std.mem.Allocator) void{
    // v.deinit(gpa);
    // v = v + 1;
    // }
    //
    var node1 = CFGNodeCreate();
    var node2 = CFGNodeCreate();
    defer {
        node1.deinit();
        node2.deinit();
    }

    try connectNodes(&node1, &node2);

    node1.mem_op = .{ .DeinitExplicit = .{ .variable = 3, .allocator = 7 } };

    var parsed: cfg_def.ParsedCFG = undefined;
    var callstack: cfg_def.Set(cfg_def.CanonicalToken) = .init(gpa);

    try expect(node1.in.sinks.get(3) == null);
    try expect(node1.in.sources.get(3) == null);
    try expect(node1.out.sinks.get(3) == null);
    try expect(node1.out.sources.get(3) == null);

    var changed = try rules.update_block(&node1, &parsed, &callstack, gpa);
    try expect(changed);
    try expect(node1.out.sinks.get(3).?.contains(.{ .Dealloc = 7 }) and node1.out.sinks.get(3).?.count() == 1);

    try expect(node2.in.sinks.get(3) == null);
    try expect(node2.in.sources.get(3) == null);
    try expect(node2.out.sinks.get(3) == null);
    try expect(node2.out.sources.get(3) == null);

    changed = try rules.update_block(&node2, &parsed, &callstack, gpa);
    try expect(changed);

    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &node1.out.sources, &node2.in.sources));
    try expect(cfg_def.recursive_eq(cfg_def.SourceState, &node2.in.sources, &node2.out.sources));
}

test "double free" {
    // fn foo(gpa: std.mem.Allocator) void  {
    // var bar = gpa.alloc();
    // gpa.free(bar);
    // gpa.free(bar);
    // }
    const fn_name: u32 = 1;
    var start = CFGNodeCreate();
    start.kind = .Start;
    var node1 = CFGNodeCreate();
    var node2 = CFGNodeCreate();
    var node3 = CFGNodeCreate();
    var end = CFGNodeCreate();
    end.kind = .Return;

    try connectNodes(&start, &node1);
    try connectNodes(&node1, &node2);
    try connectNodes(&node2, &node3);
    try connectNodes(&node3, &end);

    node1.mem_op = .{ .Allocation = .{ .allocator = 7, .result = 3 } };
    node2.mem_op = .{ .Deallocation = .{ .allocator = 7, .variable = 3 } };
    node3.mem_op = .{ .Deallocation = .{ .allocator = 7, .variable = 3 } };

    const parsedFn: cfg_def.ParsedFn = .{ .start_node = &start, .return_node = &end, .return_tok = null, .decl_params = &[_]u32{7} };
    const analyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = parsedFn };
    var parsed: cfg_def.ParsedCFG = .{ .functions = .init(gpa), .ast = undefined };
    try parsed.functions.put(fn_name, analyzedFn);

    _ = try rules.analyze_function(fn_name, &parsed, gpa);
    const alerts = try analysis.generate_alerts(fn_name, &parsed, gpa);
    //     try expect(alerts.len == 1);
    //     try expect(alerts[0].kind == .DoubleFree);
    //     try expect(alerts[0].variable == 3);
    for (alerts) |alert| {
        std.debug.print("{any}\n", .{alert});
    }
}

test "double alloc without free" {
    // fn foo(gpa: std.mem.Allocator) void  {
    // var bar = gpa.alloc();
    // bar = gpa.alloc();
    // gpa.free(bar);
    // }
    const fn_name: u32 = 1;
    var start = CFGNodeCreate();
    start.kind = .Start;
    var node1 = CFGNodeCreate();
    var node2 = CFGNodeCreate();
    var node3 = CFGNodeCreate();
    var end = CFGNodeCreate();
    end.kind = .Return;

    try connectNodes(&start, &node1);
    try connectNodes(&node1, &node2);
    try connectNodes(&node2, &node3);
    try connectNodes(&node3, &end);
    var statement1_ast = [_]std.zig.Ast.Node.Index{@enumFromInt(13)};
    node1.ast_nodes = &statement1_ast;
    var statement2_ast = [_]std.zig.Ast.Node.Index{@enumFromInt(22)};
    node2.ast_nodes = &statement2_ast;
    var statement3_ast = [_]std.zig.Ast.Node.Index{@enumFromInt(30)};
    node3.ast_nodes = &statement3_ast;

    node1.mem_op = .{ .Allocation = .{ .allocator = 3, .result = 14 } };
    node2.mem_op = .{ .Allocation = .{ .allocator = 3, .result = 14 } };
    node3.mem_op = .{ .Deallocation = .{ .allocator = 3, .variable = 14 } };

    const parsedFn: cfg_def.ParsedFn = .{ .start_node = &start, .return_node = &end, .return_tok = null, .decl_params = &[_]u32{3} };
    const analyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = parsedFn };
    var parsed: cfg_def.ParsedCFG = .{ .functions = .init(gpa), .ast = undefined };
    try parsed.functions.put(fn_name, analyzedFn);

    _ = try rules.analyze_function(fn_name, &parsed, gpa);
    const alerts = try analysis.generate_alerts(fn_name, &parsed, gpa);
    for (alerts) |alert| {
        std.debug.print("{any}\n", .{alert});
    }
    try expect(alerts.len == 1);
    try expect(alerts[0].kind == .MemoryLeakClobber);
    try expect(alerts[0].variable == 14);
}

test "alloc without free or return" {
    // fn foo(gpa: std.mem.Allocator) void  {
    // var bar = gpa.alloc();
    // DUMMY_STATEMENT_THAT_DOESNT_INVOLVE_MEM
    // }
    const fn_name: u32 = 1;
    var start = CFGNodeCreate();
    start.kind = .Start;
    var node1 = CFGNodeCreate();
    var node2 = CFGNodeCreate();
    var end = CFGNodeCreate();
    end.kind = .Return;

    try connectNodes(&start, &node1);
    try connectNodes(&node1, &node2);
    try connectNodes(&node2, &end);

    node1.mem_op = .{ .Allocation = .{ .allocator = 3, .result = 14 } };

    const parsedFn: cfg_def.ParsedFn = .{ .start_node = &start, .return_node = &end, .return_tok = null, .decl_params = &[_]u32{3} };
    const analyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = parsedFn };
    var parsed: cfg_def.ParsedCFG = .{ .functions = .init(gpa), .ast = undefined };
    try parsed.functions.put(fn_name, analyzedFn);

    _ = try rules.analyze_function(fn_name, &parsed, gpa);
    const alerts = try analysis.generate_alerts(fn_name, &parsed, gpa);
    for (alerts) |alert| {
        std.debug.print("{any}\n", .{alert});
    }
    try expect(alerts.len == 1);
    try expect(alerts[0].kind == .MemoryLeakDrop);
    try expect(alerts[0].variable == 14);
}

test "function call" {
    // fn foo(gpa: std.mem.Allocator) void  {
    // var bar = baz(gpa);
    // bar = bar + 1;
    // }
    //
    // fn baz(gpa: std.mem.Allocator) []u32 {
    // var ret = gpa.alloc();
    // return ret;
    // }
    const foo: u32 = 1;
    var foo_start = CFGNodeCreate();
    foo_start.kind = .Start;
    var foo_node1 = CFGNodeCreate();
    var foo_node2 = CFGNodeCreate();
    var foo_end = CFGNodeCreate();
    foo_end.kind = .Return;

    try connectNodes(&foo_start, &foo_node1);
    try connectNodes(&foo_node1, &foo_node2);
    try connectNodes(&foo_node2, &foo_end);

    const baz: u32 = 29;
    var baz_start = CFGNodeCreate();
    baz_start.kind = .Start;
    var baz_node1 = CFGNodeCreate();
    var baz_end = CFGNodeCreate();
    baz_end.kind = .Return;

    try connectNodes(&baz_start, &baz_node1);
    try connectNodes(&baz_node1, &baz_end);

    var args = [_]u32{3};
    foo_node1.mem_op = .{ .FunctionCall = .{ .result = 14, .arguments = &args, .function_name = baz } };

    baz_node1.mem_op = .{ .Allocation = .{ .result = 44, .allocator = 31 } };

    const fooParsedFn: cfg_def.ParsedFn = .{ .start_node = &foo_start, .return_node = &foo_end, .return_tok = null, .decl_params = &[_]u32{3} };
    const fooAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = fooParsedFn };

    const bazParsedFn: cfg_def.ParsedFn = .{ .start_node = &baz_start, .return_node = &baz_end, .return_tok = 44, .decl_params = &[_]u32{31} };
    const bazAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = bazParsedFn };

    var parsed: cfg_def.ParsedCFG = .{ .functions = .init(gpa), .ast = undefined };
    try parsed.functions.put(foo, fooAnalyzedFn);
    try parsed.functions.put(baz, bazAnalyzedFn);

    _ = try rules.analyze_function(foo, &parsed, gpa);
    const alerts = try analysis.generate_alerts(foo, &parsed, gpa);
    for (alerts) |alert| {
        std.debug.print("{any}\n", .{alert});
    }
    try expect(alerts.len == 1);
    try expect(alerts[0].kind == .MemoryLeakDrop);
    try expect(alerts[0].variable == 14);
}

test "function call free" {
    // fn foo(gpa: std.mem.Allocator) void  {
    // var bar = gpa.alloc();
    // baz(bar, gpa);
    // }
    //
    // fn baz(var, gpa: std.mem.Allocator) []u32 {
    // var.deinit(gpa)
    // }
    const foo: u32 = 1;
    var foo_start = CFGNodeCreate();
    foo_start.kind = .Start;
    var foo_node1 = CFGNodeCreate();
    var foo_node2 = CFGNodeCreate();
    var foo_end = CFGNodeCreate();
    foo_end.kind = .Return;

    try connectNodes(&foo_start, &foo_node1);
    try connectNodes(&foo_node1, &foo_node2);
    try connectNodes(&foo_node2, &foo_end);

    const baz: u32 = 29;
    var baz_start = CFGNodeCreate();
    baz_start.kind = .Start;
    var baz_node1 = CFGNodeCreate();
    var baz_end = CFGNodeCreate();
    baz_end.kind = .Return;

    try connectNodes(&baz_start, &baz_node1);
    try connectNodes(&baz_node1, &baz_end);

    foo_node1.mem_op = .{ .Allocation = .{ .result = 14, .allocator = 3 } };
    var args = [_]u32{ 14, 3 };
    foo_node2.mem_op = .{ .FunctionCall = .{ .result = null, .arguments = &args, .function_name = baz } };

    baz_node1.mem_op = .{ .DeinitExplicit = .{ .variable = 44, .allocator = 31 } };

    const fooParsedFn: cfg_def.ParsedFn = .{ .start_node = &foo_start, .return_node = &foo_end, .return_tok = null, .decl_params = &[_]u32{3} };
    const fooAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = fooParsedFn };

    const bazParsedFn: cfg_def.ParsedFn = .{ .start_node = &baz_start, .return_node = &baz_end, .return_tok = null, .decl_params = &[_]u32{ 44, 31 } };
    const bazAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = bazParsedFn };

    var parsed: cfg_def.ParsedCFG = .{ .functions = .init(gpa), .ast = undefined };
    try parsed.functions.put(foo, fooAnalyzedFn);
    try parsed.functions.put(baz, bazAnalyzedFn);

    _ = try rules.analyze_function(foo, &parsed, gpa);
    const alerts = try analysis.generate_alerts(foo, &parsed, gpa);
    for (alerts) |alert| {
        std.debug.print("{any}\n", .{alert});
    }
    try expect(alerts.len == 0);
}

test "function call free twice" {
    // fn foo(gpa: std.mem.Allocator) void  {
    // var bar = gpa.alloc();
    // baz(bar, gpa);
    // bar = gpa.alloc();
    // baz(bar, gpa);
    // }
    //
    // fn baz(var, gpa: std.mem.Allocator) []u32 {
    // var.deinit(gpa)
    // }
    const foo: u32 = 1;
    var foo_start = CFGNodeCreate();
    foo_start.kind = .Start;
    var foo_node1 = CFGNodeCreate();
    var foo_node2 = CFGNodeCreate();
    var foo_node3 = CFGNodeCreate();
    var foo_node4 = CFGNodeCreate();
    var foo_end = CFGNodeCreate();
    foo_end.kind = .Return;

    try connectNodes(&foo_start, &foo_node1);
    try connectNodes(&foo_node1, &foo_node2);
    try connectNodes(&foo_node2, &foo_node3);
    try connectNodes(&foo_node3, &foo_node4);
    try connectNodes(&foo_node4, &foo_end);

    const baz: u32 = 29;
    var baz_start = CFGNodeCreate();
    baz_start.kind = .Start;
    var baz_node1 = CFGNodeCreate();
    var baz_end = CFGNodeCreate();
    baz_end.kind = .Return;

    try connectNodes(&baz_start, &baz_node1);
    try connectNodes(&baz_node1, &baz_end);

    foo_node1.mem_op = .{ .Allocation = .{ .result = 14, .allocator = 3 } };
    var args = [_]u32{ 14, 3 };
    foo_node2.mem_op = .{ .FunctionCall = .{ .result = null, .arguments = &args, .function_name = baz } };
    foo_node3.mem_op = .{ .Allocation = .{ .result = 14, .allocator = 3 } };
    foo_node4.mem_op = .{ .FunctionCall = .{ .result = null, .arguments = &args, .function_name = baz } };

    baz_node1.mem_op = .{ .DeinitExplicit = .{ .variable = 44, .allocator = 31 } };

    const fooParsedFn: cfg_def.ParsedFn = .{ .start_node = &foo_start, .return_node = &foo_end, .return_tok = null, .decl_params = &[_]u32{3} };
    const fooAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = fooParsedFn };

    const bazParsedFn: cfg_def.ParsedFn = .{ .start_node = &baz_start, .return_node = &baz_end, .return_tok = null, .decl_params = &[_]u32{ 44, 31 } };
    const bazAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = bazParsedFn };

    var parsed: cfg_def.ParsedCFG = .{ .functions = .init(gpa), .ast = undefined };
    try parsed.functions.put(foo, fooAnalyzedFn);
    try parsed.functions.put(baz, bazAnalyzedFn);

    _ = try rules.analyze_function(foo, &parsed, gpa);
    const alerts = try analysis.generate_alerts(foo, &parsed, gpa);
    for (alerts) |alert| {
        std.debug.print("{any}\n", .{alert});
    }

    try expect(alerts.len == 0);
}

test "function call free, before alloc" {
    // fn foo(gpa: std.mem.Allocator) void  {
    // baz(bar, gpa);
    // bar = gpa.alloc();
    // baz(bar, gpa);
    // }
    //
    // fn baz(var, gpa: std.mem.Allocator) []u32 {
    // var.deinit(gpa)
    // }
    const foo: u32 = 1;
    var foo_start = CFGNodeCreate();
    foo_start.kind = .Start;
    var foo_node1 = CFGNodeCreate();
    var foo_node2 = CFGNodeCreate();
    var foo_node3 = CFGNodeCreate();
    var foo_end = CFGNodeCreate();
    foo_end.kind = .Return;

    var statement1_ast = [_]std.zig.Ast.Node.Index{@enumFromInt(13)};
    foo_node1.ast_nodes = &statement1_ast;
    var statement2_ast = [_]std.zig.Ast.Node.Index{@enumFromInt(22)};
    foo_node2.ast_nodes = &statement2_ast;
    var statement3_ast = [_]std.zig.Ast.Node.Index{@enumFromInt(30)};
    foo_node3.ast_nodes = &statement3_ast;

    try connectNodes(&foo_start, &foo_node1);
    try connectNodes(&foo_node1, &foo_node2);
    try connectNodes(&foo_node2, &foo_node3);
    try connectNodes(&foo_node3, &foo_end);

    const baz: u32 = 29;
    var baz_start = CFGNodeCreate();
    baz_start.kind = .Start;
    var baz_node1 = CFGNodeCreate();
    var baz_end = CFGNodeCreate();
    baz_end.kind = .Return;

    try connectNodes(&baz_start, &baz_node1);
    try connectNodes(&baz_node1, &baz_end);

    var args = [_]u32{ 14, 3 };
    foo_node1.mem_op = .{ .FunctionCall = .{ .result = null, .arguments = &args, .function_name = baz } };
    foo_node2.mem_op = .{ .Allocation = .{ .result = 14, .allocator = 3 } };
    foo_node3.mem_op = .{ .FunctionCall = .{ .result = null, .arguments = &args, .function_name = baz } };

    baz_node1.mem_op = .{ .DeinitExplicit = .{ .variable = 44, .allocator = 31 } };

    const fooParsedFn: cfg_def.ParsedFn = .{ .start_node = &foo_start, .return_node = &foo_end, .return_tok = null, .decl_params = &[_]u32{3} };
    const fooAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = fooParsedFn };

    const bazParsedFn: cfg_def.ParsedFn = .{ .start_node = &baz_start, .return_node = &baz_end, .return_tok = null, .decl_params = &[_]u32{ 44, 31 } };
    const bazAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = bazParsedFn };

    var parsed: cfg_def.ParsedCFG = .{ .functions = .init(gpa), .ast = undefined };
    try parsed.functions.put(foo, fooAnalyzedFn);
    try parsed.functions.put(baz, bazAnalyzedFn);

    _ = try rules.analyze_function(foo, &parsed, gpa);
    const alerts = try analysis.generate_alerts(foo, &parsed, gpa);
    for (alerts) |alert| {
        std.debug.print("{any}\n", .{alert});
    }

    try expect(alerts.len == 1);
    try expect(alerts[0].kind == .FreeBeforeAlloc);
    try expect(alerts[0].variable == 14);
    try expect(alerts[0].location == statement1_ast[0]);
}

test "cross free" {
    // fn foo(gpa1: std.mem.Allocator, gpa2: std.mem.Allocator) void  {
    // bar = gpa1.alloc();
    // baz(bar, gpa2);
    // }
    //
    // fn baz(var, gpa: std.mem.Allocator) []u32 {
    // var.deinit(gpa)
    // }
    const foo: u32 = 1;
    var foo_start = CFGNodeCreate();
    foo_start.kind = .Start;
    var foo_node1 = CFGNodeCreate();
    var foo_node2 = CFGNodeCreate();
    var foo_end = CFGNodeCreate();
    foo_end.kind = .Return;

    var statement1_ast = [_]std.zig.Ast.Node.Index{@enumFromInt(13)};
    foo_node1.ast_nodes = &statement1_ast;
    var statement2_ast = [_]std.zig.Ast.Node.Index{@enumFromInt(22)};
    foo_node2.ast_nodes = &statement2_ast;

    try connectNodes(&foo_start, &foo_node1);
    try connectNodes(&foo_node1, &foo_node2);
    try connectNodes(&foo_node2, &foo_end);

    const baz: u32 = 29;
    var baz_start = CFGNodeCreate();
    baz_start.kind = .Start;
    var baz_node1 = CFGNodeCreate();
    var baz_end = CFGNodeCreate();
    baz_end.kind = .Return;

    try connectNodes(&baz_start, &baz_node1);
    try connectNodes(&baz_node1, &baz_end);

    var args = [_]u32{ 14, 5 };
    foo_node1.mem_op = .{ .Allocation = .{ .result = 14, .allocator = 3 } };
    foo_node2.mem_op = .{ .FunctionCall = .{ .result = null, .arguments = &args, .function_name = baz } };

    baz_node1.mem_op = .{ .DeinitExplicit = .{ .variable = 44, .allocator = 31 } };

    const fooParsedFn: cfg_def.ParsedFn = .{ .start_node = &foo_start, .return_node = &foo_end, .return_tok = null, .decl_params = &[_]u32{ 3, 5 } };
    const fooAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = fooParsedFn };

    const bazParsedFn: cfg_def.ParsedFn = .{ .start_node = &baz_start, .return_node = &baz_end, .return_tok = null, .decl_params = &[_]u32{ 44, 31 } };
    const bazAnalyzedFn: cfg_def.AnalyzedFn = .{ .analysis = null, .func = bazParsedFn };

    var parsed: cfg_def.ParsedCFG = .{ .functions = .init(gpa), .ast = undefined };
    try parsed.functions.put(foo, fooAnalyzedFn);
    try parsed.functions.put(baz, bazAnalyzedFn);

    _ = try rules.analyze_function(foo, &parsed, gpa);
    const alerts = try analysis.generate_alerts(foo, &parsed, gpa);
    for (alerts) |alert| {
        std.debug.print("{any}\n", .{alert});
    }

    try expect(alerts.len == 1);
    try expect(alerts[0].kind == .CrossFree);
    try expect(alerts[0].variable == 14);
    try expect(alerts[0].location == statement2_ast[0]);
}
