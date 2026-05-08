const std = @import("std");
const functions = @import("functions.zig");
const utils = @import("utils.zig");
const assert = std.debug.assert;

const BBNode = struct {
    incoming: std.AutoHashMap(std.zig.Ast.Node.Index, void),
    outgoing: std.AutoHashMap(std.zig.Ast.Node.Index, void),
    isReturn: bool,
    isTarget: bool,
    isFirst: bool,
    isConditional: bool,

    const Self = @This();
    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .incoming = .init(gpa),
            .outgoing = .init(gpa),
            .isReturn = false,
            .isTarget = false,
            .isFirst = false,
            .isConditional = false,
        };
    }
    pub fn format(
        self: BBNode,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("incoming: [", .{});
        var it = self.incoming.keyIterator();
        while (it.next()) |key| {
            try writer.print("{}, ", .{@intFromEnum(key.*)});
        }
        try writer.print("]\n", .{});

        try writer.print("outgoing: [", .{});
        it = self.outgoing.keyIterator();
        while (it.next()) |key| {
            try writer.print("{}, ", .{@intFromEnum(key.*)});
        }
        try writer.print("]\n", .{});

        try writer.print("isReturn: {}\nisFirst: {}\nisConditional: {}", .{ self.isReturn, self.isFirst, self.isConditional });
    }
};

const BBNodeCtx = struct {
    goto: ?std.zig.Ast.Node.Index,
    parent: ?std.zig.Ast.Node.Index,
    isFirst: bool,
};

fn dfs(
    tree: *std.zig.Ast,
    nodeIndex: std.zig.Ast.Node.Index,
    statements: *std.AutoHashMap(std.zig.Ast.Node.Index, BBNode),
    gpa: std.mem.Allocator,
    ctx: BBNodeCtx,
) !void {
    const currNode = tree.nodes.get(@intFromEnum(nodeIndex));
    switch (currNode.tag) {
        // Don't have to include the LPAREN, RPAREN nodes
        .block_two, .block_two_semicolon => {
            const lindex = currNode.data.opt_node_and_opt_node.@"0".unwrap();
            const rindex = currNode.data.opt_node_and_opt_node.@"1".unwrap();
            if (lindex) |i| {
                try dfs(tree, i, statements, gpa);
            }
            if (rindex) |i| {
                try dfs(tree, i, statements, gpa);
            }
        },
        .block, .block_semicolon => {
            for (tree.extraDataSlice(currNode.data.extra_range, std.zig.Ast.Node.Index)) |i| {
                try dfs(tree, i, statements, gpa);
            }
        },
        .@"if" => {
            const if_data = tree.ifFull(nodeIndex);
            // Add the if node
            var tmp: BBNode = .init(gpa);
            tmp.isConditional = true;
            try tmp.outgoing.put(if_data.ast.then_expr, {});

            // Recurse the then block
            try dfs(tree, if_data.ast.then_expr, statements, gpa);
            // Don't add the else node
            if (if_data.ast.else_expr.unwrap()) |i| {
                try tmp.outgoing.put(i, {});
                // Recurse the else block
                try dfs(tree, i, statements, gpa);
            }
            try statements.put(nodeIndex, tmp);
        },
        .if_simple => {
            const if_data = tree.ifSimple(nodeIndex);
            // Add the if node
            var tmp: BBNode = .init(gpa);
            tmp.isConditional = true;
            try tmp.outgoing.put(if_data.ast.then_expr, {});
            try statements.put(nodeIndex, tmp);

            // Recurse the then block
            try dfs(tree, if_data.ast.then_expr, statements, gpa);
            // There is no else block for simple if
        },
        .@"switch", .switch_comma => {
            const switch_data = tree.fullSwitch(nodeIndex).?;
            // Add the switch node
            var tmp: BBNode = .init(gpa);
            tmp.isConditional = true;
            for (switch_data.ast.cases) |i| {
                try tmp.outgoing.put(i, {});
                // Recurse on each case block
                try dfs(tree, i, statements, gpa);
            }
            try statements.put(nodeIndex, tmp);
        },
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => {
            const switch_case = tree.fullSwitchCase(nodeIndex).?;

            var tmp: BBNode = .init(gpa);
            tmp.isTarget = true;
            try tmp.outgoing.put(switch_case.ast.target_expr, {});
            try statements.put(nodeIndex, tmp);

            try dfs(tree, switch_case.ast.target_expr, statements, gpa);
        },
        .while_simple,
        .while_cont,
        .@"while",
        => {
            const while_data = tree.fullWhile(nodeIndex).?;
            // Add the while block
            var tmp: BBNode = .init(gpa);
            tmp.isConditional = true;
            tmp.isTarget = true;
            try tmp.outgoing.put(while_data.ast.then_expr, {});

            if (while_data.ast.cont_expr.unwrap()) |i| {
                // If there is a continue expression add it
                try tmp.incoming.put(i, {});
                try dfs(tree, i, statements, gpa);
            }
            try statements.put(nodeIndex, tmp);

            // recurse the loop body
            try dfs(tree, while_data.ast.then_expr, statements, gpa);
        },
        .for_simple, .@"for" => {
            const for_data = tree.fullFor(nodeIndex).?;
            // Add the for node
            var tmp: BBNode = .init(gpa);
            tmp.isConditional = true;
            tmp.isTarget = true;
            try tmp.outgoing.put(for_data.ast.then_expr, {});

            // If there is an else part, add it
            if (for_data.ast.else_expr.unwrap()) |i| {
                try tmp.outgoing.put(i, {});
                try dfs(tree, i, statements, gpa);
            }
            try statements.put(nodeIndex, tmp);

            // recurse loop body
            try dfs(tree, for_data.ast.then_expr, statements, gpa);
        },
        else => {
            const tmp: BBNode = .init(gpa);
            // leaf node. Just add them
            try statements.put(nodeIndex, tmp);
            return;
        },
    }
}

pub fn getBasicBlocks(tree: *std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index, gpa: std.mem.Allocator) !void {
    const funcBodyIndex = functions.getFunctionBlockIndex(tree, nodeIndex);
    var bbGraph: std.AutoHashMap(std.zig.Ast.Node.Index, BBNode) = .init(gpa);
    defer bbGraph.deinit();
    try dfs(tree, funcBodyIndex, &bbGraph, gpa);
    var it = bbGraph.keyIterator();
    while (it.next()) |key| {
        std.debug.print("{d}->{f}\n\n", .{ @intFromEnum(key.*), bbGraph.get(key.*).? });
    }
}
