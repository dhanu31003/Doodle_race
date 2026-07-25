#!/usr/bin/env python3
"""Validate RaceGlyph vector assets without third-party Python packages."""

from __future__ import annotations

import json
import hashlib
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
ASSET_ROOT = PROJECT_ROOT / "assets"
SVG_ROOTS = (ASSET_ROOT / "source", ASSET_ROOT / "final")
LICENSED_ASSET_ROOTS = (ASSET_ROOT / "source", ASSET_ROOT / "final", ASSET_ROOT / "generated")
LICENSED_SUFFIXES = {".svg", ".json", ".png", ".webp", ".wav"}
SVG_NS = "http://www.w3.org/2000/svg"
XLINK_HREF = "{http://www.w3.org/1999/xlink}href"
URL_PATTERN = re.compile(r"url\(([^)]+)\)")
VEHICLE_V2_REQUIRED_IDS = {
    "tires",
    "floor",
    "suspension",
    "front-wing",
    "sidepods",
    "bodywork",
    "cockpit",
    "halo",
    "diffuser",
    "rear-wing",
}

REQUIRED_PATHS = (
    "assets/source/design_tokens.json",
    "assets/source/brand/raceglyph_mark_master.svg",
    "assets/source/vehicles/formula_car_master.svg",
    "assets/final/brand/raceglyph_mark.svg",
    "assets/final/ui/icon_draw.svg",
    "assets/final/ui/icon_undo.svg",
    "assets/final/ui/icon_redo.svg",
    "assets/final/ui/icon_clear.svg",
    "assets/final/ui/icon_play.svg",
    "assets/final/ui/icon_pause.svg",
    "assets/final/ui/icon_settings.svg",
    "assets/final/ui/icon_multiplayer.svg",
    "assets/final/ui/icon_boost.svg",
    "assets/final/scenery/tree_canopy.svg",
    "assets/final/scenery/grandstand.svg",
    "assets/final/scenery/pit_building.svg",
    "assets/final/scenery/track_gantry.svg",
    "assets/final/scenery/modular_barrier.svg",
    "assets/licenses/original-assets.json",
    "assets/licenses/third-party-assets.json",
)

THIRD_PARTY_ROOTS = (
    ASSET_ROOT / "source" / "third_party",
    ASSET_ROOT / "final" / "3d",
    ASSET_ROOT / "licenses" / "third_party",
)


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def validate_svg(path: Path) -> list[str]:
    errors: list[str] = []
    relative = path.relative_to(PROJECT_ROOT)
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        return [f"{relative}: malformed XML: {exc}"]

    if root.tag != f"{{{SVG_NS}}}svg":
        errors.append(f"{relative}: root must be an SVG element in the SVG namespace")

    raw_view_box = root.get("viewBox")
    if raw_view_box is None:
        errors.append(f"{relative}: missing viewBox")
    else:
        try:
            values = [float(value) for value in re.split(r"[\s,]+", raw_view_box.strip())]
        except ValueError:
            values = []
        if len(values) != 4 or not all(math.isfinite(value) for value in values):
            errors.append(f"{relative}: viewBox must contain four finite numbers")
        elif values[2] <= 0 or values[3] <= 0:
            errors.append(f"{relative}: viewBox width and height must be positive")

    ids: set[str] = set()
    fragment_references: set[str] = set()
    for element in root.iter():
        name = local_name(element.tag)
        if name == "image":
            errors.append(f"{relative}: embedded or linked raster images are forbidden")
        if name == "text":
            errors.append(f"{relative}: text elements are forbidden; icons must remain font-independent")

        element_id = element.get("id")
        if element_id:
            if element_id in ids:
                errors.append(f"{relative}: duplicate id #{element_id}")
            ids.add(element_id)

        for attribute, value in element.attrib.items():
            if attribute in {"href", XLINK_HREF}:
                if not value.startswith("#"):
                    errors.append(f"{relative}: external href is forbidden: {value}")
                else:
                    fragment_references.add(value[1:])
            for match in URL_PATTERN.finditer(value):
                target = match.group(1).strip(" '\"")
                if not target.startswith("#"):
                    errors.append(f"{relative}: external URL reference is forbidden: {target}")
                else:
                    fragment_references.add(target[1:])

    for fragment in sorted(fragment_references - ids):
        errors.append(f"{relative}: references missing local id #{fragment}")
    return errors


