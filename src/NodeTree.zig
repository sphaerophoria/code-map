const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("Db.zig");

items: Db.ExtraData(Item),
root_nodes: std.ArrayListUnmanaged(Db.NodeId),

const NodeTree = @This();

pub fn init(alloc: Allocator, db: *const Db) !NodeTree {
    var ret = try buildTreeDirectDescendents(alloc, db);
    ret.populateDescendents(db);
    return ret;
}

pub fn deinit(self: *NodeTree, alloc: Allocator) void {
    freeNodeTreeItems(&self.items, alloc);
    self.root_nodes.deinit(alloc);
}

const Item = struct {
    children: std.ArrayListUnmanaged(Db.NodeId),
    generation: u8 = 0,
    num_descendents: usize = 0,

    pub fn deinit(self: *Item, alloc: Allocator) void {
        self.children.deinit(alloc);
    }
};

const Walker = struct {
    tree: *const NodeTree,
    // FIXME: Switch to something arena friendly
    stack: std.ArrayList(StackItem),

    const Output = struct {
        level: usize,
        node: Db.NodeId,
    };

    const StackItem = struct {
        child_list: []const Db.NodeId,
        child_idx: usize = 0,
    };

    pub fn init(alloc: Allocator, tree: *const NodeTree, root_list: []const Db.NodeId) !Walker {
        var stack = std.ArrayList(StackItem).init(alloc);
        try stack.append(.{
            .child_list = root_list,
        });
        return .{
            .tree = tree,
            .stack = stack,
        };
    }

    pub fn next(self: *Walker) !?Output {
        const ret = self.currentNode() orelse return null;
        try self.advance();
        return ret;
    }

    fn currentNode(self: *Walker) ?Output {
        if (self.stack.items.len == 0) return null;
        const stack_item = self.stack.items[self.stack.items.len - 1];
        return .{
            .node = stack_item.child_list[stack_item.child_idx],
            .level = self.stack.items.len - 1,
        };
    }

    fn advance(self: *Walker) !void {
        // We want to hit the items on the way down, so it is likely that
        // we have to recurse into the most recent item on the stack. We
        // handle advancing child_idx on pop
        {
            const current_end = &self.stack.items[self.stack.items.len - 1];

            if (current_end.child_list.len > current_end.child_idx) {
                const next_id = current_end.child_list[current_end.child_idx];
                try self.stack.append(.{
                    .child_list = self.tree.items.get(next_id).children.items,
                    .child_idx = 0,
                });
            }
        }

        // Cannot go down further, go up and advance until we hit a valid node
        while (!self.atValidLocation()) {
            _ = self.stack.pop();
            if (self.stack.items.len == 0) break;
            const current_end = &self.stack.items[self.stack.items.len - 1];
            current_end.child_idx += 1;
        }
    }

    fn atValidLocation(self: *const Walker) bool {
        if (self.stack.items.len == 0) return false;
        const last = self.stack.getLast();
        return last.child_idx < last.child_list.len;
    }
};

pub fn walker(self: *const NodeTree, alloc: Allocator) !Walker {
    return try Walker.init(alloc, self, self.root_nodes.items);
}

fn buildTreeDirectDescendents(alloc: Allocator, db: *const Db) !NodeTree {
    var items = try db.makeExtraData(NodeTree.Item, alloc, .{ .children = .{}, .num_descendents = 0 });
    errdefer freeNodeTreeItems(&items, alloc);

    var root_nodes = std.ArrayListUnmanaged(Db.NodeId){};
    errdefer root_nodes.deinit(alloc);

    var node_it = db.idIter();
    while (node_it.next()) |id| {
        const node = db.getNode(id);
        if (node.parent) |parent_id| {
            try items.getPtr(parent_id).children.append(alloc, id);
        } else {
            try root_nodes.append(alloc, id);
        }
    }

    return .{
        .root_nodes = root_nodes,
        .items = items,
    };
}

fn populateDescendents(tree: *NodeTree, db: *const Db) void {
    var node_it = db.idIter();
    while (node_it.next()) |id| {
        const node = tree.items.getPtr(id);

        node.num_descendents += node.children.items.len;
        node.generation = nodeDepth(db, id);
        updateParentDescendents(tree, db, id);
    }
}

fn updateParentDescendents(tree: *NodeTree, db: *const Db, id: Db.NodeId) void {
    var parent_it = NodeParentIt.init(db, id);
    const input_node = tree.items.get(id);
    var generation = input_node.generation;
    while (parent_it.next()) |parent_id| {
        generation -= 1;
        const parent_node = tree.items.getPtr(parent_id);
        // Careful, we are only updating the descendants that are direct
        // children of the input ID. As we loop all IDs, grandchildren will
        // naturally also get added
        parent_node.num_descendents += input_node.children.items.len;
        parent_node.generation = @max(parent_node.generation, generation);
    }
}

fn freeNodeTreeItems(children: *Db.ExtraData(NodeTree.Item), alloc: Allocator) void {
    var node_it = children.idIter();
    while (node_it.next()) |id| {
        const node_children = children.getPtr(id);
        node_children.deinit(alloc);
    }

    children.deinit(alloc);
}

const NodeParentIt = struct {
    db: *const Db,
    id: Db.NodeId,

    pub fn init(db: *const Db, id: Db.NodeId) NodeParentIt {
        return .{
            .db = db,
            .id = id,
        };
    }

    pub fn next(self: *NodeParentIt) ?Db.NodeId {
        const node = self.db.getNode(self.id);
        const parent = node.parent orelse return null;

        defer self.id = parent;

        return parent;
    }
};

fn nodeDepth(db: *const Db, id: Db.NodeId) u8 {
    var depth: u8 = 0;
    var parent_it = NodeParentIt.init(db, id);
    while (parent_it.next()) |_| depth += 1;
    return depth;
}
