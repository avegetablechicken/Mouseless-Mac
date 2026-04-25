#!/usr/bin/env python3
"""
Extract the localization map from the Tencent Yuanbao macOS app bundle.

Sources parsed (all three are merged into one map):
  1. Contents/Resources/{en,zh-Hans,zh-Hant}.lproj/InfoPlist.strings
       UTF-16LE Apple `.strings` files (only the bundle display name).
  2. Contents/Resources/locales/{en,zh-cn,zh-hk}/yuanbao.ftl
       Fluent `.ftl` files (native macOS menu items).
  3. Contents/Resources/content.pkg
       ZIP archive of the Next.js web UI.  Chunks under
       `_next/static/chunks/` carry literal "\\uXXXX...":"<value>" pairs
       where the key is a `\\u`-escaped Chinese source string.

The base locale of this app is **zh-CN**: source strings live in the JS
bundle as Chinese, with two parallel translation tables (English, and
Traditional Chinese for zh-HK/zh-TW).

Output JSON written to <output>:
  {
    "by_locale":  { "<locale>": { <zh-CN source> -> <localized> }, ... },
    "by_locale_reverse": { "<locale>": { <localized> -> <zh-CN source> }, ... },
    "stats": { ... }
  }

The reverse map is built with curated-source priority (FTL > InfoPlist >
Next.js chunks): FTL/InfoPlist pairs are inserted last so they overwrite
any colliding pair from a JS chunk (e.g. multiple zh-CN strings mapping
to the same English value).

Usage:
    python3 yuanbao_pkg_parse.py <yuanbao.app> <output.json>
"""

import json
import os
import re
import sys
import zipfile


# ── helpers ──────────────────────────────────────────────────────────────

_HAS_CJK = re.compile(r'[一-鿿]')


def _is_chinese(s: str) -> bool:
    return bool(_HAS_CJK.search(s))


def parse_apple_strings(path):
    """Parse a UTF-16LE Apple `.strings` file ("key" = "value";)."""
    if not os.path.isfile(path):
        return {}
    with open(path, 'rb') as f:
        raw = f.read()
    text = None
    for enc in ('utf-16', 'utf-16-le', 'utf-8'):
        try:
            text = raw.decode(enc).lstrip('﻿')
            break
        except UnicodeDecodeError:
            continue
    if text is None:
        return {}
    out = {}
    pattern = re.compile(
        r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;'
    )
    for m in pattern.finditer(text):
        try:
            k = json.loads('"' + m.group(1) + '"')
            v = json.loads('"' + m.group(2) + '"')
        except ValueError:
            continue
        out[k] = v
    return out


def parse_ftl(path):
    """Parse a Fluent `.ftl` file (key = value, one per line)."""
    if not os.path.isfile(path):
        return {}
    out = {}
    with open(path, 'r', encoding='utf-8') as f:
        for ln in f:
            m = re.match(r'^\s*([\w-]+)\s*=\s*(.+?)\s*$', ln)
            if m:
                out[m.group(1)] = m.group(2)
    return out


# Pair pattern: "<\\u-escaped-Chinese-key>":"<value-with-or-without-CJK>"
_PAIR_RE = re.compile(
    r'"((?:\\u[0-9A-Fa-f]{4}|\\["\\nrtbf/]|[^"\\])+)":'
    r'"((?:\\u[0-9A-Fa-f]{4}|\\["\\nrtbf/]|[^"\\])*)"'
)
# Require a CJK \u-escape in the key so we don't pick up generic JSON.
_KEY_HAS_CJK = re.compile(r'\\u[4-9][0-9A-Fa-f]{3}')


def parse_next_chunk(text):
    """Yield (zh-CN-key, value) tuples from a Next.js JS chunk."""
    for m in _PAIR_RE.finditer(text):
        rk, rv = m.group(1), m.group(2)
        if not _KEY_HAS_CJK.search(rk):
            continue
        try:
            k = json.loads('"' + rk + '"')
            v = json.loads('"' + rv + '"')
        except ValueError:
            continue
        if not v or v == k:
            continue
        yield k, v


# ── main ─────────────────────────────────────────────────────────────────

