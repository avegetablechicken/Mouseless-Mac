#!/usr/bin/env python3
"""
Extract the localization map from QQ NT's major.node binary.

Discovery-based approach using V8 constant-pool structure:
  - V8 OneByteString:  [4-byte hash][byte_length LE32][ASCII bytes]
  - V8 TwoByteString:  [4-byte hash][char_count  LE32][UTF-16LE chars]

  1. Use standard macOS / Electron menu labels as anchors.
  2. Validate each anchor has the correct V8 length prefix.
  3. Search backward for the nearest V8 TwoByteString (CJK) before each anchor.
  4. Use confirmed pairs to delimit locale regions, then scan those regions
     for all additional V8 string pairs.

No QQ-specific hardcoded translations.

Usage:
    python3 parse_major_node.py <path_to_major.node> [output.json]
"""

import json
import struct
import sys
import os
from collections import OrderedDict


# ── Anchors ──────────────────────────────────────────────────────────────────
# Standard macOS / Electron labels shared across all apps.

ANCHORS = [
    # macOS app menu
    "About", "Service", "Hide", "HideOthers", "UnHide", "Quit",
    # macOS Edit menu
    "Edit", "Undo", "Redo", "Cut", "Copy", "Paste", "Delete",
    "SelectAll", "Search",
    # macOS Window menu
    "Minimize", "Zoom", "Bring all to front", "Toggle fullscreen",
    # macOS Help menu
    "Help",
    # Electron context menu
    "Open Link In New Tab", "Copy Link", "Emoji",
    "Select All", "Back", "Forward", "Reload",
    # Common Electron / macOS
    "Preferences", "New Window",
]


# ── V8 constant-pool helpers ─────────────────────────────────────────────────

def is_cjk_char(code: int) -> bool:
    return 0x4E00 <= code <= 0x9FFF


def _is_ascii_masquerading(raw: bytes, data: bytes = b"",
                           offset: int = 0) -> bool:
    """True if a supposed TwoByteString is actually a OneByteString misread.

    V8 stores both OneByteString (1 byte/char) and TwoByteString (2 bytes/char)
    with the same prefix format: [hash4][char_count LE32][content].
    When we read N*2 bytes as TwoByteString but the actual string is a
    OneByteString of N chars, we get garbage.

    Detection: the prefix value equals the char count.  For a TwoByteString
    of N chars the content is 2N bytes.  For a OneByteString of N chars the
    content is N bytes.  If the first N bytes (OneByteString interpretation)
    are mostly printable ASCII, it's a OneByteString, not TwoByteString.
    """
    n_chars = len(raw) // 2  # how the prefix was interpreted
    # Check: would this prefix also make sense as a OneByteString?
    # A OneByteString of n_chars has n_chars bytes of content.
    # The raw we got is 2*n_chars bytes.  The first n_chars bytes are what
    # a OneByteString would contain.
    onebyte_content = raw[:n_chars]
    ascii_count = sum(1 for b in onebyte_content if 0x20 <= b <= 0x7E)
    if ascii_count >= n_chars * 0.7:
        return True  # it's a OneByteString

    return False


def v8_validate_onebyte(data: bytes, offset: int, expected_len: int) -> bool:
    """Check that the 4 bytes before *offset* encode *expected_len* as LE32."""
    if offset < 4:
        return False
    prefix = struct.unpack_from("<I", data, offset - 4)[0]
    return prefix == expected_len


