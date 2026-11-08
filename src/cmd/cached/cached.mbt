// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// `#kart.cached` on a free function, turned into `<name>_cached`, which remembers
/// what the function returned, and `<name>_cached_clear`, which forgets. The
/// function itself is not touched, since a generator can only add code.
priv struct Cached {}

///|
impl @gen.Generator for Cached with fn name(_) {
  "moonkart cached"
}

///|
let cached_spec : @attr.Spec = @attr.Spec::new("kart.cached")
  .optional("name", Str)
  .optional("capacity", Str)
  .optional("policy", Str)
  .optional("ttl", Str)
  .optional("tti", Str)

///|
/// `#kart.once` takes no options: one value, kept forever, is not a cache to tune.
let once_spec : @attr.Spec = @attr.Spec::new("kart.once")

///|
/// `#kart.count_calls` takes no options either; it only adds a counter.
let calls_spec : @attr.Spec = @attr.Spec::new("kart.count_calls")

///|
/// How many results a function keeps when nothing says: `functools.lru_cache`'s
/// default.
let capacity : String = "128"

///|
fn at(attr : @attribute.Attribute, file : String) -> String {
  "\{file}:\{attr.loc.start.lnum}:\{attr.loc.start.column()}"
}

///|
fn kart_attrs(
  attrs : @list.List[@attribute.Attribute],
  file : String,
) -> Array[@attribute.Attribute] raise {
  for attr in attrs {
    if @attr.name_of(attr) is None && attr.raw.has_prefix("#kart.") {
      fail("\{at(attr, file)}: `\{attr.raw}` does not parse as an annotation")
    }
  }
  @attr.under(attrs, "kart")
}

///|
/// A duration such as `250ms`, `60s`, `5m` or `1h`, in nanoseconds, the unit the
/// cache's clock runs in.
fn nanos(text : String, where_ : String) -> Int64 raise {
  let (digits, scale) = if text.has_suffix("ms") {
    (text.exact_view(end=text.length() - 2), 1000000L)
  } else if text.has_suffix("s") {
    (text.exact_view(end=text.length() - 1), 1000000000L)
  } else if text.has_suffix("m") {
    (text.exact_view(end=text.length() - 1), 60000000000L)
  } else if text.has_suffix("h") {
    (text.exact_view(end=text.length() - 1), 3600000000000L)
  } else {
    fail(
      "\{where_}: `\{text}` is not a duration: write `250ms`, `60s`, `5m` or `1h`",
    )
  }
  let number = @string.parse_int64(digits.to_owned()) catch {
    _ => fail("\{where_}: `\{text}` is not a duration")
  }
  if number <= 0L {
    fail("\{where_}: `\{text}` is not a positive duration")
  }
  number * scale
}

///|
/// The constructor a `policy=` names, and the type of the cache it builds.
fn policy_of(name : String, where_ : String) -> String raise {
  match name {
    "lru" => "lru_cache"
    "s3fifo" => "s3fifo_cache"
    "tinylfu" => "tinylfu_cache"
    _ => fail("\{where_}: `policy` is lru, s3fifo or tinylfu, not `\{name}`")
  }
}

///|
fn snake_free(name : String) -> Bool {
  !name.contains("::")
}

