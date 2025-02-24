const std = @import("std");
const Allocator = std.mem.Allocator;
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const sphrender = @import("sphrender");
const sphmath = @import("sphmath");
const Db = @import("../Db.zig");
const Vec2 = sphmath.Vec2;
const StarColorAssigner = @import("StarColorAssigner.zig");

program: Program,
buffer: sphrender.shader_program.Buffer(StarElem),

const NodeRenderer = @This();

pub fn init(gl_alloc: *sphrender.GlAlloc) !NodeRenderer {
    const program = try Program.init(gl_alloc, star_vert_shader, star_frag_shader);
    const buffer = try program.makeBuffer(gl_alloc, &.{});

    return .{
        .program = program,
        .buffer = buffer,
    };
}

// FIXME: Stars is a bad name now
pub fn render(self: *NodeRenderer, scratch: *ScratchAlloc, colors: *const StarColorAssigner, positions: Db.ExtraData(Vec2), weights: Db.ExtraData(f32), point_radius: f32) !void {
    try updateNodeBuffer(scratch, &self.buffer, positions, weights, colors, point_radius);
    self.program.render(self.buffer, .{});
}

pub const star_vert_shader = @embedFile("shader/star/vertex.glsl");
pub const star_frag_shader = @embedFile("shader/star/fragment.glsl");

const EmptyUniform = struct {};
const StarElem = packed struct {
    vPos: sphmath.Vec2,
    vUv: sphmath.Vec2,
    vColor: sphmath.Vec3,
};

const Program = sphrender.shader_program.Program(StarElem, EmptyUniform);

fn updateNodeBuffer(scratch: *ScratchAlloc, buf: *sphrender.shader_program.Buffer(StarElem), positions: Db.ExtraData(Vec2), weights: Db.ExtraData(f32), star_colors: *const StarColorAssigner, default_circle_radius: f32) !void {
    const checkpoint = scratch.checkpoint();
    defer scratch.restore(checkpoint);

    // FIXME: boo array list
    var buf_points = std.ArrayList(StarElem).init(scratch.allocator());

    var it = positions.idIter();
    while (it.next()) |node_id| {
        const pos = positions.get(node_id);
        const weight = weights.get(node_id);
        const circle_radius = default_circle_radius * std.math.sqrt(weight);
        const color = star_colors.get(node_id);

        const tl = StarElem{
            .vPos = .{ pos[0] - circle_radius, pos[1] + circle_radius },
            .vUv = .{ 0.0, 1.0 },
            .vColor = color,
        };

        const bl = StarElem{
            .vPos = .{
                pos[0] - circle_radius,
                pos[1] - circle_radius,
            },
            .vUv = .{
                0.0,
                0.0,
            },
            .vColor = color,
        };

        const tr = StarElem{
            .vPos = .{
                pos[0] + circle_radius,
                pos[1] + circle_radius,
            },
            .vUv = .{
                1.0,
                1.0,
            },
            .vColor = color,
        };

        const br = StarElem{
            .vPos = .{
                pos[0] + circle_radius,
                pos[1] - circle_radius,
            },
            .vUv = .{
                1.0,
                0.0,
            },
            .vColor = color,
        };

        try buf_points.appendSlice(&.{
            bl, tl, tr,
            bl, tr, br,
        });
    }

    buf.updateBuffer(buf_points.items);
}
