const std = @import("std");
const version_data = @import("version_data");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

var progname: []const u8 = undefined;

fn help(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: {s} [FILE|-h]
        \\ FILE    a .zig file. If not given, STDIN is used
        \\ -h      print this help message
        \\
    , .{progname});
    try writer.flush();
}

/// Helper function that figures out if a path is relative/absolute
/// and then returns a file handler to it. Idk if I am missing something
/// there is no function in the std library to just open a file.
/// std.fs.Dir.openFile() works on both absolute and relative paths but it requires
/// a handle to the parent dir first
/// std.fs.path.openFileAbsolute(), as the name suggests works only on absolute paths
fn openFile(io: std.Io, path: []const u8) !std.Io.File {
    var ret: std.Io.File = undefined;
    if (std.fs.path.isAbsolute(path)) {
        ret = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    } else {
        ret = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    }
    return ret;
}

fn getFunctionName(tree: std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index) []const u8 {
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

fn spanToSlice(tree: std.zig.Ast, span: std.zig.Ast.Span) []const u8 {
    return tree.source[span.start..span.end];
}

fn getFunctionReturnType(tree: std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index) []const u8 {
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
    return spanToSlice(tree, tree.tokensToSpan(startTokenIndex, lastTokenIndex, tree.nodeMainToken(returnIndex)));
}

fn getAllFunctionNames(tree: std.zig.Ast, gpa: std.mem.Allocator) ![][]const u8 {
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

fn getAllFunctions(tree: std.zig.Ast, gpa: std.mem.Allocator) ![]std.zig.Ast.Node.Index {
    var ret: std.ArrayList(std.zig.Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |value, index| {
        if (value == .fn_decl) {
            try ret.append(gpa, @enumFromInt(index));
        }
    }
    return ret.items;
}

fn getFunctionArgsWithType(tree: std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index, gpa: std.mem.Allocator) !std.AutoHashMap(u16, []const u8) {
    var map: std.AutoHashMap(u16, []const u8) = .init(gpa);
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const funcProto = tree.fullFnProto(&buffer, nodeIndex).?;
    var iter = funcProto.iterate(&tree);
    var index: u16 = 0;
    while (iter.next()) |j| {
        const startTokenIndex = tree.firstToken(j.type_expr.?);
        const lastTokenIndex = tree.lastToken(j.type_expr.?);
        try map.put(index, spanToSlice(tree, tree.tokensToSpan(startTokenIndex, lastTokenIndex, @intFromEnum(j.type_expr.?))));
        index += 1;
    }
    return map;
}

fn getAllFunctionsWithAlloc(tree: std.zig.Ast, gpa: std.mem.Allocator) ![]std.zig.Ast.Node.Index {
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
            if (std.mem.eql(u8, spanToSlice(tree, tree.tokensToSpan(startTokenIndex, lastTokenIndex, @intFromEnum(j.type_expr.?))), "std.mem.Allocator")) {
                try ret.append(gpa, i);
                break;
            }
        }
    }
    return ret.items;
}

fn getReturnExpr(tree: std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index) []const u8 {
    const returnNode = tree.nodes.get(@intFromEnum(nodeIndex));
    const returnExprIndex = returnNode.data.opt_node.unwrap();
    if (returnExprIndex != null) {
        const returnExprNode = tree.nodes.get(@intFromEnum(returnExprIndex.?));
        const startTokenIndex = tree.firstToken(returnExprIndex.?);
        const lastTokenIndex = tree.lastToken(returnExprIndex.?);
        return spanToSlice(tree, tree.tokensToSpan(startTokenIndex, lastTokenIndex, returnExprNode.main_token));
    }
    return "void";
}

fn getReturn(tree: std.zig.Ast, nodeIndex: std.zig.Ast.Node.Index, gpa: std.mem.Allocator) ![][]const u8 {
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

fn printSlice(comptime T: type, slice: []T, writer: *std.Io.Writer) !void {
    try writer.print("[", .{});
    for (0..slice.len - 1) |i| {
        if (T == []const u8) {
            try writer.print("'{s}', ", .{slice[i]});
        }
        try writer.print("'{any}', ", .{slice[i]});
    }
    if (T == []const u8) {
        try writer.print("'{s}']\n", .{slice[slice.len - 1]});
    } else {
        try writer.print("'{any}']\n", .{slice[slice.len - 1]});
    }
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    progname = std.fs.path.basename(args[0]);

    var src_file_handle: std.Io.File = undefined;
    defer src_file_handle.close(io);

    switch (args.len) {
        1 => {
            src_file_handle = std.Io.File.stdin();
        },
        2 => {
            if (std.mem.startsWith(u8, args[1], "-")) {
                if (std.mem.eql(u8, args[1], "-h")) {
                    try help(stdout);
                    std.process.exit(0);
                } else {
                    try help(stderr);
                    std.process.exit(1);
                }
            } else {
                src_file_handle = openFile(io, args[1]) catch {
                    try stderr.print("{s}: Cannot open {s}\n", .{ progname, args[1] });
                    try stderr.flush();
                    std.process.exit(1);
                };
            }
        },
        else => {
            try help(stderr);
            std.process.exit(1);
        },
    }

    var reader = src_file_handle.reader(io, &.{});
    var writer = std.Io.Writer.Allocating.init(gpa);

    _ = try reader.interface.streamRemaining(&writer.writer);

    const src_code = try writer.toOwnedSliceSentinel(0);
    defer gpa.free(src_code);

    writer.deinit();

    // This has to be a var as .deinit() mutates the fields.
    var ast = try std.zig.Ast.parse(gpa, src_code, .zig);
    defer ast.deinit(gpa);

    for (try getAllFunctionsWithAlloc(ast, gpa)) |i| {
        const returns = try getReturn(ast, i, gpa);
        std.debug.print("{s}: ", .{getFunctionName(ast, i)});
        try printSlice([]const u8, returns, stdout);
    }
    try printSlice(std.zig.Ast.Node.Index, try getAllFunctions(ast, gpa), stdout);

    try stdout.flush();

    std.process.exit(0);
}

pub fn branched_alloc(gpa1: std.mem.Allocator, gpa2: std.mem.Allocator, a: bool) !void {
    var arr: [5]u8 = undefined;
    if (a) {
        arr = gpa1.alloc(u8, 5);
    } else {
        arr = gpa2.alloc(u8, 5);
    }
    // State here?
}

pub fn branched_alloc2(gpa1: std.mem.Allocator, gpa2: std.mem.Allocator, a: bool) !void {
    var arr: [5]u8 = undefined;
    if (a) {
        arr = gpa1.alloc(u8, 5);
    }
    if (!a) {
        arr = gpa2.alloc(u8, 5);
    }
}

pub fn something_and_free(thing: []u8, alloc: std.mem.Allocator) void {
    defer alloc.free(thing);
    // And do something interesting, maybe.
}
