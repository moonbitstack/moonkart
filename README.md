# moonkart

A cache for MoonBit. It is bounded by entry count or by total weight, it can
expire entries on a schedule you control, it computes missing values on demand,
and it tells you what left the cache and why. The eviction strategy is erased
behind an open contract, so every constructor returns the same `Cache[K, V]`
type and a third-party policy plugs in without changing it.

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

Every constructor returns a `Cache[K, V]`. The policy decides which entry leaves
when the cache is full; it is hidden behind the `Policy` contract, so the cache
type does not change when you switch strategies.

| Constructor | Policy | Good at |
|:--|:--|:--|
| `tinylfu_cache` | W-TinyLFU (frequency + recency) | general workloads; keeps frequently used entries |
| `lru_cache` | least recently used | simple, predictable recency |
| `s3fifo_cache` | second-chance FIFO | scan floods and one-hit wonders |

`tinylfu_cache`, `lru_cache` and `s3fifo_cache` share the same knobs; use
`new(policy, ...)` with your own policy if none of these fit.

### Measured hit rates

`src/bench` replays a trace of keys through each policy and reports the hit
rate, so a change to a policy can be judged against real access patterns rather
than intuition. Numbers below come from the three ARC traces (the request
streams published with the ARC paper), replaying every request:

| Trace | Capacity | `lru_cache` | `s3fifo_cache` | `tinylfu_cache` |
|:--|--:|--:|--:|--:|
| OLTP (914,145 requests) | 1,869 | 0.4164 | 0.4219 | 0.4219 |
| DS1 (2,510,124 requests) | 101,764 | 0.1087 | 0.1109 | 0.2418 |
| S3 (16,407,702 requests) | 524,288 | 0.2526 | n/a | 0.4640 |

Two checks make these comparable with published results. First, `lru_cache` on
S3 at 524,288 entries returns 0.25258, reproducing the 25.26% that the ARC paper
reports for the same trace at the same capacity, which validates both the replay
harness and the LRU implementation. Second, the ordering matches the published
conclusions: frequency-aware admission wins by a wide margin on the scan-heavy
S3 trace, holds a similar lead on DS1, and ties LRU on OLTP where recency
dominates.

Replay of the full traces is an offline measurement, not a test; CI replays only
the first ten thousand requests of OLTP so it needs no downloaded data.

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

`get_with` runs a loader only on a miss and stores its result. The loader may
raise; a raised error is not cached and reaches the caller. `try_get_with` lets
the loader return `None` for "no value", which is not cached either.

```moonbit
let user = cache.get_with(user_id, fn(id) raise { fetch_user(id) })
```

When the loader cannot fail, wrap it with `infallible_loader` so the call site
needs no error handling:

```moonbit
let parsed = cache.get_with(text, @moonkart.infallible_loader(fn(t) { parse(t) }))
```

## Remembering a function

`#kart.cached` is `functools.lru_cache` for MoonBit. The function stays as it is, and
the generator adds a remembering one beside it:

```moonbit
#kart.cached(capacity="1024", policy="lru", ttl="60s")
pub fn lookup(id : Int) -> String {
  expensive(id)
}
```

`lookup_cached(id)` reads through the cache and `lookup_cached_clear()` empties it. The
parameters are the key, several of them a tuple. `capacity` is 128 when nothing says,
`policy` is `tinylfu`, `lru` or `s3fifo`, `ttl` and `tti` are durations such as `250ms`,
`60s`, `5m` or `1h`, and `name` renames the function. An `async fn` goes through the
asynchronous cache. A function that raises is refused, since there is nothing to keep
when it does.

The generator wires in as a dev_build rule, in `moon.mod`:

<!-- nocheck -->
```
rule(name: "cached", command: "moonx moonbitstack/moonkart/cmd/cached -C \"$mod_dir\" \"$input\" -o \"$output\"")
```

and in the `moon.pkg` of the package, which imports `moonbitstack/moonkart` and
`moonbitstack/moonkart/policy`:

<!-- nocheck -->
```
dev_build(rule: "cached", input: "slow.mbt", output: "slow.g.mbt")
formatter(ignore: [ "slow.g.mbt" ])
```

`moon run src/examples/03-cached` shows it.

## The asynchronous cache

`@moonkart.concurrent.AsyncCache` wraps any cache so that loads can be awaited.
Concurrent readers of one key share a single loader; readers of different keys
never wait on each other, and no lock is held while a loader runs. It is built on
`moonbitlang/async`, so it shares the runtime your other tasks already use.

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

The first task to miss records a per-key in-flight load and awaits it; later
tasks asking for the same key await the same result. A loader that raises
delivers its error to every waiter and leaves nothing in the cache, so the next
call retries. Three concurrent readers of one key call the loader exactly once.
`concurrent` builds on the synchronous core unchanged, so every policy, expiry
rule and counter carries over.

## Hybrid memory and disk (native)

`@moonkart.disk.DiskCache` keeps entries in memory and appends every write or
delete to a file, so a restart can rebuild the cache from the log. Keys and
values are turned into bytes by codecs you supply, so the layer imposes no
format of its own.

```moonbit
import {
  "moonbitstack/moonkart",
  "moonbitstack/moonkart/disk",
}
```

```moonbit
let cache = @moonkart.lru_cache(cap=10_000)
let disk = @disk.DiskCache::open(
  cache, "/var/cache/app.bin",
  encode_key, decode_key, encode_value, decode_value,
)
disk.set(key, value)   // memory, then an appended record
disk.get(key)          // memory only
disk.compact()         // rewrite the log from the live entries
```

The filesystem in the standard library is asynchronous and native-only, so this
package is too. It is target-gated: the other backends compile unaffected, and
`moon check --target all` stays green. Restored entries are replayed through
`set`, so the cache's current capacity and expiry policy apply to them; call
`compact` periodically so the append log does not grow without bound.

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

`@moonkart.policy.Policy` is an open trait. A policy sees opaque numeric entry
ids, weights and the key's hash, never the keys or values. Implement `hit`,
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
| `contains(key)` | presence; no hit, no idle refresh |
| `entry(key)`, `entry_or_null(key)` | snapshot of an entry |
| `remove(key)`, `invalidate(key)` | remove one, returns whether it was present |
| `invalidate_all()`, `invalidate_if(pred)` | remove many |
| `get_with(key, loader)`, `try_get_with(key, loader)` | load on miss; the loader may raise |
| `infallible_loader(loader)` | adapt a loader that cannot fail |
| `stats()`, `size()`, `policy_size()` | counters and sizes |

### Upgrading from the 0.1.0 pre-release

The module has not been published; these are the changes to make when moving
code written against the first source drop.

| Before | After |
|:--|:--|
| `Cache[K, V, P]` | `Cache[K, V]`; the policy is chosen at construction and erased |
| `cache[Int, String, @policy.Lru]()` | `@moonkart.lru_cache(cap=...)` |
| `get_with(key, fn(k) { ... })` | `get_with(key, fn(k) raise { ... })` |
| a loader that cannot fail | wrap it: `infallible_loader(fn(k) { ... })` |
| `@policy.Policy::hit(id)` / `admit(id, w)` | `hit(id, hash)` / `admit(id, w, hash)` |

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
