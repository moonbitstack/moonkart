// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The contract the file tier is held to, on a store of strings: a fake keeps its
// keys in the order they were first written, the way browser storage does. One
// record of an Int32 key and an Int32 value is 17 bytes (1 tag + 4 + 4 + 4 + 4),
// which is what the budgets below are counted in.

///|
struct Fake {
  keys : Array[String]
  values : @hashmap.HashMap[String, String]
}

///|
fn fake() -> Fake {
  { keys: [], values: @hashmap.HashMap([]), }
}

///|
impl Storage for Fake with fn get(self : Fake, key : String) -> String? {
  self.values.get(key)
}

///|
impl Storage for Fake with fn set(self : Fake, key : String, value : String) -> Unit {
  if !self.values.contains(key) {
    self.keys.push(key)
  }
  ignore(self.values.set(key, value))
}

///|
impl Storage for Fake with fn remove(self : Fake, key : String) -> Unit {
  ignore(self.values.remove(key))
  for i, k in self.keys {
    if k == key {
      ignore(self.keys.remove(i))
      break
    }
  }
}

///|
impl Storage for Fake with fn keys(self : Fake) -> Array[String] {
  self.keys.copy()
}

///|
fn encode_i32(n : Int32) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_int_le(n)
  buf.to_bytes()
}

///|
fn decode_i32(b : Bytes) -> Int32? {
  if b.length() < 4 {
    None
  } else {
    let view = b.exact_view()
    let b0 = view.at(0).to_int()
    let b1 = view.at(1).to_int()
    let b2 = view.at(2).to_int()
    let b3 = view.at(3).to_int()
    Some(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
  }
}

///|
fn stored(
  store : Fake,
  cache : @moonkart.Cache[Int32, Int32],
  max_bytes? : Int64,
) -> @storage.StorageCache[Int32, Int32] {
  @storage.StorageCache::open(
    cache,
    store,
    encode_i32,
    decode_i32,
    encode_i32,
    decode_i32,
    max_bytes?,
  )
}

///|
test "a storage cache recovers its entries after reopening" {
  let store = fake()
  let disk = stored(store, @moonkart.lru_cache(cap=8L))
  disk.set(1, 10)
  disk.set(2, 20)
  assert_eq(disk.get(1), Some(10))
  assert_eq(disk.remove(2), true)
  let reopened = stored(store, @moonkart.lru_cache(cap=8L))
  assert_eq(reopened.get(1), Some(10))
  assert_eq(reopened.get(2), None)
}

///|
test "a read that misses memory is answered from the storage" {
  let store = fake()
  // Room for one entry in memory, room for everything in the store.
  let disk = stored(store, @moonkart.lru_cache(cap=1L))
  disk.set(1, 10)
  disk.set(2, 20)
  assert_eq(disk.size(), 1L)
  assert_eq(disk.stats().entries, 2L)
  assert_eq(disk.get(1), Some(10))
  assert_eq(disk.stats().promotions, 1L)
  assert_eq(disk.size(), 1L)
  assert_eq(disk.get(2), Some(20))
  assert_eq(disk.stats().promotions, 2L)
}

///|
test "the storage keeps its own byte budget" {
  let store = fake()
  let disk = stored(store, @moonkart.lru_cache(cap=8L), max_bytes=34L)
  disk.set(1, 10)
  disk.set(2, 20)
  assert_eq(disk.stats().entries, 2L)
  assert_eq(disk.stats().evictions, 0L)
  disk.set(3, 30)
  assert_eq(disk.stats().entries, 2L)
  assert_eq(disk.stats().evictions, 1L)
  assert_true(disk.stats().bytes <= 34L)
  assert_eq(disk.contains(1), true)
  assert_eq(disk.get(1), Some(10))
}

///|
test "a read from the storage makes that record the freshest" {
  let store = fake()
  let disk = stored(store, @moonkart.lru_cache(cap=1L), max_bytes=34L)
  disk.set(1, 10)
  disk.set(2, 20)
  assert_eq(disk.get(1), Some(10))
  disk.set(3, 30)
  assert_eq(disk.stats().evictions, 1L)
  assert_eq(disk.get(2), None)
  assert_eq(disk.get(1), Some(10))
  assert_eq(disk.get(3), Some(30))
}

///|
test "a record larger than the budget is refused and stays in memory" {
  let store = fake()
  let disk = stored(store, @moonkart.lru_cache(cap=8L), max_bytes=10L)
  disk.set(1, 10)
  assert_eq(disk.stats().refused, 1L)
  assert_eq(disk.stats().entries, 0L)
  assert_eq(disk.get(1), Some(10))
  assert_eq(disk.stats().promotions, 0L)
  assert_eq(store.keys.length(), 0)
}

///|
test "a reopened storage cache comes back with the records the budget left" {
  let store = fake()
  let disk = stored(store, @moonkart.lru_cache(cap=8L), max_bytes=34L)
  disk.set(1, 10)
  disk.set(2, 20)
  disk.set(3, 30) // evicts 1
  assert_eq(disk.stats().entries, 2L)
  let reopened = stored(store, @moonkart.lru_cache(cap=8L), max_bytes=34L)
  assert_eq(reopened.stats().entries, 2L)
  assert_eq(reopened.get(1), None)
  assert_eq(reopened.get(2), Some(20))
  assert_eq(reopened.get(3), Some(30))
}

///|
test "a key seen twice keeps its place against a key seen once" {
  let store = fake()
  let disk = stored(store, @moonkart.lru_cache(cap=8L), max_bytes=34L)
  disk.set(1, 10)
  disk.set(1, 11)
  disk.set(2, 20)
  assert_eq(disk.stats().entries, 2L)
  disk.set(3, 30)
  assert_eq(disk.stats().denied, 1L)
  assert_eq(disk.stats().entries, 2L)
  // Memory still answers for it, and the store does not hold it.
  assert_eq(disk.get(3), Some(30))
  let reopened = stored(store, @moonkart.lru_cache(cap=8L), max_bytes=34L)
  assert_eq(reopened.get(3), None)
  assert_eq(reopened.get(1), Some(11))
}

///|
test "another page's write invalidates this page's copy" {
  let store = fake()
  // Two pages over one store: each has its own memory, both see the same entries.
  let this_page = stored(store, @moonkart.lru_cache(cap=8L))
  let other_page = stored(store, @moonkart.lru_cache(cap=8L))
  other_page.set(1, 10)
  assert_eq(this_page.get(1), Some(10))
  other_page.set(1, 20)
  // Without the event this page keeps answering its own copy.
  assert_eq(this_page.cache().get(1), Some(10))
  assert_eq(this_page.apply_storage_event(other_page.text_of(1)), true)
  assert_eq(this_page.cache().get(1), None)
  assert_eq(this_page.get(1), Some(20))
}

///|
test "a key under another prefix is not this cache's" {
  let store = fake()
  let disk = stored(store, @moonkart.lru_cache(cap=8L))
  disk.set(1, 10)
  assert_eq(disk.apply_storage_event("someone-else:1"), false)
  assert_eq(disk.apply_storage_event("moonkart:zz"), false)
  assert_eq(disk.get(1), Some(10))
}

///|
test "the storage keys carry the prefix and the encoded key" {
  let store = fake()
  let disk = stored(store, @moonkart.lru_cache(cap=8L))
  disk.set(1, 10)
  // base16 of the four little-endian bytes of 1, under the default prefix.
  assert_eq(disk.text_of(1), "moonkart:01000000")
  assert_eq(store.keys, ["moonkart:01000000"])
}
