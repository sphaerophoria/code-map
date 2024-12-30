const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp.zig");
const coords = @import("coords.zig");
const treesitter = @import("treesitter.zig");
const Db = @import("Db.zig");

const TextRange = coords.TextRange;
const TextPosition = coords.TextPosition;

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
                std.debug.print("skipping path: {s}\n", .{ref.uri});
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

fn addFileToDb(alloc: Allocator, file_parser: *treesitter.FileParser, file_parent_id: Db.NodeId, abs_file: []const u8, abs_project_dir: []const u8, db: *Db) !void {
    var file_it = try file_parser.parseFile(alloc, abs_file);
    defer file_it.deinit(alloc);

    const rel_file = abs_file[abs_project_dir.len + 1 ..];

    while (try file_it.next(alloc)) |item| {
        defer item.deinit(alloc);

        var path_name = std.ArrayList(u8).init(alloc);
        defer path_name.deinit();
        try path_name.appendSlice(db.getNode(file_parent_id).name);
        try path_name.append('.');

        // FIXME: Iterate dir as well
        if (item.path.len > 0) {
            try path_name.appendSlice(item.path[0]);
            for (1..item.path.len) |i| {
                try path_name.append('.');
                try path_name.appendSlice(item.path[i]);
            }
        }

        var parent_path_name = std.ArrayList(u8).init(alloc);
        defer parent_path_name.deinit();
        try parent_path_name.appendSlice(db.getNode(file_parent_id).name);
        try parent_path_name.append('.');
        if (item.path.len > 1) {
            // FIXME: duped with above path_name
            try parent_path_name.appendSlice(item.path[0]);
            for (1..item.path.len - 1) |i| {
                try parent_path_name.append('.');
                try parent_path_name.appendSlice(item.path[i]);
            }
        }

        const parent_id = if (item.path.len <= 1) Db.NodeQuery{ .id = file_parent_id } else Db.NodeQuery{ .name = parent_path_name.items };

        _ = try db.addNode(alloc, rel_file, path_name.items, parent_id, item.ident_range, item.range);
    }
}

fn pathToName(path: []const u8, buf: []u8) []const u8 {
    @memcpy(buf[0..path.len], path);
    const ret = buf[0..path.len];

    std.mem.replaceScalar(u8, buf, std.fs.path.sep, '.');
    return ret;
}

const DbPathComponentIt = struct {
    path: []const u8,
    idx: usize = 0,
    buf: [std.fs.max_path_bytes]u8 = undefined,

    const Output = struct {
        // a/b/c
        full: []const u8,
        name: []const u8,
    };

    // a
    // a/b + "a" "b"
    // a/b/c + ["a.b.c"]
    fn next(self: *DbPathComponentIt) ?Output {
        if (self.path.len <= self.idx) {
            return null;
        }

        const idx_increment = std.mem.indexOfScalar(u8, self.path[self.idx..], std.fs.path.sep) orelse self.path.len - self.idx;
        self.idx += idx_increment;
        // consume the /
        defer self.idx += 1;

        const this_path = self.path[0..self.idx];

        const name = pathToName(this_path, &self.buf);

        return .{
            .full = this_path,
            .name = name,
        };
    }
};

