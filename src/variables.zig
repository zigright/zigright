const std = @import("std");
const functions = @import("functions.zig");
const assert = std.debug.assert;

/// Return all the variables
pub fn getAllVariables(tree: std.zig.Ast, gpa: std.mem.Allocator) ![]std.zig.Ast.Node.Index {
    var ret: std.ArrayList(std.zig.Ast.Node.Index) = .empty;
    for (0..tree.nodes.len) |index| {
        switch (tree.nodeTag(@enumFromInt(index))) {
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                try ret.append(gpa, @enumFromInt(index));
            },
            else => {},
        }
    }
    return ret.items;
}

fn isVariableDecl(tree: *std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            return true;
        },
        else => {
            return false;
        },
    }
}

pub fn getVariablesUnderFunction(tree: *std.zig.Ast, func: std.zig.Ast.Node.Index, gpa: std.mem.Allocator) ![]std.zig.Ast.Node.Index {
    const blockIndex = functions.getFunctionBlockIndex(tree, func);
    return getVariablesUnderScope(tree, blockIndex, gpa);
}

/// Return all variables under a specific scope
/// Here scope is any node of the parser tree that has the tag of
/// block, block_semicolon, block_two, block_two_semicolon
pub fn getVariablesUnderScope(tree: *std.zig.Ast, block: std.zig.Ast.Node.Index, gpa: std.mem.Allocator) ![]std.zig.Ast.Node.Index {
    var ret: std.ArrayList(std.zig.Ast.Node.Index) = .empty;
    switch (tree.nodeTag(block)) {
        .block, .block_semicolon => {
            for (tree.extraDataSlice(tree.nodeData(block).extra_range, std.zig.Ast.Node.Index)) |index| {
                if (isVariableDecl(tree, index)) {
                    try ret.append(gpa, index);
                }
            }
        },
        .block_two, .block_two_semicolon => {
            if (tree.nodeData(block).opt_node_and_opt_node.@"0".unwrap()) |i| {
                if (isVariableDecl(tree, i)) {
                    try ret.append(gpa, i);
                }
            }
            if (tree.nodeData(block).opt_node_and_opt_node.@"1".unwrap()) |i| {
                if (isVariableDecl(tree, i)) {
                    try ret.append(gpa, i);
                }
            }
        },
        else => unreachable,
    }
    return ret.items;
}

pub fn getVariableName(tree: *std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index) []const u8 {
    const decl = tree.fullVarDecl(nodeIndex);
    const tok = decl.?.firstToken() + 1;
    return tree.tokenSlice(tok);
}