def v8_read_twobyte_backward(data: bytes, before: int,
                             max_scan: int = 300):
    """Search backward from *before* for a V8 TwoByteString containing CJK.

    V8 TwoByteStrings can mix CJK with ASCII/Latin (e.g. "隐藏QQ", "退出QQ").
    The LE32 prefix stores the total character count.

    Strategy: find CJK chars, extend the CJK run backward to locate the
    string start, then use the length prefix to read the FULL string
    (which may include non-CJK characters after the CJK portion).
    """
    probe = before - 2
    limit = max(before - max_scan, 4)

    while probe >= limit:
        code = struct.unpack_from("<H", data, probe)[0]
        if not is_cjk_char(code):
            probe -= 1
            continue

        # Found CJK; extend backward to find start of CJK run
        j = probe
        while j - 2 >= limit:
            c = struct.unpack_from("<H", data, j - 2)[0]
            if is_cjk_char(c):
                j -= 2
            else:
                break
        cjk_start = j

        # Try different string start positions:
        # The CJK run might not start at the V8 string start (there could be
        # non-CJK chars before), but typically CJK is at the start for
        # localized menu labels.  Check the prefix at cjk_start.
        if cjk_start >= 4:
            prefix = struct.unpack_from("<I", data, cjk_start - 4)[0]
            # Prefix must be a reasonable string length (2-50 chars)
            if 2 <= prefix <= 50:
                # Read the full string (prefix chars from cjk_start)
                byte_len = prefix * 2
                if cjk_start + byte_len <= len(data):
                    raw = data[cjk_start:cjk_start + byte_len]
                    try:
                        text = raw.decode("utf-16-le")
                    except UnicodeDecodeError:
                        probe = cjk_start - 1
                        continue
                    # Validate: string must contain at least 2 CJK chars
                    cjk_count = sum(1 for c in text if is_cjk_char(ord(c)))
                    if cjk_count >= 2:
                        return (cjk_start, text)

        # Not validated — continue searching backward
        probe = cjk_start - 1
        continue

    return None


def v8_scan_twobyte_strings(data: bytes, start: int, end: int,
                            min_chars: int = 2) -> list[tuple[int, str]]:
    """Scan a region for all V8 TwoByteStrings containing CJK, with valid
    length prefix.  Reads the full string (which may include non-CJK chars)."""
    results = []
    seen_offsets = set()
    i = start
    while i < end - 3:
        code = struct.unpack_from("<H", data, i)[0]
        if not is_cjk_char(code):
            i += 1
            continue

        # Found CJK; extend backward to find run start
        j = i
        while j - 2 >= start:
            c = struct.unpack_from("<H", data, j - 2)[0]
            if is_cjk_char(c):
                j -= 2
            else:
                break
        cjk_start = j

        if cjk_start in seen_offsets:
            i += 2
            continue

        # Check V8 length prefix
        if cjk_start >= 4:
            prefix = struct.unpack_from("<I", data, cjk_start - 4)[0]
            if 2 <= prefix <= 50:
                byte_len = prefix * 2
                if cjk_start + byte_len <= end:
                    raw = data[cjk_start:cjk_start + byte_len]
                    try:
                        text = raw.decode("utf-16-le")
                    except UnicodeDecodeError:
                        i += 2
                        continue
                    cjk_count = sum(1 for c in text if is_cjk_char(ord(c)))
                    # Masquerade check only for 6+ char strings (short ones
                    # have too many false positives)
                    is_masq = prefix >= 6 and _is_ascii_masquerading(raw)
                    if cjk_count >= min_chars and not is_masq:
                        seen_offsets.add(cjk_start)
                        results.append((cjk_start, text))
                        i = cjk_start + byte_len
                        continue

        # Skip past this CJK run
        while i < end - 1 and is_cjk_char(struct.unpack_from("<H", data, i)[0]):
            i += 2
        i = max(i, cjk_start + 1)

    return results


def v8_scan_onebyte_strings(data: bytes, start: int, end: int,
                            min_len: int = 2) -> list[tuple[int, str]]:
    """Scan a region for all V8 OneByteStrings (ASCII) with valid length prefix."""
    results = []
    i = start
    while i < end:
        b = data[i]
        if 0x20 <= b <= 0x7E:
            # Start of potential ASCII string
            chars = [chr(b)]
            j = i + 1
            while j < end:
                b2 = data[j]
                if 0x20 <= b2 <= 0x7E:
                    chars.append(chr(b2))
                    j += 1
                else:
                    break
            s = "".join(chars)
            if len(s) >= min_len and i >= 4:
                prefix = struct.unpack_from("<I", data, i - 4)[0]
                if prefix == len(s):
                    results.append((i, s))
            i = j
        else:
            i += 1
    return results


