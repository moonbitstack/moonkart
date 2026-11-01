// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A clock returns the current time in nanoseconds. The cache never reads the
/// wall clock itself; every timestamp it compares comes from a clock the caller
/// supplies, so expiry and load timing stay deterministic under test.
pub type Clock = () -> Int64

///|
/// Weighs a value so the cache can bound total weight instead of entry count.
/// Return a positive number; the cache treats the result as the entry's weight
/// and evicts by weight when a maximum weight is set.
pub type Weigher[K, V] = (K, V) -> Int64

///|
/// Receives every entry the cache removes, together with the reason it left.
pub type RemovalListener[K, V] = (K, V, EvictionReason) -> Unit

///|
/// Why an entry left the cache.
pub(all) enum EvictionReason {
  /// The cache was full and this entry was chosen to leave.
  Capacity
  /// The entry's live time or idle time elapsed.
  Expired
  /// The caller removed the entry explicitly.
  Explicit
  /// A newer value for the same key replaced this one.
  Replaced
}

///|
/// Per-entry lifetime policy. Each callback returns an absolute nanosecond
/// deadline, or `None` to leave the existing deadline untouched (when the
/// callback does not apply) or to let the entry live until capacity eviction
/// (on create). `after_read` and `after_update` receive the current deadline so
/// they can extend or keep it.
///
/// A pure time-to-live from creation uses `ttl`; a time-to-idle (idle) lifetime
/// uses `tti`; anything else is expressed with `expire_after_create` and friends.
pub struct Expiry[K, V] {
  after_create : (K, V, Int64) -> Int64?
  after_read : (K, V, Int64, Int64?) -> Int64?
  after_update : (K, V, Int64, Int64?) -> Int64?
}

///|
/// Time-to-live measured from creation: the entry expires `duration`
/// nanoseconds after it is written and is not refreshed by reads.
pub fn[K, V] ttl(duration : Int64) -> Expiry[K, V] {
  {
    after_create: fn(_ : K, _ : V, now : Int64) { Some(now + duration) },
    after_read: fn(_ : K, _ : V, _ : Int64, cur : Int64?) { cur },
    after_update: fn(_ : K, _ : V, _ : Int64, cur : Int64?) { cur },
  }
}

///|
/// Time-to-idle: the entry expires `duration` nanoseconds after its most recent
/// read or write.
pub fn[K, V] tti(duration : Int64) -> Expiry[K, V] {
  {
    after_create: fn(_ : K, _ : V, now : Int64) { Some(now + duration) },
    after_read: fn(_ : K, _ : V, now : Int64, _ : Int64?) {
      Some(now + duration)
    },
    after_update: fn(_ : K, _ : V, now : Int64, _ : Int64?) {
      Some(now + duration)
    },
  }
}

///|
/// Counters the cache keeps while it runs.
pub struct CacheStats {
  mut hit_count : Int64
  mut miss_count : Int64
  mut eviction_count : Int64
  mut eviction_weight : Int64
  mut load_success_count : Int64
  mut load_failure_count : Int64
  mut total_load_time : Int64
}

///|
/// An entry as seen by a reader: its value, weight and absolute expiry
/// deadline (if any).
pub struct Entry[K, V] {
  key : K
  value : V
  weight : Int64
  expire_at : Int64?
}

///|
/// The default clock, built from the runtime clock in milliseconds. Callers may
/// pass their own clock to make expiry deterministic.
pub let system_clock : Clock = fn() {
  @env.now().reinterpret_as_int64() * 1_000_000
}
