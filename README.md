# moonkart

A cache for MoonBit. It is bounded by entry count or by total weight, it can
expire entries on a schedule you control, it computes missing values on demand,
and it tells you what left the cache and why. The eviction strategy is a type
parameter, so you can use the ones it ships with or supply your own.

```moonbit
let cache = @moonkart.lru_cache(cap=1000)
cache.set("answer", 42)

match cache.get("answer") {
  Some(value) => println("hit: \{value}")
  None => println("miss")
}
```

## Install

```bash
moon add moonbitstack/moonkart
```

Then import it in a package:

```moonbit
import {
  "moonbitstack/moonkart",
}
```

## Choosing an eviction policy

Every constructor returns a `Cache[K, V, P]` where `P` is the policy. The policy
decides which entry leaves when the cache is full.

| Constructor | Policy | Good at |
|:--|:--|:--|
| `tinylfu_cache` | W-TinyLFU (frequency + recency) | general workloads; keeps frequently used entries |
| `lru_cache` | least recently used | simple, predictable recency |
| `s3fifo_cache` | second-chance FIFO | scan floods and one-hit wonders |

`tinylfu_cache`, `lru_cache` and `s3fifo_cache` share the same knobs; use
`new(policy, ...)` with your own policy if none of these fit.

## Capacity

Bound the cache by entry count with `cap`, or by total weight with
`max_weight` plus a `weigher`:

```moonbit
// At most 500 entries.
let by_count = @moonkart.lru_cache(cap=500)

// At most 10 MiB, where the weight is the byte length of the value.
let by_weight = @moonkart.lru_cache(
  max_weight=10L * 1024L * 1024L,
  weigher=fn(_key, bytes) { bytes.length().to_int64() },
)
```

Without a weigher every entry weighs one, so `cap` and `max_weight` mean the
same thing.

## Expiry

Expiry deadlines are absolute nanosecond timestamps produced by a clock you
supply. The cache never reads the wall clock itself, so tests are deterministic
and do not sleep.

```moonbit
// Time-to-live from the moment of writing; reads do not extend it.
let ttl_cache = @moonkart.lru_cache(cap=1000, expiry=@moonkart.ttl(60_000_000_000L))

// Time-to-idle: every read restarts the countdown.
let tti_cache = @moonkart.lru_cache(cap=1000, expiry=@moonkart.tti(30_000_000_000L))
```

`ttl` and `tti` are shorthands over the `Expiry` record, whose `after_create`,
`after_read` and `after_update` callbacks compute per-entry deadlines. Pass your
own `clock` to move time under test:

```moonbit
let now : @ref.Ref[Int64] = @ref.Ref(0L)
let cache = @moonkart.lru_cache(cap=10, expiry=@moonkart.ttl(1_000_000_000L), clock=fn() { now.val })
```

## Loading

`get_with` runs a loader only on a miss and stores its result; `try_get_with`
lets the loader return `None` for "no value", which is not cached.

```moonbit
let user = cache.get_with(user_id, fn(id) { fetch_user(id) })
```

## The asynchronous cache

`@moonkart.concurrent.AsyncCache` wraps any cache so that loads can be awaited.
Concurrent readers of one key share a single loader instead of each computing
the value.

```moonbit
import {
  "moonbitstack/moonkart",
  "moonbitstack/moonkart/concurrent",
}
```

```moonbit
let cache = @concurrent.AsyncCache::new(@moonkart.lru_cache(cap=1000))
let user = cache.get_with(id, async fn(id) { fetch_user(id) })
```

The first task holds a mutex while its loader runs; later tasks wait, re-check
the cache under the lock, and return the stored value. Three concurrent readers
of one key call the loader exactly once. `concurrent` builds on the synchronous
core unchanged, so every policy, expiry rule and counter carries over.

## Invalidation

```moonbit
cache.invalidate(key)          // one key, returns whether it was present
cache.invalidate_all()         // everything
cache.invalidate_if(fn(k, v) { v.is_stale() })   // by predicate, returns how many
```

## Events and statistics

A removal listener is told about every entry that leaves, with the reason:
`Capacity`, `Expired`, `Explicit` or `Replaced`.

```moonbit
let cache = @moonkart.lru_cache(
  cap=1000,
  removal_listener=fn(key, _value, reason) {
    println("\{key} left: \{reason}")
  },
)
```

`cache.stats()` returns counters for hits, misses, evictions, evicted weight,
successful and failed loads, and the total time spent in loaders.

## Custom policies

`@moonkart.policy.Policy` is an open trait. A policy only ever sees opaque
numeric entry ids and weights, never your keys or values. Implement `hit`,
`admit`, `forget` and `size` for your own type and build a cache with `new`:

```moonbit
let cache = @moonkart.new(@my_policy.Policy::new())
```

## API

| Item | Meaning |
|:--|:--|
| `lru_cache`, `s3fifo_cache`, `tinylfu_cache` | constructors for the shipped policies |
| `new(policy, ...)` | construct with any policy |
| `new_with_config(policy, config)` | construct from a `Config` bundle |
| `default_config()` | defaults for every optional knob |
| `ttl(ns)`, `tti(ns)` | expiry shorthands |
| `system_clock` | the default clock, from the runtime |
| `set(key, value)` | insert or replace |
| `get(key)` | read, or `None` |
| `contains(key)` | presence, ignoring nothing |
| `entry(key)`, `entry_or_null(key)` | snapshot of an entry |
| `remove(key)`, `invalidate(key)` | remove one, returns whether it was present |
| `invalidate_all()`, `invalidate_if(pred)` | remove many |
| `get_with(key, loader)`, `try_get_with(key, loader)` | load on miss |
| `stats()`, `size()`, `policy_size()` | counters and sizes |

## Determinism

Because the clock is a parameter and every deadline is absolute, an expiry test
moves a `Ref` and never sleeps. See `src/cache_test.mbt` for the suite, and
`src/examples/` for runnable programs:

```bash
moon run src/examples/tour
moon run src/examples/01-expiry
moon run src/examples/02-loading
```

## The gate

Every commit passes this, with each exit code seen to be zero:

```bash
moon clean && moon fmt && moon check --target all --deny-warn \
  && moon build --target all && moon test --target all
```

The generated interface is checked in; `moon info --target all && git diff
--exit-code` must be clean before a release.

## Licence

Apache-2.0.
