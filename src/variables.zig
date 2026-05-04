const std = @import("std");

fn getAllVariables(tree: std.zig.Ast, gpa: std.mem.Allocator) ![]std.zig.Ast.Node.Index {
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
