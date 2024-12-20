const std = @import("std");

pub fn build(b: *std.Build) !void {

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const mod_a = b.createModule(.{
        .root_source_file = b.path("src/libA/a.zig")
    });

    const mod_b = b.createModule(.{
        .root_source_file = b.path("src/libB/b.zig")
    });
    mod_b.addImport("mod_a", mod_a);

    const exe = b.addExecutable(.{
        .name = "test",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mod_a", mod_a);
    exe.root_module.addImport("mod_b", mod_b);

    b.installArtifact(exe);
}
