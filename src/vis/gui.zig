const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const sphmath = @import("sphmath");
const Db = @import("../Db.zig");
const sphui = @import("sphui");
const Vec2 = sphmath.Vec2;
const Vec3 = sphmath.Vec3;
const vis_gui = @import("gui.zig");
const Vis = @import("Vis.zig");
const VisWidget = @import("VisWidget.zig");
const sphwindow = @import("sphwindow");
const Window = sphwindow.Window;

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
    change_line_alpha_multiplier: f32,
    change_dist_thresh_multiplier: f32,
    change_weight_propagation_ratio: f32,
    toggle_voronoi_debug,
    update_closest_node: Db.NodeId,
    edit_search: struct {
        notifier: sphui.textbox.TextboxNotifier,
        pos: usize,
        items: []const sphui.KeyEvent,
    },
    change_weight: struct {
        node_id: Db.NodeId,
        weight: f32,
    },

    pub fn makeEditSearch(notifier: sphui.textbox.TextboxNotifier, pos: usize, items: []const sphui.KeyEvent) UiAction {
        return .{
            .edit_search = .{
                .notifier = notifier,
                .pos = pos,
                .items = items,
            },
        };
    }

    pub fn makeDragGen(comptime tag: std.meta.Tag(UiAction)) fn (val: f32) UiAction {
        return struct {
            fn f(val: f32) UiAction {
                return @unionInit(UiAction, @tagName(tag), val);
            }
        }.f;
    }
};

const NodeWeightChangeAction = struct {
    node_id: Db.NodeId,

    pub fn generate(self: NodeWeightChangeAction, val: f32) UiAction {
        return .{
            .change_weight = .{
                .node_id = self.node_id,
                .weight = val,
            },
        };
    }
};

fn updateSearchMatches(alloc: Allocator, property_list: *sphui.property_list.PropertyList(UiAction), widget_factory: *sphui.widget_factory.WidgetFactory(UiAction), search_text: []const u8, db: *const Db, weights: *Db.ExtraData(f32)) !void {
    property_list.clear(alloc);

    if (search_text.len == 0) {
        return;
    }

    var node_it = db.idIter();
    while (node_it.next()) |node_id| {
        const node = db.getNode(node_id);
        if (std.mem.indexOf(u8, node.name, search_text) != null) {
            const label = try widget_factory.makeLabel(node.name);
            errdefer label.deinit(widget_factory.alloc);

            const label2 = try widget_factory.makeDragFloat(weights.getPtr(node_id), NodeWeightChangeAction{ .node_id = node_id }, 0.1);
            errdefer label2.deinit(widget_factory.alloc);

            try property_list.pushWidgets(widget_factory.alloc, label, label2);
        }
    }
}

const PropertyListGen = struct {
    property_list: *sphui.property_list.PropertyList(UiAction),
    widget_factory: *sphui.widget_factory.WidgetFactory(UiAction),
    speed: f32,

    fn add(self: PropertyListGen, name: anytype, elem: anytype, comptime tag: std.meta.Tag(UiAction)) !void {
        const key = try self.widget_factory.makeLabel(name);
        errdefer key.deinit(self.widget_factory.alloc);

        const value = try self.widget_factory.makeDragFloat(elem, &UiAction.makeDragGen(tag), self.speed);
        errdefer value.deinit(self.widget_factory.alloc);

        try self.property_list.pushWidgets(self.widget_factory.alloc, key, value);
    }
};

const SelectedNameTextRetriever = struct {
    db: *const Db,
    selected_node: *const Db.NodeId,

    pub fn getText(self: @This()) []const u8 {
        return self.db.getNode(self.selected_node.*).name;
    }
};

