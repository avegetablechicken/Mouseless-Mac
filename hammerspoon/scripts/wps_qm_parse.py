#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""Parse Qt .qm translation files (including WPS Office customized builds).

Supports standard Qt QM binary format with sections:
  Hashes (0x42), Messages (0x69), Contexts (0x2f),
  NumerusRules (0x88), Dependencies (0x96).

Usage:
  # Dump a single file as JSON
  python3 wps_qm_parse.py dump <file.qm>

  # Compare two locale files side by side
  python3 wps_qm_parse.py diff <en.qm> <zh.qm>

  # Dump all locales under a mui directory
  python3 wps_qm_parse.py dump-all <mui_dir> [-o <output_dir>]

  # Search translations by regex
  python3 wps_qm_parse.py grep <pattern> <file.qm> [<file2.qm> ...]
"""
import argparse
import json
import os
import re
import struct
import sys

QM_MAGIC = b"\x3c\xb8\x64\x18\xca\xef\x9c\x95\xcd\x21\x1c\xbf\x60\xa1\xbd\xdd"

SECTION_TAGS = {
    0x2F: "Contexts",
    0x42: "Hashes",
    0x69: "Messages",
    0x88: "NumerusRules",
    0x96: "Dependencies",
}

# Message sub-tags
TAG_END          = 1
TAG_SOURCETEXT16 = 2
TAG_TRANSLATION  = 3
TAG_CONTEXT16    = 4
TAG_SOURCETEXT   = 6
TAG_CONTEXT      = 7
TAG_COMMENT      = 8

TAG_4BYTE = {TAG_TRANSLATION, TAG_SOURCETEXT, TAG_CONTEXT, TAG_COMMENT,
             TAG_SOURCETEXT16, TAG_CONTEXT16}
TAG_NAMES = {
    TAG_SOURCETEXT16: "source",
    TAG_TRANSLATION:  "translation",
    TAG_CONTEXT16:    "context",
    TAG_SOURCETEXT:   "source",
    TAG_CONTEXT:      "context",
    TAG_COMMENT:      "comment",
}


def _u16be_to_utf8(raw: bytes) -> str:
    try:
        return raw.decode("utf-16-be")
    except Exception:
        return raw.hex()


def parse_qm(path: str) -> dict[int, str]:
    """Parse a .qm file. Returns {hash: translation_string}."""
    with open(path, "rb") as f:
        data = f.read()

    if data[:16] != QM_MAGIC:
        raise ValueError(f"not a QM file: {path}")

    # Parse section table
    sections = {}
    pos = 16
    while pos < len(data):
        tag = data[pos]; pos += 1
        if tag not in SECTION_TAGS:
            break
        length = struct.unpack_from(">I", data, pos)[0]; pos += 4
        sections[SECTION_TAGS[tag]] = (pos, length)
        pos += length

    if "Hashes" not in sections or "Messages" not in sections:
        raise ValueError(f"missing required sections in {path}")

    h_off, h_len = sections["Hashes"]
    m_off, m_len = sections["Messages"]

    def _parse_msg(rel_offset: int) -> dict:
        p = m_off + rel_offset
        end = m_off + m_len
        msg = {}
        while p < end:
            t = data[p]; p += 1
            if t == TAG_END:
                break
            if t in TAG_4BYTE:
                ln = struct.unpack_from(">I", data, p)[0]; p += 4
                raw = data[p:p + ln]; p += ln
                name = TAG_NAMES.get(t)
                if name:
                    msg[name] = _u16be_to_utf8(raw)
            elif t in (5, 9):  # obsolete
                ln = struct.unpack_from(">I", data, p)[0]; p += 4
                p += ln
            else:
                break
        return msg

    results = {}
    for i in range(h_len // 8):
        p = h_off + i * 8
        h, o = struct.unpack_from(">II", data, p)
        msg = _parse_msg(o)
        trans = msg.get("translation", "")
        if trans:
            results[h] = trans
    return results


def parse_qm_full(path: str) -> dict[int, dict]:
    """Parse a .qm file. Returns {hash: {translation, source, context, comment}}."""
    with open(path, "rb") as f:
        data = f.read()

    if data[:16] != QM_MAGIC:
        raise ValueError(f"not a QM file: {path}")

    sections = {}
    pos = 16
    while pos < len(data):
        tag = data[pos]; pos += 1
        if tag not in SECTION_TAGS:
            break
        length = struct.unpack_from(">I", data, pos)[0]; pos += 4
        sections[SECTION_TAGS[tag]] = (pos, length)
        pos += length

    if "Hashes" not in sections or "Messages" not in sections:
        raise ValueError(f"missing required sections in {path}")

    h_off, h_len = sections["Hashes"]
    m_off, m_len = sections["Messages"]

    def _parse_msg(rel_offset: int) -> dict:
        p = m_off + rel_offset
        end = m_off + m_len
        msg = {}
        while p < end:
            t = data[p]; p += 1
            if t == TAG_END:
                break
            if t in TAG_4BYTE:
                ln = struct.unpack_from(">I", data, p)[0]; p += 4
                raw = data[p:p + ln]; p += ln
                name = TAG_NAMES.get(t)
                if name:
                    msg[name] = _u16be_to_utf8(raw)
            elif t in (5, 9):
                ln = struct.unpack_from(">I", data, p)[0]; p += 4
                p += ln
            else:
                break
        return msg

    results = {}
    for i in range(h_len // 8):
        p = h_off + i * 8
        h, o = struct.unpack_from(">II", data, p)
        msg = _parse_msg(o)
        if msg:
            results[h] = msg
    return results


# -- CLI commands --

def cmd_dump(args):
    for path in args.files:
        entries = parse_qm(path)
        out = [{"hash": f"0x{h:08x}", "translation": t}
               for h, t in sorted(entries.items())]
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                json.dump(out, f, ensure_ascii=False, indent=2)
            print(f"{path}: {len(out)} entries -> {args.output}")
        else:
            json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
            print()


def cmd_diff(args):
    a = parse_qm(args.file_a)
    b = parse_qm(args.file_b)
    common = sorted(set(a) & set(b))
    a_label = os.path.basename(os.path.dirname(args.file_a))
    b_label = os.path.basename(os.path.dirname(args.file_b))
    count = 0
    for h in common:
        if a[h] != b[h]:
            print(f"[0x{h:08x}] {a_label}: {a[h]}")
            print(f"{'':12s} {b_label}: {b[h]}")
            print()
            count += 1
    only_a = set(a) - set(b)
    only_b = set(b) - set(a)
    print(f"--- {count} differing, {len(only_a)} only in {a_label}, "
          f"{len(only_b)} only in {b_label}")


def cmd_dump_all(args):
    mui_dir = args.mui_dir
    out_dir = args.output or os.path.join(os.path.dirname(mui_dir), "qm_parsed")
    os.makedirs(out_dir, exist_ok=True)

    locales = sorted(d for d in os.listdir(mui_dir)
                     if os.path.isdir(os.path.join(mui_dir, d)))
    # Collect all qm names
    qm_names = set()
    for locale in locales:
        d = os.path.join(mui_dir, locale)
        for f in os.listdir(d):
            if f.endswith(".qm"):
                qm_names.add(f[:-3])

    total = 0
    for name in sorted(qm_names):
        locale_data = {}
        for locale in locales:
            path = os.path.join(mui_dir, locale, f"{name}.qm")
            if os.path.exists(path):
                locale_data[locale] = parse_qm(path)

        all_hashes = set()
        for d in locale_data.values():
            all_hashes.update(d)

        rows = []
        for h in sorted(all_hashes):
            row = {"_hash": f"0x{h:08x}"}
            for locale in locales:
                if locale in locale_data and h in locale_data[locale]:
                    row[locale] = locale_data[locale][h]
            rows.append(row)

        total += len(rows)
        out_path = os.path.join(out_dir, f"{name}.json")
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(rows, f, ensure_ascii=False, indent=2)
        print(f"{name}.json: {len(rows)} entries")

    print(f"\nTotal: {total} entries -> {out_dir}/")


def cmd_grep(args):
    pat = re.compile(args.pattern, re.IGNORECASE if args.ignore_case else 0)
    for path in args.files:
        entries = parse_qm(path)
        label = path
        for h, t in sorted(entries.items()):
            if pat.search(t):
                print(f"{label}:0x{h:08x}: {t}")


def cmd_lookup(args):
    """Given a source string pattern, find its translation in a target QM file.

    Loads source QM (typically en_US) to find the hash matching the pattern,
    then looks up that hash in the target QM file.
    """
    src_entries = parse_qm(args.source_qm)
    tgt_entries = parse_qm(args.target_qm)
    pat = re.compile(args.pattern)
    for h, src_text in src_entries.items():
        if pat.fullmatch(src_text):
            tgt_text = tgt_entries.get(h, "")
            if tgt_text:
                print(tgt_text, end="")
                return
    # No match found, exit silently


def cmd_reverse_lookup(args):
    """Given a translated string pattern, find its source string.

    Loads target QM to find the hash matching the pattern,
    then looks up that hash in the source QM file.
    """
    tgt_entries = parse_qm(args.target_qm)
    src_entries = parse_qm(args.source_qm)
    pat = re.compile(args.pattern)
    for h, tgt_text in tgt_entries.items():
        if pat.fullmatch(tgt_text):
            src_text = src_entries.get(h, "")
            if src_text:
                print(src_text, end="")
                return


def cmd_to_po(args):
    """Convert a QM file to PO format on stdout (lconvert replacement)."""
    entries = parse_qm_full(args.file)
    # Group by context for proper PO output
    for h, msg in sorted(entries.items()):
        ctx = msg.get("context", "")
        src = msg.get("source", "")
        trans = msg.get("translation", "")
        if ctx:
            print(f'msgctxt "{ctx}"')
        print(f'msgid "{src}"')
        print(f'msgstr "{trans}"')
        print()


def cmd_cache_wps(args):
    """Build cached locale maps for WPS Office QM files.

    Pairs en_US and target locale QM files by hash to produce:
      <name>_loc.json   — {en_string: locale_string}
      <name>_deloc.json — {locale_string: en_string}
    """
    src_dir = args.source_dir
    tgt_dir = args.target_dir
    out_dir = args.output
    os.makedirs(out_dir, exist_ok=True)

    src_files = {f[:-3] for f in os.listdir(src_dir) if f.endswith(".qm")}
    tgt_files = {f[:-3] for f in os.listdir(tgt_dir) if f.endswith(".qm")}
    common = sorted(src_files & tgt_files)

    for name in common:
        src_entries = parse_qm(os.path.join(src_dir, name + ".qm"))
        tgt_entries = parse_qm(os.path.join(tgt_dir, name + ".qm"))

        loc_map = {}    # en -> locale
        deloc_map = {}  # locale -> en
        for h in set(src_entries) & set(tgt_entries):
            s, t = src_entries[h], tgt_entries[h]
            if s and t and s != t and len(s) <= 100 and len(t) <= 100:
                loc_map[s] = t
                if t not in deloc_map:
                    deloc_map[t] = s

        loc_path = os.path.join(out_dir, name + "_loc.json")
        deloc_path = os.path.join(out_dir, name + "_deloc.json")
        with open(loc_path, "w", encoding="utf-8") as f:
            json.dump(loc_map, f, ensure_ascii=False)
        with open(deloc_path, "w", encoding="utf-8") as f:
            json.dump(deloc_map, f, ensure_ascii=False)
        print(f"{name}: {len(loc_map)} loc, {len(deloc_map)} deloc")

    print(f"\nCached {len(common)} modules -> {out_dir}/")


def main():
    parser = argparse.ArgumentParser(
        description="Parse Qt .qm translation files")
    sub = parser.add_subparsers(dest="command")

    p_dump = sub.add_parser("dump", help="Dump QM file(s) as JSON")
    p_dump.add_argument("files", nargs="+")
    p_dump.add_argument("-o", "--output")
    p_dump.set_defaults(fn=cmd_dump)

    p_diff = sub.add_parser("diff", help="Compare two QM files")
    p_diff.add_argument("file_a")
    p_diff.add_argument("file_b")
    p_diff.set_defaults(fn=cmd_diff)

    p_all = sub.add_parser("dump-all", help="Dump all locales under a mui dir")
    p_all.add_argument("mui_dir")
    p_all.add_argument("-o", "--output")
    p_all.set_defaults(fn=cmd_dump_all)

    p_grep = sub.add_parser("grep", help="Search translations by regex")
    p_grep.add_argument("pattern")
    p_grep.add_argument("files", nargs="+")
    p_grep.add_argument("-i", "--ignore-case", action="store_true")
    p_grep.set_defaults(fn=cmd_grep)

    p_lookup = sub.add_parser("lookup",
        help="Find translation for a source string pattern")
    p_lookup.add_argument("pattern", help="Regex to match source string")
    p_lookup.add_argument("source_qm", help="Source locale QM (e.g. en_US)")
    p_lookup.add_argument("target_qm", help="Target locale QM (e.g. zh_CN)")
    p_lookup.set_defaults(fn=cmd_lookup)

    p_rlookup = sub.add_parser("reverse-lookup",
        help="Find source string for a translated string pattern")
    p_rlookup.add_argument("pattern", help="Regex to match translated string")
    p_rlookup.add_argument("target_qm", help="Target locale QM (e.g. zh_CN)")
    p_rlookup.add_argument("source_qm", help="Source locale QM (e.g. en_US)")
    p_rlookup.set_defaults(fn=cmd_reverse_lookup)

    p_to_po = sub.add_parser("to-po",
        help="Convert QM to PO format (lconvert replacement)")
    p_to_po.add_argument("file")
    p_to_po.set_defaults(fn=cmd_to_po)

    p_cache = sub.add_parser("cache-wps",
        help="Build cached locale maps for WPS QM files by hash-pairing")
    p_cache.add_argument("source_dir", help="Source locale dir (e.g. mui/en_US)")
    p_cache.add_argument("target_dir", help="Target locale dir (e.g. mui/zh_CN)")
    p_cache.add_argument("-o", "--output", required=True,
        help="Output directory for cached JSON maps")
    p_cache.set_defaults(fn=cmd_cache_wps)

    args = parser.parse_args()
    if not hasattr(args, "fn"):
        parser.print_help()
        sys.exit(1)
    args.fn(args)


if __name__ == "__main__":
    main()
