const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("Db.zig");
const Config = @import("Config.zig");
const treesitter = @import("treesitter.zig");
const lsp = @import("lsp.zig");

alloc: Allocator,
processed_files: std.ArrayListUnmanaged([]const u8) = .{},
file_nodes: std.StringHashMapUnmanaged(Db.NodeId) = .{},
blacklist_paths: []const []const u8,
matched_extension: []const u8,
file_parser: *treesitter.FileParser,
reference_retriever: *lsp.ReferenceRetriever,
abs_project_dir: []const u8,
db: *Db,

const DbBuilder = @This();

pub fn deinit(self: *DbBuilder) void {
    for (self.processed_files.items) |item| {
        self.alloc.free(item);
    }
    self.processed_files.deinit(self.alloc);

    var file_node_it = self.file_nodes.keyIterator();
    while (file_node_it.next()) |item| {
        self.alloc.free(item.*);
    }
    self.file_nodes.deinit(self.alloc);
}

pub const FsPopulatorSource = struct {
    abs_project_dir: []const u8,
    buf: []u8,
    dir: std.fs.Dir,
    project_dir_it: std.fs.Dir.Walker,

    pub fn init(alloc: Allocator, abs_project_dir: []const u8) !FsPopulatorSource {
        const buf = try alloc.alloc(u8, 1 << 20);
        errdefer alloc.free(buf);

        var dir = try std.fs.cwd().openDir(abs_project_dir, .{ .iterate = true });
        errdefer dir.close();

        var project_dir_it = try dir.walk(alloc);
        errdefer project_dir_it.deinit();

        return .{
            .abs_project_dir = abs_project_dir,
            .dir = dir,
            .buf = buf,
            .project_dir_it = project_dir_it,
        };
    }

    pub fn deinit(self: *FsPopulatorSource, alloc: Allocator) void {
        alloc.free(self.buf);
        self.project_dir_it.deinit();
        self.dir.close();
    }

    pub const FsItem = struct {
        abs_project_dir: []const u8,
        path: []const u8,
        buf: []u8,

        // Data valid until next content() call from any FsItem, data owned by
        // FsPopulatorSource, do not free
        pub fn content(self: FsItem) ![]const u8 {
            var abs_file_buf: [std.fs.max_path_bytes]u8 = undefined;

            const abs_path = try std.fmt.bufPrint(&abs_file_buf, "{s}{s}{s}", .{ self.abs_project_dir, std.fs.path.sep_str, self.path });

            const f = try std.fs.openFileAbsolute(abs_path, .{});
            defer f.close();

            const len = try f.readAll(self.buf);
            return self.buf[0..len];
        }
    };

    pub fn next(self: *FsPopulatorSource) !?FsItem {
        const entry = try self.project_dir_it.next() orelse return null;
        return .{
            .abs_project_dir = self.abs_project_dir,
            .path = entry.path,
            .buf = self.buf,
        };
    }
};

pub const TarPopulatorSource = struct {
    buf_reader: IoReader,
    tar_iter: TarIter,
    content_buf: []u8,
    name_buf: [std.fs.max_path_bytes]u8 = undefined,
    link_buf: [std.fs.max_path_bytes]u8 = undefined,

    const IoReader = std.io.FixedBufferStream([]const u8);
    const TarIter = std.tar.Iterator(IoReader.Reader);

    pub fn init(alloc: Allocator, tar_data: []const u8) !*TarPopulatorSource {
        const ret = try alloc.create(TarPopulatorSource);
        errdefer alloc.destroy(ret);

        const content_buf = try alloc.alloc(u8, 1<<20);
        errdefer alloc.free(content_buf);

        ret.* = .{
            .buf_reader = std.io.fixedBufferStream(tar_data),
            .tar_iter = undefined,
            .content_buf = content_buf,
        };
        errdefer alloc.destroy(ret.buf_reader);

        ret.tar_iter = std.tar.iterator(ret.buf_reader.reader(), .{
            .file_name_buffer = &ret.name_buf,
            .link_name_buffer = &ret.link_buf,
        });

        return ret;
    }

    pub fn deinit(self: *TarPopulatorSource, alloc: Allocator) void {
        alloc.destroy(self);
    }

    pub const TarItem = struct {
        // Duplicated from file, but part of public API
        path: []const u8,

        file: TarIter.File,
        buf: []u8,

        pub fn content(self: TarItem) ![]const u8 {
            const len = try self.file.read(self.buf);
            return self.buf[0..len];
        }
    };

    pub fn next(self: *TarPopulatorSource) !?TarItem {
        const tar_item = try self.tar_iter.next() orelse return null;

        return .{
            .path = tar_item.name,
            .file = tar_item,
            .buf = self.content_buf,
        };
    }
};

