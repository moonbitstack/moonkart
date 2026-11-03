// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Replays a prefix of the ARC OLTP trace through each shipped policy. The full
/// trace is too large for the repository and too slow for every CI run, so the
/// test pins a short prefix and only checks the ordering the policies are
/// designed to produce: frequency-aware admission does not lose to pure recency
/// on this trace.
test "policies replay a truncated ARC trace" {
  let keys = @bench.truncated_oltp()
  let cap = 500L
  let lru = @bench.hit_rate(keys, "lru", cap)
  let s3fifo = @bench.hit_rate(keys, "s3fifo", cap)
  let tinylfu = @bench.hit_rate(keys, "tinylfu", cap)
  println("lru=\{lru} s3fifo=\{s3fifo} tinylfu=\{tinylfu}")
  assert_true(lru >= 0.0 && lru <= 1.0)
  assert_true(s3fifo >= 0.0 && s3fifo <= 1.0)
  assert_true(tinylfu >= 0.0 && tinylfu <= 1.0)
  assert_true(s3fifo >= lru - 0.01)
  assert_true(tinylfu >= lru + 0.01)
}

///|
test "parse_keys reads the first column and skips the weight columns" {
  let keys = @bench.parse_keys("1 8 0 0\n2 8 0 0\n\n3 1 0 0\n")
  assert_eq(keys.length(), 3)
  assert_eq(keys[0], 1)
  assert_eq(keys[1], 2)
  assert_eq(keys[2], 3)
}
