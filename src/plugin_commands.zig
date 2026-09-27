const std = @import("std");
const plugin_api = @import("plugin_api.zig");
const parser = @import("parser.zig");
const lower = @import("lower.zig");
const plugin_skills = @import("plugin_skills.zig");
const host_paths = @import("host_paths.zig");

pub const help_text =
    \\usage: rust <command> [options]
    \\       sa rust <command> [options]
    \\
    \\Commands:
    \\  init       [path]
    \\  skills     [--json]
    \\  build      [file.rs] [--out <file.sa>]
    \\  build-exe  [file.rs] [--out <exe>] [sa-build-exe args]
    \\  check      [file.rs]
    \\  test       [file.rs] [sa-test args]
    \\  run        [file.rs] [sa-run args]
    \\
    \\Options:
    \\  -o, --out <file>   Explicit output path
    \\  -h, --help         Show this help message
    \\
;

const UsageError = error{ Usage };

/// `argv[1]` must be the plugin name; the host and `local_cli` both guarantee it.
pub fn runRustCommandImpl(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !?u8 {
    if (args.len < 2) return null;
    if (!std.mem.eql(u8, args[1], "rust")) return null;
    if (args.len < 3) {
        try stderr.writeAll(help_text);
        return 1;
    }
    const cmd = args[2];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help")) {
        try stdout.writeAll(help_text);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "skills")) return runSkills(ctx, args, stdout);
    if (std.mem.eql(u8, cmd, "init")) return runInit(args, stdout, stderr);
    if (std.mem.eql(u8, cmd, "build")) return runBuild(args, stdout, stderr);
    if (std.mem.eql(u8, cmd, "check")) return runCheck(args, stdout, stderr);
    if (std.mem.eql(u8, cmd, "build-exe")) return runBuildExe(args, stdout, stderr);
    if (std.mem.eql(u8, cmd, "test")) return runForward(args, "test", stdout, stderr);
    if (std.mem.eql(u8, cmd, "run")) return runForward(args, "run", stdout, stderr);
    try stderr.print("Unknown rust command: {s}\n", .{cmd});
    try stderr.writeAll(help_text);
    return 1;
}

const Options = struct {
    source: ?[]const u8 = null,
    out: ?[]const u8 = null,
    /// Everything the plugin did not recognise, forwarded to `sa` verbatim.
    passthrough: []const []const u8 = &.{},
    help: bool = false,
    json: bool = false,
    /// Fail the build when the lowering had to drop a construct, instead of
    /// emitting a placeholder and letting the program look fine.
    deny_unsupported: bool = false,
    /// Parse every `.rs` file under this directory tree and report coverage.
    corpus: ?[]const u8 = null,
    /// Suppress `#loc` source hints. They are on by default because they cost one
    /// line per statement and turn every diagnostic into a Rust file/line.
    no_loc: bool = false,
};

/// Split `args` into the plugin's own options and the child's passthrough.
///
/// The source file may appear anywhere, so the scan does not stop at the first
/// bare token: `--out` after the file name is still ours, and anything
/// unrecognised is forwarded.
fn parseOptions(args: []const []const u8) Options {
    var o = Options{};
    // The result outlives this function, so the buffer is handed over rather
    // than freed by a `defer`.
    var extra: std.ArrayList([]const u8) = .init(std.heap.page_allocator);

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            o.help = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--deny-unsupported")) {
            o.deny_unsupported = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-loc")) {
            o.no_loc = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--corpus")) {
            if (i + 1 < args.len) {
                o.corpus = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--corpus=")) {
            o.corpus = a["--corpus=".len..];
            continue;
        }
        if (std.mem.eql(u8, a, "--out") or std.mem.eql(u8, a, "-o")) {
            if (i + 1 < args.len) {
                o.out = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--out=")) {
            o.out = a["--out=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "-o") and a.len > 2 and a[2] != '-') {
            o.out = a[2..];
            continue;
        }
        if (o.source == null and a.len > 0 and a[0] != '-') {
            o.source = a;
            continue;
        }
        extra.append(a) catch {};
    }
    o.passthrough = extra.toOwnedSlice() catch &.{};
    return o;
}

/// Default output for a `.rs` input: the same path with a `.sa` extension.
fn defaultSaPath(allocator: std.mem.Allocator, file: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, file, ".rs")) {
        return std.fmt.allocPrint(allocator, "{s}.sa", .{file[0 .. file.len - 3]});
    }
    return std.fmt.allocPrint(allocator, "{s}.sa", .{file});
}

