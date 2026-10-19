#!/usr/bin/env python3
"""Validate the app icon names and vector source assets used by the iOS target."""

from __future__ import annotations

import json
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Up Next.xcodeproj/project.pbxproj"
ICON_ROOT = ROOT / "Raul"


def fail(message: str) -> None:
    raise SystemExit(f"app icon validation failed: {message}")


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True, check=False)


project = PROJECT.read_text()
match = re.search(
    r'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES\s*=\s*"([^"]*)"\s*;',
    project,
)
if not match:
    fail("alternate icon build setting was not found")

declared = match.group(1).split()
if len(declared) != len(set(declared)):
    fail("alternate icon names contain duplicates")

bundles = {path.stem: path for path in ICON_ROOT.glob("*.icon") if path.is_dir()}
expected = {"AppIcon", *declared}
if set(bundles) != expected:
    fail(
        "declared icon names and icon bundles differ; "
        f"missing={sorted(expected - set(bundles))}, "
        f"undeclared={sorted(set(bundles) - expected)}"
    )

with tempfile.TemporaryDirectory(prefix="upnext-icon-validation-") as temporary:
    temporary_path = Path(temporary)
    for name in sorted(expected):
        bundle = bundles[name]
        metadata_path = bundle / "icon.json"
        if not metadata_path.is_file():
            fail(f"{name} has no icon.json")
        metadata = json.loads(metadata_path.read_text())
        platforms = metadata.get("supported-platforms", {})
        if platforms.get("squares") != "shared":
            fail(f"{name} has no shared square appearance for iPhone/iPad")

        def has_dark_appearance(value: object) -> bool:
            if isinstance(value, dict):
                return value.get("appearance") == "dark" or any(
                    has_dark_appearance(child) for child in value.values()
                )
            if isinstance(value, list):
                return any(has_dark_appearance(child) for child in value)
            return False

        if not has_dark_appearance(metadata):
            fail(f"{name} does not define a dark appearance specialization")

        image_names: set[str] = set()

        def collect_images(value: object) -> None:
            if isinstance(value, dict):
                image_name = value.get("image-name")
                if isinstance(image_name, str):
                    image_names.add(image_name)
                for child in value.values():
                    collect_images(child)
            elif isinstance(value, list):
                for child in value:
                    collect_images(child)

        collect_images(metadata)
        if not image_names:
            fail(f"{name} contains no image layers")
        for image_name in image_names:
            image_path = bundle / "Assets" / image_name
            if not image_path.is_file():
                fail(f"{name} references missing layer {image_name}")
            if image_path.suffix.lower() == ".svg":
                try:
                    ET.parse(image_path)
                except ET.ParseError as error:
                    fail(f"{name}/{image_name} is malformed SVG: {error}")
            elif image_path.suffix.lower() not in {".png", ".jpg", ".jpeg"}:
                fail(f"{name}/{image_name} uses unsupported image format {image_path.suffix}")
            rendered_path = temporary_path / f"{name}-{image_path.stem}.png"
            result = run([
                "sips", "-s", "format", "png", str(image_path), "--out", str(rendered_path)
            ])
            if result.returncode != 0 or not rendered_path.is_file():
                fail(f"{name}/{image_name} could not be rasterized: {result.stderr.strip()}")
            dimensions = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(rendered_path)])
            numbers = [int(number) for number in re.findall(r"pixel(?:Width|Height):\s*(\d+)", dimensions.stdout)]
            if len(numbers) != 2 or min(numbers) <= 0:
                fail(f"{name}/{image_name} rendered to an empty image")

    compile_dir = temporary_path / "compiled"
    compile_dir.mkdir()
    command = [
        "xcrun", "actool", "--compile", str(compile_dir),
        "--platform", "iphonesimulator", "--minimum-deployment-target", "26.0",
        "--app-icon", "AppIcon",
    ]
    for name in declared:
        command.extend(["--alternate-app-icon", name])
    command.extend([
        "--output-partial-info-plist", str(temporary_path / "partial.plist"),
        *(str(bundles[name]) for name in sorted(expected)),
    ])
    result = run(command)
    try:
        report = plistlib.loads(result.stdout.encode())
    except Exception as error:
        fail(f"actool returned no parseable validation report: {error}; {result.stderr.strip()}")
    errors = report.get("com.apple.actool.errors", [])
    if result.returncode != 0 or errors:
        descriptions = "; ".join(item.get("description", str(item)) for item in errors)
        fail(f"actool could not compile the configured icons: {descriptions or result.stderr.strip()}")
    if not (compile_dir / "Assets.car").is_file():
        fail("actool did not produce a compiled asset catalog")

print(f"Validated primary icon and {len(declared)} alternate icons with actool.")
