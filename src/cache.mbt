// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Internal mutable state. The cache is a handle: every method receives a copy
/// of the struct but the copy shares this single heap state through a `Ref`, so
/// counters and entries accumulate across calls.
priv struct State[K, V] {
  policy : &@policy.Policy
  weigher : Weigher[K, V]?
  clock : Clock
  expiry : Expiry[K, V]?
  removal_listener : RemovalListener[K, V]?
  entries : @hashmap.HashMap[K, Slot[V]]
  id_to_key : @hashmap.HashMap[Int64, K]
  mut next_id : Int64
  stats : CacheStats
}

///|
priv struct Slot[V] {
  id : Int64
  value : V
  weight : Int64
  expire_at : Int64?
  /// The caller fixed this deadline on the write, so no rule may move it.
  fixed : Bool
}

///|
/// A bounded cache generic over key `K` and value `V`. The eviction strategy is
/// erased behind the open `Policy` contract, so one `Cache` type serves every
/// strategy; [`new`] accepts a third-party policy without changing this type.
///
/// The default strategy, chosen by [`tinylfu_cache`], is W-TinyLFU; [`lru_cache`]
/// and [`s3fifo_cache`] provide the other shipped strategies.
pub struct Cache[K, V] {
  priv state : Ref[State[K, V]]
}

///|
fn[K : Eq + Hash, V] build(
  policy : &@policy.Policy,
  weigher : Weigher[K, V]?,
  clock : Clock,
  expiry : Expiry[K, V]?,
  removal_listener : RemovalListener[K, V]?,
) -> Cache[K, V] {
  {
    state: @ref.Ref({
      policy,
      weigher,
      clock,
      expiry,
      removal_listener,
      entries: @hashmap.HashMap([]),
      id_to_key: @hashmap.HashMap([]),
      next_id: 1,
      stats: {
        hit_count: 0,
        miss_count: 0,
        eviction_count: 0,
        eviction_weight: 0,
        load_success_count: 0,
        load_failure_count: 0,
        total_load_time: 0,
      },
    }),
  }
}

///|
/// Builds a cache from a policy and a [`Config`] bundle.
pub fn[K : Eq + Hash, V] new_with_config(
  policy : &@policy.Policy,
  config : Config[K, V],
) -> Cache[K, V] {
  build(
    policy,
    config.weigher,
    config.clock,
    config.expiry,
    config.removal_listener,
  )
}

///|
/// Builds a cache from a policy and the individual knobs. Capacity belongs to
/// the policy: pass `cap` or `max_weight` to the policy preset, not here.
pub fn[K : Eq + Hash, V] new(
  policy : &@policy.Policy,
  weigher? : Weigher[K, V],
  clock~ : Clock = system_clock,
  expiry? : Expiry[K, V],
  removal_listener? : RemovalListener[K, V],
) -> Cache[K, V] {
  build(policy, weigher, clock, expiry, removal_listener)
}

///|
/// A cache that evicts least-recently-used entries.
pub fn[K : Eq + Hash, V] lru_cache(
  cap? : Int64,
  max_weight? : Int64,
  weigher? : Weigher[K, V],
  clock~ : Clock = system_clock,
  expiry? : Expiry[K, V],
  removal_listener? : RemovalListener[K, V],
) -> Cache[K, V] {
  new(
    @policy.new_lru(cap?, max_weight?),
    weigher?,
    clock~,
    expiry?,
    removal_listener?,
  )
}

///|
/// A cache using the S3-FIFO-inspired second-chance FIFO: entries that were read
/// since they entered get another round before eviction, which resists scan and
/// one-hit-wonder patterns.
pub fn[K : Eq + Hash, V] s3fifo_cache(
  cap? : Int64,
  max_weight? : Int64,
  weigher? : Weigher[K, V],
  clock~ : Clock = system_clock,
  expiry? : Expiry[K, V],
  removal_listener? : RemovalListener[K, V],
) -> Cache[K, V] {
  new(
    @policy.new_s3fifo(cap?, max_weight?),
    weigher?,
    clock~,
    expiry?,
    removal_listener?,
  )
}