///|
/// The wrapper of one annotated function. `once` keeps one value with no
/// arguments and no way back; `count` adds the function that reports how many
/// times the remembered function really ran.
fn wrapper(
  note : @attribute.Attribute,
  name : String,
  params : Array[@gen.Param],
  returns : String?,
  is_async : Bool,
  public : Bool,
  file : String,
  once : Bool,
  count : Bool,
) -> String raise {
  let where_ = at(note, file)
  let args = if once {
    ignore(once_spec.bind(note))
    None
  } else {
    Some(cached_spec.bind(note))
  }
  guard returns is Some(value) && value != "Unit" else {
    fail("\{where_}: a remembered function returns what it remembers")
  }
  if !snake_free(name) {
    fail("\{where_}: the annotation goes on a free function")
  }
  let names = []
  let types = []
  for param in params {
    guard param.name is Some(p) &&
      param.ty is Some(ty) &&
      param.pass is Positional else {
      fail(
        "\{where_}: the arguments of a remembered function are its key, so they are plain",
      )
    }
    names.push(p)
    types.push(ty)
  }
  if once && !names.is_empty() {
    fail(
      "\{where_}: `#kart.once` keeps one value, so the function takes no arguments",
    )
  }
  let (key_type, key) = match (names, types) {
    ([], _) => ("Unit", "()")
    ([one], [ty]) => (ty, one)
    _ => ("(\{types.join(", ")})", "(\{names.join(", ")})")
  }
  let cached = match args {
    Some(a) => a.str("name").unwrap_or(name + "_cached")
    None => name + "_once"
  }
  let build = match args {
    Some(a) => policy_of(a.str("policy").unwrap_or("tinylfu"), where_)
    None => "lru_cache"
  }
  let size = match args {
    Some(a) => a.str("capacity").unwrap_or(capacity)
    None => "1"
  }
  guard size is [_, ..] &&
    size.iter().all(c => c is ('0'..<='9')) &&
    size != "0" else {
    fail("\{where_}: `capacity` is a positive number, not `\{size}`")
  }
  let expiry = match args {
    Some(a) =>
      if a.str("ttl") is Some(_) && a.str("tti") is Some(_) {
        fail("\{where_}: give `ttl` or `tti`, not both")
      } else {
        match (a.str("ttl"), a.str("tti")) {
          (Some(text), _) => ", expiry=@moonkart.ttl(\{nanos(text, where_)}L)"
          (_, Some(text)) => ", expiry=@moonkart.tti(\{nanos(text, where_)}L)"
          _ => ""
        }
      }
    None => ""
  }
  let vis = if public { "pub " } else { "" }
  let holder = cached + "_store"
  let signature = names.mapi((i, p) => "\{p} : \{types[i]}").join(", ")
  let inner = "@moonkart.\{build}(cap=\{size}L\{expiry})"
  let cache_type = "@moonkart.Cache[\{key_type}, \{value}]"
  let (store, store_type, run, ran) = if is_async {
    (
      "@concurrent.AsyncCache::new(\{inner})",
      "@concurrent.AsyncCache[\{key_type}, \{value}]",
      "async ",
      "\{holder}.inner().stats().miss_count",
    )
  } else {
    (inner, cache_type, "", "\{holder}.stats().miss_count")
  }
  // Nothing puts a one-value store back, so it has nothing to clear.
  let clear = if once {
    ""
  } else if is_async {
    (
      $|
      $|\{vis}fn \{cached}_clear() -> Unit {
      $|  \{holder}.inner().invalidate_all()
      $|}
    )
  } else {
    (
      $|
      $|\{vis}fn \{cached}_clear() -> Unit {
      $|  \{holder}.invalidate_all()
      $|}
    )
  }
  let calls = if count {
    (
      $|
      $|\{vis}fn \{cached}_calls() -> Int64 {
      $|  \{ran}
      $|}
    )
  } else {
    ""
  }
  (
    $|let \{holder} : \{store_type} = \{store}
    $|
    $|\{vis}\{run}fn \{cached}(\{signature}) -> \{value} {
    $|  match \{holder}.get(\{key}) {
    $|    Some(v) => v
    $|    None => {
    $|      let v = \{name}(\{names.join(", ")})
    $|      \{holder}.set(\{key}, v)
    $|      v
    $|    }
    $|  }
    $|}
  ) +
  clear +
  calls
}

///|
impl @gen.Generator for Cached with fn generate(_, decls) {
  let out = []
  for decl in decls {
    match decl {
      Func(
        owner~,
        name~,
        params~,
        returns~,
        is_async~,
        attrs~,
        public~,
        file~,
        raw~
      ) => {
        let found = kart_attrs(attrs, file)
        guard !found.is_empty() else { continue }
        let remembering : Array[@attribute.Attribute] = []
        let mut counting : @attribute.Attribute? = None
        for attr in found {
          match @attr.name_of(attr) {
            Some("kart.cached") | Some("kart.once") => remembering.push(attr)
            Some("kart.count_calls") => {
              ignore(calls_spec.bind(attr))
              match counting {
                Some(_) =>
                  fail(
                    "\{at(attr, file)}: `#kart.count_calls` is written twice",
                  )
                None => counting = Some(attr)
              }
            }
            _ =>
              fail(
                "\{at(attr, file)}: `\{attr.raw}` is not a moonkart annotation",
              )
          }
        }
        if remembering.length() > 1 {
          let first = @attr.name_of(remembering[0]).unwrap_or("")
          let second = @attr.name_of(remembering[1]).unwrap_or("")
          if first == second {
            fail("\{at(remembering[1], file)}: `#\{second}` is written twice")
          } else {
            fail(
              "\{at(remembering[1], file)}: `#\{second}` cannot go beside `#\{first}`: a function is remembered one way",
            )
          }
        }
        guard remembering is [note, ..] else {
          match counting {
            Some(attr) =>
              fail(
                "\{at(attr, file)}: `#kart.count_calls` goes beside `#kart.cached` or `#kart.once`",
              )
            None => continue
          }
        }
        if owner is Some(_) {
          fail("\{at(note, file)}: the annotation goes on a free function")
        }
        guard raw
          is TopFuncDef(
            fun_decl={ error_type: NoErrorType | Noraise(..), .. },
            ..
          ) else {
          fail(
            "\{at(note, file)}: a raising function cannot be remembered: there is nothing to keep when it raises",
          )
        }
        let once = @attr.name_of(note) == Some("kart.once")
        out.push(
          wrapper(
            note,
            name,
            params,
            returns,
            is_async,
            public,
            file,
            once,
            counting is Some(_),
          ),
        )
      }
      Struct(attrs~, file~, ..) | Enum(attrs~, file~, ..) =>
        if kart_attrs(attrs, file) is [first, ..] {
          fail("\{at(first, file)}: the annotation goes on a free function")
        }
      Other(..) => ()
    }
  }
  @quote.items(out.join("\n\n")).render()
}
