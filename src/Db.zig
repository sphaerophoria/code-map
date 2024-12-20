const std = @import("std");
const Allocator = std.mem.Allocator;
const coords = @import("coords.zig");
const TextRange = coords.TextRange;
const TextPosition = coords.TextPosition;

nodes: std.ArrayListUnmanaged(Node) = .{},

const Db = @This();

pub fn deinit(self: *Db, alloc: Allocator) void {
    for (self.nodes.items) |*node| {
        node.deinit(alloc);
    }
    self.nodes.deinit(alloc);
}

pub const SaveData = []Node.SaveData;

pub fn save(self: Db, alloc: Allocator) !SaveData {
    const ret = try alloc.alloc(Node.SaveData, self.nodes.items.len);
    errdefer alloc.free(ret);

    for (0..self.nodes.items.len) |i| {
        ret[i] = self.nodes.items[i].save();
    }

    return ret;
}

pub fn load(alloc: Allocator, savedata: SaveData) !Db {
    var nodes = std.ArrayListUnmanaged(Node){};
    errdefer {
        for (nodes.items) |*node| {
            node.deinit(alloc);
        }
        nodes.deinit(alloc);
    }

    for (savedata) |node| {
        var loaded = try Node.load(alloc, node);
        errdefer loaded.deinit(alloc);

        try nodes.append(alloc, loaded);
    }

    return .{
        .nodes = nodes,
    };
}

pub const NodeQuery = union(enum) {
    none,
    name: []const u8,
    id: NodeId,
};

pub fn addNode(
    self: *Db,
    alloc: Allocator,
    path: []const u8,
    name: []const u8,
    parent: NodeQuery,
    ident_range: TextRange,
    range: TextRange,
) !NodeId {
    const ret = NodeId{ .value = self.nodes.items.len };
    const name_duped = try alloc.dupe(u8, name);
    errdefer alloc.free(name_duped);

    const path_duped = try alloc.dupe(u8, path);
    errdefer alloc.free(path_duped);

    try self.nodes.append(alloc, .{
        .name = name_duped,
        .data = .{ .within_file = .{
            .path = path_duped,
            .ident_range = ident_range,
            .range = range,
        } },
        .parent = self.findNodeId(parent),
    });
    return ret;
}

pub fn addFsNode(
    self: *Db,
    alloc: Allocator,
    path: []const u8,
    name: []const u8,
    parent: NodeQuery,
) !NodeId {
    const ret = NodeId{ .value = self.nodes.items.len };
    const name_duped = try alloc.dupe(u8, name);
    errdefer alloc.free(name_duped);

    const path_duped = try alloc.dupe(u8, path);
    errdefer alloc.free(path_duped);

    try self.nodes.append(alloc, .{
        .name = name_duped,
        .data = .{
            .filesystem = path_duped,
        },
        .parent = self.findNodeId(parent),
    });
    return ret;
}

pub fn findNodeId(self: Db, query: NodeQuery) ?NodeId {
    switch (query) {
        .name => |n| return self.nodeByName(n),
        .id => |id| return id,
        .none => return null,
    }
}

pub const NodeWithLocIt = struct {
    nodes: []Node,
    file: []const u8,
    loc: TextPosition,
    idx: usize = 0,

    pub fn next(self: *NodeWithLocIt) ?NodeId {
        while (true) {
            if (self.idx >= self.nodes.len) return null;
            defer self.idx += 1;

            const node = self.nodes[self.idx];
            if (node.data.containsLocation(self.file, self.loc)) {
                return .{ .value = self.idx };
            }
        }
    }
};

pub fn nodesContainingLoc(self: Db, file: []const u8, loc: TextPosition) NodeWithLocIt {
    return .{
        .file = file,
        .nodes = self.nodes.items,
        .loc = loc,
    };
}

pub fn getNode(self: Db, id: NodeId) Node {
    return self.nodes.items[id.value];
}

pub fn getNodePtr(self: *Db, id: NodeId) *Node {
    return &self.nodes.items[id.value];
}

pub const IdIter = struct {
    idx: usize = 0,
    max: usize,

    pub fn next(self: *IdIter) ?NodeId {
        if (self.idx >= self.max) return null;
        defer self.idx += 1;
        return .{ .value = self.idx };
    }
};

