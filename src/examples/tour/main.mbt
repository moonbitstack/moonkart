// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The whole surface in one run: capacity, hits, eviction and stats.
///
///     moon run src/examples/tour
#coverage.skip
fn main {
  let cache = @moonkart.lru_cache(cap=2L)
  cache.set("a", 1)
  cache.set("b", 2)
  println("a is present: \{cache.contains("a")}")
  match cache.get("a") {
    Some(v) => println("read a: \{v}")
    None => println("read a: none")
  }
  // The read above made "a" the most recent, so writing a third entry now
  // evicts "b" instead of "a".
  cache.set("c", 3)
  println("b survives: \{cache.contains("b")}")
  println("c is present: \{cache.contains("c")}")
  let stats = cache.stats()
  println("hits: \{stats.hit_count}, misses: \{stats.miss_count}")
  println("evictions: \{stats.eviction_count}")
}
