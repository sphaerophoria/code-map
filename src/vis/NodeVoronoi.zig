const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const geometry = sphrender.geometry;
const Texture = sphrender.Texture;

program: gl.GLuint,

// FIXME: Probably name will change
const NodeVornoi = @This();

const num_cone_points = 20;
const num_cone_triangles = num_cone_points * 2;
const num_cone_verts = num_cone_triangles * 3;
const depth_radius = 2 * std.math.sqrt2;

pub fn init() !NodeVornoi {
    const program = try sphrender.compileLinkProgram(distance_field_vertex_shader, distance_field_fragment_shader);
    errdefer gl.glDeleteProgram(program);

    return .{
        .program = program,
    };
}

pub fn deinit(self: NodeVornoi) void {
    gl.glDeleteProgram(self.program);
}

const Locs = struct {
    vpos: gl.GLuint,
    cone_offs: gl.GLuint,
    color: gl.GLuint,
    inner_radius: gl.GLuint,
    outer_radius: gl.GLuint,
    inner_depth: gl.GLuint,
    outer_depth: gl.GLuint,
};

pub fn makeConeBuf(self: NodeVornoi) !InstancedRenderBuffer {
    const locs = Locs{
        .vpos = std.math.cast(gl.GLuint, gl.glGetAttribLocation(self.program, "vPos")) orelse return error.NoVpos,
        .cone_offs = std.math.cast(gl.GLuint, gl.glGetAttribLocation(self.program, "vOffs")) orelse return error.NovOffs,
        .color = std.math.cast(gl.GLuint, gl.glGetAttribLocation(self.program, "vColor")) orelse return error.NovColor,
        .inner_radius = std.math.cast(gl.GLuint, gl.glGetAttribLocation(self.program, "vInnerRadius")) orelse return error.NovInnerRadius,
        .outer_radius = std.math.cast(gl.GLuint, gl.glGetAttribLocation(self.program, "vOuterRadius")) orelse return error.NovOuterRadius,
        .inner_depth = std.math.cast(gl.GLuint, gl.glGetAttribLocation(self.program, "vInnerDepth")) orelse return error.NovInnerDepth,
        .outer_depth = std.math.cast(gl.GLuint, gl.glGetAttribLocation(self.program, "vOuterDepth")) orelse return error.NovOuterDepth,
    };

    const cone_buf = try genCone(locs);
    return cone_buf;
}

pub fn render(self: NodeVornoi, cone_buf: InstancedRenderBuffer, transform: sphmath.Transform3D) !void {
    gl.glEnable(gl.GL_DEPTH_TEST);
    // FIXME: Restore initial state, don't hard disable
    defer gl.glDisable(gl.GL_DEPTH_TEST);

    {
        clearBuffers();

        gl.glUseProgram(self.program);

        gl.glBindVertexArray(cone_buf.vao);
        gl.glDrawArraysInstanced(gl.GL_TRIANGLES, 0, num_cone_verts, @intCast(cone_buf.num_items));
        const uniform_loc = gl.glGetUniformLocation(self.program, "transform");
        gl.glUniformMatrix4fv(uniform_loc, 1, gl.GL_TRUE, &transform.inner.data);
    }
}

