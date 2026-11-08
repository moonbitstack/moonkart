// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// `#kart.once` keeps a single value with no arguments, and `#kart.count_calls`
// adds the function that says how often the remembered function really ran.
// Both are additions to the same generator, so they share its `generate`,
// `refused` and `flat` helpers.

///|
test "once keeps one value and has nothing to clear" {
  let code = generate("#kart.once\nfn build() -> Int {\n  1\n}")
  assert_true(
    code.contains(flat("let build_once_store : @moonkart.Cache[Unit, Int]")),
  )
  assert_true(code.contains(flat("@moonkart.lru_cache(cap=1L)")))
  assert_true(code.contains(flat("fn build_once() -> Int")))
  assert_true(!code.contains("_clear"))
}

///|
test "once on an async function awaits the same way" {
  let code = generate("#kart.once\nasync fn build() -> Int {\n  1\n}")
  assert_true(code.contains(flat("async fn build_once() -> Int")))
  assert_true(code.contains(flat("@concurrent.AsyncCache::new")))
}

///|
test "count_calls reports how often the function ran, not how often it was asked" {
  let code = generate(
    "#kart.cached\n#kart.count_calls\nfn f(n : Int) -> Int {\n  n\n}",
  )
  assert_true(code.contains(flat("fn f_cached_calls() -> Int64")))
  assert_true(code.contains(flat("f_cached_store.stats().miss_count")))
  assert_true(code.contains(flat("fn f_cached_clear() -> Unit")))
}

///|
test "count_calls goes with once too, and reads the store underneath" {
  let code = generate(
    "#kart.once\n#kart.count_calls\nasync fn build() -> Int {\n  1\n}",
  )
  assert_true(code.contains(flat("fn build_once_calls() -> Int64")))
  assert_true(
    code.contains(flat("build_once_store.inner().stats().miss_count")),
  )
}

///|
test "the new annotations refuse what they cannot mean" {
  let cases : Array[(String, String)] = [
    ("#kart.once\nfn f(a : Int) -> Int {\n  a\n}", "takes no arguments"),
    ("#kart.once\n#kart.cached\nfn f() -> Int {\n  1\n}", "cannot go beside"),
    ("#kart.count_calls\nfn f() -> Int {\n  1\n}", "goes beside"),
    (
      "#kart.cached\n#kart.count_calls\n#kart.count_calls\nfn f() -> Int {\n  1\n}",
      "written twice",
    ),
    ("#kart.once\nfn T::f(self : T) -> Int {\n  1\n}", "free function"),
    ("#kart.once\nfn f() -> Int raise {\n  1\n}", "a raising function"),
  ]
  for one in cases {
    let (source, want) = one
    let got = refused(source)
    assert_true(got.contains(want), msg="\{source}\nwanted \{want}\ngot \{got}")
  }
}
