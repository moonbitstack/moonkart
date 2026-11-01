// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Behavioural tests for the cache. Every test drives the public API only, so a
// regression in any internal block (capacity, expiry, eviction, loading,
// invalidation, events, stats) shows up here.

///|
test "lru evicts the least recently used entry" {
  let c = @moonkart.lru_cache(cap=2L)
  c.set(1, "one")
  c.set(2, "two")
  c.set(3, "three")
  assert_eq(c.size(), 2L)
  assert_eq(c.contains(1), false)
  assert_eq(c.get(2), Some("two"))
  assert_eq(c.get(3), Some("three"))
  assert_eq(c.stats().eviction_count, 1L)
}

///|
test "lru honours recency on eviction" {
  let c = @moonkart.lru_cache(cap=2L)
  c.set(1, "one")
  c.set(2, "two")
  assert_eq(c.get(1), Some("one"))
  // 1 is now the most recent, so 2 is evicted.
  c.set(3, "three")
  assert_eq(c.contains(2), false)
  assert_eq(c.contains(1), true)
  assert_eq(c.contains(3), true)
}

///|
test "set replaces a value in place" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a")
  c.set(1, "b")
  assert_eq(c.size(), 1L)
  assert_eq(c.get(1), Some("b"))
}

///|
test "remove reports presence and drops the entry" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a")
  assert_eq(c.remove(1), true)
  assert_eq(c.remove(1), false)
  assert_eq(c.contains(1), false)
  assert_eq(c.size(), 0L)
}

///|
test "ttl expires an entry after its deadline" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let clock = fn() { now.val }
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.ttl(100L), clock~)
  c.set(1, "a")
  now.val = 50L
  assert_eq(c.get(1), Some("a"))
  now.val = 150L
  assert_eq(c.contains(1), false)
}

///|
test "ttl is not extended by reads" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let clock = fn() { now.val }
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.ttl(100L), clock~)
  c.set(1, "a")
  now.val = 50L
  assert_eq(c.get(1), Some("a"))
  now.val = 120L
  assert_eq(c.contains(1), false)
}

///|
test "tti is extended by reads" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let clock = fn() { now.val }
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.tti(100L), clock~)
  c.set(1, "a")
  now.val = 60L
  assert_eq(c.get(1), Some("a"))
  // Last access at 60, so the entry lives to 160.
  now.val = 150L
  assert_eq(c.contains(1), true)
  now.val = 200L
  assert_eq(c.contains(1), false)
}

///|
test "expiry reports Expired to the removal listener" {
  let last : @ref.Ref[String] = @ref.Ref("")
  let record = fn(_k : Int32, _v : String, r : @moonkart.EvictionReason) {
    last.val = match r {
      Capacity => "capacity"
      Expired => "expired"
      Explicit => "explicit"
      Replaced => "replaced"
    }
  }
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let clock = fn() { now.val }
  let c = @moonkart.lru_cache(
    cap=4L,
    expiry=@moonkart.ttl(10L),
    clock~,
    removal_listener=record,
  )
  c.set(1, "a")
  now.val = 20L
  ignore(c.get(1))
  assert_eq(last.val, "expired")
}

///|
test "capacity eviction reports Capacity" {
  let last : @ref.Ref[String] = @ref.Ref("")
  let record = fn(_k : Int32, _v : String, r : @moonkart.EvictionReason) {
    last.val = match r {
      Capacity => "capacity"
      Expired => "expired"
      Explicit => "explicit"
      Replaced => "replaced"
    }
  }
  let c = @moonkart.lru_cache(cap=1L, removal_listener=record)
  c.set(1, "a")
  c.set(2, "b")
  assert_eq(last.val, "capacity")
}

///|
test "explicit removal reports Explicit" {
  let last : @ref.Ref[String] = @ref.Ref("")
  let record = fn(_k : Int32, _v : String, r : @moonkart.EvictionReason) {
    last.val = match r {
      Capacity => "capacity"
      Expired => "expired"
      Explicit => "explicit"
      Replaced => "replaced"
    }
  }
  let c = @moonkart.lru_cache(cap=4L, removal_listener=record)
  c.set(1, "a")
  ignore(c.remove(1))
  assert_eq(last.val, "explicit")
}

///|
test "replacing reports Replaced" {
  let last : @ref.Ref[String] = @ref.Ref("")
  let record = fn(_k : Int32, _v : String, r : @moonkart.EvictionReason) {
    last.val = match r {
      Capacity => "capacity"
      Expired => "expired"
      Explicit => "explicit"
      Replaced => "replaced"
    }
  }
  let c = @moonkart.lru_cache(cap=4L, removal_listener=record)
  c.set(1, "a")
  c.set(1, "b")
  assert_eq(last.val, "replaced")
}

