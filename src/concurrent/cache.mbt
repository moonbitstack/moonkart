// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// An asynchronous handle around a cache. Loads are coalesced per key: while one
/// task is computing a value for a key, other tasks asking for the same key wait
/// for that computation instead of starting their own; tasks asking for other
/// keys never wait on it.
///
/// No lock is held while the loader runs. The only shared mutable state is the
/// in-flight table, whose reads and writes are synchronous, so under the
/// cooperative scheduler they never interleave. The first task to miss records a
/// per-key `Lazy`, releases the scheduler by awaiting it, and the loader runs
/// outside any shared critical section.
pub struct AsyncCache[K, V] {
  priv inner : @moonkart.Cache[K, V]
  priv in_flight : Ref[@hashmap.HashMap[K, @async.Lazy[Result[V, Error]]]]
  priv in_flight_opt : Ref[@hashmap.HashMap[K, @async.Lazy[Result[V?, Error]]]]
}

///|
/// Wraps a cache so it can be used from asynchronous code.
pub fn[K : Eq + Hash, V] AsyncCache::new(
  inner : @moonkart.Cache[K, V],
) -> AsyncCache[K, V] {
  {
    inner,
    in_flight: @ref.Ref(@hashmap.HashMap([])),
    in_flight_opt: @ref.Ref(@hashmap.HashMap([])),
  }
}

///|
/// The synchronous cache underneath, for callers that already hold it.
pub fn[K, V] AsyncCache::inner(
  self : AsyncCache[K, V],
) -> @moonkart.Cache[K, V] {
  self.inner
}

///|
/// Reads `key`, or `None`.
pub fn[K : Eq + Hash, V] AsyncCache::get(
  self : AsyncCache[K, V],
  key : K,
) -> V? {
  self.inner.get(key)
}

///|
/// Inserts or replaces `key`.
pub fn[K : Eq + Hash, V] AsyncCache::set(
  self : AsyncCache[K, V],
  key : K,
  value : V,
) -> Unit {
  self.inner.set(key, value)
}

///|
/// Returns the value for `key`. On a miss, runs `loader(key)` and stores the
/// result. Concurrent calls for the same key share one loader run; a loader that
/// raises is not cached and its error is handed to every waiter. Different keys
/// proceed independently.
pub async fn[K : Eq + Hash, V] AsyncCache::get_with(
  self : AsyncCache[K, V],
  key : K,
  loader : async (K) -> V,
) -> V {
  match self.inner.get(key) {
    Some(v) => v
    None =>
      // No `await` between the lookup and the insert, so the cooperative
      // scheduler makes the miss path atomic.
      match self.in_flight.val.get(key) {
        Some(pending) =>
          match pending.wait() {
            Ok(v) => v
            Err(e) => raise e
          }
        None => {
          let pending : @async.Lazy[Result[V, Error]] = @async.Lazy(async fn() {
            try {
              let value = loader(key)
              self.inner.set(key, value)
              Ok(value)
            } catch {
              e => Err(e)
            }
          })
          ignore(self.in_flight.val.set(key, pending))
          let result = pending.wait()
          ignore(self.in_flight.val.remove(key))
          match result {
            Ok(v) => v
            Err(e) => raise e
          }
        }
      }
  }
}

///|
/// Like `get_with`, but the loader may return `None` for "no value". `None` is
/// not cached; a raised error is not cached and reaches every waiter.
pub async fn[K : Eq + Hash, V] AsyncCache::try_get_with(
  self : AsyncCache[K, V],
  key : K,
  loader : async (K) -> V?,
) -> V? {
  match self.inner.get(key) {
    Some(v) => Some(v)
    None =>
      match self.in_flight_opt.val.get(key) {
        Some(pending) =>
          match pending.wait() {
            Ok(v) => v
            Err(e) => raise e
          }
        None => {
          let pending : @async.Lazy[Result[V?, Error]] = @async.Lazy(async fn() {
            try {
              match loader(key) {
                Some(value) => {
                  self.inner.set(key, value)
                  Ok(Some(value))
                }
                None => Ok(None)
              }
            } catch {
              e => Err(e)
            }
          })
          ignore(self.in_flight_opt.val.set(key, pending))
          let result = pending.wait()
          ignore(self.in_flight_opt.val.remove(key))
          match result {
            Ok(v) => v
            Err(e) => raise e
          }
        }
      }
  }
}
