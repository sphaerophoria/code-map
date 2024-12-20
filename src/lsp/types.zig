const meta = @import("meta.zig");
const PatchStruct = meta.PatchStruct;

pub const Message = struct {
    jsonrpc: []const u8 = "2.0",
};

pub const RequestMessage = PatchStruct(Message, struct {
    id: i32,
});

pub const ResponseMessage = PatchStruct(Message, struct {
    id: i32,
});

pub const InitializeMessage = PatchStruct(RequestMessage, struct {
    method: []const u8 = "initialize",
    params: struct {
        capabilities: struct {
            textDocument: struct {
                references: struct {
                    dynamicRegistration: bool = false,
                } = .{},
            } = .{},
        } = .{},
    },
});

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const TextDocumentPositionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
};

pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8,
    version: i32,
    text: []const u8,
};

pub const ReferenceParams = PatchStruct(TextDocumentPositionParams, struct {
    context: struct {
        includeDeclaration: bool,
    },
});

pub const FindReferences = PatchStruct(RequestMessage, struct {
    method: []const u8 = "textDocument/references",
    params: ReferenceParams,
});

pub const FindReferencesResponse = PatchStruct(ResponseMessage, struct {
    result: ?[]Location,
});

pub const InitializedNotification = PatchStruct(Message, struct {
    method: []const u8 = "initialized",
    params: struct {},
});

pub const DidOpenNotification = PatchStruct(Message, struct {
    method: []const u8 = "textDocument/didOpen",
    params: struct {
        textDocument: TextDocumentItem,
    },
});
