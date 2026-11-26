#!/usr/bin/env bash
# build-node.sh: repackage one official Node.js release as a homeCore
# interpreter.
#
#   build-node.sh --version 24.22.3 [--arch x86_64] [--out dist]
#
# Downloads node-v<version>-linux-<x64|arm64>.tar.xz from nodejs.org, checks it
# against the release's SHASUMS256.txt, removes what a plugin never uses (npm,
# corepack, headers, docs), proves what is left still works, and writes
#
#   <out>/node-<version>-linux-<arch>.tar.zst   one top directory, node/
#   <out>/node-<version>-linux-<arch>.meta      version, abi, arch, upstream, sha256, size
#
# The runtime host unpacks the archive and runs node/bin/node. Nothing in it
# depends on where it is unpacked. A plugin carries its node_modules, so the
# runtime never runs npm.
set -euo pipefail
VERSION=""
ARCH="x86_64"
OUT="dist"
die() { echo "build-node: $*" >&2; exit 1; }
note() { echo "build-node: $*"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --version)  VERSION="${2:?}"; shift 2 ;;
        --arch)     ARCH="${2:?}"; shift 2 ;;
        --out)      OUT="${2:?}"; shift 2 ;;
        -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
        *) die "unknown argument $1" ;;
    esac
done
[ -n "$VERSION" ] || die "--version is required, e.g. 24.22.3"
[[ "$VERSION" =~ ^([0-9]+)\.[0-9]+\.[0-9]+$ ]] || die "--version must be a release like 24.22.3, not $VERSION"
MAJOR="${BASH_REMATCH[1]}"
ABI="node${MAJOR}"
case "$ARCH" in
    x86_64)  UPARCH=x64 ;;
    aarch64) UPARCH=arm64 ;;
    *) die "--arch must be x86_64 or aarch64" ;;
esac
for tool in curl tar xz zstd sha256sum; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

NAME="node-v${VERSION}-linux-${UPARCH}.tar.xz"
BASE="https://nodejs.org/dist/v${VERSION}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

note "downloading $NAME"
curl -fsSL --retry 3 -o "$WORK/$NAME" "$BASE/$NAME" || die "could not download $BASE/$NAME"
curl -fsSL --retry 3 -o "$WORK/SHASUMS256.txt" "$BASE/SHASUMS256.txt" || die "could not download the release's SHASUMS256.txt"

want="$(awk -v n="$NAME" '$2 == n {print $1}' "$WORK/SHASUMS256.txt")"
[ -n "$want" ] || die "$NAME is not listed in the release's SHASUMS256.txt"
have="$(sha256sum "$WORK/$NAME" | cut -d' ' -f1)"
[ "$want" = "$have" ] || die "$NAME does not match SHASUMS256.txt: expected $want, got $have"
note "upstream checksum matches"

mkdir -p "$WORK/root"
tar -xJf "$WORK/$NAME" -C "$WORK/root"
mv "$WORK/root/node-v${VERSION}-linux-${UPARCH}" "$WORK/root/node"
N="$WORK/root/node"
[ -x "$N/bin/node" ] || die "the archive has no bin/node"

before="$(du -sk "$N" | cut -f1)"
# A plugin is installed with its node_modules already in it, so the runtime
# never runs npm, npx or corepack. Headers are for compiling native addons,
# which happens when a plugin is built, not where it runs. The license stays.
rm -rf "$N/lib/node_modules" "$N/bin/npm" "$N/bin/npx" "$N/bin/corepack" \
    "$N/include" "$N/share"
after="$(du -sk "$N" | cut -f1)"
note "pruned $(( (before - after) / 1024 )) MB, $(( after / 1024 )) MB left"

# Prove it runs, is the version it claims, and has what plugins rely on: TLS,
# compression, UDP and multicast (Matter, mDNS), workers, and full ICU.
note "checking the result"
"$N/bin/node" - "$VERSION" <<'JS'
const want = process.argv[2];
const have = process.versions.node;
if (have !== want) { console.error(`node is ${have}, expected ${want}`); process.exit(1); }
const mods = ["crypto", "tls", "https", "zlib", "dgram", "net", "dns", "os", "worker_threads",
  "child_process", "fs/promises", "stream/web", "events", "util", "readline", "sqlite"];
const missing = [];
for (const m of mods) {
  try { require(`node:${m}`); } catch (e) { missing.push(`${m} (${e.message})`); }
}
if (missing.length) { console.error("missing: " + missing.join(", ")); process.exit(1); }
require("node:crypto").createHash("sha256").update("x").digest("hex");
require("node:tls").createSecureContext();
if (new Intl.DateTimeFormat("de-DE", { month: "long" }).format(new Date(2000, 0, 1)) !== "Januar") {
  console.error("Intl has no full ICU"); process.exit(1);
}
const s = require("node:dgram").createSocket({ type: "udp6", reuseAddr: true });
s.close();
console.log("ok:", have, mods.length, "modules");
JS

mkdir -p "$OUT"
FILE="node-${VERSION}-linux-${ARCH}.tar.zst"
# Sorted, numeric owners and a fixed mtime, so the same input packs to the
# same bytes.
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
    -C "$WORK/root" -cf - node | zstd -19 -T0 -q -o "$OUT/$FILE"
sha256="$(sha256sum "$OUT/$FILE" | cut -d' ' -f1)"
size="$(stat -c %s "$OUT/$FILE")"
{
    echo "version=$VERSION"
    echo "abi=$ABI"
    echo "arch=$ARCH"
    echo "upstream=v$VERSION"
    echo "file=$FILE"
    echo "sha256=$sha256"
    echo "size=$size"
} > "$OUT/node-${VERSION}-linux-${ARCH}.meta"
note "wrote $OUT/$FILE ($(( size / 1024 / 1024 )) MB, sha256 $sha256)"
