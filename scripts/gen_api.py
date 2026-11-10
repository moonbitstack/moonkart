#!/usr/bin/env python3
"""Render docs/api.html from the package interfaces and their doc comments.

The interface of every package is read from its `pkg.generated.mbti`; the prose
comes from the `///|` block above each declaration in the sources. Running this
twice produces the same file, so CI can re-run it and diff.
"""

import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

PACKAGES = [
    ("moonbitstack/moonkart", "src", "moonkart",
     "The cache itself: constructors, reads and writes, expiry, invalidation, and the counters.",
     None),
    ("moonbitstack/moonkart/concurrent", "src/concurrent", "concurrent",
     "The same cache behind an await, with loads coalesced per key, and the same cache split over independent shards.",
     None),
    ("moonbitstack/moonkart/policy", "src/policy", "policy",
     "Eviction policies. The cache sees them only through this contract, so a third-party policy plugs in without touching it.",
     None),
    ("moonbitstack/moonkart/disk", "src/disk", "disk",
     "A memory cache and a bounded file behind it, for the native target.",
     "Native only: the filesystem in the standard library is asynchronous and native-only. "
     "`storage` offers the same contract on the js target."),
    ("moonbitstack/moonkart/storage", "src/storage", "storage",
     "The same second tier over a store of strings, such as the browser's localStorage.",
     "`local_storage()` and `StorageCache::watch` exist on the js target only, where they bind "
     "`localStorage` and its `storage` event."),
    ("moonbitstack/moonkart/tier", "src/tier", "tier",
     "The bookkeeping both second tiers share: which keys a slower medium holds, how big they are, and who leaves.",
     None),
]

DOC_BLOCK = re.compile(r"((?:^[ \t]*///.*\n)+)", re.M)
DECL = re.compile(
    r"^[ \t]*"
    # `pub using @tier {type Stats}`: the item it re-exports is the one described
    r"(?:pub[ \t]+using[ \t]+\S+[ \t]*\{[ \t]*(?:type|let|fn)[ \t]+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
    r"|(?:pub(?:[ \t]*\([a-z]+\))?[ \t]+)?"
    r"(?:fn|struct|enum|let|trait|type)(?:[ \t]+|(?=\[))"
    r"(?:\[[^\]]*\][ \t]*)?([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)?))",
    re.M,
)


def collect_docs(directory: pathlib.Path) -> dict:
    """Map a declared name to the prose above it."""
    found = {}
    for path in sorted(directory.rglob("*.mbt")):
        text = path.read_text(encoding="utf-8")
        for match in DOC_BLOCK.finditer(text):
            block = match.group(1)
            rest = text[match.end():]
            # an attribute such as #warnings may sit between the prose and the item
            rest = re.sub(r"^(?:[ \t]*#[^\n]*\n)+", "", rest)
            decl = DECL.match(rest)
            if not decl:
                continue
            lines = []
            for line in block.splitlines():
                line = line.strip()
                if not line.startswith("///"):
                    continue
                line = line[3:].strip()
                if line in ("", "|"):
                    continue
                lines.append(line)
            if not lines:
                continue
            name = decl.group(1) or decl.group(2)
            # `Cache::get` keeps its own entry, so a method is not described by
            # the paragraph above its type.
            found.setdefault(name, " ".join(lines))
    return found


def split_signature(line: str):
    """Split an mbti line into a kind, a display name, and the signature."""
    kind = "value"
    body = line
    for prefix in ("pub(all) ", "pub(open) ", "pub "):
        if body.startswith(prefix):
            body = body[len(prefix):]
            break
    shown = body
    # `async fn` is one declaration, and the modifier sits before the keyword
    probe = body[len("async "):] if body.startswith("async ") else body
    for word in ("fn", "struct", "enum", "type", "let", "using", "trait", "impl"):
        # `fn[K, V] name(...)` has no space between the keyword and its generics
        if probe.startswith(word + " ") or probe.startswith(word + "["):
            kind = word
            probe = probe[len(word):].lstrip()
            break
    body = probe.strip()
    # drop a generic parameter list to find the name
    name_text = body
    if name_text.startswith("["):
        depth = 0
        for i, ch in enumerate(name_text):
            if ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    name_text = name_text[i + 1:].strip()
                    break
    name = re.match(r"([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)?)", name_text)
    if kind == "using":
        # `using @tier {type Stats}` is described by the item it re-exports
        re_exported = re.search(r"(?:type|let|fn)\s+([A-Za-z_][A-Za-z0-9_]*)", shown)
        if re_exported:
            return kind, re_exported.group(1), shown
    return kind, (name.group(1) if name else body[:40]), shown.rstrip("{").strip()


