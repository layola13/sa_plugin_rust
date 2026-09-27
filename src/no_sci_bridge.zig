//! Stand-in for `sci/src/plugin_bridge.zig` when the plugin is built outside a
//! `sci` workspace. The Rust front end never needs it: `.rs -> .sa` is pure
//! in-process code, and `.sa -> exe` shells out to the `sa` executable.
comptime {
    _ = @This();
}
