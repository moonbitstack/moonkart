# moonkart

A cache for MoonBit. It is bounded by entry count or by total weight, it can
expire entries on a schedule you control, it computes missing values on demand,
and it tells you what left the cache and why. The eviction strategy is erased
behind an open contract, so every constructor returns the same `Cache[K, V]`
type and a third-party policy plugs in without changing it.

<p>
  <a href="https://moonbitstack.github.io/moonkart/"><b>Site</b></a> &middot;
  <a href="https://moonbitstack.github.io/moonkart/guide.html">Guide</a> &middot;
  <a href="https://moonbitstack.github.io/moonkart/inside.html">Inside</a> &middot;
  <a href="https://moonbitstack.github.io/moonkart/api.html">API</a> &middot;
  <a href="https://mooncakes.io/docs/moonbitstack/moonkart">mooncakes</a>
</p>

```moonbit
let cache = @moonkart.tinylfu_cache(cap=1000)
cache.set("answer", 42)

assert_eq(cache.get("answer"), Some(42))
assert_eq(cache.get("unknown"), None)
```

## Install

```bash
moon add moonbitstack/moonkart
```

Then import it in a package:

```moonbit
// moon.pkg
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

The `bench` package replays a trace of keys through each policy and reports the
hit rate, so a change to a policy can be judged against real access patterns
rather than intuition. The figures below come from the three ARC traces (the
request streams published with the ARC paper), replaying every request:

| Trace | Capacity | `lru_cache` | `s3fifo_cache` | `tinylfu_cache` |
|:--|--:|--:|--:|--:|
| OLTP (914,145 requests) | 1,869 | 0.4164 | 0.4219 | 0.4269 |
| DS1 (2,505,947 requests) | 101,764 | 0.1087 | 0.1109 | 0.2411 |
| S3 (16.4 million requests) | 524,288 | 0.2526 | n/a | 0.4640 |

Two checks make these comparable with published results. First, `lru_cache` on
S3 at 524,288 entries returns 0.25258, reproducing the 25.26% that the ARC paper
reports for the same trace at the same capacity, which validates both the replay
harness and the LRU implementation. Second, the ordering matches the published
conclusions: frequency-aware admission wins by a wide margin on the scan-heavy S3
trace, holds a similar lead on DS1, and only edges ahead on OLTP, where recency
dominates and frequency has little to add.

The frequency sketch is keyed by the runtime's hash seed, so a different seed
reshuffles its collisions and moves a TinyLFU figure by a few tenths of a point;
the recency policies are unaffected.

## Capacity

Bound the cache by entry count with `cap`, or by total weight with `max_weight`
plus a `weigher`:

```moonbit
// At most 500 entries.
let by_count = @moonkart.lru_cache(cap=500)
by_count.set("a", 1)
assert_eq(by_count.size(), 1L)
```

```moonbit
// At most 12 units of weight, where a value weighs one per character.
let by_weight = @moonkart.lru_cache(
  max_weight=12L,
  weigher=fn(_key : String, value : String) { value.length().to_int64() },
)
by_weight.set("foo", "123456") // 6
by_weight.set("emm", "123456") // 6 + 6 = 12
assert_eq(by_weight.size(), 2L)

by_weight.set("bar", "123456") // 18 > 12, so the oldest entry leaves
assert_eq(by_weight.contains("foo"), false)
assert_eq(by_weight.size(), 2L)
```

Without a weigher every entry weighs one, so `cap` and `max_weight` mean the
same thing.

## Expiry

Expiry deadlines are absolute nanosecond timestamps produced by a clock you
supply. The cache never reads the wall clock itself, so tests are deterministic
and do not sleep.

```moonbit
// Time to live from the moment of writing; reads do not extend it.
let now : @ref.Ref[Int64] = @ref.Ref(0L)
let ttl_cache = @moonkart.lru_cache(
  cap=100,
  expiry=@moonkart.ttl(10L),
  clock=fn() { now.val },
)
ttl_cache.set("user:7", "Vega")
assert_eq(ttl_cache.contains("user:7"), true)

