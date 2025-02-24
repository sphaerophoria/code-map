const std = @import("std");
const Allocator = std.mem.Allocator;
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const ScratchAlloc = sphalloc.ScratchAlloc;
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const Db = @import("Db.zig");
const sphwindow = @import("sphwindow");
const vis_gui = @import("vis/gui.zig");
const Vis = @import("vis/Vis.zig");

fn openDb(gpa: Allocator, scratch: *ScratchAlloc, path: []const u8) !Db {
    const checkpoint = scratch.checkpoint();
    defer scratch.restore(checkpoint);

    const db_parsed = blk: {
        const saved_db_f = try std.fs.cwd().openFile(path, .{});
        defer saved_db_f.close();

        var json_reader = std.json.reader(scratch.allocator(), saved_db_f.reader());
        defer json_reader.deinit();

        break :blk try std.json.parseFromTokenSourceLeaky(Db.SaveData, scratch.allocator(), &json_reader, .{});
    };

    return try Db.load(gpa, db_parsed);
}

fn initGlParams() void {
    gl.glEnable(gl.GL_MULTISAMPLE);
    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);
}

pub fn main() !void {
    var tpa = sphalloc.TinyPageAllocator(100) {
        .page_allocator = std.heap.page_allocator,
    };

    var heap: Sphalloc = undefined;
    try heap.initPinned(tpa.allocator(), "root");

    var scratch = ScratchAlloc.init(try std.heap.page_allocator.alloc(u8, 10 * 1024 * 1024));

    const args = try std.process.argsAlloc(heap.general());

    var window: sphwindow.Window = undefined;
    const initial_window_width = 1100;
    const initial_window_height = 800;
    try window.initPinned("vis", initial_window_width, initial_window_height);

    var gl_alloc = try sphrender.GlAlloc.init(&heap);
    const scratch_gl = try gl_alloc.makeSubAlloc(&heap);
    const render_alloc = sphrender.RenderAlloc.init(&heap, &gl_alloc);

    initGlParams();

    var db = try openDb(heap.general(), &scratch, args[1]);

    var vis = try Vis.init(render_alloc, &scratch, &db);

    var gui: vis_gui.Gui = undefined;
    try gui.initPinned(render_alloc, &scratch, scratch_gl, &vis, &window);

    while (!window.closed()) {
        scratch.reset();
        scratch_gl.reset();

        const action = try gui.step(&window);

        if (action) |a| {
            try vis_gui.applyGuiAction(a, &scratch, &vis, &gui);
        }

        window.swapBuffers();
    }
}
