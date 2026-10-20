#!/usr/bin/env python3
"""Update reviewed Mono metadata from immutable Wine release sources."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
METADATA = ROOT / "packages/wine-modules/wine-base-env/wine-mono.json"
VERSION = re.compile(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?")


def read_url(url, *, api=False):
    headers = {"User-Agent": "nix-overlayfs-mono-updater"}
    if api and os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    with urllib.request.urlopen(
        urllib.request.Request(url, headers=headers), timeout=60
    ) as response:
        return response.read()


def discover_versions():
    tags = subprocess.check_output(
        ["git", "ls-remote", "--tags", "--refs", "https://github.com/wine-mirror/wine.git"],
        text=True,
        timeout=120,
    )
    versions = []
    for line in tags.splitlines():
        tag = line.split("refs/tags/wine-")[-1]
        if VERSION.fullmatch(tag):
            versions.append(tag)
    if not versions:
        raise ValueError("no numbered Wine releases found")
    key = lambda version: tuple(map(int, version.split(".")))
    # Track the newest numbered release and the newest stable (X.0[.Y]) release.
    stable = [v for v in versions if v.split(".")[1] == "0"]
    if not stable:
        raise ValueError("no stable Wine release found")
    return sorted({max(versions, key=key), max(stable, key=key)}, key=key)


def parse_addons(source):
    version = re.search(r'^#define\s+MONO_VERSION\s+"([0-9.]+)"', source, re.M)
    checksum = re.search(
        r'#define\s+MONO_ARCH\s+"x86"\s*\n\s*#define\s+MONO_SHA\s+"([0-9a-f]{64})"',
        source,
    )
    if not version or not VERSION.fullmatch(version[1]) or not checksum:
        raise ValueError("unsupported Wine Mono metadata format; manual review required")
    return version[1], checksum[1]


def release_metadata(version):
    if not VERSION.fullmatch(version):
        raise ValueError(f"not a numbered Wine release: {version!r}")
    commit = json.loads(read_url(
        f"https://api.github.com/repos/wine-mirror/wine/commits/wine-{version}", api=True
    ))["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("invalid Wine commit identifier")
    source_url = f"https://raw.githubusercontent.com/wine-mirror/wine/{commit}/dlls/appwiz.cpl/addons.c"
    mono, checksum = parse_addons(read_url(source_url).decode())
    url = f"https://github.com/wine-mono/wine-mono/releases/download/wine-mono-{mono}/wine-mono-{mono}-x86.msi"
    return mono, checksum, url, source_url


def verify_download(url, expected):
    digest = hashlib.sha256()
    # Stream the MSI without executing it or retaining it in the worktree.
    with urllib.request.urlopen(url, timeout=60) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError(f"Mono MSI checksum differs from Wine source: {url}")
    return "sha256-" + base64.b64encode(digest.digest()).decode()


def apply_release(metadata, wine, mono, url, sri):
    previous = metadata["versions"].get(wine, "missing")
    if previous != "missing" and previous != mono:
        raise ValueError(f"refusing to replace existing mapping for Wine {wine}")
    download = {"url": url, "hash": sri}
    if mono in metadata["downloads"] and metadata["downloads"][mono] != download:
        raise ValueError(f"refusing to replace existing source for Mono {mono}")
    metadata["versions"][wine] = mono
    metadata["downloads"][mono] = download


def render(metadata):
    return json.dumps(metadata, indent=2, sort_keys=True) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wine-version", action="append", help="numbered release; repeatable")
    parser.add_argument("--check", action="store_true", help="verify without writing; exit 1 if an update is needed")
    parser.add_argument("--report", type=Path, help="write a Markdown update report")
    args = parser.parse_args()
    before = METADATA.read_text()
    metadata = json.loads(before)
    report = ["## Wine Mono metadata update", ""]
    versions = args.wine_version or discover_versions()
    for wine in versions:
        mono, checksum, url, source = release_metadata(wine)
        sri = verify_download(url, checksum)
        apply_release(metadata, wine, mono, url, sri)
        report.append(f"- Wine **{wine}** → Mono **{mono}** ([Wine source]({source})); MSI SHA-256 verified.")
    after = render(metadata)
    report += ["", "Only dependency metadata is updated. Installer workarounds are unchanged.",
               "Metadata/selection checks do not establish bootstrap or application compatibility; review new Mono versions before merging."]
    if args.report:
        args.report.write_text("\n".join(report) + "\n")
    print("\n".join(report))
    if args.check:
        return int(after != before)
    # Fetch and validate every source before replacing the catalog.
    temporary = METADATA.with_suffix(".json.tmp")
    temporary.write_text(after)
    temporary.replace(METADATA)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
