#!/usr/bin/env python3
"""Move versions.toml to the newest patches upstream offers.

    python3 check-upstream.py [--arch x86_64] [--write]

Python: reads python-build-standalone's latest release, and for each minor in
versions.toml finds the newest final patch built there as install_only_stripped
for linux. Node.js: reads nodejs.org's release list, and for each major finds
its newest release. Prints what would change; with --write it edits
versions.toml in place, keeping its comments, and prints the tags to push after
the change is merged.

Uses GITHUB_TOKEN when set, for the API's higher rate limit.
"""
import argparse
import json
import os
import re
import sys
import tomllib
import urllib.request

API = "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest"
NODE_INDEX = "https://nodejs.org/dist/index.json"
HERE = os.path.dirname(os.path.abspath(__file__))
VERSIONS = os.path.join(HERE, "versions.toml")


def latest_release():
    req = urllib.request.Request(API, headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def as_tuple(v):
    return tuple(int(x) for x in v.split("."))


def offered(release, arch):
    """Final versions upstream built for linux on `arch`, by minor."""
    pattern = re.compile(
        rf"^cpython-(3\.\d+\.\d+)\+(\d+)-{re.escape(arch)}-unknown-linux-gnu-install_only_stripped\.tar\.gz$"
    )
    by_minor = {}
    for asset in release.get("assets", []):
        m = pattern.match(asset["name"])
        if not m:
            continue
        version = m.group(1)
        minor = ".".join(version.split(".")[:2])
        if minor not in by_minor or as_tuple(version) > as_tuple(by_minor[minor]):
            by_minor[minor] = version
    return by_minor


def node_newest():
    """The newest release of each Node.js major, from nodejs.org."""
    with urllib.request.urlopen(NODE_INDEX, timeout=30) as resp:
        releases = json.load(resp)
    by_major = {}
    for rel in releases:
        version = rel["version"].lstrip("v")
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            continue
        major = version.split(".")[0]
        if major not in by_major or as_tuple(version) > as_tuple(by_major[major]):
            by_major[major] = version
    return by_major


def check_node(current, write_text):
    """Node.js majors with a newer release: [(major, old, new)], and the text."""
    newest = node_newest()
    changes = []
    for major, entry in current.items():
        new = newest.get(major)
        if new and as_tuple(new) > as_tuple(entry["version"]):
            changes.append((major, entry["version"], new))
            print(f"node {major}: {entry['version']} -> {new}")
        else:
            print(f"node {major}: {entry['version']} is current")
    for major, old, new in changes:
        section = re.compile(
            rf'(\[node\."{re.escape(major)}"\][^\[]*?version\s*=\s*)"{re.escape(old)}"'
        )
        write_text, n = section.subn(rf'\g<1>"{new}"', write_text)
        if n != 1:
            sys.exit(f"could not find the node {major} entry to update in versions.toml")
    return changes, write_text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", default="x86_64")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    with open(VERSIONS, "rb") as f:
        listed = tomllib.load(f)
    current = listed["python"]
    release = latest_release()
    upstream = release["tag_name"]
    available = offered(release, args.arch)

    changes = []
    for minor, entry in current.items():
        newest = available.get(minor)
        if newest is None:
            print(f"{minor}: upstream {upstream} has no {args.arch} build; staying on {entry['version']}")
            continue
        if as_tuple(newest) > as_tuple(entry["version"]):
            changes.append((minor, entry["version"], newest))
            print(f"{minor}: {entry['version']} -> {newest} (upstream {upstream})")
        else:
            print(f"{minor}: {entry['version']} is current")

    newer_minors = sorted(set(available) - set(current), key=as_tuple)
    for minor in newer_minors:
        if as_tuple(minor) > max(as_tuple(m) for m in current):
            print(f"{minor}: upstream builds it ({available[minor]}); add it here once the "
                  "compiled libraries plugins use publish wheels for it")

    text = open(VERSIONS).read()
    node_changes, text_after_node = check_node(listed.get("node", {}), text)
    if not (changes or node_changes) or not args.write:
        return

    text = text_after_node
    for minor, old, new in changes:
        section = re.compile(
            rf'(\[python\."{re.escape(minor)}"\][^\[]*?version\s*=\s*)"{re.escape(old)}"'
            rf'(\s*\nupstream\s*=\s*)"\d+"'
        )
        text, n = section.subn(rf'\g<1>"{new}"\g<2>"{upstream}"', text)
        if n != 1:
            sys.exit(f"could not find the {minor} entry to update in versions.toml")
    with open(VERSIONS, "w") as f:
        f.write(text)
    tags = [f"python-{new}" for _, _, new in changes] + [f"node-{new}" for _, _, new in node_changes]
    print("tags: " + " ".join(tags))


if __name__ == "__main__":
    main()
