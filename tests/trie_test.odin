package tests

import "../source/util"
import "core:mem"
import "core:testing"


@(test)
test_trie_zero_value :: proc(t: ^testing.T) {
	tr: util.Trie(8, i32)
	testing.expect_value(t, tr.root, rawptr(nil))
	testing.expect_value(t, tr.depth, u32(0))
}


@(test)
test_trie_get_empty :: proc(t: ^testing.T) {
	tr: util.Trie(8, i32)
	v, ok := util.trie_get(tr, 3)
	testing.expect(t, !ok, "empty trie should report missing")
	testing.expect_value(t, v, i32(0))
}


@(test)
test_trie_get_after_set :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 1024)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	tr: util.Trie(8, i32)
	tr2 := util.trie_set(tr, 3, 42, allocator)

	// Set slot reads back the value.
	v, ok := util.trie_get(tr2, 3)
	testing.expect(t, ok)
	testing.expect_value(t, v, i32(42))

	// Other in-range slots in the same leaf read as zero, ok=true —
	// the leaf exists, the slot just hasn't been written.
	v0, ok0 := util.trie_get(tr2, 0)
	testing.expect(t, ok0)
	testing.expect_value(t, v0, i32(0))
}


@(test)
test_trie_set_into_empty :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 1024)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	tr: util.Trie(8, i32)
	tr2 := util.trie_set(tr, 3, 42, allocator)

	// Original is untouched: structural sharing means the empty trie
	// hasn't acquired a root.
	testing.expect_value(t, tr.root, rawptr(nil))

	// New trie has a leaf at depth 0 with our value at slot 3.
	testing.expect_value(t, tr2.depth, u32(0))
	leaf := cast(^util.Leaf(8, i32))tr2.root
	testing.expect_value(t, leaf.values[3], i32(42))
	testing.expect_value(t, leaf.values[0], i32(0))
}


@(test)
test_trie_set_within_leaf :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 4096)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	tr: util.Trie(8, i32)
	tr1 := util.trie_set(tr, 3, 42, allocator)
	tr2 := util.trie_set(tr1, 5, 99, allocator)

	// tr1 unchanged after the second set: 99 lives only in tr2's leaf.
	v, ok := util.trie_get(tr1, 3)
	testing.expect(t, ok)
	testing.expect_value(t, v, i32(42))
	v5_in_tr1, _ := util.trie_get(tr1, 5)
	testing.expect_value(t, v5_in_tr1, i32(0))

	// tr2 has both.
	v3, ok3 := util.trie_get(tr2, 3)
	testing.expect(t, ok3)
	testing.expect_value(t, v3, i32(42))
	v5, ok5 := util.trie_get(tr2, 5)
	testing.expect(t, ok5)
	testing.expect_value(t, v5, i32(99))
}


@(test)
test_trie_set_grows_one_level :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 4096)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	// B=8: single leaf holds keys 0..7. Setting key=8 forces a wrap to
	// depth=1 (root Branch with two leaves).
	tr: util.Trie(8, i32)
	tr1 := util.trie_set(tr, 3, 42, allocator)
	tr2 := util.trie_set(tr1, 8, 99, allocator)

	testing.expect_value(t, tr2.depth, u32(1))

	// Old keys still resolve.
	v3, ok3 := util.trie_get(tr2, 3)
	testing.expect(t, ok3)
	testing.expect_value(t, v3, i32(42))

	// New key resolves.
	v8, ok8 := util.trie_get(tr2, 8)
	testing.expect(t, ok8)
	testing.expect_value(t, v8, i32(99))

	// tr1 still depth 0 — sharing held.
	testing.expect_value(t, tr1.depth, u32(0))
}


@(test)
test_trie_set_grows_two_levels :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 8192)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	// B=8: B^2 = 64 is the first key needing depth 2.
	tr: util.Trie(8, i32)
	tr1 := util.trie_set(tr, 5, 11, allocator)
	tr2 := util.trie_set(tr1, 64, 22, allocator)

	testing.expect_value(t, tr2.depth, u32(2))

	v5, ok5 := util.trie_get(tr2, 5)
	testing.expect(t, ok5)
	testing.expect_value(t, v5, i32(11))

	v64, ok64 := util.trie_get(tr2, 64)
	testing.expect(t, ok64)
	testing.expect_value(t, v64, i32(22))
}


