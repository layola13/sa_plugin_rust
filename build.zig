const std = @import("std");

/// Dev installs run in Debug even when ReleaseFast is requested, matching
/// sa_plugin_sla so a dev-mode plugin install stays fast to rebuild.
fn effectiveOptimizeForDevInstall(b: *std.Build, requested: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    if (requested != .ReleaseFast) return requested;
    const value = std.process.getEnvVarOwned(b.allocator, "SA_PLUGIN_DEV") catch return requested;
    defer b.allocator.free(value);
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) return .Debug;
    return requested;
}

/// `b.path()` rejects absolute paths but SCI_ROOT may be absolute.
fn lazyPath(b: *std.Build, p: []const u8) std.Build.LazyPath {
    return b.path(p);
}

/// True when `root`/`rel` names an existing file. `root` may be relative, in
/// which case it is resolved against the process working directory.
fn dirHasFile(root: []const u8, rel: []const u8) bool {
    if (std.fs.path.isAbsolute(rel)) {
        std.fs.cwd().access(rel, .{}) catch return false;
        return true;
    }
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return false;
    defer dir.close();
    dir.access(rel, .{}) catch return false;
    return true;
}

/// Relative locations of the sibling `sci` checkout.
const sibling_roots = [_][]const u8{ "../../../sci", "../sci" };

/// Locate the `sci` repository that provides `src/plugin_bridge.zig`.
fn resolveRepoRoot(b: *std.Build) ?[]const u8 {
    // Only a relative root is usable: `b.path` rejects absolute paths.
    if (std.process.getEnvVarOwned(b.allocator, "SCI_ROOT_REL") catch null) |sci_root| {
        defer b.allocator.free(sci_root);
        if (!std.fs.path.isAbsolute(sci_root) and dirHasFile(sci_root, "src/plugin_bridge.zig")) {
            return b.allocator.dupe(u8, sci_root) catch sci_root;
        }
    }

    for (sibling_roots) |rel| {
        if (dirHasFile(rel, "src/plugin_bridge.zig")) return b.allocator.dupe(u8, rel) catch rel;
    }

    // An absolute `SCI_ROOT` is deliberately ignored: `b.path` cannot take one.
    // Set `SCI_ROOT_REL=../sci` to wire up the in-process bridge.

    return null;
}

fn linkHostSystemLibs(compile: *std.Build.Step.Compile, is_windows: bool) void {
    if (!is_windows) return;
    compile.linkSystemLibrary("ws2_32");
    compile.linkSystemLibrary("iphlpapi");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const requested_optimize = b.standardOptimizeOption(.{});
    const optimize = effectiveOptimizeForDevInstall(b, requested_optimize);
    const test_filter = b.option([]const u8, "test-filter", "Only run Zig tests whose name contains this filter.");
    const is_windows = target.result.os.tag == .windows;

    // The `sci` checkout is only needed for the optional `sci_bridge` module
    // (in-process flattener/verifier access). The `.rs -> .sa` path is pure
    // in-process code and the `.sa -> exe` step shells out to `sa`, so a plugin
    // built outside a `sci` workspace must still compile.
    const repo_root = resolveRepoRoot(b);

    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });

    const rust_build_options = b.addOptions();
    rust_build_options.addOption([]const u8, "plugin_name", "rust");

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);
    root_module.addOptions("rust_build_options", rust_build_options);

    if (repo_root) |root| {
        root_module.addAnonymousImport("sci_bridge", .{
            .root_source_file = b.path(b.pathJoin(&.{ root, "src/plugin_bridge.zig" })),
            .target = target,
            .optimize = optimize,
        });
    } else {
        root_module.addAnonymousImport("sci_bridge", .{
            .root_source_file = b.path("src/no_sci_bridge.zig"),
            .target = target,
            .optimize = optimize,
        });
    }

    // --- dynamic library consumed by the `sa` plugin host ---
    const lib = b.addLibrary(.{
        .name = "rust",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    linkHostSystemLibs(lib, is_windows);
    b.installArtifact(lib);

    const install_sap = b.addInstallFile(b.path("sap.json"), "lib/sap.json");
    b.getInstallStep().dependOn(&install_sap.step);

    // --- standalone `rust` driver (no host process required) ---
    const local_cli_module = b.createModule(.{
        .root_source_file = b.path("src/local_cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    local_cli_module.addImport("plugin_api", plugin_api);
    local_cli_module.addOptions("rust_build_options", rust_build_options);
    if (repo_root) |root| {
        local_cli_module.addAnonymousImport("sci_bridge", .{
            .root_source_file = b.path(b.pathJoin(&.{ root, "src/plugin_bridge.zig" })),
            .target = target,
            .optimize = optimize,
        });
    } else {
        local_cli_module.addAnonymousImport("sci_bridge", .{
            .root_source_file = b.path("src/no_sci_bridge.zig"),
            .target = target,
            .optimize = optimize,
        });
    }

    const local_cli = b.addExecutable(.{
        .name = "rust",
        .root_module = local_cli_module,
    });
    linkHostSystemLibs(local_cli, is_windows);
    b.installArtifact(local_cli);

    const run_local_cli = b.addRunArtifact(local_cli);
    run_local_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_local_cli.addArgs(args);
    const local_cli_step = b.step("local-cli", "Run the local Rust plugin CLI driver");
    local_cli_step.dependOn(&run_local_cli.step);

    // --- end-to-end suite ---
    // `zig build test` never spawns the host `sa`, so it cannot see capability
    // mismatches, use-after-move on derived pointers or leaks at function exit.
    // Those only appear once the Referee runs the program, so the suite compiles
    // and executes each fixture and diffs the real output.
    const e2e_step = b.step("e2e", "Compile and run the end-to-end fixtures");
    e2e_step.dependOn(b.getInstallStep());
    const run_e2e = b.addSystemCommand(&.{"sh"});
    run_e2e.addFileArg(b.path("tools/e2e.sh"));
    e2e_step.dependOn(&run_e2e.step);

    // --- tests ---
    const main_tests = b.addTest(.{
        .root_module = root_module,
        .filter = test_filter,
    });
    linkHostSystemLibs(main_tests, is_windows);
    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_main_tests.step);

    // --- batched test binary (sliced runner for low-memory hosts) ---
    const batch_tests = b.addTest(.{
        .root_module = root_module,
        .test_runner = .{ .path = b.path("src/batch_test_runner.zig"), .mode = .simple },
    });
    linkHostSystemLibs(batch_tests, is_windows);
    const install_batch_tests = b.addInstallArtifact(batch_tests, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
    });
    const batch_build_step = b.step("test-batch-build", "Build the batched test binary");
    batch_build_step.dependOn(&install_batch_tests.step);
}
