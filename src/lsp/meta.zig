const std = @import("std");

pub fn PatchStructMany(comptime Base: type, comptime Children: []const type) type {
    const base_info = @typeInfo(Base);

    var fields: []const std.builtin.Type.StructField = base_info.Struct.fields;

    inline for (Children) |Child| {
        const child_info = @typeInfo(Child);
        fields = fields ++ child_info.Struct.fields;
    }
    return @Type(.{
        .Struct = .{
            .layout = .auto,
            .fields = fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn PatchStruct(comptime Base: type, comptime Child: type) type {
    return PatchStructMany(Base, &.{Child});
}
