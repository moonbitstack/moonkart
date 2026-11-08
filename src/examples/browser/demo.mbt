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

///|
/// Why an entry left, in one word, for the page to print.
fn reason_code(reason : @moonkart.EvictionReason) -> String {
  match reason {
    Capacity => "capacity"
    Expired => "expired"
    Explicit => "explicit"
    Replaced => "replaced"
  }
}

///|
/// Replays a comma-separated trace through one policy and reports every step.
///
/// Each line is `key \t hit|miss \t what left`, and the name of the entry that
/// left follows a colon with its reason, so the page can say *why* the box gave
/// something up rather than only that it did.
fn replay_line(
  cache : @moonkart.Cache[String, String],
  key : String,
  left : Array[String],
) -> String {
  let state = match cache.get(key) {
    Some(_) => "hit"
    None => {
      cache.set(key, key)
      "miss"
    }
  }
  let moved = left.join(",")
  left.clear()
  "\{key}\t\{state}\t\{moved}"
}

///|
/// Runs the trace against the named policy. Returns one line per request.
#export_name("mk_replay")
pub fn mk_replay(policy : String, cap : Int32, trace : String) -> String {
  let cap = Int64::from_int(cap)
  let left : Array[String] = []
  let note = fn(k : String, _v : String, r : @moonkart.EvictionReason) {
    left.push("\{k}:\{reason_code(r)}")
  }
  let cache = match policy {
    "lru" => @moonkart.lru_cache(cap~, removal_listener=note)
    "s3fifo" => @moonkart.s3fifo_cache(cap~, removal_listener=note)
    _ => @moonkart.tinylfu_cache(cap~, removal_listener=note)
  }
  let lines : Array[String] = []
  for key in trace.split(",") {
    lines.push(replay_line(cache, key.to_owned(), left))
  }
  lines.join("\n")
}

///|
/// Replays the same trace through the three policies and returns their hit
/// counts as `lru \t n \t s3fifo \t n \t tinylfu \t n`.
#export_name("mk_survey")
pub fn mk_survey(cap : Int32, trace : String, watch : String) -> String {
  // one Iter can be walked once, and the three policies each need the whole trace
  let keys = trace.split(",").to_array()
  let names = watch.split(",").to_array()
  let lines : Array[String] = []
  for policy in ["lru", "s3fifo", "tinylfu"] {
    let cache = match policy {
      "lru" => @moonkart.lru_cache(cap=Int64::from_int(cap))
      "s3fifo" => @moonkart.s3fifo_cache(cap=Int64::from_int(cap))
      _ => @moonkart.tinylfu_cache(cap=Int64::from_int(cap))
    }
    let mut hits = 0
    for k in keys {
      let key = k.to_owned()
      match cache.get(key) {
        Some(_) => hits = hits + 1
        None => cache.set(key, key)
      }
    }
    let held : Array[String] = []
    for w in names {
      let name = w.to_owned()
      held.push(if cache.contains(name) { "1" } else { "0" })
    }
    lines.push("\{policy}\t\{hits}\t\{held.join("")}")
  }
  lines.join("\n")
}
