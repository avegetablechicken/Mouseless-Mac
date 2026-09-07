# Vendored Dependencies

## Chromium PAK Tool

Source: [myfreeer/chrome-pak-customizer](https://github.com/myfreeer/chrome-pak-customizer),
as credited in the `mlmac` branch's root `README.md`.
Upstream licenses non-Windows builds under MIT; the full copyright and
permission notice is retained in `licenses/pak.LICENSE`.

`pak` is a prebuilt macOS Mach-O universal executable for `x86_64` and
`arm64`. `src/utils/localization/common.lua` invokes it with
`scripts/vendor/pak -u <pak_file> <destination_path>` to unpack Chromium
localization resources. No compiler or network access is needed at runtime.

| Binary | Architecture | License | SHA-256 |
| --- | --- | --- | --- |
| pak | macOS x86_64 + arm64 | MIT | `df30379319b162786ee2bdeaf4706b70a4f3b1d95ca5675a0b7d9eb6d09a81ad` |

Local commit `f8d824ce2a5fd3ef458e721c9c059265dd3636d8` (2024-01-06),
`macos: build "pak" as universal binary`, introduced this binary. Moving it
into `vendor` does not change its contents or executable permissions.
The exact upstream version/commit, build commands, and any local source
changes are not recorded, so a byte-for-byte rebuild cannot currently be
documented. In particular, this binary is not identified as upstream 2.0.

To recover the known binary from this repository, run from its root:

```sh
git show f8d824ce2a5fd3ef458e721c9c059265dd3636d8:macos/.hammerspoon/scripts/pak > /tmp/pak-restored
chmod +x /tmp/pak-restored
shasum -a 256 /tmp/pak-restored
```

Compare the checksum with the table before replacing `scripts/vendor/pak`.
For a new build, follow the upstream README's CMake instructions and record
the selected source commit, macOS architectures, build options, and new hash.

## NIB Archive Parser

Source: [MatrixEditor/nibarchive](https://github.com/MatrixEditor/nibarchive),
version 1.0.0, pinned to commit
[`e393750572bfa8c4d31b9016b9b642677e880b9b`](https://github.com/MatrixEditor/nibarchive/tree/e393750572bfa8c4d31b9016b9b642677e880b9b)
(2023-12-10). The vendored package files match this commit byte for byte;
the original import commit was not recorded locally.

Copyright (C) 2023 MatrixEditor. The source headers specify
**GPL-3.0-or-later**; the upstream license text is retained in
`licenses/nibarchive.LICENSE` and covers both the package and CLI.

`nibarchive/` contains the unmodified `__init__.py`, `model.py`, and
`parse.py`. `nib_parse.py` is upstream `nibarchive/__main__.py`, relocated
next to the package so its imports resolve when invoked directly.
`src/utils/localization/common.lua` runs it with `/usr/bin/python3` to
extract localized strings from binary NIB archives. It uses only the Python
standard library and needs no pip installation or network access at runtime.

Local CLI changes, applied to all three JSON output paths:

- Serialize `dataclasses.asdict(archive)['values']` instead of the entire
  archive to reduce `hs.json` loading time.
- Pass `ensure_ascii=False` to `json.dump` to preserve Unicode characters.

To restore the upstream baseline, run from the Hammerspoon directory
(use a fresh temporary clone directory):

```sh
git clone https://github.com/MatrixEditor/nibarchive.git /tmp/nibarchive-source
git -C /tmp/nibarchive-source checkout --detach e393750572bfa8c4d31b9016b9b642677e880b9b
mkdir -p scripts/vendor/nibarchive scripts/vendor/licenses
cp /tmp/nibarchive-source/nibarchive/{__init__,model,parse}.py scripts/vendor/nibarchive/
cp /tmp/nibarchive-source/nibarchive/__main__.py scripts/vendor/nib_parse.py
cp /tmp/nibarchive-source/LICENSE scripts/vendor/licenses/nibarchive.LICENSE
```

Then reapply both local CLI changes above before using the extractor.
Documentation and packaging metadata are omitted.

## .NET Resource Dependencies

Unmodified pure Python packages from PyPI wheels, loaded directly by
`scripts/dotnet_resources.py`. No pip installation, .NET runtime, or network
access is needed when running the extractor.

| Package | Version | License | Wheel SHA-256 |
| --- | --- | --- | --- |
| dnfile | 0.18.0 | MIT | `7579fe2d6bb1d854aa154929c309fbf34e70b622053a043a51d42f079fad1772` |
| pefile | 2024.8.26 | MIT | `76f8b485dcd3b1bb8166f1128d395fa3d87af26360c2358fb75b80019b957c6f` |

Upstream licenses are retained in `licenses/dnfile.LICENSE` and
`licenses/pefile.LICENSE`. Unused `.dist-info` installation metadata is omitted.
Package source files are not modified locally.

The extractor adapts dnfile 0.18.0's resource string length decoding to
BinaryReader's 7-bit format. Upstream currently uses ECMA-335 compressed
integers for those lengths, which misreads strings longer than 127 bytes.
This adapter affects only resource decoding; metadata parsing stays unchanged.

To reproduce these files, download the pinned wheels and extract both into
this directory:

```sh
python3 -m pip download --only-binary=:all: --dest /tmp/dotnet-wheels dnfile==0.18.0 pefile==2024.8.26
unzip /tmp/dotnet-wheels/dnfile-0.18.0-py3-none-any.whl -d scripts/vendor
unzip /tmp/dotnet-wheels/pefile-2024.8.26-py3-none-any.whl -d scripts/vendor
mkdir -p scripts/vendor/licenses
mv scripts/vendor/dnfile-0.18.0.dist-info/licenses/LICENSE scripts/vendor/licenses/dnfile.LICENSE
mv scripts/vendor/pefile-2024.8.26.dist-info/LICENSE scripts/vendor/licenses/pefile.LICENSE
rm -r scripts/vendor/dnfile-0.18.0.dist-info scripts/vendor/pefile-2024.8.26.dist-info
```
