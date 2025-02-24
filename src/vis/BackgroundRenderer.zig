const std = @import("std");
const Allocator = std.mem.Allocator;
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const Db = @import("../Db.zig");
const sphmath = @import("sphmath");
const sphrender = @import("sphrender");
const RenderAlloc = sphrender.RenderAlloc;
const Vec2 = sphmath.Vec2;
const Vec3 = sphmath.Vec3;
const NodeVoronoi = @import("NodeVoronoi.zig");
const NodeTree = @import("../NodeTree.zig");

const BackgroundRenderer = @This();

background_colors: Db.ExtraData(Vec3),

voronoi_buf: NodeVoronoi.InstancedRenderBuffer,
voronoi: NodeVoronoi,

pub fn init(alloc: RenderAlloc, scratch: *ScratchAlloc, db: *const Db, node_tree: *const NodeTree) !BackgroundRenderer {
    const voronoi = try NodeVoronoi.init(alloc.gl);
    const voronoi_buf = try voronoi.makeConeBuf();
    const background_colors = try makeBackgroundColors(alloc.heap.general(), scratch, db, node_tree);

    return .{
        .background_colors = background_colors,
        .voronoi = voronoi,
        .voronoi_buf = voronoi_buf,
    };
}

pub fn render(
    self: *BackgroundRenderer, scratch: *ScratchAlloc, positions: Db.ExtraData(Vec2), db: *const Db, node_tree: *const NodeTree, transform: sphmath.Transform3D, dist_thresh_multiplier: f32,) !void {

    const checkpoint = scratch.checkpoint();
    defer scratch.restore(checkpoint);

    var voronoi_data = std.ArrayList(NodeVoronoi.InstancedRenderBuffer.InstanceData).init(scratch.allocator());

    const dist_thresholds = try calculateDistanceThresholds(scratch.allocator(), positions, db, node_tree, dist_thresh_multiplier,);

    var node_it = db.idIter();
    while (node_it.next()) |node_id| {
        var gen = ConeSegmentGenerator{
            .db = db,
            .center = positions.get(node_id),
            .dist_thresholds = dist_thresholds,
            .node_tree = node_tree,
            .node_id = node_id,
            .dist_thresh_multiplier = dist_thresh_multiplier,
            .background_colors = self.background_colors,
        };

        while (try gen.next()) |segment| {
            try voronoi_data.append(segment);
        }
    }

    self.voronoi_buf.setOffsetData(voronoi_data.items);
    try self.voronoi.render(self.voronoi_buf, transform);
}

fn calculateDistanceThresholds(alloc: Allocator, positions: Db.ExtraData(Vec2), db: *const Db, node_tree: *const NodeTree, dist_thresh_multiplier: f32,) !Db.ExtraData(f32) {
    var calc = try DistThreshCalculator.init(
        alloc,
        positions,
        db,
        node_tree,
        dist_thresh_multiplier,
    );

    var walker = try node_tree.walker(alloc);

    while (try walker.next()) |tree_node| {
        try calc.push(tree_node.node, tree_node.level);
    }
    calc.finish();
    return calc.dist_thresholds;
}

fn calculateDistThresh(min_x: f32, max_x: f32, min_y: f32, max_y: f32, num_descendents: usize, dist_thresh_multiplier: f32) f32 {
    // As the density of a cluster shrinks, the maximum distance we are willing
    // to draw background for should probably grow
    //
    // Imagine that items are spread in a circle evenly spaced. This is not
    // true, but a good enough approximation for us. If you were to imagine
    // each point as a forcefield that pushes away any element closer than some
    // radius, you would get a circle full of circles. The radius of these
    // inner circles is the distance between a node and its closest neighbor
    //
    // This distance seems like it should be proportional to how far away we
    // are willing to draw background for. The reasoning here is that we only
    // have to draw background for one point until we get in range of another
    // point
    //
    // Some calculations...
    //
    // With ratio of filled/unfilled space == R
    // With outer container radius == CR
    // With ball radius == IR
    // Inputs == CR, num_points
    //
    // CR * CR * PI = num_points * IR * IR * PI * R
    // CR * CR = num_points * IR * IR * R
    // IR * IR = CR * CR / num_points / R
    // IR = sqrt(CR * CR / num_points / R)

    // Approximate outer diameter as min(x)->max(x) or min(y)->max(y)
    const diameter = @max(max_x - min_x, max_y - min_y);
    const num_points_f: f32 = @floatFromInt(num_descendents);
    return std.math.sqrt(diameter * diameter / num_points_f * dist_thresh_multiplier);
}

