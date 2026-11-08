// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How many times the functions below have really run.
let runs : Ref[Int32] = Ref(0)

///|
/// Something worth remembering. `#kart.cached` leaves it as it is and adds
/// `square_cached` beside it; `#kart.count_calls` adds `square_cached_calls`.
#kart.cached(capacity="16", policy="lru", ttl="60s")
#kart.count_calls
pub fn square(n : Int32) -> Int32 {
  runs.val = runs.val + 1
  n * n
}

///|
/// Several parameters are one key.
#kart.cached
pub fn area(width : Int32, height : Int32) -> Int32 {
  runs.val = runs.val + 1
  width * height
}

///|
/// A value that is worked out once and kept. `#kart.once` takes no arguments and
/// builds no way back, so `banner_once` is the only name it adds.
#kart.once
#kart.count_calls
pub fn banner() -> String {
  "kart no. 128"
}
