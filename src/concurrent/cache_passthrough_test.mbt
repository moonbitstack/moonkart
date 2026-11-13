// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The asynchronous handle is a view of one cache, not a second one: every
// question a caller can ask the cache underneath has to have the same answer
// here, so a caller that only holds the handle is never forced to reach through
// `inner()` for a read, a removal or a counter.

///|
async test "the handle reports what the cache underneath holds" {
  let cache : @concurrent.AsyncCache[Int32, String] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=4L),
  )
  assert_eq(cache.insert(1, "a"), None)
  assert_eq(cache.insert(1, "b"), Some("a"))
  assert_eq(cache.peek(1), Some("b"))
  assert_eq(cache.contains(1), true)
  assert_eq(cache.size(), 1L)
  assert_eq(cache.stats().hit_count, 0L)
  assert_eq(cache.weight(), 1L)
  assert_eq(cache.remove(1), true)
  assert_eq(cache.contains(1), false)
  cache.set(2, "c")
  cache.invalidate_all()
  assert_eq(cache.size(), 0L)
}

///|
async test "a peek through the handle does not count as a read" {
  let cache : @concurrent.AsyncCache[Int32, String] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=4L),
  )
  cache.set(1, "a")
  assert_eq(cache.peek(1), Some("a"))
  assert_eq(cache.stats().hit_count, 0L)
  assert_eq(cache.get(1), Some("a"))
  assert_eq(cache.stats().hit_count, 1L)
}

///|
async test "the handle sweeps expired entries out from underneath" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let cache : @concurrent.AsyncCache[Int32, String] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=4L, clock=fn() { now.val }),
  )
  cache.inner().set(1, "a", expire_after=5L)
  cache.set(2, "b")
  now.val = 5L
  assert_eq(cache.purge_expired(), 1L)
  assert_eq(cache.size(), 1L)
  assert_eq(cache.stats().hit_count + cache.stats().miss_count, 0L)
}
