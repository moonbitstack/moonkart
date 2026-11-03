// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
async test "async set and get round-trip" {
  let cache : @concurrent.AsyncCache[Int32, String] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=4L),
  )
  cache.set(1, "a")
  assert_eq(cache.get(1), Some("a"))
  assert_eq(cache.inner().size(), 1L)
}

///|
async test "concurrent loads for one key run the loader once" {
  let calls : Array[Int32] = [0]
  let cache : @concurrent.AsyncCache[Int32, Int32] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=8L),
  )
  let loader = async fn(k : Int32) -> Int32 {
    calls[0] = calls[0] + 1
    @async.pause()
    k * 2
  }
  let results = @async.all([
    async fn() { cache.get_with(1, loader) catch { _ => -1 } },
    async fn() { cache.get_with(1, loader) catch { _ => -1 } },
    async fn() { cache.get_with(1, loader) catch { _ => -1 } },
  ])
  assert_eq(results[0], 2)
  assert_eq(results[1], 2)
  assert_eq(results[2], 2)
  assert_eq(calls[0], 1)
}

///|
suberror LoadFailed

///|
async test "a failing load reaches every waiter and is not cached" {
  let calls : Array[Int32] = [0]
  let cache : @concurrent.AsyncCache[Int32, Int32] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=8L),
  )
  let loader = async fn(_k : Int32) -> Int32 {
    calls[0] = calls[0] + 1
    @async.pause()
    raise LoadFailed
  }
  let results = @async.all([
    async fn() { Some(cache.get_with(1, loader)) catch { _ => None } },
    async fn() { Some(cache.get_with(1, loader)) catch { _ => None } },
    async fn() { Some(cache.get_with(1, loader)) catch { _ => None } },
  ])
  assert_eq(results[0], None)
  assert_eq(results[1], None)
  assert_eq(results[2], None)
  assert_eq(calls[0], 1)
  assert_eq(cache.get(1), None)
}

///|
async test "different keys are not serialised behind one load" {
  let cache : @concurrent.AsyncCache[Int32, Int32] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=8L),
  )
  let pair = @async.all([
    async fn() {
      cache.get_with(1, async fn(_k) {
        @async.pause()
        10
      })
    },
    async fn() {
      cache.get_with(2, async fn(_k) {
        @async.pause()
        20
      })
    },
  ])
  assert_eq(pair[0], 10)
  assert_eq(pair[1], 20)
  assert_eq(cache.get(1), Some(10))
  assert_eq(cache.get(2), Some(20))
}

///|
async test "try_get_with does not cache None" {
  let calls : Array[Int32] = [0]
  let cache : @concurrent.AsyncCache[Int32, Int32] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=8L),
  )
  let loader = async fn(_k : Int32) -> Int32? {
    calls[0] = calls[0] + 1
    @async.pause()
    None
  }
  assert_eq(cache.try_get_with(1, loader), None)
  assert_eq(cache.try_get_with(1, loader), None)
  assert_eq(calls[0], 2)
  assert_eq(cache.get(1), None)
}