const Compiled = struct {
    sa: []const u8,
    fn_count: usize,
    def_count: usize,
    unsupported: usize,
    /// Distinct reasons the lowering had to give something up.
    notes: []const []const u8,
    /// `--deny-unsupported`: turn those refusals into a build failure.
    deny_unsupported: bool,
};

/// Release the buffers `compile` handed over.
fn freeResult(allocator: std.mem.Allocator, c: Compiled) void {
    allocator.free(c.sa);
    allocator.free(c.notes);
}

/// Report what the lowering could not do.
///
/// A construct that is not lowered still produces a value (usually a zero), so
/// the program builds and runs while being quietly wrong. Naming every refusal
/// is the difference between a compiler that fails loudly and one that lies.
fn reportUnsupported(stderr: std.io.AnyWriter, c: Compiled, file: []const u8) !void {
    if (c.unsupported == 0) return;
    try stderr.print(
        "Rust Warning: {s}: {d} construct(s) could not be lowered and were replaced with placeholder values.\n",
        .{ file, c.unsupported },
    );
    for (c.notes) |n| try stderr.print("  - {s}\n", .{n});
    try stderr.writeAll(
        "  The program still compiles; treat the result as unverified.\n",
    );
    if (c.deny_unsupported) try stderr.writeAll("  --deny-unsupported was given, so this is an error.\n");
}

/// The shared `parse -> lower` path for every subcommand.
/// The `lower.Options` implied by the parsed command line.
fn lowerOpts(o: Options) lower.Options {
    return .{ .emit_source_map = !o.no_loc };
}

fn compile(
    allocator: std.mem.Allocator,
    file: []const u8,
    options: lower.Options,
    stderr: std.io.AnyWriter,
    deny_unsupported: bool,
) !?Compiled {
    const src = std.fs.cwd().readFileAlloc(allocator, file, 16 * 1024 * 1024) catch |err| {
        try stderr.print("Rust Error: cannot read {s}: {s}\n", .{ file, @errorName(err) });
        return null;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var p = parser.Parser.init(arena.allocator(), src);
    const program = p.parseProgram() catch |err| {
        p.printDiagnostic(stderr, file, err) catch {};
        return null;
    };
    // The `#loc` hints name the file the user actually passed, so a trap points
    // at `src/main.rs:42` rather than at whatever the compiler called it.
    var opts = options;
    opts.source_name = file;
    const res = lower.Lowerer.lower(allocator, program, opts) catch |err| {
        try stderr.print("Rust Lowering Error: {s} ({s})\n", .{ file, @errorName(err) });
        return null;
    };
    if (deny_unsupported and res.unsupported > 0) {
        try reportUnsupported(stderr, .{
            .sa = res.sa,
            .fn_count = res.function_count,
            .def_count = res.def_count,
            .unsupported = res.unsupported,
            .notes = res.unsupported_notes,
            .deny_unsupported = true,
        }, file);
        return null;
    }
    return .{
        .sa = res.sa,
        .fn_count = res.function_count,
        .def_count = res.def_count,
        .unsupported = res.unsupported,
        .notes = res.unsupported_notes,
        .deny_unsupported = deny_unsupported,
    };
}

fn runBuild(args: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) !?u8 {
    const opts = parseOptions(args);
    if (opts.help) {
        try stdout.writeAll(help_text);
        return 0;
    }
    const file = opts.source orelse "main.rs";
    const allocator = std.heap.page_allocator;
    const result = (try compile(allocator, file, lowerOpts(opts), stderr, opts.deny_unsupported)) orelse return 1;
    try reportUnsupported(stderr, result, file);
    const out_path = opts.out orelse try defaultSaPath(allocator, file);
    std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = result.sa }) catch |err| {
        try stderr.print("Rust Error: cannot write {s}: {s}\n", .{ out_path, @errorName(err) });
        return 1;
    };
    try stdout.print(
        "Rust Compiler: compiled {s} to {s} ({d} functions, {d} layout defs, {d} unsupported constructs).\n",
        .{ file, out_path, result.fn_count, result.def_count, result.unsupported },
    );
    freeResult(allocator, result);
    return 0;
}

