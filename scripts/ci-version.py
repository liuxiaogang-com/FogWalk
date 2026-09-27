#!/usr/bin/env python3
"""Check or increment FogWalk's version across all Xcode configurations."""
import argparse
from pathlib import Path
import re

PROJECT = Path(__file__).resolve().parents[1] / "FogWalk.xcodeproj/project.pbxproj"
VERSION = re.compile(rb"\bMARKETING_VERSION = ([^;]+);")
BUILD = re.compile(rb"\bCURRENT_PROJECT_VERSION = ([^;]+);")


def update(project: Path, action: str) -> str:
    source = project.read_bytes()
    versions, builds = VERSION.findall(source), BUILD.findall(source)
    if not versions or len(set(versions)) != 1:
        raise ValueError("Missing or inconsistent MARKETING_VERSION values.")
    if not builds or len(set(builds)) != 1:
        raise ValueError("Missing or inconsistent CURRENT_PROJECT_VERSION values.")
    version, build = versions[0], builds[0]
    if not re.fullmatch(rb"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Version must be three non-negative integers: major.minor.patch.")
    if not re.fullmatch(rb"[1-9][0-9]*", build):
        raise ValueError("Build must be a positive integer.")
    if action == "check":
        return f"{version.decode()} (local build {build.decode()})"
    if action not in ("major", "minor", "patch"):
        raise ValueError("Expected check, major, minor or patch.")
    parts = list(map(int, version.split(b".")))
    index = ("major", "minor", "patch").index(action)
    parts[index] += 1
    parts[index + 1:] = [0] * (2 - index)
    next_version = ".".join(map(str, parts)).encode()
    next_build = str(int(build) + 1).encode()
    updated = VERSION.sub(lambda _: b"MARKETING_VERSION = " + next_version + b";", source)
    updated = BUILD.sub(lambda _: b"CURRENT_PROJECT_VERSION = " + next_build + b";", updated)
    project.write_bytes(updated)
    return f"{version.decode()} -> {next_version.decode()} (local build {next_build.decode()})"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "patch", "minor", "major"))
    args = parser.parse_args()
    try:
        print(update(PROJECT, args.action))
    except (OSError, ValueError) as error:
        parser.exit(1, f"Version error: {error}\n")