now.val = 11L
assert_eq(ttl_cache.contains("user:7"), false)
```

```moonbit
// Time to idle: every read restarts the countdown.
let idle_now : @ref.Ref[Int64] = @ref.Ref(0L)
let tti_cache = @moonkart.lru_cache(
  cap=100,
  expiry=@moonkart.tti(10L),
  clock=fn() { idle_now.val },
)
tti_cache.set("session", "open")
idle_now.val = 6L
assert_eq(tti_cache.get("session"), Some("open")) // read at 6, so it lives to 16

idle_now.val = 15L
assert_eq(tti_cache.contains("session"), true)
idle_now.val = 17L
assert_eq(tti_cache.contains("session"), false)
```

`ttl` and `tti` are shorthands over the `Expiry` record, whose `after_create`,
`after_read` and `after_update` callbacks compute a deadline per entry, so a
rule can depend on the value or apply to only some keys.

A single write can also carry its own deadline, which then outranks the rule:

```moonbit
let fixed_now : @ref.Ref[Int64] = @ref.Ref(0L)
let mixed = @moonkart.lru_cache(
  cap=100,
  expiry=@moonkart.ttl(1_000L),
  clock=fn() { fixed_now.val },
)
mixed.set("short", "lived", expire_after=10L) // ten nanoseconds from now
mixed.set("long", "lived") // the cache's rule
assert_eq(mixed.entry("short").expire_at, Some(10L))
assert_eq(mixed.entry("long").expire_at, Some(1_000L))

fixed_now.val = 11L
assert_eq(mixed.contains("short"), false)
assert_eq(mixed.contains("long"), true)
```

A deadline fixed that way is not moved by a read, even on a time-to-idle cache,
and writing the entry again without `expire_after` hands it back to the rule.
`get_with` and `try_get_with` take the same parameter for the value they load.

## Loading

`get_with` runs a loader only on a miss and stores its result. The loader may
raise; a raised error is not cached and reaches the caller.

```moonbit
let users = @moonkart.lru_cache(cap=64)
let loads : @ref.Ref[Int] = @ref.Ref(0)
let fetch_user = fn(id : Int) raise {
  loads.val = loads.val + 1
  if id < 0 {
    fail("no such user")
  }
  "user-\{id}"
}
assert_eq(users.get_with(7, fetch_user), "user-7")
assert_eq(users.get_with(7, fetch_user), "user-7")
assert_eq(loads.val, 1) // the second call was a plain hit
```

```moonbit
let failed = users.get_with(-1, fetch_user) catch { _ => "none" }
assert_eq(failed, "none")
assert_eq(users.contains(-1), false) // a failed load leaves nothing behind
```

`try_get_with` lets the loader return `None` for "no value", which is not cached
either. When the loader cannot fail, wrap it with `infallible_loader` so the
call site needs no error handling:

```moonbit
let parsed = users.try_get_with(
  12,
  @moonkart.infallible_loader(fn(id : Int) {
    if id % 2 == 0 {
      Some("user-\{id}")
    } else {
      None
    }
  }),
)
assert_eq(parsed, Some("user-12"))
assert_eq(users.size(), 2L)
```

## Remembering a function

`#kart.cached` is `functools.lru_cache` for MoonBit. The function stays as it is,
and the generator adds a remembering one beside it:

```moonbit
#kart.cached(capacity="1024", policy="lru", ttl="60s")
#kart.count_calls
pub fn lookup(id : Int) -> String {
  "item-\{id}"
}
```

`lookup_cached(id)` reads through the cache, `lookup_cached_clear()` empties it,
and `lookup_cached_calls()` reports how many times `lookup` itself ran — the
number of misses, not the number of questions. The parameters are the key,
several of them a tuple. `capacity` is 128 when nothing says, `policy` is
`tinylfu`, `lru` or `s3fifo`, `ttl` and `tti` are durations such as `250ms`,
`60s`, `5m` or `1h`, and `name` renames the function. An `async fn` goes through
the asynchronous cache. A function that raises is refused, since there is
nothing to keep when it does.

For a value that is worked out once and never again, `#kart.once` turns a
function with no arguments into a one-entry store with no way back:

```moonbit
#kart.once
pub fn banner() -> String {
  "kart no. 128"
}
```