// Abstraction around inputs for the distance field generator program. A
// mesh (cone or tent) is instanced at a location with some transformations
// applied to it
pub const InstancedRenderBuffer = struct {
    mesh_vbo: gl.GLuint, // mesh data
    instance_vbo: gl.GLuint, // instance data
    vao: gl.GLuint,
    num_items: usize,

    locs: Locs,

    const mesh_binding_index = 0;
    const offsets_binding_index = 1;

    fn init(locs: Locs) InstancedRenderBuffer {
        var vertex_buffer: gl.GLuint = 0;
        gl.glCreateBuffers(1, &vertex_buffer);

        var instance_vbo: gl.GLuint = 0;
        gl.glCreateBuffers(1, &instance_vbo);

        var vertex_array: gl.GLuint = 0;
        gl.glCreateVertexArrays(1, &vertex_array);

        gl.glEnableVertexArrayAttrib(vertex_array, locs.vpos);

        gl.glVertexArrayVertexBuffer(vertex_array, mesh_binding_index, vertex_buffer, 0, @sizeOf(sphmath.Vec3));
        gl.glVertexArrayAttribFormat(vertex_array, locs.vpos, 3, gl.GL_FLOAT, gl.GL_FALSE, 0);
        gl.glVertexArrayAttribBinding(vertex_array, locs.vpos, mesh_binding_index);

        return .{
            .mesh_vbo = vertex_buffer,
            .instance_vbo = instance_vbo,
            .vao = vertex_array,
            .locs = locs,
            .num_items = 0,
        };
    }

    pub fn deinit(self: InstancedRenderBuffer) void {
        gl.glDeleteBuffers(1, &self.mesh_vbo);
        gl.glDeleteBuffers(1, &self.instance_vbo);
        gl.glDeleteVertexArrays(1, &self.vao);
    }

    pub fn setMeshData(self: InstancedRenderBuffer, points: []const sphmath.Vec3) void {
        gl.glNamedBufferData(
            self.mesh_vbo,
            @intCast(points.len * @sizeOf(sphmath.Vec3)),
            points.ptr,
            gl.GL_STATIC_DRAW,
        );
    }

    pub const InstanceData = struct {
        offset: sphmath.Vec2,
        color: sphmath.Vec3,
        inner_radius: f32 = 0.0,
        outer_radius: f32 = depth_radius,
        inner_depth: f32 = 0.0,
        outer_depth: f32 = 1.0,
    };

    pub fn setOffsetData(self: *InstancedRenderBuffer, offsets: []const InstanceData) void {
        gl.glEnableVertexArrayAttrib(self.vao, self.locs.cone_offs);
        gl.glEnableVertexArrayAttrib(self.vao, self.locs.color);
        gl.glEnableVertexArrayAttrib(self.vao, self.locs.inner_radius);
        gl.glEnableVertexArrayAttrib(self.vao, self.locs.outer_radius);
        gl.glEnableVertexArrayAttrib(self.vao, self.locs.inner_depth);
        gl.glEnableVertexArrayAttrib(self.vao, self.locs.outer_depth);

        gl.glVertexArrayVertexBuffer(self.vao, offsets_binding_index, self.instance_vbo, 0, @sizeOf(InstanceData));

        gl.glVertexArrayAttribFormat(self.vao, self.locs.cone_offs, 2, gl.GL_FLOAT, gl.GL_FALSE, @offsetOf(InstanceData, "offset"));
        gl.glVertexArrayAttribBinding(self.vao, self.locs.cone_offs, offsets_binding_index);

        gl.glVertexArrayAttribFormat(self.vao, self.locs.color, 3, gl.GL_FLOAT, gl.GL_FALSE, @offsetOf(InstanceData, "color"));
        gl.glVertexArrayAttribBinding(self.vao, self.locs.color, offsets_binding_index);

        gl.glVertexArrayAttribFormat(self.vao, self.locs.inner_radius, 1, gl.GL_FLOAT, gl.GL_FALSE, @offsetOf(InstanceData, "inner_radius"));
        gl.glVertexArrayAttribBinding(self.vao, self.locs.inner_radius, offsets_binding_index);

        gl.glVertexArrayAttribFormat(self.vao, self.locs.outer_radius, 1, gl.GL_FLOAT, gl.GL_FALSE, @offsetOf(InstanceData, "outer_radius"));
        gl.glVertexArrayAttribBinding(self.vao, self.locs.outer_radius, offsets_binding_index);

        gl.glVertexArrayAttribFormat(self.vao, self.locs.inner_depth, 1, gl.GL_FLOAT, gl.GL_FALSE, @offsetOf(InstanceData, "inner_depth"));
        gl.glVertexArrayAttribBinding(self.vao, self.locs.inner_depth, offsets_binding_index);

        gl.glVertexArrayAttribFormat(self.vao, self.locs.outer_depth, 1, gl.GL_FLOAT, gl.GL_FALSE, @offsetOf(InstanceData, "outer_depth"));
        gl.glVertexArrayAttribBinding(self.vao, self.locs.outer_depth, offsets_binding_index);

        gl.glNamedBufferData(
            self.instance_vbo,
            @intCast(offsets.len * @sizeOf(InstanceData)),
            offsets.ptr,
            gl.GL_STATIC_DRAW,
        );
        gl.glVertexArrayBindingDivisor(self.vao, offsets_binding_index, 1);
        self.num_items = offsets.len;
    }
};

