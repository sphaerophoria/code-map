const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphwindow = @import("sphwindow");
const gl = sphrender.gl;

fn lastMtime(path: []const u8) !i128 {
    const stat = try std.fs.cwd().statFile(path);
    return stat.mtime;
}

const ShaderProgram = sphrender.xyuvt_program.Program(struct{});

fn loadProgram(alloc: Allocator, shader_path: []const u8) !ShaderProgram {
    const shader_f = try std.fs.cwd().openFile(shader_path, .{});
    defer shader_f.close();

    const fs = try shader_f.readToEndAllocOptions(alloc, 1<<20, null, 4, 0);
    defer alloc.free(fs);

    return try ShaderProgram.init(fs);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var window: sphwindow.Window = undefined;
    try window.initPinned("sphadertoy", 800, 800);

    const shader_path = args[1];

    var prog = try loadProgram(alloc, shader_path);
    defer prog.deinit();

    var prog_buf = prog.makeFullScreenPlane();
    defer prog_buf.deinit();

    var last_mtime = try lastMtime(shader_path);

    while (!window.closed()) {
        blk: {
            const shader_mtime = lastMtime(shader_path) catch break :blk;
            if (shader_mtime != last_mtime) {
                const new_prog = loadProgram(alloc, shader_path) catch {
                    break :blk;
                };
                errdefer new_prog.deinit();

                const new_buf = new_prog.makeFullScreenPlane();
                errdefer new_buf.deinit();

                prog.deinit();
                prog_buf.deinit();

                prog = new_prog;
                prog_buf = new_buf;
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
