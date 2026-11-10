---
name: moonkart
description: "Cache values in MoonBit with moonbitstack/moonkart: bounded by entry count or by weight, W-TinyLFU, LRU or S3-FIFO eviction behind one Cache type, time-to-live and time-to-idle on a clock you pass, loaders that run only on a miss, eviction events and hit statistics, a concurrent cache, a native memory-plus-disk tier, and #kart.cached to memoise a function. Use when code repeats an expensive lookup or computation, or needs a bounded map that forgets."
---

# moonkart

```bash
moon add moonbitstack/moonkart
```

```moonbit
// moon.pkg
import {
  "moonbitstack/moonkart",
}
```

## A bounded cache

```moonbit
fn prices() -> @moonkart.Cache[String, Double] {
  // W-TinyLFU keeps what is used often; lru_cache and s3fifo_cache take the same knobs.
  @moonkart.tinylfu_cache(cap=10_000)
}

fn price(cache : @moonkart.Cache[String, Double], sku : String) -> Double? {
  cache.get(sku)
}
```

Every constructor returns the same `Cache[K, V]`, so switching policy changes one line.

## Load on a miss

```moonbit
fn lookup(
  cache : @moonkart.Cache[Int, String],
  id : Int,
  fetch : (Int) -> String raise,
) -> String raise {
  cache.get_with(id, fetch) // runs `fetch` only on a miss; an error is not cached
}
```

`try_get_with` takes a loader that answers `None` for "no such value", which is not cached either.

## Expiry and weight

```moonbit
fn sessions(clock : () -> Int64) -> @moonkart.Cache[String, Bytes] {
  @moonkart.lru_cache(
    max_weight=10L * 1024L * 1024L, // 10 MiB of values
    weigher=(_key, value) => value.length().to_int64(),
    expiry=@moonkart.tti(30_000_000_000L), // 30 s idle, in nanoseconds
    clock~,
  )
}
```

`ttl(ns)` counts from the write and is not extended by reads; `tti(ns)` restarts on every read. The `Expiry` record takes per-entry callbacks for anything else.

One write can carry its own deadline instead: `cache.set(key, value, expire_after=ns)`, and `get_with(key, loader, expire_after=ns)` for a loaded value. Such a deadline outranks the cache's rule and no read moves it.

## Refresh a value behind a read

An old value can keep answering while a loader replaces it: `@concurrent` measures a window from the write, so an aged value returns at once and the reload runs behind the read.

```moonbit
fn polled(
  clock : () -> Int64,
  spawn : @concurrent.Spawn, // in a task group: fn(task) { group.spawn_bg(task) }
) -> @concurrent.AsyncCache[Int, String] {
  @concurrent.AsyncCache::new(
    @moonkart.lru_cache(cap=64, clock~),
    refresh=@concurrent.refresh_every(60_000_000_000L), // stale after a minute
    spawn~,
  )
}
```

`get_with(key, loader)` starts at most one reload per key; a reload that raises keeps the old value and calls `refresh.on_failure`. `refresh_after=ns` on the call overrides the window, and `settle()` runs whatever is waiting when you gave the cache no `spawn`. The synchronous `Cache` never refreshes on its own.

## Remember a function

```moonbit
#kart.cached(capacity="1024", policy="lru", ttl="60s")
pub fn price_of(sku : String) -> Double {
  sku.length().to_double()
}
```

The generator adds `price_of_cached(sku)` beside the function, which reads through a cache, and `price_of_cached_clear()`. `policy` is `tinylfu`, `lru` or `s3fifo`;
`ttl` and `tti` take durations such as `250ms`, `60s`, `5m`, `1h`. The function must not raise. Enable it with a `dev_build` rule in `moon.mod` and a
`dev_build(rule: "cached", input: "...", output: "...")` line in `moon.pkg`; see the repository's `src/examples/03-cached` for both files.

Next to it, `#kart.count_calls` adds `price_of_cached_calls()`, which counts how many times the function ran. `#kart.once` is for a value that never changes: it takes no arguments and generates `name_once()` with no way to clear it.

```moonbit
#kart.cached
#kart.count_calls
pub fn ratio(a : Int, b : Int) -> Double {
  a.to_double() / b.to_double()
}

#kart.once
pub fn revision() -> String {
  "3f9c1ab"
}
```

## Things that catch people out

- The cache reads no clock unless you give it one: expiry needs `clock`, a nanosecond reading. `system_clock` is there for production; tests pass their own and never sleep.
- `removal_listener` hears every entry that leaves, with the reason: `Capacity`, `Expired`, `Explicit` or `Replaced`. `stats()` gives hits, misses and their rates.
- A weight-bounded cache needs both `max_weight` and a `weigher`; `cap` and `max_weight` are alternatives.
- `@concurrent.ShardedCache` splits the key space over independent caches with their own budgets. It keeps unrelated traffic from evicting your entries; it does not add parallelism by itself.
- The disk tier is native only, in `moonbitstack/moonkart/disk`; `moonbitstack/moonkart/storage` is the same contract over a store of strings, on the js target with `local_storage()`. `max_bytes` bounds the live records, a read that misses memory is served from the medium and put back, and `stats()` reports promotions, evictions, refusals and denials. The file tier needs `compact()` now and then, or it keeps its dead records.
- A second tier admits by value by default: a key seen once does not push out a key seen twice. `admission=@policy.TakeAll` keeps everything that fits instead.
- In a browser page, call `watch()` once so a write in another tab drops this page's copy of that key; without it a page answers from memory that has fallen behind.
- TinyLFU's frequency sketch is keyed by the runtime's hash seed, so its hit rate moves by a few tenths of a point between seeds; the recency policies do not.