// Add all nodes that we care about to the database (ignoring references, those
// require all nodes to exist before populating)
//
// source should be a ...PopulatorSource
pub fn populateDbNodes(self: *DbBuilder, source: anytype) !void {
    const project_dir = try std.fs.cwd().openDir(self.abs_project_dir, .{ .iterate = true });

    var project_dir_it = try project_dir.walk(self.alloc);
    defer project_dir_it.deinit();

    while (try source.next()) |entry| {
        if (isBlacklisted(entry.path, self.blacklist_paths)) {
            continue;
        }

        if (!std.mem.endsWith(u8, entry.path, self.matched_extension)) {
            continue;
        }

        try self.addPathWithParents(entry.path);

        {
            const full_path = try std.fs.path.join(self.alloc, &.{ self.abs_project_dir, entry.path });
            errdefer self.alloc.free(full_path);

            try self.processed_files.append(self.alloc, full_path);
        }

        const file_id = self.file_nodes.get(entry.path) orelse unreachable;

        const file_content = try entry.content();
        try addFileNodesToDb(self.alloc, self.file_parser, entry.path, file_id, file_content, self.db);
    }
}

pub fn populateReferences(self: *DbBuilder) !void {
    for (self.processed_files.items) |file| {
        std.log.debug("Opening {s}", .{file});
        try self.reference_retriever.openFile(self.alloc, file);
    }

    var node_it = self.db.idIter();
    const num_nodes = self.db.nodes.items.len;

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("Populating references\n");

    var i: usize = 0;
    while (node_it.next()) |id| {
        const node = self.db.getNodePtr(id);
        i += 1;
        try stdout.print("\r{d}/{d}", .{ i, num_nodes });

        if (node.data != .within_file) continue;

        const node_data = node.data.within_file;

        const full_path = try std.fs.path.join(self.alloc, &.{ self.abs_project_dir, node_data.path });
        defer self.alloc.free(full_path);

        var references = try self.reference_retriever.findReferences(self.alloc, full_path, node_data.ident_range.start.line, node_data.ident_range.start.col);
        defer references.deinit();

        try addReferencesToDb(self.alloc, self.abs_project_dir, id, &references, self.db);
    }
    try stdout.writeAll("\n");
}

fn addPathIfMissing(self: *DbBuilder, name: []const u8, path: []const u8) !void {
    const gop = try self.file_nodes.getOrPut(self.alloc, path);

    if (gop.found_existing) return;

    errdefer _ = self.file_nodes.remove(path);
    gop.key_ptr.* = try self.alloc.dupe(u8, path);

    const parent_query: Db.NodeQuery = blk: {
        const parent_name = std.fs.path.dirname(path) orelse break :blk .none;
        const parent_id = self.file_nodes.get(parent_name) orelse break :blk .none;
        break :blk .{ .id = parent_id };
    };
    const id = try self.db.addFsNode(self.alloc, path, name, parent_query);

    gop.value_ptr.* = id;
}

fn addPathWithParents(self: *DbBuilder, path: []const u8) !void {
    // Add path with parents
    var component_it = try std.fs.path.componentIterator(path);
    while (component_it.next()) |res| {
        try self.addPathIfMissing(res.path, res.path);
    }
}

fn uriToPath(uri: []const u8, abs_project_dir: []const u8) ?[]const u8 {
    std.debug.assert(std.mem.startsWith(u8, uri, "file://"));
    const full_path = uri[7..];
    if (!std.mem.startsWith(u8, full_path, abs_project_dir)) return null;

    return full_path[abs_project_dir.len + 1 ..];
}

