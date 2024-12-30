const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("lsp/types.zig");
const coords = @import("coords.zig");
const TextPosition = coords.TextPosition;
const TextRange = coords.TextRange;

fn getRecordedPath(alloc: Allocator, msg: anytype) ![64]u8 {
    const Hasher = std.crypto.hash.sha2.Sha256;

    var msg2 = msg;
    if (@hasField(@TypeOf(msg), "id")) {
        msg2.id = 0;
    }

    const msg_serialized = try std.json.stringifyAlloc(alloc, msg2, .{});
    defer alloc.free(msg_serialized);

    std.debug.print("serialized msg: {s}\n", .{msg_serialized});

    var hashed: [32]u8 = undefined;
    Hasher.hash(msg_serialized, &hashed, .{});
    const hex = std.fmt.bytesToHex(hashed, .lower);
    std.debug.print("Hash: {s}\n", .{hex});
    return hex;
}

fn sendMessage(alloc: Allocator, msg: anytype, writer: anytype) !void {
    const msg_serialized = try std.json.stringifyAlloc(alloc, msg, .{});
    defer alloc.free(msg_serialized);

    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ msg_serialized.len, msg_serialized });
}

pub const Recorder = struct {
    recording_dir: std.fs.Dir,

    pub fn init(recording_path: []const u8) !Recorder {
        const recording_dir = try std.fs.cwd().makeOpenPath(recording_path, .{});

        return .{
            .recording_dir = recording_dir,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.recording_dir.close();
    }

    pub fn openReqRecording(self: Recorder, alloc: Allocator, req: anytype) !std.fs.File {
        const file_name = try getRecordedPath(alloc, req);

        const f = try self.recording_dir.createFile(&file_name, .{
            .exclusive = true,
        });
        return f;
    }
};

// LSP messages need an ID, just keep adding 1
const LspIdAllocator = struct {
    id: i32 = 1,

    fn next(self: *LspIdAllocator) i32 {
        defer self.id +%= 1;
        return self.id;
    }
};

pub const ReferenceRetriever = struct {
    backend: union(enum) {
        process: ReferenceRetrieverProcessBackend,
        recording: ReferenceRetrieverRecordingBackend,
    },
    id_allocator: LspIdAllocator,
    recorder: ?Recorder,

    pub fn init(alloc: Allocator, argv: []const []const u8, cwd: []const u8, language_id: []const u8, recorder: ?Recorder) !ReferenceRetriever {
        var id_allocator = LspIdAllocator{};
        const backend = try ReferenceRetrieverProcessBackend.init(alloc, argv, cwd, language_id, &id_allocator);

        return .{
            .backend = .{
                .process = backend,
            },
            .recorder = recorder,
            .id_allocator = id_allocator,
        };
    }

    pub fn initRecording(recording_path: []const u8) !ReferenceRetriever {
        const id_allocator = LspIdAllocator{};
        const backend = try ReferenceRetrieverRecordingBackend.init(recording_path);

        return .{
            .backend = .{
                .recording = backend,
            },
            .recorder = null,
            .id_allocator = id_allocator,
        };
    }

    pub fn deinit(self: *ReferenceRetriever) void {
        switch (self.backend) {
            .process => |*p| p.deinit(),
            .recording => |*r| r.deinit(),
        }

        if (self.recorder) |*r| r.deinit();
    }

    // Helper type to avoid leaking details about the json parsing to the caller of findReferences()
    pub const ReferenceIt = struct {
        parsed: std.json.Parsed(types.FindReferencesResponse),
        idx: usize = 0,

        pub fn deinit(self: *ReferenceIt) void {
            self.parsed.deinit();
        }

        pub const Output = struct {
            uri: []const u8,
            range: TextRange,
        };

        pub fn reset(self: *ReferenceIt) void {
            self.idx = 0;
        }

        pub fn next(self: *ReferenceIt) ?Output {
            const result = self.parsed.value.result orelse return null;

            if (self.idx >= result.len) {
                return null;
            }

            defer self.idx += 1;
            const out = result[self.idx];
            return .{ .uri = out.uri, .range = .{
                .start = .{
                    .line = out.range.start.line,
                    .col = out.range.start.character,
                },
                .end = .{
                    .line = out.range.end.line,
                    .col = out.range.end.character,
                },
            } };
        }
    };

    pub fn findReferences(
        self: *ReferenceRetriever,
        alloc: Allocator,
        abs_path: []const u8,
        line: u32,
        col: u32,
    ) !ReferenceIt {
        const uri = try std.fmt.allocPrint(alloc, "file://{s}", .{abs_path});
        defer alloc.free(uri);

        const id = self.id_allocator.next();
        const msg = types.FindReferences{
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
        };

        const parsed = switch (self.backend) {
            .process => |*p| try p.findReferences(alloc, msg),
            .recording => |*r| try r.findReferences(alloc, msg),
        };

        // FIXME: Call all be folded into one function
        const recording_handle = try self.createRecordingHandle(alloc, msg);
        defer closeRecordingHandle(recording_handle);
        if (recording_handle) |h| {
            try std.json.stringify(parsed.value, .{ .whitespace = .indent_2 }, h.writer());
        }

        return .{
            .parsed = parsed,
        };
    }

    fn createRecordingHandle(self: ReferenceRetriever, alloc: Allocator, msg: anytype) !?std.fs.File {
        const r = self.recorder orelse return null;
        return try r.openReqRecording(alloc, msg);
    }

    fn closeRecordingHandle(file: ?std.fs.File) void {
        if (file) |f| f.close();
    }

    pub fn openFile(self: *ReferenceRetriever, alloc: Allocator, abs_path: []const u8) !void {
        switch (self.backend) {
            .process => |*p| try p.openFile(alloc, abs_path),
            .recording => {},
        }
    }
};

// Manage an LSP process and provide an abstraction to ask it stuff
pub const ReferenceRetrieverProcessBackend = struct {
    process: std.process.Child,
    language_id: []const u8,

    pub fn init(alloc: Allocator, argv: []const []const u8, cwd: []const u8, language_id: []const u8, id_allocator: *LspIdAllocator) !ReferenceRetrieverProcessBackend {
        var process = std.process.Child.init(argv, alloc);
        process.cwd = cwd;
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Ignore;

        try process.spawn();
        errdefer {
            _ = process.kill() catch {};
            _ = process.wait() catch {};
        }

        try sendMessage(alloc, types.InitializeMessage{
            .id = id_allocator.next(),
            .params = .{},
        }, process.stdin.?.writer());

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        const arena_alloc = arena.allocator();
        var resp = try waitResponse(types.ResponseMessage, arena_alloc, process.stdout.?);
        resp.deinit();

        try sendMessage(alloc, types.InitializedNotification{
            .method = "initialized",
            .params = .{},
        }, process.stdin.?.writer());

        return .{
            .process = process,
            .language_id = language_id,
        };
    }

    pub fn deinit(self: *ReferenceRetrieverProcessBackend) void {
        _ = self.process.kill() catch return;
        _ = self.process.wait() catch return;
    }

    pub fn findReferences(
        self: *ReferenceRetrieverProcessBackend,
        alloc: Allocator,
        msg: types.FindReferences,
    ) !std.json.Parsed(types.FindReferencesResponse) {
        const writer = self.process.stdin.?.writer();

        try sendMessage(alloc, msg, writer);
        return try waitResponse(types.FindReferencesResponse, alloc, self.process.stdout.?);
    }

    pub fn openFile(self: *ReferenceRetrieverProcessBackend, alloc: Allocator, abs_path: []const u8) !void {
        const uri = try std.fmt.allocPrint(alloc, "file://{s}", .{abs_path});
        defer alloc.free(uri);

        const f = try std.fs.openFileAbsolute(abs_path, .{});
        defer f.close();

        const content = try f.readToEndAlloc(alloc, 1 << 20);
        defer alloc.free(content);

        try sendMessage(alloc, types.DidOpenNotification{
            .params = .{
                .textDocument = .{
                    .uri = uri,
                    .languageId = self.language_id,
                    .version = 1,
                    .text = content,
                },
            },
        }, self.process.stdin.?.writer());
    }

    fn waitResponse(comptime Response: type, alloc: Allocator, rx: std.fs.File) !std.json.Parsed(Response) {
        var splitter = LspMessageSplitter.init(alloc);
        defer splitter.deinit();

        // FIXME: Maybe we don't alloc this over and over...
        const rx_buf = try alloc.alloc(u8, 1 << 20);
        defer alloc.free(rx_buf);

        const msg = blk: while (true) {
            var read_len: usize = 0;

            while (read_len == 0) {
                read_len = try rx.read(rx_buf);
                // FIXME: poll
                std.time.sleep(50 * std.time.ns_per_ms);
            }

            try splitter.push(rx_buf[0..read_len]);
            if (try splitter.next(alloc)) |msg| {
                break :blk msg;
            }
        };
        defer alloc.free(msg);

        var json_io_reader = std.io.fixedBufferStream(msg);

        var json_reader = std.json.reader(alloc, json_io_reader.reader());
        defer json_reader.deinit();

        var diagnostics = std.json.Diagnostics{};
        json_reader.enableDiagnostics(&diagnostics);
        return std.json.parseFromTokenSource(Response, alloc, &json_reader, .{ .ignore_unknown_fields = true }) catch |e| {
            @breakpoint();
            std.log.err("Json parsing failed at byte offs {d}", .{diagnostics.getByteOffset()});
            return e;
        };
    }
};
pub const ReferenceRetrieverRecordingBackend = struct {
    recording_dir: std.fs.Dir,

    pub fn init(recording_path: []const u8) !ReferenceRetrieverRecordingBackend {
        return .{
            .recording_dir = try std.fs.cwd().openDir(recording_path, .{}),
        };
    }

    pub fn deinit(self: *ReferenceRetrieverRecordingBackend) void {
        self.recording_dir.close();
    }

    pub fn findReferences(
        self: *ReferenceRetrieverRecordingBackend,
        alloc: Allocator,
        msg: types.FindReferences,
    ) !std.json.Parsed(types.FindReferencesResponse) {
        const recorded_path = try getRecordedPath(alloc, msg);
        const f = try self.recording_dir.openFile(&recorded_path, .{});

        var json_reader = std.json.reader(alloc, f.reader());
        defer json_reader.deinit();

        return try std.json.parseFromTokenSource(types.FindReferencesResponse, alloc, &json_reader, .{});
    }

    pub fn openFile(_: *ReferenceRetrieverRecordingBackend, _: Allocator, _: []const u8) !void {}
};

const LspHeaderParser = struct {
    data: []const u8,
    idx: usize,

    pub fn init(data: []const u8) LspHeaderParser {
        return .{
            .data = data,
            .idx = 0,
        };
    }

    pub const Output = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn next(self: *LspHeaderParser) !?Output {
        // key: value\r\n
        // key2: value2\r\n
        // \r\n

        if (std.mem.eql(u8, self.data[self.idx..], "\r\n")) {
            return null;
        }

        const key_advance = std.mem.indexOfScalar(u8, self.data[self.idx..], ':') orelse return error.NoKeyEnd;
        const key_end = self.idx + key_advance;

        const value_start_advance = std.mem.indexOfNone(u8, self.data[key_end + 1 ..], &std.ascii.whitespace) orelse return error.NoValueStart;
        const value_start = key_end + 1 + value_start_advance;
        const value_end_advance = std.mem.indexOf(u8, self.data[value_start..], "\r\n") orelse return error.NoValueEnd;
        const value_end = value_start + value_end_advance;

        defer self.idx = value_end + 2;

        const key = self.data[self.idx..key_end];
        const value = self.data[value_start..value_end];

        return .{
            .key = key,
            .value = value,
        };
    }
};

test "simple header parsing" {
    const data =
        "Content-Length: 100\r\n" ++
        "Something-Else: hello\r\n" ++
        "\r\n";

    var it = LspHeaderParser.init(data);

    {
        const val = try it.next() orelse return error.EndsEarly;
        try std.testing.expectEqualSlices(u8, "Content-Length", val.key);
        try std.testing.expectEqualSlices(u8, "100", val.value);
    }

    {
        const val = try it.next() orelse return error.EndsEarly;
        try std.testing.expectEqualSlices(u8, "Something-Else", val.key);
        try std.testing.expectEqualSlices(u8, "hello", val.value);
    }

    {
        if (try it.next() != null) {
            return error.NotFinished;
        }
    }
}

const LspMessageSplitter = struct {
    buf: std.ArrayList(u8),

    state: union(enum) {
        waiting_header,
        waiting_data: struct {
            expected_len: usize,
        },
    } = .waiting_header,

    pub fn init(alloc: Allocator) LspMessageSplitter {
        const buf = std.ArrayList(u8).init(alloc);
        return .{
            .buf = buf,
        };
    }

    pub fn deinit(self: *LspMessageSplitter) void {
        self.buf.deinit();
    }

    pub fn push(self: *LspMessageSplitter, data: []const u8) !void {
        try self.buf.appendSlice(data);
    }

    fn shift(self: *LspMessageSplitter, amount: usize) !void {
        const new_buf_len = self.buf.items.len - amount;
        std.mem.copyForwards(u8, self.buf.items[0..new_buf_len], self.buf.items[amount..]);
        try self.buf.resize(new_buf_len);
    }

    pub fn next(self: *LspMessageSplitter, alloc: Allocator) !?[]const u8 {
        while (true) {
            switch (self.state) {
                .waiting_header => {
                    const end_tag = "\r\n\r\n";
                    const end_tag_start = std.mem.indexOf(u8, self.buf.items, end_tag) orelse return null;
                    const content_start = end_tag_start + end_tag.len;
                    defer self.shift(content_start) catch unreachable;

                    const content_length = try findContentLength(self.buf.items[0..content_start]);

                    self.state = .{
                        .waiting_data = .{
                            .expected_len = content_length,
                        },
                    };
                },
                .waiting_data => |d| {
                    if (self.buf.items.len < d.expected_len) {
                        return null;
                    }

                    const ret = try alloc.alloc(u8, d.expected_len);
                    @memcpy(ret, self.buf.items[0..d.expected_len]);
                    defer self.shift(d.expected_len) catch unreachable;

                    self.state = .waiting_header;
                    return ret;
                },
            }
        }
    }
};

test "split message" {
    var splitter = LspMessageSplitter.init(std.testing.allocator);
    defer splitter.deinit();

    const data = "Content-Length: 100\r\n" ++
        "idgaf: at all\r\n";

    const data2 =
        "\r\n" ++
        "b" ** 100;

    try splitter.push(data);
    try std.testing.expectEqual(null, try splitter.next(std.testing.allocator));

    try splitter.push(data2);
    {
        const output = try splitter.next(std.testing.allocator) orelse return error.NoData;
        defer std.testing.allocator.free(output);

        try std.testing.expectEqualStrings("b" ** 100, output);
    }

    try std.testing.expectEqual(null, try splitter.next(std.testing.allocator));
}

test "joined messages" {
    var splitter = LspMessageSplitter.init(std.testing.allocator);
    defer splitter.deinit();

    const data = "Content-Length: 100\r\n" ++
        "idgaf: at all\r\n" ++
        "\r\n" ++
        "b" ** 100 ++
        "Content-Length: 50\r\n" ++
        "idgaf: at all for real\r\n" ++
        "\r\n" ++
        "c" ** 50;

    try splitter.push(data);

    {
        const output = try splitter.next(std.testing.allocator) orelse return error.NoData;
        defer std.testing.allocator.free(output);

        try std.testing.expectEqualStrings("b" ** 100, output);
    }

    {
        const output = try splitter.next(std.testing.allocator) orelse return error.NoData;
        defer std.testing.allocator.free(output);

        try std.testing.expectEqualStrings("c" ** 50, output);
    }

    try std.testing.expectEqual(null, try splitter.next(std.testing.allocator));
}

test "typical message" {
    var splitter = LspMessageSplitter.init(std.testing.allocator);
    defer splitter.deinit();

    const data = "Content-Length: 100\r\n" ++
        "idgaf: at all\r\n" ++
        "\r\n" ++
        "b" ** 100;

    try splitter.push(data);

    const output = try splitter.next(std.testing.allocator) orelse return error.NoData;
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("b" ** 100, output);

    try std.testing.expectEqual(null, try splitter.next(std.testing.allocator));
}

fn findContentLength(data: []const u8) !usize {
    var header_it = LspHeaderParser.init(data);
    while (try header_it.next()) |header_item| {
        if (std.mem.eql(u8, header_item.key, "Content-Length")) {
            return try std.fmt.parseInt(usize, header_item.value, 10);
        }
    }

    return error.NoContentLength;
}
