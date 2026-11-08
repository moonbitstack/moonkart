// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Remembered functions. `slow.g.mbt` is generated from `slow.mbt` by `cmd/cached`; a
/// project wires the generator as a dev_build rule (see the README).
///
///     moon run src/examples/03-cached
fn main {
  println(square_cached(4))
  println(square_cached(4))
  println(
    "square ran \{runs.val} time, and the cache counted \{square_cached_calls()}",
  )

  println(area_cached(2, 3))
  println(area_cached(2, 3))
  println("both ran \{runs.val} times")

  square_cached_clear()
  println(square_cached(4))
  println("cleared, so \{runs.val} times in all")

  println(banner_once())
  println(banner_once())
  println("banner ran \{banner_once_calls()} time")
}
