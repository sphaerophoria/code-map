const mod_a = @import("mod_a");
const mod_b = @import("mod_b");

pub fn main() void {
    const s = mod_a.SomeStruct.init();
    s.doSomething();

    const e = mod_a.SomeEnum.a;
    e.doSomething();

    const u = mod_a.SomeUnion { .a = 4 };
    u.doSomething();

    _ = mod_a.aFreeFn();
    _ = mod_b.aFreeFn();

}
