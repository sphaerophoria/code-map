const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const Db = @import("../Db.zig");
const Vec2 = sphmath.Vec2;

db: *const Db,

protected: struct {
    mutex: std.Thread.Mutex = .{},
    positions: Db.ExtraData(Vec2),
    shutdown: bool = false,
},

num_children: Db.ExtraData(u32),

// Technically these parameters are not thread safe, but what does it matter :)
pull_multiplier: f32 = 0.200,
parent_pull_multiplier: f32 = 1.220,
push_multiplier: f32 = 22.300,
center_pull_multiplier: f32 = 0.34,
max_pull_movement: f32 = 0.020,
max_parent_pull_movement: f32 = 0.209,
max_push_movement: f32 = 0.117,
max_center_movement: f32 = 0.012,

layout_thread: std.Thread,

const NodeLayout = @This();

pub fn init(alloc: Allocator, db: *const Db) !*NodeLayout {
    var positions = try db.makeExtraData(Vec2, alloc, undefined);
    errdefer positions.deinit(alloc);

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.timestamp()));
    var rand = rng.random();
    var node_it = db.idIter();
    while (node_it.next()) |id| {
        const pos = positions.getPtr(id);
        const x = rand.float(f32) * 2 - 1;
        const y = rand.float(f32) * 2 - 1;
        pos.* = .{ x, y };
    }

    const num_children = try calcChildrenForNodes(alloc, db.*);

    const ret = try alloc.create(NodeLayout);
    errdefer alloc.destroy(ret);

    ret.* = .{
        .db = db,
        .protected = .{
            .positions = positions,
        },
        .num_children = num_children,
        .layout_thread = undefined,
    };

    ret.layout_thread = try std.Thread.spawn(.{}, NodeLayout.run, .{ ret, alloc });

    return ret;
}

pub fn deinit(self: *NodeLayout, alloc: Allocator) void {
    self.protected.mutex.lock();
    self.protected.shutdown = true;
    self.protected.mutex.unlock();
    self.layout_thread.join();

    self.protected.positions.deinit(alloc);
    self.num_children.deinit(alloc);
    alloc.destroy(self);
}

pub fn snapshotPositions(self: *NodeLayout, alloc: Allocator) !Db.ExtraData(Vec2) {
    self.protected.mutex.lock();
    defer self.protected.mutex.unlock();

    return self.protected.positions.clone(alloc);
}

pub fn run(self: *NodeLayout, alloc: Allocator) !void {
    // Run with high step size, then lower it to improve stability
    var step_speed: f32 = 7.0;
    while (try self.step(alloc, step_speed)) {
        const sleep_time: u64 = 1 * std.time.ns_per_ms;

        step_speed -= 0.01;
        step_speed = @max(3.00, step_speed);

        std.time.sleep(sleep_time);
    }
}

fn step(self: *NodeLayout, alloc: Allocator, step_speed: f32) !bool {
    self.protected.mutex.lock();
    defer self.protected.mutex.unlock();
    const positions = &self.protected.positions;

    var movements = try self.db.makeExtraData(Vec2, alloc, .{ 0, 0 });
    defer movements.deinit(alloc);

    self.pullReferences(positions.*, &movements);
    self.pullParents(positions.*, &movements);
    self.pushNodes(positions.*, &movements);
    // Because of how we push nodes away from eachother, there is a
    // tendency for items to end up outside the bounds of the window. Pull
    // them back
    self.pullCenter(positions.*, &movements);
    applyMovements(positions, movements, step_speed);

    return !self.protected.shutdown;
}

fn calcPull(offs: Vec2, multiplier: f32, max_dist: f32) Vec2 {
    const dist = sphmath.length(offs);
    const dir = if (dist == 0) return .{ 0.0, 0.0 } else sphmath.normalize(offs);
    const pull_magnitude = max_dist * (dist * multiplier) / (1 + dist * multiplier);
    return dir * @as(Vec2, @splat(pull_magnitude));
}

fn calcPush(offs: Vec2, multiplier: f32, max_dist: f32) Vec2 {
    var dist = sphmath.length(offs);
    const dir = if (dist == 0) Vec2{ 1, 1 } else sphmath.normalize(offs);
    dist = @max(1e-6, dist);
    const push_mag = 1 / (multiplier * dist) * max_dist;
    return dir * @as(Vec2, @splat(push_mag));
}

