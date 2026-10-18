#!/usr/bin/env python3
"""Print the paths Xcode itself builds to, so scripts share the GUI's cache.

Never pass -derivedDataPath to xcodebuild: that forks a private cache inside the
repository. Ask Xcode instead, and fail loudly when Xcode is pointed elsewhere.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

DEFAULT_CACHE = Path.home() / "Library/Developer/Xcode/DerivedData"
CACHE_DIRS = {"DerivedData", "build", "SourcePackages", "checkouts"}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("configuration", nargs="?", default="Release",
                    choices=("Debug", "Release"))
parser.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent),
                    help="repository root (default: parent of this script)")
parser.add_argument("--project", help="path to the .xcodeproj")
parser.add_argument("--scheme", help="scheme name (default: project name)")
parser.add_argument("--target", help="target holding the settings (default: scheme)")
parser.add_argument("--derived-data", action="store_true",
                    help="print the project's cache directory instead of the product")
args = parser.parse_args()

repo = Path(args.repo).resolve()


def find_project():
    if args.project:
        return Path(args.project).resolve()
    found = sorted(
        p for p in repo.rglob("*.xcodeproj")
        if not any(part.startswith(".") or part in CACHE_DIRS
                   for part in p.relative_to(repo).parts))
    if len(found) != 1:
        raise SystemExit(
            f"Found {len(found)} .xcodeproj files: pass --project\n"
            + "\n".join(f"  {p}" for p in found))
    return found[0]


project = find_project()
scheme = args.scheme or project.stem
target = args.target or scheme
result = subprocess.run(
    ["xcodebuild", "-project", str(project), "-scheme", scheme,
     "-configuration", args.configuration, "-destination", "generic/platform=macOS",
     "-showBuildSettings", "-json"],
    capture_output=True, text=True)
if result.returncode:
    sys.stderr.write(result.stdout + result.stderr)
    raise SystemExit(result.returncode)

settings = [entry["buildSettings"] for entry in json.loads(result.stdout)
            if entry["target"] == target and entry["buildSettings"].get("FULL_PRODUCT_NAME")]
if len(settings) != 1:
    raise SystemExit(f"Expected one {target} target with a product, got {len(settings)}")
settings = settings[0]

build_dir = Path(settings["BUILD_DIR"])
if not build_dir.is_relative_to(DEFAULT_CACHE):
    raise SystemExit(
        f"Xcode builds outside its default location: {build_dir}\n"
        "Reset Xcode > Settings > Locations > Derived Data to Default.")
cache = next((p for p in build_dir.parents if p.parent == DEFAULT_CACHE), None)
if cache is None:
    raise SystemExit(f"No project cache under {DEFAULT_CACHE} for {build_dir}")

print(cache if args.derived_data
      else Path(settings["BUILT_PRODUCTS_DIR"]) / settings["FULL_PRODUCT_NAME"])
