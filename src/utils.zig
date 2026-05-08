const std = @import("std");

pub fn spanToSlice(tree: *std.zig.Ast, span: std.zig.Ast.Span) []const u8 {
    return tree.source[span.start..span.end];
}

pub fn printSlice(comptime T: type, slice: []T, writer: *std.Io.Writer) !void {
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

/// Helper function that figures out if a path is relative/absolute
/// and then returns a file handler to it. Idk if I am missing something
/// there is no function in the std library to just open a file.
/// std.fs.Dir.openFile() works on both absolute and relative paths but it requires
/// a handle to the parent dir first
/// std.fs.path.openFileAbsolute(), as the name suggests works only on absolute paths
pub fn openFile(io: std.Io, path: []const u8) !std.Io.File {
    var ret: std.Io.File = undefined;
    if (std.fs.path.isAbsolute(path)) {
        ret = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    } else {
        ret = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    }
    return ret;
}
