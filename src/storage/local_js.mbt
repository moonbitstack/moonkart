// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The browser binding: `localStorage` as a `Storage`, and the `storage` event as
// the way another tab's write reaches this one. Both are plain JS calls, so they
// exist on the js target only.

///|
/// The browser's `localStorage`: one string under each key, kept across reloads
/// and shared with every other tab of the same origin.
#external
pub type LocalStorage

///|
/// The browser's `localStorage`, ready to hand to [`StorageCache::open`].
pub fn local_storage() -> LocalStorage {
  js_local_storage()
}

///|
/// The store itself.
extern "js" fn js_local_storage() -> LocalStorage =
  #| () => globalThis.localStorage

///|
/// Whether `key` is present. A missing entry is what `getItem` answers `null`
/// for, and an empty string is a value like any other, so the two calls are kept
/// apart.
extern "js" fn LocalStorage::has_item(
  self : LocalStorage,
  key : String,
) -> Bool =
  #| (self, key) => self.getItem(key) !== null

///|
extern "js" fn LocalStorage::get_item(
  self : LocalStorage,
  key : String,
) -> String =
  #| (self, key) => {
  #|   const value = self.getItem(key);
  #|   return value === null ? "" : value;
  #| }

///|
extern "js" fn LocalStorage::set_item(
  self : LocalStorage,
  key : String,
  value : String,
) =
  #| (self, key, value) => self.setItem(key, value)

///|
extern "js" fn LocalStorage::remove_item(self : LocalStorage, key : String) =
  #| (self, key) => self.removeItem(key)

///|
extern "js" fn LocalStorage::item_count(self : LocalStorage) -> Int32 =
  #| (self) => self.length

///|
extern "js" fn LocalStorage::key_at(
  self : LocalStorage,
  index : Int32,
) -> String =
  #| (self, index) => {
  #|   const key = self.key(index);
  #|   return key === null ? "" : key;
  #| }

///|
pub impl Storage for LocalStorage with fn get(self : LocalStorage, key : String) -> String? {
  if self.has_item(key) {
    Some(self.get_item(key))
  } else {
    None
  }
}

///|
pub impl Storage for LocalStorage with fn set(
  self : LocalStorage,
  key : String,
  value : String,
) -> Unit {
  self.set_item(key, value)
}

///|
pub impl Storage for LocalStorage with fn remove(
  self : LocalStorage,
  key : String,
) -> Unit {
  self.remove_item(key)
}

///|
pub impl Storage for LocalStorage with fn keys(self : LocalStorage) -> Array[
  String,
] {
  // `localStorage` lists its keys in the order they were first written, which is
  // the order the tier wants for deciding what does not fit.
  let out : Array[String] = []
  for i = 0; i < self.item_count(); i = i + 1 {
    out.push(self.key_at(i))
  }
  out
}

///|
pub extend LocalStorage with Storage::{get, set, remove, keys}

///|
/// Hears the other tabs. Every `storage` event belongs to a write another tab
/// made, and the ones under this cache's prefix drop their key from memory, so
/// the next read takes the value that tab wrote. Call it once; the listener lives
/// as long as the page.
pub fn[K : Eq + Hash, V] StorageCache::watch(self : StorageCache[K, V]) -> Unit {
  on_storage_event(fn(text) { ignore(self.apply_storage_event(text)) })
}

///|
extern "js" fn on_storage_event(cb : (String) -> Unit) =
  #| (cb) => {
  #|   const target = globalThis;
  #|   if (typeof target.addEventListener !== "function") return;
  #|   target.addEventListener("storage", (event) => {
  #|     if (typeof event.key === "string") cb(event.key);
  #|   });
  #| }
