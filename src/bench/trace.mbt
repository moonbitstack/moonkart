// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn is_space(c : UInt16) -> Bool {
  c == 32 || c == 10 || c == 13 || c == 9
}

///|
fn is_digit(c : UInt16) -> Bool {
  c >= 48 && c <= 57
}

///|
/// Reads the first whitespace-separated column of every non-empty line as the
/// request key. The ARC `.lis` traces carry extra weight columns after the key;
/// only the key drives a hit-or-miss replay, so the rest is ignored.
pub fn parse_keys(text : String) -> Array[Int32] {
  let out : Array[Int32] = []
  let n = text.length()
  let mut i = 0
  while i < n {
    while i < n && is_space(text[i]) {
      i = i + 1
    }
    if i >= n {
      break
    }
    let mut v = 0
    let mut any = false
    while i < n && is_digit(text[i]) {
      v = v * 10 + (text[i].to_int() - 48)
      i = i + 1
      any = true
    }
    if any {
      out.push(v)
    }
    while i < n && text[i] != 10 {
      i = i + 1
    }
  }
  out
}
