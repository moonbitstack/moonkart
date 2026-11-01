// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A pluggable eviction policy. The cache assigns every entry an opaque numeric
/// id and talks to the policy only through ids and weights, so a policy never
/// sees a key or value. Implement this trait of your own type and hand the
/// instance to the cache to use a strategy the library does not ship.
pub(open) trait Policy {
  /// Record a read or write of an entry that is already present.
  fn hit(self : Self, id : Int64) -> Unit
  /// Record admission of a new entry of the given weight and return the ids the
  /// cache must evict. The list may contain `id` itself, which means the entry
  /// was refused and the cache should drop it.
  fn admit(self : Self, id : Int64, weight : Int64) -> Array[Int64]
  /// Forget an entry removed for a reason other than capacity.
  fn forget(self : Self, id : Int64) -> Unit
  /// Number of entries the policy currently tracks.
  fn size(self : Self) -> Int32
}

///|
/// A node of the intrusive doubly linked list used by the LRU-family policies.
pub struct Link {
  prev : Int64
  next : Int64
  weight : Int64
}

///|
/// A doubly linked list keyed by id, with `0` as the empty marker so valid ids
/// (which start at 1) never collide with it. Every mutable piece lives in a
/// `Ref` so that copying the list (for example passing it to a method that
/// takes `self` by value) still mutates the one shared list.
pub struct IntrusiveList {
  head : Ref[Int64]
  tail : Ref[Int64]
  links : @hashmap.HashMap[Int64, Link]
  weight_sum : Ref[Int64]
}

///|
fn new_list() -> IntrusiveList {
  {
    head: @ref.Ref(0),
    tail: @ref.Ref(0),
    links: @hashmap.HashMap([]),
    weight_sum: @ref.Ref(0),
  }
}

///|
fn IntrusiveList::length(self : IntrusiveList) -> Int32 {
  self.links.length()
}

///|
fn IntrusiveList::is_empty(self : IntrusiveList) -> Bool {
  self.links.is_empty()
}

///|
fn IntrusiveList::contains(self : IntrusiveList, id : Int64) -> Bool {
  self.links.contains(id)
}

///|
fn IntrusiveList::weight_of(self : IntrusiveList, id : Int64) -> Int64 {
  match self.links.get(id) {
    Some(l) => l.weight
    None => 0
  }
}

///|
fn IntrusiveList::push_back(
  self : IntrusiveList,
  id : Int64,
  weight : Int64,
) -> Unit {
  self.links.set(id, { prev: self.tail.val, next: 0, weight, })
  if self.tail.val != 0 {
    match self.links.get(self.tail.val) {
      Some(t) =>
        self.links.set(self.tail.val, {
          prev: t.prev,
          next: id,
          weight: t.weight,
        })
      None => ()
    }
  } else {
    self.head.val = id
  }
  self.tail.val = id
  self.weight_sum.val += weight
}

///|
fn IntrusiveList::peek_front(self : IntrusiveList) -> Int64? {
  if self.head.val == 0 {
    None
  } else {
    Some(self.head.val)
  }
}

///|
fn IntrusiveList::pop_front(self : IntrusiveList) -> Int64? {
  if self.head.val == 0 {
    None
  } else {
    let h = self.head.val
    match self.links.get(h) {
      Some(node) => {
        self.head.val = node.next
        if node.next != 0 {
          match self.links.get(node.next) {
            Some(n) =>
              self.links.set(node.next, {
                prev: 0,
                next: n.next,
                weight: n.weight,
              })
            None => ()
          }
        } else {
          self.tail.val = 0
        }
        self.weight_sum.val -= node.weight
        self.links.remove(h)
        Some(h)
      }
      None => None
    }
  }
}

///|
fn IntrusiveList::remove(self : IntrusiveList, id : Int64) -> Unit {
  match self.links.get(id) {
    None => ()
    Some(node) => {
      if node.prev != 0 {
        match self.links.get(node.prev) {
          Some(p) =>
            self.links.set(node.prev, {
              prev: p.prev,
              next: node.next,
              weight: p.weight,
            })
          None => ()
        }
      } else {
        self.head.val = node.next
      }
      if node.next != 0 {
        match self.links.get(node.next) {
          Some(n) =>
            self.links.set(node.next, {
              prev: node.prev,
              next: n.next,
              weight: n.weight,
            })
          None => ()
        }
      } else {
        self.tail.val = node.prev
      }
      self.weight_sum.val -= node.weight
      self.links.remove(id)
    }
  }
}

