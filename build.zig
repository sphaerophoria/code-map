const std = @import("std");
const builtin = @import("builtin");

fn installArtifactWithCheck(b: *std.Build, artifact: *std.Build.Step.Compile, check_step: *std.Build.Step) void {
    const duped = b.allocator.create(std.Build.Step.Compile) catch unreachable;
    duped.* = artifact.*;
    check_step.dependOn(&duped.step);
    b.installArtifact(artifact);
}

fn makeZls(b: *std.Build) void {
    const cmd = b.addSystemCommand(&.{"zig", "build", "-Doptimize=ReleaseSafe"});
    cmd.setCwd(b.path("zls"));
    b.getInstallStep().dependOn(&cmd.step);
}

fn makeDbTestTarball(b: *std.Build) std.Build.LazyPath {
    // Make a tarball, but make the file list manually. Zigs build system seems
    // to cache hit even when directory contents change, which means we need to
    // force a cache miss ourselves in this case.
    //
    // Force generate a new file list on every build run, then let the zig
    // cache system decide if it wants to re-tar based off the contents of the
    // generated file
    const make_file_list_exe = b.addExecutable(.{
        .name = "make-file-list",
        .root_source_file = b.path("src/test/make_test_tarball_list.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug
    });

    const run_make_file_list = b.addRunArtifact(make_file_list_exe);
    run_make_file_list.addDirectoryArg(b.path("res/test"));
    const file_list = run_make_file_list.addOutputFileArg("list.txt");
    // Directory arg is not sufficient to force a rerun
    run_make_file_list.has_side_effects = true;

    const cmd = b.addSystemCommand(&.{
        "tar",
        "cf",
    });

    const output_path = cmd.addOutputFileArg("test.tar");
    cmd.addArgs(&.{
        "-C",
    });
    cmd.addDirectoryArg(b.path("res/test"));
    cmd.addArgs(&.{"-T"});
    cmd.addFileArg(file_list);

    return output_path;
}

pub fn build(b: *std.Build) void {
    const check_step = b.step("check", "");

    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "");
    const with_zls = b.option(bool, "zls", "build custom zls") orelse true;

    const treesitter = b.dependency("treesitter", .{});
    const treesitter_zig = b.dependency("treesitter_zig", .{});
    const sphui_dep = b.dependency("sphui", .{});
    const sphmath_dep = b.dependency("sphmath", .{});
    const sphrender_dep = b.dependency("sphrender", .{});
    const sphwindow_dep = b.dependency("sphwindow", .{});

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

    if (with_zls) {
        makeZls(b);
    }

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
    installArtifactWithCheck(b, exe, check_step);

    const test_tar = makeDbTestTarball(b);
    const ut = b.addTest(.{
        .name = "code-map-test",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = opt,
    });
    ut.root_module.addAnonymousImport("test_tarball", .{
        .root_source_file = test_tar,
    });
    ut.root_module.addAnonymousImport("zig_so", .{
        .root_source_file = ts_zig.getEmittedBin(),
    });
    ut.root_module.addAnonymousImport("zig_config", .{
        .root_source_file = b.path("res/config.json"),
    });
    ut.addCSourceFile(.{
        .file = treesitter.path("lib/src/lib.c"),
    });
    ut.addIncludePath(treesitter.path("lib/include"));
    ut.addIncludePath(treesitter.path("lib/src"));
    ut.linkLibC();

    b.installArtifact(ut);
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
    vis.root_module.addImport("sphwindow", sphwindow_dep.module("sphwindow"));

    vis.linkSystemLibrary("GL");
    vis.linkLibC();

    installArtifactWithCheck(b, vis, check_step);
}