def validate_vehicle_v2(path: Path) -> list[str]:
    """Keep the shipped car family on the authored V2 aero/material contract."""
    relative = path.relative_to(PROJECT_ROOT)
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return []  # The general SVG validator reports the parse error once.

    errors: list[str] = []
    if root.get("data-design-version") != "2":
        errors.append(f"{relative}: vehicle design version must be 2")
    if root.get("data-vehicle-class") != "fictional-open-wheel":
        errors.append(f"{relative}: vehicle class must be fictional-open-wheel")

    element_ids = {element.get("id") for element in root.iter() if element.get("id")}
    missing = sorted(VEHICLE_V2_REQUIRED_IDS - element_ids)
    if missing:
        errors.append(f"{relative}: missing V2 vehicle layers: {', '.join(missing)}")

    path_count = sum(1 for element in root.iter() if local_name(element.tag) == "path")
    gradient_count = sum(
        1 for element in root.iter()
        if local_name(element.tag) in {"linearGradient", "radialGradient"}
    )
    if path_count < 30 or gradient_count < 4:
        errors.append(
            f"{relative}: V2 vehicle detail regressed "
            f"({path_count} paths, {gradient_count} gradients)"
        )

    raw = path.read_text(encoding="utf-8").upper()
    for material_color in ("#FFFFFF", "#171D24", "#FF6B72"):
        if material_color not in raw:
            errors.append(f"{relative}: missing shared V2 material color {material_color}")
    return errors


def validate_json(path: Path) -> tuple[dict, list[str]]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        return {}, [f"{path.relative_to(PROJECT_ROOT)}: invalid JSON: {exc}"]
    if not isinstance(value, dict):
        return {}, [f"{path.relative_to(PROJECT_ROOT)}: root must be a JSON object"]
    return value, []


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def path_is_within_declared(relative: str, declarations: set[str]) -> bool:
    for declaration in declarations:
        if declaration.endswith("/") and relative.startswith(declaration):
            return True
        if relative == declaration:
            return True
    return False


def is_declared_original_or_import_sidecar(relative: str, declarations: set[str]) -> bool:
    if path_is_within_declared(relative, declarations):
        return True
    if relative.endswith(".import"):
        return path_is_within_declared(relative.removesuffix(".import"), declarations)
    return False