pub const Gui = struct {
    runner: sphui.runner.Runner(UiAction),
    widget_factory: *sphui.widget_factory.WidgetFactory(UiAction),

    search_text: std.ArrayListUnmanaged(u8) = .{},
    selected_node: Db.NodeId = Db.NodeId{ .value = 0 },

    // Owned by runner
    search_match: *sphui.property_list.PropertyList(UiAction),

    pub fn initPinned(self: *Gui, alloc: Allocator, tmp_alloc: Allocator, vis: *Vis, window: *Window) !void {
        const initial_params = try initialInit(alloc);
        const layout = initial_params.layout;

        self.* = .{
            .runner = initial_params.runner,
            .widget_factory = initial_params.widget_factory,
            .search_match = undefined,
        };
        errdefer self.deinit(alloc);

        const sidebar_width = 300;

        const box, const stack = blk: {
            const stack = try self.widget_factory.makeStack();
            errdefer stack.deinit(self.widget_factory.alloc);

            break :blk .{
                try self.widget_factory.makeBox(
                    stack.asWidget(),
                    .{
                        .width = sidebar_width,
                        .height = 0,
                    },
                    .fill_height,
                ),
                stack,
            };
        };
        try layout.pushOrDeinitWidget(self.widget_factory.alloc, box);

        const rect = try self.widget_factory.makeRect(.{
            .r = 0.1,
            .g = 0.1,
            .b = 0.1,
            .a = 1.0,
        });
        try stack.pushWidgetOrDeinit(self.widget_factory.alloc, rect, .fill);

        const stack_layout = try self.widget_factory.makeLayout();
        try stack.pushWidgetOrDeinit(self.widget_factory.alloc, stack_layout.asWidget(), .{ .offset = .{ .x_offs = 0, .y_offs = 0 } });

        const property_list = try self.widget_factory.makePropertyList();
        const property_list_widget = property_list.asWidget();
        try stack_layout.pushOrDeinitWidget(self.widget_factory.alloc, property_list_widget);

        self.search_match = try self.widget_factory.makePropertyList();
        try stack_layout.pushOrDeinitWidget(self.widget_factory.alloc, self.search_match.asWidget());

        var property_list_gen = PropertyListGen{
            .property_list = property_list,
            .widget_factory = self.widget_factory,
            .speed = 0.1,
        };

        try property_list_gen.add("Max pull movement", &vis.node_layout.max_pull_movement, .change_max_pull_movement);
        try property_list_gen.add("Max parent pull movement", &vis.node_layout.max_parent_pull_movement, .change_max_parent_pull_movement);
        try property_list_gen.add("Max push movement", &vis.node_layout.max_push_movement, .change_max_push_movement);
        try property_list_gen.add("Max center pull", &vis.node_layout.max_center_movement, .change_max_center_movement);

        try property_list_gen.add("Pull multiplier", &vis.node_layout.pull_multiplier, .change_pull_multiplier);
        try property_list_gen.add("Parent pull multiplier", &vis.node_layout.parent_pull_multiplier, .change_parent_pull_multiplier);
        try property_list_gen.add("Center pull multiplier", &vis.node_layout.center_pull_multiplier, .change_center_pull_multiplier);
        try property_list_gen.add("Push multiplier", &vis.node_layout.push_multiplier, .change_push_multiplier);

        property_list_gen.speed = 0.001;
        try property_list_gen.add("Point radius", &vis.render_params.point_radius, .change_point_radius);
        property_list_gen.speed = 0.1;
        try property_list_gen.add("Line thickness", &vis.render_params.line_thickness, .change_line_thickness);
        try property_list_gen.add("Line alpha multiplier", &vis.render_params.line_alpha_multiplier, .change_line_alpha_multiplier);
        try property_list_gen.add("Distance threshold multiplier", &vis.render_params.dist_thresh_multiplier, .change_dist_thresh_multiplier);
        try property_list_gen.add("Weight propagation ratio", &vis.render_params.weight_propagation_ratio, .change_weight_propagation_ratio);

        {
            const voronoi_debug_label = try self.widget_factory.makeLabel("Voronoi debug");
            errdefer voronoi_debug_label.deinit(self.widget_factory.alloc);

            const voronoi_debug_checkbox = try self.widget_factory.makeCheckbox(&vis.voronoi_debug.enabled, .toggle_voronoi_debug);
            errdefer voronoi_debug_checkbox.deinit(self.widget_factory.alloc);

            try property_list.pushWidgets(self.widget_factory.alloc, voronoi_debug_label, voronoi_debug_checkbox);
        }

        {
            const search_label = try self.widget_factory.makeLabel("Search");
            errdefer search_label.deinit(self.widget_factory.alloc);

            const search_content = try self.widget_factory.makeTextbox(
                &self.search_text.items,
                &UiAction.makeEditSearch,
            );
            errdefer search_content.deinit(self.widget_factory.alloc);

            try property_list.pushWidgets(self.widget_factory.alloc, search_label, search_content);
        }

        {
            const key = try self.widget_factory.makeLabel("Name");
            errdefer key.deinit(self.widget_factory.alloc);

            const value = try self.widget_factory.makeLabel(SelectedNameTextRetriever{
                .db = vis.db,
                .selected_node = &self.selected_node,
            });
            errdefer value.deinit(self.widget_factory.alloc);

            try property_list.pushWidgets(self.widget_factory.alloc, key, value);
        }

        const vis_widget = try VisWidget.create(self.widget_factory.alloc, tmp_alloc, vis, window);
        try layout.pushOrDeinitWidget(self.widget_factory.alloc, vis_widget);
    }

    pub fn deinit(self: *Gui, alloc: Allocator) void {
        self.runner.deinit();
        self.search_text.deinit(alloc);
        self.widget_factory.deinit();
    }

    pub fn step(self: *Gui, window: *Window) !?UiAction {
        const window_width, const window_height = window.getWindowSize();

        const widget_area = sphui.PixelBBox{
            .top = 0,
            .left = 0,
            .right = @intCast(window_width),
            .bottom = @intCast(window_height),
        };

        const window_size = sphui.PixelSize{
            .width = @intCast(window_width),
            .height = @intCast(window_height),
        };

        gl.glViewport(0, 0, @intCast(window_width), @intCast(window_height));
        gl.glScissor(0, 0, @intCast(window_width), @intCast(window_height));

        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        return try self.runner.step(widget_area, window_size, &window.queue);
    }

    const InitialParams = struct {
        layout: *sphui.layout.Layout(UiAction),
        runner: sphui.runner.Runner(UiAction),
        widget_factory: *sphui.widget_factory.WidgetFactory(UiAction),
    };

    fn initialInit(alloc: Allocator) !InitialParams {
        const widget_factory = try sphui.widget_factory.widgetFactory(UiAction, alloc);
        errdefer widget_factory.deinit();

        const layout = try widget_factory.makeLayout();
        layout.cursor.direction = .horizontal;

        var runner = try widget_factory.makeRunnerOrDeinit(layout.asWidget());
        errdefer runner.deinit();

        return .{
            .layout = layout,
            .runner = runner,
            .widget_factory = widget_factory,
        };
    }
};

