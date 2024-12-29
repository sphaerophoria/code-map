const std = @import("std");
const Allocator = std.mem.Allocator;
const glfwb = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const gl = @cImport({
    @cInclude("GL/gl.h");
});
const sphrender = @import("sphrender");
const sphmath = @import("sphmath");
const Db = @import("Db.zig");
const sphui = @import("sphui");
const Vec2 = sphmath.Vec2;

fn errorCallbackGlfw(_: c_int, description: [*c]const u8) callconv(.C) void {
    std.log.err("Error: {s}\n", .{std.mem.span(description)});
}

fn cursorPositionCallbackGlfw(window: ?*glfwb.GLFWwindow, xpos: f64, ypos: f64) callconv(.C) void {
    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    glfw.queue.writeItem(.{
        .mouse_move = .{
            .x = @floatCast(xpos),
            .y = @floatCast(ypos),
        },
    }) catch |e| {
        std.debug.print("Failed to write mouse movement: {s}", .{@errorName(e)});
    };
}

fn mouseButtonCallbackGlfw(window: ?*glfwb.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.C) void {
    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    const is_down = action == glfwb.GLFW_PRESS;
    var write_obj: ?sphui.WindowAction = null;

    if (button == glfwb.GLFW_MOUSE_BUTTON_LEFT and is_down) {
        write_obj = .mouse_down;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_LEFT and !is_down) {
        write_obj = .mouse_up;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_MIDDLE and is_down) {
        write_obj = .middle_down;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_MIDDLE and !is_down) {
        write_obj = .middle_up;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_RIGHT and is_down) {
        write_obj = .right_click;
    }

    if (write_obj) |w| {
        glfw.queue.writeItem(w) catch |e| {
            std.debug.print("Failed to write mouse press/release: {s}", .{@errorName(e)});
        };
    }
}

