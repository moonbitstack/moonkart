// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Time-to-live with an injectable clock, so expiry is deterministic and needs
/// no sleeping in tests.
///
///     moon run src/examples/01-expiry
#coverage.skip
fn main {
  let now : @ref.Ref[Int64] = @ref.Ref(0L)
  let clock = fn() { now.val }
  // One second, expressed in nanoseconds.
  let cache = @moonkart.lru_cache(
    cap=4L,
    expiry=@moonkart.ttl(1_000_000_000L),
    clock~,
  )
  cache.set("token", 42)
  println("fresh: \{to_text(cache.get("token"))}")
  // Move the clock two seconds ahead without sleeping.
  now.val = now.val + 2_000_000_000L
  println("after ttl: \{to_text(cache.get("token"))}")
  println("present: \{cache.contains("token")}")
}

///|
fn to_text(value : Int32?) -> String {
  match value {
    Some(v) => "some \{v}"
    None => "none"
  }
}
