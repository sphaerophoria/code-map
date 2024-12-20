const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const args = try std.process.argsAlloc(gpa.allocator());

    const input_path = args[1];
    const output_path = args[2];

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    const output_writer = output_file.writer();

    const dir = try std.fs.cwd().openDir(input_path, .{ .iterate = true });
    var walker = try dir.walk(gpa.allocator());

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .block_device,
            .character_device,
            .directory,
            .named_pipe,
            .unix_domain_socket,
            .whiteout,
            .door,
            .event_port,
            .unknown,
            => {
                continue;
            },
            .sym_link, .file => {},
        }

        try output_writer.writeAll(entry.path);
        try output_writer.writeAll("\n");
    }
}
