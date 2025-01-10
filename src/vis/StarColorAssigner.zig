const std = @import("std");
const sphmath = @import("sphmath");
const StarColorAssigner = @This();
const Db = @import("../Db.zig");

const capacity = 3;
const color_palette = [capacity]sphmath.Vec3{
    .{ 1.0, 0.3, 0.3 },
    .{ 0.3, 1.0, 0.3 },
    .{ 0.3, 0.3, 1.0 },
};
items: [capacity]struct {
    weight: f32,
    id: Db.NodeId,
} = undefined,
min_idx: u8 = 0,
len: u8 = 0,

pub fn push(self: *StarColorAssigner, id: Db.NodeId, weight: f32) void {
    if (weight <= 1.0) {
        return;
    }

    if (self.len < capacity) {
        self.items[self.len] = .{
            .weight = weight,
            .id = id,
        };
        self.len += 1;
        if (self.len == capacity) {
            self.updateMin();
        }
        return;
    }

    if (weight < self.items[self.min_idx].weight) {
        return;
    }

    self.items[self.min_idx] = .{
        .weight = weight,
        .id = id,
    };

    self.updateMin();
}

pub const IdColorIt = struct {
    assigner: *const StarColorAssigner,
    idx: u8 = 0,

    pub const Output = struct {
        id: Db.NodeId,
        color: sphmath.Vec3,
    };

    pub fn next(self: *IdColorIt) ?Output {
        if (self.idx >= self.assigner.len) {
            return null;
        }

        defer self.idx += 1;

        return .{
            .id = self.assigner.items[self.idx].id,
            .color = color_palette[self.idx],
        };
    }
};

pub fn idColors(self: *const StarColorAssigner) IdColorIt {
    return .{
        .assigner = self,
    };
}

pub fn get(self: *const StarColorAssigner, id: Db.NodeId) sphmath.Vec3 {
    for (0..self.len) |idx| {
        const item = self.items[idx];
        if (item.id.value == id.value) {
            return color_palette[idx];
        }
    }

    return .{ 1.0, 1.0, 1.0 };
}

fn updateMin(self: *StarColorAssigner) void {
    var min = std.math.inf(f32);
    var min_idx: u8 = 0;

    for (self.items, 0..) |item, idx| {
        if (item.weight < min) {
            min = item.weight;
            min_idx = @intCast(idx);
        }
    }

    self.min_idx = min_idx;
}
