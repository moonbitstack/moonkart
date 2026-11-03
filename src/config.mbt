// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The cross-cutting knobs of a cache, bundled so they can be built once and
/// reused across caches. Capacity lives on the eviction policy, not here.
///
/// Fields are public so a caller can start from [`default_config`] and change
/// one knob, or build a record by hand.
pub struct Config[K, V] {
  weigher : Weigher[K, V]?
  clock : Clock
  expiry : Expiry[K, V]?
  removal_listener : RemovalListener[K, V]?
}

///|
/// A config with every knob at its default: no weigher (each entry weighs one),
/// the system clock, no expiry, no listener.
pub fn[K, V] default_config() -> Config[K, V] {
  { weigher: None, clock: system_clock, expiry: None, removal_listener: None, }
}
