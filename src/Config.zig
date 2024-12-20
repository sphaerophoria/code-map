const treesitter = @import("treesitter.zig");

language_server: []const []const u8,
language_server_progress_token: []const u8,
language_id: []const u8,
blacklist_paths: []const []const u8,
treesitter_so: [:0]const u8,
treesitter_init: [:0]const u8,
treesitter_ruleset: treesitter.RuleSet,
matched_extension: []const u8,