def parse_app(app_path, out_path):
    contents = os.path.join(app_path, 'Contents')
    resources = os.path.join(contents, 'Resources')

    by_locale = {'en': {}, 'zh-cn': {}, 'zh-hk': {}}
    stats = {'sources': {}, 'totals': {}}

    # Track reverse-map insertions in priority order:
    # chunks first (lowest priority) → InfoPlist → FTL (highest).
    chunk_pairs = {'en': [], 'zh-hk': []}
    plist_pairs = {'en': [], 'zh-hk': []}
    ftl_pairs   = {'en': [], 'zh-hk': []}

    # 3 (collected first to populate forward map; reverse uses ftl/plist priority).
    pkg = os.path.join(resources, 'content.pkg')
    web_en = web_zhhk = 0
    if os.path.isfile(pkg) and zipfile.is_zipfile(pkg):
        with zipfile.ZipFile(pkg, 'r') as z:
            for info in z.infolist():
                name = info.filename
                if not name.startswith('_next/static/chunks/'):
                    continue
                if not name.endswith('.js'):
                    continue
                try:
                    text = z.read(info).decode('utf-8', errors='replace')
                except Exception:
                    continue
                for k, v in parse_next_chunk(text):
                    by_locale['zh-cn'].setdefault(k, k)
                    if _is_chinese(v):
                        if k not in by_locale['zh-hk']:
                            by_locale['zh-hk'][k] = v
                            chunk_pairs['zh-hk'].append((k, v))
                            web_zhhk += 1
                    else:
                        if k not in by_locale['en']:
                            by_locale['en'][k] = v
                            chunk_pairs['en'].append((k, v))
                            web_en += 1
    stats['sources']['next_chunks'] = {'en': web_en, 'zh-hk': web_zhhk}

    # 2. InfoPlist.strings — overrides chunks on collision.
    plist_paths = {
        'en':    os.path.join(resources, 'en.lproj',      'InfoPlist.strings'),
        'zh-cn': os.path.join(resources, 'zh-Hans.lproj', 'InfoPlist.strings'),
        'zh-hk': os.path.join(resources, 'zh-Hant.lproj', 'InfoPlist.strings'),
    }
    parsed_plist = {loc: parse_apple_strings(p) for loc, p in plist_paths.items()}
    base_plist = parsed_plist.get('zh-cn', {})
    for key, base_val in base_plist.items():
        for loc, table in parsed_plist.items():
            v = table.get(key)
            if not v:
                continue
            by_locale[loc][base_val] = v  # forward: overwrite
            if loc in plist_pairs:
                plist_pairs[loc].append((base_val, v))
    stats['sources']['infoplist'] = {loc: len(t) for loc, t in parsed_plist.items()}

    # 1. macOS menu .ftl — highest priority (curated by app team).
    ftl_paths = {
        'en':    os.path.join(resources, 'locales', 'en',    'yuanbao.ftl'),
        'zh-cn': os.path.join(resources, 'locales', 'zh-cn', 'yuanbao.ftl'),
        'zh-hk': os.path.join(resources, 'locales', 'zh-hk', 'yuanbao.ftl'),
    }
    parsed_ftl = {loc: parse_ftl(p) for loc, p in ftl_paths.items()}
    base_ftl = parsed_ftl.get('zh-cn', {})
    for key, base_val in base_ftl.items():
        for loc, table in parsed_ftl.items():
            v = table.get(key)
            if not v:
                continue
            by_locale[loc][base_val] = v
            if loc in ftl_pairs:
                ftl_pairs[loc].append((base_val, v))
    stats['sources']['ftl'] = {loc: len(t) for loc, t in parsed_ftl.items()}

    stats['totals'] = {loc: len(t) for loc, t in by_locale.items()}

    # Build reverse maps with priority chunks < plist < ftl.
    by_locale_reverse = {'en': {}, 'zh-cn': {}, 'zh-hk': {}}
    for k, v in by_locale['zh-cn'].items():
        by_locale_reverse['zh-cn'].setdefault(v, k)
    for loc in ('en', 'zh-hk'):
        rev = {}
        # chunks: first-seen wins (later chunk pairs are typically
        # namespaced variants.
        for k, v in chunk_pairs[loc]:
            rev.setdefault(v, k)
        # plist/ftl override chunk entries — they are curated by the
        # app team and represent the canonical mapping for menu items.
        for k, v in plist_pairs[loc]:
            rev[v] = k
        for k, v in ftl_pairs[loc]:
            rev[v] = k
        by_locale_reverse[loc] = rev

    out = {'by_locale': by_locale,
           'by_locale_reverse': by_locale_reverse,
           'stats': stats}
    tmp = out_path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp, out_path)
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    app_path, out_path = sys.argv[1], sys.argv[2]
    if not os.path.isdir(app_path):
        print('Not a directory: %s' % app_path, file=sys.stderr)
        sys.exit(1)
    res = parse_app(app_path, out_path)
    print(json.dumps(res['stats'], indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
