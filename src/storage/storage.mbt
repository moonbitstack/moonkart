// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A second tier over a store of strings: the browser's `localStorage`, a map in
// a test, or anything else that answers `get`, `set`, `remove` and `keys`. One
// storage entry per record, so a write touches one key and another tab's write
// to a key is a single thing to invalidate. The record's bytes are the same ones
// the file tier writes, hex-encoded into the storage key and base64-encoded into
// the storage value.

///|
/// A string-keyed store. `keys` is where restoring starts, so a store that knows
/// the order its entries were written in should return them in it: the entries
/// that do not fit the budget are then the oldest ones.
pub(open) trait Storage {
  /// The value stored under `key`, or `None`.
  fn get(self : Self, key : String) -> String?
  /// Stores `value` under `key`, replacing what was there.
  fn set(self : Self, key : String, value : String) -> Unit
  /// Forgets `key`.
  fn remove(self : Self, key : String) -> Unit
  /// Every key the store holds, in the store's own order.
  fn keys(self : Self) -> Array[String]
}

///|
/// A cache backed by both memory and a store that outlives the page: the same
/// contract as the file tier, on a medium that is a map of strings.
///
/// Every write goes to memory and to the store, bounded by `max_bytes` over the
/// record bytes, with the rule in `admission` deciding who keeps the last byte.
/// A read that misses memory is answered from the store and put back into
/// memory. Records found on open are restored in the store's own order and the
/// memory cache's current capacity and expiry policy apply to them; a stored
/// record carries no write time, so a restored value counts as written when the
/// page loads.
pub struct StorageCache[K, V] {
  cache : @moonkart.Cache[K, V]
  storage : &Storage
  prefix : String
  encode_key : (K) -> Bytes
  decode_key : (Bytes) -> K?
  encode_value : (V) -> Bytes
  decode_value : (Bytes) -> V?
  priv tier : @tier.Tier[K]
}

///|
/// Wraps `cache` so every write also lands in `storage`, and restores what the
/// store already holds.
///
/// `prefix` namespaces this cache's entries, so two caches on one page keep out
/// of each other's way. `max_bytes` bounds the records kept; without it the store
/// keeps everything written, and an entry larger than the whole budget is refused
/// and stays in memory only.
pub fn[K : Eq + Hash, V] StorageCache::open(
  cache : @moonkart.Cache[K, V],
  storage : &Storage,
  encode_key : (K) -> Bytes,
  decode_key : (Bytes) -> K?,
  encode_value : (V) -> Bytes,
  decode_value : (Bytes) -> V?,
  max_bytes? : Int64,
  prefix~ : String = "moonkart:",
  admission~ : @policy.Admission = ByValue,
) -> StorageCache[K, V] {
  let cache_handle : StorageCache[K, V] = {
    cache,
    storage,
    prefix,
    encode_key,
    decode_key,
    encode_value,
    decode_value,
    tier: @tier.Tier::new(admission, max_bytes.unwrap_or(0L), fn(key) {
      @tier.hash_of_bytes(encode_key(key).exact_view())
    }),
  }
  cache_handle.restore()
  cache_handle
}

///|
/// The bytes the stored records take, against the budget the cache was opened
/// with.
pub fn[K, V] StorageCache::budget(self : StorageCache[K, V]) -> Int64 {
  self.tier.budget()
}

///|
/// What the store has done since it was opened.
pub fn[K, V] StorageCache::stats(self : StorageCache[K, V]) -> @tier.Stats {
  self.tier.stats()
}

///|
/// The in-memory cache underneath.
pub fn[K, V] StorageCache::cache(
  self : StorageCache[K, V],
) -> @moonkart.Cache[K, V] {
  self.cache
}

///|
/// Number of entries in memory. The store's own count is in [`stats`].
pub fn[K, V] StorageCache::size(self : StorageCache[K, V]) -> Int64 {
  self.cache.size()
}

///|
/// Reads `key`. Memory answers first; a miss falls to the store, whose answer is
/// put back into memory so the next read is a memory hit.
pub fn[K : Eq + Hash, V] StorageCache::get(
  self : StorageCache[K, V],
  key : K,
) -> V? {
  match self.cache.get(key) {
    Some(v) => Some(v)
    None =>
      // The store is shared, so a page-local index cannot be trusted to say what
      // is in it: another page may have written this key, and this one has not
      // seen it before.
      match self.read_record(key) {
        None => {
          // The store no longer has it: another page may have removed it.
          ignore(self.tier.discharge(key))
          None
        }
        Some((value, len)) => {
          self.cache.set(key, value)
          for victim in self.tier.adopt(key, 0L, len) {
            self.storage.remove(self.text_of(victim))
          }
          Some(value)
        }
      }
  }
}

