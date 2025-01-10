const std = @import("std");
const Allocator = std.mem.Allocator;

const GltfMeshPrimitive = struct {
    POSITION: ?usize = null,
    NORMAL: ?usize = null,
    TEXCOORD_0: ?usize = null,
};

const GltfComponentType = enum(u32) {
    float = 5126,
    ushort = 5123,

    fn toU32(self: GltfComponentType) u32 {
        return @intFromEnum(self);
    }
};

const GltfAccessorType = enum {
    SCALAR,
    VEC2,
    VEC3,
    VEC4,
    MAT2,
    MAT3,
    MAT4,
};

pub const GltfNode = struct {
    name: ?[]const u8 = null,
    mesh: ?usize = null,
    translation: ?[3]f32 = null,
};

pub const GltfMaterial = struct {
    name: ?[]const u8 = null,
    doubleSided: bool = true,
    pbrMetallicRoughness: ?struct {
        baseColorFactor: [4]f32,
        metallicFactor: f32,
        roughnessFactor: f32,
    } = null,
};

const GltfMesh = struct {
    name: ?[]const u8 = null,
    primitives: [1]struct {
        attributes: GltfMeshPrimitive = .{},
        material: ?usize = null,
    } = .{.{}},
};

const GltfAccessor = struct {
    bufferView: usize,
    componentType: u32,
    count: usize,
    @"type": []const u8,
};

const GltfBufferView = struct {
    buffer: usize,
    byteLength: usize,
    byteOffset: ?usize = null,
};

const GltfBuffer = struct {
    byteLength: usize,
    uri: []const u8,
};

const Gltf = struct {
    asset: struct {
        generator: []const u8,
        version: []const u8,
    },
    nodes: ?[]const GltfNode,
    meshes: ?[]const GltfMesh,
    accessors: ?[]const struct {
        bufferView: usize,
        componentType: u32,
        count: usize,
        @"type": []const u8,
    } = null,
    bufferViews: ?[]const struct {
        buffer: usize,
        byteLength: usize,
        byteOffset: ?usize = null,
    } = null,
    buffers: ?[]const struct {
        byteLength: usize,
        uri: []const u8,
    },
    materials: ?[]const GltfMaterial = null,
};

const Vec3 = @Vector(3, f32);

fn exportGltf(alloc: Allocator, mesh: []const f32, instances: []const Vec3, colors: []const Vec3, gltf_path: []const u8, bin_path: []const u8) !void {
    const nodes = try alloc.alloc(GltfNode, instances.len);
    defer alloc.free(nodes);

    const meshes = try alloc.alloc(GltfMesh, instances.len);
    defer alloc.free(meshes);

    std.debug.assert(instances.len == colors.len);

    const materials = try alloc.alloc(GltfMaterial, instances.len);
    defer alloc.free(materials);

    for (colors, materials) |color, *out_material| {
        out_material.* = .{
            .pbrMetallicRoughness = .{
                .baseColorFactor = .{ color[0], color[1], color[2], 1.0 },
                .metallicFactor = 0.0,
                .roughnessFactor = 1.0,
            },
        };
    }

    for (instances, nodes, meshes, 0..) |instance, *node, *out_mesh, idx| {
        node.* = .{
            .mesh = idx,
            .translation = instance,
        };

        out_mesh.* = .{
            .name = "mesh",
            .primitives = .{
                .{
                    .attributes = .{
                        .POSITION = 0,
                    },
                    .material = idx,
                }
            },
        };
    }

    {
        const bin_writer = try std.fs.cwd().createFile(bin_path, .{});
        defer bin_writer.close();
        _ = try bin_writer.writeAll(std.mem.sliceAsBytes(mesh));
    }

    const gltf = Gltf {
        .asset = .{
            .generator = ":)",
            .version = "2.0",
        },
        .nodes = nodes,
        .meshes = meshes,
        .accessors = &.{
            .{
                .bufferView = 0,
                .componentType = GltfComponentType.float.toU32(),
                .count = mesh.len / 3,
                .@"type" = @tagName(GltfAccessorType.VEC3),
            },
        },
        .bufferViews = &.{
            .{
                .buffer = 0,
                .byteLength = mesh.len * @sizeOf(f32),
                .byteOffset = 0,
            },
        },
        .buffers = &.{
            .{
                .uri = "test_gltf.bin",
                .byteLength = mesh.len * @sizeOf(f32),
            },
        },
        .materials = materials,
    };

    const gltf_file = try std.fs.cwd().createFile(gltf_path, .{});
    defer gltf_file.close();

    try std.json.stringify(gltf, .{ .whitespace = .indent_2, .emit_null_optional_fields = false}, gltf_file.writer());

}

