// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn flat(code : String) -> String {
  let out = StringBuilder()
  for c in code {
    if c != ' ' && c != '\n' {
      out.write_char(c)
    }
  }
  out.to_string().replace_all(old=",)", new=")").replace_all(old=",]", new="]")
}

///|
fn generate(source : String) -> String raise {
  flat(@gen.render(Cached::{ }, [("m.mbt", source)]))
}

///|
fn refused(source : String) -> String {
  try {
    ignore(generate(source))
    ""
  } catch {
    e => "\{e}"
  }
}

///|
test "a function keeps 128 results under the default policy when nothing says" {
  let code = generate("#kart.cached\npub fn f(n : Int) -> Int {\n  n\n}")
  assert_true(code.contains(flat("pub fn f_cached(n : Int) -> Int")))
  assert_true(code.contains(flat("pub fn f_cached_clear() -> Unit")))
  assert_true(code.contains(flat("@moonkart.tinylfu_cache(cap=128L)")))
  assert_true(code.contains(flat("@moonkart.Cache[Int, Int, @policy.Tinylfu]")))
}

///|
test "several parameters are a tuple key, and none is a unit key" {
  let code = generate(
    "#kart.cached\nfn f(a : Int, b : String) -> Int {\n  a\n}",
  )
  assert_true(code.contains(flat("@moonkart.Cache[(Int, String), Int")))
  assert_true(code.contains(flat("let (a, b) = key")))
  let code = generate("#kart.cached\nfn f() -> Int {\n  1\n}")
  assert_true(code.contains(flat("@moonkart.Cache[Unit, Int")))
}

///|
test "the capacity, policy, name and expiry are the annotation's" {
  let code = generate(
    "#kart.cached(name=\"g\", capacity=\"9\", policy=\"lru\", ttl=\"60s\")\nfn f(a : Int) -> Int {\n  a\n}",
  )
  assert_true(code.contains(flat("fn g(a : Int)")))
  assert_true(code.contains(flat("fn g_clear()")))
  assert_true(
    code.contains(
      flat("@moonkart.lru_cache(cap=9L, expiry=@moonkart.ttl(60000000000L))"),
    ),
  )
  let code = generate(
    "#kart.cached(policy=\"s3fifo\", tti=\"250ms\")\nfn f(a : Int) -> Int {\n  a\n}",
  )
  assert_true(code.contains(flat("expiry=@moonkart.tti(250000000L)")))
  assert_true(code.contains(flat("@policy.S3Fifo")))
}

///|
test "minutes and hours are durations" {
  assert_eq(nanos("5m", ""), 300000000000L)
  assert_eq(nanos("1h", ""), 3600000000000L)
}

///|
test "an async function goes through the async cache" {
  let code = generate("#kart.cached\nasync fn f(a : Int) -> Int {\n  a\n}")
  assert_true(code.contains(flat("async fn f_cached(a : Int)")))
  assert_true(code.contains(flat("@concurrent.AsyncCache::new")))
  assert_true(code.contains(".inner().invalidate_all()"))
}

///|
test "what cannot be cached is refused, with where" {
  let cases : Array[(String, String)] = [
    ("#kart.cached\nfn f() -> Unit {\n}", "returns what it remembers"),
    ("#kart.cached\nfn f(a : Int) -> Int raise {\n  a\n}", "a raising function"),
    (
      "#kart.cached\nfn T::f(self : T) -> Int {\n  1\n}", "goes on a free function",
    ),
    ("#kart.cached\nstruct S {\n  a : Int\n}", "goes on a free function"),
    ("#kart.cached\nfn f(a~ : Int) -> Int {\n  a\n}", "they are plain"),
    ("#kart.cached(policy=\"fifo\")\nfn f() -> Int {\n  1\n}", "`policy` is"),
    ("#kart.cached(capacity=\"0\")\nfn f() -> Int {\n  1\n}", "`capacity` is"),
    ("#kart.cached(capacity=\"x\")\nfn f() -> Int {\n  1\n}", "`capacity` is"),
    (
      "#kart.cached(ttl=\"1s\", tti=\"1s\")\nfn f() -> Int {\n  1\n}", "not both",
    ),
    ("#kart.cached(ttl=\"soon\")\nfn f() -> Int {\n  1\n}", "not a duration"),
    (
      "#kart.cached(ttl=\"0s\")\nfn f() -> Int {\n  1\n}", "not a positive duration",
    ),
    ("#kart.cached\n#kart.cached\nfn f() -> Int {\n  1\n}", "written twice"),
    ("#kart.other\nfn f() -> Int {\n  1\n}", "not a moonkart annotation"),
  ]
  for one in cases {
    let (source, want) = one
    let got = refused(source)
    assert_true(got.contains(want), msg="\{source}\nwanted \{want}\ngot \{got}")
  }
}
