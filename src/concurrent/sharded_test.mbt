// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A sharded cache is a partition, not a second cache. These tests pin what the
// partition buys: each shard evicts only inside itself, one key's loaders are
// still coalesced, and what the caller reads back is the shards added together.

///|
fn pick_keys(
  cache : @concurrent.ShardedCache[Int32, String],
  per_shard : Int32,
) -> Array[Array[Int32]] {
  let picked : Array[Array[Int32]] = []
  for i = 0; i < cache.shards(); i = i + 1 {
    picked.push([])
  }
  let mut key = 0
  while key < 4000 {
    let shard = cache.shard_of(key)
    if picked[shard].length() < per_shard {
      picked[shard].push(key)
    }
    key = key + 1
  }
  picked
}

///|
async test "a shard evicts inside itself only" {
  let cache : @concurrent.ShardedCache[Int32, String] = @concurrent.ShardedCache::new(
    shards=4,
    make=fn(_index) { @moonkart.lru_cache(cap=2L) },
  )
  let picked = pick_keys(cache, 3)
  for shard in picked {
    for key in shard {
      cache.set(key, "v\{key}")
    }
  }
  // Three writes into a two-entry shard: the first one in leaves, four times.
  assert_eq(cache.size(), 8L)
  for shard in picked {
    assert_eq(cache.get(shard[0]), None)
    assert_eq(cache.get(shard[1]), Some("v\{shard[1]}"))
    assert_eq(cache.get(shard[2]), Some("v\{shard[2]}"))
  }
}

///|
async test "waiters on one key share a load whatever shard it is in" {
  let calls : Array[Int32] = [0]
  let cache : @concurrent.ShardedCache[Int32, Int32] = @concurrent.ShardedCache::new(
    shards=4,
    make=fn(_index) { @moonkart.lru_cache(cap=8L) },
  )
  let loader = async fn(key : Int32) -> Int32 {
    calls[0] = calls[0] + 1
    @async.pause()
    key * 2
  }
  let results = @async.all([
    async fn() { cache.get_with(7, loader) },
    async fn() { cache.get_with(7, loader) },
    async fn() { cache.get_with(7, loader) },
  ])
  assert_eq(results[0], 14)
  assert_eq(results[1], 14)
  assert_eq(results[2], 14)
  assert_eq(calls[0], 1)
  assert_eq(cache.get(7), Some(14))
}

///|
async test "the counters and the size are the shards added together" {
  let cache : @concurrent.ShardedCache[Int32, String] = @concurrent.ShardedCache::new(
    shards=3,
    make=fn(_index) { @moonkart.tinylfu_cache(cap=4L) },
  )
  cache.set(1, "a")
  cache.set(2, "b")
  ignore(cache.get(1))
  ignore(cache.get(3))
  let stats = cache.stats()
  assert_eq(stats.hit_count, 1L)
  assert_eq(stats.miss_count, 1L)
  assert_eq(cache.size(), 2L)
}

///|
async test "a key is removed from the one shard that holds it" {
  let cache : @concurrent.ShardedCache[Int32, String] = @concurrent.ShardedCache::new(
    shards=4,
    make=fn(_index) { @moonkart.lru_cache(cap=8L) },
  )
  cache.set(1, "a")
  cache.set(2, "b")
  assert_eq(cache.invalidate(1), true)
  assert_eq(cache.invalidate(1), false)
  assert_eq(cache.get(1), None)
  assert_eq(cache.get(2), Some("b"))
  cache.invalidate_all()
  assert_eq(cache.size(), 0L)
}

///|
test "panic new refuses a cache with no shards" {
  let _ : @concurrent.ShardedCache[Int32, Int32] = @concurrent.ShardedCache::new(
    shards=0,
    make=fn(_index) { @moonkart.lru_cache(cap=1L) },
  )
}

///|
async test "a peek and a presence check land in the right shard and change nothing" {
  let cache : @concurrent.ShardedCache[Int32, String] = @concurrent.ShardedCache::new(
    shards=4,
    make=fn(_index) { @moonkart.lru_cache(cap=8L) },
  )
  cache.set(1, "a")
  assert_eq(cache.peek(1), Some("a"))
  assert_eq(cache.contains(1), true)
  assert_eq(cache.contains(2), false)
  assert_eq(cache.stats().hit_count, 0L)
  assert_eq(cache.stats().miss_count, 0L)
  assert_eq(cache.weight(), 1L)
}

///|
async test "a sweep across the shards counts what it removed" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let cache : @concurrent.ShardedCache[Int32, String] = @concurrent.ShardedCache::new(
    shards=2,
    make=fn(index) {
      // Shard 0 keeps its entries for five ticks, shard 1 for fifty.
      @moonkart.lru_cache(
        cap=8L,
        expiry=@moonkart.ttl(if index == 0 { 5L } else { 50L }),
        clock=fn() { now.val },
      )
    },
  )
  // One key per shard, so the count is a sum and not one shard's answer twice.
  let mut short = 0
  while cache.shard_of(short) != 0 {
    short = short + 1
  }
  let mut long = short
  while cache.shard_of(long) != 1 {
    long = long + 1
  }
  cache.set(short, "a")
  cache.set(long, "b")
  now.val = 10L
  assert_eq(cache.size(), 2L)
  assert_eq(cache.purge_expired(), 1L)
  assert_eq(cache.size(), 1L)
  assert_eq(cache.contains(short), false)
  assert_eq(cache.contains(long), true)
}
