const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "code-map",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = opt,
    });

    b.installArtifact(exe);
}
