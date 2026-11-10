// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Bookkeeping for a second tier: which keys the slower medium holds, how many
// bytes they take, which was read least recently, and how often each has been
// seen. The medium itself is the caller's: a file appends records, browser
// storage writes one entry per key. The tier never reads or writes either; it
// answers which key leaves, and the caller carries that out.

///|
/// Where a medium keeps one record, and how many bytes it takes there. `slot` is
/// the medium's own address: the file tier's offset, or zero for a medium that
/// finds a record by its key.
pub(all) struct Record {
  slot : Int64
  len : Int32
}

///|
/// What a second tier has done since it was opened. `entries` and `bytes`
/// describe the live records, not the size of the medium: a medium that appends
/// keeps the space of superseded and deleted records until it rewrites itself.
pub(all) struct Stats {
  /// Reads answered by the medium and put back into memory.
  mut promotions : Int64
  /// Records dropped for capacity.
  mut evictions : Int64
  /// Records the medium would not hold at all, because they alone exceed the
  /// whole budget.
  mut refused : Int64
  /// Records the value rule turned away in favour of a resident record.
  mut denied : Int64
  /// Live records.
  mut entries : Int64
  /// Bytes those records take.
  mut bytes : Int64
}

///|
/// A hash of a record's encoded bytes, for the frequency sketch. FNV-1a is used
/// rather than the runtime's key hash because it must give the same answer in
/// every process: a sketch fed by a seeded hash ranks the same traffic
/// differently on every start, and a hit rate measured once could not be
/// reproduced.
pub fn hash_of_bytes(view : BytesView) -> Int32 {
  let mut h : Int32 = 0x811c9dc5
  for i = 0; i < view.length(); i = i + 1 {
    h = (h ^ view.at(i).to_int()) * 0x01000193
  }
  h
}

///|
/// The keys a slower medium holds, with the bookkeeping the two-tier caches
/// share: an index of record sizes and addresses, a least-recently-used order,
/// a frequency sketch and a byte budget. Each method that can free room returns
/// the keys to delete from the medium, so the caller keeps the only copy of the
/// medium's own rules.
///
/// Copies of the value share one set of bookkeeping, so a handle can be passed
/// by value.
pub struct Tier[K] {
  priv index : @hashmap.HashMap[K, Record]
  priv order : Lru[K]
  priv hasher : (K) -> Int32
  priv sketch : @ref.Ref[@policy.Sketch]
  priv sketch_keys : @ref.Ref[Int32]
  priv admission : @policy.Admission
  priv max_bytes : Int64
  priv bytes : @ref.Ref[Int64]
  priv stats : @ref.Ref[Stats]
}

///|
/// A tier bounded by `max_bytes`, with `admission` deciding who gets in and
/// `hash` mapping a key to the hash the sketch counts. A budget of zero or less
/// means unbounded: nothing is ever evicted and the sketch stays empty.
pub fn[K : Eq + Hash] Tier::new(
  admission : @policy.Admission,
  max_bytes : Int64,
  hash : (K) -> Int32,
) -> Tier[K] {
  {
    index: @hashmap.HashMap([]),
    order: Lru::new(),
    hasher: hash,
    sketch: @ref.Ref(@policy.Sketch::new(16)),
    sketch_keys: @ref.Ref(16),
    admission,
    max_bytes,
    bytes: @ref.Ref(0),
    stats: @ref.Ref({
      promotions: 0,
      evictions: 0,
      refused: 0,
      denied: 0,
      entries: 0,
      bytes: 0,
    }),
  }
}

///|
/// The byte budget, zero when unbounded.
pub fn[K] Tier::budget(self : Tier[K]) -> Int64 {
  self.max_bytes
}

///|
/// The record held for `key`, if any.
pub fn[K : Eq + Hash] Tier::record_of(self : Tier[K], key : K) -> Record? {
  self.index.get(key)
}

///|
/// Whether the tier holds a record for `key`.
pub fn[K : Eq + Hash] Tier::contains(self : Tier[K], key : K) -> Bool {
  self.index.contains(key)
}

///|
/// A snapshot of the counters.
pub fn[K] Tier::stats(self : Tier[K]) -> Stats {
  let s = self.stats.val
  {
    promotions: s.promotions,
    evictions: s.evictions,
    refused: s.refused,
    denied: s.denied,
    entries: self.index.length().to_int64(),
    bytes: self.bytes.val,
  }
}

///|
/// Bytes the live records take.
pub fn[K] Tier::bytes(self : Tier[K]) -> Int64 {
  self.bytes.val
}

///|
/// How often the key whose record this is has been seen lately, at most 15. The
/// estimate comes from the sketch, so it survives the record leaving and coming
/// back.
pub fn[K] Tier::frequency(self : Tier[K], key : K) -> Int32 {
  self.sketch.val.estimate((self.hasher)(key))
}

///|
/// Counts one sighting of `key`. Called by the paths that use the medium, so the
/// sketch reflects traffic that reached it rather than traffic that only reached
/// memory.
pub fn[K] Tier::record_seen(self : Tier[K], key : K) -> Unit {
  if self.max_bytes <= 0L {
    return
  }
  self.grow(self.index.length())
  self.sketch.val.record((self.hasher)(key))
}

