const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const sphmath = @import("sphmath");
const NodeLayout = @import("NodeLayout.zig");
const Db = @import("../Db.zig");
const sphui = @import("sphui");
const Vec2 = sphmath.Vec2;
const Vec3 = sphmath.Vec3;
const NodeVoronoi = @import("NodeVoronoi.zig");
const vis_gui = @import("gui.zig");
const UiAction = vis_gui.UiAction;
const NodeRenderer = @import("NodeRenderer.zig");
const StarColorAssigner = @import("StarColorAssigner.zig");
const NodeTree = @import("../NodeTree.zig");
const BackgroundRenderer = @import("BackgroundRenderer.zig");
const sphwindow = @import("sphwindow");
const Window = sphwindow.Window;

const Vis = @This();

db: *const Db,
node_tree: NodeTree,
interactions: Interactions,
render_params: RenderParams = .{},
star_colors: StarColorAssigner = .{},

weights: Db.ExtraData(f32),
user_weights: Db.ExtraData(f32),
max_weight: f32 = 0.0,

node_layout: *NodeLayout,

voronoi_debug: VoronoiDebug = .{},

line_prog: LineProgram,
line_buf: sphrender.shader_program.Buffer(LineElem),

node_renderer: NodeRenderer,
background_renderer: BackgroundRenderer,

pub fn init(alloc: Allocator, db: *const Db) !Vis {
    var node_tree = try NodeTree.init(alloc, db);
    errdefer node_tree.deinit(alloc);

    var interactions = try makeInteractions(alloc, db);
    errdefer freeInteractions(&interactions, alloc);

    var user_weights = try db.makeExtraData(f32, alloc, 1.0);
    errdefer user_weights.deinit(alloc);

    var weights = try user_weights.clone(alloc);
    errdefer weights.deinit(alloc);

    const line_prog = try LineProgram.init(line_vertex_shader, alpha_weighted_frag);
    errdefer line_prog.deinit();

    const line_buf = line_prog.makeBuffer(&.{});
    errdefer line_buf.deinit();

    const node_renderer = try NodeRenderer.init();
    errdefer node_renderer.deinit();

    var node_layout = try NodeLayout.init(alloc, db);
    errdefer node_layout.deinit(alloc);

    var background_renderer = try BackgroundRenderer.init(alloc, db, &node_tree);
    errdefer background_renderer.deinit();

    return .{
        .db = db,
        .interactions = interactions,
        .node_tree = node_tree,
        .user_weights = user_weights,
        .weights = weights,
        .line_prog = line_prog,
        .line_buf = line_buf,
        .node_renderer = node_renderer,
        .node_layout = node_layout,
        .background_renderer = background_renderer,
    };
}

pub fn deinit(self: *Vis, alloc: Allocator) void {
    freeInteractions(&self.interactions, alloc);
    self.node_tree.deinit(alloc);
    self.user_weights.deinit(alloc);
    self.weights.deinit(alloc);
    self.background_renderer.deinit(alloc);
    self.line_buf.deinit();
    self.line_prog.deinit();
    self.node_renderer.deinit();
    self.node_layout.deinit(alloc);
}

pub fn render(self: *Vis, tmp_alloc: Allocator, positions: Db.ExtraData(Vec2)) !void {
    try self.background_renderer.render(tmp_alloc, positions, self.db, &self.node_tree, self.voronoi_debug.getTransform(), self.render_params.dist_thresh_multiplier);

    if (!self.voronoi_debug.enabled) {
        try self.renderHighlightedConnections(tmp_alloc, positions);
        try self.node_renderer.render(tmp_alloc, &self.star_colors, positions, self.weights, self.render_params.point_radius);
    }
}

pub fn applyUserWeights(self: *Vis) void {
    self.max_weight = 0.0;

    self.star_colors = .{};

    var it = self.user_weights.idIter();
    while (it.next()) |id| {
        const weight = self.user_weights.get(id);
        self.weights.getPtr(id).* = weight;
        self.star_colors.push(id, weight);
        self.max_weight = @max(weight, self.max_weight);
    }

    it = self.user_weights.idIter();
    while (it.next()) |id| {
        // FIXME: Bidirectional
        //
        // weight propagation:
        //   * Each node references N things
        //   * Each node is referenced by M things
        //   * Total interactions is N + M
        //   * Weight propagation should be relative to interactions with thing / N + M
        //   * Between all references, we are only allowed to increase their size by 20% (or something)
        //   * Distribute that 20% based off interactions with thing / N + M
        //   * Weight increase weight *= 1 + (0.2 * num_interactions / total_interactions)
        const item_interactions = self.interactions.get(id);

        const log_interactions = self.user_weights.get(id) > 10.0;
        if (log_interactions) {
            std.debug.print("Total interactions: {d}\n", .{item_interactions.total});
        }

        // Weight of 1
        //
        // Weight of 100
        //  == some ratio

        var item_interactions_other = item_interactions.by_node.iterator();
        while (item_interactions_other.next()) |entry| {
            const count = entry.value_ptr.*;
            var interaction_ratio: f32 = @floatFromInt(count);
            interaction_ratio /= @floatFromInt(item_interactions.total);
            interaction_ratio = std.math.clamp(interaction_ratio, 0.0, 1.0);
            if (log_interactions) {
                std.debug.print("{d}: {s}\n", .{ count, self.db.getNode(entry.key_ptr.*).name });
                std.debug.print("interaction_ratio: {d}\n", .{interaction_ratio});
            }

            const other_weight = self.weights.getPtr(entry.key_ptr.*);
            // If weight == 1 -> no propogation
            // If weight is 100 -> total increase * ratio
            other_weight.* *= 1 + (self.render_params.weight_propagation_ratio * (self.user_weights.get(id) - 1.0) * interaction_ratio);
            self.max_weight = @max(self.max_weight, other_weight.*);
        }
    }
}

