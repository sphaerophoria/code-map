
pub const SomeStruct = struct {
    a: i32,
    b: u64,
    u: SomeUnion,

    pub fn init() SomeStruct {
        return .{
            .a = 4,
            .b = 3,
            .u = SomeUnion{ .a = 7 },
        };
    }

    pub fn doSomething(self: SomeStruct) void {
        self.u.doSomething();
    }
};

pub const SomeUnion = union(enum) {
    a: i32,
    b: i32,

    pub fn doSomething(_: SomeUnion) void {}
};

pub const SomeEnum = enum {
    a,
    b,
    c,

    pub fn doSomething(_: SomeEnum) void {}
};


pub fn aFreeFn() i32 {
    const s = SomeStruct.init();
    const u = SomeUnion { .b = 4 };
    const e = SomeEnum.b;

    return u.b + s.a + @intFromEnum(e);
}
