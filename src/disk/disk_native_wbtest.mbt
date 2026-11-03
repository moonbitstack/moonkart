// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

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
    Some(read_i32_le(b.exact_view(), 0))
  }
}

///|
async fn discard(dir : String, path : String) -> Unit {
  if @fs.exists(path) {
    @fs.remove(path)
  }
  @fs.rmdir(dir, recursive=true)
}

///|
async test "a disk cache recovers its entries after reopening" {
  let dir = @fs.tmpdir(prefix="moonkart-disk-test-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=8L)
  let disk = DiskCache::open(
    cache, path, encode_i32, decode_i32, encode_i32, decode_i32,
  )
  disk.set(1, 10)
  disk.set(2, 20)
  assert_eq(disk.get(1), Some(10))
  assert_eq(disk.remove(2), true)
  disk.compact()
  let reopened_cache = @moonkart.lru_cache(cap=8L)
  let reopened = DiskCache::open(
    reopened_cache, path, encode_i32, decode_i32, encode_i32, decode_i32,
  )
  assert_eq(reopened.get(1), Some(10))
  assert_eq(reopened.get(2), None)
  discard(dir, path)
}

///|
async test "a truncated tail is ignored on replay" {
  let dir = @fs.tmpdir(prefix="moonkart-disk-tail-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=8L)
  let disk = DiskCache::open(
    cache, path, encode_i32, decode_i32, encode_i32, decode_i32,
  )
  disk.set(1, 10)
  disk.compact()
  // A crash mid-write leaves a record header without its body.
  let tail = @buffer.Buffer()
  tail.write_byte(b'\x01')
  @fs.write_file(
    path,
    tail.to_bytes().exact_view(),
    create_mode=OpenOrCreate,
    append=true,
  )
  let reopened_cache = @moonkart.lru_cache(cap=8L)
  let reopened = DiskCache::open(
    reopened_cache, path, encode_i32, decode_i32, encode_i32, decode_i32,
  )
  assert_eq(reopened.get(1), Some(10))
  assert_eq(reopened.size(), 1L)
  discard(dir, path)
}

///|
async test "appends keep earlier records without a compact" {
  let dir = @fs.tmpdir(prefix="moonkart-disk-append-")
  let path = dir + "/cache.bin"
  let cache = @moonkart.lru_cache(cap=8L)
  let disk = DiskCache::open(
    cache, path, encode_i32, decode_i32, encode_i32, decode_i32,
  )
  disk.set(1, 10)
  disk.set(2, 20)
  let reopened_cache = @moonkart.lru_cache(cap=8L)
  let reopened = DiskCache::open(
    reopened_cache, path, encode_i32, decode_i32, encode_i32, decode_i32,
  )
  assert_eq(reopened.get(1), Some(10))
  assert_eq(reopened.get(2), Some(20))
  discard(dir, path)
}
