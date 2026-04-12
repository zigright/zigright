const std = @import("std");

var progname: []const u8 = undefined;

// Unbuffered IO. Sorry Andrew. I won't flush
var stdout_writer = std.fs.File.stdout().writer(&.{});
var stderr_writer = std.fs.File.stderr().writer(&.{});
const stdout = &stdout_writer.interface;
const stderr = &stderr_writer.interface;

const helpOptions = struct { output_to_stderr: bool = false };
fn help(opts: helpOptions) !void {
    var writer: *std.Io.Writer = if (opts.output_to_stderr) stderr else stdout;
    try writer.print(
        \\Usage: {s} [FILE|-h]
        \\ FILE    a .zig file. If not given, STDIN is used
        \\ -h      print this help message
        \\
    , .{progname});
}

/// Helper function that figures out if a path is relative/absolute
/// and then returns a file handler to it. Idk if I am missing something
/// there is no function in the std library to just open a file.
/// std.fs.Dir.openFile() works on both absolute and relative paths but it requires
/// a handle to the parent dir first
/// std.fs.path.openFileAbsolute(), as the name suggests works only on absolute paths
fn openFile(path: []const u8) !std.fs.File {
    var ret: std.fs.File = undefined;
    if (std.fs.path.isAbsolute(path)) {
        ret = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    } else {
        ret = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    }
    return ret;
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    progname = std.fs.path.basename(args[0]);

    var src_file_handle: std.fs.File = undefined;
    defer src_file_handle.close();

    switch (args.len) {
        1 => {
            src_file_handle = std.fs.File.stdin();
        },
        2 => {
            if (std.mem.eql(u8, args[1], "-h")) {
                try help(.{});
                std.process.exit(0);
            } else {
                src_file_handle = openFile(args[1]) catch {
                    try stderr.print("{s}: Couldn't open {s}\n", .{ progname, args[1] });
                    std.process.exit(1);
                };
            }
        },
        else => {
            try help(.{ .output_to_stderr = true });
            std.process.exit(1);
        },
    }

    var reader = src_file_handle.reader(&.{});
    var src_code = std.Io.Writer.Allocating.init(gpa);
    defer src_code.deinit();

    _ = try reader.interface.streamRemaining(&src_code.writer);
    std.process.exit(0);
}