fn applyBidirectionalPull(a: Db.NodeId, b: Db.NodeId, pull: Vec2, movements: *Db.ExtraData(Vec2)) void {
    const half_pull = pull / @as(Vec2, @splat(2.0));
    movements.getPtr(a).* += half_pull;
    movements.getPtr(b).* -= half_pull;
}

fn pullReferences(self: NodeLayout, positions: Db.ExtraData(Vec2), movements: *Db.ExtraData(Vec2)) void {
    var node_it = self.db.idIter();
    while (node_it.next()) |node_id| {
        const node = self.db.getNode(node_id);
        const pos = positions.get(node_id);
        const num_referecnes_f: f32 = @floatFromInt(node.referenced_by.items.len);

        // If each ref can pull us by max/num, then if every references
        // pulls as much as it can, we will move by max_pull
        const max_ref_pull = self.max_pull_movement / num_referecnes_f;

        for (node.referenced_by.items) |ref| {
            const other_pos = positions.get(ref);
            const pull = calcPull(
                other_pos - pos,
                self.pull_multiplier,
                max_ref_pull,
            );

            applyBidirectionalPull(node_id, ref, pull, movements);
        }
    }
}

fn pullParents(self: NodeLayout, positions: Db.ExtraData(Vec2), movements: *Db.ExtraData(Vec2)) void {
    var id_iter = self.db.idIter();
    while (id_iter.next()) |node_id| {
        const node = self.db.getNode(node_id);
        const pos = positions.get(node_id);

        const parent_id = node.parent orelse continue;

        const num_siblings_f: f32 = @floatFromInt(self.num_children.get(parent_id));

        const parent_pos = positions.get(parent_id);
        // Keep us in range of parent
        const parent_pull = calcPull(
            parent_pos - pos,
            self.parent_pull_multiplier,
            self.max_parent_pull_movement / num_siblings_f,
        );

        applyBidirectionalPull(node_id, parent_id, parent_pull, movements);
    }
}

fn pushNodes(self: NodeLayout, positions: Db.ExtraData(Vec2), movements: *Db.ExtraData(Vec2)) void {
    const num_items_f: f32 = @floatFromInt(movements.data.len - 1);
    // If each elem can only push by max push / num items, if all items
    // push the max amount, we will move by max push
    const max_pair_push = self.max_push_movement / num_items_f;

    var a_it = positions.idIter();
    while (a_it.next()) |a_id| {
        const a_pos = positions.get(a_id);

        var b_it = positions.idIterAfter(a_id);

        while (b_it.next()) |b_id| {
            const b_pos = positions.get(b_id);
            const push = calcPush(
                b_pos - a_pos,
                self.push_multiplier,
                max_pair_push,
            );

            // Backwards ids to turn the pull into a push
            applyBidirectionalPull(b_id, a_id, push, movements);
        }
    }
}

fn pullCenter(self: NodeLayout, positions: Db.ExtraData(Vec2), movements: *Db.ExtraData(Vec2)) void {
    var it = positions.idIter();
    while (it.next()) |id| {
        const pos = positions.get(id);
        const movement = movements.getPtr(id);
        const pull = calcPull(-pos, self.center_pull_multiplier, self.max_center_movement);
        movement.* += pull;
    }
}

fn applyMovements(positions: *Db.ExtraData(Vec2), movements: Db.ExtraData(Vec2), movement_multiplier: f32) void {
    var it = positions.idIter();
    while (it.next()) |id| {
        const pos = positions.getPtr(id);
        const movement = movements.get(id);
        pos.* += movement * @as(Vec2, @splat(movement_multiplier));
        pos.*[0] = std.math.clamp(pos.*[0], -1, 1);
        pos.*[1] = std.math.clamp(pos.*[1], -1, 1);
    }
}

fn calcChildrenForNodes(alloc: Allocator, db: Db) !Db.ExtraData(u32) {
    var ret = try db.makeExtraData(u32, alloc, 0);

    var it = db.idIter();
    while (it.next()) |id| {
        const node = db.getNode(id);
        if (node.parent) |v| {
            ret.getPtr(v).* += 1;
        }
    }
    return ret;
}
