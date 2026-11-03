// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Replays `keys` through a fresh cache of `policy` bounded to `cap` entries and
/// returns the hit rate. A miss inserts the key, which is what a read-through
/// cache does; the values are irrelevant to the hit count.
pub fn hit_rate(keys : Array[Int32], policy : String, cap : Int64) -> Double {
  replay_stats(keys, policy, cap).0
}

///|
pub fn replay_stats(
  keys : Array[Int32],
  policy : String,
  cap : Int64,
) -> (Double, Int64, Int32) {
  let cache = make(policy, cap)
  let mut hits = 0L
  for k in keys {
    match cache.get(k) {
      Some(_) => hits = hits + 1L
      None => cache.set(k, ())
    }
  }
  let total = keys.length()
  let rate = if total == 0 { 0.0 } else { hits.to_double() / total.to_double() }
  (rate, cache.size(), cache.policy_size())
}

///|
fn make(policy : String, cap : Int64) -> @moonkart.Cache[Int32, Unit] {
  match policy {
    "lru" => @moonkart.lru_cache(cap~)
    "s3fifo" => @moonkart.s3fifo_cache(cap~)
    _ => @moonkart.tinylfu_cache(cap~)
  }
}
