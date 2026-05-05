const std = @import("std");
const assert = std.debug.assert;
const utils = @import("utils.zig");

pub fn getFunctionName(tree: *std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index) []const u8 {
    const node = tree.nodes.get(@intFromEnum(nodeIndex));
    assert(node.tag == .fn_decl);
    const start_token_index = tree.firstToken(node.data.node_and_node.@"0");
    const end_token_index = tree.lastToken(node.data.node_and_node.@"0");
    // use +1 as .. is not inclusive
    for (start_token_index..end_token_index + 1) |index| {
        const token = tree.tokens.get(index);
        if (token.tag == .identifier) {
            return tree.tokenSlice(@intCast(index));
        }
    }
    unreachable;
}

pub fn getFunctionReturnType(tree: *std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index) []const u8 {
    const nodeData = tree.nodeData(nodeIndex);
    const fnProtoNode = tree.nodes.get(@intFromEnum(nodeData.node_and_node.@"0"));
    var returnIndex: std.zig.Ast.Node.Index = undefined;
    switch (fnProtoNode.tag) {
        .fn_proto_simple => {
            returnIndex = fnProtoNode.data.opt_node_and_opt_node.@"1".unwrap().?;
        },
        .fn_proto_multi, .fn_proto_one, .fn_proto => {
            returnIndex = fnProtoNode.data.extra_and_opt_node.@"1".unwrap().?;
        },
        else => {},
    }
    const startTokenIndex = tree.firstToken(returnIndex);
    const lastTokenIndex = tree.lastToken(returnIndex);
    return utils.spanToSlice(tree, tree.tokensToSpan(startTokenIndex, lastTokenIndex, tree.nodeMainToken(returnIndex)));
}

pub fn getAllFunctionNames(tree: *std.zig.Ast, gpa: std.mem.Allocator) ![][]const u8 {
    var ret: std.ArrayList([]const u8) = .empty;
    for (0..tree.nodes.len) |value| {
        const node = tree.nodes.get(value);
        if (node.tag == .fn_decl) {
            const tmp = getFunctionName(tree, value);
            try ret.append(gpa, tmp);
        }
    }
    return ret.items;
}

