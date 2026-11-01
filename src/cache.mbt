// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Internal mutable state. The cache is a handle: every method receives a copy
/// of the struct but the copy shares this single heap state through a `Ref`, so
/// counters and entries accumulate across calls.
pub struct State[K, V, P] {
  policy : P
  max_weight : Int64
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
pub struct Slot[V] {
  id : Int64
  value : V
  weight : Int64
  expire_at : Int64?
}

///|
/// A bounded cache generic over key `K`, value `V` and an eviction `Policy`.
///
/// The default policy is W-TinyLFU (see `tinylfu_cache`); `lru_cache` and
/// `s3fifo_cache` provide the other shipped strategies. Bring your own by
/// implementing the open `Policy` trait from `@moonkart.policy`.
pub struct Cache[K, V, P] {
  state : Ref[State[K, V, P]]
}

///|
/// Bundles the optional knobs of a cache so they can be reused or built once.
pub struct Config[K, V] {
  max_weight : Int64?
  weigher : Weigher[K, V]?
  clock : Clock
  expiry : Expiry[K, V]?
  removal_listener : RemovalListener[K, V]?
}

///|
/// A config with every optional knob left at its default: unbounded, no weigher,
/// the system clock, no expiry, no listener.
pub fn[K, V] default_config() -> Config[K, V] {
  {
    max_weight: None,
    weigher: None,
    clock: system_clock,
    expiry: None,
    removal_listener: None,
  }
}

///|
fn[K : Eq + Hash, V, P] build(
  policy : P,
  max_weight : Int64?,
  weigher : Weigher[K, V]?,
  clock : Clock,
  expiry : Expiry[K, V]?,
  removal_listener : RemovalListener[K, V]?,
) -> Cache[K, V, P] {
  {
    state: @ref.Ref({
      policy,
      max_weight: max_weight.unwrap_or(0),
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
/// Builds a cache from a policy and a config bundle.
pub fn[K : Eq + Hash, V, P] new_with_config(
  policy : P,
  config : Config[K, V],
) -> Cache[K, V, P] {
  build(
    policy,
    config.max_weight,
    config.weigher,
    config.clock,
    config.expiry,
    config.removal_listener,
  )
}

///|
/// Builds a cache from a policy and optional knobs. `max_weight` bounds total
/// weight; when a `weigher` is supplied, pass `max_weight`, otherwise pass
/// `cap` to the policy presets to bound entry count (each entry then weighs
/// one).
pub fn[K : Eq + Hash, V, P] new(
  policy : P,
  max_weight? : Int64,
  weigher? : Weigher[K, V],
  clock~ : Clock = system_clock,
  expiry? : Expiry[K, V],
  removal_listener? : RemovalListener[K, V],
) -> Cache[K, V, P] {
  build(policy, max_weight, weigher, clock, expiry, removal_listener)
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
) -> Cache[K, V, @policy.Lru] {
  let eff = max_weight.unwrap_or(cap.unwrap_or(0))
  build(
    @policy.new_lru(cap?, max_weight?),
    Some(eff),
    weigher,
    clock,
    expiry,
    removal_listener,
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
) -> Cache[K, V, @policy.S3Fifo] {
  let eff = max_weight.unwrap_or(cap.unwrap_or(0))
  build(
    @policy.new_s3fifo(cap?, max_weight?),
    Some(eff),
    weigher,
    clock,
    expiry,
    removal_listener,
  )
}

///|
/// A cache using the W-TinyLFU policy (the default): a small admission window
/// feeds a frequency-guarded segmented LRU, so frequently used entries survive
/// even after they age out of recency.
pub fn[K : Eq + Hash, V] tinylfu_cache(
  cap? : Int64,
  max_weight? : Int64,
  window_ratio~ : Double = 0.01,
  protected_ratio~ : Double = 0.8,
  weigher? : Weigher[K, V],
  clock~ : Clock = system_clock,
  expiry? : Expiry[K, V],
  removal_listener? : RemovalListener[K, V],
) -> Cache[K, V, @policy.Tinylfu] {
  let eff = max_weight.unwrap_or(cap.unwrap_or(0))
  build(
    @policy.new_tinylfu(cap?, max_weight?, window_ratio~, protected_ratio~),
    Some(eff),
    weigher,
    clock,
    expiry,
    removal_listener,
  )
}

///|
fn[K, V, P] notify(
  s : State[K, V, P],
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
fn[K : Eq + Hash, V, P : @policy.Policy] remove_slot(
  st : Ref[State[K, V, P]],
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
fn[K : Eq + Hash, V, P] process_evicted(
  st : Ref[State[K, V, P]],
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
fn[K : Eq + Hash, V, P] refresh_read(
  st : Ref[State[K, V, P]],
  key : K,
  slot : Slot[V],
  now : Int64,
) -> Unit {
  match st.val.expiry {
    Some(e) => {
      let ne = (e.after_read)(key, slot.value, now, slot.expire_at)
      ignore(
        st.val.entries.set(key, {
          id: slot.id,
          value: slot.value,
          weight: slot.weight,
          expire_at: ne,
        }),
      )
    }
    None => ()
  }
}

///|
/// Inserts or replaces `key`. A replaced value is reported to the removal
/// listener as `Replaced`.
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::set(
  self : Cache[K, V, P],
  key : K,
  value : V,
) -> Unit {
  let st = self.state
  let now = (st.val.clock)()
  let weight = match st.val.weigher {
    Some(w) => w(key, value)
    None => 1
  }
  let expire_at = match st.val.expiry {
    Some(e) => (e.after_create)(key, value, now)
    None => None
  }
  match st.val.entries.get(key) {
    Some(slot) => {
      ignore(st.val.id_to_key.remove(slot.id))
      st.val.policy.forget(slot.id)
      notify(st.val, key, slot.value, Replaced)
    }
    None => ()
  }
  let id = st.val.next_id
  st.val.next_id = st.val.next_id + 1
  st.val.entries.set(key, { id, value, weight, expire_at, })
  st.val.id_to_key.set(id, key)
  let evicted = st.val.policy.admit(id, weight)
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
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::get(
  self : Cache[K, V, P],
  key : K,
) -> V? {
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
            st.val.policy.hit(slot.id)
            Some(slot.value)
          }
        None => {
          refresh_read(st, key, slot, now)
          st.val.stats.hit_count += 1
          st.val.policy.hit(slot.id)
          Some(slot.value)
        }
      }
  }
}

///|
/// Whether `key` is present and not expired. Expired entries are purged and
/// report as absent.
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::contains(
  self : Cache[K, V, P],
  key : K,
) -> Bool {
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
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::entry_or_null(
  self : Cache[K, V, P],
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
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::entry(
  self : Cache[K, V, P],
  key : K,
) -> Entry[K, V] {
  match self.entry_or_null(key) {
    Some(e) => e
    None => abort("moonkart: entry: key not present")
  }
}

///|
/// Removes `key` explicitly. Returns whether it was present.
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::remove(
  self : Cache[K, V, P],
  key : K,
) -> Bool {
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
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::invalidate(
  self : Cache[K, V, P],
  key : K,
) -> Bool {
  self.remove(key)
}

///|
/// Removes every entry, reporting each to the removal listener as `Explicit`.
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::invalidate_all(
  self : Cache[K, V, P],
) -> Unit {
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
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::invalidate_if(
  self : Cache[K, V, P],
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
pub fn[K, V, P] Cache::stats(self : Cache[K, V, P]) -> CacheStats {
  self.state.val.stats
}

///|
/// Number of entries currently stored.
pub fn[K, V, P] Cache::size(self : Cache[K, V, P]) -> Int64 {
  Int64::from_int(self.state.val.entries.length())
}

///|
/// Number of entries the eviction policy currently tracks (equals `size`).
pub fn[K, V, P : @policy.Policy] Cache::policy_size(
  self : Cache[K, V, P],
) -> Int32 {
  self.state.val.policy.size()
}

///|
/// A snapshot of every live entry as `(key, value)` pairs, in no particular
/// order. Useful for persistence and for tests.
pub fn[K, V, P] Cache::to_array(self : Cache[K, V, P]) -> Array[(K, V)] {
  self.state.val.entries.to_array().map(fn(p) { (p.0, p.1.value) })
}

///|
fn[K : Eq + Hash, V, P : @policy.Policy] load_value(
  cache : Cache[K, V, P],
  key : K,
  loader : (K) -> V,
) -> V {
  let st = cache.state
  let start = (st.val.clock)()
  let result = loader(key)
  let end = (st.val.clock)()
  st.val.stats.total_load_time += end - start
  st.val.stats.load_success_count += 1
  cache.set(key, result)
  result
}

///|
fn[K : Eq + Hash, V, P : @policy.Policy] load_opt(
  cache : Cache[K, V, P],
  key : K,
  loader : (K) -> V?,
) -> V? {
  let st = cache.state
  let start = (st.val.clock)()
  let result = loader(key)
  let end = (st.val.clock)()
  match result {
    Some(v) => {
      st.val.stats.total_load_time += end - start
      st.val.stats.load_success_count += 1
      cache.set(key, v)
      Some(v)
    }
    None => {
      st.val.stats.load_failure_count += 1
      None
    }
  }
}

///|
/// Returns the value for `key`. On a miss, computes it with `loader(key)`,
/// stores the result and returns it. The loader is never run when the value is
/// already present, which is the common dedupe: repeated reads of a hot key
/// compute nothing after the first miss.
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::get_with(
  self : Cache[K, V, P],
  key : K,
  loader : (K) -> V,
) -> V {
  match self.get(key) {
    Some(v) => v
    None => load_value(self, key, loader)
  }
}

///|
/// Like `get_with`, but `loader` may return `None` to signal "no value"; such a
/// result is not cached and `None` is returned.
pub fn[K : Eq + Hash, V, P : @policy.Policy] Cache::try_get_with(
  self : Cache[K, V, P],
  key : K,
  loader : (K) -> V?,
) -> V? {
  match self.get(key) {
    Some(v) => Some(v)
    None => load_opt(self, key, loader)
  }
}
