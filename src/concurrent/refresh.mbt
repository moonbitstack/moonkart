// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A hand-off for a background reload: the cache gives the caller a task to run
/// and never waits for it. Wrap a task group with
/// `spawn=fn(task) { group.spawn_bg(task) }`, or collect the tasks and run them
/// yourself, which is what a test wants.
pub type Spawn = (async () -> Unit) -> Unit

///|
/// When a value should be reloaded, and who hears about a reload that failed.
///
/// A value older than `after` still answers a read, and the loader runs behind
/// the read to replace it. The same key has one reload in flight at a time, and a
/// reload that raises leaves the old value in place and reports the error to
/// `on_failure`. `None` never refreshes on its own: the value stays until it
/// expires or is evicted.
///
/// Only the asynchronous cache acts on this. The synchronous cache answers a
/// read and returns, with nowhere to run a reload, so a value there changes only
/// when something writes it.
pub(all) struct Refresh[K] {
  after : Int64?
  on_failure : ((K, Error) -> Unit)?
}

///|
/// A refresh window of `ns` nanoseconds after the write, with nothing listening
/// for failures.
pub fn[K] refresh_every(ns : Int64) -> Refresh[K] {
  { after: Some(ns), on_failure: None, }
}