///|
/// A cache using W-TinyLFU (the default): a small admission window feeds a
/// frequency-guarded segmented LRU, so frequently used entries survive even
/// after they age out of recency.
pub fn[K : Eq + Hash, V] tinylfu_cache(
  cap? : Int64,
  max_weight? : Int64,
  window_ratio~ : Double = @policy.tinylfu_window_ratio,
  protected_ratio~ : Double = @policy.tinylfu_protected_ratio,
  weigher? : Weigher[K, V],
  clock~ : Clock = system_clock,
  expiry? : Expiry[K, V],
  removal_listener? : RemovalListener[K, V],
) -> Cache[K, V] {
  new(
    @policy.new_tinylfu(cap?, max_weight?, window_ratio~, protected_ratio~),
    weigher?,
    clock~,
    expiry?,
    removal_listener?,
  )
}

///|
fn[K, V] notify(
  s : State[K, V],
  key : K,
  value : V,
  reason : EvictionReason,
) -> Unit {
  match s.removal_listener {
    Some(f) => f(key, value, reason)
    None => ()
  }
}

///|
fn[K : Eq + Hash, V] remove_slot(
  st : Ref[State[K, V]],
  key : K,
  slot : Slot[V],
  reason : EvictionReason,
) -> Unit {
  ignore(st.val.entries.remove(key))
  ignore(st.val.id_to_key.remove(slot.id))
  st.val.policy.forget(slot.id)
  notify(st.val, key, slot.value, reason)
}

///|
fn[K : Eq + Hash, V] process_evicted(
  st : Ref[State[K, V]],
  evicted : Array[Int64],
  self_id : Int64,
) -> Bool {
  let mut refused = false
  for e in evicted {
    if e == self_id {
      refused = true
    } else {
      match st.val.id_to_key.get(e) {
        Some(k) => {
          match st.val.entries.get(k) {
            Some(slot) => {
              st.val.stats.eviction_count += 1
              st.val.stats.eviction_weight += slot.weight
              notify(st.val, k, slot.value, Capacity)
            }
            None => ()
          }
          ignore(st.val.entries.remove(k))
          ignore(st.val.id_to_key.remove(e))
        }
        None => ()
      }
    }
  }
  refused
}

///|
fn[K : Eq + Hash, V] refresh_read(
  st : Ref[State[K, V]],
  key : K,
  slot : Slot[V],
  now : Int64,
) -> Unit {
  // A deadline the caller fixed on the write outranks the cache's rule.
  if slot.fixed {
    return
  }
  match st.val.expiry {
    Some(e) => {
      let ne = (e.after_read)(key, slot.value, now, slot.expire_at)
      ignore(
        st.val.entries.set(key, {
          id: slot.id,
          value: slot.value,
          weight: slot.weight,
          expire_at: ne,
          fixed: false,
        }),
      )
    }
    None => ()
  }
}

///|
/// Inserts or replaces `key`. A replaced value is reported to the removal
/// listener as `Replaced`; an insertion calls `after_update` when the key was
/// already present, otherwise `after_create`.
///
/// `expire_after` fixes this entry's deadline at `expire_after` nanoseconds from
/// now, for this write only: the cache's own rule does not apply to it, and a
/// later read will not move the deadline it computed. Write the entry again
/// without it to hand the entry back to the cache's rule.
pub fn[K : Eq + Hash, V] Cache::set(
  self : Cache[K, V],
  key : K,
  value : V,
  expire_after? : Int64,
) -> Unit {
  let st = self.state
  let now = (st.val.clock)()
  let weight = match st.val.weigher {
    Some(w) => w(key, value)
    None => 1
  }
  let previous = st.val.entries.get(key)
  let expire_at = match expire_after {
    Some(ns) => {
      guard ns > 0L else {
        abort(
          "moonkart: set: expire_after must be a positive number of nanoseconds",
        )
      }
      Some(now + ns)
    }
    None =>
      match previous {
        Some(old) =>
          match st.val.expiry {
            Some(e) => (e.after_update)(key, value, now, old.expire_at)
            None => None
          }
        None =>
          match st.val.expiry {
            Some(e) => (e.after_create)(key, value, now)
            None => None
          }
      }
  }
  match previous {
    Some(old) => {
      ignore(st.val.id_to_key.remove(old.id))
      st.val.policy.forget(old.id)
      notify(st.val, key, old.value, Replaced)
    }
    None => ()
  }
  let id = st.val.next_id
  st.val.next_id = st.val.next_id + 1
  ignore(
    st.val.entries.set(key, {
      id,
      value,
      weight,
      expire_at,
      fixed: expire_after is Some(_),
    }),
  )
  ignore(st.val.id_to_key.set(id, key))
  let evicted = st.val.policy.admit(id, weight, Hash::hash(key))
  let refused = process_evicted(st, evicted, id)
  if refused {
    ignore(st.val.entries.remove(key))
    ignore(st.val.id_to_key.remove(id))
  }
}

