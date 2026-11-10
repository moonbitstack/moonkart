// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The file is a tier, not just a log: it answers a read that memory cannot, it
// keeps a budget of its own, and it evicts in its own order. One record of an
// Int32 key and an Int32 value is 17 bytes (1 tag + 4 + 4 + 4 + 4), which is what
// the budgets below are counted in.

///|
async test "a read that misses memory is answered from the file" {
  let dir = @fs.tmpdir(prefix="moonkart-tier-promote-")
  let path = dir + "/cache.bin"
  // Room for one entry in memory, room for everything in the file.
  let cache = @moonkart.lru_cache(cap=1L)
  let disk = DiskCache::open(
    cache, path, encode_i32, decode_i32, encode_i32, decode_i32,
  )
  disk.set(1, 10)
  disk.set(2, 20)
  assert_eq(disk.size(), 1L)
  assert_eq(disk.stats().entries, 2L)
  assert_eq(disk.get(1), Some(10))
  assert_eq(disk.stats().promotions, 1L)
  // The promotion put it back in memory, at the cost of the entry that was there.
  assert_eq(disk.size(), 1L)
  assert_eq(disk.get(2), Some(20))
  assert_eq(disk.stats().promotions, 2L)
  discard(dir, path)
}

///|
async test "the file keeps its own byte budget" {
  let dir = @fs.tmpdir(prefix="moonkart-tier-budget-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=8L)
  let disk = DiskCache::open(
    cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=40L, // two 17-byte records
  )
  disk.set(1, 10)
  disk.set(2, 20)
  assert_eq(disk.stats().entries, 2L)
  assert_eq(disk.stats().evictions, 0L)
  disk.set(3, 30)
  assert_eq(disk.stats().entries, 2L)
  assert_eq(disk.stats().evictions, 1L)
  assert_true(disk.stats().bytes <= 40L)
  // The oldest record left the file, so only memory can still answer for it.
  assert_eq(disk.contains(1), true)
  assert_eq(disk.get(1), Some(10))
  discard(dir, path)
}

///|
async test "a read from the file makes that record the freshest" {
  let dir = @fs.tmpdir(prefix="moonkart-tier-read-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=1L)
  let disk = DiskCache::open(
    cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=40L,
  )
  disk.set(1, 10)
  disk.set(2, 20)
  // Reading 1 from the file moves it behind 2 in the eviction order.
  assert_eq(disk.get(1), Some(10))
  disk.set(3, 30)
  assert_eq(disk.stats().evictions, 1L)
  assert_eq(disk.get(2), None)
  assert_eq(disk.get(1), Some(10))
  assert_eq(disk.get(3), Some(30))
  discard(dir, path)
}

///|
async test "a record larger than the budget is refused and stays in memory" {
  let dir = @fs.tmpdir(prefix="moonkart-tier-refuse-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=8L)
  let disk = DiskCache::open(
    cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=10L, // smaller than one record
  )
  disk.set(1, 10)
  assert_eq(disk.stats().refused, 1L)
  assert_eq(disk.stats().entries, 0L)
  assert_eq(disk.get(1), Some(10))
  assert_eq(disk.stats().promotions, 0L)
  discard(dir, path)
}

///|
async test "a reopened file comes back with the records the budget left" {
  let dir = @fs.tmpdir(prefix="moonkart-tier-reopen-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=8L)
  let disk = DiskCache::open(
    cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=40L,
  )
  disk.set(1, 10)
  disk.set(2, 20)
  disk.set(3, 30) // evicts 1
  assert_eq(disk.stats().entries, 2L)
  let reopened_cache = @moonkart.lru_cache(cap=8L)
  let reopened = DiskCache::open(
    reopened_cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=40L,
  )
  assert_eq(reopened.stats().entries, 2L)
  assert_eq(reopened.get(1), None)
  assert_eq(reopened.get(2), Some(20))
  assert_eq(reopened.get(3), Some(30))
  discard(dir, path)
}

///|
async test "compact drops what the budget already evicted" {
  let dir = @fs.tmpdir(prefix="moonkart-tier-compact-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=8L)
  let disk = DiskCache::open(
    cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=40L,
  )
  disk.set(1, 10)
  disk.set(2, 20)
  disk.set(3, 30)
  let before = @fs.file_size(path)
  disk.compact()
  let after = @fs.file_size(path)
  // Two live records of 17 bytes each; the append log held more than that.
  assert_eq(after, 34L)
  assert_true(before > after)
  assert_eq(disk.stats().entries, 2L)
  assert_eq(disk.get(2), Some(20))
  assert_eq(disk.get(3), Some(30))
  discard(dir, path)
}

///|
async test "a key seen twice keeps its place against a key seen once" {
  let dir = @fs.tmpdir(prefix="moonkart-tier-value-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=8L)
  let disk = DiskCache::open(
    cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=34L, // two 17-byte records
  )
  disk.set(1, 10)
  disk.set(1, 11) // the same key again: seen twice
  disk.set(2, 20)
  assert_eq(disk.stats().entries, 2L)
  disk.set(3, 30) // seen once, and the budget is spent
  assert_eq(disk.stats().denied, 1L)
  assert_eq(disk.stats().evictions, 0L)
  assert_eq(disk.stats().entries, 2L)
  // Memory still answers for it; the file does not hold it, and a restart
  // honours the same decision.
  assert_eq(disk.get(3), Some(30))
  let reopened_cache = @moonkart.lru_cache(cap=8L)
  let reopened = DiskCache::open(
    reopened_cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=34L,
  )
  assert_eq(reopened.get(3), None)
  assert_eq(reopened.get(1), Some(11))
  assert_eq(reopened.get(2), Some(20))
  discard(dir, path)
}

///|
async test "taking everything writes what value admission turns away" {
  let dir = @fs.tmpdir(prefix="moonkart-tier-take-all-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=8L)
  let disk = DiskCache::open(
    cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=34L,
    admission=@policy.TakeAll,
  )
  disk.set(1, 10)
  disk.set(1, 11)
  disk.set(2, 20)
  disk.set(3, 30)
  assert_eq(disk.stats().denied, 0L)
  assert_eq(disk.stats().evictions, 1L)
  let reopened_cache = @moonkart.lru_cache(cap=8L)
  let reopened = DiskCache::open(
    reopened_cache,
    path,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes=34L,
  )
  assert_eq(reopened.get(1), None)
  assert_eq(reopened.get(3), Some(30))
  discard(dir, path)
}