const GltfAsset = struct {
    generator: []const u8,
    version: []const u8,
};

pub fn GltfExporter(comptime Writer: type) type {
    return struct {
        writer: std.json.WriteStream(Writer, .{ .checked_to_fixed_depth = 256 }),
        state: State = .root,
        written_fields: struct {
            nodes: bool = false,
            meshes: bool = false,
            accessors: bool = false,
            buffer_views: bool = false,
            buffers: bool = false,
            materials: bool = false,
        } = .{},

        const State = enum {
            root,
            write_nodes,
            write_meshes,
            write_accessors,
            write_buffer_views,
            write_buffers,
            write_materials,
        };
        const Self = @This();

        pub fn finish(self: *Self) !void {
            try self.closeToRoot();
            try self.writer.endObject();
            self.writer.deinit();
        }

        pub fn nodeWriter(self: *Self) !ArrayWriter(GltfNode) {
            return self.arrayWriter(GltfNode, "nodes", .write_nodes, &self.written_fields.nodes);
        }

        pub fn meshWriter(self: *Self) !ArrayWriter(GltfMesh) {
            // If we ever want to add support for multiple primitives, we will
            // have to make a wrapper type for the array writer
            return self.arrayWriter(GltfMesh, "meshes", .write_meshes, &self.written_fields.meshes);
        }

        pub fn accessorsWriter(self: *Self) !ArrayWriter(GltfAccessor) {
            return self.arrayWriter(GltfAccessor, "accessors", .write_accessors, &self.written_fields.accessors);
        }

        pub fn bufferViewsWriter(self: *Self) !ArrayWriter(GltfBufferView) {
            return self.arrayWriter(GltfBufferView, "bufferViews", .write_buffer_views, &self.written_fields.buffer_views);
        }

        pub fn buffersWriter(self: *Self) !ArrayWriter(GltfBuffer) {
            return self.arrayWriter(GltfBuffer, "buffers", .write_buffers, &self.written_fields.buffers);
        }

        pub fn materialsWriter(self: *Self) !ArrayWriter(GltfMaterial) {
            return self.arrayWriter(GltfMaterial, "materials", .write_materials, &self.written_fields.materials);
        }

        fn closeToRoot(self: *Self) !void {
            switch (self.state) {
                .root => {},
                .write_meshes,
                .write_nodes,
                .write_accessors,
                .write_buffer_views,
                .write_buffers,
                .write_materials,
                    => {
                    try self.writer.endArray();
                },
            }

            self.state = .root;
        }

        fn expectedState(comptime ElemType: type) State {
            return switch (ElemType) {
                GltfNode => .write_nodes,
                GltfMesh => .write_meshes,
                GltfBufferView => .write_buffer_views,
                GltfAccessor => .write_accessors,
                GltfBuffer => .write_buffers,
                GltfMaterial => .write_materials,
                else => @compileError("Unknown"),
            };
        }

        fn ArrayWriter(comptime ElemType: type) type {
            return struct {
                parent: *Self,

                fn append(self: *@This(), elem: ElemType) !void {
                    std.debug.assert(self.parent.state == expectedState(ElemType));
                    try self.parent.writer.write(elem);
                }
            };
        }

        fn arrayWriter(self: *Self, comptime T: type, key: []const u8, state: State, already_written: *bool) !ArrayWriter(T) {
            std.debug.assert(already_written.* == false);
            try self.closeToRoot();

            self.state = state;

            try self.writer.objectField(key);
            try self.writer.beginArray();

            already_written.* = true;

            return .{
                .parent = self,
            };

        }

    };
}