///|
fn IntrusiveList::move_to_back(self : IntrusiveList, id : Int64) -> Unit {
  match self.links.get(id) {
    Some(node) => {
      let w = node.weight
      self.remove(id)
      self.push_back(id, w)
    }
    None => ()
  }
}

///|
/// Least-recently-used policy: the entry not touched for the longest time
/// leaves first.
pub struct Lru {
  max_weight : Int64
  weight : Ref[Int64]
  order : IntrusiveList
}

///|
/// Creates an LRU policy. Set at most one of `max_weight` (evict by weight) or
/// `cap` (evict by entry count).
pub fn new_lru(cap? : Int64, max_weight? : Int64) -> Lru {
  {
    max_weight: max_weight.unwrap_or(cap.unwrap_or(0)),
    weight: @ref.Ref(0),
    order: new_list(),
  }
}

///|
pub impl Policy for Lru with fn hit(self : Lru, id : Int64) -> Unit {
  self.order.move_to_back(id)
}

///|
pub impl Policy for Lru with fn admit(self : Lru, id : Int64, weight : Int64) -> Array[
  Int64,
] {
  self.order.push_back(id, weight)
  self.weight.val += weight
  let evicted : Array[Int64] = []
  while self.max_weight > 0 && self.weight.val > self.max_weight {
    match self.order.peek_front() {
      Some(v) => {
        let w = self.order.weight_of(v)
        ignore(self.order.pop_front())
        self.weight.val -= w
        evicted.push(v)
      }
      None => break
    }
  }
  evicted
}

///|
pub impl Policy for Lru with fn forget(self : Lru, id : Int64) -> Unit {
  if self.order.contains(id) {
    self.weight.val -= self.order.weight_of(id)
    ignore(self.order.remove(id))
  }
}

///|
pub impl Policy for Lru with fn size(self : Lru) -> Int32 {
  self.order.length()
}

///|
pub extend Lru with Policy::{admit, hit, forget, size}

///|
/// S3-FIFO-inspired second-chance FIFO: a single FIFO queue with a `visited`
/// bit per entry. When the queue is over budget, an entry that has been read
/// since it entered is moved back to the tail with its bit cleared, while an
/// entry never read since it entered is evicted. Scan floods and one-hit
/// wonders are evicted on first sight, while repeated keys survive several
/// rounds, at the cost of one boolean per entry.
pub struct S3Fifo {
  max_weight : Int64
  weight : Ref[Int64]
  q_order : IntrusiveList
  q_weight : @hashmap.HashMap[Int64, Int64]
  q_visited : @hashmap.HashMap[Int64, Bool]
}

///|
/// Creates an S3-FIFO-inspired second-chance FIFO. Bound by `cap` (entry count)
/// or `max_weight` (total weight).
pub fn new_s3fifo(cap? : Int64, max_weight? : Int64) -> S3Fifo {
  let max = max_weight.unwrap_or(cap.unwrap_or(0))
  {
    max_weight: max,
    weight: @ref.Ref(0),
    q_order: new_list(),
    q_weight: @hashmap.HashMap([]),
    q_visited: @hashmap.HashMap([]),
  }
}

///|
pub impl Policy for S3Fifo with fn hit(self : S3Fifo, id : Int64) -> Unit {
  if self.q_weight.contains(id) {
    self.q_visited.set(id, true)
  }
}

///|
pub impl Policy for S3Fifo with fn admit(
  self : S3Fifo,
  id : Int64,
  weight : Int64,
) -> Array[Int64] {
  if self.q_weight.contains(id) {
    let old = self.q_weight.get(id).unwrap_or(0)
    self.weight.val += weight - old
    self.q_weight.set(id, weight)
  } else {
    self.q_order.push_back(id, weight)
    self.q_weight.set(id, weight)
    self.q_visited.set(id, false)
    self.weight.val += weight
  }
  let evicted : Array[Int64] = []
  while self.max_weight > 0 && self.weight.val > self.max_weight {
    if self.q_order.is_empty() {
      break
    }
    match self.q_order.peek_front() {
      Some(vid) => {
        let vw = self.q_weight.get(vid).unwrap_or(0)
        let visited = match self.q_visited.get(vid) {
          Some(b) => b
          None => false
        }
        ignore(self.q_order.pop_front())
        ignore(self.q_weight.remove(vid))
        ignore(self.q_visited.remove(vid))
        self.weight.val -= vw
        if visited {
          self.q_order.push_back(vid, vw)
          self.q_weight.set(vid, vw)
          self.q_visited.set(vid, false)
          self.weight.val += vw
        } else {
          evicted.push(vid)
        }
      }
      None => break
    }
  }
  evicted
}

