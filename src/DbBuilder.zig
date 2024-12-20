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

    pub fn open(self: FsPopulatorSource, path: []const u8, buf: []u8) ![]const u8 {
        var abs_file_buf: [std.fs.max_path_bytes]u8 = undefined;

        const abs_path = try std.fmt.bufPrint(
            &abs_file_buf,
            "{s}{s}{s}",
            .{ self.abs_project_dir, std.fs.path.sep_str, path },
        );

        const f = try std.fs.openFileAbsolute(abs_path, .{});
        defer f.close();

        const len = try f.readAll(buf);
        return buf[0..len];
    }

    pub fn iter(self: FsPopulatorSource, alloc: Allocator) !Iterator {
        return Iterator.init(alloc, self.abs_project_dir);
    }

    pub const Iterator = struct {
        dir: std.fs.Dir,
        project_dir_it: std.fs.Dir.Walker,

        pub fn init(alloc: Allocator, abs_project_dir: []const u8) !Iterator {
            var dir = try std.fs.cwd().openDir(abs_project_dir, .{ .iterate = true });
            errdefer dir.close();

            var project_dir_it = try dir.walk(alloc);
            errdefer project_dir_it.deinit();

            return .{
                .dir = dir,
                .project_dir_it = project_dir_it,
            };
        }

        pub fn deinit(self: *Iterator) void {
            self.project_dir_it.deinit();
            self.dir.close();
        }

        pub fn next(self: *Iterator) !?[]const u8 {
            const entry = try self.project_dir_it.next() orelse return null;
            return entry.path;
        }
    };
};

// Add all nodes that we care about to the database (ignoring references, those
// require all nodes to exist before populating)
pub fn populateDbNodes(self: *DbBuilder, source: FsPopulatorSource) !void {
    var it = try source.iter(self.alloc);
    defer it.deinit();

    const buf = try self.alloc.alloc(u8, 1 << 20);
    defer self.alloc.free(buf);

    while (try it.next()) |path| {
        if (isBlacklisted(path, self.blacklist_paths)) {
            continue;
        }

        if (!std.mem.endsWith(u8, path, self.matched_extension)) {
            continue;
        }

        try self.addPathWithParents(path);

        {
            const duped_path = try self.alloc.dupe(u8, path);
            errdefer self.alloc.free(duped_path);

            try self.processed_files.append(self.alloc, duped_path);
        }

        // Added in self.addPathWithParents
        const file_id = self.file_nodes.get(path) orelse unreachable;

        const file_content = try source.open(path, buf);
        try addFileNodesToDb(self.alloc, self.file_parser, path, file_id, file_content, self.db);
    }
}

pub const ReferencePopulator = struct {
    db_builder: *DbBuilder,
    node_it: Db.IdIter,
    uri_buf: [std.fs.max_path_bytes + 10]u8 = undefined,
    state: enum {
        waiting,
        iterating,
    } = .waiting,

    pub fn step(self: *ReferencePopulator) !bool {
        switch (self.state) {
            .waiting => {
                try self.db_builder.reference_retriever.waitReady(self.db_builder.alloc);
                self.state = .iterating;
                return true;
            },
            .iterating => {
                return self.stepInner();
            },
        }
    }

    pub fn stepInner(self: *ReferencePopulator) !bool {
        while (true) {
            const id = self.node_it.next() orelse return false;
            const node = self.db_builder.db.getNode(id);
            if (node.data != .within_file) return true;

            const node_data = node.data.within_file;

            const uri = try pathToUri(node_data.path, self.db_builder.abs_project_dir, &self.uri_buf);

            var references = try self.db_builder.reference_retriever.findReferences(
                self.db_builder.alloc,
                uri,
                node_data.ident_range.start.line,
                node_data.ident_range.start.col,
            );
            defer references.deinit();

            try addReferencesToDb(
                self.db_builder.alloc,
                self.db_builder.abs_project_dir,
                id,
                &references,
                self.db_builder.db,
            );
            return true;
        }
    }
};

pub fn referencePopulator(self: *DbBuilder, source: FsPopulatorSource) !ReferencePopulator {
    const content_buf = try self.alloc.alloc(u8, 1 << 20);
    defer self.alloc.free(content_buf);

    var uri_buf: [std.fs.max_path_bytes + 10]u8 = undefined;

    for (self.processed_files.items) |file| {
        std.log.debug("Opening file {s}\n", .{file});
        const uri = try pathToUri(file, self.abs_project_dir, &uri_buf);
        const content = try source.open(file, content_buf);

        try self.reference_retriever.openFile(self.alloc, uri, content);
    }

    return .{
        .db_builder = self,
        .node_it = self.db.idIter(),
    };
}

pub fn populateReferences(self: *DbBuilder, source: FsPopulatorSource) !void {
    var populator = try self.referencePopulator(source);
    while (try populator.step()) {}
}