/// Parse every `.rs` file under `root` and report how many succeeded.
///
/// This is the regression gate for the parser: the rosetta corpus is real Rust,
/// so a parse failure is a real gap rather than a hypothetical one.
fn runCorpusCheck(
    allocator: std.mem.Allocator,
    root: []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !?u8 {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        try stderr.print("Rust Error: cannot open corpus {s}: {s}\n", .{ root, @errorName(err) });
        return 1;
    };
    defer dir.close();

    var ok: usize = 0;
    var failed: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory and !std.mem.endsWith(u8, entry.name, ".rs")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name });
        defer allocator.free(path);
        if (entry.kind == .directory) {
            // One level of nesting is enough for the rosetta layout and keeps the
            // walk free of platform-specific recursive directory handling.
            var sub = std.fs.cwd().openDir(path, .{ .iterate = true }) catch continue;
            defer sub.close();
            var sit = sub.iterate();
            while (try sit.next()) |f| {
                if (!std.mem.endsWith(u8, f.name, ".rs")) continue;
                const sp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, f.name });
                defer allocator.free(sp);
                if (try parseOne(allocator, sp, stderr)) |_| {
                    ok += 1;
                } else {
                    failed += 1;
                }
            }
            continue;
        }
        if (try parseOne(allocator, path, stderr)) |_| {
            ok += 1;
        } else {
            failed += 1;
        }
    }
    try stdout.print("Rust Parser: {d} parsed, {d} failed under {s}.\n", .{ ok, failed, root });
    return if (failed == 0) 0 else 1;
}

fn parseOne(allocator: std.mem.Allocator, path: []const u8, stderr: std.io.AnyWriter) !?void {
    const src = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch {
        try stderr.print("Rust Error: cannot read {s}\n", .{path});
        return null;
    };
    defer allocator.free(src);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), src);
    const program = p.parseProgram() catch |err| {
        p.printDiagnostic(stderr, path, err) catch {};
        return null;
    };
    _ = program;
    return {};
}

fn runCheck(args: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) !?u8 {
    const opts = parseOptions(args);
    if (opts.help) {
        try stdout.writeAll(help_text);
        return 0;
    }
    if (opts.corpus) |root| return runCorpusCheck(std.heap.page_allocator, root, stdout, stderr);
    const file = opts.source orelse "main.rs";
    const allocator = std.heap.page_allocator;
    const check_opts = lowerOpts(opts);
    const result = (try compile(allocator, file, check_opts, stderr, opts.deny_unsupported)) orelse return 1;
    try reportUnsupported(stderr, result, file);
    try stdout.print("Rust Checker: {s} is valid ({d} functions).\n", .{ file, result.fn_count });
    return 0;
}

fn runBuildExe(args: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) !?u8 {
    const opts = parseOptions(args);
    if (opts.help) {
        try stdout.writeAll(help_text);
        return 0;
    }
    const file = opts.source orelse "main.rs";
    const allocator = std.heap.page_allocator;
    const result = (try compile(allocator, file, lowerOpts(opts), stderr, opts.deny_unsupported)) orelse return 1;
    try reportUnsupported(stderr, result, file);
    // The intermediate `.sa` keeps the source name; `--out` names the final
    // executable and is forwarded to `sa build-exe` as `-o`.
    const sa_path = try defaultSaPath(allocator, file);
    std.fs.cwd().writeFile(.{ .sub_path = sa_path, .data = result.sa }) catch |err| {
        try stderr.print("Rust Error: cannot write {s}: {s}\n", .{ sa_path, @errorName(err) });
        return 1;
    };
    try stdout.print("Rust Compiler: compiled {s} to {s}.\n", .{ file, sa_path });
    // `sa` is order-sensitive about options, so the forwarded flags go before
    // the output path.
    var fixed: std.ArrayList([]const u8) = .init(allocator);
    defer fixed.deinit();
    try fixed.append("build-exe");
    try fixed.append(sa_path);
    try fixed.appendSlice(opts.passthrough);
    if (opts.out) |o| {
        try fixed.append("-o");
        try fixed.append(o);
    }
    // The second half of the pipeline is the SA compiler itself.
    return spawnSa(allocator, fixed.items, &.{}, stderr);
}