fn addReferencesToDb(alloc: Allocator, abs_project_dir: []const u8, node_being_referenced: Db.NodeId, references: *lsp.ReferenceRetriever.ReferenceIt, db: *Db) !void {
    // Imagine the following
    //
    // We want to know who references A.B.c
    //
    // Lsp returns locations that map to
    //   C.D.e
    //   F.G.h
    //
    // We want to output the following as the list of elements we have to append to Node.referenced_by
    //   C.D.e
    //   C.D
    //   C
    //   F.G.h
    //   F.G
    //   F
    //
    // AND we want to append this whole list to all of
    // A
    // A.B
    // A.B.c

    var append_it: ?Db.NodeId = node_being_referenced;
    while (append_it) |append_id| {
        const node = db.getNodePtr(append_id);
        append_it = node.parent;

        defer references.reset();
        while (references.next()) |ref| {
            const ref_path = uriToPath(ref.uri, abs_project_dir) orelse {
                std.log.debug("skipping path: {s}", .{ref.uri});
                continue;
            };

            var reference_nodes = db.nodesContainingLoc(ref_path, ref.range.start);

            while (reference_nodes.next()) |ref_node_id| {
                // Node == AppWidget.render
                // Ref == AppWidget.vtable.render
                //
                // AppWidget contains AppWidget.vtable which means that the
                // node_id here will sometimes be AppWidget, which results in
                // AppWidget references AppWidget.render, which is silly
                const ref_node = db.getNode(ref_node_id);
                if (!ref_node.data.containsNodeData(node.data) and !node.data.containsNodeData(ref_node.data)) {
                    try node.referenced_by.append(alloc, ref_node_id);
                }
            }
        }
    }
    var append_node: ?Db.NodeId = node_being_referenced;
    while (append_node) |nid| {
        // For each ref, check if it is a child of us, if it is, ignore
        const node_to_append = db.getNodePtr(nid);
        append_node = node_to_append.parent;
    }
}

const ConcatNodeName = struct {
    name: []const u8,
    last_split: usize,

    fn deinit(self: ConcatNodeName, alloc: Allocator) void {
        alloc.free(self.name);
    }
};

fn concatNodeName(alloc: Allocator, parent_name: []const u8, trailing_components: []const []const u8) !ConcatNodeName {
    if (trailing_components.len == 0) {
        std.debug.assert(false);
        return .{
            .name = "",
            .last_split = 0,
        };
    }

    var path_name = std.ArrayList(u8).init(alloc);
    defer path_name.deinit();

    var last_split: usize = 0;
    try path_name.appendSlice(parent_name);

    for (0..trailing_components.len) |i| {
        last_split = path_name.items.len;
        try path_name.append('/');
        try path_name.appendSlice(trailing_components[i]);
    }

    return .{
        .name = try path_name.toOwnedSlice(),
        .last_split = last_split,
    };
}

fn addFileNodesToDb(alloc: Allocator, file_parser: *treesitter.FileParser, file_path: []const u8, file_parent_id: Db.NodeId, file_content: []const u8, db: *Db) !void {
    var file_it = try file_parser.parseFile(file_content);
    defer file_it.deinit();

    while (try file_it.next(alloc)) |item| {
        defer item.deinit(alloc);

        const concat_name = try concatNodeName(alloc, db.getNode(file_parent_id).name, item.path);
        defer concat_name.deinit(alloc);
        const parent_path_name = concat_name.name[0..concat_name.last_split];

        const parent_id = if (item.path.len <= 1) Db.NodeQuery{ .id = file_parent_id } else Db.NodeQuery{ .name = parent_path_name };

        _ = try db.addNode(alloc, file_path, concat_name.name, parent_id, item.ident_range, item.range);
    }
}

pub fn logAllReferences(db: Db) void {
    var node_it = db.idIter();
    std.debug.print("LOGGING REFERENCES\n", .{});
    defer std.debug.print("END LOGGING REFERENCES\n", .{});
    while (node_it.next()) |id| {
        const node = db.getNode(id);
        if (node.referenced_by.items.len > 0) {
            std.debug.print("{s} is referenced by\n", .{node.name});
            for (node.referenced_by.items) |ref_id| {
                const ref = db.getNode(ref_id);
                std.debug.print("   {s}\n", .{ref.name});
            }
            std.debug.print("\n", .{});
        }
    }
}

fn isBlacklisted(path: []const u8, blacklisted_paths: []const []const u8) bool {
    var component_it = try std.fs.path.componentIterator(path);
    while (component_it.next()) |comp| {
        for (blacklisted_paths) |bp| {
            if (std.mem.eql(u8, comp.name, bp)) {
                return true;
            }
        }
    }
    return false;
}