DECLARATION = re.compile(r"^pub(?:\s*\([a-z]+\))?\s+")

TRAIT_HEAD = re.compile(r"^pub(?:\s*\(open\))?\s+trait\s+([A-Za-z_][A-Za-z0-9_]*)")


def parse_mbti(path: pathlib.Path):
    """Yield (section, kind, name, signature) for each public declaration."""
    section = "Values"
    trait = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if raw.startswith("// "):
            section = raw[3:].strip()
            continue
        head = TRAIT_HEAD.match(line)
        if head:
            trait = head.group(1)
            kind, name, sig = split_signature(line)
            yield section, kind, name, sig
            continue
        if trait is not None:
            if line == "}":
                trait = None
                continue
            if line.startswith("fn ") or line.startswith("pub fn "):
                kind, name, sig = split_signature(
                    line if line.startswith("pub ") else "pub " + line
                )
                # a method of a trait is reached through the trait, so it is
                # named that way and keeps the trait's own paragraph above it
                yield section, kind, f"{trait}::{name}", f"fn {sig[len('fn '):]}"
                continue
        if not DECLARATION.match(line):
            continue
        kind, name, sig = split_signature(line)
        if name in ("struct", "enum", "trait"):
            continue
        yield section, kind, name, sig


def prose(text: str) -> str:
    """Escape prose, then let `code` and [name] keep their meaning as code."""
    out = html.escape(text)
    out = re.sub(r"\[`([^`]+)`\]", r"<code>\1</code>", out)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\[([^\]]+)\]", r"<code>\1</code>", out)
    return out