fn addPathIfMissing(self: *DbBuilder, name: []const u8, path: []const u8) !void {
    const gop = try self.file_nodes.getOrPut(self.alloc, path);

    if (gop.found_existing) return;

    errdefer _ = self.file_nodes.remove(path);
    gop.key_ptr.* = try self.alloc.dupe(u8, path);

    const parent_query: Db.NodeQuery = blk: {
        const parent_name = std.fs.path.dirname(path) orelse break :blk .none;
        break :blk .{ .name = parent_name };
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

fn pathToUri(path: []const u8, abs_project_dir: []const u8, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "file://{s}{s}{s}", .{ abs_project_dir, std.fs.path.sep_str, path });
}

fn uriToPath(uri: []const u8, abs_project_dir: []const u8) ?[]const u8 {
    std.debug.assert(std.mem.startsWith(u8, uri, "file://"));
    const full_path = uri[7..];
    if (!std.mem.startsWith(u8, full_path, abs_project_dir)) return null;

    return full_path[abs_project_dir.len + 1 ..];
}

fn addReferencesToDb(
    alloc: Allocator,
    abs_project_dir: []const u8,
    node_being_referenced: Db.NodeId,
    references: *lsp.ReferenceRetriever.ReferenceIt,
    db: *Db,
) !void {
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

        const parent_id = if (item.path.len <= 1)
            Db.NodeQuery{ .id = file_parent_id }
        else
            Db.NodeQuery{ .name = parent_path_name };

        _ = try db.addNode(alloc, file_path, concat_name.name, parent_id, item.ident_range, item.range);
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

const TestFixture = struct {
    tmp_dir: std.testing.TmpDir,
    tmp_dir_path: []const u8,
    file_parser: treesitter.FileParser,
    reference_retriever: lsp.ReferenceRetriever,
    recording_root: []const u8,
    // Referenced by file_parser, so needs a stable memory address
    config: *std.json.Parsed(Config),

    pub fn init() !TestFixture {
        const config = try getLangConfig(std.testing.allocator);
        errdefer config.deinit();

        var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp_dir.cleanup();

        try extractResources(tmp_dir.dir);

        var tmp_dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_dir_path_stack = try std.os.getFdPath(tmp_dir.dir.fd, &tmp_dir_path_buf);
        const tmp_dir_path = try std.testing.allocator.dupe(u8, tmp_dir_path_stack);

        const file_parser = try makeTsParser(tmp_dir.dir, &config.value);
        const reference_retriever = try makeReferenceRetriever(tmp_dir.dir);

        const recording_root = try getRecordingRoot(tmp_dir.dir);

        return .{
            .config = config,
            .file_parser = file_parser,
            .tmp_dir = tmp_dir,
            .tmp_dir_path = tmp_dir_path,
            .recording_root = recording_root,
            .reference_retriever = reference_retriever,
        };
    }

    pub fn deinit(self: *TestFixture) void {
        self.tmp_dir.cleanup();
        self.file_parser.deinit();
        self.config.deinit();
        std.testing.allocator.free(self.tmp_dir_path);
        std.testing.allocator.destroy(self.config);
        std.testing.allocator.free(self.recording_root);
    }

    fn getRecordingRoot(tmp_dir: std.fs.Dir) ![]const u8 {
        const f = try tmp_dir.openFile("recording_root.txt", .{});
        defer f.close();

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try f.readAll(&buf);
        const recording_root = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);

        return try std.testing.allocator.dupe(u8, recording_root);
    }

    fn getLangConfig(alloc: Allocator) !*std.json.Parsed(Config) {
        const lang_config_data = @embedFile("zig_config");

        const ret = try alloc.create(std.json.Parsed(Config));
        errdefer alloc.destroy(ret);

        ret.* = try std.json.parseFromSlice(Config, alloc, lang_config_data, .{});

        return ret;
    }

    fn extractResources(tmp_dir: std.fs.Dir) !void {
        const tarball_data = @embedFile("test_tarball");
        var fb = std.io.fixedBufferStream(tarball_data);
        try std.tar.pipeToFileSystem(tmp_dir, fb.reader(), .{});
    }

    fn makeTsParser(tmp_dir: std.fs.Dir, config: *Config) !treesitter.FileParser {
        const parser_so = @embedFile("zig_so");

        const zig_so_file = try tmp_dir.createFile("zig.so", .{});
        try zig_so_file.writeAll(parser_so);

        var zig_so_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memset(&zig_so_path_buf, 0);

        const zig_so_path = try std.os.getFdPath(zig_so_file.handle, &zig_so_path_buf);

        const file_parser = try treesitter.FileParser.init(
            @ptrCast(zig_so_path), // getFdPath is null termiiated due to the memset(0)
            config.treesitter_init,
            &config.treesitter_ruleset,
        );

        return file_parser;
    }

    fn makeReferenceRetriever(tmp_dir: std.fs.Dir) !lsp.ReferenceRetriever {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const recording_path = try tmp_dir.realpath("recording", &path_buf);
        return lsp.ReferenceRetriever.initRecording(recording_path);
    }
};

test "sanity" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();

    var db = Db{};
    defer db.deinit(std.testing.allocator);

    var db_builder = DbBuilder{
        .alloc = std.testing.allocator,
        .blacklist_paths = fixture.config.value.blacklist_paths,
        .matched_extension = fixture.config.value.matched_extension,
        .file_parser = &fixture.file_parser,
        .reference_retriever = &fixture.reference_retriever,
        .abs_project_dir = fixture.recording_root,
        .db = &db,
    };
    defer db_builder.deinit();

    const populator_source = FsPopulatorSource{ .abs_project_dir = fixture.tmp_dir_path };

    try db_builder.populateDbNodes(populator_source);
    try db_builder.populateReferences(populator_source);

    const node_id = db.findNodeId(.{ .name = "src/libA/a.zig/SomeUnion/doSomething" }) orelse return error.MissingNode;
    var node = db.getNode(node_id);
    const parents: []const []const u8 = &.{
        "src/libA/a.zig/SomeUnion",
        "src/libA/a.zig",
        "src/libA",
        "src",
    };

    for (parents) |parent_name| {
        node = db.getNode(node.parent orelse return error.MissingParent);
        try std.testing.expectEqualStrings(parent_name, node.name);
    }

    try std.testing.expectEqual(null, node.parent);

    try expectReferencedBy(
        std.testing.allocator,
        db,
        "src/libA/a.zig/SomeUnion/doSomething",
        &.{
            .{
                .name = "src/libA/a.zig/SomeStruct/doSomething",
                .num_refs = 1,
            },
            .{
                .name = "src/libA/a.zig/SomeStruct",
                .num_refs = 1,
            },
            .{
                .name = "src/main.zig",
                .num_refs = 1,
            },
            .{
                .name = "src/main.zig/main",
                .num_refs = 1,
            },
        },
    );

    try expectReferencedBy(
        std.testing.allocator,
        db,
        "src/libA/a.zig/SomeUnion",
        &.{
            .{
                .name = "src/libA/a.zig/SomeStruct",
                .num_refs = 3,
            },
            .{
                .name = "src/libA/a.zig/SomeStruct/doSomething",
                .num_refs = 1,
            },
            .{
                .name = "src/libA/a.zig/SomeStruct/init",
                .num_refs = 1,
            },
            .{
                .name = "src/libA/a.zig/aFreeFn",
                .num_refs = 1,
            },
            .{
                .name = "src/main.zig",
                .num_refs = 2,
            },
            .{
                .name = "src/main.zig/main",
                .num_refs = 2,
            },
        },
    );

    try expectReferencedBy(
        std.testing.allocator,
        db,
        "src/libA/a.zig/aFreeFn",
        &.{
            .{
                .name = "src/libB/b.zig/aFreeFn",
                .num_refs = 1,
            },
            .{
                .name = "src/libB/b.zig",
                .num_refs = 1,
            },
            .{
                .name = "src/libB",
                .num_refs = 1,
            },
            .{
                .name = "src/main.zig/main",
                .num_refs = 1,
            },
            .{
                .name = "src/main.zig",
                .num_refs = 1,
            },
        },
    );
}

