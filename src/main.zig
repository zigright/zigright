const std = @import("std");

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

    for (ast.nodes.items(.tag)) |value| {
        try stdout.print("{}\n", .{value});
    }
    try stdout.flush();

    std.process.exit(0);
}