///|
/// Returns the value for `key`, or `None` if absent or expired. A successful
/// read counts a hit and bumps the entry's recency; an expired or missing read
/// counts a miss.
pub fn[K : Eq + Hash, V] Cache::get(self : Cache[K, V], key : K) -> V? {
  let st = self.state
  let now = (st.val.clock)()
  match st.val.entries.get(key) {
    None => {
      st.val.stats.miss_count += 1
      None
    }
    Some(slot) =>
      match slot.expire_at {
        Some(exp) =>
          if now >= exp {
            remove_slot(st, key, slot, Expired)
            st.val.stats.miss_count += 1
            None
          } else {
            refresh_read(st, key, slot, now)
            st.val.stats.hit_count += 1
            st.val.policy.hit(slot.id, Hash::hash(key))
            Some(slot.value)
          }
        None => {
          refresh_read(st, key, slot, now)
          st.val.stats.hit_count += 1
          st.val.policy.hit(slot.id, Hash::hash(key))
          Some(slot.value)
        }
      }
  }
}

///|
/// Whether `key` is present and not expired. Expired entries are purged and
/// report as absent. This is a presence check: it neither refreshes a
/// time-to-idle deadline nor counts a hit.
pub fn[K : Eq + Hash, V] Cache::contains(self : Cache[K, V], key : K) -> Bool {
  let st = self.state
  let now = (st.val.clock)()
  match st.val.entries.get(key) {
    None => false
    Some(slot) =>
      match slot.expire_at {
        Some(exp) =>
          if now >= exp {
            remove_slot(st, key, slot, Expired)
            false
          } else {
            true
          }
        None => true
      }
  }
}

///|
/// Returns a snapshot of the entry for `key`, or `None`. The snapshot is a copy
/// detached from the cache.
pub fn[K : Eq + Hash, V] Cache::entry_or_null(
  self : Cache[K, V],
  key : K,
) -> Entry[K, V]? {
  let st = self.state
  let now = (st.val.clock)()
  match st.val.entries.get(key) {
    None => None
    Some(slot) =>
      match slot.expire_at {
        Some(exp) =>
          if now >= exp {
            remove_slot(st, key, slot, Expired)
            None
          } else {
            Some({
              key,
              value: slot.value,
              weight: slot.weight,
              expire_at: slot.expire_at,
            })
          }
        None =>
          Some({
            key,
            value: slot.value,
            weight: slot.weight,
            expire_at: slot.expire_at,
          })
      }
  }
}

///|
/// Returns a snapshot of the entry for `key`. Panics if the key is absent or
/// expired; prefer `entry_or_null` when absence is expected.
pub fn[K : Eq + Hash, V] Cache::entry(
  self : Cache[K, V],
  key : K,
) -> Entry[K, V] {
  match self.entry_or_null(key) {
    Some(e) => e
    None => abort("moonkart: entry: key not present")
  }
}

///|
/// Removes `key` explicitly. Returns whether it was present.
pub fn[K : Eq + Hash, V] Cache::remove(self : Cache[K, V], key : K) -> Bool {
  let st = self.state
  match st.val.entries.get(key) {
    None => false
    Some(slot) => {
      remove_slot(st, key, slot, Explicit)
      true
    }
  }
}

///|
/// Removes `key` explicitly (alias of `remove`). Returns whether it was present.
pub fn[K : Eq + Hash, V] Cache::invalidate(self : Cache[K, V], key : K) -> Bool {
  self.remove(key)
}

