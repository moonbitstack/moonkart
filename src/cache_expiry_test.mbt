// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A write may carry its own deadline. These tests pin the three things that
// makes true: the deadline is the caller's, a read does not move it however the
// cache's rule would have, and writing the entry again without one hands it
// back to the rule.

///|
test "a write can outrank the cache's expiry rule" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.ttl(100L), clock=fn() {
    now.val
  })
  c.set(1, "default")
  c.set(2, "short", expire_after=10L)
  assert_eq(c.entry(1).expire_at, Some(100L))
  assert_eq(c.entry(2).expire_at, Some(10L))
  now.val = 11L
  assert_eq(c.contains(1), true)
  assert_eq(c.contains(2), false)
}

///|
test "a fixed deadline is not moved by a read" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.tti(100L), clock=fn() {
    now.val
  })
  c.set(1, "v", expire_after=10L)
  now.val = 5L
  // An idle timeout would push the deadline to 105 here.
  assert_eq(c.get(1), Some("v"))
  assert_eq(c.entry(1).expire_at, Some(10L))
  now.val = 11L
  assert_eq(c.contains(1), false)
}

///|
test "writing again without a duration returns the entry to the rule" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.tti(50L), clock=fn() {
    now.val
  })
  c.set(1, "a", expire_after=10L)
  assert_eq(c.entry(1).expire_at, Some(10L))
  // The rewrite goes through the cache's rule again, and reads move it again.
  c.set(1, "b")
  assert_eq(c.entry(1).expire_at, Some(50L))
  now.val = 30L
  assert_eq(c.get(1), Some("b"))
  assert_eq(c.entry(1).expire_at, Some(80L))
}

///|
test "a plain rewrite keeps the deadline time-to-live set at creation" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.ttl(50L), clock=fn() {
    now.val
  })
  c.set(1, "a", expire_after=10L)
  c.set(1, "b")
  assert_eq(c.entry(1).expire_at, Some(10L))
}

///|
test "a loaded value takes the duration of the call" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.ttl(1_000L), clock=fn() {
    now.val
  })
  let loader = @moonkart.infallible_loader(fn(id : Int32) { id * 10 })
  assert_eq(c.get_with(3, loader, expire_after=20L), 30)
  assert_eq(c.entry(3).expire_at, Some(20L))
  assert_eq(
    c.try_get_with(
      4,
      @moonkart.infallible_loader(fn(id : Int32) { Some(id * 10) }),
      expire_after=30L,
    ),
    Some(40),
  )
  assert_eq(c.entry(4).expire_at, Some(30L))
  now.val = 21L
  assert_eq(c.contains(3), false)
  assert_eq(c.contains(4), true)
}

///|
test "a fixed deadline survives the entry being read on a plain cache" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, clock=fn() { now.val })
  c.set(1, "v", expire_after=5L)
  assert_eq(c.get(1), Some("v"))
  assert_eq(c.entry(1).expire_at, Some(5L))
  now.val = 5L
  assert_eq(c.contains(1), false)
}

///|
test "panic set refuses a duration that is not positive" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a", expire_after=0L)
}
