const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("Db.zig");

const VimMessage = struct {
    name: []const u8,
    line: u32,
    col: u32,
};

fn openDb(alloc: Allocator, path: []const u8) !Db {
    const db_parsed = blk: {
        const saved_db_f = try std.fs.cwd().openFile(path, .{});
        defer saved_db_f.close();

        var json_reader = std.json.reader(alloc, saved_db_f.reader());
        defer json_reader.deinit();

        break :blk try std.json.parseFromTokenSource(Db.SaveData, alloc, &json_reader, .{});
    };
    defer db_parsed.deinit();

    return try Db.load(alloc, db_parsed.value);
}

const Args = struct {
    db_path: []const u8,
    root: []const u8,
    output_path: []const u8,
    it: std.process.ArgIterator,

    fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        errdefer it.deinit();

        const process_name = it.next() orelse "server";

        const db_path = it.next() orelse {
            std.log.err("db_path not provided", .{});
            help(process_name);
        };

        const root = it.next() orelse {
            std.log.err("scan_dir not provided", .{});
            help(process_name);
        };

        const output_path = it.next() orelse {
            std.log.err("output_path not provided", .{});
            help(process_name);
        };

        return .{
            .db_path = db_path,
            .root = root,
            .output_path = output_path,
            .it = it,
        };
    }

    fn deinit(self: *Args) void {
        self.it.deinit();
    }

    fn help(process_name: []const u8) noreturn {
        const stderr = std.io.getStdErr().writer();
        stderr.print("USAGE: {s} <db_path> <scan_root> <output_path>\n", .{process_name}) catch {};
        std.process.exit(1);
    }
};

const LocHistory = struct {
    const max_samples: usize = 5;

    alloc: Allocator,

    // FIXME: StackArrayList or CircularBuffer
    // 0, 1, 2, 3, 4, 5
    // [3, 6]
    samples: std.ArrayListUnmanaged(usize) = .{},
    samples_start: usize = 0,
    // FIXME: Circular buffer
    sample_storage: std.ArrayListUnmanaged(Db.NodeId) = .{},

    const Sample = []Db.NodeId;

    pub fn init(alloc: Allocator) LocHistory {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *LocHistory) void {
        self.samples.deinit(self.alloc);
        self.sample_storage.deinit(self.alloc);
    }

    pub fn pushNode(self: *LocHistory, id: Db.NodeId) !void {
        try self.sample_storage.append(self.alloc, id);
    }

    pub fn endSample(self: *LocHistory) !void {
        try self.samples.append(self.alloc, self.samples_start + self.sample_storage.items.len);

        if (self.samples.items.len > max_samples) {
            const new_samples_start = self.samples.orderedRemove(0);

            const storage_remove = new_samples_start - self.samples_start;
            std.mem.copyForwards(Db.NodeId, self.sample_storage.items[0..], self.sample_storage.items[storage_remove..]);
            try self.sample_storage.resize(self.alloc, self.sample_storage.items.len - storage_remove);
            self.samples_start = new_samples_start;
        }
    }

    const SampleIt = struct {
        history: *const LocHistory,
        idx: usize = 0,
        start_idx: usize,

        pub fn next(self: *SampleIt) ?[]const Db.NodeId {
            if (self.idx >= self.history.samples.items.len) return null;
            defer self.idx += 1;

            const end_idx = self.history.samples.items[self.idx];
            defer self.start_idx = end_idx;

            return self.history.sample_storage.items[self.start_idx - self.history.samples_start .. end_idx - self.history.samples_start];
        }
    };

    pub fn sampleIt(self: *const LocHistory) SampleIt {
        return .{
            .history = self,
            .start_idx = self.samples_start,
        };
    }

    pub fn writeHistory(self: LocHistory, path: []const u8) !void {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();

        var json_writer = std.json.writeStream(f.writer(), .{});
        defer json_writer.deinit();

        try json_writer.beginArray();

        var sample_it = self.sampleIt();
        while (sample_it.next()) |samples| {
            try json_writer.beginArray();
            for (samples) |sample| {
                try json_writer.write(sample.value);
            }
            try json_writer.endArray();
        }

        try json_writer.endArray();
    }
};

const MessageType = enum(u16) {
    file_data = 0,
    file_end = 1,
    file_patch = 2,
    cursor_update = 3,
};