///|
/// Removes every entry, reporting each to the removal listener as `Explicit`.
pub fn[K : Eq + Hash, V] Cache::invalidate_all(self : Cache[K, V]) -> Unit {
  let st = self.state
  let pairs = st.val.entries.to_array()
  for p in pairs {
    let k = p.0
    match st.val.entries.get(k) {
      Some(slot) => remove_slot(st, k, slot, Explicit)
      None => ()
    }
  }
}

///|
/// Removes every entry for which `pred(key, value)` is true. Returns the number
/// removed.
pub fn[K : Eq + Hash, V] Cache::invalidate_if(
  self : Cache[K, V],
  pred : (K, V) -> Bool,
) -> Int64 {
  let st = self.state
  let pairs = st.val.entries.to_array()
  let mut count : Int64 = 0
  for p in pairs {
    let k = p.0
    let v = p.1.value
    if pred(k, v) {
      match st.val.entries.get(k) {
        Some(slot) => {
          remove_slot(st, k, slot, Explicit)
          count += 1
        }
        None => ()
      }
    }
  }
  count
}

///|
/// A copy of the running counters.
pub fn[K, V] Cache::stats(self : Cache[K, V]) -> CacheStats {
  self.state.val.stats
}

///|
/// Number of entries currently stored.
pub fn[K, V] Cache::size(self : Cache[K, V]) -> Int64 {
  self.state.val.entries.length().to_int64()
}

///|
/// Number of entries the eviction policy currently tracks (equals `size`).
pub fn[K, V] Cache::policy_size(self : Cache[K, V]) -> Int32 {
  self.state.val.policy.size()
}

///|
/// A snapshot of every live entry as `(key, value)` pairs, in no particular
/// order. Useful for persistence and for tests.
pub fn[K, V] Cache::to_array(self : Cache[K, V]) -> Array[(K, V)] {
  self.state.val.entries.to_array().map(fn(p) { (p.0, p.1.value) })
}

///|
/// Adapts an infallible loader to the raising loader type [`get_with`] and
/// [`try_get_with`] accept. Use it when producing a value cannot fail, so the
/// call site needs no error handling while still sharing one read path.
#warnings("-unused_error_type")
pub fn[K, V] infallible_loader(loader : (K) -> V) -> (K) -> V raise {
  fn(k) raise { loader(k) }
}

///|
/// Returns the value for `key`. On a miss, runs `loader(key)` and stores the
/// result. The loader may raise; a raised error is not cached, is counted as a
/// load failure, and is handed to the caller unchanged. `expire_after` does to
/// the loaded value what it does to [`set`].
pub fn[K : Eq + Hash, V, E : Error] Cache::get_with(
  self : Cache[K, V],
  key : K,
  loader : (K) -> V raise E,
  expire_after? : Int64,
) -> V raise E {
  match self.get(key) {
    Some(v) => v
    None => {
      let st = self.state
      let start = (st.val.clock)()
      errdefer {
        st.val.stats.load_failure_count += 1
      }
      let value = loader(key)
      let end = (st.val.clock)()
      st.val.stats.total_load_time += end - start
      st.val.stats.load_success_count += 1
      self.set(key, value, expire_after?)
      value
    }
  }
}

///|
/// Like `get_with`, but `loader` may return `None` to signal "no value"; such a
/// result is not cached and `None` is returned. A raised error propagates to the
/// caller and is counted as a load failure.
pub fn[K : Eq + Hash, V, E : Error] Cache::try_get_with(
  self : Cache[K, V],
  key : K,
  loader : (K) -> V? raise E,
  expire_after? : Int64,
) -> V? raise E {
  match self.get(key) {
    Some(v) => Some(v)
    None => {
      let st = self.state
      let start = (st.val.clock)()
      errdefer {
        st.val.stats.load_failure_count += 1
      }
      match loader(key) {
        Some(value) => {
          let end = (st.val.clock)()
          st.val.stats.total_load_time += end - start
          st.val.stats.load_success_count += 1
          self.set(key, value, expire_after?)
          Some(value)
        }
        None => {
          st.val.stats.load_failure_count += 1
          None
        }
      }
    }
  }
}
