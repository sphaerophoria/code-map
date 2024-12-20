const std = @import("std");
const Allocator = std.mem.Allocator;
const coords = @import("coords.zig");
const bindings = @cImport({
    @cInclude("tree_sitter/api.h");
});

const TextRange = coords.TextRange;

const NavigationAction = union(enum) {
    goto_parent,
    expect_type: []const u8,
    first_child_with_type: []const u8,
    print_children, // Debug action to inspect state
};

pub const RuleSet = struct {
    // Each element in this array is a set of actions that can be taken to
    // resolve an identifier. Not all rules are applicable in all
    // situations, so we need to provide multiple sets.
    //
    // e.g. A zig struct could be created as
    //
    // A: `const X = struct {...}`
    // or
    // B: `x: struct {...}`
    //
    // For this case we'd have a set of rules for A, and a set of rules for
    // B, try them both, and take whichever one works
    //
    // Now consider that in the above, A, B could be structs, or enums, or
    // unions. This means the same actions would resolve the identifier for
    // all of the above. Stash our ident resolvers, and reference them by
    // index in the rules
    ident_resolvers: []const []const NavigationAction,
    rules: []const Rule,
};

pub const Rule = struct {
    match_type: []const u8,
    print_name: []const u8,
    // Which ident_resolvers indices are relevant to us
    resolve_ident: []const usize,
};

pub const AstIterator = struct {
    tree: *bindings.TSTree,
    cursor: bindings.TSTreeCursor,
    file_content: []const u8,
    ruleset: *const RuleSet,

    depth: i32 = 0,

    pub fn deinit(self: *AstIterator) void {
        bindings.ts_tree_cursor_delete(&self.cursor);
        bindings.ts_tree_delete(self.tree);
    }

    pub const Output = struct {
        path: []const []const u8,
        ident_range: TextRange,
        range: TextRange,

        pub fn deinit(self: Output, alloc: Allocator) void {
            alloc.free(self.path);
        }
    };

    pub fn next(self: *AstIterator, alloc: Allocator) !?Output {
        while (true) {
            if (self.depth < 0) return null;

            const node = bindings.ts_tree_cursor_current_node(&self.cursor);
            self.advanceCursor();

            if (self.runRules(node)) |res| {
                const full = try self.resolveNodePath(alloc, node);
                errdefer alloc.free(full);

                const start = bindings.ts_node_start_point(node);
                const end = bindings.ts_node_end_point(node);

                return .{
                    .path = full,
                    .ident_range = res.range,
                    .range = .{
                        .start = .{
                            .line = start.row,
                            .col = start.column,
                        },
                        .end = .{
                            .line = end.row,
                            .col = end.column,
                        },
                    },
                };
            }
        }
    }

    fn resolveNodePath(self: AstIterator, alloc: Allocator, in_node: bindings.TSNode) ![]const []const u8 {
        var name_stack = std.ArrayList([]const u8).init(alloc);
        defer name_stack.deinit();

        var node = in_node;
        while (!bindings.ts_node_is_null(node)) {
            defer node = bindings.ts_node_parent(node);

            if (self.runRules(node)) |res| {
                try name_stack.append(res.name);
            }
        }

        std.mem.reverse([]const u8, name_stack.items);
        return name_stack.toOwnedSlice();
    }

    fn runRules(self: AstIterator, node: bindings.TSNode) ?Ident {
        for (self.ruleset.rules) |rule| {
            if (self.runRule(node, rule)) |res| {
                return res;
            }
        }
        return null;
    }

    const Ident = struct {
        range: TextRange,
        name: []const u8,
    };

    fn runRule(self: AstIterator, node: bindings.TSNode, rule: Rule) ?Ident {
        const node_type = std.mem.span(bindings.ts_node_type(node));
        if (!std.mem.eql(u8, node_type, rule.match_type)) {
            return null;
        }

        for (rule.resolve_ident) |resolver_idx| {
            if (self.resolveIdent(node, self.ruleset.ident_resolvers[resolver_idx])) |ident| {
                return ident;
            }
        }

        return null;
    }

    fn resolveIdent(self: AstIterator, node: bindings.TSNode, seq: []const NavigationAction) ?Ident {
        var ident_it = node;
        for (seq) |action| {
            switch (action) {
                .goto_parent => {
                    ident_it = bindings.ts_node_parent(ident_it);
                },
                .expect_type => |expected| {
                    const it_type = std.mem.span(bindings.ts_node_type(ident_it));
                    if (!std.mem.eql(u8, it_type, expected)) {
                        return null;
                    }
                },
                .first_child_with_type => |expected_t| {
                    const it_children = bindings.ts_node_child_count(ident_it);
                    var found = false;
                    for (0..it_children) |i| {
                        const it_child = bindings.ts_node_child(ident_it, @intCast(i));
                        const child_type = std.mem.span(bindings.ts_node_type(it_child));
                        if (std.mem.eql(u8, child_type, expected_t)) {
                            found = true;
                            ident_it = it_child;
                            break;
                        }
                    }
                    if (!found) {
                        return null;
                    }
                },
                .print_children => {
                    const it_children = bindings.ts_node_child_count(ident_it);
                    for (0..it_children) |i| {
                        const it_child = bindings.ts_node_child(ident_it, @intCast(i));
                        const child_type = std.mem.span(bindings.ts_node_type(it_child));
                        std.debug.print("child_type: {s}\n", .{child_type});
                    }
                    return null;
                },
            }
        }

        const start = bindings.ts_node_start_point(ident_it);
        const end = bindings.ts_node_end_point(ident_it);

        const start_byte = bindings.ts_node_start_byte(ident_it);
        const end_byte = bindings.ts_node_end_byte(ident_it);

        return .{
            .name = self.file_content[start_byte..end_byte],
            .range = .{
                .start = .{
                    .line = start.row,
                    .col = start.column,
                },
                .end = .{
                    .line = end.row,
                    .col = end.column,
                },
            },
        };
    }

    fn advanceCursor(self: *AstIterator) void {
        if (bindings.ts_tree_cursor_goto_first_child(&self.cursor)) {
            self.depth += 1;
            return;
        }

        if (bindings.ts_tree_cursor_goto_next_sibling(&self.cursor)) {
            return;
        }

        while (self.depth >= 0) {
            self.depth -= 1;
            // If it fails, our depth will still decrease
            if (!bindings.ts_tree_cursor_goto_parent(&self.cursor)) {
                std.debug.assert(self.depth < 0);
            }

            if (bindings.ts_tree_cursor_goto_next_sibling(&self.cursor)) {
                return;
            }
        }
    }
};