const Glfw = struct {
    window: *glfwb.GLFWwindow = undefined,
    queue: Fifo = undefined,

    const Fifo = std.fifo.LinearFifo(sphui.WindowAction, .{ .Static = 1024 });

    fn initPinned(self: *Glfw, window_width: comptime_int, window_height: comptime_int) !void {
        _ = glfwb.glfwSetErrorCallback(errorCallbackGlfw);

        if (glfwb.glfwInit() != glfwb.GLFW_TRUE) {
            return error.GLFWInit;
        }
        errdefer glfwb.glfwTerminate();

        glfwb.glfwWindowHint(glfwb.GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfwb.glfwWindowHint(glfwb.GLFW_CONTEXT_VERSION_MINOR, 3);
        glfwb.glfwWindowHint(glfwb.GLFW_OPENGL_PROFILE, glfwb.GLFW_OPENGL_CORE_PROFILE);
        glfwb.glfwWindowHint(glfwb.GLFW_OPENGL_DEBUG_CONTEXT, 1);
        glfwb.glfwWindowHint(glfwb.GLFW_SAMPLES, 4);

        const window = glfwb.glfwCreateWindow(window_width, window_height, "vis", null, null);
        if (window == null) {
            return error.CreateWindow;
        }
        errdefer glfwb.glfwDestroyWindow(window);

        _ = glfwb.glfwSetCursorPosCallback(window, cursorPositionCallbackGlfw);
        _ = glfwb.glfwSetMouseButtonCallback(window, mouseButtonCallbackGlfw);

        glfwb.glfwMakeContextCurrent(window);
        glfwb.glfwSwapInterval(1);

        glfwb.glfwSetWindowUserPointer(window, self);

        self.* = .{
            .window = window.?,
            .queue = Fifo.init(),
        };
    }

    fn deinit(self: *Glfw) void {
        glfwb.glfwDestroyWindow(self.window);
        glfwb.glfwTerminate();
    }

    fn closed(self: *Glfw) bool {
        return glfwb.glfwWindowShouldClose(self.window) == glfwb.GLFW_TRUE;
    }

    fn getWindowSize(self: *Glfw) struct { usize, usize } {
        var width: c_int = 0;
        var height: c_int = 0;
        glfwb.glfwGetFramebufferSize(self.window, &width, &height);
        return .{ @intCast(width), @intCast(height) };
    }

    fn swapBuffers(self: *Glfw) void {
        glfwb.glfwSwapBuffers(self.window);
        glfwb.glfwPollEvents();
    }
};

pub const constant_color_shader =
    \\#version 330
    \\out vec4 fragment;
    \\void main()
    \\{
    \\    fragment = vec4(1.0, 1.0, 1.0, 0.01);
    \\}
;

pub const circle_shader =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform vec3 color = vec3(1.0, 1.0, 1.0);
    \\void main()
    \\{
    \\    vec2 center = uv - 0.5;
    \\    float outer_r2 = 0.5 * 0.5;
    \\    float inner_r2 = 0.4 * 0.4;
    \\    float dist2 = center.x * center.x + center.y * center.y;
    \\    if (dist2 > outer_r2) {
    \\        discard;
    \\    } else if (dist2 > inner_r2) {
    \\        fragment = vec4(0.0, 0.0, 0.5, 1.0);
    \\    } else {
    \\        fragment = vec4(color.xyz, 1.0);
    \\    }
    \\}
;

fn appendLinePointsToBuf(buf: *std.ArrayList(sphrender.PlaneRenderProgram.Buffer.BufferPoint), a: Vec2, b: Vec2, line_width: f32) !void {
    const ab = b - a;
    const perp = sphmath.normalize(Vec2{ -ab[1], ab[0] });

    const half_line_width = line_width / 2;
    const a1 = a + perp * @as(Vec2, @splat(half_line_width));
    const a2 = a - perp * @as(Vec2, @splat(half_line_width));
    const b1 = b + perp * @as(Vec2, @splat(half_line_width));
    const b2 = b - perp * @as(Vec2, @splat(half_line_width));

    try buf.appendSlice(&.{
        .{ .clip_x = a1[0], .clip_y = a1[1], .uv_x = 0, .uv_y = 0 },
        .{ .clip_x = b1[0], .clip_y = b1[1], .uv_x = 0, .uv_y = 0 },
        .{ .clip_x = a2[0], .clip_y = a2[1], .uv_x = 0, .uv_y = 0 },

        .{ .clip_x = a2[0], .clip_y = a2[1], .uv_x = 0, .uv_y = 0 },
        .{ .clip_x = b1[0], .clip_y = b1[1], .uv_x = 0, .uv_y = 0 },
        .{ .clip_x = b2[0], .clip_y = b2[1], .uv_x = 0, .uv_y = 0 },
    });
}

fn updateLineBuffer(alloc: Allocator, buf: *sphrender.PlaneRenderProgram.Buffer, db: Db, positions: []const Vec2, line_width: f32) !void {
    var cpu_buf = std.ArrayList(sphrender.PlaneRenderProgram.Buffer.BufferPoint).init(alloc);
    defer cpu_buf.deinit();

    var node_it = db.idIter();
    while (node_it.next()) |node_id| {
        const node = db.getNode(node_id);
        const a = positions[node_id.value];
        for (node.referenced_by.items) |ref_id| {
            const b = positions[ref_id.value];
            try appendLinePointsToBuf(&cpu_buf, a, b, line_width);
        }
    }

    buf.updateBuffer(cpu_buf.items);
}

fn updateNodeBuffer(alloc: Allocator, buf: *sphrender.PlaneRenderProgram.Buffer, positions: []const sphmath.Vec2, circle_radius: f32) !void {
    const BufferPoint = sphrender.PlaneRenderProgram.Buffer.BufferPoint;
    var buf_points = std.ArrayList(BufferPoint).init(alloc);
    defer buf_points.deinit();

    for (positions) |pos| {
        const tl = BufferPoint{
            .clip_x = pos[0] - circle_radius,
            .clip_y = pos[1] + circle_radius,
            .uv_x = 0.0,
            .uv_y = 1.0,
        };

        const bl = BufferPoint{
            .clip_x = pos[0] - circle_radius,
            .clip_y = pos[1] - circle_radius,
            .uv_x = 0.0,
            .uv_y = 0.0,
        };

        const tr = BufferPoint{
            .clip_x = pos[0] + circle_radius,
            .clip_y = pos[1] + circle_radius,
            .uv_x = 1.0,
            .uv_y = 1.0,
        };

        const br = BufferPoint{
            .clip_x = pos[0] + circle_radius,
            .clip_y = pos[1] - circle_radius,
            .uv_x = 1.0,
            .uv_y = 0.0,
        };

        try buf_points.appendSlice(&.{
            bl, tl, tr,
            bl, tr, br,
        });
    }

    buf.updateBuffer(buf_points.items);
}

const Graph = struct {
    // FIXME: Use NodeDb and load from save correctly
    db: *const Db,

    protected: struct {
        mutex: std.Thread.Mutex = .{},
        positions: []sphmath.Vec2,
    },

    // FIXME: Migrate to DB
    num_children: []const u32,

    pull_multiplier: f32 = 0.200,
    parent_pull_multiplier: f32 = 1.220,
    push_multiplier: f32 = 22.300,
    center_pull_multiplier: f32 = 0.34,

    max_pull_movement: f32 = 0.020,
    max_parent_pull_movement: f32 = 0.209,
    max_push_movement: f32 = 0.117,
    max_center_movement: f32 = 0.012,

    fn init(alloc: Allocator, db: *const Db, num_children: []const u32) !Graph {
        const positions = try alloc.alloc(sphmath.Vec2, db.nodes.items.len);

        var rng = std.Random.DefaultPrng.init(@bitCast(std.time.timestamp()));
        var rand = rng.random();
        for (positions) |*pos| {
            const x = rand.float(f32) * 2 - 1;
            const y = rand.float(f32) * 2 - 1;
            pos.* = .{ x, y };
        }

        return .{
            .db = db,
            .protected = .{
                .positions = positions,
            },
            .num_children = num_children,
        };
    }

    fn deinit(self: *Graph, alloc: Allocator) void {
        alloc.free(self.protected.positions);
    }

    pub fn snapshotPositions(self: *Graph, alloc: Allocator) ![]Vec2 {
        self.protected.mutex.lock();
        defer self.protected.mutex.unlock();

        return alloc.dupe(Vec2, self.protected.positions);
    }

    fn maxReferences(alloc: Allocator, reference_list: []const Db.NodeId) !u32 {
        var reference_counts = std.AutoHashMap(Db.NodeId, u32).init(alloc);
        defer reference_counts.deinit();

        for (reference_list) |ref| {
            const gop = try reference_counts.getOrPut(ref);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
            }

            gop.value_ptr.* += 1;
        }

        var max: u32 = 0;
        var it = reference_counts.iterator();
        while (it.next()) |kv| {
            max = @max(kv.value_ptr.*, max);
        }

        return max;
    }

    pub fn run(self: *Graph, alloc: Allocator) !void {
        var step_speed: f32 = 5.0;
        while (true) {
            try self.step(alloc, step_speed);
            std.time.sleep(10);
            step_speed -= 0.01;
            step_speed = @max(1.00, step_speed);
        }
    }

    fn step(self: *Graph, alloc: Allocator, step_speed: f32) !void {
        self.protected.mutex.lock();
        defer self.protected.mutex.unlock();
        const positions = self.protected.positions;

        const movements = try alloc.alloc(sphmath.Vec2, positions.len);
        defer alloc.free(movements);
        @memset(movements, .{ 0, 0 });


        self.pullReferences(positions, movements);
        self.pullParents(positions, movements);
        self.pushNodes(positions, movements);
        // Because of how we push nodes away from eachother, there is a
        // tendency for items to end up outside the bounds of the window. Pull
        // them back
        self.pullCenter(positions, movements);
        applyMovements(positions, movements, step_speed);
    }

    // FIXME: Name params better
    fn calcPull(offs: sphmath.Vec2, multiplier: f32, max_dist: f32) sphmath.Vec2 {
        const dist = sphmath.length(offs);
        const dir = if (dist == 0) return .{ 0.0, 0.0 } else sphmath.normalize(offs);
        const pull_magnitude = max_dist * (dist * multiplier) / (1 + dist * multiplier);
        return dir * @as(sphmath.Vec2, @splat(pull_magnitude));
    }

    fn calcPush(offs: sphmath.Vec2, multiplier: f32, max_dist: f32) sphmath.Vec2 {
        var dist = sphmath.length(offs);
        const dir = if (dist == 0) sphmath.Vec2{ 1, 1 } else sphmath.normalize(offs);
        dist = @max(1e-6, dist);
        const push_mag = 1 / (multiplier * dist) * max_dist;
        return dir * @as(sphmath.Vec2, @splat(push_mag));
    }

    fn applyBidirectionalPull(a: Db.NodeId, b: Db.NodeId, pull: Vec2, movements: []Vec2) void {
        const half_pull: Vec2 = pull / sphmath.Vec2{ 2, 2 };
        movements[a.value] += half_pull;
        movements[b.value] -= half_pull;
    }

    fn pullReferences(self: Graph, positions: []Vec2, movements: []Vec2) void {
        var node_it = self.db.idIter();
        while (node_it.next()) |node_id| {
            const node = self.db.getNode(node_id);
            const pos = positions[node_id.value];
            const num_referecnes_f: f32 = @floatFromInt(node.referenced_by.items.len);

            // If each ref can pull us by max/num, then if every references
            // pulls as much as it can, we will move by max_pull
            const max_ref_pull = self.max_pull_movement / num_referecnes_f;

            for (node.referenced_by.items) |ref| {
                const other_pos = positions[ref.value];
                const pull = calcPull(
                    other_pos - pos,
                    self.pull_multiplier,
                    max_ref_pull,
                );

                applyBidirectionalPull(node_id, ref, pull, movements);
            }
        }
    }

    fn pullParents(self: Graph, positions: []Vec2, movements: []Vec2) void {
        var id_iter = self.db.idIter();
        while (id_iter.next()) |node_id| {
            const node = self.db.getNode(node_id);
            const pos = positions[node_id.value];

            const parent_id = node.parent orelse continue;

            const num_siblings: sphmath.Vec2 = .{
                @floatFromInt(self.num_children[parent_id.value]),
                @floatFromInt(self.num_children[parent_id.value]),
            };

            const parent_pos = positions[parent_id.value];
            // Keep us in range of parent
            // FIXME: tune parent pulling, needs same changes as other pull/push
            const parent_pull = calcPull(parent_pos - pos, self.parent_pull_multiplier, self.max_parent_pull_movement / num_siblings[0]);

            applyBidirectionalPull(node_id, parent_id, parent_pull, movements);
        }
    }

    fn pushNodes(self: Graph, positions: []Vec2, movements: []Vec2) void {
        const num_items_f: f32 = @floatFromInt(movements.len - 1);
        // If each elem can only push by max push / num items, if all items
        // push the max amount, we will move by max push
        const max_pair_push = self.max_push_movement / num_items_f;

        for (0..movements.len - 1) |i| {
            const a_pos = positions[i];

            for (i + 1..movements.len) |j| {

                const b_pos = positions[j];
                const push = calcPush(
                    b_pos - a_pos,
                    self.push_multiplier,
                    max_pair_push,
                );

                applyBidirectionalPull(.{ .value = j }, .{ .value = i }, push, movements);
            }
        }
    }

    fn pullCenter(self: Graph, positions: []Vec2, movements: []Vec2) void {
        for (positions, movements) |pos, *movement| {
            const pull = calcPull(-pos, self.center_pull_multiplier, self.max_center_movement);
            movement.* += pull;
        }
    }

    fn applyMovements(positions: []Vec2, movements: []const Vec2, movement_multiplier: f32) void {
        for (positions, movements) |*pos, movement| {
            pos.* += movement * @as(Vec2, @splat(movement_multiplier));
            pos.*[0] = std.math.clamp(pos.*[0], -1, 1);
            pos.*[1] = std.math.clamp(pos.*[1], -1, 1);
        }
    }

};

