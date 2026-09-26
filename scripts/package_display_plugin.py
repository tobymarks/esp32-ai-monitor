#!/usr/bin/env python3
"""Build a reproducible .aimplugin ZIP containing only plugin.json."""

import argparse
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


def package(source: Path, target: Path) -> None:
    manifest = source.read_bytes()
    json.loads(manifest)
    info = ZipInfo("plugin.json", (1980, 1, 1, 0, 0, 0))
    info.compress_type = ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    with ZipFile(target, "w") as archive:
        archive.writestr(info, manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="path to a plugin.json manifest")
    parser.add_argument("output", type=Path, help="path for the .aimplugin package")
    args = parser.parse_args()
    package(args.manifest, args.output)
    print(args.output)


if __name__ == "__main__":
    main()
