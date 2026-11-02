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
fn policy_of(name : String, where_ : String) -> (String, String) raise {
  match name {
    "lru" => ("lru_cache", "Lru")
    "s3fifo" => ("s3fifo_cache", "S3Fifo")
    "tinylfu" => ("tinylfu_cache", "Tinylfu")
    _ => fail("\{where_}: `policy` is lru, s3fifo or tinylfu, not `\{name}`")
  }
}

///|
fn snake_free(name : String) -> Bool {
  !name.contains("::")
}

///|
/// The wrapper of one annotated function.
fn wrapper(
  note : @attribute.Attribute,
  name : String,
  params : Array[@gen.Param],
  returns : String?,
  is_async : Bool,
  public : Bool,
  file : String,
) -> String raise {
  let where_ = at(note, file)
  let args = cached_spec.bind(note)
  guard returns is Some(value) && value != "Unit" else {
    fail("\{where_}: a cached function returns what it remembers")
  }
  if !snake_free(name) {
    fail("\{where_}: `#kart.cached` goes on a free function")
  }
  let names = []
  let types = []
  for param in params {
    guard param.name is Some(p) &&
      param.ty is Some(ty) &&
      param.pass is Positional else {
      fail(
        "\{where_}: the arguments of a cached function are its key, so they are plain",
      )
    }
    names.push(p)
    types.push(ty)
  }
  let (key_type, key) = match (names, types) {
    ([], _) => ("Unit", "()")
    ([one], [ty]) => (ty, one)
    _ => ("(\{types.join(", ")})", "(\{names.join(", ")})")
  }
  let cached = args.str("name").unwrap_or(name + "_cached")
  let (build, policy) = policy_of(
    args.str("policy").unwrap_or("tinylfu"),
    where_,
  )
  let size = args.str("capacity").unwrap_or(capacity)
  guard size is [_, ..] &&
    size.iter().all(c => c is ('0'..<='9')) &&
    size != "0" else {
    fail("\{where_}: `capacity` is a positive number, not `\{size}`")
  }
  if args.str("ttl") is Some(_) && args.str("tti") is Some(_) {
    fail("\{where_}: give `ttl` or `tti`, not both")
  }
  let expiry = match (args.str("ttl"), args.str("tti")) {
    (Some(text), _) => ", expiry=@moonkart.ttl(\{nanos(text, where_)}L)"
    (_, Some(text)) => ", expiry=@moonkart.tti(\{nanos(text, where_)}L)"
    _ => ""
  }
  let vis = if public { "pub " } else { "" }
  let holder = cached + "_store"
  let signature = names.mapi((i, p) => "\{p} : \{types[i]}").join(", ")
  let unpack = if names.length() > 1 {
    "let (\{names.join(", ")}) = key\n    "
  } else if names.is_empty() {
    "ignore(key)\n    "
  } else {
    "let \{names[0]} = key\n    "
  }
  let inner = "@moonkart.\{build}(cap=\{size}L\{expiry})"
  let cache_type = "@moonkart.Cache[\{key_type}, \{value}, @policy.\{policy}]"
  let (store, store_type, run, clear) = if is_async {
    (
      "@concurrent.AsyncCache::new(\{inner})",
      "@concurrent.AsyncCache[\{key_type}, \{value}, @policy.\{policy}]",
      "async ",
      "\{holder}.inner().invalidate_all()",
    )
  } else {
    (inner, cache_type, "", "\{holder}.invalidate_all()")
  }
  (
    $|let \{holder} : \{store_type} = \{store}
    $|
    $|\{vis}\{run}fn \{cached}(\{signature}) -> \{value} {
    $|  \{holder}.get_with(\{key}, key => {
    $|    \{unpack}\{name}(\{names.join(", ")})
    $|  })
    $|}
    $|
    $|\{vis}fn \{cached}_clear() -> Unit {
    $|  \{clear}
    $|}
  )
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
        guard found is [first, ..] else { continue }
        if found.length() > 1 {
          fail("\{at(found[1], file)}: `#kart.cached` is written twice")
        }
        if @attr.name_of(first) != Some("kart.cached") {
          fail(
            "\{at(first, file)}: `\{first.raw}` is not a moonkart annotation",
          )
        }
        if owner is Some(_) {
          fail("\{at(first, file)}: `#kart.cached` goes on a free function")
        }
        guard raw
          is TopFuncDef(
            fun_decl={ error_type: NoErrorType | Noraise(..), .. },
            ..
          ) else {
          fail(
            "\{at(first, file)}: a raising function cannot be cached: there is nothing to keep when it raises",
          )
        }
        out.push(wrapper(first, name, params, returns, is_async, public, file))
      }
      Struct(attrs~, file~, ..) | Enum(attrs~, file~, ..) =>
        if kart_attrs(attrs, file) is [first, ..] {
          fail("\{at(first, file)}: `#kart.cached` goes on a free function")
        }
      Other(..) => ()
    }
  }
  @quote.items(out.join("\n\n")).render()
}
