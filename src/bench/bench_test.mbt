// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Replays a prefix of the ARC OLTP trace through each shipped policy. The full
/// trace is too large for the repository and too slow for every CI run, so the
/// test pins a short prefix.
///
/// Two properties are checked. Every policy must finish with its cache full:
/// a policy that leaks weight stops admitting early and under-fills, which is
/// what a lost weight accounted for by hand does. And frequency-aware admission
/// must beat pure recency by a margin larger than the run-to-run spread: the
/// frequency sketch is keyed by the runtime's hash seed, so a seed change
/// reshuffles collisions and moves the TinyLFU figure by about half a point.
test "policies replay a truncated ARC trace" {
  let keys = @bench.truncated_oltp()
  let cap = 500L
  let (lru, lru_size, _) = @bench.replay_stats(keys, "lru", cap)
  let (s3fifo, s3fifo_size, _) = @bench.replay_stats(keys, "s3fifo", cap)
  let (tinylfu, tinylfu_size, _) = @bench.replay_stats(keys, "tinylfu", cap)
  println("lru=\{lru} s3fifo=\{s3fifo} tinylfu=\{tinylfu}")
  assert_true(lru >= 0.0 && lru <= 1.0)
  assert_true(s3fifo >= 0.0 && s3fifo <= 1.0)
  assert_true(tinylfu >= 0.0 && tinylfu <= 1.0)
  assert_eq(lru_size, cap)
  assert_eq(s3fifo_size, cap)
  assert_eq(tinylfu_size, cap)
  assert_true(s3fifo >= lru)
  assert_true(tinylfu >= lru + 0.03)
}

///|
test "parse_keys reads the first column and skips the weight columns" {
  let keys = @bench.parse_keys("1 8 0 0\n2 8 0 0\n\n3 1 0 0\n")
  assert_eq(keys.length(), 3)
  assert_eq(keys[0], 1)
  assert_eq(keys[1], 2)
  assert_eq(keys[2], 3)
}