pub fn applyGuiAction(a: UiAction, alloc: Allocator, vis: *Vis, gui: *Gui) !void {
    switch (a) {
        .change_max_pull_movement => |f| {
            vis.node_layout.max_pull_movement = f;
        },
        .change_max_parent_pull_movement => |f| {
            vis.node_layout.max_parent_pull_movement = f;
        },
        .change_max_push_movement => |f| {
            vis.node_layout.max_push_movement = f;
        },
        .change_pull_multiplier => |f| {
            vis.node_layout.pull_multiplier = f;
        },
        .change_push_multiplier => |f| {
            vis.node_layout.push_multiplier = @max(0.01, f);
        },
        .change_parent_pull_multiplier => |f| {
            vis.node_layout.parent_pull_multiplier = f;
        },
        .change_point_radius => |f| {
            vis.render_params.point_radius = @max(0.00001, f);
        },
        .change_max_center_movement => |f| {
            vis.node_layout.max_center_movement = @max(0.0, f);
        },
        .change_center_pull_multiplier => |f| {
            vis.node_layout.center_pull_multiplier = @max(0.0, f);
        },
        .change_line_thickness => |f| {
            vis.render_params.line_thickness = @max(0.0, f);
        },
        .change_line_alpha_multiplier => |f| {
            vis.render_params.line_alpha_multiplier = @max(0.0, f);
        },
        .edit_search => |params| {
            try sphui.textbox.executeTextEditOnArrayList(alloc, &gui.search_text, params.pos, params.notifier, params.items);
            try updateSearchMatches(alloc, gui.search_match, gui.widget_factory, gui.search_text.items, vis.db, &vis.user_weights);
        },
        .change_weight_propagation_ratio => |r| {
            vis.render_params.weight_propagation_ratio = std.math.clamp(r, 0.0, 1.0);
            vis.applyUserWeights();
        },
        .change_weight => |params| {
            vis.user_weights.getPtr(params.node_id).* = @max(1.000, params.weight);
            vis.applyUserWeights();
        },
        .change_dist_thresh_multiplier => |f| {
            vis.render_params.dist_thresh_multiplier = f;
        },
        .update_closest_node => |n| {
            gui.selected_node = n;
        },
        .toggle_voronoi_debug => {
            vis.voronoi_debug.enabled = !vis.voronoi_debug.enabled;
            vis.voronoi_debug.camera = sphmath.Transform3D.scale(1.0, 1.0, 4.0).then(sphmath.Transform3D.translate(0.0, 0.0, 1.0));
        },
    }
}
