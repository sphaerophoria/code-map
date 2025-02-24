const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const gl = sphrender.gl;
const sphmath = @import("sphmath");
const Db = @import("../Db.zig");
const sphui = @import("sphui");
const Vec2 = sphmath.Vec2;
const Vec3 = sphmath.Vec3;
const vis_gui = @import("gui.zig");
const UiAction = vis_gui.UiAction;
const Vis = @import("Vis.zig");
const sphwindow = @import("sphwindow");
const Window = sphwindow.Window;

scratch: *ScratchAlloc,
vis: *Vis,
size: sphui.PixelSize = .{ .width = 0, .height = 0 },
positions: Db.ExtraData(Vec2),
last_time: std.time.Instant,
delta_s: f32 = 0,

// HACK: Gui framework does not notify on key release
window: *Window,

const VisWidget = @This();

const widget_vtable = sphui.Widget(UiAction).VTable{
    .render = VisWidget.render,
    .getSize = VisWidget.getSize,
    .update = VisWidget.update,
    .setInputState = VisWidget.setInputState,
    .setFocused = null,
    .reset = null,
};

pub fn create(arena: Allocator, scratch: *ScratchAlloc, vis: *Vis, window: *Window) !sphui.Widget(UiAction) {
    const ctx = try arena.create(VisWidget);
    errdefer arena.destroy(ctx);

    ctx.* = .{
        .scratch = scratch,
        .vis = vis,
        .positions = undefined,
        .last_time = try std.time.Instant.now(),
        .window = window,
    };

    return .{
        .ctx = ctx,
        .vtable = &widget_vtable,
    };
}

fn update(ctx: ?*anyopaque, available_size: sphui.PixelSize) anyerror!void {
    const self: *VisWidget = @ptrCast(@alignCast(ctx));
    self.size = available_size;
    // Use of scratch allocator looks bad here, but the widget is guaranteed to
    // call update every frame before the other functions, so we know that this
    // will always be valid
    self.positions = try self.vis.node_layout.snapshotPositions(self.scratch.allocator());

    const now = try std.time.Instant.now();
    self.delta_s = @floatFromInt(now.since(self.last_time));
    self.delta_s /= std.time.ns_per_s;
    self.last_time = now;
}

fn render(ctx: ?*anyopaque, widget_bounds: sphui.PixelBBox, window_bounds: sphui.PixelBBox) void {
    const self: *VisWidget = @ptrCast(@alignCast(ctx));

    const centered_bounds = centeredBounds(widget_bounds);

    var viewport = sphrender.TemporaryViewport.init();
    defer viewport.reset();

    viewport.setViewportOffset(centered_bounds.left, window_bounds.bottom - centered_bounds.bottom, centered_bounds.calcWidth(), centered_bounds.calcHeight());
    var scissor = sphrender.TemporaryScissor.init();
    defer scissor.reset();

    scissor.set(centered_bounds.left, window_bounds.bottom - centered_bounds.bottom, centered_bounds.calcWidth(), centered_bounds.calcHeight());

    self.vis.render(self.scratch, self.positions) catch return;
}

fn getSize(ctx: ?*anyopaque) sphui.PixelSize {
    const self: *VisWidget = @ptrCast(@alignCast(ctx));
    return self.size;
}

fn setInputState(ctx: ?*anyopaque, widget_bounds: sphui.PixelBBox, input_bounds: sphui.PixelBBox, input_state: sphui.InputState) sphui.InputResponse(UiAction) {
    const self: *VisWidget = @ptrCast(@alignCast(ctx));

    const no_action = sphui.InputResponse(UiAction){
        .wants_focus = false,
        .action = null,
    };

    if (!input_bounds.containsMousePos(input_state.mouse_pos) and !input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
        return no_action;
    }

    if (input_state.mouse_down_location) |pos| {
        if (!input_bounds.containsMousePos(pos)) {
            return no_action;
        }
    }

    if (self.vis.voronoi_debug.enabled) {
        self.vis.voronoi_debug.handleVoronoiDebugInput(
            &input_state.key_tracker,
            &input_state,
            self.delta_s,
        );
        // HACK: camera movements are not sent through action framework
        return no_action;
    }

    const centered_bounds = centeredBounds(widget_bounds);

    var graph_x = input_state.mouse_pos.x;
    graph_x -= @floatFromInt(centered_bounds.left);
    graph_x /= @floatFromInt(centered_bounds.calcWidth());
    graph_x = graph_x * 2.0 - 1.0;

    var graph_y: f32 = @floatFromInt(centered_bounds.bottom);
    graph_y -= input_state.mouse_pos.y;
    graph_y /= @floatFromInt(centered_bounds.calcHeight());
    graph_y = graph_y * 2.0 - 1.0;

    const graph_pos = sphmath.Vec2{ graph_x, graph_y };

    const closest_node = findClosestNode(graph_pos, self.positions);
    return .{
        .wants_focus = false,
        .action = .{
            .update_closest_node = closest_node,
        },
    };
}

fn centeredBounds(widget_bounds: sphui.PixelBBox) sphui.PixelBBox {
    const width = widget_bounds.calcWidth();
    const height = widget_bounds.calcHeight();
    const size = @min(width, height);

    return sphui.util.centerBoxInBounds(.{ .width = size, .height = size }, widget_bounds);
}

fn findClosestNode(graph_pos: Vec2, positions: Db.ExtraData(Vec2)) Db.NodeId {
    var it = positions.idIter();
    var closest_dist = std.math.inf(f32);
    var closest_node: Db.NodeId = .{ .value = 0 };
    while (it.next()) |id| {
        const position = positions.get(id);
        const dist = sphmath.length2(position - graph_pos);
        if (dist < closest_dist) {
            closest_dist = dist;
            closest_node = id;
        }
    }
    return closest_node;
}