test "DbPathComponentIt" {
    var it = DbPathComponentIt{ .path = "a/b/c" };

    {
        const component = it.next() orelse return error.NoCompoenent;
        try std.testing.expectEqualStrings("a", component.name);
        try std.testing.expectEqualStrings("a", component.full);
    }
    {
        const component = it.next() orelse return error.NoCompoenent;
        try std.testing.expectEqualStrings("a/b", component.full);
        try std.testing.expectEqualStrings("a.b", component.name);
    }
    {
        const component = it.next() orelse return error.NoCompoenent;
        try std.testing.expectEqualStrings("a/b/c", component.full);
        try std.testing.expectEqualStrings("a.b.c", component.name);
    }

    try std.testing.expectEqual(null, it.next());
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

// Add all nodes that we care about to the database (ignoring references, those
// require all nodes to exist before populating)
fn populateDbNodes(alloc: Allocator, config: Config, abs_project_dir: []const u8, db: *Db, files: *std.ArrayList([]const u8), file_parser: *treesitter.FileParser) !void {
    const project_dir = try std.fs.cwd().openDir(abs_project_dir, .{ .iterate = true });

    var project_dir_it = try project_dir.walk(alloc);
    defer project_dir_it.deinit();

    var db_added_paths = std.BufSet.init(alloc);
    defer db_added_paths.deinit();

    // a/b/c.zig
    //
    // a
    // b -> parent a
    // c.zig -> parent b
    //
    // fn doThing() -> c.zig
    //
    while (try project_dir_it.next()) |entry| {
        if (isBlacklisted(entry.path, config.blacklist_paths)) {
            continue;
        }
        var component_it = DbPathComponentIt{ .path = entry.path };
        while (component_it.next()) |res| {
            if (!db_added_paths.contains(res.full)) {
                // UiAction init()
                //
                // UiAciton.init()
                //
                // "a" "b" "c"
                // a.b.c
                try db_added_paths.insert(res.full);
                const parent = std.fs.path.dirname(res.full) orelse "";
                _ = try db.addFsNode(alloc, res.full, res.name, parent);
            }
        }

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const file_node_name = pathToName(entry.path, &buf);
        const file_id = db.findNodeId(.{ .name = file_node_name }) orelse unreachable;
        if (std.mem.endsWith(u8, entry.path, config.matched_extension)) {
            const abs_file = blk: {
                std.debug.print("Found path {s}\n", .{entry.path});
                const abs_file = try project_dir.realpathAlloc(alloc, entry.path);
                errdefer alloc.free(abs_file);

                try files.append(abs_file);
                break :blk abs_file;
            };

            try addFileToDb(alloc, file_parser, file_id, abs_file, abs_project_dir, db);
        }
    }
}

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
    //if (true) return error.UhOh;

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

    // FIXME: Should be part of DB probably
    var files = std.ArrayList([]const u8).init(alloc);
    defer {
        for (files.items) |item| {
            alloc.free(item);
        }
        files.deinit();
    }

    const project_dir = try std.fs.cwd().openDir(args.project_root, .{ .iterate = true });

    var project_dir_it = try project_dir.walk(alloc);
    defer project_dir_it.deinit();

    // a/b/c.zig
    //
    // a
    // b -> parent a
    // c.zig -> parent b
    //
    // fn doThing() -> c.zig
    //
    try populateDbNodes(alloc, config.value, abs_project_dir, &db, &files, &file_parser);

    var node_it = db.idIter();
    while (node_it.next()) |node_id| {
        const node = db.getNode(node_id);
        std.debug.print("{s}\n", .{node.name});
    }
    for (files.items) |file| {
        std.debug.print("Opening {s}\n", .{file});
        try retriever.openFile(alloc, file);
    }

    node_it = db.idIter();
    while (node_it.next()) |id| {
        const node = db.getNodePtr(id);

        if (node.data != .within_file) continue;

        const node_data = node.data.within_file;

        const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ abs_project_dir, node_data.path });
        defer alloc.free(full_path);

        var references = try retriever.findReferences(alloc, full_path, node_data.ident_range.start.line, node_data.ident_range.start.col);
        defer references.deinit();

        std.debug.print("references to {s} ({d}, {d}) -> ({d}, {d})\n", .{ full_path, node_data.range.start.line, node_data.range.start.col, node_data.range.end.line, node_data.range.end.col });

        try addReferencesToDb(alloc, abs_project_dir, id, &references, &db);

        const db_json = try std.fs.cwd().createFile("db.json", .{});
        defer db_json.close();

        const savedata = try db.save(alloc);
        defer alloc.free(savedata);

        try std.json.stringify(savedata, .{ .whitespace = .indent_2 }, db_json.writer());
        //logAllReferences(db);
    }
}
