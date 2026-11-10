// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A native, asynchronous two-tier cache. Memory answers reads first; the file
// behind it holds what memory could not keep, with a byte budget, an eviction
// order and an admission rule of its own, and a read that misses memory is
// served from the file and put back into memory.
//
// Wire format, all little-endian:
//
//   put : 0x01 | klen:i32 | key | vlen:i32 | value
//   del : 0x02 | klen:i32 | key
//
// A truncated tail (a crash mid-write) is ignored on replay: the loop stops at
// the first record it cannot read in full, which keeps the last durable prefix.

///|
pub using @tier {type Stats}

///|
/// A cache backed by both memory and a file. The memory cache answers reads; the
/// file holds a record for every write it keeps, so the cache survives a
/// restart, and the file is itself bounded: `max_bytes` caps the live records,
/// and when a write would spend the last of the budget the rule in `admission`
/// decides whether the newcomer or a resident record leaves.
///
/// Keys and values are encoded with codecs you supply, so the layer stays
/// generic and imposes no wire format of its own. Records restored on open are
/// replayed through `set`, so the memory cache's current capacity and expiry
/// policy apply to them; call `compact` periodically so the file does not grow
/// without bound.
pub struct DiskCache[K, V] {
  cache : @moonkart.Cache[K, V]
  path : String
  encode_key : (K) -> Bytes
  decode_key : (Bytes) -> K?
  encode_value : (V) -> Bytes
  decode_value : (Bytes) -> V?
  write_lock : @async.Mutex
  priv end_offset : @ref.Ref[Int64]
  priv tier : @tier.Tier[K]
}

///|
/// Opens `path` and rebuilds the memory cache from the log, then returns a
/// disk-backed handle. A missing file is created empty.
///
/// `max_bytes` bounds the file's live records. Without it the file keeps
/// everything written; with it, an entry larger than the whole budget is refused
/// and stays in memory only, and older entries leave to make room.
///
/// `admission` decides who wins that last byte. The default keeps a newcomer
/// only if it has been seen more often than the record it would displace, which
/// is what keeps a scan of one-hit keys from walking the file clean.
pub async fn[K : Eq + Hash, V] DiskCache::open(
  cache : @moonkart.Cache[K, V],
  path : StringView,
  encode_key : (K) -> Bytes,
  decode_key : (Bytes) -> K?,
  encode_value : (V) -> Bytes,
  decode_value : (Bytes) -> V?,
  max_bytes? : Int64,
  admission~ : @policy.Admission = ByValue,
) -> DiskCache[K, V] {
  let budget = max_bytes.unwrap_or(0L)
  let disk : DiskCache[K, V] = {
    cache,
    path: path.to_owned(),
    encode_key,
    decode_key,
    encode_value,
    decode_value,
    write_lock: @async.Mutex(),
    end_offset: @ref.Ref(0L),
    tier: @tier.Tier::new(admission, budget, fn(key) {
      @tier.hash_of_bytes(encode_key(key).exact_view())
    }),
  }
  if @fs.exists(disk.path) {
    replay(disk)
  } else {
    @fs.write_file(disk.path, empty_view())
  }
  disk.end_offset.val = @fs.file_size(disk.path)
  // Opening a file that is already over its budget trims it before anyone reads.
  ignore(disk.tier.shrink())
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
/// The bytes the file's live records take, against the budget it was opened with.
pub fn[K, V] DiskCache::budget(self : DiskCache[K, V]) -> Int64 {
  self.tier.budget()
}

///|
/// What the file has done since it was opened.
pub fn[K, V] DiskCache::stats(self : DiskCache[K, V]) -> Stats {
  self.tier.stats()
}

///|
/// Reads `key`. Memory answers first; a miss falls to the file, whose answer is
/// put back into memory so the next read is a memory hit.
pub async fn[K : Eq + Hash, V] DiskCache::get(
  self : DiskCache[K, V],
  key : K,
) -> V? {
  match self.cache.get(key) {
    Some(v) => Some(v)
    None =>
      match self.tier.record_of(key) {
        None => None
        Some(record) => {
          let file = @fs.open(self.path, mode=ReadOnly)
          let raw = file.read_exactly_at(record.len, position=record.slot)
          file.close()
          match
            parse_put(raw.exact_view(), self.decode_key, self.decode_value) {
            None => None
            Some((found, value)) => {
              self.cache.set(found, value)
              self.tier.promote(found)
              Some(value)
            }
          }
        }
      }
  }
}

///|
/// Whether `key` would be found: in memory, or in the file.
pub fn[K : Eq + Hash, V] DiskCache::contains(
  self : DiskCache[K, V],
  key : K,
) -> Bool {
  self.cache.contains(key) || self.tier.contains(key)
}

///|
/// Number of entries in memory. The file's own count is in [`stats`].
pub fn[K, V] DiskCache::size(self : DiskCache[K, V]) -> Int64 {
  self.cache.size()
}

///|
/// Writes `key` to memory and appends a record to the file, then makes room if
/// the budget is spent. A record larger than the whole budget is not written at
/// all: it stays in memory, is counted as refused, and is gone when memory
/// evicts it. A record the admission rule turns away is written, marked dead in
/// the same log, and left off the index, so a restart does not bring it back and
/// only [`compact`] reclaims its bytes.
pub async fn[K : Eq + Hash, V] DiskCache::set(
  self : DiskCache[K, V],
  key : K,
  value : V,
) -> Unit {
  self.cache.set(key, value)
  let buf = @buffer.Buffer()
  write_put(buf, self.encode_key, self.encode_value, key, value)
  let record = buf.to_bytes()
  let len = record.length()
  let budget = self.tier.budget()
  if budget > 0L && len.to_int64() > budget {
    self.tier.note_refused()
    return
  }
  self.write_lock.acquire()
  defer self.write_lock.release()
  let offset = self.append(record.exact_view())
  for victim in self.tier.admit(key, offset, len) {
    let del = @buffer.Buffer()
    write_del(del, self.encode_key, victim)
    ignore(self.append(del.to_bytes().exact_view()))
  }
}

///|
/// Removes `key` from memory and, when the file holds it, appends a `del` record.
pub async fn[K : Eq + Hash, V] DiskCache::remove(
  self : DiskCache[K, V],
  key : K,
) -> Bool {
  let in_memory = self.cache.remove(key)
  match self.tier.discharge(key) {
    None => in_memory
    Some(_) => {
      self.write_lock.acquire()
      defer self.write_lock.release()
      let buf = @buffer.Buffer()
      write_del(buf, self.encode_key, key)
      ignore(self.append(buf.to_bytes().exact_view()))
      true
    }
  }
}

///|
/// Rewrites the file from the live records, dropping superseded, deleted and
/// never-admitted ones, and re-points the index at the new offsets. Run this
/// periodically so the file does not grow without bound.
pub async fn[K : Eq + Hash, V] DiskCache::compact(
  self : DiskCache[K, V],
) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  let data = @fs.read_file(self.path).binary()
  let view = data.exact_view()
  let out = @buffer.Buffer()
  for key in self.tier.keys() {
    match self.tier.record_of(key) {
      None => ()
      Some(record) => {
        let start = record.slot.to_int()
        let body = view.exact_view(start~, end=start + record.len)
        self.tier.restore(key, out.length().to_int64(), record.len)
        out.write_bytes(body)
      }
    }
  }
  let total = out.to_bytes()
  @fs.write_file(self.path, total.exact_view())
  self.end_offset.val = total.length().to_int64()
}

