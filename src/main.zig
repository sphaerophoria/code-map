const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp.zig");
const treesitter = @import("treesitter.zig");
const Db = @import("Db.zig");
const Config = @import("Config.zig");
const DbBuilder = @import("DbBuilder.zig");

pub const std_options = std.Options{
    .log_level = .info,
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

const RecordingOption = union(enum) {
    replay: []const u8,
    record: []const u8,
    none,
};

fn makeProcessRetriever(
    alloc: Allocator,
    config: Config,
    abs_project_dir: []const u8,
    recording: RecordingOption,
) !lsp.ReferenceRetriever {
    if (recording == .replay) {
        return try lsp.ReferenceRetriever.initRecording(recording.replay);
    }

    const recording_dir = if (recording == .record)
        try lsp.Recorder.init(recording.record)
    else
        null;

    const argv = try alloc.dupe([]const u8, config.language_server);
    defer alloc.free(argv);

    var argv0: ?[]const u8 = null;

    defer if (argv0) |v| {
        alloc.free(v);
    };

    if (std.fs.cwd().statFile(argv[0])) |metadata| {
        if (metadata.kind == .file) {
            const cwd = try std.process.getCwdAlloc(alloc);
            defer alloc.free(cwd);

            const abs_path = try std.fs.path.join(alloc, &.{ cwd, config.language_server[0] });

            argv0 = abs_path;
            argv[0] = abs_path;
        }
    } else |_| {}

    return try lsp.ReferenceRetriever.init(
        alloc,
        argv,
        abs_project_dir,
        config.language_id,
        config.language_server_progress_token,
        recording_dir,
    );
}

pub fn makeFileParser(config: *const Config) !treesitter.FileParser {
    return try treesitter.FileParser.init(
        config.treesitter_so,
        config.treesitter_init,
        &config.treesitter_ruleset,
    );
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

    const abs_project_dir = try std.fs.cwd().realpathAlloc(alloc, args.project_root);
    defer alloc.free(abs_project_dir);

    var file_parser = try makeFileParser(&config.value);
    defer file_parser.deinit();

    const recording_option: RecordingOption = if (args.replay_dir) |d|
        .{ .replay = d }
    else if (args.recording_dir) |d|
        .{ .record = d }
    else
        .none;

    var retriever = try makeProcessRetriever(alloc, config.value, abs_project_dir, recording_option);
    defer retriever.deinit();

    var db = Db{};
    defer db.deinit(alloc);

    var db_builder = DbBuilder{
        .alloc = alloc,
        .blacklist_paths = config.value.blacklist_paths,
        .matched_extension = config.value.matched_extension,
        .file_parser = &file_parser,
        .abs_project_dir = abs_project_dir,
        .reference_retriever = &retriever,
        .db = &db,
    };
    defer db_builder.deinit();

    const pop_source = DbBuilder.FsPopulatorSource{ .abs_project_dir = abs_project_dir };

    try db_builder.populateDbNodes(pop_source);

    const stdout = std.io.getStdOut().writer();

    var reference_populator = try db_builder.referencePopulator(pop_source);
    try stdout.writeAll("Waiting for language server to be ready...\n");
    _ = try reference_populator.step();

    try stdout.writeAll("Populating references\n");
    var i: usize = 0;
    const num_nodes = db.nodes.items.len;
    while (try reference_populator.step()) {
        i += 1;
        try stdout.print("\r{d}/{d}", .{ i, num_nodes });
    }
    try stdout.print("\n", .{});

    const db_json = try std.fs.cwd().createFile("db.json", .{});
    defer db_json.close();

    const savedata = try db.save(alloc);
    defer alloc.free(savedata);

    try std.json.stringify(savedata, .{ .whitespace = .indent_2 }, db_json.writer());
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
