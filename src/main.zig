const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp.zig");
const coords = @import("coords.zig");
const treesitter = @import("treesitter.zig");
const Db = @import("Db.zig");
const Config = @import("Config.zig");
const DbBuilder = @import("DbBuilder.zig");

const TextRange = coords.TextRange;
const TextPosition = coords.TextPosition;

pub const std_options = std.Options {
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

fn makeProcessRetriever(alloc: Allocator, config: Config, abs_project_dir: []const u8, recording_dir: ?[]const u8) !lsp.ReferenceRetriever {
    var recorder: ?lsp.Recorder = null;
    if (recording_dir) |d| {
        recorder = try lsp.Recorder.init(d);
    }

    return try lsp.ReferenceRetriever.init(alloc, config.language_server, abs_project_dir, config.language_id, recorder);
}


pub fn makeFileParser(config: Config) !treesitter.FileParser {
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

    var file_parser = try makeFileParser(config.value);
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
        .blacklist_paths = config.value.blacklist_paths,
        .matched_extension = config.value.matched_extension,
        .file_parser = &file_parser,
        .abs_project_dir = abs_project_dir,
        .reference_retriever = &retriever,
        .db = &db,
    };
    defer db_builder.deinit();

    var pop_source = try DbBuilder.FsPopulatorSource.init(alloc, abs_project_dir);
    defer pop_source.deinit(alloc);

    try db_builder.populateDbNodes(&pop_source);
    try db_builder.populateReferences();

    const db_json = try std.fs.cwd().createFile("db.json", .{});
    defer db_json.close();

    const savedata = try db.save(alloc);
    defer alloc.free(savedata);

    try std.json.stringify(savedata, .{ .whitespace = .indent_2 }, db_json.writer());
}
