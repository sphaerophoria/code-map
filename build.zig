const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "");

    const treesitter = b.dependency("treesitter", .{});
    const treesitter_zig = b.dependency("treesitter_zig", .{});
    const sphui_dep = b.dependency("sphui", .{});
    const sphmath_dep = b.dependency("sphmath", .{});
    const sphrender_dep = b.dependency("sphrender", .{});

    const ts_zig = b.addSharedLibrary(.{
        .name = "treesitter_zig",
        .target = target,
        .optimize = opt,
        .link_libc = true,
    });
    ts_zig.addCSourceFile(.{
        .file = treesitter_zig.path("src/parser.c")
    });
    ts_zig.addIncludePath(treesitter_zig.path("src/tree_sitter"));
    b.installArtifact(ts_zig);

    const exe = b.addExecutable(.{
        .name = "code-map",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = opt,
    });

    exe.addCSourceFile(.{
        .file = treesitter.path("lib/src/lib.c"),
    });
    exe.addIncludePath(treesitter.path("lib/include"));
    exe.addIncludePath(treesitter.path("lib/src"));
    exe.linkLibC();
    b.installArtifact(exe);

    const ut = b.addTest(.{
        .name = "code-map-test",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = opt,
    });
    const run_ut = b.addRunArtifact(ut);
    test_step.dependOn(&run_ut.step);

    const vis = b.addExecutable(.{
        .name = "vis",
        .root_source_file = b.path("src/vis.zig"),
        .target = target,
        .optimize = opt,
    });
    vis.root_module.addImport("sphmath", sphmath_dep.module("sphmath"));
    vis.root_module.addImport("sphrender", sphrender_dep.module("sphrender"));
    vis.root_module.addImport("sphui", sphui_dep.module("sphui"));

    vis.linkSystemLibrary("glfw");
    vis.linkSystemLibrary("GL");
    vis.linkLibC();

    b.installArtifact(vis);
}
