package seq


Mod_Op_Kind :: enum u8 {
	Nop,
	Set,
	Add,
}

Mod_Op :: struct {
	kind:  Mod_Op_Kind,
	value: i16,
}

Apply_Op :: proc(parent, value: i32) -> i32

@(rodata)
apply_ops := [Mod_Op_Kind]Apply_Op {
	.Nop = proc(parent, value: i32) -> i32 {return parent},
	.Set = proc(parent, value: i32) -> i32 {return value},
	.Add = proc(parent, value: i32) -> i32 {return parent + value},
}