def find_all(data: bytes, pattern: bytes, end: int = 0,
             limit: int = 0) -> list[int]:
    if end <= 0:
        end = len(data)
    positions = []
    pos = 0
    while True:
        idx = data.find(pattern, pos, end)
        if idx == -1:
            break
        positions.append(idx)
        if limit and len(positions) >= limit:
            break
        pos = idx + 1
    return positions


# ── Phase 1: anchor-based discovery ──────────────────────────────────────────

def discover_anchor_pairs(data: bytes, x86_end: int) -> list[dict]:
    """For each anchor, find it as a V8 OneByteString, then look backward
    for its V8 TwoByteString (CJK) counterpart."""

    # Locale block markers
    markers = set()
    for m in [b"useChinese", b"getDefaultMenuItems", b"getLocale"]:
        for pos in find_all(data, m, end=x86_end, limit=20):
            markers.add(pos)

    pairs = []
    seen = set()

    for anchor in ANCHORS:
        anchor_bytes = anchor.encode("ascii")
        anchor_len = len(anchor_bytes)

        for pos in find_all(data, anchor_bytes, end=x86_end, limit=50):
            # Boundary check: not a substring
            if pos > 0 and 0x41 <= data[pos - 1] <= 0x7A:
                continue
            ep = pos + anchor_len
            if ep < len(data) and 0x41 <= data[ep] <= 0x7A:
                continue

            # Validate V8 length prefix
            if not v8_validate_onebyte(data, pos, anchor_len):
                continue

            # Must be near a locale marker
            if not any(abs(pos - m) < 12000 for m in markers):
                continue

            # Search backward for CJK counterpart
            result = v8_read_twobyte_backward(data, pos - 4)  # skip past length prefix
            if result is None:
                continue

            cjk_off, cjk_text = result
            key = (cjk_text, anchor)
            if key in seen:
                continue
            seen.add(key)

            pairs.append({
                "zh": cjk_text,
                "en": anchor,
                "zh_offset": f"0x{cjk_off:08x}",
                "en_offset": f"0x{pos:08x}",
                "source": "anchor",
            })

    return pairs


# ── Phase 2: region scan using V8 string format ─────────────────────────────

def discover_region_pairs(data: bytes, anchor_pairs: list[dict],
                          x86_end: int) -> list[dict]:
    """Use anchor pair offsets to delimit locale regions, then scan for
    all V8 TwoByteString → OneByteString pairs in those regions."""

    if not anchor_pairs:
        return []

    # Build regions from anchor offsets (merge within 3KB)
    offsets = []
    for p in anchor_pairs:
        offsets.append(int(p["zh_offset"], 16))
        offsets.append(int(p["en_offset"], 16))
    offsets.sort()

    regions = []
    lo = offsets[0]
    hi = offsets[0]
    for off in offsets[1:]:
        if off - hi < 3000:
            hi = off
        else:
            regions.append((max(0, lo - 1000), min(hi + 1000, x86_end)))
            lo = off
            hi = off
    regions.append((max(0, lo - 1000), min(hi + 1000, x86_end)))

    # Scan each region for V8 string pairs
    known_zh = {p["zh"] for p in anchor_pairs}
    extra_pairs = []

    for reg_start, reg_end in regions:
        cjk_strings = v8_scan_twobyte_strings(data, reg_start, reg_end)
        ascii_strings = v8_scan_onebyte_strings(data, reg_start, reg_end, min_len=2)

        for cjk_off, cjk_text in cjk_strings:
            if cjk_text in known_zh:
                continue

            cjk_byte_end = cjk_off + len(cjk_text) * 2

            # Find nearest validated ASCII string after this CJK
            best_en = None
            for asc_off, asc_text in ascii_strings:
                if asc_off <= cjk_byte_end:
                    continue
                gap = asc_off - cjk_byte_end
                if gap > 200:
                    break
                best_en = asc_text
                break

            if best_en:
                known_zh.add(cjk_text)
                extra_pairs.append({
                    "zh": cjk_text,
                    "en": best_en,
                    "zh_offset": f"0x{cjk_off:08x}",
                    "source": "region_scan",
                })

    return extra_pairs


