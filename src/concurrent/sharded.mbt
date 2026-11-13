// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How many shards a cache gets when the caller does not say. Eight is enough
/// that a busy key crowds out little else, and small enough that each shard
/// still holds a working set worth keeping.
pub let default_shards : Int32 = 8

///|
/// A cache split into independent shards, each with its own entries, its own
/// eviction budget and its own in-flight table. A key always lands in the same
/// shard, so a read or a write behaves exactly as it does on a single cache;
/// what changes is that traffic in one shard cannot evict entries in another,
/// and a slow loader in one shard holds up nothing in the others.
///
/// The shard is `hash(key) modulo shards`, so the split is stable across calls
/// and across processes only as far as the runtime's hash seed is. The runtime
/// schedules tasks cooperatively, so sharding is not by itself a speed-up: it is
/// the unit a caller can hand to its own threads, and the unit that keeps
/// unrelated workloads from pushing each other out.
pub struct ShardedCache[K, V] {
  priv shards : Array[AsyncCache[K, V]]
}

///|
/// Builds `shards` caches. `make` is called once per shard with that shard's
/// index, so each one can be bounded and tuned on its own.
pub fn[K : Eq + Hash, V] ShardedCache::new(
  make~ : (Int32) -> @moonkart.Cache[K, V],
  shards~ : Int32 = default_shards,
) -> ShardedCache[K, V] {
  guard shards > 0 else {
    abort("moonkart: ShardedCache::new: shards must be at least one")
  }
  let built : Array[AsyncCache[K, V]] = []
  for i = 0; i < shards; i = i + 1 {
    built.push(AsyncCache::new(make(i)))
  }
  { shards: built, }
}

///|
/// The index of the shard `key` belongs to.
pub fn[K : Hash, V] ShardedCache::shard_of(
  self : ShardedCache[K, V],
  key : K,
) -> Int32 {
  (Hash::hash(key) & 0x7fffffff) % self.shards.length()
}

///|
/// How many shards this cache is split into.
pub fn[K, V] ShardedCache::shards(self : ShardedCache[K, V]) -> Int32 {
  self.shards.length()
}

///|
fn[K : Hash, V] ShardedCache::shard(
  self : ShardedCache[K, V],
  key : K,
) -> AsyncCache[K, V] {
  self.shards[self.shard_of(key)]
}

///|
/// Reads `key` from the shard that holds it, or `None`.
pub fn[K : Eq + Hash, V] ShardedCache::get(
  self : ShardedCache[K, V],
  key : K,
) -> V? {
  self.shard(key).get(key)
}

///|
/// Inserts or replaces `key` in the shard that holds it.
pub fn[K : Eq + Hash, V] ShardedCache::set(
  self : ShardedCache[K, V],
  key : K,
  value : V,
) -> Unit {
  self.shard(key).set(key, value)
}

///|
/// Reads `key` without counting a hit or a miss and without moving it in the
/// eviction order, as `Cache::peek` does.
pub fn[K : Eq + Hash, V] ShardedCache::peek(
  self : ShardedCache[K, V],
  key : K,
) -> V? {
  self.shard(key).peek(key)
}

///|
/// Whether `key` is present and live in the shard that holds it.
pub fn[K : Eq + Hash, V] ShardedCache::contains(
  self : ShardedCache[K, V],
  key : K,
) -> Bool {
  self.shard(key).contains(key)
}

///|
/// Reads `key`, running `loader` on a miss. Waiters on the same key share one
/// loader run; waiters on keys in other shards are unaffected.
pub async fn[K : Eq + Hash, V] ShardedCache::get_with(
  self : ShardedCache[K, V],
  key : K,
  loader : async (K) -> V,
) -> V {
  self.shard(key).get_with(key, loader)
}

///|
/// Like [`get_with`], but the loader may answer `None` for "no value".
pub async fn[K : Eq + Hash, V] ShardedCache::try_get_with(
  self : ShardedCache[K, V],
  key : K,
  loader : async (K) -> V?,
) -> V? {
  self.shard(key).try_get_with(key, loader)
}

///|
/// Removes `key` from the shard that holds it. Returns whether it was present.
pub fn[K : Eq + Hash, V] ShardedCache::invalidate(
  self : ShardedCache[K, V],
  key : K,
) -> Bool {
  self.shard(key).inner().remove(key)
}

///|
/// Removes every entry in every shard.
pub fn[K : Eq + Hash, V] ShardedCache::invalidate_all(
  self : ShardedCache[K, V],
) -> Unit {
  for shard in self.shards {
    shard.inner().invalidate_all()
  }
}

///|
/// Number of entries held across all shards.
pub fn[K, V] ShardedCache::size(self : ShardedCache[K, V]) -> Int64 {
  let mut total : Int64 = 0L
  for shard in self.shards {
    total = total + shard.inner().size()
  }
  total
}

///|
/// The total weight held across all shards, as `Cache::weight` adds it up.
pub fn[K, V] ShardedCache::weight(self : ShardedCache[K, V]) -> Int64 {
  let mut total : Int64 = 0L
  for shard in self.shards {
    total = total + shard.inner().weight()
  }
  total
}

///|
/// Sweeps every shard for entries past their deadline, and returns how many went
/// altogether.
pub fn[K : Eq + Hash, V] ShardedCache::purge_expired(
  self : ShardedCache[K, V],
) -> Int64 {
  let mut total : Int64 = 0L
  for shard in self.shards {
    total = total + shard.inner().purge_expired()
  }
  total
}

///|
/// The counters of every shard added together.
pub fn[K, V] ShardedCache::stats(
  self : ShardedCache[K, V],
) -> @moonkart.CacheStats {
  let mut total = self.shards[0].inner().stats()
  for i = 1; i < self.shards.length(); i = i + 1 {
    total = total.merge(self.shards[i].inner().stats())
  }
  total
}
