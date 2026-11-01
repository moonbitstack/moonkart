// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// An asynchronous handle around a cache. Loads are coalesced: while one task is
/// computing a value for a key, other tasks asking for the same key wait for
/// that computation instead of starting their own.
///
/// A `Mutex` serialises the fill path. Under MoonBit's cooperative scheduler
/// this is exactly what deduplication needs: the task that wins the lock
/// computes and stores the value, and every later task re-checks the cache under
/// the lock, finds the value and returns it without running a loader.
pub struct AsyncCache[K, V, P] {
  inner : @moonkart.Cache[K, V, P]
  fill : @async.Mutex
}

///|
/// Wraps a cache so it can be used from asynchronous code.
pub fn[K, V, P] AsyncCache::new(
  inner : @moonkart.Cache[K, V, P],
) -> AsyncCache[K, V, P] {
  { inner, fill: @async.Mutex(), }
}

///|
/// The synchronous cache underneath, for callers that already hold it.
pub fn[K, V, P] AsyncCache::inner(
  self : AsyncCache[K, V, P],
) -> @moonkart.Cache[K, V, P] {
  self.inner
}

///|
/// Reads `key`, or `None`.
pub fn[K : Eq + Hash, V, P : @policy.Policy] AsyncCache::get(
  self : AsyncCache[K, V, P],
  key : K,
) -> V? {
  self.inner.get(key)
}

///|
/// Inserts or replaces `key`.
pub async fn[K : Eq + Hash, V, P : @policy.Policy] AsyncCache::set(
  self : AsyncCache[K, V, P],
  key : K,
  value : V,
) -> Unit {
  self.fill.acquire()
  defer self.fill.release()
  self.inner.set(key, value)
}

///|
/// Returns the value for `key`. On a miss, runs `loader(key)` and stores the
/// result. Concurrent calls for the same key wait for the first loader instead
/// of each running their own.
pub async fn[K : Eq + Hash, V, P : @policy.Policy] AsyncCache::get_with(
  self : AsyncCache[K, V, P],
  key : K,
  loader : async (K) -> V,
) -> V {
  match self.inner.get(key) {
    Some(v) => v
    None => {
      self.fill.acquire()
      defer self.fill.release()
      match self.inner.get(key) {
        Some(v) => v
        None => {
          let v = loader(key)
          self.inner.set(key, v)
          v
        }
      }
    }
  }
}
