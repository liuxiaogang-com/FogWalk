#!/usr/bin/env python3
"""Publish a verified unsigned IPA as a unique, persistent private-repository release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "liuxiaogang-com/FogWalk"))
parser.add_argument("--dry-run", action="store_true")
args = parser.parse_args()

directory = args.directory.resolve()
metadata_path = directory / "build-info.json"
metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
if metadata.get("validation_mode") != "full" or os.environ.get("CI_TEST_STATUS") != "passed":
    raise SystemExit("Release publication requires full validation and successful tests.")
filename = metadata["file"]
if Path(filename).name != filename or "/" in filename or "\\" in filename:
    raise SystemExit("The IPA filename must be a basename.")
ipa = directory / filename
checksum = ipa.with_suffix(".ipa.sha256")
guide = Path(__file__).resolve().parents[1] / "WINDOWS_INSTALL.md"
assets = [ipa, checksum, metadata_path, guide]
for asset in assets:
    if not asset.is_file():
        raise SystemExit(f"Missing release asset: {asset}")
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
if digest != metadata["sha256"] or digest != checksum.read_text().split()[0]:
    raise SystemExit("IPA checksum does not match its build provenance.")
if metadata["signed"] is not False:
    raise SystemExit("This publisher expects an unsigned IPA.")
version, build, commit = (str(metadata[key]) for key in ("version", "build", "commit"))
if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdigit():
    raise SystemExit("Invalid version or build number.")
if not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("Expected the full source commit SHA.")
attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
if not attempt.isdigit() or int(attempt) < 1:
    raise SystemExit("Invalid workflow run attempt.")
tag = f"v{version}-build{build}" + (f"-r{attempt}" if int(attempt) > 1 else "")
title = f"FogWalk {version} · build {build} · unsigned" + (f" · retry {attempt}" if int(attempt) > 1 else "")
notes = f"""迷雾足迹 iPhone 未签名安装包。

- 版本：{version} / build {build}
- 最低 iOS：{metadata['minimum_ios']}
- 平台：arm64 / iPhoneOS
- 源码提交：{commit}
- [GitHub Actions 构建记录]({metadata['run_url']})
- SHA-256：`{digest}`

下载 Assets 中的 .ipa；.sha256 和 build-info.json 用于校验及追溯。
WINDOWS_INSTALL.md 提供 Windows 重新签名和侧载步骤。
未签名 IPA 必须使用自己的 Apple ID 重新签名后才能安装。
云端测试排除 3 项个人数据测试；定位集成测试可能因权限跳过，具体结果见构建日志。真机安装、锁屏记录及耗电需另行验证。

此版本作为 Release 资产保留，不受 Actions artifact 的 30 天保留期影响。
"""
print(json.dumps({"tag": tag, "commit": commit, "assets": [str(p) for p in assets]}, ensure_ascii=False, indent=2))
if args.dry_run:
    print(notes)
    raise SystemExit(0)

metadata["tests"] = "passed"
metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

gh = os.environ.get("GH_EXE", "gh")
# Each run/attempt has its own tag. Never replace an existing historical release.
existing = subprocess.run([gh, "release", "view", tag, "--repo", args.repo],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if existing.returncode == 0:
    raise SystemExit(f"Release {tag} already exists; refusing to overwrite history.")
with tempfile.TemporaryDirectory(prefix="fogwalk-release-") as temporary:
    notes_path = Path(temporary) / "notes.md"
    notes_path.write_text(notes, encoding="utf-8")
    subprocess.run([gh, "release", "create", tag, *map(str, assets),
                    "--repo", args.repo, "--target", commit, "--title", title,
                    "--notes-file", str(notes_path), "--draft"], check=True)
    # Publish only after every asset uploaded successfully.
    subprocess.run([gh, "release", "edit", tag, "--repo", args.repo,
                    "--draft=false", "--latest"], check=True)
url = subprocess.check_output([gh, "release", "view", tag, "--repo", args.repo,
                               "--json", "url", "--jq", ".url"], text=True).strip()
print(url)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
        summary.write(f"\n### Persistent release\n[{tag}]({url})\n")