def render() -> str:
    toc = []
    body = []
    for module, folder, anchor, blurb, note in PACKAGES:
        mbti = ROOT / folder / "pkg.generated.mbti"
        if not mbti.exists():
            continue
        docs = collect_docs(ROOT / folder)
        groups: dict[str, list] = {}
        for section, kind, name, sig in parse_mbti(mbti):
            owner = name.split("::")[0]
            groups.setdefault(section, []).append(
                (kind, name, sig, docs.get(name) or docs.get(owner, ""))
            )

        heading = [f'<section class="chapter chapter--long panel" id="{anchor}">',
                   f'<span class="chapter__eyebrow">{html.escape(module)}</span>',
                   f'<h2>{html.escape(module.split("/")[-1])}</h2>',
                   f'<p>{html.escape(blurb)}</p>']
        if note:
            heading.append(f'<div class="note"><span>{prose(note)}</span></div>')
        if not groups:
            # A package whose files are all gated to one target has no interface
            # to dump. Name it anyway, and say where its reference is.
            toc.append(f'<li><a href="#{anchor}">{module.split("/")[-1]}</a></li>')
            heading.append(
                '<p>Every file of this package is gated to one target, so the '
                'interface dump is empty and the readme is its reference. Give the '
                'module a canonical backend on that target to list it here.</p>'
            )
            heading.append("</section>")
            body.append("\n".join(heading))
            continue
        toc.append(f'<li><a href="#{anchor}">{module.split("/")[-1]}</a></li>')
        parts = list(heading)
        order = ["Values", "Types and methods", "Type aliases", "Errors", "Traits"]
        for section in order + [s for s in groups if s not in order]:
            items = groups.get(section)
            if not items:
                continue
            label = {"Values": "Functions and values",
                     "Type aliases": "Type aliases"}.get(section, section)
            parts.append(f'<h3 class="api__h">{label}</h3><dl class="api">')
            for kind, name, sig, doc in sorted(items, key=lambda row: row[1].lower()):
                if kind == "impl":
                    # an impl carries no prose of its own; say what it is instead
                    # of leaving a hole in the page
                    target = sig[len("impl "):]
                    parts_of = target.split(" for ")
                    doc = (
                        f"Implements the methods of `{parts_of[0]}` for "
                        f"`{parts_of[1]}`." if len(parts_of) == 2 else ""
                    )
                shown = html.escape(sig)
                parts.append(f'<dt><code>{shown}</code></dt>')
                parts.append(f'<dd>{prose(doc) if doc else "<span class=\'api__none\'>No description yet.</span>"}</dd>')
            parts.append("</dl>")
        parts.append("</section>")
        rendered = "\n".join(parts)
        missing = [
            shown
            for line in mbti.read_text(encoding="utf-8").splitlines()
            if (shown := split_signature(line.strip())[2])
            and line.strip().startswith("pub")
            and html.escape(shown) not in rendered
        ]
        if missing:
            raise SystemExit(f"{module}: not listed: {missing}")
        body.append(rendered)

    nav = "\n".join(f"      {item}" for item in toc)
    return f"""<!doctype html>
<html lang="en" class="at-top">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>API &mdash; moonkart</title>
<meta name="description" content="Every public type, function and method in moonkart, generated from the package interfaces.">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='3' fill='%23c9a678'/%3E%3Cpath d='M5 12 16 6l11 6v14l-11 6-11-6z' fill='%23e0c69e' stroke='%236b4a2f' stroke-width='1.6' stroke-linejoin='round'/%3E%3Cpath d='M5 12l11 6 11-6M16 18v14' stroke='%236b4a2f' stroke-width='1.6' fill='none' stroke-linejoin='round'/%3E%3C/svg%3E">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Caveat:wght@400..700&family=Kalam:wght@300;400;700&family=Permanent+Marker&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="./site.css">
<script src="./shell.js" defer></script>
</head>
<body>
<div class="lamp" aria-hidden="true"></div>
<div class="grain" aria-hidden="true"></div>
<div class="walls" aria-hidden="true"><i></i><b></b></div>
<div class="rail" aria-hidden="true"><span class="rail__thumb"></span></div>
<div class="shell doc">

<header class="bar panel">
  <a class="ticket" href="./index.html">
    <svg class="ticket__mark" viewBox="0 0 32 32" aria-hidden="true">
      <path d="M4 11.5 16 5l12 6.5v14L16 32 4 25.5z" fill="#e8cea0" stroke="#6b4a2f" stroke-width="1.7" stroke-linejoin="round"/>
      <path d="M4 11.5 16 18l12-6.5M16 18v13.6" stroke="#6b4a2f" stroke-width="1.7" fill="none" stroke-linejoin="round"/>
    </svg>
    <span class="ticket__name">moonkart</span>
    <span class="ticket__no"><b>API</b>every package</span>
  </a>
  <nav class="nav" aria-label="Main">
    <a href="./index.html">Home</a>
    <a href="./guide.html">Guide</a>
    <a href="./inside.html">Inside</a>
    <a href="./api.html" aria-current="page">API</a>
    <a href="https://github.com/moonbitstack/moonkart">GitHub</a>
  </nav>
</header>

<aside class="toc panel">
  <h2>Packages</h2>
  <ol>
{nav}
  </ol>
</aside>

<main class="doc__body">
{chr(10).join(body)}

  <nav class="pager">
    <a href="./guide.html">&larr; Guide</a>
    <a href="./index.html">Home &rarr;</a>
  </nav>
</main>

<footer class="foot panel">
  <div>
    <p class="foot__note">Generated from the package interfaces.</p>
    <p class="foot__lic">Apache 2.0</p>
  </div>
  <nav class="foot__links" aria-label="Elsewhere">
    <a href="./index.html">Home</a>
    <a href="./guide.html">Guide</a>
    <a href="./inside.html">Inside</a>
    <a href="https://github.com/moonbitstack/moonkart">GitHub</a>
    <a href="https://mooncakes.io/docs/moonbitstack/moonkart">MoonCakes</a>
  </nav>
  <div class="stamp" aria-hidden="true"><span><b>PACKED</b>IN MOONBIT</span></div>
</footer>

</div>
</body>
</html>
"""


if __name__ == "__main__":
    (DOCS / "api.html").write_text(render(), encoding="utf-8", newline="\n")
    print("wrote docs/api.html")
