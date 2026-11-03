// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// `get_with` runs the loader only on a miss; a hit reuses the stored value.
///
///     moon run src/examples/02-loading
#coverage.skip
fn main raise {
  let loads : @ref.Ref[Int32] = @ref.Ref(0)
  let cache = @moonkart.lru_cache(cap=8L)
  let loader = fn(key : String) {
    loads.val = loads.val + 1
    key.length()
  }
  println(
    "first: \{cache.get_with("hello", @moonkart.infallible_loader(loader))}",
  )
  println(
    "second: \{cache.get_with("hello", @moonkart.infallible_loader(loader))}",
  )
  println("loader ran \{loads.val} time(s)")
  let stats = cache.stats()
  println(
    "loads: \{stats.load_success_count}, time: \{stats.total_load_time}ns",
  )
}
