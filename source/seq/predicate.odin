package seq


Predicate_Getter :: proc(t: ^Runtime_Timeline) -> f32
Predicate_Op :: proc(value, constant: f32) -> bool

Predicate_Field :: enum u8 {
	Trans,
	Rate,
	Velocity,
	Mod1,
	Mod2,
	Mod3,
	Mod4,
}

Predicate_Side :: union #no_nil {
	f32,
	Predicate_Field,
}

Predicate_Op_Kind :: enum u8 {
	Gt,
	Lt,
	Eq,
	Neq,
	Geq,
	Leq,
}

get_trans_semitones :: proc(t: ^Runtime_Timeline) -> f32 {
	return f32(
		i32(t.transposition.semitones) +
		degrees_to_semitones(i32(t.transposition.degrees), t.scale),
	)
}
get_rate :: proc(t: ^Runtime_Timeline) -> f32 {return t.rate}
get_velocity :: proc(t: ^Runtime_Timeline) -> f32 {return f32(t.velocity)}
get_mod1 :: proc(t: ^Runtime_Timeline) -> f32 {return f32(t.mods[0])}
get_mod2 :: proc(t: ^Runtime_Timeline) -> f32 {return f32(t.mods[1])}
get_mod3 :: proc(t: ^Runtime_Timeline) -> f32 {return f32(t.mods[2])}
get_mod4 :: proc(t: ^Runtime_Timeline) -> f32 {return f32(t.mods[3])}

op_gt :: proc(a, b: f32) -> bool {return a > b}
op_lt :: proc(a, b: f32) -> bool {return a < b}
op_eq :: proc(a, b: f32) -> bool {return a == b}
op_neq :: proc(a, b: f32) -> bool {return a != b}
op_geq :: proc(a, b: f32) -> bool {return a >= b}
op_leq :: proc(a, b: f32) -> bool {return a <= b}

@(rodata)
predicate_getters := [Predicate_Field]Predicate_Getter {
	.Trans    = get_trans_semitones,
	.Rate     = get_rate,
	.Velocity = get_velocity,
	.Mod1     = get_mod1,
	.Mod2     = get_mod2,
	.Mod3     = get_mod3,
	.Mod4     = get_mod4,
}

predicate_side_value :: proc(side: Predicate_Side, t: ^Runtime_Timeline) -> f32 {
	switch v in side {
	case f32:
		return v
	case Predicate_Field:
		return predicate_getters[v](t)
	}
	return 0
}

@(rodata)
predicate_ops := [Predicate_Op_Kind]Predicate_Op {
	.Gt  = op_gt,
	.Lt  = op_lt,
	.Eq  = op_eq,
	.Neq = op_neq,
	.Geq = op_geq,
	.Leq = op_leq,
}