# ── Sub-component scanners ───────────────────────────────────────────────────

def scan_cherry_markdown(data: bytes, x86_end: int):
    if data.find(b"changeLocale", 0, x86_end) == -1:
        return None
    locales = []
    for pos in find_all(data, b"changeLocale", end=x86_end, limit=5):
        window = data[max(0, pos - 200):pos + 200]
        for code in [b"zh_CN", b"en_US", b"ru_RU", b"ja_JP", b"ko_KR",
                     b"zh_TW", b"fr_FR", b"de_DE"]:
            if code in window and code.decode() not in locales:
                locales.append(code.decode())
    api = [n for n in ["changeLocale", "afterChangeLocale", "addLocale",
                       "addLocales", "getLocales", "setLocale"]
           if data.find(n.encode(), 0, x86_end) != -1]
    return {"component": "Cherry Markdown Editor", "locales": locales, "api": api}


def scan_dayjs_formats(data: bytes, x86_end: int):
    formats = OrderedDict()
    for dpos in find_all(data, b"YYYY/MM/DD", end=x86_end, limit=10):
        window = data[max(0, dpos - 50):dpos + 300]
        for lc in [b"zh-CN", b"zh-TW", b"en-AU", b"en-CA", b"en-GB",
                   b"en-NZ", b"en-ZA", b"fr-CA", b"fr-CH", b"es-ES", b"es-MX"]:
            li = window.find(lc)
            if li == -1:
                continue
            code = lc.decode()
            for dp in [b"YYYY/MM/DD", b"DD/MM/YYYY", b"MM/DD/YYYY",
                       b"D.MM.YYYY", b"DD.MM.YYYY", b"DD-MM-YYYY",
                       b"YYYY.MM.DD", b"D. MMMM YYYY"]:
                di = window.find(dp)
                if di != -1 and abs(di - li) < 60 and code not in formats:
                    formats[code] = dp.decode()
        if formats:
            break
    if not formats:
        return None
    formats["default"] = "MM/DD/YYYY"
    return {"component": "Day.js customParseFormat", "locale_date_formats": formats}


def scan_tencent_docs(data: bytes, x86_end: int):
    if data.find(b"Undefined language", 0, x86_end) == -1:
        return None
    locales = [c.decode() for c in [b"zh-CN", b"en-US", b"zh-TW", b"zh-HK"]
               if data.find(c, 0, x86_end) != -1]
    api = [n for n in ["addMessages", "basicClientVars", "userInfo"]
           if data.find(n.encode(), 0, x86_end) != -1]
    return {"component": "TencentDocs", "locales": locales, "api": api}


def scan_thumbplayer(data: bytes, x86_end: int):
    api = [n for n in ["compileI18n", "defaultI18nConfig", "i18nConfig", "i18nToolC"]
           if data.find(n.encode(), 0, x86_end) != -1]
    return {"component": "ThumbPlayer", "api": api} if api else None


# ── Detect supported locales ─────────────────────────────────────────────────

def detect_supported_locales(data: bytes, x86_end: int) -> list[str]:
    candidates = set()
    for marker in [b"getLocale", b"useChinese"]:
        for pos in find_all(data, marker, end=x86_end, limit=5):
            window = data[max(0, pos - 300):pos + 300]
            for code in [b"zh-CN", b"zh-TW", b"zh-HK", b"en-US"]:
                if code in window:
                    candidates.add(code.decode())
    return sorted(candidates)


