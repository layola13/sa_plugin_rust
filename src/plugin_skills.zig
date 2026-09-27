const plugin_api = @import("plugin_api.zig");

pub const skills = [_]plugin_api.SkillSection{
    .{
        .name = "rust",
        .summary = "Compile Rust (.rs) to SA-ASM and build native executables",
        .items = &.{
            "rust init [path]",
            "rust build main.rs --out main.sa",
            "rust build-exe main.rs -o main",
            "rust check main.rs",
            "rust test main.rs",
            "rust run main.rs",
            "rust skills --json",
        },
    },
};
