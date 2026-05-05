package seq


Mod_Op_Kind :: enum u8 {
	Nop,
	Set,
	Add,
	Mul,
}

Op :: struct {
	kind:    Mod_Op_Kind,
	operand: Predicate_Side,
	negate:  bool, // only honored for Predicate_Field operands; literal operands are pre-signed
}

Apply_Op :: proc(parent, value: i32) -> i32

@(rodata)
apply_ops := [Mod_Op_Kind]Apply_Op {
	.Nop = proc(parent, value: i32) -> i32 {return parent},
	.Set = proc(parent, value: i32) -> i32 {return value},
	.Add = proc(parent, value: i32) -> i32 {return parent + value},
	.Mul = proc(parent, value: i32) -> i32 {return parent * value},
}

apply_op :: proc(parent: f32, op: Op, t: ^Runtime_Timeline) -> f32 {
	v := predicate_side_value(op.operand, t)
	if op.negate do v = -v
	switch op.kind {
	case .Nop:
		return parent
	case .Set:
		return v
	case .Add:
		return parent + v
	case .Mul:
		return parent * v
	}
	return parent
}

apply_op_i32 :: proc(parent: i32, op: Op, t: ^Runtime_Timeline) -> i32 {
	return i32(apply_op(f32(parent), op, t))
}