def validate_third_party_manifest(
    path: Path,
    original_declarations: set[str],
) -> tuple[int, list[str]]:
    manifest, errors = validate_json(path)
    groups = manifest.get("asset_groups", [])
    if not isinstance(groups, list) or not groups:
        return 0, errors + [f"{path.relative_to(PROJECT_ROOT)}: asset_groups must be non-empty"]

    declared: set[str] = set()
    identifiers: set[str] = set()
    for group in groups:
        if not isinstance(group, dict):
            errors.append(f"{path.relative_to(PROJECT_ROOT)}: every asset group must be an object")
            continue
        identifier = group.get("id", "")
        if not isinstance(identifier, str) or not identifier:
            errors.append(f"{path.relative_to(PROJECT_ROOT)}: every third-party group needs an id")
        elif identifier in identifiers:
            errors.append(f"{path.relative_to(PROJECT_ROOT)}: duplicate third-party id {identifier}")
        identifiers.add(identifier)
        if group.get("license") != "CC0-1.0" or group.get("status") != "CLEARED":
            errors.append(f"{identifier}: only verified CC0-1.0 CLEARED assets are accepted by this manifest")
        for field in ("creator", "source_page", "download_url", "retrieved_at", "modifications"):
            if not isinstance(group.get(field), str) or not group[field].strip():
                errors.append(f"{identifier}: missing required provenance field {field}")

        for field in ("license_proof",):
            relative = group.get(field, "")
            if not isinstance(relative, str) or not relative.startswith("assets/"):
                errors.append(f"{identifier}: invalid {field} path")
                continue
            declared.add(relative)
            if not (PROJECT_ROOT / relative).is_file():
                errors.append(f"{identifier}: missing {field} {relative}")

        archive_relative = group.get("source_archive", "")
        expected_archive_hash = group.get("source_archive_sha256", "")
        source_files = group.get("source_files", {})
        has_archive = isinstance(archive_relative, str) and bool(archive_relative)
        has_source_files = isinstance(source_files, dict) and bool(source_files)
        if not has_archive and not has_source_files:
            errors.append(f"{identifier}: source_archive or source_files is required")
        if has_archive:
            declared.add(archive_relative)
            archive_path = PROJECT_ROOT / archive_relative
            if not archive_relative.startswith("assets/") or not archive_path.is_file():
                errors.append(f"{identifier}: missing source archive {archive_relative}")
            elif sha256_file(archive_path) != expected_archive_hash:
                errors.append(f"{identifier}: source archive checksum mismatch")
        if has_source_files:
            for relative, expected in source_files.items():
                declared.add(relative)
                resolved = PROJECT_ROOT / relative
                if not isinstance(relative, str) or not relative.startswith("assets/") or not resolved.is_file():
                    errors.append(f"{identifier}: missing direct source file {relative}")
                elif sha256_file(resolved) != expected:
                    errors.append(f"{identifier}: direct source checksum mismatch: {relative}")

        for list_field in ("runtime_paths",):
            values = group.get(list_field, [])
            if not isinstance(values, list) or not values:
                errors.append(f"{identifier}: {list_field} must be non-empty")
                continue
            for relative in values:
                if not isinstance(relative, str) or not relative.startswith("assets/"):
                    errors.append(f"{identifier}: invalid {list_field} entry {relative!r}")
                    continue
                declared.add(relative)
                resolved = PROJECT_ROOT / relative.rstrip("/")
                if not resolved.exists():
                    errors.append(f"{identifier}: declared path is missing: {relative}")
                elif relative.endswith("/") and not any(resolved.rglob("*")):
                    errors.append(f"{identifier}: declared directory is empty: {relative}")

        source_paths = group.get("source_paths", [])
        if not isinstance(source_paths, list):
            errors.append(f"{identifier}: source_paths must be an array when present")
        else:
            for relative in source_paths:
                if not isinstance(relative, str) or not relative.startswith("assets/"):
                    errors.append(f"{identifier}: invalid source_paths entry {relative!r}")
                    continue
                declared.add(relative)
                resolved = PROJECT_ROOT / relative.rstrip("/")
                if not resolved.exists():
                    errors.append(f"{identifier}: declared source path is missing: {relative}")

        runtime_hashes = group.get("runtime_sha256", {})
        if not isinstance(runtime_hashes, dict):
            errors.append(f"{identifier}: runtime_sha256 must be an object")
            continue
        for relative, expected in runtime_hashes.items():
            resolved = PROJECT_ROOT / relative
            if not resolved.is_file():
                errors.append(f"{identifier}: checksummed runtime file is missing: {relative}")
            elif sha256_file(resolved) != expected:
                errors.append(f"{identifier}: runtime checksum mismatch: {relative}")

    actual_third_party = {
        str(file.relative_to(PROJECT_ROOT))
        for root in THIRD_PARTY_ROOTS
        if root.exists()
        for file in root.rglob("*")
        if file.is_file()
        and not is_declared_original_or_import_sidecar(
            str(file.relative_to(PROJECT_ROOT)),
            original_declarations,
        )
    }
    uncovered = sorted(relative for relative in actual_third_party if not path_is_within_declared(relative, declared))
    if uncovered:
        errors.append("third-party license inventory does not cover: " + ", ".join(uncovered))
    return len(actual_third_party), errors


