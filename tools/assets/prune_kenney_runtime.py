#!/usr/bin/env python3
"""Keep only the reviewed Kenney Racing Kit files used by RaceGlyph.

The complete upstream archive remains under assets/source/third_party. This
tool only curates the runtime copy so all-resources mobile exports cannot pick
up unused road pieces or promotional textures.
"""

from __future__ import annotations

import argparse
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_ROOT = PROJECT_ROOT / "assets/final/3d/trackside/kenney_racing"
REQUIRED_FILES = {
    "barrierRed.bin",
    "barrierRed.gltf",
    "barrierWhite.bin",
    "barrierWhite.gltf",
    "fenceStraight.bin",
    "fenceStraight.gltf",
    "grandStand.bin",
    "grandStand.gltf",
    "grandStandCovered.bin",
    "grandStandCovered.gltf",
    "net.png",
    "overheadLights.bin",
    "overheadLights.gltf",
    "pitsOffice.bin",
    "pitsOffice.gltf",
    "pitsOfficeCorner.bin",
    "pitsOfficeCorner.gltf",
    "treeLarge.bin",
    "treeLarge.gltf",
    "treeSmall.bin",
    "treeSmall.gltf",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Delete unreviewed files from the runtime copy (dry-run by default).",
    )
    args = parser.parse_args()

    if not RUNTIME_ROOT.is_dir() or RUNTIME_ROOT.is_symlink():
        raise SystemExit(f"Refusing unexpected runtime root: {RUNTIME_ROOT}")
    missing = sorted(name for name in REQUIRED_FILES if not (RUNTIME_ROOT / name).is_file())
    if missing:
        raise SystemExit("Refusing prune; required runtime files are missing: " + ", ".join(missing))

    allowed = set(REQUIRED_FILES)
    allowed.update(f"{name}.import" for name in REQUIRED_FILES)
    files = sorted(path for path in RUNTIME_ROOT.iterdir() if path.is_file())
    rejected = [path for path in files if path.name not in allowed]
    action = "DELETE" if args.apply else "WOULD_DELETE"
    for path in rejected:
        print(f"{action} {path.relative_to(PROJECT_ROOT)}")
    if args.apply:
        for path in rejected:
            path.unlink()
    print(
        f"Kenney runtime curation: kept {len(files) - len(rejected)}, "
        f"{'deleted' if args.apply else 'would delete'} {len(rejected)} files."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