pub fn gltfExporter(writer: anytype) !GltfExporter(@TypeOf(writer)) {
    var json_writer = std.json.writeStream(writer, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    try json_writer.beginObject();

    try json_writer.objectField("asset");
    try json_writer.write(GltfAsset {
        .generator = "sphaero",
        .version = "2.0",
    });

    return .{
        .writer = json_writer,
    };
}

pub fn exportGltfScene(gltf_path: []const u8, mesh_path: []const u8, mesh: []const f32, nodes: anytype, materials: anytype) !void {
    {
        const mesh_f = try std.fs.cwd().createFile(mesh_path, .{});
        defer mesh_f.close();

        try mesh_f.writer().writeAll(std.mem.sliceAsBytes(mesh));
    }

    const f = try std.fs.cwd().createFile(gltf_path, .{});
    defer f.close();

    var gltf_exporter = try gltfExporter(f.writer());
    defer gltf_exporter.finish() catch {};

    {
        var bw = try gltf_exporter.buffersWriter();
        try bw.append(.{
            .byteLength = mesh.len * @sizeOf(f32),
            .uri = mesh_path,
        });
    }

    {
        var bw = try gltf_exporter.bufferViewsWriter();
        try bw.append(.{
            .byteLength = mesh.len * @sizeOf(f32),
            .byteOffset = 0,
            .buffer = 0,
        });
    }

    {
        var aw = try gltf_exporter.accessorsWriter();
        try aw.append(.{
            .componentType = @intFromEnum(GltfComponentType.float),
            .@"type" = "VEC3",
            .bufferView = 0,
            .count = mesh.len / 3,
        });
    }

    var num_materials: usize = 0;
    {
        var aw = try gltf_exporter.materialsWriter();

        while (materials.next()) |mat| {
            num_materials += 1;
            try aw.append(mat);
        }
    }

    {
        var mw = try gltf_exporter.meshWriter();
        for (0..num_materials) |mat_idx| {
            try mw.append(.{
                .primitives = .{
                    .{
                        .attributes = .{
                            .POSITION = 0,
                        },
                        .material = mat_idx,
                    },
                },
            });
        }
    }

    {
        var nw = try gltf_exporter.nodeWriter();
        while (nodes.next()) |node| {
            try nw.append(node);
        }
    }
}

pub fn main() !void {
    const f = try std.fs.cwd().createFile("test.gltf", .{});
    var gltf_exporter = try gltfExporter(f.writer());
    defer gltf_exporter.finish() catch {};

    var nw = try gltf_exporter.nodeWriter();
    try nw.append(.{
        .name = "hi",
    });
    try nw.append(.{
        .name = "mom",
    });

    var mw = try gltf_exporter.meshWriter();
    try mw.append(.{
        .name = "mesh1",
        .primitives = .{.{}},
    });
    try mw.append(.{
        .name = "mesh2",
        .primitives = .{.{}},
    });

    {
        var bw = try gltf_exporter.buffersWriter();
        try bw.append(.{
            .uri = "test.bin",
            .byteLength = 200,
        });
    }

    {
        var bw = try gltf_exporter.bufferViewsWriter();
        try bw.append(.{
            .byteLength = 200,
            .byteOffset = 0,
            .buffer = 0,
        });
    }

    {
        var aw = try gltf_exporter.accessorsWriter();
        try aw.append(.{
            .count = 10,
            .@"type" = "VEC3",
            .bufferView = 0,
            .componentType = 1234,
        });
    }
}