pub fn genConeVertices() [num_cone_verts]sphmath.Vec3 {
    var cone_points: [num_cone_verts]sphmath.Vec3 = undefined;
    var i: usize = 0;
    var cone_it = geometry.ConeSegmentGenerator.init(num_cone_points, 1.0, 1.0, 0.0, 1.0);
    while (cone_it.next()) |tri| {
        for (tri) |point| {
            cone_points[i] = point;
            i += 1;
        }
    }
    return cone_points;
}

fn genCone(locs: Locs) !InstancedRenderBuffer {
    const cone_points = genConeVertices();
    var ret = InstancedRenderBuffer.init(locs);
    ret.setMeshData(&cone_points);

    return ret;
}

fn clearBuffers() void {
    //gl.glClearColor(0.0, 0.0, 0.0, 1.0);
    gl.glClearDepth(std.math.inf(f32));
    gl.glClear(gl.GL_DEPTH_BUFFER_BIT);
}

fn calcAspectCorrection(width: usize, height: usize) sphmath.Vec2 {
    const aspect = sphmath.calcAspect(width, height);
    if (aspect > 1.0) {
        return .{ 1.0, aspect };
    } else {
        return .{ 1.0 / aspect, 1.0 };
    }
}

fn updateBuffers(self: NodeVornoi, alloc: Allocator, point_it: anytype, aspect_correction: sphmath.Vec2) !usize {
    var cone_offsets = std.ArrayList(sphmath.Vec2).init(alloc);
    defer cone_offsets.deinit();

    while (point_it.next()) |item| {
        const p = switch (item) {
            .new_line => |p| {
                try cone_offsets.append(p / aspect_correction);
                continue;
            },
            .line_point => |p| p / aspect_correction,
        };
        try cone_offsets.append(p);
    }

    self.cone_buf.setOffsetData(cone_offsets.items);

    return cone_offsets.items.len;
}

const distance_field_vertex_shader =
    \\#version 330
    \\in vec3 vPos;
    \\in vec2 vOffs;
    \\in float vInnerRadius;
    \\in float vOuterRadius;
    \\in float vInnerDepth;
    \\in float vOuterDepth;
    \\in vec3 vColor;
    \\in float vDistThresh;
    \\out vec3 color;
    \\uniform mat4x4 transform;
    \\void main()
    \\{
    \\    vec3 cone_points = vPos;
    \\    if (vPos.z == -1000.0) {
    \\        cone_points.xy *= vInnerRadius;
    \\        cone_points.xy *= vOuterRadius;
    \\}
    \\    if (vPos.z < 0.5) {
    \\        cone_points.xy *= vInnerRadius;
    \\        cone_points.z = vInnerDepth;
    \\    } else {
    \\        cone_points.xy *= vOuterRadius;
    \\        cone_points.z = vOuterDepth;
    \\    }
    \\
    \\    gl_Position = transform * vec4(cone_points.xy + vOffs, cone_points.z, 1.0);
    \\    color = vColor;
    \\}
;

const distance_field_fragment_shader =
    \\#version 330 core
    \\out vec4 fragment;
    \\in vec3 color;
    \\void main()
    \\{
    \\    fragment = vec4(color, 1.0);
    \\}
;