fn findItemUnderCursor(positions: []const Vec2, mouse_pos_px: sphui.MousePos, window_width: f32, window_height: f32) usize {
    const mouse_pos_clip = Vec2{
        mouse_pos_px.x / window_width * 2 - 1,
        1.0 - mouse_pos_px.y / window_height * 2,
    };

    var closest_dist = std.math.inf(f32);
    var closest_idx: usize = 0;

    for (0..positions.len) |i| {
        const mouse_item_dist = sphmath.length2(mouse_pos_clip - positions[i]);
        if (mouse_item_dist < closest_dist) {
            closest_dist = mouse_item_dist;
            closest_idx = i;
        }
    }

    return closest_idx;
}

pub const UiAction = union(enum) {
    change_pull_multiplier: f32,
    change_push_multiplier: f32,
    change_center_pull_multiplier: f32,
    change_parent_pull_multiplier: f32,
    change_max_pull_movement: f32,
    change_max_parent_pull_movement: f32,
    change_max_push_movement: f32,
    change_point_radius: f32,
    change_max_center_movement: f32,
    change_line_thickness: f32,

    fn makeDragGen(comptime tag: std.meta.Tag(UiAction)) fn (val: f32) UiAction {
        return struct {
            fn f(val: f32) UiAction {
                return @unionInit(UiAction, @tagName(tag), val);
            }
        }.f;
    }
};

