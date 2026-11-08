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

## Things that catch people out

- The cache reads no clock unless you give it one: expiry needs `clock`, a nanosecond reading. `system_clock` is there for production; tests pass their own and never sleep.
- `removal_listener` hears every entry that leaves, with the reason: `Capacity`, `Expired`, `Explicit` or `Replaced`. `stats()` gives hits, misses and their rates.
- A weight-bounded cache needs both `max_weight` and a `weigher`; `cap` and `max_weight` are alternatives.
- TinyLFU's frequency sketch is keyed by the runtime's hash seed, so its hit rate moves by a few tenths of a point between seeds; the recency policies do not.
- The disk tier is native only, in `moonbitstack/moonkart/disk`.
