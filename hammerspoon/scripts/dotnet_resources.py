#!/usr/bin/env python3
"""Read ServiceLib UI strings from a .NET single-file bundle without executing it."""

import argparse
import json
from pathlib import Path
import struct
import sys
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent / "vendor"))
import dnfile


BUNDLE_SIGNATURE = bytes.fromhex(
    "8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae")


class Reader:
    def __init__(self, data, position=0):
        self.data = data
        self.position = position

    def read(self, size):
        if size < 0 or self.position < 0 or self.position + size > len(self.data):
            raise ValueError("Truncated resource data")
        result = self.data[self.position:self.position + size]
        self.position += size
        return result

    def unpack(self, fmt):
        return struct.unpack(fmt, self.read(struct.calcsize(fmt)))

    def encoded_integer(self):
        value = 0
        for shift in range(0, 35, 7):
            byte = self.read(1)[0]
            value |= (byte & 127) << shift
            if byte < 128:
                return value
        raise ValueError("Invalid 7-bit encoded integer")

    def string(self, encoding="utf-8"):
        return self.read(self.encoded_integer()).decode(encoding)


def read_resource_data(self, data, offset):
    reader = Reader(data, offset)
    value = reader.read(reader.encoded_integer())
    return value, reader.position - offset


# dnfile 0.18.0 uses ECMA-335 integers here, but .resources strings use
# BinaryReader's 7-bit lengths. Adapt only resource decoding, not metadata.
dnfile.resource.ResourceTypeFactory.read_serialized_data = read_resource_data
dnfile.resource.ResourceSet.read_serialized_data = (
    lambda self, offset: read_resource_data(self, self._data, offset))


def bundle_assemblies(data):
    signature = data.find(BUNDLE_SIGNATURE)
    if signature < 8:
        raise ValueError(".NET single-file bundle signature not found")
    offset = struct.unpack_from("<Q", data, signature - 8)[0]
    reader = Reader(data, offset)
    major, minor, count = reader.unpack("<III")
    if major not in (1, 2, 6) or minor != 0 or count > 100000:
        raise ValueError("Unsupported .NET bundle manifest")
    reader.string()  # Bundle ID.
    if major >= 2:
        reader.read(40)  # deps/runtimeconfig locations and extraction flags.
    for _ in range(count):
        start, size = reader.unpack("<QQ")
        compressed = reader.unpack("<Q")[0] if major >= 6 else 0
        kind = reader.read(1)[0]
        path = reader.string().replace("\\", "/")
        parts = path.split("/")
        if kind != 1 or parts[-1] not in ("ServiceLib.dll", "ServiceLib.resources.dll"):
            continue
        locale = "en" if path == "ServiceLib.dll" else parts[-2] if len(parts) == 2 else None
        if locale is None or size > 128 * 1024 * 1024:
            raise ValueError("Unexpected resource assembly path or size")
        assembly = Reader(data, start).read(compressed or size)
        if compressed:
            inflater = zlib.decompressobj(-zlib.MAX_WBITS)
            assembly = inflater.decompress(assembly, size + 1)
            if not inflater.eof:
                raise ValueError("Invalid compressed resource assembly")
        if len(assembly) != size:
            raise ValueError("Resource assembly size mismatch")
        yield locale, assembly


def assembly_strings(assembly):
    strings = {}
    with dnfile.dnPE(data=assembly, clr_lazy_load=True) as pe:
        if pe.net is None:
            raise ValueError("Resource assembly has no CLR metadata")
        for resource in pe.net.resources:
            if not isinstance(resource.data, dnfile.resource.ResourceSet):
                continue
            for entry in resource.data.entries:
                if entry.type_name != "System.String":
                    continue
                if not isinstance(entry.name, str) or not isinstance(entry.value, str):
                    raise ValueError("Invalid string resource entry")
                if entry.name in strings and strings[entry.name] != entry.value:
                    raise ValueError("Conflicting embedded resource keys: " + entry.name)
                strings[entry.name] = entry.value
    return strings


def extract(binary):
    translations = {}
    for locale, assembly in bundle_assemblies(Path(binary).read_bytes()):
        if locale in translations:
            raise ValueError("Duplicate resource locale: " + locale)
        translations[locale] = assembly_strings(assembly)
    if not translations.get("en") or "TbDisplayGUI" not in translations["en"]:
        raise ValueError("v2rayN ServiceLib UI resources not found")
    return translations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    try:
        json.dump(extract(args.binary), sys.stdout, ensure_ascii=False, sort_keys=True)
        sys.stdout.write("\n")
    except (OSError, ValueError, struct.error, zlib.error,
            dnfile.PEFormatError, dnfile.errors.dnFormatError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