`banner_once()` answers with the first result for the rest of the process. There
is no clear function, by design: a value that can be forgotten is a cache, and
`#kart.cached` is the way to ask for one.

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

`src/examples/03-cached` is a working copy of both files.

## The asynchronous cache

`@moonkart.concurrent.AsyncCache` wraps any cache so that loads can be awaited.
Concurrent readers of one key share a single loader; readers of different keys
never wait on each other, and no lock is held while a loader runs.

```moonbit
// moon.pkg
import {
  "moonbitstack/moonkart",
  "moonbitstack/moonkart/concurrent",
}
```

```moonbit
let async_cache = @concurrent.AsyncCache::new(@moonkart.lru_cache(cap=64))
let value = async_cache.get_with(1, id => "user-\{id}")
assert_eq(value, "user-1")
assert_eq(async_cache.get(1), Some("user-1"))
```

The first task to miss records a per-key in-flight load and awaits it; later
tasks asking for the same key await the same result. A loader that raises
delivers its error to every waiter and leaves nothing in the cache, so the next
call retries. Three concurrent readers of one key call the loader exactly once.
`concurrent` builds on the synchronous core unchanged, so every policy, expiry
rule and counter carries over.

The handle carries the rest of the surface too — `peek`, `contains`, `remove`,
`invalidate_all`, `size`, `weight`, `stats` and `purge_expired` — so code that
holds only an `AsyncCache` never has to reach through `inner()` to read, remove
or measure something.

### Refreshing behind a read

A value that took ten minutes to work out should not have to be a choice between
a hit that never moves and a miss on every read. Give the cache a refresh window
and a value older than it answers the read at once while the loader runs behind
it:

```moonbit
let clock_now : @ref.Ref[Int64] = @ref.Ref(0L)
let fetched = @concurrent.AsyncCache::new(
  @moonkart.lru_cache(cap=64, clock=fn() { clock_now.val }),
  refresh=@concurrent.refresh_every(60_000_000_000L), // an hour, in nanoseconds
)
let version : @ref.Ref[Int] = @ref.Ref(0)
let load_user = async fn(id : Int) -> String {
  version.val = version.val + 1
  "user-\{id} v\{version.val}"
}
assert_eq(fetched.get_with(1, load_user), "user-1 v1")

// An hour later the value is stale: the read is answered from it, and the
// reload it starts runs behind the read.
clock_now.val = 60_000_000_000L
assert_eq(fetched.get_with(1, load_user), "user-1 v1")
assert_eq(version.val, 1) // the loader has not run again yet
fetched.settle()
assert_eq(version.val, 2)
assert_eq(fetched.get(1), Some("user-1 v2"))
```

`settle` runs whatever reloads are waiting. In a real program the cache runs them
itself: hand it a way to start a task and they live in your task group, which is
what `AsyncCache::new(inner, refresh=window, spawn=fn(task) { group.spawn_bg(task) })`
does inside `@async.with_task_group`. A reload that raises keeps the old value
and reports the error to `refresh.on_failure`; one key has at most one reload in
flight, however many readers find it stale; and `refresh_after=ns` on `get_with`
or `try_get_with` overrides the window for that call.

The synchronous cache has no refresh. It answers a read and returns, with nowhere
to run a reload, so its values change only when something writes them.

### Shards

`ShardedCache` splits the key space over independent caches. A key always lands
in the same shard, so a read or a write behaves as it does on one cache; what
changes is that each shard holds its own budget, so traffic in one cannot evict
entries in another, and each has its own in-flight table.

```moonbit
let sharded = @concurrent.ShardedCache::new(
  shards=4,
  make=fn(_index) { @moonkart.lru_cache(cap=256L) },
)
sharded.set("user:1", "Leo")
assert_eq(sharded.get("user:1"), Some("Leo"))
assert_eq(sharded.shards(), 4)
assert_eq(sharded.stats().hit_count + sharded.stats().miss_count, 1L)
```

