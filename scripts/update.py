#!/usr/bin/env python3
"""Move sources.json to a newer upstream Scion release.

Picks the newest upstream tag on the configured channel (never an older one),
waits until upstream has published release binaries for it, then rewrites
sources.json with the tag's commit and every hash derived from it:

  hash         NAR hash of the source tree (fetchFromGitHub)
  npmDepsHash  web client dependencies, recomputed by building with a fake hash
  vendorHash   Go module dependencies, recomputed the same way
  binaries     SHA-256 of each platform's upstream release tarball
  imageTag     tag the harness images are published under

image-manifest.json is not touched: its digests only exist after the images
workflow has built and pushed images for the new rev (see update.yml).

Usage:
  scripts/update.py                  # follow sources.json's channel
  scripts/update.py --check          # report what would change, write nothing
  scripts/update.py --version v0.3.0-preview.4
  scripts/update.py --channel stable

Needs git and nix (with flakes) on PATH. In GitHub Actions, results are also
written to $GITHUB_OUTPUT (changed, version, rev, image_tag, previous).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

REPO = "GoogleCloudPlatform/scion"
REPO_URL = f"https://github.com/{REPO}"
ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "sources.json"
FAKE_HASH = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
ASSETS = {
    "x86_64-linux": "scion-linux-amd64",
    "aarch64-linux": "scion-linux-arm64",
    "x86_64-darwin": "scion-darwin-amd64",
    "aarch64-darwin": "scion-darwin-arm64",
}
CHANNELS = ("stable", "preview")
_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-(preview|rc)\.(\d+))?$")
_STAGE = {"preview": 0, "rc": 1, None: 2}


class Version(NamedTuple):
    """Sortable form of an upstream release tag (vX.Y.Z[-preview.N|-rc.N])."""

    major: int
    minor: int
    patch: int
    stage: int  # preview < rc < final
    number: int

    @property
    def stable(self) -> bool:
        return self.stage == _STAGE[None]


def parse_version(tag: str) -> Version | None:
    """Parse a release tag; nightly and other tags return None."""
    match = _TAG.match(tag)
    if not match:
        return None
    major, minor, patch, stage, number = match.groups()
    return Version(int(major), int(minor), int(patch), _STAGE[stage], int(number or 0))


def pick_release(tags: dict[str, str], channel: str, current: str) -> str | None:
    """Newest tag on the channel that is newer than current, if any.

    stable follows only final releases; preview follows previews, release
    candidates and finals. Unparseable tags (nightlies) are ignored.
    """
    if channel not in CHANNELS:
        raise ValueError(f"unknown channel {channel!r}; use one of {', '.join(CHANNELS)}")
    current_version = parse_version(current)
    candidates = []
    for tag in tags:
        version = parse_version(tag)
        if version is None or (channel == "stable" and not version.stable):
            continue
        if current_version is not None and version <= current_version:
            continue
        candidates.append((version, tag))
    return max(candidates)[1] if candidates else None


def parse_ls_remote(output: str) -> dict[str, str]:
    """Map tag name to commit from `git ls-remote --tags`, peeling annotated tags."""
    tags: dict[str, str] = {}
    peeled: dict[str, str] = {}
    for line in output.splitlines():
        if not line.strip():
            continue
        sha, ref = line.split("\t", 1)
        if not ref.startswith("refs/tags/"):
            continue
        name = ref[len("refs/tags/"):]
        if name.endswith("^{}"):
            peeled[name[:-3]] = sha
        else:
            tags[name] = sha
    tags.update(peeled)
    return tags


def extract_hash(output: str) -> str | None:
    """The hash Nix reports for a fixed-output derivation built with the wrong one."""
    match = re.search(r"got:\s+(sha256-[A-Za-z0-9+/]+=*)", output)
    return match.group(1) if match else None


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=check)


def remote_tags() -> dict[str, str]:
    return parse_ls_remote(run("git", "ls-remote", "--tags", REPO_URL).stdout)


def prefetch_source(rev: str) -> str:
    result = run("nix", "flake", "prefetch", "--json", f"github:{REPO}/{rev}")
    return json.loads(result.stdout)["hash"]


def prefetch_binary(version: str, asset: str) -> str | None:
    url = f"{REPO_URL}/releases/download/{version}/{asset}.tar.gz"
    result = run("nix", "store", "prefetch-file", "--json", url, check=False)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)["hash"]


def current_system() -> str:
    return run("nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem").stdout


def recompute_hash(system: str, attr: str) -> str:
    """Build a fixed-output derivation whose hash is fake and read the real one."""
    installable = f".#packages.{system}.google-scion-source.{attr}"
    result = run("nix", "build", "--no-link", installable, check=False)
    got = extract_hash(result.stderr)
    if got is None:
        sys.stderr.write(result.stderr)
        raise SystemExit(f"could not determine the hash of {installable}")
    return got


def write_sources(sources: dict) -> None:
    SOURCES.write_text(json.dumps(sources, indent=2) + "\n")


def github_output(**values: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--channel", choices=CHANNELS, help="release channel to follow (default: sources.json)")
    parser.add_argument("--version", help="move to this exact upstream tag instead of the newest one")
    parser.add_argument("--check", action="store_true", help="only report the target release")
    args = parser.parse_args()

    sources = json.loads(SOURCES.read_text())
    channel = args.channel or sources.get("channel", "preview")
    previous = sources["version"]
    github_output(changed="false", previous=previous)

    tags = remote_tags()
    if args.version:
        if args.version not in tags:
            raise SystemExit(f"{args.version} is not an upstream tag")
        target = args.version
    else:
        target = pick_release(tags, channel, previous)
        if target is None:
            print(f"Up to date: {previous} is the newest {channel} release.")
            return 0
    rev = tags[target]
    if target == previous and rev == sources["rev"]:
        print(f"Already at {target}.")
        return 0
    print(f"{previous} -> {target} ({rev})")

    binaries = {}
    for system, asset in ASSETS.items():
        binary = prefetch_binary(target, asset)
        if binary is None:
            message = f"Upstream has not published {asset}.tar.gz for {target} yet."
            if args.version:
                raise SystemExit(message)
            print(message + " Try again later.")
            return 0
        binaries[system] = binary

    if args.check:
        github_output(changed="true", version=target, rev=rev, image_tag=f"scion-{target}")
        return 0

    sources.update(
        channel=channel,
        version=target,
        rev=rev,
        hash=prefetch_source(rev),
        npmDepsHash=FAKE_HASH,
        vendorHash=FAKE_HASH,
        imageTag=f"scion-{target}",
        binaries=binaries,
    )
    write_sources(sources)
    try:
        system = current_system()
        sources["npmDepsHash"] = recompute_hash(system, "web.npmDeps")
        write_sources(sources)
        sources["vendorHash"] = recompute_hash(system, "goModules")
        write_sources(sources)
    except BaseException:
        print("Hash computation failed; sources.json holds placeholder hashes.", file=sys.stderr)
        raise

    print(json.dumps(sources, indent=2))
    github_output(changed="true", version=target, rev=rev, image_tag=sources["imageTag"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