///|
/// Whether `key` would be found: in memory, or in the store.
pub fn[K : Eq + Hash, V] StorageCache::contains(
  self : StorageCache[K, V],
  key : K,
) -> Bool {
  self.cache.contains(key) ||
  self.tier.contains(key) ||
  self.storage.get(self.text_of(key)) is Some(_)
}

///|
/// Writes `key` to memory and to the store, then makes room if the budget is
/// spent. A record larger than the whole budget is not written at all: it stays
/// in memory, is counted as refused, and is gone when memory evicts it. A record
/// the admission rule turns away is removed from the store again and counted as
/// denied.
pub fn[K : Eq + Hash, V] StorageCache::set(
  self : StorageCache[K, V],
  key : K,
  value : V,
) -> Unit {
  self.cache.set(key, value)
  let record = @tier.encode_record(
    self.encode_key,
    self.encode_value,
    key,
    value,
  )
  let len = record.length()
  let budget = self.tier.budget()
  if budget > 0L && len.to_int64() > budget {
    self.tier.note_refused()
    return
  }
  self.storage.set(self.text_of(key), @base64.encode(record.exact_view()))
  for victim in self.tier.admit(key, 0L, len) {
    self.storage.remove(self.text_of(victim))
  }
}

///|
/// Removes `key` from memory and from the store.
pub fn[K : Eq + Hash, V] StorageCache::remove(
  self : StorageCache[K, V],
  key : K,
) -> Bool {
  let in_memory = self.cache.remove(key)
  match self.tier.discharge(key) {
    None => in_memory
    Some(_) => {
      self.storage.remove(self.text_of(key))
      true
    }
  }
}

///|
/// Drops a key this page still holds because another page wrote it: the memory
/// entry goes, the store's newer value stays, and the next read takes it. Returns
/// whether the storage key belonged to this cache.
///
/// A `storage` event listener passes it the key of every write another tab makes,
/// which is what [`StorageCache::watch`] wires up in a browser.
pub fn[K : Eq + Hash, V] StorageCache::apply_storage_event(
  self : StorageCache[K, V],
  storage_key : String,
) -> Bool {
  match self.key_of_text(storage_key[:]) {
    None => false
    Some(key) => {
      ignore(self.tier.discharge(key))
      ignore(self.cache.remove(key))
      true
    }
  }
}

///|
/// The storage key this cache keeps `key` under.
pub fn[K, V] StorageCache::text_of(
  self : StorageCache[K, V],
  key : K,
) -> String {
  self.prefix + @base16.encode((self.encode_key)(key).exact_view())
}

///|
/// The key a storage key names, if it belongs to this cache.
fn[K, V] StorageCache::key_of_text(
  self : StorageCache[K, V],
  text : StringView,
) -> K? {
  if !text.has_prefix(self.prefix[:]) {
    return None
  }
  let body = text.exact_view(start=self.prefix.length(), end=text.length())
  match decode_hex(body) {
    None => None
    Some(bytes) => (self.decode_key)(bytes)
  }
}

///|
/// The value stored under `key`, or `None` if the store has none or what it has
/// is not a record this cache wrote.
fn[K, V] StorageCache::read_record(
  self : StorageCache[K, V],
  key : K,
) -> (V, Int32)? {
  match self.storage.get(self.text_of(key)) {
    None => None
    Some(text) =>
      match decode_base64(text[:]) {
        None => None
        Some(bytes) =>
          match
            @tier.decode_record(
              bytes.exact_view(),
              self.decode_key,
              self.decode_value,
            ) {
            None => None
            Some((_, value)) => Some((value, bytes.length()))
          }
      }
  }
}

///|
/// Restores every record the store holds under this cache's prefix, oldest
/// first, and drops the ones the budget does not have room for.
fn[K : Eq + Hash, V] StorageCache::restore(self : StorageCache[K, V]) -> Unit {
  for text in self.storage.keys() {
    guard self.key_of_text(text[:]) is Some(_) else { continue }
    match self.storage.get(text) {
      None => ()
      Some(stored) =>
        match decode_base64(stored[:]) {
          None => ()
          Some(bytes) =>
            match
              @tier.decode_record(
                bytes.exact_view(),
                self.decode_key,
                self.decode_value,
              ) {
              None => ()
              Some((found, value)) => {
                self.tier.restore(found, 0L, bytes.length())
                self.cache.set(found, value)
              }
            }
        }
    }
  }
  for victim in self.tier.shrink() {
    self.storage.remove(self.text_of(victim))
  }
}

///|
/// Hex without the library's error type leaking into a code path that already
/// treats undecodable text as "not ours".
fn decode_hex(text : StringView) -> Bytes? {
  Some(@base16.decode(text)) catch {
    _ => None
  }
}

///|
fn decode_base64(text : StringView) -> Bytes? {
  Some(@base64.decode(text)) catch {
    _ => None
  }
}
