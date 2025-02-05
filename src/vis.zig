const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const Db = @import("Db.zig");
const sphwindow = @import("sphwindow");
const vis_gui = @import("vis/gui.zig");
const Vis = @import("vis/Vis.zig");

fn openDb(alloc: Allocator, path: []const u8) !Db {
    const db_parsed = blk: {
        const saved_db_f = try std.fs.cwd().openFile(path, .{});
        defer saved_db_f.close();

        var json_reader = std.json.reader(alloc, saved_db_f.reader());
        defer json_reader.deinit();

        break :blk try std.json.parseFromTokenSource(Db.SaveData, alloc, &json_reader, .{});
    };
    defer db_parsed.deinit();

    return try Db.load(alloc, db_parsed.value);
}

fn initGlParams() void {
    gl.glEnable(gl.GL_MULTISAMPLE);
    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var window: sphwindow.Window = undefined;
    const initial_window_width = 1100;
    const initial_window_height = 800;
    try window.initPinned("vis", initial_window_width, initial_window_height);

    initGlParams();

    var db = try openDb(alloc, args[1]);
    defer db.deinit(alloc);

    var vis = try Vis.init(alloc, &db);
    defer vis.deinit(alloc);

    var gui: vis_gui.Gui = undefined;
    try gui.initPinned(alloc, arena.allocator(), &vis, &window);
    defer gui.deinit(alloc);

    while (!window.closed()) {
        _ = arena.reset(.{ .retain_with_limit = 1 << 20 });

        const action = try gui.step(&window);

        if (action) |a| {
            try vis_gui.applyGuiAction(a, alloc, &vis, &gui);
        }

        window.swapBuffers();
    }
}
