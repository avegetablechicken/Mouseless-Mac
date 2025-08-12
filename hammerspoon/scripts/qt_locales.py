#!/usr/bin/python3
# -*- coding: utf-8 -*-
import re
import sys

def hexdump(b, start=0, end=None):
    if end is None: end = len(b)
    chunk = b[start:end]
    return " ".join(f"{x:02x}" for x in chunk)

def make_utf16le_literal(s: str) -> bytes:
    # 'abc' -> b'a\x00b\x00c\x00'
    return b"".join(ch.encode("ascii") + b"\x00" for ch in s)

def make_utf16be_literal(s: str) -> bytes:
    # 'abc' -> b'\x00a\x00b\x00c'
    return b"".join(b"\x00" + ch.encode("ascii") for ch in s)

def find_gui_qm_all(file_path, prefix):
    with open(file_path, "rb") as f:
        data = f.read()

    results = []

    ascii_pat = re.compile(
        prefix.encode("ascii") +
        br'[A-Za-z0-9._\- ]{1,256}?\.qm', re.IGNORECASE
    )
    for m in ascii_pat.finditer(data):
        name = m.group(0).decode("ascii", errors="ignore")
        results.append((name, m.start()))

    utf16le_pat = re.compile(
        make_utf16le_literal(prefix) +
        br'(?:[\x20-\x7E]\x00){1,256}?' +
        make_utf16le_literal('.qm'),
        re.IGNORECASE
    )
    for m in utf16le_pat.finditer(data):
        raw = m.group(0)
        name = raw[::2].decode("ascii", errors="ignore")
        results.append((name, m.start()))

    utf16be_pat = re.compile(
        make_utf16be_literal(prefix) +
        br'(?:\x00[\x20-\x7E]){1,256}?' +
        make_utf16be_literal('.qm'),
        re.IGNORECASE
    )
    for m in utf16be_pat.finditer(data):
        raw = m.group(0)
        name = raw[1::2].decode("ascii", errors="ignore")
        results.append((name, m.start()))

    uniq = {}
    for r in results:
        uniq[r[0]] = r
    results = list(uniq.values())
    results.sort(key=lambda x: x[1])
    results = [x[0] for x in results]
    return results

if __name__ == "__main__":
    path, prefix = sys.argv[1], sys.argv[2] + '_'
    hits = find_gui_qm_all(path, prefix)
    for hit in hits:
        print(hit)