// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "a counter stops at its ceiling" {
  let sketch = @policy.Sketch::new(16)
  for i = 0; i < 40; i = i + 1 {
    sketch.record(1234)
  }
  assert_eq(sketch.estimate(1234), 15)
}

///|
test "an unseen hash estimates zero" {
  let sketch = @policy.Sketch::new(16)
  sketch.record(7)
  assert_eq(sketch.estimate(8), 0)
}

///|
test "aging halves every counter" {
  let sketch = @policy.Sketch::new(16)
  for i = 0; i < 7; i = i + 1 {
    sketch.record(99)
  }
  assert_eq(sketch.estimate(99), 7)
  sketch.age()
  assert_eq(sketch.estimate(99), 3)
  sketch.record(99)
  sketch.record(99)
  assert_eq(sketch.estimate(99), 5)
}

///|
test "a full window halves the table by itself" {
  // A capacity of 16 sets the window at 160 records; the 161st halves the table
  // before counting, so a saturated counter reads 15 / 2 + 1.
  let sketch = @policy.Sketch::new(16)
  for i = 0; i < 161; i = i + 1 {
    sketch.record(42)
  }
  assert_eq(sketch.estimate(42), 8)
}
