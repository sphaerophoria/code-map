const mod_a = @import("mod_a");

pub fn aFreeFn() i32 {
    return mod_a.aFreeFn();
}
