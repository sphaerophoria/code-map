const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp.zig");
const coords = @import("coords.zig");
const treesitter = @import("treesitter.zig");
const Db = @import("Db.zig");

const TextRange = coords.TextRange;
const TextPosition = coords.TextPosition;

pub const std_options = std.Options {
    .log_level = .info,
};

const Config = struct {
    language_server: []const []const u8,
    language_id: []const u8,
    blacklist_paths: []const []const u8,
    treesitter_so: [:0]const u8,
    treesitter_init: [:0]const u8,
    treesitter_ruleset: treesitter.RuleSet,
    matched_extension: []const u8,
};

const Args = struct {
    project_root: []const u8,
    recording_dir: ?[]const u8,
    replay_dir: ?[]const u8,
    config: []const u8,
    it: std.process.ArgIterator,

    fn deinit(self: *Args) void {
        self.it.deinit();
    }

    const Switch = enum {
        @"--recording-dir",
        @"--replay-dir",
        @"--config",
        @"--scan-dir",
        @"--help",
    };

    fn parse(alloc: Allocator) Args {
        var it = try std.process.argsWithAllocator(alloc);

        const process_name = it.next() orelse "code-map";

        var recording_dir: ?[]const u8 = null;
        var config: ?[]const u8 = null;
        var scan_dir: ?[]const u8 = null;
        var replay_dir: ?[]const u8 = null;

        while (it.next()) |arg| {
            const parsed = std.meta.stringToEnum(Switch, arg) orelse {
                std.log.err("Unknown arg {s}", .{arg});
                help(process_name);
            };

            switch (parsed) {
                .@"--recording-dir" => {
                    recording_dir = nextArg(&it, "recording dir", process_name);
                },
                .@"--scan-dir" => {
                    scan_dir = nextArg(&it, "scan dir", process_name);
                },
                .@"--replay-dir" => {
                    replay_dir = nextArg(&it, "replay dir", process_name);
                },
                .@"--config" => {
                    config = nextArg(&it, "config", process_name);
                },
                .@"--help" => {
                    help(process_name);
                },
            }
        }

        if (recording_dir != null and replay_dir != null) {
            std.log.err("--recording-dir and --replay-dir do not work at the same time", .{});
            help(process_name);
        }

        return .{
            .recording_dir = recording_dir,
            .config = config orelse {
                std.log.err("Config not provided", .{});
                help(process_name);
            },
            .project_root = scan_dir orelse {
                std.log.err("Scan dir not provided", .{});
                help(process_name);
            },
            .replay_dir = replay_dir,
            .it = it,
        };
    }

    fn nextArg(it: *std.process.ArgIterator, comptime field: []const u8, process_name: []const u8) []const u8 {
        const val = it.next() orelse {
            std.log.err("No " ++ field ++ " provided", .{});
            help(process_name);
        };

        if (std.mem.eql(u8, val, "--help")) {
            help(process_name);
        }

        return val;
    }

    fn parseInt(comptime T: type, s: []const u8, comptime field: []const u8, process_name: []const u8) T {
        return std.fmt.parseInt(u32, s, 0) catch {
            std.log.err("Invalid " ++ field, .{});
            help(process_name);
        };
    }

    fn help(program_name: []const u8) noreturn {
        const stderr = std.io.getStdErr().writer();
        stderr.print(
            \\USAGE: {s} [ARGS]
            \\
            \\Print references at file using config
            \\
            \\Required args:
            \\--config <config>: Language configuration (see res/config.json for zig)
            \\--scan-dir <dir>: What are we indexing
            \\
            \\Optional args:
            \\--recording-dir <dir>: Write down LSP responses here
            \\--replay-dir <dir>: Instead of launching the LSP, use this recording
            \\
        , .{program_name}) catch {};

        std.process.exit(1);
    }
};

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

