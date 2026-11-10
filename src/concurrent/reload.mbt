// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading a value that has gone stale returns it and starts a reload behind the
// read. The reload is a `Lazy`: whoever gets there first runs the loader, and a
// second read of the same key joins that run rather than starting another, which
// is what "one reload per key" means here.

///|
/// The window this call should measure against: the one passed to the call wins
/// over the one the cache was built with.
fn[K, V] AsyncCache::window_for(
  self : AsyncCache[K, V],
  refresh_after : Int64?,
) -> Int64? {
  match refresh_after {
    Some(ns) => Some(ns)
    None =>
      match self.refresh {
        Some(r) => r.after
        None => None
      }
  }
}

///|
/// Whether a value written at `written` has outlived `ns`. A window of zero or
/// less makes every read start a reload.
fn is_stale(now : Int64, written : Int64, ns : Int64) -> Bool {
  ns <= 0L || now - written >= ns
}

///|
/// Starts a reload of `key` if the value there is stale and nothing is reloading
/// it already, and returns without waiting for it.
fn[K : Eq + Hash, V] AsyncCache::start_reload(
  self : AsyncCache[K, V],
  key : K,
  reload : async () -> Unit,
  refresh_after : Int64?,
) -> Unit {
  let ns = match self.window_for(refresh_after) {
    Some(ns) => ns
    None => return
  }
  let written = match self.inner.written_at(key) {
    Some(t) => t
    None => return
  }
  guard is_stale(self.inner.now(), written, ns) else { return }
  guard !self.reloading.val.contains(key) else { return }
  let pending : @async.Lazy[Unit] = @async.Lazy(async fn() { reload() })
  ignore(self.reloading.val.set(key, pending))
  match self.spawn {
    None => ()
    Some(run) =>
      run(async fn() {
        ignore(pending.wait())
        ignore(self.reloading.val.remove(key))
      })
  }
}

///|
/// Reloads `key` behind a read, keeping the old value if the loader raises and
/// telling `on_failure`.
fn[K : Eq + Hash, V] AsyncCache::reload_if_stale(
  self : AsyncCache[K, V],
  key : K,
  loader : async (K) -> V,
  refresh_after : Int64?,
) -> Unit {
  self.start_reload(
    key,
    async fn() {
      try {
        let value = loader(key)
        self.inner.set(key, value)
      } catch {
        e =>
          match self.refresh {
            Some(r) =>
              match r.on_failure {
                Some(f) => f(key, e)
                None => ()
              }
            None => ()
          }
      }
    },
    refresh_after,
  )
}

///|
/// The same for a loader that may answer "no value": such an answer leaves the
/// old value alone, because a reload that found nothing is not a value worth
/// replacing a usable one with.
fn[K : Eq + Hash, V] AsyncCache::reload_if_stale_opt(
  self : AsyncCache[K, V],
  key : K,
  loader : async (K) -> V?,
  refresh_after : Int64?,
) -> Unit {
  self.start_reload(
    key,
    async fn() {
      try {
        match loader(key) {
          Some(value) => self.inner.set(key, value)
          None => ()
        }
      } catch {
        e =>
          match self.refresh {
            Some(r) =>
              match r.on_failure {
                Some(f) => f(key, e)
                None => ()
              }
            None => ()
          }
      }
    },
    refresh_after,
  )
}

///|
/// Waits for every reload that is waiting to run, and for the ones already
/// running. A cache built without a `spawn` never reloads by itself, so this is
/// how its caller drives refreshes; a test uses it to make a reload happen at a
/// point it chooses instead of at a time it hopes for.
pub async fn[K : Eq + Hash, V] AsyncCache::settle(
  self : AsyncCache[K, V],
) -> Unit {
  for pair in self.reloading.val.to_array() {
    ignore(pair.1.wait())
    ignore(self.reloading.val.remove(pair.0))
  }
}