///|
/// Notes that the medium answered a read for `key`: the record counts as recent
/// and the key counts as seen.
pub fn[K : Eq + Hash] Tier::promote(self : Tier[K], key : K) -> Unit {
  if self.index.contains(key) {
    self.order.move_to_back(key)
  }
  self.stats.val.promotions = self.stats.val.promotions + 1L
  self.record_seen(key)
}

///|
/// Indexes a record written to the medium at `slot`, or replaces the record the
/// key already had. Returns the keys whose records the medium must delete once
/// the budget settles. The newcomer is among them when the admission rule turned
/// it away, which is the caller's signal that the record it just wrote must not
/// be replayed as live.
pub fn[K : Eq + Hash] Tier::admit(
  self : Tier[K],
  key : K,
  slot : Int64,
  len : Int32,
) -> Array[K] {
  self.place(key, slot, len)
  self.record_seen(key)
  if self.max_bytes <= 0L || self.bytes.val <= self.max_bytes {
    return []
  }
  let victim = self.order.front()
  let keep = match victim {
    // The newcomer is the only record left, so it stays and the budget is
    // overrun by at most that one record.
    Some(v) if v == key => true
    Some(v) =>
      match self.admission {
        TakeAll => true
        // A tie goes to the newcomer: two records seen equally often are
        // decided by recency, which is what the tier did before it kept
        // frequencies, so turning the sketch on only changes the case it is
        // meant to change.
        ByValue => self.frequency(key) >= self.frequency(v)
      }
    None => true
  }
  if !keep {
    ignore(self.drop(key))
    self.stats.val.denied = self.stats.val.denied + 1L
    // The newcomer is named like any other eviction, so a medium that keeps a
    // log of writes marks the record it just wrote as dead instead of leaving it
    // to be replayed as live.
    return [key]
  }
  let evicted : Array[K] = []
  while self.bytes.val > self.max_bytes {
    let next = match self.order.front() {
      Some(v) if v != key => v
      _ => break
    }
    ignore(self.drop(next))
    evicted.push(next)
    self.stats.val.evictions = self.stats.val.evictions + 1L
  }
  evicted
}

///|
/// Indexes a record read back from the medium, without an admission decision and
/// without counting an eviction: a restore reports what the medium already held.
/// Call [`shrink`] afterwards to bring a medium that is over budget back inside.
pub fn[K : Eq + Hash] Tier::restore(
  self : Tier[K],
  key : K,
  slot : Int64,
  len : Int32,
) -> Unit {
  self.place(key, slot, len)
  self.record_seen(key)
}

///|
/// Forgets `key` and returns its record, if the tier held one. The caller writes
/// the medium's own delete.
pub fn[K : Eq + Hash] Tier::discharge(self : Tier[K], key : K) -> Record? {
  self.drop(key)
}

///|
/// Drops the least recently used records until the budget is met, without asking
/// admission. Returns the keys the medium must delete.
pub fn[K : Eq + Hash] Tier::shrink(self : Tier[K]) -> Array[K] {
  let evicted : Array[K] = []
  if self.max_bytes <= 0L {
    return evicted
  }
  while self.bytes.val > self.max_bytes {
    let victim = match self.order.front() {
      Some(v) => v
      None => break
    }
    ignore(self.drop(victim))
    evicted.push(victim)
    self.stats.val.evictions = self.stats.val.evictions + 1L
  }
  evicted
}

///|
/// Counts a record the medium would not hold at all, because it alone exceeds
/// the budget.
pub fn[K] Tier::note_refused(self : Tier[K]) -> Unit {
  self.stats.val.refused = self.stats.val.refused + 1L
}

///|
/// Every key the tier holds, least recently used first.
pub fn[K : Eq + Hash] Tier::keys(self : Tier[K]) -> Array[K] {
  self.order.to_array()
}

///|
/// Indexes the record and puts the key at the recent end, keeping the byte count
/// straight when the key was already there.
fn[K : Eq + Hash] Tier::place(
  self : Tier[K],
  key : K,
  slot : Int64,
  len : Int32,
) -> Unit {
  match self.index.get(key) {
    Some(old) => self.bytes.val = self.bytes.val - old.len.to_int64()
    None => ()
  }
  ignore(self.index.set(key, { slot, len, }))
  self.order.move_to_back(key)
  self.bytes.val = self.bytes.val + len.to_int64()
}

///|
fn[K : Eq + Hash] Tier::drop(self : Tier[K], key : K) -> Record? {
  match self.index.get(key) {
    None => None
    Some(record) => {
      self.bytes.val = self.bytes.val - record.len.to_int64()
      ignore(self.index.remove(key))
      self.order.remove(key)
      Some(record)
    }
  }
}

///|
/// Sizes the sketch for the records held. Growing resets it, which forgets the
/// history — the alternative is a table that never covers the working set, and a
/// reset costs a few estimates once while the medium fills up.
fn[K] Tier::grow(self : Tier[K], keys : Int32) -> Unit {
  if keys <= self.sketch_keys.val {
    return
  }
  let mut cap = self.sketch_keys.val
  while cap < keys {
    cap = cap * 2
  }
  self.sketch.val = @policy.Sketch::new(cap)
  self.sketch_keys.val = cap
}