def main() -> int:
    errors: list[str] = []
    for relative in REQUIRED_PATHS:
        if not (PROJECT_ROOT / relative).is_file():
            errors.append(f"missing required asset: {relative}")

    svg_paths = sorted(path for root in SVG_ROOTS for path in root.rglob("*.svg"))
    for path in svg_paths:
        errors.extend(validate_svg(path))

    team_paths = sorted((ASSET_ROOT / "final" / "vehicles").glob("car_*.svg"))
    if len(team_paths) < 7:
        errors.append(f"expected a player car plus at least six team variants; found {len(team_paths)}")
    vehicle_v2_paths = [ASSET_ROOT / "source" / "vehicles" / "formula_car_master.svg"]
    vehicle_v2_paths.extend(team_paths)
    for path in vehicle_v2_paths:
        errors.extend(validate_vehicle_v2(path))

    tokens, token_errors = validate_json(ASSET_ROOT / "source" / "design_tokens.json")
    errors.extend(token_errors)
    if tokens.get("geometry", {}).get("car_forward_direction") != "negative_y":
        errors.append("assets/source/design_tokens.json: car forward direction must be negative_y")

    key_art_metadata_path = ASSET_ROOT / "generated" / "key_art" / "raceglyph_splash_concept_v1.metadata.json"
    key_art_metadata, key_art_errors = validate_json(key_art_metadata_path)
    errors.extend(key_art_errors)
    provenance_items = [key_art_metadata.get("source", {})]
    provenance_items.extend(key_art_metadata.get("runtime_derivatives", []))
    for item in provenance_items:
        if not isinstance(item, dict):
            errors.append(f"{key_art_metadata_path.relative_to(PROJECT_ROOT)}: malformed provenance item")
            continue
        relative = item.get("path", "")
        expected = item.get("sha256", "")
        asset_path = PROJECT_ROOT / relative
        if not isinstance(relative, str) or not asset_path.is_file():
            errors.append(f"{key_art_metadata_path.relative_to(PROJECT_ROOT)}: missing provenance asset {relative}")
            continue
        actual = hashlib.sha256(asset_path.read_bytes()).hexdigest()
        if actual != expected:
            errors.append(f"{relative}: checksum does not match key-art provenance metadata")

    manifest_path = ASSET_ROOT / "licenses" / "original-assets.json"
    manifest, manifest_errors = validate_json(manifest_path)
    errors.extend(manifest_errors)
    covered: set[str] = set()
    for group in manifest.get("asset_groups", []):
        if group.get("origin") != "original" or group.get("created_by") != "RaceGlyph project":
            errors.append(f"{manifest_path.relative_to(PROJECT_ROOT)}: every group must be project-created and original")
        group_paths = group.get("paths", [])
        if not isinstance(group_paths, list) or not group_paths:
            errors.append(f"{manifest_path.relative_to(PROJECT_ROOT)}: every group needs a non-empty paths list")
            continue
        for relative in group_paths:
            if not isinstance(relative, str) or not relative.startswith("assets/"):
                errors.append(f"{manifest_path.relative_to(PROJECT_ROOT)}: invalid asset path {relative!r}")
                continue
            covered.add(relative)
            if not (PROJECT_ROOT / relative).is_file():
                errors.append(f"{manifest_path.relative_to(PROJECT_ROOT)}: inventoried file is missing: {relative}")

    original_licensable = {
        str(path.relative_to(PROJECT_ROOT))
        for root in LICENSED_ASSET_ROOTS
        for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() in LICENSED_SUFFIXES
        and not any(path.is_relative_to(third_party_root) for third_party_root in THIRD_PARTY_ROOTS)
    }
    uncovered = sorted(original_licensable - covered)
    if uncovered:
        errors.append("license inventory does not cover: " + ", ".join(uncovered))

    third_party_count, third_party_errors = validate_third_party_manifest(
        ASSET_ROOT / "licenses" / "third-party-assets.json",
        covered,
    )
    errors.extend(third_party_errors)

    if errors:
        print("RaceGlyph asset validation FAILED")
        for error in errors:
            print(f"- {error}")
        return 1

    print(
        "RaceGlyph asset validation passed: "
        f"{len(svg_paths)} SVGs, {len(team_paths)} car colorways, "
        f"{len(covered)} inventoried source/final/generated assets, "
        f"{third_party_count} retained third-party source/runtime/proof files, "
        f"{len(vehicle_v2_paths)} V2 vehicle layer contracts."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