const Server = struct {
    history: LocHistory,
    socket_server: std.net.Server,

    pub fn init(alloc: Allocator) !Server {
        var history = LocHistory.init(alloc);
        errdefer history.deinit();

        const addy = try std.net.Address.initUnix("test.sock");
        var socket_server = try addy.listen(.{});
        errdefer socket_server.deinit();

        return .{
            .history = history,
            .socket_server = socket_server,
        };
    }

    pub fn deinit(self: *Server) void {
        self.history.deinit();
        self.socket_server.deinit();
    }

    fn run(self: *Server, alloc: Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);

        while (true) {
            _ = arena.reset(.retain_capacity);
            var conn = try self.socket_server.accept();
            defer conn.stream.close();

            try self.runConn(arena.allocator(), conn);
        }
    }

    fn runConn(self: *Server, tmp_alloc: Allocator, conn: std.net.Server.Connection) !void {
        var incoming_file = std.ArrayList(u8).init(tmp_alloc);
        defer incoming_file.deinit();

        while (true) {
            const reader = conn.stream.reader();

            const message_type = try reader.readInt(u16, .little);
            const parsed_message_type = std.meta.intToEnum(MessageType, message_type) catch {
                std.log.err("Invalid message type {d}", .{message_type});
                return;
            };
            std.debug.print("message type: {s}\n", .{@tagName(parsed_message_type)});

            const message_len = try reader.readInt(u32, .little);
            std.debug.print("message len {d}\n", .{message_len});

            const msg = try tmp_alloc.alloc(u8, message_len);
            _ = try reader.readAll(msg);
            std.debug.print("message content {d}\n", .{msg});

            switch (parsed_message_type) {
                .file_data => {
                    std.debug.print("Got file chunk: {d}\n", .{msg.len});
                    try incoming_file.appendSlice(msg);
                },
                .file_end => {
                    try incoming_file.appendSlice(msg);
                    std.debug.print("Got file: {s}\n", .{incoming_file.items});
                    incoming_file.clearAndFree();
                },
                .file_patch => {
                    var fb = std.io.fixedBufferStream(msg);
                    var msg_reader = fb.reader();
                    const first = try msg_reader.readInt(u32, .little);
                    const last = try msg_reader.readInt(u32, .little);
                    std.debug.print("Editing range: {d}-{d}", .{ first, last });
                    const num_lines = try msg_reader.readInt(u32, .little);
                    for (0..num_lines) |_| {
                        const line_len = try msg_reader.readInt(u32, .little);

                        const line = try tmp_alloc.alloc(u8, line_len);
                        defer tmp_alloc.free(line);

                        _ = try msg_reader.readAll(line);
                        std.debug.print("got line: {s}\n", .{line});
                    }
                },
                .cursor_update => self.handleCursorUpdate(msg),
            }
        }
    }

    fn handleCursorUpdate(self: *Server, msg: []const u8) void {
        _ = self;
        _ = msg;
        //// FIXME: Should not crash on json parse failure
        //const message = try std.json.parseFromSliceLeaky(VimMessage, arena.allocator(), buf.items, .{});
        //std.debug.print("got message: {any}\n", .{message});

        //if (message.name.len < args.root.len + 1) continue;

        //if (!std.mem.startsWith(u8, message.name, args.root)) {
        //    continue;
        //}
        //const rel_path = message.name[args.root.len..];
        //if (message.line == 0) {
        //    std.log.err("Line was not 1 indexed",.{});
        //    continue;
        //}

        //var node_it = db.nodesContainingLoc(rel_path, .{ .line = message.line - 1, .col = message.col} );
        //while (node_it.next()) |id| {
        //    try history.pushNode(id);
        //    const node = db.getNode(id);
        //    std.debug.print("Spending time in {s}\n", .{node.name});
        //}
        //try history.endSample();

        //var sample_it = history.sampleIt();
        //std.debug.print("Current history\n", .{});
        //while (sample_it.next()) |samples| {
        //    std.debug.print("samples: {any}\n", .{samples});
        //}

        //try history.writeHistory(args.output_path);

    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit();

    var db = try openDb(alloc, args.db_path);
    defer db.deinit(alloc);

    var server = try Server.init(alloc);
    defer server.deinit();

    try server.run(alloc);
}
