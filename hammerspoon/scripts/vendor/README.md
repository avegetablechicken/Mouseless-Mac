# Vendored .NET Resource Dependencies

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