@(test)
test_trie_overwrite :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 4096)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	tr: util.Trie(8, i32)
	tr1 := util.trie_set(tr, 3, 42, allocator)
	tr2 := util.trie_set(tr1, 3, 99, allocator)

	// tr1 still has the old value — overwrite is non-destructive.
	v1, _ := util.trie_get(tr1, 3)
	testing.expect_value(t, v1, i32(42))

	v2, _ := util.trie_get(tr2, 3)
	testing.expect_value(t, v2, i32(99))
}


@(test)
test_trie_get_unallocated_subtree :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 4096)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	// Grow to depth 2 by writing only two keys whose paths share the
	// root but diverge at the mid level. Slots that were never written
	// remain nil and `trie_get` reports ok=false for keys routed there.
	tr: util.Trie(8, i32)
	tr = util.trie_set(tr, 0, 1, allocator)
	tr = util.trie_set(tr, 65, 2, allocator)
	testing.expect_value(t, tr.depth, u32(2))

	// Key 8 routes: top-slot 0 → mid-slot 1 → leaf-slot 0.
	// Mid-slot 1 was never allocated under the slot-0 wrap, so ok=false.
	_, ok8 := util.trie_get(tr, 8)
	testing.expect(t, !ok8, "subtree at mid-slot 1 should be nil")
}


@(test)
test_trie_many_keys :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 64 * 1024)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	// Insert 0..199 sequentially, each set returning a new trie.
	// B=8 means 200 keys span up to depth 2 (B^2 = 64, B^3 = 512).
	tr: util.Trie(8, i32)
	for i in 0 ..< 200 {
		tr = util.trie_set(tr, u32(i), i32(i * 7), allocator)
	}

	for i in 0 ..< 200 {
		v, ok := util.trie_get(tr, u32(i))
		testing.expect(t, ok)
		testing.expect_value(t, v, i32(i * 7))
	}
}


@(test)
test_trie_sharing_after_deep_set :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 16 * 1024)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	tr: util.Trie(8, i32)
	tr1 := util.trie_set(tr, 0, 100, allocator)
	tr2 := util.trie_set(tr1, 1000, 200, allocator) // forces depth growth
	tr3 := util.trie_set(tr2, 7, 300, allocator) // path-copy through deeper tree

	// All earlier versions still see their own contents.
	v0_in_tr1, _ := util.trie_get(tr1, 0)
	testing.expect_value(t, v0_in_tr1, i32(100))

	v0_in_tr2, _ := util.trie_get(tr2, 0)
	testing.expect_value(t, v0_in_tr2, i32(100))
	v1000_in_tr2, _ := util.trie_get(tr2, 1000)
	testing.expect_value(t, v1000_in_tr2, i32(200))

	// tr3 sees all three.
	v0, _ := util.trie_get(tr3, 0)
	testing.expect_value(t, v0, i32(100))
	v7, _ := util.trie_get(tr3, 7)
	testing.expect_value(t, v7, i32(300))
	v1000, _ := util.trie_get(tr3, 1000)
	testing.expect_value(t, v1000, i32(200))
}


@(test)
test_trie_branching_factor_4 :: proc(t: ^testing.T) {
	scratch: mem.Scratch_Allocator
	mem.scratch_allocator_init(&scratch, 16 * 1024)
	defer mem.scratch_allocator_destroy(&scratch)
	allocator := mem.scratch_allocator(&scratch)

	// B=4 stresses the shift/mask math — single leaf holds 4, depth-1
	// holds 16, etc.
	tr: util.Trie(4, i32)
	tr = util.trie_set(tr, 3, 30, allocator)
	tr = util.trie_set(tr, 4, 40, allocator) // grows to depth 1
	tr = util.trie_set(tr, 16, 160, allocator) // grows to depth 2
	tr = util.trie_set(tr, 0, 0, allocator)
	tr = util.trie_set(tr, 62, 0, allocator)

	v, _ := util.trie_get(tr, 3)
	testing.expect_value(t, v, i32(30))
	v, _ = util.trie_get(tr, 4)
	testing.expect_value(t, v, i32(40))
	v, _ = util.trie_get(tr, 16)
	testing.expect_value(t, v, i32(160))
	v, _ = util.trie_get(tr, 0)
	testing.expect_value(t, v, i32(0))
	testing.expect_value(t, tr.depth, u32(2))
}
