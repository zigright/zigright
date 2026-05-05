const std = @import("std");
const utils = @import("utils.zig");
const functions = @import("functions.zig");
const variables = @import("variables.zig");
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
                src_file_handle = utils.openFile(io, args[1]) catch {
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

    for (try functions.getAllFunctions(&ast, gpa)) |i| {
        const vars = try variables.getVariablesUnderFunction(&ast, i, gpa);
        for (vars) |v| {
            std.debug.print("{s} {s}\n", .{ functions.getFunctionName(&ast, i), variables.getVariableName(&ast, v) });
        }
        // const params = try functions.getFunctionParamsWithType(ast, i, gpa);
        // var iter = params.iterator();
        // std.debug.print("{s}:\n", .{functions.getFunctionName(ast, i)});
        // while (iter.next()) |param| {
        //     std.debug.print("\t{s}:{s}\n", .{ param.key_ptr.*, param.value_ptr.* });
        // }
    }
    try stdout.flush();

    std.process.exit(0);
}