fn renderHighlightedConnections(self: *Vis, tmp_alloc: Allocator, positions: Db.ExtraData(Vec2)) !void {
    try updateLineBuffer(
        tmp_alloc,
        &self.line_buf,
        self.star_colors,
        self.interactions,
        positions,
        self.render_params.line_thickness,
        self.render_params.line_alpha_multiplier,
    );
    self.line_prog.render(self.line_buf, .{});
}

// FIXME: Completely unverified if any of this interactions code works
const NodeInteractions = struct {
    by_node: std.AutoHashMapUnmanaged(Db.NodeId, usize) = .{},
    total: usize = 0,

    pub fn deinit(self: *NodeInteractions, alloc: Allocator) void {
        self.by_node.deinit(alloc);
    }

    pub fn addInteraction(
        self: *NodeInteractions,
        alloc: Allocator,
        other: Db.NodeId,
    ) !void {
        const gop = try self.by_node.getOrPut(alloc, other);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
        }

        // FIXME: Unsure what we want to do here. Previously we only
        // incremented total if it was a top level reference. Why? I don't
        // remember.
        //
        // This becomes problematic in the following case
        //
        // A
        //   B
        //     c()
        //   D
        //     e()
        // F
        //   G
        //     h()
        //
        // Say we are finding interactions with item B
        //
        // c() calls e(), this is NOT counted as an interaction with A, as self
        // references are not counted. However, if e calls h, we get
        // interactions of e->h, e->G, e->F, D->h, D->G, D->F, A->e, A->G, A->F.
        // Is that reference inflation? Is that double counting? All references
        // are now guaranteed to be a low proportion of the total
        gop.value_ptr.* += 1;
        self.total += 1;
    }
};

const Interactions = Db.ExtraData(NodeInteractions);

fn makeInteractions(alloc: Allocator, db: *const Db) !Interactions {
    var interactions = try db.makeExtraData(NodeInteractions, alloc, .{});
    errdefer freeInteractions(&interactions, alloc);

    var it = db.idIter();
    while (it.next()) |id| {
        const node = db.getNode(id);
        for (node.referenced_by.items) |ref_by_id| {
            try interactions.getPtr(ref_by_id).addInteraction(alloc, id);
            try interactions.getPtr(id).addInteraction(alloc, ref_by_id);
        }
    }

    return interactions;
}

fn freeInteractions(interactions: *Interactions, alloc: Allocator) void {
    var it = interactions.idIter();
    while (it.next()) |id| {
        const item_interactions = interactions.getPtr(id);
        item_interactions.deinit(alloc);
    }
    interactions.deinit(alloc);
}

const RenderParams = struct {
    point_radius: f32 = 0.005,
    line_thickness: f32 = 0.003,
    line_alpha_multiplier: f32 = 5.0,
    dist_thresh_multiplier: f32 = 0.6,
    weight_propagation_ratio: f32 = 0.3,
};