pub fn getAllFunctions(tree: *std.zig.Ast, gpa: std.mem.Allocator) ![]std.zig.Ast.Node.Index {
    var ret: std.ArrayList(std.zig.Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |value, index| {
        if (value == .fn_decl) {
            try ret.append(gpa, @enumFromInt(index));
        }
    }
    return ret.items;
}

pub fn getFunctionParamsWithType(tree: *std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var map: std.StringHashMap([]const u8) = .init(gpa);
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const funcProto = tree.fullFnProto(&buffer, nodeIndex).?;
    var iter = funcProto.iterate(&tree);
    while (iter.next()) |j| {
        const startTokenIndex = tree.firstToken(j.type_expr.?);
        const lastTokenIndex = tree.lastToken(j.type_expr.?);
        try map.put(tree.tokenSlice(j.name_token.?), utils.spanToSlice(tree, tree.tokensToSpan(startTokenIndex, lastTokenIndex, @intFromEnum(j.type_expr.?))));
    }
    return map;
}

pub fn getAllFunctionsWithAlloc(tree: *std.zig.Ast, gpa: std.mem.Allocator) ![]std.zig.Ast.Node.Index {
    const functionIndices = try getAllFunctions(tree, gpa);
    var node: std.zig.Ast.Node = undefined;
    var ret: std.ArrayList(std.zig.Ast.Node.Index) = .empty;
    for (functionIndices) |i| {
        node = tree.nodes.get(@intFromEnum(i));
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const funcProto = tree.fullFnProto(&buffer, i).?;
        var iter = funcProto.iterate(&tree);
        while (iter.next()) |j| {
            const startTokenIndex = tree.firstToken(j.type_expr.?);
            const lastTokenIndex = tree.lastToken(j.type_expr.?);
            if (std.mem.eql(u8, utils.spanToSlice(tree, tree.tokensToSpan(startTokenIndex, lastTokenIndex, @intFromEnum(j.type_expr.?))), "std.mem.Allocator")) {
                try ret.append(gpa, i);
                break;
            }
        }
    }
    return ret.items;
}

pub fn getReturnExpr(tree: *std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index) []const u8 {
    const returnNode = tree.nodes.get(@intFromEnum(nodeIndex));
    const returnExprIndex = returnNode.data.opt_node.unwrap();
    if (returnExprIndex != null) {
        const returnExprNode = tree.nodes.get(@intFromEnum(returnExprIndex.?));
        const startTokenIndex = tree.firstToken(returnExprIndex.?);
        const lastTokenIndex = tree.lastToken(returnExprIndex.?);
        return utils.spanToSlice(tree, tree.tokensToSpan(startTokenIndex, lastTokenIndex, returnExprNode.main_token));
    }
    return "void";
}

pub fn getReturn(tree: *std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index, gpa: std.mem.Allocator) ![][]const u8 {
    var ret: std.ArrayList([]const u8) = .empty;
    const funcBodyIndex = tree.nodeData(nodeIndex).node_and_node.@"1";
    var stack: std.ArrayList(std.zig.Ast.Node.Index) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, funcBodyIndex);

    while (stack.items.len > 0) {
        const curr = stack.pop().?;
        const currNode = tree.nodes.get(@intFromEnum(curr));
        switch (currNode.tag) {
            .block_two, .block_two_semicolon => {
                const lindex = currNode.data.opt_node_and_opt_node.@"0".unwrap();
                const rindex = currNode.data.opt_node_and_opt_node.@"1".unwrap();
                if (lindex != null) {
                    try stack.append(gpa, lindex.?);
                }
                if (rindex != null) {
                    try stack.append(gpa, rindex.?);
                }
            },
            .block, .block_semicolon => {
                for (tree.extraDataSlice(currNode.data.extra_range, std.zig.Ast.Node.Index)) |index| {
                    try stack.append(gpa, index);
                }
            },
            .@"if" => {
                const if_data = tree.ifFull(curr);
                try stack.append(gpa, if_data.ast.then_expr);
                if (if_data.ast.else_expr.unwrap()) |val| {
                    try stack.append(gpa, val);
                }
            },
            .if_simple => {
                const if_data = tree.ifSimple(curr);
                try stack.append(gpa, if_data.ast.then_expr);
                if (if_data.ast.else_expr.unwrap()) |val| {
                    try stack.append(gpa, val);
                }
            },
            .@"switch", .switch_comma => {
                const switch_data = tree.fullSwitch(curr).?;
                for (switch_data.ast.cases) |case| {
                    try stack.append(gpa, case);
                }
            },
            .switch_case_one,
            .switch_case_inline_one,
            .switch_case,
            .switch_case_inline,
            => {
                const switch_case = tree.fullSwitchCase(curr).?;
                try stack.append(gpa, switch_case.ast.target_expr);
            },
            .@"return" => {
                try ret.append(gpa, getReturnExpr(tree, curr));
            },
            .while_simple,
            .while_cont,
            .@"while",
            => {
                const while_data = tree.fullWhile(curr).?;
                try stack.append(gpa, while_data.ast.then_expr);
            },
            .for_simple, .@"for" => {
                const for_data = tree.fullFor(curr).?;
                try stack.append(gpa, for_data.ast.then_expr);
            },
            else => {},
        }
    }
    if (ret.items.len == 0) {
        try ret.append(gpa, "void");
    }
    return ret.items;
}

pub fn getFunctionBlockIndex(tree: *std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index) std.zig.Ast.Node.Index {
    assert(tree.nodeTag(nodeIndex) == .fn_decl);
    return tree.nodes.get(@intFromEnum(nodeIndex)).data.node_and_node.@"1";
}
