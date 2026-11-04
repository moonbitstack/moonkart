// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Runs every snippet the guide shows, so the page can quote real output.
fn main raise {
  let cache = @moonkart.tinylfu_cache(cap=1000)
  cache.set("user:128", "Leo")
  match cache.get("user:128") {
    Some(name) => println("read user:128 -> \{name}")
    None => println("read user:128 -> nothing")
  }

  let by_weight = @moonkart.lru_cache(max_weight=12L, weigher=fn(
    _k : String,
    v : String,
  ) {
    Int64::from_int(v.length())
  })
  by_weight.set("foo", ".foo{}")
  by_weight.set("emm", ".emm{}")
  by_weight.set("bar", ".bar{}")
  println(
    "foo=\{by_weight.contains("foo")} emm=\{by_weight.contains("emm")} bar=\{by_weight.contains("bar")}",
  )

  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let timed = @moonkart.lru_cache(cap=8L, expiry=@moonkart.ttl(10L), clock=fn() {
    now.val
  })
  timed.set("user:7", "Vega")
  println("at t=0:  \{timed.contains("user:7")}")
  now.val = 11L
  println("at t=11: \{timed.contains("user:7")}")

  let loaded = @moonkart.lru_cache(cap=8L)
  let calls : @ref.Ref[Int32] = @ref.Ref(0)
  let first = loaded.get_with("user:128", fn(_k) raise {
    calls.val = calls.val + 1
    if calls.val > 9 {
      fail("too many calls")
    }
    "Leo"
  })
  let second = loaded.get_with("user:128", fn(_k) raise {
    calls.val = calls.val + 1
    if calls.val > 9 {
      fail("too many calls")
    }
    "Leo"
  })
  println("\{first} then \{second}, loader ran \{calls.val} time(s)")

  let failing : @moonkart.Cache[String, String] = @moonkart.lru_cache(cap=8L)
  let mut failed = false
  let _ = failing.get_with("class:foo", fn(_k) raise { fail("no such rule") }) catch {
    _ => {
      failed = true
      ""
    }
  }
  println(
    "failed load -> error=\{failed}; stored=\{failing.contains("class:foo")}",
  )

  let s = cache.stats()
  println("hits \{s.hit_count}, misses \{s.miss_count}")
}
