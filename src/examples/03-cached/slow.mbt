// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How many times `square` has really run.
let runs : Ref[Int32] = Ref(0)

///|
/// Something worth remembering. `#kart.cached` leaves it as it is and adds
/// `square_cached` beside it.
#kart.cached(capacity="16", policy="lru", ttl="60s")
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