`make` is called once per shard with its index, so each one can be bounded and
tuned on its own. `size()` and `stats()` report the shards added together, as do
`weight()` and `purge_expired()`; `peek` and `contains` ask the one shard the key
belongs to. Sharding is not by itself a speed-up on a runtime that schedules
tasks cooperatively; it is the unit that keeps unrelated workloads apart, and the
unit a caller can hand to its own threads.

## Hybrid memory and disk (native)

`@moonkart.disk.DiskCache` is a two-tier cache: a memory cache in front, and a
file behind it that holds what memory could not keep. Every write appends a
record, so the file doubles as the log a restart replays; every read asks memory
first and falls to the file, whose answer is put back into memory.

```moonbit
// moon.pkg
import {
  "moonbitstack/moonkart",
  "moonbitstack/moonkart/disk",
}
```

```moonbit native
async fn persist(path : String) -> Unit raise {
  let disk = @disk.DiskCache::open(
    @moonkart.lru_cache(cap=10_000),
    path,
    fn(key : String) { @utf8.encode(key) },
    fn(bytes) { Some(@utf8.decode_lossy(bytes)) },
    fn(value : String) { @utf8.encode(value) },
    fn(bytes) { Some(@utf8.decode_lossy(bytes)) },
    max_bytes=64L * 1024L * 1024L, // at most 64 MiB of live records
  )
  disk.set("greeting", "hello") // memory, then an appended record
  assert_eq(disk.get("greeting"), Some("hello"))
  assert_eq(disk.stats().entries, 1L)
  disk.compact() // rewrite the file from the live records
}
```

The file is bounded on its own terms. `max_bytes` caps the live records it
keeps; when a write would take it over, the least recently read record leaves
first — a read that came from the file counts as recent. A record larger than
the whole budget is refused rather than written: it stays in memory, `refused`
goes up, and it is gone when memory evicts it. Without `max_bytes` the file keeps
everything written.

Who gets that last byte is a decision, and by default it goes to the record that
has been seen more often. The file keeps a frequency sketch over the keys it
wrote — the same sketch the policies use — so a key seen once cannot push out a
key seen twice, and a scan of one-off keys leaves the working set alone. On a
stream where seven requests in ten name one of ten keys and the rest walk a long
list of new ones, with room for twelve records, that answers 1,285 of 2,000
requests where keeping everything that fits answers 1,194. Pass
`admission=@policy.TakeAll` to keep the plain rule instead; an equal estimate
goes to the newcomer either way, so a cache with no favourite keys behaves
exactly as it did.

```moonbit native
// A file that keeps what is read, not what merely arrived last.
async fn picky(path : String) -> Unit raise {
  let disk = @disk.DiskCache::open(
    @moonkart.lru_cache(cap=10_000),
    path,
    fn(key : String) { @utf8.encode(key) },
    fn(bytes) { Some(@utf8.decode_lossy(bytes)) },
    fn(value : String) { @utf8.encode(value) },
    fn(bytes) { Some(@utf8.decode_lossy(bytes)) },
    max_bytes=64L * 1024L * 1024L,
    admission=@policy.TakeAll, // keep everything that fits, as before
  )
  disk.set("greeting", "hello")
  assert_eq(disk.stats().denied, 0L) // nothing was turned away
  assert_eq(disk.stats().entries, 1L)
}
```

`stats()` reports `promotions`, `evictions`, `refused`, `denied`, and the file's
live `entries` and `bytes`. Call `compact` periodically: until it runs,
superseded and deleted records still take space.

The filesystem in the standard library is asynchronous and native-only, so this
package is too. It is target-gated: the other backends compile unaffected, and
`moon check --target all` stays green. Records restored on open are replayed
through `set`, so the memory cache's current capacity and expiry policy apply to
them — and so they count as written when the cache opens. A record on the file
carries no write time, so a refresh window measured from the write starts again
after a restart: nothing on the medium can say how old the value is.

## Second tier in browser storage (js)

`@moonkart.storage` is the same second tier over a store of strings, which is what
a browser has: one entry per record, kept across reloads. `local_storage()` binds
the browser's own store; anything that answers `get`, `set`, `remove` and `keys`
can stand in its place, which is how this package is tested without a browser.

```moonbit
// moon.pkg
import {
  "moonbitstack/moonkart",
  "moonbitstack/moonkart/storage",
}
```

