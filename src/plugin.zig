const std = @import("std");
const plugin_api = @import("plugin_api.zig");
const parser = @import("parser.zig");
const layout = @import("layout.zig");
const lower = @import("lower.zig");
const plugin_skills = @import("plugin_skills.zig");
const plugin_commands = @import("plugin_commands.zig");

const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "rust",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runRustCommandAbi,
    .skills_ptr = plugin_skills.skills[0..].ptr,
    .skills_len = plugin_skills.skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;

pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}

fn anyWriterFromHostStream(stream: plugin_api.HostStream, storage: *plugin_api.HostStream) std.io.AnyWriter {
    storage.* = stream;
    return .{ .context = storage, .writeFn = struct {
        fn write(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
            const hs: *const plugin_api.HostStream = @ptrCast(@alignCast(ctx));
            const write_all = hs.write_all orelse return error.WriteFailed;
            if (write_all(hs.ctx, bytes.ptr, bytes.len) != @intFromEnum(plugin_api.AbiStatus.ok)) return error.WriteFailed;
            return bytes.len;
        }
    }.write };
}

fn runRustCommandAbi(
    ctx: *const plugin_api.Context,
    argv: [*]const [*:0]const u8,
    argv_len: usize,
    stdout: plugin_api.HostStream,
    stderr: plugin_api.HostStream,
    out_code: *u8,
) callconv(.c) u32 {
    out_code.* = 0;
    const allocator = std.heap.page_allocator;
    var local_ctx = ctx.*;
    local_ctx.allocator = allocator;

    const args = allocator.alloc([]const u8, argv_len) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer allocator.free(args);
    for (0..argv_len) |i| args[i] = std.mem.span(argv[i]);

    var stdout_storage = stdout;
    var stderr_storage = stderr;
    const out_writer = anyWriterFromHostStream(stdout, &stdout_storage);
    const err_writer = anyWriterFromHostStream(stderr, &stderr_storage);

    const result = plugin_commands.runRustCommandImpl(&local_ctx, args, out_writer, err_writer) catch
        return @intFromEnum(plugin_api.AbiStatus.failed);
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    return @intFromEnum(plugin_api.AbiStatus.unknown_command);
}

/// Convenience entry point used by `local_cli` and the tests.
pub fn compileFile(
    allocator: std.mem.Allocator,
    file: []const u8,
    options: lower.Options,
) !lower.Result {
    const src = try std.fs.cwd().readFileAlloc(allocator, file, 16 * 1024 * 1024);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), src);
    const prog = p.parseProgram() catch |err| {
        try p.printDiagnostic(stderr_writer_ref orelse undefined, file, err);
        return err;
    };
    var opts = options;
    opts.source_name = file;
    return lower.Lowerer.lower(allocator, prog, opts);
}

var stderr_writer_ref: ?std.io.AnyWriter = null;

pub fn setDiagnosticWriter(w: std.io.AnyWriter) void {
    stderr_writer_ref = w;
}

test {
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("layout.zig");
    _ = @import("lower.zig");
    _ = @import("plugin_tests.zig");
}