# ── Binary format ────────────────────────────────────────────────────────────

def detect_format(data: bytes) -> dict:
    info = {}
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == 0xCAFEBABE:
        nfat = struct.unpack_from(">I", data, 4)[0]
        info["format"] = "Mach-O universal binary"
        info["slices"] = nfat
        if nfat >= 1:
            _cpu, _sub, offset, size, _align = struct.unpack_from(">IIIII", data, 8)
            info["first_slice_offset"] = offset
            info["first_slice_size"] = size
    elif magic == 0xFEEDFACF:
        info["format"] = "Mach-O 64-bit"
    else:
        info["format"] = "unknown"
    info["size_bytes"] = len(data)
    return info


# ── De-duplicate ─────────────────────────────────────────────────────────────

def is_clean_zh(text: str) -> bool:
    """True if every char is CJK (U+4E00-9FFF) or basic ASCII (U+0020-007E)."""
    return all(0x4E00 <= ord(c) <= 0x9FFF or 0x0020 <= ord(c) <= 0x007E for c in text)


def deduplicate(pairs: list[dict]) -> list[dict]:
    """Remove exact (zh, en) duplicates.  Keep first occurrence."""
    seen = set()
    out = []
    for p in pairs:
        key = (p["zh"], p["en"])
        if key not in seen:
            seen.add(key)
            out.append(p)
    return out


# ── Main ─────────────────────────────────────────────────────────────────────

def parse_major_node(path: str) -> dict:
    with open(path, "rb") as f:
        data = f.read()

    fmt = detect_format(data)
    x86_end = fmt.get("first_slice_offset", 0) + fmt.get("first_slice_size", len(data))
    x86_end = min(x86_end, len(data))

    result = OrderedDict()
    result["_meta"] = {
        "file": os.path.basename(path),
        **fmt,
        "supported_locales": detect_supported_locales(data, x86_end),
        "string_format": {
            "onebyte": "[4-byte hash][byte_length LE32][ASCII bytes]",
            "twobyte": "[4-byte hash][char_count  LE32][UTF-16LE CJK chars]",
        },
    }

    # Phase 1: anchor pairs
    anchor_pairs = discover_anchor_pairs(data, x86_end)

    # Phase 2: region-scan pairs
    region_pairs = discover_region_pairs(data, anchor_pairs, x86_end)

    # Filter: only keep entries with clean Chinese text
    clean_pairs = [p for p in anchor_pairs + region_pairs if is_clean_zh(p["zh"])]
    all_pairs = deduplicate(clean_pairs)

    result["locale_map"] = all_pairs
    result["locale_map_count"] = len(all_pairs)

    # Sub-components
    components = OrderedDict()
    for name, scanner in [
        ("cherry_markdown", scan_cherry_markdown),
        ("dayjs_date_formats", scan_dayjs_formats),
        ("tencent_docs", scan_tencent_docs),
        ("thumbplayer", scan_thumbplayer),
    ]:
        info = scanner(data, x86_end)
        if info:
            components[name] = info
    result["components"] = components

    return result


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <major.node> [output.json]", file=sys.stderr)
        sys.exit(1)

    node_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else None

    result = parse_major_node(node_path)

    json_str = json.dumps(result, ensure_ascii=False, indent=2)

    if out_path:
        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(json_str)
        n_a = sum(1 for p in result["locale_map"] if p.get("source") == "anchor")
        n_s = sum(1 for p in result["locale_map"] if p.get("source") == "region_scan")
        print(f"Wrote {len(json_str)} bytes → {out_path}", file=sys.stderr)
        print(f"  {n_a} anchor + {n_s} region-scan = {result['locale_map_count']} pairs",
              file=sys.stderr)
    else:
        print(json_str)


if __name__ == "__main__":
    main()
