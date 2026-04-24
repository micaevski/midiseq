package seq


// A fixed-capacity object pool with a free list.
//
// Index 0 is reserved as the nil sentinel: a successful `pool_alloc`
// returns a positive index, and 0 signals exhaustion. A freed slot
// keeps its place in `storage`, but its first size_of(u32) bytes are
// reused as the free-list link while it's free — so `T` must be at
// least that wide.
Pool :: struct($T: typeid) where size_of(T) >= size_of(u32) {
	storage:   []T,
	count:     u32,
	free_head: u32,
}


pool_init :: proc(pool: ^Pool($T), capacity: int) {
	pool.storage = make([]T, capacity)
	pool.count = 1 // reserve index 0 as the nil sentinel
	pool.free_head = 0
}

pool_destroy :: proc(pool: ^Pool($T)) {
	delete(pool.storage)
	pool^ = {}
}

// Reserve a zero-initialized slot. Pops from the free list if possible,
// otherwise bumps `count`. Returns 0 if the pool is exhausted.
pool_alloc :: proc(pool: ^Pool($T)) -> u32 {
	if pool.free_head != 0 {
		index := pool.free_head
		pool.free_head = (cast(^u32)&pool.storage[index])^
		pool.storage[index] = {}
		return index
	}
	if int(pool.count) >= len(pool.storage) do return 0
	index := pool.count
	pool.count += 1
	pool.storage[index] = {}
	return index
}

// Return a slot to the free list. Ignores index 0.
pool_free :: proc(pool: ^Pool($T), index: u32) {
	if index == 0 do return
	(cast(^u32)&pool.storage[index])^ = pool.free_head
	pool.free_head = index
}

pool_get :: proc(pool: ^Pool($T), index: u32) -> ^T {
	return &pool.storage[index]
}