const DistThreshCalculator = struct {
    stack: std.ArrayList(DescendentBounds),
    node_tree: *const NodeTree,
    dist_thresholds: Db.ExtraData(f32),
    positions: Db.ExtraData(Vec2),
    dist_threshold_multiplier: f32,

    fn init(alloc: Allocator, positions: Db.ExtraData(Vec2), db: *const Db, node_tree: *const NodeTree, dist_threshold_mutliplier: f32) !DistThreshCalculator {
        const dist_thresholds = try db.makeExtraData(f32, alloc, 0);
        // FIXME: Unfriendly to arena allcoators, which we are using from above
        const stack = std.ArrayList(DescendentBounds).init(alloc);

        return .{
            .stack = stack,
            .node_tree = node_tree,
            .dist_thresholds = dist_thresholds,
            .positions = positions,
            .dist_threshold_multiplier = dist_threshold_mutliplier,
        };
    }

    fn push(self: *DistThreshCalculator, node_id: Db.NodeId, level: usize) !void {
        // There are three options here
        // 1. We have moved to a parent
        // 2. We have moved to a sibling
        // 3. We have moved to a child
        //
        // In both cases 1 and 2, we have some bounds on our stack that have to
        // be applied/finalized
        while (level < self.stack.items.len) {
            self.applyLast();
        }

        // Since cases 1 and 2 were handled the same, it means we have to be in
        // case 3 now. We've popped our stack to the point where we have to be
        // adding a child
        try self.stack.append(.{ .id = node_id });

        const position = self.positions.get(node_id);
        self.applyPosition(position);
    }

    fn finish(self: *DistThreshCalculator) void {
        while (self.stack.items.len > 0) {
            self.applyLast();
        }
    }

    fn applyPosition(self: *DistThreshCalculator, position: Vec2) void {
        // Merge position into the PARENTs tracking box, not ours. This is a
        // little odd. If we consider leaf nodes, the distance threshold is
        // essentially 0. We don't care about those, we want to collect how an
        // items descendants are laid out, not our own point.
        //
        // This raises the question, why only our first parent, well in
        // applyLast we merge bboxes on the way up so this will propagate up
        // automatically
        if (self.stack.items.len > 1) {
            self.stack.items[self.stack.items.len - 2].mergePos(position);
        }
    }

    fn applyLast(self: *DistThreshCalculator) void {
        const last = self.stack.pop();
        if (self.stack.items.len > 0) {
            self.stack.items[self.stack.items.len - 1].mergeBounds(last);
        }

        if (!std.math.isInf(last.min_x)) {
            const num_descendents = self.node_tree.items.get(last.id).num_descendents;
            self.dist_thresholds.getPtr(last.id).* = calculateDistThresh(
                last.min_x,
                last.max_x,
                last.min_y,
                last.max_y,
                num_descendents,
                self.dist_threshold_multiplier,
            );
        }
    }

    const DescendentBounds = struct {
        id: Db.NodeId,
        min_x: f32 = std.math.inf(f32),
        max_x: f32 = -std.math.inf(f32),
        min_y: f32 = std.math.inf(f32),
        max_y: f32 = -std.math.inf(f32),

        fn mergePos(self: *DescendentBounds, position: Vec2) void {
            self.min_x = @min(position[0], self.min_x);
            self.max_x = @max(position[0], self.max_x);
            self.min_y = @min(position[1], self.min_y);
            self.max_y = @max(position[1], self.max_y);
        }

        fn mergeBounds(self: *DescendentBounds, other: DescendentBounds) void {
            self.min_x = @min(self.min_x, other.min_x);
            self.max_x = @max(self.max_x, other.max_x);
            self.min_y = @min(self.min_y, other.min_y);
            self.max_y = @max(self.max_y, other.max_y);
        }
    };
};

