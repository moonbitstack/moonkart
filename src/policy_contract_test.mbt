// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The `Policy` contract is open, so a strategy can live outside this library.
// These tests implement one here and drive a cache with it, which is the only
// way to tell an open contract from a closed set of shipped policies. They also
// cover the weighted bounds of the other two policies, which the shipped
// constructors expose but nothing else exercised.

///|
/// A first-in-first-out policy that refuses nothing. Written the way a caller
/// outside the library would write it: it sees only ids and weights.
priv struct Fifo {
  order : Array[Int64]
  cap : Int64
}

///|
impl @policy.Policy for Fifo with fn hit(
  self : Fifo,
  _id : Int64,
  _hash : Int32,
) -> Unit {
  ignore(self)
}

///|
impl @policy.Policy for Fifo with fn admit(
  self : Fifo,
  id : Int64,
  _weight : Int64,
  _hash : Int32,
) -> Array[Int64] {
  self.order.push(id)
  if self.order.length().to_int64() > self.cap {
    [self.order.remove(0)]
  } else {
    []
  }
}

///|
impl @policy.Policy for Fifo with fn forget(self : Fifo, id : Int64) -> Unit {
  for i, v in self.order {
    if v == id {
      ignore(self.order.remove(i))
      break
    }
  }
}

///|
impl @policy.Policy for Fifo with fn size(self : Fifo) -> Int32 {
  self.order.length()
}

///|
test "a policy written outside the library drives the cache" {
  let policy : Fifo = { order: [], cap: 2L, }
  let c = @moonkart.new(policy)
  c.set(1, "a")
  c.set(2, "b")
  c.set(3, "c")
  assert_eq(c.size(), 2L)
  // FIFO order: the first one in is the first one out, and reads change nothing.
  assert_eq(c.contains(1), false)
  assert_eq(c.contains(2), true)
  assert_eq(c.contains(3), true)
  assert_eq(c.policy_size(), 2)
}

///|
test "the cache reports capacity evictions of a foreign policy" {
  let reasons : Array[String] = []
  let policy : Fifo = { order: [], cap: 1L, }
  let c = @moonkart.new(policy, removal_listener=fn(
    key : Int32,
    _v : String,
    reason,
  ) {
    let why = match reason {
      Capacity => "capacity"
      Expired => "expired"
      Explicit => "explicit"
      Replaced => "replaced"
    }
    reasons.push("\{key}:\{why}")
  })
  c.set(1, "a")
  c.set(2, "b")
  assert_eq(reasons, ["1:capacity"])
  assert_eq(c.stats().eviction_count, 1L)
}

///|
test "a foreign policy sees the weight the weigher computed" {
  let policy : Fifo = { order: [], cap: 10L, }
  let c = @moonkart.new(policy, weigher=fn(_k : String, v : String) {
    v.length().to_int64()
  })
  c.set("a", "12345")
  assert_eq(c.entry("a").weight, 5L)
  assert_eq(c.stats().eviction_weight, 0L)
}

///|
test "s3fifo bounds total weight when a weigher is given" {
  let c = @moonkart.s3fifo_cache(max_weight=5L, weigher=fn(
    _k : String,
    v : String,
  ) {
    v.length().to_int64()
  })
  c.set("a", "12")
  c.set("b", "34")
  c.set("c", "56")
  // Six units in a five-unit box: the unread oldest entry leaves.
  assert_eq(c.size(), 2L)
  assert_eq(c.contains("a"), false)
  assert_eq(c.contains("b"), true)
  assert_eq(c.contains("c"), true)
  assert_eq(c.stats().eviction_weight, 2L)
}

///|
test "s3fifo keeps a read entry while the weight is over budget" {
  let c = @moonkart.s3fifo_cache(max_weight=4L, weigher=fn(
    _k : String,
    v : String,
  ) {
    v.length().to_int64()
  })
  c.set("a", "12")
  c.set("b", "34")
  ignore(c.get("a"))
  c.set("c", "56")
  // "a" was read, so it gets a second round and "b" goes instead.
  assert_eq(c.contains("a"), true)
  assert_eq(c.contains("b"), false)
  assert_eq(c.contains("c"), true)
}

///|
test "tinylfu keeps the total weight inside the budget" {
  let c = @moonkart.tinylfu_cache(max_weight=5L, weigher=fn(
    _k : String,
    v : String,
  ) {
    v.length().to_int64()
  })
  for key in ["a", "b", "c", "d", "e", "f"] {
    c.set(key, "12")
  }
  // Two two-unit entries fit in five units; a third would need six, so the
  // admission filter refuses the newcomer rather than break the budget.
  assert_eq(c.size() <= 2L, true)
  let mut held = 0L
  for pair in c.to_array() {
    held = held + c.entry(pair.0).weight
  }
  assert_true(held <= 5L)
}

///|
test "the tinylfu segment ratios are honoured at the boundary" {
  // A policy whose window and protected segment are the whole cache still holds
  // its bound: the ratios only move entries between regions.
  let c = @moonkart.tinylfu_cache(
    cap=16L,
    window_ratio=0.5,
    protected_ratio=0.5,
  )
  for i = 0; i < 64; i = i + 1 {
    c.set(i, i)
  }
  assert_eq(c.size(), 16L)
  assert_eq(Int64::from_int(c.policy_size()), 16L)
}