///|
pub impl Policy for S3Fifo with fn forget(self : S3Fifo, id : Int64) -> Unit {
  if self.q_weight.contains(id) {
    let w = self.q_weight.get(id).unwrap_or(0)
    ignore(self.q_weight.remove(id))
    ignore(self.q_visited.remove(id))
    ignore(self.q_order.remove(id))
    self.weight.val -= w
  }
}

///|
pub impl Policy for S3Fifo with fn size(self : S3Fifo) -> Int32 {
  self.q_order.length()
}

///|
pub extend S3Fifo with Policy::{admit, hit, forget, size}

///|
/// A Count-Min frequency sketch with periodic aging. A small doorkeeper keeps
/// one-hit wonders from polluting the counters.
pub struct Sketch {
  rows : Array[Array[Int32]]
  mask : Int32
  count : Ref[Int32]
  sample_size : Int32
}

///|
let sketch_seeds : Array[Int32] = [
  0x9e3779b1, 0x85ebca77, 0xc2b2ae3d, 0x27d4eb2f,
]

///|
fn new_sketch(capacity : Int32) -> Sketch {
  let width = max2(16, (capacity * 2).next_power_of_two())
  let rows = [
    Array::make(width, 0),
    Array::make(width, 0),
    Array::make(width, 0),
    Array::make(width, 0),
  ]
  {
    rows,
    mask: width - 1,
    count: @ref.Ref(0),
    sample_size: max2(16, capacity * 10),
  }
}

///|
fn Sketch::sketch_increment(self : Sketch, id : Int64) -> Unit {
  let x = id.to_int()
  for i = 0; i < 4; i = i + 1 {
    let idx = (x * sketch_seeds[i]) & self.mask
    self.rows[i][idx] = min2(self.rows[i][idx] + 1, 15)
  }
  self.count.val += 1
}

///|
fn Sketch::sketch_estimate(self : Sketch, id : Int64) -> Int32 {
  let x = id.to_int()
  let mut est = 15
  for i = 0; i < 4; i = i + 1 {
    let idx = (x * sketch_seeds[i]) & self.mask
    est = min2(est, self.rows[i][idx])
  }
  est
}

///|
fn Sketch::sketch_age(self : Sketch) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    let row = self.rows[i]
    for j = 0; j < row.length(); j = j + 1 {
      row[j] = row[j] / 2
    }
  }
  self.count.val = self.count.val / 2
}

///|
/// W-TinyLFU policy: a small admission window feeds a segmented LRU (probation
/// and protected) that is guarded by the frequency sketch, so frequently used
/// entries survive even after they age out of recency. The default for the
/// cache.
pub struct Tinylfu {
  max_weight : Int64
  window_max : Int64
  probation_max : Int64
  protected_max : Int64
  weight : Ref[Int64]
  window : IntrusiveList
  probation : IntrusiveList
  protected_list : IntrusiveList
  sketch : Sketch
  doorkeeper : @hashmap.HashMap[Int64, Unit]
}

///|
/// Creates a W-TinyLFU policy. `window_ratio` (default `0.01`) sizes the
/// admission window; `protected_ratio` (default `0.8`) sizes the protected
/// segment of the main LRU.
pub fn new_tinylfu(
  cap? : Int64,
  max_weight? : Int64,
  window_ratio~ : Double = 0.01,
  protected_ratio~ : Double = 0.8,
) -> Tinylfu {
  let max = max_weight.unwrap_or(cap.unwrap_or(0))
  let window_max = max_i64(
    1,
    int64_of_double(int64_to_double(max) * window_ratio),
  )
  let remain = max - window_max
  let protected_max = int64_of_double(int64_to_double(remain) * protected_ratio)
  let probation_max = remain - protected_max
  {
    max_weight: max,
    window_max,
    probation_max,
    protected_max,
    weight: @ref.Ref(0),
    window: new_list(),
    probation: new_list(),
    protected_list: new_list(),
    sketch: new_sketch(max.to_int()),
    doorkeeper: @hashmap.HashMap([]),
  }
}