const VoronoiDebug = struct {
    enabled: bool = false,
    last_mouse_pos: ?sphui.MousePos = null,
    camera: sphmath.Transform3D = .{},

    fn getTransform(self: VoronoiDebug) sphmath.Transform3D {
        if (self.enabled) {
            const perspective = sphmath.Transform3D.perspective(10.0, 0.01);
            return self.camera.then(perspective);
        } else {
            return sphmath.Transform3D{};
        }
    }

    pub fn handleVoronoiDebugInput(
        self: *VoronoiDebug,
        key_state: *const sphui.KeyTracker,
        input_state: *const sphui.InputState,
        delta_s: f32,
    ) void {
        const move_speed = 1.0;
        const rot_speed = 1.0;
        var x_movement: f32 = 0.0;
        var y_movement: f32 = 0.0;
        var z_movement: f32 = 0.0;

        if (input_state.mouse_down_location) |dloc| blk: {
            if (self.last_mouse_pos == null) {
                self.last_mouse_pos = dloc;
                break :blk;
            }
            const pos = input_state.mouse_pos;

            const y_rot = (pos.x - self.last_mouse_pos.?.x) * rot_speed * delta_s;
            self.camera = self.camera.then(sphmath.Transform3D.rotateY(y_rot));

            const x_rot = -(pos.y - self.last_mouse_pos.?.y) * rot_speed * delta_s;
            self.camera = self.camera.then(sphmath.Transform3D.rotateX(x_rot));

            self.last_mouse_pos = pos;
        } else {
            self.last_mouse_pos = null;
        }

        if (key_state.isKeyDown(.{ .ascii = 'a' })) {
            x_movement += move_speed * delta_s;
        }

        if (key_state.isKeyDown(.{ .ascii = 'd' })) {
            x_movement -= move_speed * delta_s;
        }

        if (key_state.isKeyDown(.{ .ascii = 'w' })) {
            z_movement -= move_speed * delta_s;
        }

        if (key_state.isKeyDown(.{ .ascii = 's' })) {
            z_movement += move_speed * delta_s;
        }

        if (key_state.isKeyDown(.{ .ascii = 'q' })) {
            y_movement -= move_speed * delta_s * 0.3;
        }

        if (key_state.isKeyDown(.{ .ascii = 'e' })) {
            y_movement += move_speed * delta_s * 0.3;
        }

        self.camera = self.camera.then(sphmath.Transform3D.translate(
            x_movement,
            y_movement,
            z_movement,
        ));
    }
};

const LineElem = struct {
    pos: sphmath.Vec2,
    color: sphmath.Vec3,
    alpha: f32,
};

const EmptyUniform = struct {};
const LineProgram = sphrender.shader_program.Program(LineElem, EmptyUniform);
pub const line_vertex_shader =
    \\#version 330
    \\in vec2 pos;
    \\in vec3 color;
    \\in float alpha;
    \\out vec3 fcolor;
    \\out float falpha;
    \\void main()
    \\{
    \\    gl_Position = vec4(pos, 0.0, 1.0);
    \\    fcolor = color;
    \\    falpha = alpha;
    \\}
;

pub const alpha_weighted_frag =
    \\#version 330
    \\in vec3 fcolor;
    \\in float falpha;
    \\out vec4 fragment;
    \\void main()
    \\{
    \\    fragment = vec4(fcolor, falpha);
    \\}
;

fn appendLinePointsToBuf(buf: *std.ArrayList(LineElem), a: Vec2, b: Vec2, line_width: f32, color: sphmath.Vec3, alpha: f32) !void {
    const ab = b - a;
    const perp = sphmath.normalize(Vec2{ -ab[1], ab[0] });

    const half_line_width = line_width / 2;
    const a1 = a + perp * @as(Vec2, @splat(half_line_width));
    const a2 = a - perp * @as(Vec2, @splat(half_line_width));
    const b1 = b + perp * @as(Vec2, @splat(half_line_width));
    const b2 = b - perp * @as(Vec2, @splat(half_line_width));

    try buf.appendSlice(&.{
        .{ .pos = .{ a1[0], a1[1] }, .color = color, .alpha = alpha },
        .{ .pos = .{ b1[0], b1[1] }, .color = color, .alpha = alpha },
        .{ .pos = .{ a2[0], a2[1] }, .color = color, .alpha = alpha },

        .{ .pos = .{ a2[0], a2[1] }, .color = color, .alpha = alpha },
        .{ .pos = .{ b1[0], b1[1] }, .color = color, .alpha = alpha },
        .{ .pos = .{ b2[0], b2[1] }, .color = color, .alpha = alpha },
    });
}
fn updateLineBuffer(tmp_alloc: Allocator, buf: *sphrender.shader_program.Buffer(LineElem), star_colors: StarColorAssigner, interactions: Interactions, positions: Db.ExtraData(Vec2), line_width: f32, interaction_ratio_multiplier: f32) !void {
    var cpu_buf = std.ArrayList(LineElem).init(tmp_alloc);
    defer cpu_buf.deinit();

    var node_it = star_colors.idColors();
    while (node_it.next()) |item| {
        const a = positions.get(item.id);
        const node_interactions = interactions.get(item.id);
        var interaction_it = node_interactions.by_node.iterator();
        while (interaction_it.next()) |interaction_item| {
            const b = positions.get(interaction_item.key_ptr.*);
            const this_node_interactions = interaction_item.value_ptr.*;
            var interaction_ratio: f32 = @floatFromInt(this_node_interactions);
            interaction_ratio /= @floatFromInt(node_interactions.total);

            interaction_ratio *= interaction_ratio_multiplier;

            try appendLinePointsToBuf(&cpu_buf, a, b, line_width, item.color, @min(interaction_ratio, 1.0));
        }
    }

    buf.updateBuffer(cpu_buf.items);
}
