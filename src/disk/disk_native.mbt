// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A native, asynchronous hybrid cache: entries live in a memory cache and every
// mutation is appended to a file, so the cache can be rebuilt after a restart.
//
// Wire format, all little-endian:
//
//   put : 0x01 | klen:i32 | key | vlen:i32 | value
//   del : 0x02 | klen:i32 | key
//
// A truncated tail (a crash mid-write) is ignored on replay: the loop stops at
// the first record it cannot read in full, which keeps the last durable prefix.

///|
/// A cache backed by both memory and a file. The memory cache answers reads; a
/// `put`/`del` record per mutation is appended to `path`. Opening replays the
/// log to rebuild the memory cache. `compact` rewrites the file from the live
/// entries so the log does not grow forever.
///
/// Keys and values are encoded with codecs you supply, so the layer stays
/// generic and imposes no wire format of its own. Restored entries are replayed
/// through `set`, so the cache's current capacity and expiry policy apply to
/// them.
pub struct DiskCache[K, V] {
  cache : @moonkart.Cache[K, V]
  path : String
  encode_key : (K) -> Bytes
  decode_key : (Bytes) -> K?
  encode_value : (V) -> Bytes
  decode_value : (Bytes) -> V?
  write_lock : @async.Mutex
}

///|
/// Opens `path` and rebuilds `cache` from the log, then returns a disk-backed
/// handle. A missing file is created empty.
pub async fn[K : Eq + Hash, V] DiskCache::open(
  cache : @moonkart.Cache[K, V],
  path : StringView,
  encode_key : (K) -> Bytes,
  decode_key : (Bytes) -> K?,
  encode_value : (V) -> Bytes,
  decode_value : (Bytes) -> V?,
) -> DiskCache[K, V] {
  let disk : DiskCache[K, V] = {
    cache,
    path: path.to_owned(),
    encode_key,
    decode_key,
    encode_value,
    decode_value,
    write_lock: @async.Mutex(),
  }
  if @fs.exists(disk.path) {
    replay(disk)
  } else {
    @fs.write_binary(disk.path, empty_view(), append=false)
  }
  disk
}

///|
/// The path this cache persists to.
pub fn[K, V] DiskCache::path(self : DiskCache[K, V]) -> String {
  self.path
}

///|
/// The in-memory cache underneath.
pub fn[K, V] DiskCache::cache(self : DiskCache[K, V]) -> @moonkart.Cache[K, V] {
  self.cache
}

///|
/// Reads `key` from memory.
pub fn[K : Eq + Hash, V] DiskCache::get(self : DiskCache[K, V], key : K) -> V? {
  self.cache.get(key)
}

///|
/// Whether `key` is in memory.
pub fn[K : Eq + Hash, V] DiskCache::contains(
  self : DiskCache[K, V],
  key : K,
) -> Bool {
  self.cache.contains(key)
}

///|
/// Number of entries in memory.
pub fn[K, V] DiskCache::size(self : DiskCache[K, V]) -> Int64 {
  self.cache.size()
}

///|
/// Writes `key` to memory and appends a `put` record to the file.
pub async fn[K : Eq + Hash, V] DiskCache::set(
  self : DiskCache[K, V],
  key : K,
  value : V,
) -> Unit {
  self.cache.set(key, value)
  let buf = @buffer.Buffer()
  write_put(buf, self.encode_key, self.encode_value, key, value)
  self.write_lock.acquire()
  defer self.write_lock.release()
  @fs.write_binary(self.path, buf.to_bytes().exact_view(), append=true)
}

///|
/// Removes `key` from memory and, when it was present, appends a `del` record.
pub async fn[K : Eq + Hash, V] DiskCache::remove(
  self : DiskCache[K, V],
  key : K,
) -> Bool {
  let existed = self.cache.remove(key)
  if existed {
    let buf = @buffer.Buffer()
    write_del(buf, self.encode_key, key)
    self.write_lock.acquire()
    defer self.write_lock.release()
    @fs.write_binary(self.path, buf.to_bytes().exact_view(), append=true)
  }
  existed
}

///|
/// Rewrites the file from the live entries, dropping superseded and deleted
/// records. Run this periodically so the log does not grow without bound.
pub async fn[K, V] DiskCache::compact(self : DiskCache[K, V]) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  let buf = @buffer.Buffer()
  for pair in self.cache.to_array() {
    write_put(buf, self.encode_key, self.encode_value, pair.0, pair.1)
  }
  @fs.write_binary(self.path, buf.to_bytes().exact_view(), append=false)
}

///|
fn empty_view() -> BytesView {
  @buffer.Buffer().to_bytes().exact_view()
}

///|
fn[K, V] write_put(
  buf : @buffer.Buffer,
  encode_key : (K) -> Bytes,
  encode_value : (V) -> Bytes,
  key : K,
  value : V,
) -> Unit {
  let kb = encode_key(key)
  let vb = encode_value(value)
  buf.write_byte(b'\x01')
  buf.write_int_le(kb.length())
  buf.write_bytes(kb.exact_view())
  buf.write_int_le(vb.length())
  buf.write_bytes(vb.exact_view())
}

///|
fn[K] write_del(
  buf : @buffer.Buffer,
  encode_key : (K) -> Bytes,
  key : K,
) -> Unit {
  let kb = encode_key(key)
  buf.write_byte(b'\x02')
  buf.write_int_le(kb.length())
  buf.write_bytes(kb.exact_view())
}

///|
fn read_i32_le(view : BytesView, off : Int32) -> Int32 {
  let b0 = view.at(off).to_int()
  let b1 = view.at(off + 1).to_int()
  let b2 = view.at(off + 2).to_int()
  let b3 = view.at(off + 3).to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
async fn[K : Eq + Hash, V] replay(disk : DiskCache[K, V]) -> Unit {
  let data = @fs.read_binary(disk.path)
  let view = data.exact_view()
  let total = view.length()
  let mut off : Int32 = 0
  while off < total {
    let op = view.at(off).to_int()
    off = off + 1
    if op == 1 {
      if off + 4 > total {
        break
      }
      let klen = read_i32_le(view, off)
      off = off + 4
      if klen < 0 || off + klen > total {
        break
      }
      let kb = view.exact_view(start=off, end=off + klen).to_owned()
      off = off + klen
      if off + 4 > total {
        break
      }
      let vlen = read_i32_le(view, off)
      off = off + 4
      if vlen < 0 || off + vlen > total {
        break
      }
      let vb = view.exact_view(start=off, end=off + vlen).to_owned()
      off = off + vlen
      match (disk.decode_key)(kb) {
        Some(k) =>
          match (disk.decode_value)(vb) {
            Some(v) => disk.cache.set(k, v)
            None => ()
          }
        None => ()
      }
    } else if op == 2 {
      if off + 4 > total {
        break
      }
      let klen = read_i32_le(view, off)
      off = off + 4
      if klen < 0 || off + klen > total {
        break
      }
      let kb = view.exact_view(start=off, end=off + klen).to_owned()
      off = off + klen
      match (disk.decode_key)(kb) {
        Some(k) => ignore(disk.cache.remove(k))
        None => ()
      }
    } else {
      break
    }
  }
}