///|
fn Tinylfu::record_access(self : Tinylfu, id : Int64) -> Unit {
  if self.sketch.count.val >= self.sketch.sample_size {
    self.sketch.sketch_age()
    self.doorkeeper.clear()
  }
  if self.doorkeeper.contains(id) {
    self.sketch.sketch_increment(id)
  } else {
    self.doorkeeper.set(id, ())
  }
}

///|
fn Tinylfu::evict(self : Tinylfu, candidate : Int64) -> Array[Int64] {
  let evicted : Array[Int64] = []
  while self.max_weight > 0 && self.weight.val > self.max_weight {
    while self.window.weight_sum.val > self.window_max &&
          !self.window.is_empty() {
      match self.window.peek_front() {
        Some(wid) => {
          let w = self.window.weight_of(wid)
          ignore(self.window.pop_front())
          self.probation.push_back(wid, w)
        }
        None => break
      }
    }
    let victim_opt = if !self.probation.is_empty() {
      self.probation.peek_front()
    } else if !self.window.is_empty() {
      self.window.peek_front()
    } else {
      None
    }
    match victim_opt {
      None => break
      Some(v) => {
        let in_window = self.window.contains(v)
        let vw = if in_window {
          self.window.weight_of(v)
        } else {
          self.probation.weight_of(v)
        }
        if self.sketch.sketch_estimate(v) >=
          self.sketch.sketch_estimate(candidate) {
          let cw = self.window.weight_of(candidate)
          ignore(self.window.remove(candidate))
          self.weight.val -= cw
          evicted.push(candidate)
          return evicted
        } else {
          if in_window {
            ignore(self.window.remove(v))
          } else {
            ignore(self.probation.remove(v))
          }
          self.weight.val -= vw
          evicted.push(v)
        }
      }
    }
  }
  evicted
}

///|
pub impl Policy for Tinylfu with fn hit(self : Tinylfu, id : Int64) -> Unit {
  self.record_access(id)
  if self.window.contains(id) {
    self.window.move_to_back(id)
  } else if self.probation.contains(id) {
    let w = self.probation.weight_of(id)
    ignore(self.probation.remove(id))
    if self.protected_list.weight_sum.val + w <= self.protected_max {
      self.protected_list.push_back(id, w)
    } else {
      match self.protected_list.pop_front() {
        Some(pf) => {
          let pw = self.protected_list.weight_of(pf)
          self.probation.push_back(pf, pw)
        }
        None => ()
      }
      self.protected_list.push_back(id, w)
    }
  } else if self.protected_list.contains(id) {
    self.protected_list.move_to_back(id)
  }
}

///|
pub impl Policy for Tinylfu with fn admit(
  self : Tinylfu,
  id : Int64,
  weight : Int64,
) -> Array[Int64] {
  self.record_access(id)
  self.weight.val += weight
  self.window.push_back(id, weight)
  self.evict(id)
}

///|
pub impl Policy for Tinylfu with fn forget(self : Tinylfu, id : Int64) -> Unit {
  if self.window.contains(id) {
    self.weight.val -= self.window.weight_of(id)
    ignore(self.window.remove(id))
  } else if self.probation.contains(id) {
    self.weight.val -= self.probation.weight_of(id)
    ignore(self.probation.remove(id))
  } else if self.protected_list.contains(id) {
    self.weight.val -= self.protected_list.weight_of(id)
    ignore(self.protected_list.remove(id))
  }
}

///|
pub impl Policy for Tinylfu with fn size(self : Tinylfu) -> Int32 {
  self.window.length() + self.probation.length() + self.protected_list.length()
}

///|
pub extend Tinylfu with Policy::{admit, hit, forget, size}

///|
fn max2(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn min2(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn max_i64(a : Int64, b : Int64) -> Int64 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn int64_of_double(d : Double) -> Int64 {
  d.to_int64()
}

///|
fn int64_to_double(i : Int64) -> Double {
  i.to_double()
}