///|
/// Appends one record at the end of the file and returns where it starts.
async fn[K, V] DiskCache::append(
  self : DiskCache[K, V],
  record : BytesView,
) -> Int64 {
  let offset = self.end_offset.val
  @fs.write_file(self.path, record, create_mode=OpenOrCreate, append=true)
  self.end_offset.val = offset + record.length().to_int64()
  offset
}

///|
/// Parses one `put` record, returning the key and value it carries.
fn[K, V] parse_put(
  view : BytesView,
  decode_key : (Bytes) -> K?,
  decode_value : (Bytes) -> V?,
) -> (K, V)? {
  let total = view.length()
  if total < 5 || view.at(0).to_int() != 1 {
    return None
  }
  let klen = read_i32_le(view, 1)
  if klen < 0 || 5 + klen > total {
    return None
  }
  let vstart = 5 + klen
  if vstart + 4 > total {
    return None
  }
  let vlen = read_i32_le(view, vstart)
  if vlen < 0 || vstart + 4 + vlen > total {
    return None
  }
  let key_bytes = view.exact_view(start=5, end=5 + klen).to_owned()
  let value_bytes = view
    .exact_view(start=vstart + 4, end=vstart + 4 + vlen)
    .to_owned()
  match decode_key(key_bytes) {
    Some(key) =>
      match decode_value(value_bytes) {
        Some(value) => Some((key, value))
        None => None
      }
    None => None
  }
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
/// Walks the file and rebuilds the index from it, replaying the live records
/// into memory so a restart comes back with the most recent writes.
async fn[K : Eq + Hash, V] replay(disk : DiskCache[K, V]) -> Unit {
  let data = @fs.read_file(disk.path).binary()
  let view = data.exact_view()
  let total = view.length()
  let mut off : Int32 = 0
  while off < total {
    let start = off
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
            Some(v) => {
              disk.tier.restore(k, start.to_int64(), off - start)
              disk.cache.set(k, v)
            }
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
        Some(k) => {
          ignore(disk.tier.discharge(k))
          ignore(disk.cache.remove(k))
        }
        None => ()
      }
    } else {
      break
    }
  }
}
