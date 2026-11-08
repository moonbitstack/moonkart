// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The parts of the interface a caller configures rather than calls: what a
// presence check may and may not do, how the counters are derived, how a custom
// expiry rule and a hand-built config reach the cache.

///|
test "contains is a presence check, not a read" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.tti(10L), clock=fn() {
    now.val
  })
  c.set("k", "v")
  now.val = 6L
  assert_eq(c.contains("k"), true)
  // A read at 6 would push the deadline to 16; a presence check leaves it at 10.
  now.val = 11L
  assert_eq(c.contains("k"), false)
  assert_eq(c.stats().hit_count, 0L)
  assert_eq(c.stats().miss_count, 0L)
}

///|
test "contains purges an expired entry and reports it" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let reasons : Array[String] = []
  let c = @moonkart.lru_cache(
    cap=4L,
    expiry=@moonkart.ttl(10L),
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
  now.val = 10L
  assert_eq(c.contains(1), false)
  assert_eq(c.size(), 0L)
  assert_eq(reasons, ["expired"])
}

///|
test "entry_or_null reports an expired entry as absent" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.ttl(5L), clock=fn() {
    now.val
  })
  c.set(1, "a")
  match c.entry_or_null(1) {
    Some(entry) => assert_eq(entry.expire_at, Some(5L))
    None => abort("expected a live entry")
  }
  now.val = 5L
  assert_eq(c.entry_or_null(1) is None, true)
  assert_eq(c.remove(1), false)
}

///|
test "the rates are derived from the two counts" {
  let empty : @moonkart.Cache[Int32, String] = @moonkart.lru_cache(cap=4L)
  assert_eq(empty.stats().hit_rate(), 0.0)
  assert_eq(empty.stats().miss_rate(), 0.0)

  let c = @moonkart.lru_cache(cap=4L)
  c.set(1, "a")
  ignore(c.get(1))
  ignore(c.get(1))
  ignore(c.get(2))
  let s = c.stats()
  assert_eq(s.hit_count, 2L)
  assert_eq(s.miss_count, 1L)
  assert_eq(s.hit_rate(), 2.0 / 3.0)
  assert_eq(s.miss_rate(), 1.0 / 3.0)
}

///|
test "a load is timed with the clock the cache was given" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, clock=fn() { now.val })
  let loader = @moonkart.infallible_loader(fn(k : Int32) {
    now.val = now.val + 1_000L
    k * 2
  })
  assert_eq(c.get_with(5, loader), 10)
  let s = c.stats()
  assert_eq(s.total_load_time, 1_000L)
  assert_eq(s.load_success_count, 1L)
  assert_eq(s.load_failure_count, 0L)
  // A hit does not run the loader, so the timing does not move.
  assert_eq(c.get_with(5, loader), 10)
  assert_eq(c.stats().total_load_time, 1_000L)
}

///|
test "a loader that answers None is counted as a failed load" {
  let c : @moonkart.Cache[Int32, Int32] = @moonkart.lru_cache(cap=4L)
  let loader = fn(_k : Int32) -> Int32? { None }
  assert_eq(c.try_get_with(1, @moonkart.infallible_loader(loader)), None)
  assert_eq(c.stats().load_failure_count, 1L)
  assert_eq(c.stats().load_success_count, 0L)
  assert_eq(c.contains(1), false)
}

///|
test "to_array lists every live entry with its value" {
  let c = @moonkart.lru_cache(cap=8L)
  c.set(1, "a")
  c.set(2, "b")
  c.set(3, "c")
  ignore(c.remove(2))
  let pairs = c.to_array()
  assert_eq(pairs.length(), 2)
  assert_eq(pairs.contains((1, "a")), true)
  assert_eq(pairs.contains((3, "c")), true)
  assert_eq(pairs.contains((2, "b")), false)
}

///|
test "invalidate_if counts what it removed and says why" {
  let reasons : Array[String] = []
  let c = @moonkart.lru_cache(cap=8L, removal_listener=fn(
    _k : Int32,
    _v : String,
    reason,
  ) {
    reasons.push(
      match reason {
        Capacity => "capacity"
        Expired => "expired"
        Explicit => "explicit"
        Replaced => "replaced"
      },
    )
  })
  c.set(1, "a")
  c.set(2, "bb")
  c.set(3, "ccc")
  assert_eq(c.invalidate_if(fn(_k, v) { v.length() > 1 }), 2L)
  assert_eq(c.size(), 1L)
  assert_eq(reasons, ["explicit", "explicit"])
  assert_eq(c.invalidate_if(fn(_k, _v) { true }), 1L)
  assert_eq(c.size(), 0L)
}

///|
test "an expiry rule built by the caller reaches the cache" {
  let expiry : @moonkart.Expiry[Int32, String] = {
    // Only even keys expire, and a read extends the deadline by the same span.
    after_create: fn(k, _v, now) {
      if k % 2 == 0 {
        Some(now + 10L)
      } else {
        None
      }
    },
    after_read: fn(_k, _v, now, current) {
      match current {
        Some(_) => Some(now + 10L)
        None => None
      }
    },
    after_update: fn(_k, _v, _now, current) { current },
  }
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=8L, expiry~, clock=fn() { now.val })
  c.set(1, "odd")
  c.set(2, "even")
  assert_eq(c.entry(1).expire_at, None)
  assert_eq(c.entry(2).expire_at, Some(10L))
  now.val = 8L
  ignore(c.get(2))
  assert_eq(c.entry(2).expire_at, Some(18L))
  now.val = 19L
  assert_eq(c.contains(2), false)
  assert_eq(c.contains(1), true)
}

///|
test "a config record built by the caller reaches the cache" {
  let cfg : @moonkart.Config[Int32, String] = {
    weigher: Some(fn(_k, v) { v.length().to_int64() }),
    clock: fn() { 100L },
    expiry: Some(@moonkart.ttl(10L)),
    removal_listener: None,
  }
  let c = @moonkart.new_with_config(@policy.new_lru(max_weight=4L), cfg)
  c.set(1, "abc")
  assert_eq(c.entry(1).weight, 3L)
  assert_eq(c.entry(1).expire_at, Some(110L))
  c.set(2, "de")
  c.set(3, "fg")
  // Six units in a four-unit box: the oldest entry leaves.
  assert_eq(c.size(), 2L)
  assert_eq(c.contains(1), false)
}

///|
test "an entry is gone at its deadline, not after it" {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry=@moonkart.ttl(10L), clock=fn() {
    now.val
  })
  c.set(1, "a")
  now.val = 9L
  assert_eq(c.get(1), Some("a"))
  // A deadline is the first instant the entry is no longer live.
  now.val = 10L
  assert_eq(c.get(1), None)
}

///|
test "an update goes through after_update, not after_create" {
  let expiry : @moonkart.Expiry[Int32, String] = {
    after_create: fn(_k, _v, now) { Some(now + 100L) },
    after_read: fn(_k, _v, _now, current) { current },
    // An update leaves the entry without a deadline at all.
    after_update: fn(_k, _v, _now, _current) { None },
  }
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let c = @moonkart.lru_cache(cap=4L, expiry~, clock=fn() { now.val })
  c.set(1, "a")
  assert_eq(c.entry(1).expire_at, Some(100L))
  c.set(1, "b")
  assert_eq(c.entry(1).expire_at, None)
  assert_eq(c.get(1), Some("b"))
}
