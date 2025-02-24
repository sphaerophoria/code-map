const std = @import("std");
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const ScratchAlloc = sphalloc.ScratchAlloc;
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphwindow = @import("sphwindow");
const gl = sphrender.gl;

fn lastMtime(path: []const u8) !i128 {
    const stat = try std.fs.cwd().statFile(path);
    return stat.mtime;
}

const ShaderProgram = sphrender.xyuvt_program.Program(struct {});

fn loadProgram(gl_alloc: *sphrender.GlAlloc, scratch: *ScratchAlloc, shader_path: []const u8) !ShaderProgram {
    const checkpoint = scratch.checkpoint();
    defer scratch.restore(checkpoint);

    const shader_f = try std.fs.cwd().openFile(shader_path, .{});
    defer shader_f.close();

    const fs_buf = try scratch.allocator().alloc(u8, 1 << 20);
    const fs_len = try shader_f.readAll(fs_buf);
    fs_buf[fs_len] = 0;

    return try ShaderProgram.init(gl_alloc, @ptrCast(fs_buf[0..fs_len]));
}

pub fn main() !void {
    var tpa = sphalloc.TinyPageAllocator(100){
        .page_allocator = std.heap.page_allocator,
    };

    var scratch = ScratchAlloc.init(try std.heap.page_allocator.alloc(u8, 10 * 1024 * 1024));

    var root_alloc: Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    var root_gl = try sphrender.GlAlloc.init(&root_alloc);
    var render_alloc = sphrender.RenderAlloc.init(&root_alloc, &root_gl);

    const args = try std.process.argsAlloc(root_alloc.arena());

    var window: sphwindow.Window = undefined;
    try window.initPinned("sphadertoy", 800, 800);

    const shader_path = args[1];

    var shader_alloc = try render_alloc.makeSubAlloc("shader");
    var prog = try loadProgram(shader_alloc.gl, &scratch, shader_path);
    var prog_buf = try prog.makeFullScreenPlane(shader_alloc.gl);

    var last_mtime = try lastMtime(shader_path);

    while (!window.closed()) {
        scratch.reset();
        blk: {
            const shader_mtime = lastMtime(shader_path) catch break :blk;
            if (shader_mtime != last_mtime) {
                const new_alloc = try render_alloc.makeSubAlloc("shader");

                // FIXME: Program will be invalid if program was invalid
                prog = try loadProgram(new_alloc.gl, &scratch, shader_path);
                prog_buf = try prog.makeFullScreenPlane(new_alloc.gl);

                shader_alloc.deinit();
                shader_alloc = new_alloc;

                last_mtime = shader_mtime;
            }
        }

        const window_size = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(window_size[0]), @intCast(window_size[1]));
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        prog.render(prog_buf, .{});

        window.queue.discard(window.queue.count);
        window.swapBuffers();
    }
}
