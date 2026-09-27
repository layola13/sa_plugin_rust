const std = @import("std");

const is_windows_build = @import("builtin").os.tag == .windows;
const sa_exe_suffix: []const u8 = if (is_windows_build) ".exe" else "";

fn accessOk(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}


/// Build `dir/base` and return it only if it is runnable.
///
/// The candidate is freed on a miss: this runs once per `PATH` entry, and
/// leaking each one would grow with the environment.
fn probeExists(allocator: std.mem.Allocator, dir: []const u8, base: []const u8) ?[]const u8 {
    const candidate = std.fs.path.join(allocator, &.{ dir, base }) catch return null;
    if (accessOk(candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

/// Resolve the `sa` executable used for the second half of the pipeline.
///
/// Lookup order, mirroring sa_plugin_sla:
///   1. `$SA_EXE`
///   2. `$SCI_ROOT/zig-out/bin/sa`
///   3. next to the running `sa` that loaded this plugin
///   4. `$PATH`
///   5. the bare name `sa`
/// The returned string is always owned by the caller and must be freed with
/// `freeSaExecutable`. Returning a bare literal on the fallback path would leave
/// the caller unable to tell whether it owns the memory, which is a leak on one
/// path and a free-of-a-literal on the other.
pub fn resolveSaExecutable(allocator: std.mem.Allocator) []const u8 {
    const base = std.fmt.allocPrint(allocator, "sa{0s}", .{sa_exe_suffix}) catch
        return allocator.dupe(u8, "sa") catch "sa";

    if (std.process.getEnvVarOwned(allocator, "SA_EXE") catch null) |override_path| {
        defer allocator.free(override_path);
        if (override_path.len > 0 and accessOk(override_path)) {
            defer allocator.free(base);
            return allocator.dupe(u8, override_path) catch "sa";
        }
    }

    if (std.process.getEnvVarOwned(allocator, "SCI_ROOT") catch null) |sci_root| {
        defer allocator.free(sci_root);
        const dev_bin = std.fs.path.join(allocator, &.{ sci_root, "zig-out", "bin" }) catch return fallback(allocator, base);
        defer allocator.free(dev_bin);
        if (probeExists(allocator, dev_bin, base)) |hit| return hit;
    }

    if (std.fs.selfExePathAlloc(allocator)) |self_path| {
        defer allocator.free(self_path);
        if (std.fs.path.dirname(self_path)) |self_dir| {
            if (probeExists(allocator, self_dir, base)) |hit| return hit;
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "PATH") catch null) |path_val| {
        defer allocator.free(path_val);
        const sep: u8 = if (is_windows_build) ';' else ':';
        var it = std.mem.tokenizeAny(u8, path_val, &[_]u8{ sep, '\n' });
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            if (probeExists(allocator, entry, base)) |hit| return hit;
        }
    }

    return fallback(allocator, base);
}

/// The bare name, as an owned copy, for when nothing else was found. The OS
/// resolves it against `PATH` at spawn time.
fn fallback(allocator: std.mem.Allocator, base: []const u8) []const u8 {
    defer allocator.free(base);
    return allocator.dupe(u8, "sa") catch "sa";
}