const ConeSegmentGenerator = struct {
    db: *const Db,
    last_radius: f32 = 0.0,
    last_depth: f32 = 0.0,
    center: Vec2,
    node_tree: *const NodeTree,
    dist_thresholds: Db.ExtraData(f32),
    node_id: ?Db.NodeId,
    dist_thresh_multiplier: f32,
    background_colors: Db.ExtraData(sphmath.Vec3),

    const Segment = NodeVoronoi.InstancedRenderBuffer.InstanceData;

    pub fn next(self: *ConeSegmentGenerator) !?Segment {
        while (true) {
            const node_id = self.node_id orelse return null;
            const node = self.db.getNode(node_id);
            defer self.node_id = node.parent;
            const num_descendants = self.node_tree.items.get(node_id).num_descendents;
            if (num_descendants == 0) continue;

            const dist_thresh = self.dist_thresholds.get(node_id);

            if (dist_thresh < self.last_radius) continue;
            defer self.last_radius = dist_thresh;

            const color = self.background_colors.get(node_id);

            const slope = 0.5;

            const outer_depth = self.last_depth + slope * (dist_thresh - self.last_radius);
            defer self.last_depth = outer_depth;

            const ret = Segment{
                .offset = self.center,
                .color = color,
                .inner_radius = self.last_radius,
                .outer_radius = dist_thresh,
                .inner_depth = self.last_depth,
                .outer_depth = outer_depth,
            };
            return ret;
        }
    }
};

fn hsvNormToRgb(h: f32, s: f32, v: f32) sphmath.Vec3 {
    const hp = h * 6.0;
    const c = v * s;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1));
    const m = v - c;

    if (hp < 1.0) {
        return .{ c + m, x + m, m };
    } else if (hp < 2.0) {
        return .{ x + m, c + m, m };
    } else if (hp < 3.0) {
        return .{ m, c + m, x + m };
    } else if (hp < 4.0) {
        return .{ m, x + m, c + m };
    } else if (hp < 5.0) {
        return .{ x + m, m, c + m };
    } else {
        return .{ c + m, m, x + m };
    }
}

fn makeBackgroundColors(gpa: Allocator, scratch: *ScratchAlloc, db: *const Db, node_tree: *const NodeTree) !Db.ExtraData(sphmath.Vec3) {
    var background_colors = try db.makeExtraData(sphmath.Vec3, gpa, sphmath.Vec3{ 1.0, 1.0, 1.0 });

    const checkpoint = scratch.checkpoint();
    defer scratch.restore(checkpoint);

    var node_walker = try node_tree.walker(scratch.allocator());

    const ColorAllocation = struct {
        initial_min: f32,
        min: f32,
        max: f32,
        allocated: usize,
        total: usize,

        fn allocate(self: *@This(), amount: usize) @This() {
            var allocation_ratio: f32 = @floatFromInt(amount);
            allocation_ratio /= @floatFromInt(self.total);

            const new_amount = allocation_ratio * (self.max - self.initial_min);
            const ret = .{
                .min = self.min,
                .initial_min = self.min,
                .max = self.min + new_amount,
                .allocated = 0,
                .total = amount,
            };

            self.min = ret.max;
            self.allocated += amount;
            return ret;
        }

        fn center(self: *const @This()) f32 {
            return (self.max + self.min) / 2.0;
        }
    };

    // FIXME: Arena friendly type
    var color_allocations = std.ArrayList(ColorAllocation).init(scratch.allocator());

    try color_allocations.append(.{
        .initial_min = 0.0,
        .min = 0.0,
        .max = 1.0,
        .allocated = 0,
        .total = db.nodes.items.len,
    });

    while (try node_walker.next()) |item| {
        const expected_num_allocations = item.level + 1;
        std.debug.assert(expected_num_allocations <= color_allocations.items.len);
        try color_allocations.resize(expected_num_allocations);

        const remaining_allocation = &color_allocations.items[item.level];

        const new_allocation = remaining_allocation.allocate(node_tree.items.get(item.node).num_descendents);
        try color_allocations.append(new_allocation);

        // FIXME: Probably should track max generation here instead of hardcoding 0.1
        const hue = new_allocation.center();
        const lightness = 0.05 * @as(f32, @floatFromInt(node_tree.items.get(item.node).generation + 1));

        // FIXME: Allocation is missing a bunch of colors
        background_colors.getPtr(item.node).* = hsvNormToRgb(hue, 0.8, lightness);
    }

    return background_colors;
}
