// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The cache the page talks to. A one-element array stands in for a mutable
/// global, which keeps the package free of a runtime dependency.
let slot : Array[@moonkart.Cache[String, String]] = []

///|
/// Exported functions cannot raise, so a call before `mk_reset` builds a small
/// cache instead of failing.
fn cache() -> @moonkart.Cache[String, String] {
  if slot.is_empty() {
    slot.push(@moonkart.tinylfu_cache(cap=16L))
  }
  slot[0]
}

///|
/// Builds a fresh cache with room for `cap` entries.
#export_name("mk_reset")
pub fn mk_reset(cap : Int32) -> Unit {
  let c = @moonkart.tinylfu_cache(cap=Int64::from_int(cap))
  if slot.is_empty() {
    slot.push(c)
  } else {
    slot[0] = c
  }
}

///|
/// Stores a value. Returns "1" when an older value was replaced, "0" otherwise.
#export_name("mk_set")
pub fn mk_set(key : String, value : String) -> String {
  let c = cache()
  let existed = c.contains(key)
  c.set(key, value)
  if existed {
    "1"
  } else {
    "0"
  }
}

///|
/// Reads a value. Returns `hit\tvalue` or `miss\t`.
#export_name("mk_get")
pub fn mk_get(key : String) -> String {
  let c = cache()
  match c.get(key) {
    Some(v) => "hit\t\{v}"
    None => "miss\t"
  }
}

///|
/// Counters as one line: hits, misses, evictions, size.
#export_name("mk_stats")
pub fn mk_stats() -> String {
  let c = cache()
  let s = c.stats()
  "\{s.hit_count}\t\{s.miss_count}\t\{s.eviction_count}\t\{c.size()}"
}
