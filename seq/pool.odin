package seq


// A fixed-capacity pool of Runtime_Events with a free list.
//
// Index 0 (NIL_RUNTIME) is reserved as the nil sentinel: a successful
// `runtime_alloc` returns a positive index, NIL_RUNTIME signals
// exhaustion. A freed slot keeps its place in `storage`, but its first
// `size_of(Runtime_Index)` bytes are reused as the free-list link
// while it's free.
Runtime_Pool :: struct {
	storage:   []Runtime_Event,
	count:     u32,
	free_head: Runtime_Index,
	in_use:    u32,
}


runtime_pool_init :: proc(pool: ^Runtime_Pool, capacity: int) {
	pool.storage = make([]Runtime_Event, capacity)
	pool.count = 1 // reserve index 0 as the nil sentinel
	pool.free_head = NIL_RUNTIME
	pool.in_use = 0
}

runtime_pool_reset :: proc(pool: ^Runtime_Pool) {
	pool.count = 1
	pool.free_head = NIL_RUNTIME
	pool.in_use = 0
}

runtime_pool_destroy :: proc(pool: ^Runtime_Pool) {
	delete(pool.storage)
	pool^ = {}
}

runtime_pool_capacity :: proc(pool: ^Runtime_Pool) -> int {
	return len(pool.storage) - 1 // slot 0 is reserved
}

// Reserve a zero-initialized slot. Pops from the free list if possible,
// otherwise bumps `count`. Returns NIL_RUNTIME if the pool is exhausted.
runtime_alloc :: proc(pool: ^Runtime_Pool) -> Runtime_Index {
	if pool.free_head != NIL_RUNTIME {
		index := pool.free_head
		pool.free_head = (cast(^Runtime_Index)&pool.storage[index])^
		pool.storage[index] = {}
		pool.in_use += 1
		return index
	}
	if int(pool.count) >= len(pool.storage) do return NIL_RUNTIME
	index := Runtime_Index(pool.count)
	pool.count += 1
	pool.storage[index] = {}
	pool.in_use += 1
	return index
}

// Return a slot to the free list. Ignores NIL_RUNTIME.
runtime_free :: proc(pool: ^Runtime_Pool, index: Runtime_Index) {
	if index == NIL_RUNTIME do return
	(cast(^Runtime_Index)&pool.storage[index])^ = pool.free_head
	pool.free_head = index
	pool.in_use -= 1
}

runtime_get :: proc(pool: ^Runtime_Pool, index: Runtime_Index) -> ^Runtime_Event {
	return &pool.storage[index]
}
