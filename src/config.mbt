// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The cross-cutting knobs of a cache, bundled so they can be built once and
/// reused across caches. Capacity lives on the eviction policy, not here.
///
/// [`default_config`] fills in every knob; write the record out when one of them
/// differs, and hand the result to `new_with_config`.
pub(all) struct Config[K, V] {
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
