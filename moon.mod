name = "moonbitstack/moonkart"

version = "0.1.2"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonkart"

license = "Apache-2.0"

keywords = [
  "cache",
  "caching",
  "lru",
  "tinylfu",
  "w-tinylfu",
  "s3fifo",
  "arc",
  "s3-fifo",
  "trace",
  "benchmark",
  "hit-rate",
  "eviction-policy",
  "ttl",
  "tti",
  "expiry",
  "eviction",
  "loader",
  "concurrent",
  "disk-cache",
  "two-tier",
  "refresh",
  "stale-while-revalidate",
  "localstorage",
  "web-storage",
  "admission",
  "caffeine",
  "moka",
  "moonbit",
]

description = "A cache for MoonBit: bounded by count or weight, with expiry, loaders and eviction listeners."

import {
  "moonbitstack/moonast@0.2.7",
  "moonbitlang/parser@0.4.6",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonbase@0.4.4",
}

source = "src"

preferred_target = "native"