pub const FileParser = struct {
    parser: *bindings.TSParser,
    lang: *bindings.TSLanguage,
    ruleset: *const RuleSet,
    lang_lib: *anyopaque,

    pub fn init(lang_path: [:0]const u8, lang_init_name: [:0]const u8, ruleset: *const RuleSet) !FileParser {
        const parser: *bindings.TSParser = bindings.ts_parser_new() orelse return error.InitParser;
        errdefer bindings.ts_parser_delete(parser);

        const lang_lib: *anyopaque = std.c.dlopen(lang_path, std.c.RTLD.LAZY) orelse return error.OpenLang;
        errdefer _ = std.c.dlclose(lang_lib);

        const langInit: *const fn () ?*bindings.TSLanguage = @ptrCast(std.c.dlsym(lang_lib, lang_init_name));
        const lang: *bindings.TSLanguage = langInit() orelse return error.InitLang;
        errdefer bindings.ts_language_delete(lang);

        if (!bindings.ts_parser_set_language(parser, lang)) {
            return error.SetLang;
        }

        return .{
            .parser = parser,
            .lang_lib = lang_lib,
            .lang = lang,
            .ruleset = ruleset,
        };
    }

    pub fn deinit(self: *FileParser) void {
        bindings.ts_parser_delete(self.parser);
        bindings.ts_language_delete(self.lang);
        _ = std.c.dlclose(self.lang_lib);
    }

    pub fn parseFile(self: *FileParser, file_content: []const u8) !AstIterator {
        const ts_tree: *bindings.TSTree = blk: {
            break :blk bindings.ts_parser_parse_string(self.parser, null, file_content.ptr, @intCast(file_content.len));
        } orelse return error.ParseFile;
        errdefer bindings.ts_tree_delete(ts_tree);

        return .{
            .tree = ts_tree,
            .cursor = bindings.ts_tree_cursor_new(bindings.ts_tree_root_node(ts_tree)),
            .file_content = file_content,
            .ruleset = self.ruleset,
        };
    }
};
