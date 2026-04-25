package main

import "core:os"
import "core:time"


// File_Watcher polls `path`'s modification time. Cheapest cross-platform
// approach — works anywhere `os.last_write_time_by_name` works.
File_Watcher :: struct {
	path:  string,
	mtime: time.Time,
	known: bool,
}

// Returns true if the file's mtime has advanced since the last poll, or
// on the first successful poll. Returns false if the file isn't
// readable or hasn't changed.
file_watcher_poll :: proc(w: ^File_Watcher) -> bool {
	mtime, err := os.last_write_time_by_name(w.path)
	if err != nil do return false
	if !w.known {
		w.mtime = mtime
		w.known = true
		return true
	}
	if mtime._nsec != w.mtime._nsec {
		w.mtime = mtime
		return true
	}
	return false
}