```moonbit js
let page = @storage.StorageCache::open(
  @moonkart.tinylfu_cache(cap=500),
  @storage.local_storage(),
  fn(key : String) { @utf8.encode(key) },
  fn(bytes) { Some(@utf8.decode_lossy(bytes)) },
  fn(value : String) { @utf8.encode(value) },
  fn(bytes) { Some(@utf8.decode_lossy(bytes)) },
  max_bytes=1L * 1024L * 1024L, // at most 1 MiB of records
)
page.set("cart", "3 items")
assert_eq(page.get("cart"), Some("3 items"))
assert_eq(page.stats().entries, 1L)
page.watch()
```

The rules are the file tier's: `max_bytes` bounds the records, the least recently
read one leaves when a write would go over, a record larger than the budget is
refused, and `admission` decides who keeps the last byte. Each record is stored
under a prefix and the key's hex, its body base64, so one cache cannot read
another's entries and a key is recognisable in a developer tool.

`watch()` is what a page needs when the same page is open twice. It listens for
the browser's `storage` event and drops this page's copy of whatever the other
page wrote, so the next read takes the value that was actually written instead of
answering from memory that has fallen behind. Pass `apply_storage_event(key)`
yourself if you would rather wire the event your own way.

What the store holds on load is read back through `set`, in the store's own
order, so the memory cache's capacity and expiry rule apply to it. A stored
record carries no write time, so a restored value counts as written when the page
loads, and a refresh window starts again from there.

## Invalidation

```moonbit
let c = @moonkart.lru_cache(cap=8)
c.set("a", 1)
c.set("b", 2)
assert_eq(c.invalidate("a"), true) // one key, returns whether it was present
assert_eq(c.invalidate_if(fn(_k, value) { value > 1 }), 1L) // by predicate, returns how many
c.invalidate_all() // everything
assert_eq(c.size(), 0L)
```

## Looking on the side, and sweeping

Expiry is lazy: an entry past its deadline is dropped when something asks for it,
so one nobody asks for again keeps its space and its place in the eviction order.
Four calls cover the cases around that. `peek` answers without counting a hit or
a miss, moving the entry in the eviction order, or restarting an idle deadline.
`insert` is `set` that hands back the value it displaced. `weight` adds up the
entries as the weigher counted them. `purge_expired` collects the entries whose
deadline passed, without waiting for a read.

```moonbit
let sweep_now : @ref.Ref[Int64] = @ref.Ref(0L)
let side = @moonkart.lru_cache(cap=8, clock=fn() { sweep_now.val })
side.set("a", "kept", expire_after=10L)
side.set("b", "aged", expire_after=1L)

assert_eq(side.insert("a", "newer"), Some("kept")) // the value it replaced
assert_eq(side.peek("a"), Some("newer")) // read, but counted nowhere
assert_eq(side.stats().hit_count, 0L)

sweep_now.val = 5L
assert_eq(side.purge_expired(), 1L) // "b" died unread
assert_eq(side.size(), 1L)
assert_eq(side.weight(), 1L)
```

## Events and statistics

A removal listener is told about every entry that leaves, with the reason:
`Capacity`, `Expired`, `Explicit` or `Replaced`.

```moonbit
let gone : Array[String] = []
let tracked = @moonkart.lru_cache(
  cap=2,
  removal_listener=fn(key : Int, _value : String, reason) {
    let why = match reason {
      Capacity => "capacity"
      Expired => "expired"
      Explicit => "explicit"
      Replaced => "replaced"
    }
    gone.push("\{key}:\{why}")
  },
)
tracked.set(1, "a")
tracked.set(2, "b")
tracked.set(3, "c")
assert_eq(gone, ["1:capacity"])
```

`stats()` returns counters for hits, misses, evictions, evicted weight,
successful and failed loads, and the total time spent in loaders.
`hit_rate()` and `miss_rate()` are derived from the first two.

```moonbit
let counted = @moonkart.lru_cache(cap=4)
counted.set(1, 1)
ignore(counted.get(1))
ignore(counted.get(2))
let s = counted.stats()
assert_eq(s.hit_count, 1L)
assert_eq(s.miss_count, 1L)
assert_eq(s.hit_rate(), 0.5)
```