///|
test "a weigher bounds the cache by weight" {
  let weigher = fn(_k : String, v : String) { Int64::from_int(v.length()) }
  let c = @moonkart.lru_cache(max_weight=5L, weigher~)
  c.set("a", "12")
  c.set("b", "34")
  c.set("c", "56")
  assert_eq(c.size(), 2L)
  assert_eq(c.contains("a"), false)
  assert_eq(c.contains("b"), true)
  assert_eq(c.contains("c"), true)
}

///|
test "get_with loads on a miss and caches the result" {
  let calls : @ref.Ref[Int32] = @ref.Ref(0)
  let loader = fn(k : Int32) {
    calls.val = calls.val + 1
    k * 10
  }
  let c = @moonkart.lru_cache(cap=4L)
  assert_eq(c.get_with(3, loader), 30)
  assert_eq(calls.val, 1)
  assert_eq(c.get_with(3, loader), 30)
  assert_eq(calls.val, 1)
  assert_eq(c.stats().load_success_count, 1L)
}

///|
test "try_get_with does not cache a miss" {
  let loader = fn(_k : Int32) -> Int32? { None }
  let c = @moonkart.lru_cache(cap=4L)
  assert_eq(c.try_get_with(1, loader), None)
  assert_eq(c.contains(1), false)
  assert_eq(c.stats().load_failure_count, 1L)
}

///|
test "invalidate_all empties the cache" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a")
  c.set(2, "b")
  c.set(3, "c")
  c.invalidate_all()
  assert_eq(c.size(), 0L)
  assert_eq(c.contains(1), false)
}

///|
test "invalidate_if removes only matching entries" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a")
  c.set(2, "bb")
  c.set(3, "ccc")
  let removed = c.invalidate_if(fn(_k, v) { v.length() > 1 })
  assert_eq(removed, 2L)
  assert_eq(c.contains(1), true)
  assert_eq(c.contains(2), false)
  assert_eq(c.contains(3), false)
}

///|
test "entry_or_null returns a detached snapshot" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a")
  match c.entry_or_null(1) {
    Some(e) => {
      assert_eq(e.key, 1)
      assert_eq(e.value, "a")
      assert_eq(e.weight, 1L)
    }
    None => abort("expected an entry")
  }
  match c.entry_or_null(9) {
    Some(_) => abort("expected no entry")
    None => ()
  }
}

///|
test "panic entry on a missing key" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a")
  ignore(c.entry(404))
}

///|
test "stats count hits and misses" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a")
  ignore(c.get(1))
  ignore(c.get(2))
  let s = c.stats()
  assert_eq(s.hit_count, 1L)
  assert_eq(s.miss_count, 1L)
}

///|
test "s3fifo respects capacity" {
  let c = @moonkart.s3fifo_cache(cap=2L)
  c.set(1, "a")
  c.set(2, "b")
  c.set(3, "c")
  assert_eq(c.size(), 2L)
  assert_eq(c.contains(1), false)
  assert_eq(c.contains(3), true)
}

///|
test "s3fifo gives a read entry a second chance" {
  let c = @moonkart.s3fifo_cache(cap=2L)
  c.set(1, "a")
  c.set(2, "b")
  ignore(c.get(1))
  c.set(3, "c")
  assert_eq(c.contains(1), true)
  assert_eq(c.contains(2), false)
  assert_eq(c.contains(3), true)
}

///|
test "tinylfu keeps its size under a large workload" {
  let c = @moonkart.tinylfu_cache(cap=8L)
  for i = 0; i < 200; i = i + 1 {
    c.set(i, i)
  }
  assert_eq(c.size() <= 8L, true)
}

///|
test "tinylfu protects a hot entry against a scan" {
  let c = @moonkart.tinylfu_cache(cap=16L)
  c.set(-1, 0)
  for _i = 0; _i < 40; _i = _i + 1 {
    ignore(c.get(-1))
  }
  for i = 0; i < 100; i = i + 1 {
    c.set(i, i)
  }
  assert_eq(c.contains(-1), true)
}

///|
test "new_with_config mirrors the direct constructor" {
  let cfg : @moonkart.Config[Int32, Int32] = @moonkart.default_config()
  let c = @moonkart.new_with_config(@policy.new_lru(cap=2L), cfg)
  c.set(1, 10)
  c.set(2, 20)
  c.set(3, 30)
  assert_eq(c.size(), 2L)
  assert_eq(c.contains(1), false)
}

///|
test "policy_size tracks the stored entries" {
  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a")
  c.set(2, "b")
  c.set(3, "c")
  assert_eq(c.policy_size(), 3)
  assert_eq(c.policy_size(), c.size().to_int())
}
