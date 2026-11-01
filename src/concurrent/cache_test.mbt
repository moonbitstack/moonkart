// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
async test "async set and get round-trip" {
  let cache : @concurrent.AsyncCache[Int32, String, @policy.Lru] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=4L),
  )
  cache.set(1, "a")
  assert_eq(cache.get(1), Some("a"))
  assert_eq(cache.inner().size(), 1L)
}

///|
async test "concurrent loads for one key run the loader once" {
  let calls : Array[Int32] = [0]
  let cache : @concurrent.AsyncCache[Int32, Int32, @policy.Lru] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=8L),
  )
  let loader = async fn(k : Int32) -> Int32 {
    calls[0] = calls[0] + 1
    @async.pause()
    k * 2
  }
  let results = @async.all([
    async fn() { cache.get_with(1, loader) },
    async fn() { cache.get_with(1, loader) },
    async fn() { cache.get_with(1, loader) },
  ])
  assert_eq(results[0], 2)
  assert_eq(results[1], 2)
  assert_eq(results[2], 2)
  assert_eq(calls[0], 1)
}
