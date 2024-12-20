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
    id: i32 = 2,

    fn next(self: *IdAllocator) i32 {
        defer self.id += 1;
        return self.id;
    }
};

const App = struct {
    const RequestType = enum {
        initialize,
        find_references,
    };

    alloc: Allocator,
    outgoing_requests: std.AutoHashMapUnmanaged(i32, RequestType),
    id_allocator: IdAllocator = .{},

    rx_buf: []u8,
    tx: std.fs.File,
    rx: std.fs.File,
    project_dir: []const u8,

    fn init(alloc: Allocator, rx: std.fs.File, tx: std.fs.File, project_dir: []const u8) !App {
        try sendMessage(alloc, lsp.InitializeMessage{
            .id = 1,
            .params = .{},
        }, tx.writer());

        var outgoing_requests = std.AutoHashMapUnmanaged(i32, RequestType){};
        errdefer outgoing_requests.deinit(alloc);

        try outgoing_requests.put(alloc, 1, .initialize);

        const rx_buf = try alloc.alloc(u8, 1 << 20);
        return .{
            .alloc = alloc,
            .outgoing_requests = outgoing_requests,
            .tx = tx,
            .rx = rx,
            .rx_buf = rx_buf,
            .project_dir = project_dir,
        };
    }

    fn deinit(self: *App) void {
        self.outgoing_requests.deinit(self.alloc);
        self.alloc.free(self.rx_buf);
    }

    fn step(self: *App) !void {
        const read_len = try self.rx.read(self.rx_buf);
        if (read_len == 0) return;

        const message = self.rx_buf[0..read_len];

        // FIXME: Multiple messages will break this
        const header_end = std.mem.indexOf(u8, message, "\r\n\r\n") orelse return;
        const json_start = header_end + 4;

        const partial_resposne = try std.json.parseFromSlice(lsp.ResponseMessage, self.alloc, message[json_start..], .{ .ignore_unknown_fields = true });
        defer partial_resposne.deinit();

        std.debug.print("got response for {d}\n", .{partial_resposne.value.id});
        const expected_response_type = self.outgoing_requests.get(partial_resposne.value.id) orelse return;
        switch (expected_response_type) {
            .initialize => {
                std.debug.print("Initialized baybeee\n", .{});
                try sendMessage(self.alloc, lsp.InitializedNotification{
                    .method = "initialized",
                    .params = .{},
                }, self.tx.writer());

                const main_path = try std.fmt.allocPrint(self.alloc, "{s}/src/main.zig", .{self.project_dir});
                defer self.alloc.free(main_path);

                const main_uri = try std.fmt.allocPrint(self.alloc, "file://{s}/src/main.zig", .{self.project_dir});
                defer self.alloc.free(main_uri);

                const main_zig_f = try std.fs.openFileAbsolute(main_path, .{});
                defer main_zig_f.close();
                const main_zig_content = try main_zig_f.readToEndAlloc(self.alloc, 1 << 20);
                defer self.alloc.free(main_zig_content);

                try sendMessage(self.alloc, lsp.DidOpenNotification{
                    .params = .{
                        .textDocument = .{
                            .uri = main_uri,
                            .languageId = "zig",
                            .version = 1,
                            .text = main_zig_content,
                        },
                    },
                }, self.tx.writer());

                const id = self.id_allocator.next();
                try self.outgoing_requests.put(self.alloc, id, .find_references);
                try sendMessage(self.alloc, lsp.FindReferences{
                    .id = id,
                    .params = .{
                        .textDocument = .{
                            .uri = main_uri,
                        },
                        .position = .{
                            .line = 19,
                            .character = 8,
                        },
                        .context = .{
                            .includeDeclaration = false,
                        },
                    },
                }, self.tx.writer());

                const id2 = self.id_allocator.next();
                try self.outgoing_requests.put(self.alloc, id2, .find_references);
                try sendMessage(self.alloc, lsp.FindReferences{
                    .id = id2,
                    .params = .{
                        .textDocument = .{
                            .uri = main_uri,
                        },
                        .position = .{
                            .line = 1182,
                            .character = 22,
                        },
                        .context = .{
                            .includeDeclaration = false,
                        },
                    },
                }, self.tx.writer());
            },
            .find_references => {
                std.debug.print("Find references response time now\n", .{});
                const response = try std.json.parseFromSlice(lsp.FindReferencesResponse, self.alloc, message[json_start..], .{ .ignore_unknown_fields = true });
                defer response.deinit();
                std.debug.print("result: {any}", .{response.value.result});
                if (response.value.result == null) return error.NoResults;
                for (response.value.result.?) |loc| {
                    std.debug.print("{s}, ({d},{d})\n", .{ loc.uri, loc.range.start.line, loc.range.start.character });
                }
            },
        }
    }

    fn run(self: *App) !void {
        while (true) {
            try self.step();

            // FIXME: Proper poll on file handle
            std.time.sleep(50 * std.time.ns_per_ms);
        }
    }
};


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const project_dir = args[1];
    const abs_project_dir = try std.fs.cwd().realpathAlloc(alloc, project_dir);
    defer alloc.free(abs_project_dir);

    var process = std.process.Child.init(&.{"zls"}, alloc);
    process.cwd = project_dir;
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;

    try process.spawn();

    var app = try App.init(alloc, process.stdout.?, process.stdin.?, abs_project_dir);
    defer app.deinit();
    try app.run();

    _ = try process.kill();
    _ = try process.wait();
}