pub fn idIter(self: Db) IdIter {
    return .{
        .max = self.nodes.items.len,
    };
}

fn nodeByName(self: Db, name: []const u8) ?NodeId {
    for (self.nodes.items, 0..) |node, idx| {
        if (std.mem.eql(u8, node.name, name)) {
            return .{ .value = idx };
        }
    }

    return null;
}

pub const NodeId = packed struct(usize) {
    value: usize,
};

pub const Node = struct {
    name: []const u8,
    parent: ?NodeId,
    data: NodeData,
    referenced_by: std.ArrayListUnmanaged(NodeId) = .{},

    pub const SaveData = struct {
        name: []const u8,
        parent: ?usize,
        data: NodeData,
        referenced_by: []const usize,
    };

    pub fn deinit(self: *Node, alloc: Allocator) void {
        alloc.free(self.name);
        self.referenced_by.deinit(alloc);
        self.data.deinit(alloc);
    }

    pub fn load(alloc: Allocator, savedata: Node.SaveData) !Node {
        const name = try alloc.dupe(u8, savedata.name);
        errdefer alloc.free(name);

        var data = try savedata.data.clone(alloc);
        errdefer data.deinit(alloc);

        std.debug.assert(@alignOf(NodeId) == @alignOf(usize));
        std.debug.assert(@sizeOf(NodeId) == @sizeOf(usize));

        var referenced_by = std.ArrayListUnmanaged(NodeId){};
        errdefer referenced_by.deinit(alloc);

        try referenced_by.appendSlice(alloc, @ptrCast(savedata.referenced_by));

        return .{
            .name = name,
            .parent = if (savedata.parent) |v| .{ .value = v } else null,
            .data = data,
            .referenced_by = referenced_by,
        };
    }

    pub fn save(self: Node) Node.SaveData {
        std.debug.assert(@alignOf(NodeId) == @alignOf(usize));
        std.debug.assert(@sizeOf(NodeId) == @sizeOf(usize));

        return .{
            .name = self.name,
            .parent = if (self.parent) |v| v.value else null,
            .data = self.data,
            .referenced_by = @ptrCast(self.referenced_by.items),
        };
    }
};

const NodeData = union(enum) {
    within_file: struct {
        path: []const u8,
        ident_range: TextRange,
        range: TextRange,
    },
    filesystem: []const u8,

    pub fn deinit(self: *NodeData, alloc: Allocator) void {
        switch (self.*) {
            .within_file => |d| {
                alloc.free(d.path);
            },
            .filesystem => |p| {
                alloc.free(p);
            },
        }
    }

    pub fn clone(self: NodeData, alloc: Allocator) !NodeData {
        switch (self) {
            .within_file => |d| {
                const path = try alloc.dupe(u8, d.path);
                errdefer alloc.free(path);

                return .{
                    .within_file = .{
                        .path = path,
                        .ident_range = d.ident_range,
                        .range = d.range,
                    },
                };
            },
            .filesystem => |p| {
                return .{ .filesystem = try alloc.dupe(u8, p) };
            },
        }
    }

    pub fn containsNodeData(self: NodeData, other: NodeData) bool {
        if (self == .within_file and other == .filesystem) {
            return false;
        } else if (self == .filesystem and other == .filesystem) {
            return std.mem.startsWith(u8, self.filesystem, other.filesystem);
        } else if (self == .filesystem and other == .within_file) {
            return std.mem.startsWith(u8, other.within_file.path, self.filesystem);
        } else {
            if (!std.mem.eql(u8, self.within_file.path, other.within_file.path)) {
                return false;
            }

            return self.within_file.range.contains(other.within_file.range.start);
        }
    }

    pub fn containsLocation(self: NodeData, file: []const u8, loc: TextPosition) bool {
        switch (self) {
            .within_file => |d| {
                if (!std.mem.eql(u8, d.path, file)) {
                    return false;
                }

                return d.range.contains(loc);
            },
            .filesystem => |p| {
                return std.mem.startsWith(u8, file, p);
            },
        }
    }
};
