// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The tier decides who gets the last byte, and the medium is not needed to judge
// that: a hit here is a key the tier still holds when it is asked for.

///|
/// A skewed stream: seven requests in ten name one of ten hot keys, the rest
/// walk a long list of keys that are asked for once. Returns the hits.
fn[K : Eq + Hash] replay(
  tier : @tier.Tier[K],
  requests : Int32,
  key_of : (Int32) -> K,
) -> Int64 {
  let mut hits : Int64 = 0
  let mut slot : Int64 = 0
  for i = 0; i < requests; i = i + 1 {
    let key = key_of(i)
    if tier.contains(key) {
      hits = hits + 1
      tier.promote(key)
    } else {
      ignore(tier.admit(key, slot, 17))
      slot = slot + 17
    }
  }
  hits
}

///|
/// The ith request of the skewed stream above. The order is scrambled by the same
/// hash the sketch uses, so the run is reproducible and neighbouring requests do
/// not walk the keys in step.
fn skewed_key(i : Int32) -> Int32 {
  let hot = (i / 10 * 7 + i * 3) % 10
  let pick = i % 10
  if pick < 7 {
    hot
  } else {
    1000 + i
  }
}

///|
fn tier_of(admission : @policy.Admission, budget : Int64) -> @tier.Tier[Int32] {
  @tier.Tier::new(admission, budget, fn(key) { key })
}

///|
test "a skewed stream hits more with value admission than with taking all" {
  // Room for twelve 17-byte records, so the ten hot keys would fit if nothing
  // pushed them out.
  let taking = replay(tier_of(@policy.TakeAll, 204L), 2000, skewed_key)
  let by_value = replay(tier_of(@policy.ByValue, 204L), 2000, skewed_key)
  // Taking everything keeps the newest record and loses the hot keys to every
  // scan; the sketch makes the hot keys outrank the newcomers.
  // 1,194 of 2,000 requests against 1,285: taking everything spends the budget
  // on whatever arrived last, and a scan of new keys then flushes the ten keys
  // that carry seven requests in ten.
  assert_eq(taking, 1194L)
  assert_eq(by_value, 1285L)
}

///|
test "a record seen less often than a resident one is turned away" {
  // Room for two records.
  let tier = tier_of(@policy.ByValue, 34L)
  ignore(tier.admit(1, 0, 17))
  for i = 0; i < 5; i = i + 1 {
    tier.promote(1)
  }
  assert_eq(tier.frequency(1), 6)
  ignore(tier.admit(2, 17, 17))
  // The budget is spent, and the newcomer is seen once: it does not get in, and
  // it is named among the keys the medium must delete.
  assert_eq(tier.admit(3, 34, 17), [3])
  assert_eq(tier.contains(3), false)
  assert_eq(tier.contains(1), true)
  assert_eq(tier.stats().denied, 1L)
  assert_eq(tier.stats().evictions, 0L)
}

///|
test "taking everything evicts the least recently used record" {
  let tier = tier_of(@policy.TakeAll, 34L)
  ignore(tier.admit(1, 0, 17))
  ignore(tier.admit(2, 17, 17))
  tier.promote(1)
  ignore(tier.admit(3, 34, 17))
  assert_eq(tier.contains(1), true)
  assert_eq(tier.contains(2), false)
  assert_eq(tier.contains(3), true)
  assert_eq(tier.stats().evictions, 1L)
  assert_eq(tier.stats().denied, 0L)
}

///|
test "a read from the medium counts as a sighting" {
  let tier = tier_of(@policy.ByValue, 102L)
  ignore(tier.admit(7, 0, 17))
  tier.promote(7)
  tier.promote(7)
  assert_eq(tier.frequency(7), 3)
  assert_eq(tier.stats().promotions, 2L)
}

///|
test "a record the medium keeps but the tier drops frees its bytes" {
  let tier = tier_of(@policy.TakeAll, 102L)
  ignore(tier.admit(1, 0, 17))
  ignore(tier.admit(2, 17, 17))
  assert_eq(tier.bytes(), 34L)
  assert_eq(tier.discharge(2) is Some(_), true)
  assert_eq(tier.bytes(), 17L)
  assert_eq(tier.contains(2), false)
}

///|
test "a budget of nothing keeps everything" {
  let tier = @tier.Tier::new(@policy.ByValue, 0L, fn(key) { key })
  for i = 0; i < 50; i = i + 1 {
    assert_eq(tier.admit(i, i.to_int64() * 17L, 17).length(), 0)
  }
  assert_eq(tier.stats().entries, 50L)
  assert_eq(tier.stats().evictions, 0L)
}

///|
test "a record adopted from the medium counts as a read" {
  let tier = tier_of(@policy.ByValue, 102L)
  ignore(tier.adopt(5, 0, 17))
  // The medium answered a read, so the key is both recent and seen.
  assert_eq(tier.stats().promotions, 1L)
  assert_eq(tier.frequency(5), 1)
}