fn appendFloatToPropertyList(
    property_list: *sphui.property_list.PropertyList(UiAction),
    widget_factory: *sphui.widget_factory.WidgetFactory(UiAction),
    name: []const u8,
    elem: *f32,
    action_gen: *const fn (f32) UiAction,
    speed: f32,
) !void {
    const key = try widget_factory.makeLabel(name);
    errdefer key.deinit(widget_factory.alloc);

    const value = try widget_factory.makeDragFloat(elem, action_gen, speed);
    errdefer value.deinit(widget_factory.alloc);

    try property_list.pushWidgets(widget_factory.alloc, key, value);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const db_parsed = blk: {
        const saved_db_f = try std.fs.cwd().openFile(args[1], .{});
        defer saved_db_f.close();

        var json_reader = std.json.reader(alloc, saved_db_f.reader());
        defer json_reader.deinit();

        break :blk try std.json.parseFromTokenSource([]Db.Node, alloc, &json_reader, .{});
    };
    defer db_parsed.deinit();

    const children_for_nodes = try alloc.alloc(u32, db_parsed.value.len);
    defer alloc.free(children_for_nodes);

    @memset(children_for_nodes, 0);

    for (db_parsed.value) |node| {
        if (node.parent) |id| {
            children_for_nodes[id.value] += 1;
        }
    }

    var db = try Db.load(alloc, db_parsed.value);
    defer db.deinit(alloc);

    var graph = try Graph.init(alloc, &db, children_for_nodes);
    defer graph.deinit(alloc);

    var glfw: Glfw = undefined;
    const window_width = 800;
    const window_height = 800;
    try glfw.initPinned(window_width, window_height);

    //sphrender.gl.glEnable(sphrender.gl.GL_MULTISAMPLE);
    //sphrender.gl.glEnable(sphrender.gl.GL_SCISSOR_TEST);
    sphrender.gl.glBlendFunc(sphrender.gl.GL_SRC_ALPHA, sphrender.gl.GL_ONE_MINUS_SRC_ALPHA);
    sphrender.gl.glEnable(sphrender.gl.GL_BLEND);
    sphrender.gl.glViewport(0, 0, window_width, window_height);

    var widget_factory = try sphui.widget_factory.widgetFactory(UiAction, alloc);
    defer widget_factory.deinit();

    var input_state = sphui.InputState{};

    const stack = try widget_factory.makeStack();
    const rect = try widget_factory.makeRect(.fill, .{
        .r = 0.1,
        .g = 0.1,
        .b = 0.1,
        .a = 1.0,
    });
    try stack.pushWidgetOrDeinit(widget_factory.alloc, rect, .fill);

    const stack_widget = stack.asWidget();
    defer stack.deinit(widget_factory.alloc);

    const property_list = try widget_factory.makePropertyList();
    const property_list_widget = property_list.asWidget();
    try stack.pushWidgetOrDeinit(widget_factory.alloc, property_list_widget, .centered);

    var point_radius: f32 = 0.014;
    var line_thickness: f32 = 0.005;

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Max pull movement",
        &graph.max_pull_movement,
        &UiAction.makeDragGen(.change_max_pull_movement),
        0.001,
    );

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Max parent pull movement",
        &graph.max_parent_pull_movement,
        &UiAction.makeDragGen(.change_max_parent_pull_movement),
        0.001,
    );

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Max push movement",
        &graph.max_push_movement,
        &UiAction.makeDragGen(.change_max_push_movement),
        0.001,
    );

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Pull multiplier",
        &graph.pull_multiplier,
        &UiAction.makeDragGen(.change_pull_multiplier),
        0.001,
    );

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Parent pull multiplier",
        &graph.parent_pull_multiplier,
        &UiAction.makeDragGen(.change_parent_pull_multiplier),
        0.01,
    );

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Center pull multiplier",
        &graph.center_pull_multiplier,
        &UiAction.makeDragGen(.change_center_pull_multiplier),
        0.001,
    );

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Max center pull",
        &graph.max_center_movement,
        &UiAction.makeDragGen(.change_max_center_movement),
        0.001,
    );

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Push multiplier",
        &graph.push_multiplier,
        &UiAction.makeDragGen(.change_push_multiplier),
        0.1,
    );

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Point radius",
        &point_radius,
        &UiAction.makeDragGen(.change_point_radius),
        0.001,
    );

    try appendFloatToPropertyList(
        property_list,
        widget_factory,
        "Line thickness",
        &line_thickness,
        &UiAction.makeDragGen(.change_line_thickness),
        0.001,
    );

    var selected_node = Db.NodeId{ .value = 0 };
    {
        const key = try widget_factory.makeLabel("Name");
        errdefer key.deinit(widget_factory.alloc);

        const SelectedNameTextRetriever = struct {
            db: *const Db,
            selected_node: *const Db.NodeId,

            pub fn getText(self: @This()) []const u8 {
                return self.db.getNode(self.selected_node.*).name;
            }
        };

        const value = try widget_factory.makeLabel(SelectedNameTextRetriever{
            .db = &db,
            .selected_node = &selected_node,
        });
        errdefer value.deinit(widget_factory.alloc);

        try property_list.pushWidgets(widget_factory.alloc, key, value);
    }

    const line_prog = try sphrender.PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, constant_color_shader, null);
    defer line_prog.deinit(alloc);

    const circle_prog = try sphrender.PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, circle_shader, null);
    defer circle_prog.deinit(alloc);

    var point_buf = circle_prog.makeDefaultBuffer();
    defer point_buf.deinit();

    var line_buf = line_prog.makeDefaultBuffer();
    defer line_buf.deinit();

    const t = try std.Thread.spawn(.{}, Graph.run, .{&graph, alloc});
    _ = t;

    while (!glfw.closed()) {

        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const positions = try graph.snapshotPositions(alloc);
        defer alloc.free(positions);

        try updateLineBuffer(alloc, &line_buf, db, positions, line_thickness);
        line_prog.render(line_buf, &.{}, &.{}, sphmath.Transform.identity);

        try updateNodeBuffer(alloc, &point_buf, positions, point_radius);
        circle_prog.render(point_buf, &.{.{ .float3 = .{ 1.0, 1.0, 1.0 } }}, &.{}, sphmath.Transform.identity);

        input_state.startFrame();
        while (glfw.queue.readItem()) |action| {
            try input_state.pushInput(alloc, action);
        }

        try stack_widget.update(.{ .width = 300, .height = 800 });
        const stack_widget_size = stack_widget.getSize();

        const property_widget_bounds = sphui.PixelBBox{
            .top = 0,
            .left = 0,
            .right = stack_widget_size.width,
            .bottom = stack_widget_size.height,
        };

        const action = stack_widget.setInputState(property_widget_bounds, property_widget_bounds, input_state);
        stack_widget.render(.{ .top = 0, .left = 0, .right = stack_widget_size.width, .bottom = stack_widget_size.height }, .{
            .top = 0,
            .left = 0,
            .right = 800,
            .bottom = 800,
        });

        if (action.action) |a| {
            switch (a) {
                .change_max_pull_movement => |f| {
                    graph.max_pull_movement = f;
                },
                .change_max_parent_pull_movement => |f| {
                    graph.max_parent_pull_movement = f;
                },
                .change_max_push_movement => |f| {
                    graph.max_push_movement = f;
                },
                .change_pull_multiplier => |f| {
                    graph.pull_multiplier = f;
                },
                .change_push_multiplier => |f| {
                    graph.push_multiplier = @max(0.01, f);
                },
                .change_parent_pull_multiplier => |f| {
                    graph.parent_pull_multiplier = f;
                },
                .change_point_radius => |f| {
                    point_radius = @max(0.00001, f);
                },
                .change_max_center_movement => |f| {
                    graph.max_center_movement = @max(0.0, f);
                },
                .change_center_pull_multiplier => |f| {
                    graph.center_pull_multiplier = @max(0.0, f);
                },
                .change_line_thickness => |f| {
                    line_thickness = @max(0.0, f);
                },
            }
        }

        const item_under_cursor = findItemUnderCursor(positions, input_state.mouse_pos, window_width, window_height);
        selected_node = Db.NodeId{ .value = item_under_cursor };

        try updateNodeBuffer(alloc, &point_buf, &.{positions[item_under_cursor]}, point_radius);
        circle_prog.render(point_buf, &.{.{ .float3 = .{ 0.0, 1.0, 1.0 } }}, &.{}, sphmath.Transform.identity);

        glfw.swapBuffers();
    }
}
