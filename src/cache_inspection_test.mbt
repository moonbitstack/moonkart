// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Looking at a cache without changing it, and sweeping out what has died: a
// peek that touches neither the counters nor the eviction order, the value an
// insert displaced, the weight the weigher adds up to, and the purge that
// collects entries nobody will read again.

///|
test "peek answers without counting or reordering" {
  let c = @moonkart.lru_cache(cap=2L)
  c.set(1, "a")
  c.set(2, "b")
  assert_eq(c.peek(1), Some("a"))
  assert_eq(c.peek(3), None)
  // A read of 1 would make 1 the recent entry and push 2 out; a peek must not.
  c.set(3, "c")
  assert_eq(c.contains(1), false)
  assert_eq(c.contains(2), true)
  assert_eq(c.contains(3), true)
  assert_eq(c.stats().hit_count, 0L)
  assert_eq(c.stats().miss_count, 0L)
}

///|
test "peek does not restart a time-to-idle deadline" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.tti(10L), clock=fn() {
    now.val
  })
  c.set(1, "a")
  now.val = 6L
  assert_eq(c.peek(1), Some("a"))
  // A read at 6 would carry the deadline to 16; the peek left it at 10.
  now.val = 11L
  assert_eq(c.peek(1), None)
}

///|
test "peek drops an expired entry and says why" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let reasons : Array[String] = []
  let c = @moonkart.lru_cache(
    cap=4L,
    expiry=@moonkart.ttl(5L),
    clock=fn() { now.val },
    removal_listener=fn(_k : Int32, _v : String, reason) {
      reasons.push(
        match reason {
          Capacity => "capacity"
          Expired => "expired"
          Explicit => "explicit"
          Replaced => "replaced"
        },
      )
    },
  )
  c.set(1, "a")
  now.val = 5L
  assert_eq(c.peek(1), None)
  assert_eq(c.size(), 0L)
  assert_eq(reasons, ["expired"])
}

///|
test "insert hands back the value it displaced" {
  let c = @moonkart.lru_cache(cap=4L)
  assert_eq(c.insert(1, "a"), None)
  assert_eq(c.insert(1, "b"), Some("a"))
  assert_eq(c.get(1), Some("b"))
  assert_eq(c.size(), 1L)
}

///|
test "insert keeps the deadline it was given" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, clock=fn() { now.val })
  let _ = c.insert(1, "a", expire_after=10L)
  assert_eq(c.entry(1).expire_at, Some(10L))
  now.val = 10L
  assert_eq(c.contains(1), false)
}

///|
test "insert reports a replacement to the listener like a set does" {
  let gone : Array[String] = []
  let c = @moonkart.lru_cache(cap=4L, removal_listener=fn(
    _k : Int32,
    value : String,
    reason,
  ) {
    let why = match reason {
      Capacity => "capacity"
      Expired => "expired"
      Explicit => "explicit"
      Replaced => "replaced"
    }
    gone.push("\{value}:\{why}")
  })
  let _ = c.insert(1, "a")
  let _ = c.insert(1, "b")
  assert_eq(gone, ["a:replaced"])
}

///|
test "weight adds up what the weigher says" {
  let c = @moonkart.lru_cache(max_weight=100L, weigher=fn(
    _k : String,
    value : String,
  ) {
    value.length().to_int64()
  })
  c.set("a", "123")
  c.set("b", "12345")
  assert_eq(c.weight(), 8L)
  // A replacement spends the new weight, not the sum of both.
  c.set("a", "1")
  assert_eq(c.weight(), 6L)
  assert_eq(c.size(), 2L)
}

///|
test "weight counts one per entry when nothing weighs them" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set("a", 1)
  c.set("b", 2)
  assert_eq(c.weight(), 2L)
  assert_eq(c.weight(), c.size())
}

///|
test "purge_expired collects only what has died" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let gone : Array[Int32] = []
  let c = @moonkart.lru_cache(cap=8L, clock=fn() { now.val }, removal_listener=fn(
    key : Int32,
    _v : String,
    reason,
  ) {
    match reason {
      Expired => gone.push(key)
      _ => ()
    }
  })
  c.set(1, "a", expire_after=5L)
  c.set(2, "b", expire_after=50L)
  c.set(3, "c")
  now.val = 10L
  assert_eq(c.purge_expired(), 1L)
  assert_eq(c.purge_expired(), 0L)
  assert_eq(gone, [1])
  assert_eq(c.size(), 2L)
  assert_eq(c.contains(2), true)
  assert_eq(c.contains(3), true)
  // A sweep is not a read: it neither hits nor misses.
  assert_eq(c.stats().hit_count, 0L)
  assert_eq(c.stats().miss_count, 0L)
}

///|
test "purge_expired leaves the policy able to fill the cache again" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=2L, clock=fn() { now.val })
  c.set(1, "a", expire_after=5L)
  c.set(2, "b", expire_after=5L)
  now.val = 10L
  assert_eq(c.purge_expired(), 2L)
  assert_eq(c.policy_size(), 0)
  c.set(3, "c")
  c.set(4, "d")
  assert_eq(c.size(), 2L)
  assert_eq(c.contains(3), true)
  assert_eq(c.contains(4), true)
}
