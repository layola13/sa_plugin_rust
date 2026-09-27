const std = @import("std");
const plugin_api = @import("plugin_api.zig");
const plugin_commands = @import("plugin_commands.zig");

/// Standalone `rust` driver: the same dispatcher the plugin host uses.
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    const command_names = [_][]const u8{
        "init", "skills", "build",  "build-exe",
        "check", "test",  "run",   "help",
    };

    // The dispatcher expects `argv[1] == "rust"`, so the marker is inserted
    // before the first recognised subcommand: `rust check x.rs` becomes
    // `["rust", "rust", "check", "x.rs"]`.
    var forwarded: std.ArrayList([]const u8) = .init(allocator);
    try forwarded.append(argv[0]);

    var inserted = false;
    for (argv[1..]) |token| {
        if (!inserted) {
            var is_cmd = false;
            for (command_names) |c| {
                if (std.mem.eql(u8, token, c)) is_cmd = true;
            }
            if (is_cmd) {
                try forwarded.append("rust");
                inserted = true;
            }
        }
        try forwarded.append(token);
    }
    if (!inserted) {
        try forwarded.append("rust");
        try forwarded.append("help");
    }

    var ctx = plugin_api.Context{ .allocator = allocator };
    // The dispatcher takes `AnyWriter`; the `any()` adaptation lets a plain
    // `File.Writer` satisfy it without a buffering layer.
    const stdout: std.io.AnyWriter = .{ .context = @as(*const anyopaque, &std.io.getStdOut()), .writeFn = writeAny };
    const stderr: std.io.AnyWriter = .{ .context = @as(*const anyopaque, &std.io.getStdErr()), .writeFn = writeAny };
    const code = plugin_commands.runRustCommandImpl(&ctx, forwarded.items, stdout, stderr) catch |err| {
        std.io.getStdErr().writer().print("rust: {s}\n", .{@errorName(err)}) catch {};
        return err;
    };
    std.process.exit(code orelse 0);
}

fn writeAny(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
    const file: *const std.fs.File = @ptrCast(@alignCast(ctx));
    file.writeAll(bytes) catch |err| return err;
    return bytes.len;
}