## Custom policies

`@moonkart.policy.Policy` is an open trait. A policy sees opaque numeric entry
ids, weights and the key's hash, never the keys or values. Implement `hit`,
`admit`, `forget` and `size` for your own type and build a cache with `new`:

```moonbit
pub struct Fifo {
  order : Array[Int64]
  cap : Int64
}

impl @policy.Policy for Fifo with fn hit(
  self : Fifo,
  _id : Int64,
  _hash : Int32,
) -> Unit {
  ignore(self)
}

impl @policy.Policy for Fifo with fn admit(
  self : Fifo,
  id : Int64,
  _weight : Int64,
  _hash : Int32,
) -> Array[Int64] {
  self.order.push(id)
  if self.order.length().to_int64() > self.cap {
    [self.order.remove(0)]
  } else {
    []
  }
}

impl @policy.Policy for Fifo with fn forget(self : Fifo, id : Int64) -> Unit {
  for i, v in self.order {
    if v == id {
      ignore(self.order.remove(i))
      break
    }
  }
}

impl @policy.Policy for Fifo with fn size(self : Fifo) -> Int32 {
  self.order.length()
}
```

```moonbit
let fifo_policy : Fifo = { order: [], cap: 2L }
let fifo = @moonkart.new(fifo_policy)
fifo.set(1, "a")
fifo.set(2, "b")
fifo.set(3, "c")
assert_eq(fifo.contains(1), false)
assert_eq(fifo.size(), 2L)
```

`admit` returns the ids to evict, and may return the new id itself to refuse an
entry that is too heavy for the cache. `new_with_config` takes the same policy
together with a `Config` bundle; `default_config()` fills in every optional knob.

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
| `set(key, value, expire_after=ns)` | insert or replace, with a deadline for this write only |
| `insert(key, value)` | the same, returning the value it displaced |
| `get(key)` | read, or `None` |
| `peek(key)` | read without counting it, reordering the entry or refreshing an idle deadline |
| `contains(key)` | presence; no hit, no idle refresh |
| `entry(key)`, `entry_or_null(key)` | snapshot of an entry |
| `remove(key)`, `invalidate(key)` | remove one, returns whether it was present |
| `invalidate_all()`, `invalidate_if(pred)` | remove many |
| `purge_expired()` | drop every entry past its deadline, returns how many |
| `get_with(key, loader)`, `try_get_with(key, loader)` | load on miss; the loader may raise |
| `infallible_loader(loader)` | adapt a loader that cannot fail |
| `to_array()` | every live entry as `(key, value)` |
| `stats()`, `size()`, `weight()`, `policy_size()` | counters, entry count, total weight, policy size |
| `CacheStats::merge(a, b)` | two sets of counters added together |
| `written_at(key)`, `now()` | when a value was written, and the clock reading before it |
| `refresh_every(ns)` | a refresh window for `@moonkart/concurrent` |
| `AsyncCache::get_with(key, loader, refresh_after=ns)` | a stale value answers, and is reloaded behind the read |
| `AsyncCache::settle()` | run the reloads that are waiting |
| `StorageCache::open(...)`, `apply_storage_event(key)`, `local_storage()` | the second tier over a store of strings |
| `@policy.TakeAll`, `@policy.ByValue` | how a second tier spends its last byte |

The same library adds three more packages: `@moonkart.concurrent` for
`AsyncCache` and `ShardedCache`, `@moonkart.disk` for the native memory-plus-file
tier, and `@moonkart.storage` for the two-tier cache over browser storage.
`@moonkart.tier` holds the bookkeeping those two tiers share. `#kart.cached`,
`#kart.once` and `#kart.count_calls` come from the generator in `cmd/cached`, run
as a dev_build rule.

The clock, the weigher, the expiry rule and the removal listener are all
parameters of the constructor, so one `Cache` type serves a request path, a
long-running job and a test that moves a `Ref`. Because every deadline is
absolute and the clock is passed in, an expiry test never sleeps.

## Licence

Apache 2.0.