const UsageCount = struct {
    name: []const u8,
    num_refs: usize,
};

fn expectReferencedBy(alloc: Allocator, db: Db, node_name: []const u8, expected_counts: []const UsageCount) !void {
    const node_id = db.findNodeId(.{ .name = node_name }) orelse return error.NodeNotFound;
    const node = db.getNode(node_id);

    var counts = std.StringHashMap(usize).init(alloc);
    defer counts.deinit();

    for (node.referenced_by.items) |ref_node_id| {
        const ref_node = db.getNode(ref_node_id);
        const gop = try counts.getOrPut(ref_node.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    for (expected_counts) |expected| {
        const count = counts.get(expected.name) orelse {
            std.log.err("{s} is not referenced by {s}", .{ node_name, expected.name });
            return error.MissingReference;
        };

        if (count != expected.num_refs) {
            std.log.err(
                "{s} is referenced by {s} {d} times, expected {d}",
                .{ node_name, expected.name, count, expected.num_refs },
            );
            return error.IncorrectRefcount;
        }
    }

    var ref_names = counts.keyIterator();
    while (ref_names.next()) |ref_name| {
        if (!isInExpected(ref_name.*, expected_counts)) {
            std.log.err("{s} is referenced by {s}", .{ node_name, ref_name.* });
            return error.UnexpectedReference;
        }
    }
}

fn isInExpected(name: []const u8, expected_counts: []const UsageCount) bool {
    for (expected_counts) |expected| {
        if (std.mem.eql(u8, expected.name, name)) {
            return true;
        }
    }
    return false;
}
