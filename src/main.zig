const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = @import("meta.zig");
const PatchStruct = meta.PatchStruct;
const lsp = @import("lsp.zig");

fn sendMessage(alloc: Allocator, msg: anytype, writer: anytype) !void {
    const msg_serialized = try std.json.stringifyAlloc(alloc, msg, .{});
    defer alloc.free(msg_serialized);

    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ msg_serialized.len, msg_serialized });
}

const IdAllocator = struct {
    id: i32 = 1,

    fn next(self: *IdAllocator) i32 {
        defer self.id +%= 1;
        return self.id;
    }
};

const LspReferenceRetreiver = struct {
    process: std.process.Child,
    id_allocator: IdAllocator,
    language_id: []const u8,

    pub fn init(alloc: Allocator, argv: []const []const u8, cwd: []const u8, language_id: []const u8) !LspReferenceRetreiver {
        var process = std.process.Child.init(argv, alloc);
        process.cwd = cwd;
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;

        var id_allocator = IdAllocator{};

        try process.spawn();
        errdefer {
            _ = process.kill() catch {};
            _ = process.wait() catch {};
        }

        try sendMessage(alloc, lsp.InitializeMessage{
            .id = id_allocator.next(),
            .params = .{},
        }, process.stdin.?.writer());

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        const arena_alloc = arena.allocator();
        _ = try waitResponseLeaky(lsp.ResponseMessage, arena_alloc, process.stdout.?);

        try sendMessage(alloc, lsp.InitializedNotification{
            .method = "initialized",
            .params = .{},
        }, process.stdin.?.writer());

        return .{
            .process = process,
            .id_allocator = id_allocator,
            .language_id = language_id,
        };
    }

    pub fn deinit(self: *LspReferenceRetreiver) void {
        _ = self.process.kill() catch return;
        _ = self.process.wait() catch return;
    }

    pub fn findReferencesLeaky(
        self: *LspReferenceRetreiver,
        alloc: Allocator,
        abs_path: []const u8,
        line: u32,
        col: u32,
    ) ![]lsp.Location {
        const uri = try std.fmt.allocPrint(alloc, "file://{s}", .{abs_path});
        defer alloc.free(uri);

        const writer = self.process.stdin.?.writer();

        {
            const f = try std.fs.openFileAbsolute(abs_path, .{});
            defer f.close();

            const content = try f.readToEndAlloc(alloc, 1 << 20);
            defer alloc.free(content);

            const start = try std.time.Instant.now();
            try sendMessage(alloc, lsp.DidOpenNotification{
                .params = .{
                    .textDocument = .{
                        .uri = uri,
                        .languageId = self.language_id,
                        .version = 1,
                        .text = content,
                    },
                },
            }, writer);
            const end = try std.time.Instant.now();
            std.debug.print("did open: {d}ms\n", .{end.since(start) / std.time.ns_per_ms});
        }

        const start = try std.time.Instant.now();
        const id = self.id_allocator.next();
        try sendMessage(alloc, lsp.FindReferences{
            .id = id,
            .params = .{
                .textDocument = .{
                    .uri = uri,
                },
                .position = .{
                    .line = line,
                    .character = col,
                },
                .context = .{
                    .includeDeclaration = false,
                },
            },
        }, writer);

        const response = try waitResponseLeaky(lsp.FindReferencesResponse, alloc, self.process.stdout.?);

        const end = try std.time.Instant.now();
        std.debug.print("find references: {d}ms\n", .{end.since(start) / std.time.ns_per_ms});
        return response.result orelse return error.NoReferences;
    }

    fn waitResponseLeaky(comptime Response: type, alloc: Allocator, rx: std.fs.File) !Response {
        var read_len: usize = 0;
        const rx_buf = try alloc.alloc(u8, 1 << 20);
        while (read_len == 0) {
            read_len = try rx.read(rx_buf);
            // FIXME: poll
            std.time.sleep(50 * std.time.ns_per_ms);
        }

        const message = rx_buf[0..read_len];
        // FIXME: Multiple messages will break this
        const header_end = std.mem.indexOf(u8, message, "\r\n\r\n") orelse return error.NoHeaderEnd;
        const json_start = header_end + 4;

        return try std.json.parseFromSliceLeaky(Response, alloc, message[json_start..], .{ .ignore_unknown_fields = true });
    }
};

const Config = struct {
    project_root: []const u8,
    language_server: []const []const u8,
    language_id: []const u8,
};

const Args = struct {
    config: []const u8,
    file: []const u8,
    line: u32,
    col: u32,
    it: std.process.ArgIterator,

    fn deinit(self: *Args) void {
        self.it.deinit();
    }

    fn parse(alloc: Allocator) Args {
        var it = try std.process.argsWithAllocator(alloc);

        const process_name = it.next() orelse "code-map";

        const config = nextArg(&it, "config", process_name);
        const file = nextArg(&it, "file", process_name);

        const line_s = nextArg(&it, "line", process_name);
        const line = parseInt(u32, line_s, "line", process_name);

        const col_s = nextArg(&it, "col", process_name);
        const col = parseInt(u32, col_s, "col", process_name);

        return .{
            .config = config,
            .file = file,
            .line = line,
            .col = col,
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
            \\USAGE: {s} <config> <file> <line> <col>
            \\
            \\Print references at file/line/col using config
        , .{program_name}) catch {};

        std.process.exit(1);
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

    const abs_project_dir = try std.fs.cwd().realpathAlloc(alloc, config.value.project_root);
    defer alloc.free(abs_project_dir);

    var retriever = try LspReferenceRetreiver.init(alloc, config.value.language_server, abs_project_dir, config.value.language_id);
    defer retriever.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const abs_file = try std.fs.cwd().realpathAlloc(alloc, args.file);
    defer alloc.free(abs_file);

    for (0..3) |_| {
        const references = try retriever.findReferencesLeaky(arena.allocator(), abs_file, args.line, args.col);
        for (references) |loc| {
            std.debug.print("ref: {s} ({d}, {d})\n", .{ loc.uri, loc.range.start.line, loc.range.start.character });
        }
        _ = arena.reset(.retain_capacity);
    }
}
