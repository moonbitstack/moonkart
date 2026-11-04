// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Runs every snippet the guide shows, so the page can quote real output.
fn main raise {
  let cache = @moonkart.tinylfu_cache(cap=1000)
  cache.set("user:42", "Ada")
  match cache.get("user:42") {
    Some(name) => println("read user:42 -> \{name}")
    None => println("read user:42 -> nothing")
  }

  let by_weight = @moonkart.lru_cache(max_weight=12L, weigher=fn(
    _k : String,
    v : String,
  ) {
    Int64::from_int(v.length())
  })
  by_weight.set("a", "three")
  by_weight.set("b", "four")
  by_weight.set("c", "five")
  println(
    "a=\{by_weight.contains("a")} b=\{by_weight.contains("b")} c=\{by_weight.contains("c")}",
  )

  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let timed = @moonkart.lru_cache(cap=8L, expiry=@moonkart.ttl(10L), clock=fn() {
    now.val
  })
  timed.set("k", "v")
  println("at t=0:  \{timed.contains("k")}")
  now.val = 11L
  println("at t=11: \{timed.contains("k")}")

  let loaded = @moonkart.lru_cache(cap=8L)
  let calls : @ref.Ref[Int32] = @ref.Ref(0)
  let first = loaded.get_with("user:7", fn(_k) raise {
    calls.val = calls.val + 1
    if calls.val > 9 {
      fail("too many calls")
    }
    "Grace"
  })
  let second = loaded.get_with("user:7", fn(_k) raise {
    calls.val = calls.val + 1
    if calls.val > 9 {
      fail("too many calls")
    }
    "Grace"
  })
  println("\{first} then \{second}, loader ran \{calls.val} time(s)")

  let failing : @moonkart.Cache[String, String] = @moonkart.lru_cache(cap=8L)
  let mut failed = false
  let _ = failing.get_with("x", fn(_k) raise { fail("no such row") }) catch {
    _ => {
      failed = true
      ""
    }
  }
  println("failed load -> error=\{failed}; stored=\{failing.contains("x")}")

  let s = cache.stats()
  println("hits \{s.hit_count}, misses \{s.miss_count}")
}
