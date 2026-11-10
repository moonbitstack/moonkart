// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A refresh is measured from the write, so these tests move a clock instead of
// waiting, and they hand the cache a `spawn` that only counts, so a reload
// happens when the test says `settle` and never at a time it hopes for.

///|
/// A cache whose clock the test drives, and whose background reloads the test
/// runs itself.
fn[V] driven_cache(
  now : @ref.Ref[Int64],
  window : Int64,
  spawn : @concurrent.Spawn,
) -> @concurrent.AsyncCache[Int32, V] {
  @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=8L, clock=fn() { now.val }),
    refresh=@concurrent.refresh_every(window),
    spawn~,
  )
}

///|
async test "a value inside its window is not reloaded" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let loads : @ref.Ref[Int32] = @ref.Ref(0)
  let tasks : @ref.Ref[Int32] = @ref.Ref(0)
  let cache = driven_cache(now, 100L, fn(_task) { tasks.val = tasks.val + 1 })
  let loader = async fn(_k : Int32) -> String {
    @async.pause()
    loads.val = loads.val + 1
    "v\{loads.val}"
  }
  assert_eq(cache.get_with(1, loader), "v1")
  now.val = 99L
  assert_eq(cache.get_with(1, loader), "v1")
  cache.settle()
  assert_eq(loads.val, 1)
  assert_eq(tasks.val, 0)
}

///|
async test "a stale value answers at once and is reloaded behind the read" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let loads : @ref.Ref[Int32] = @ref.Ref(0)
  let tasks : @ref.Ref[Int32] = @ref.Ref(0)
  let cache = driven_cache(now, 100L, fn(_task) { tasks.val = tasks.val + 1 })
  let loader = async fn(_k : Int32) -> String {
    @async.pause()
    loads.val = loads.val + 1
    "v\{loads.val}"
  }
  assert_eq(cache.get_with(1, loader), "v1")
  now.val = 100L
  // The read is answered from the stale value: the loader has not run again.
  assert_eq(cache.get_with(1, loader), "v1")
  assert_eq(loads.val, 1)
  assert_eq(tasks.val, 1)
  // The reload the cache handed off is what replaces the value.
  cache.settle()
  assert_eq(loads.val, 2)
  assert_eq(cache.get(1), Some("v2"))
  // The write the reload made restarts the window.
  now.val = 150L
  assert_eq(cache.get_with(1, loader), "v2")
  cache.settle()
  assert_eq(loads.val, 2)
}

///|
async test "a reload that fails keeps the old value and reaches the listener" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let loads : @ref.Ref[Int32] = @ref.Ref(0)
  let failing : @ref.Ref[Bool] = @ref.Ref(false)
  let heard : Array[String] = []
  let cache : @concurrent.AsyncCache[Int32, String] = @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=8L, clock=fn() { now.val }),
    refresh={
      after: Some(100L),
      on_failure: Some(fn(key, _error) { heard.push("key \{key}") }),
    },
    spawn=fn(_task) { () },
  )
  let loader = async fn(_k : Int32) -> String {
    @async.pause()
    loads.val = loads.val + 1
    if failing.val {
      raise LoadFailed
    }
    "v\{loads.val}"
  }
  assert_eq(cache.get_with(1, loader), "v1")
  failing.val = true
  now.val = 100L
  assert_eq(cache.get_with(1, loader), "v1")
  cache.settle()
  assert_eq(loads.val, 2)
  assert_eq(heard, ["key 1"])
  // The old value is still there, and the next reload may still succeed.
  assert_eq(cache.get(1), Some("v1"))
  failing.val = false
  assert_eq(cache.get_with(1, loader), "v1")
  cache.settle()
  assert_eq(loads.val, 3)
  assert_eq(cache.get(1), Some("v3"))
}

///|
async test "one reload per key, however many reads find it stale" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let loads : @ref.Ref[Int32] = @ref.Ref(0)
  let tasks : @ref.Ref[Int32] = @ref.Ref(0)
  let cache = driven_cache(now, 100L, fn(_task) { tasks.val = tasks.val + 1 })
  let loader = async fn(_k : Int32) -> String {
    @async.pause()
    loads.val = loads.val + 1
    "v\{loads.val}"
  }
  assert_eq(cache.get_with(1, loader), "v1")
  now.val = 100L
  assert_eq(cache.get_with(1, loader), "v1")
  assert_eq(cache.get_with(1, loader), "v1")
  assert_eq(cache.get_with(1, loader), "v1")
  assert_eq(tasks.val, 1)
  cache.settle()
  assert_eq(loads.val, 2)
  assert_eq(cache.get(1), Some("v2"))
}

///|
async test "a reload runs in the caller's task group" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let loads : @ref.Ref[Int32] = @ref.Ref(0)
  @async.with_task_group(async fn(group) {
    let cache = @concurrent.AsyncCache::new(
      @moonkart.lru_cache(cap=8L, clock=fn() { now.val }),
      refresh=@concurrent.refresh_every(100L),
      spawn=fn(task) { group.spawn_bg(task) },
    )
    let loader = async fn(_k : Int32) -> String {
      @async.pause()
      loads.val = loads.val + 1
      "v\{loads.val}"
    }
    assert_eq(cache.get_with(1, loader), "v1")
    now.val = 100L
    assert_eq(cache.get_with(1, loader), "v1")
    // Yield until the task the group took on has run the loader; no clock is
    // involved, so the wait is bounded by the scheduler and not by a sleep.
    let mut spins = 0
    while loads.val < 2 && spins < 1_000 {
      @async.pause()
      spins = spins + 1
    }
    assert_eq(loads.val, 2)
    cache.settle()
    assert_eq(cache.get(1), Some("v2"))
  })
}