fn makeProcessRetriever(alloc: Allocator, config: Config, abs_project_dir: []const u8, recording_dir: ?[]const u8) !lsp.ReferenceRetriever {
    var recorder: ?lsp.Recorder = null;
    if (recording_dir) |d| {
        recorder = try lsp.Recorder.init(d);
    }

    return try lsp.ReferenceRetriever.init(alloc, config.language_server, abs_project_dir, config.language_id, recorder);
}

const DbBuilder = struct {
    alloc: Allocator,
    processed_files: std.ArrayListUnmanaged([]const u8) = .{},
    file_nodes: std.StringHashMapUnmanaged(Db.NodeId) = .{},
    config: *const Config,
    file_parser: *treesitter.FileParser,
    reference_retriever: *lsp.ReferenceRetriever,
    abs_project_dir: []const u8,
    db: *Db,

    fn deinit(self: *DbBuilder) void {
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

    // Add all nodes that we care about to the database (ignoring references, those
    // require all nodes to exist before populating)
    fn populateDbNodes(self: *DbBuilder) !void {
        const project_dir = try std.fs.cwd().openDir(self.abs_project_dir, .{ .iterate = true });

        var project_dir_it = try project_dir.walk(self.alloc);
        defer project_dir_it.deinit();

        while (try project_dir_it.next()) |entry| {
            if (isBlacklisted(entry.path, self.config.blacklist_paths)) {
                continue;
            }

            if (!std.mem.endsWith(u8, entry.path, self.config.matched_extension)) {
                continue;
            }

            try self.addPathWithParents(entry.path);
            const file_id = self.file_nodes.get(entry.path) orelse unreachable;

            const abs_file = try std.fs.path.join(self.alloc, &.{self.abs_project_dir, entry.path});

            {
                errdefer self.alloc.free(abs_file);
                try self.processed_files.append(self.alloc, abs_file);
            }

            const f = try std.fs.openFileAbsolute(abs_file, .{});
            defer f.close();

            const file_content = try f.readToEndAlloc(self.alloc, 1 << 20);
            defer self.alloc.free(file_content);

            try addFileNodesToDb(self.alloc, self.file_parser, entry.path, file_id, file_content, self.db);
        }
    }

    fn populateReferences(self: *DbBuilder) !void {
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
            try stdout.print("\r{d}/{d}", .{i, num_nodes});

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
};


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = Args.parse(alloc);
    defer args.deinit();

    const config_f = try std.fs.cwd().openFile(args.config, .{});
    var config_reader = std.json.reader(alloc, config_f.reader());
    defer config_reader.deinit();

    const config = try std.json.parseFromTokenSource(Config, alloc, &config_reader, .{});
    defer config.deinit();

    const abs_project_dir = try std.fs.cwd().realpathAlloc(alloc, args.project_root);
    defer alloc.free(abs_project_dir);

    var file_parser = try treesitter.FileParser.init(
        config.value.treesitter_so,
        config.value.treesitter_init,
        &config.value.treesitter_ruleset,
    );
    defer file_parser.deinit();

    var retriever = if (args.replay_dir) |d|
        try lsp.ReferenceRetriever.initRecording(d)
    else
        try makeProcessRetriever(alloc, config.value, abs_project_dir, args.recording_dir);
    defer retriever.deinit();

    var db = Db{};
    defer db.deinit(alloc);

    const project_dir = try std.fs.cwd().openDir(args.project_root, .{ .iterate = true });

    var project_dir_it = try project_dir.walk(alloc);
    defer project_dir_it.deinit();

    var db_builder = DbBuilder {
        .alloc = alloc,
        .config = &config.value,
        .file_parser = &file_parser,
        .abs_project_dir = abs_project_dir,
        .reference_retriever = &retriever,
        .db = &db,
    };
    defer db_builder.deinit();

    try db_builder.populateDbNodes();
    try db_builder.populateReferences();

    const db_json = try std.fs.cwd().createFile("db.json", .{});
    defer db_json.close();

    const savedata = try db.save(alloc);
    defer alloc.free(savedata);

    try std.json.stringify(savedata, .{ .whitespace = .indent_2 }, db_json.writer());
}
