// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The order the file evicts in. Keys are kept in a doubly linked list over a
// hash map, so a read moves a key to the back and an eviction takes the front
// without scanning. The links are rebuilt rather than mutated in place: a
// `HashMap` hands back a copy, so a field write on it would be lost.

///|
priv struct Link[K] {
  prev : K?
  next : K?
}

///|
priv struct Lru[K] {
  head : Ref[K?]
  tail : Ref[K?]
  links : @hashmap.HashMap[K, Link[K]]
}

///|
fn[K : Eq + Hash] Lru::new() -> Lru[K] {
  { head: @ref.Ref(None), tail: @ref.Ref(None), links: @hashmap.HashMap([]), }
}

///|
/// The key that would leave first.
fn[K] Lru::front(self : Lru[K]) -> K? {
  self.head.val
}

///|
fn[K : Eq + Hash] Lru::push_back(self : Lru[K], key : K) -> Unit {
  let tail = self.tail.val
  ignore(self.links.set(key, { prev: tail, next: None, }))
  match tail {
    Some(t) =>
      match self.links.get(t) {
        Some(node) =>
          ignore(self.links.set(t, { prev: node.prev, next: Some(key), }))
        None => ()
      }
    None => self.head.val = Some(key)
  }
  self.tail.val = Some(key)
}

///|
fn[K : Eq + Hash] Lru::remove(self : Lru[K], key : K) -> Unit {
  match self.links.get(key) {
    None => ()
    Some(node) => {
      match node.prev {
        Some(p) =>
          match self.links.get(p) {
            Some(before) =>
              ignore(self.links.set(p, { prev: before.prev, next: node.next, }))
            None => ()
          }
        None => self.head.val = node.next
      }
      match node.next {
        Some(n) =>
          match self.links.get(n) {
            Some(after) =>
              ignore(self.links.set(n, { prev: node.prev, next: after.next, }))
            None => ()
          }
        None => self.tail.val = node.prev
      }
      ignore(self.links.remove(key))
    }
  }
}

///|
/// Puts `key` at the back, whether or not it was already in the list.
fn[K : Eq + Hash] Lru::move_to_back(self : Lru[K], key : K) -> Unit {
  if self.links.contains(key) {
    self.remove(key)
  }
  self.push_back(key)
}

///|
/// Every key, least recently used first.
fn[K : Eq + Hash] Lru::to_array(self : Lru[K]) -> Array[K] {
  let out : Array[K] = []
  let mut cursor = self.head.val
  while cursor is Some(key) {
    out.push(key)
    cursor = match self.links.get(key) {
      Some(node) => node.next
      None => None
    }
  }
  out
}