fn runForward(
    args: []const []const u8,
    sa_subcommand: []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !?u8 {
    const opts = parseOptions(args);
    if (opts.help) {
        try stdout.writeAll(help_text);
        return 0;
    }
    const file = opts.source orelse "main.rs";
    const allocator = std.heap.page_allocator;
    const result = (try compile(allocator, file, lowerOpts(opts), stderr, opts.deny_unsupported)) orelse return 1;
    try reportUnsupported(stderr, result, file);
    const sa_path = try defaultSaPath(allocator, file);
    std.fs.cwd().writeFile(.{ .sub_path = sa_path, .data = result.sa }) catch |err| {
        try stderr.print("Rust Error: cannot write {s}: {s}\n", .{ sa_path, @errorName(err) });
        return 1;
    };
    return spawnSa(allocator, &.{ sa_subcommand, sa_path }, opts.passthrough, stderr);
}

fn spawnSa(
    allocator: std.mem.Allocator,
    fixed: []const []const u8,
    passthrough: []const []const u8,
    stderr: std.io.AnyWriter,
) !?u8 {
    var argv: std.ArrayList([]const u8) = .init(allocator);
    defer argv.deinit();
    const sa_exe = host_paths.resolveSaExecutable(allocator);
    defer allocator.free(sa_exe);
    try argv.append(sa_exe);
    try argv.appendSlice(fixed);
    try argv.appendSlice(passthrough);

    var child = std.process.Child.init(argv.items, allocator);
    const term = child.spawnAndWait() catch |err| {
        try stderr.print("Rust Error: cannot run 'sa {s}': {s}\n", .{ fixed[0], @errorName(err) });
        return 1;
    };
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn runSkills(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    stdout: std.io.AnyWriter,
) !?u8 {
    const json = ctx.json_mode or blk: {
        var j = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--json")) j = true;
        }
        break :blk j;
    };
    if (json) {
        try stdout.print("{{\"status\":\"ok\",\"skills\":[{{\"name\":\"{s}\",\"summary\":\"{s}\"}}]}}\n", .{
            plugin_skills.skills[0].name,
            plugin_skills.skills[0].summary,
        });
        return 0;
    }
    for (plugin_skills.skills) |s| {
        try stdout.print("{s}: {s}\n", .{ s.name, s.summary });
        for (s.items) |item| try stdout.print("  {s}\n", .{item});
    }
    return 0;
}

fn runInit(args: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) !?u8 {
    const allocator = std.heap.page_allocator;
    var root: []const u8 = ".";
    for (args[3..]) |a| {
        if (a.len > 0 and a[0] == '-') {
            if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
                try stdout.writeAll(help_text);
                return 0;
            }
            continue;
        }
        root = a;
        break;
    }
    std.fs.cwd().makePath(root) catch |err| {
        try stderr.print("Rust Error: cannot create {s}: {s}\n", .{ root, @errorName(err) });
        return 1;
    };
    const src_dir = try std.fs.path.join(allocator, &.{ root, "src" });
    std.fs.cwd().makePath(src_dir) catch {};
    const main_rs = try std.fs.path.join(allocator, &.{ src_dir, "main.rs" });
    const main_sa = try std.fs.path.join(allocator, &.{ src_dir, "main.sa" });
    writeNew(allocator, main_rs, "fn main() {\n    println!(\"hello from Rust on SA\");\n}\n") catch |err| {
        try stderr.print("Rust Error: cannot write {s}: {s}\n", .{ main_rs, @errorName(err) });
        return 1;
    };
    writeNew(allocator, main_sa, "// Generated by `sa rust build src/main.rs`.\n@import \"sa_std/io/print.sai\"\n\n@const GREETING = utf8:\"hello from Rust on SA\\n\"\n\n@main():\nL_ENTRY:\n    call @sa_print_bytes(&GREETING, 24)\n    return\n") catch |err| {
        try stderr.print("Rust Error: cannot write {s}: {s}\n", .{ main_sa, @errorName(err) });
        return 1;
    };
    try stdout.print("Created {s} and {s}.\n", .{ main_rs, main_sa });
    try stdout.print("Next: sa rust build-exe {s}\n", .{main_rs});
    return 0;
}

/// Never overwrite an existing file, so `init` is safe to re-run.
fn writeNew(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    _ = allocator;
    if (std.fs.cwd().access(path, .{})) |_| {
        return error.PathAlreadyExists;
    } else |_| {}
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = contents });
}

comptime {
    _ = UsageError;
}
