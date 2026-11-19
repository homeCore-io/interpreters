#!/usr/bin/env bash
# build-python.sh: repackage one python-build-standalone release as a homeCore
# interpreter.
#
#   build-python.sh --version 3.13.18 --upstream 20261110 [--arch x86_64] [--out dist]
#
# Downloads cpython-<version>+<upstream>-<arch>-unknown-linux-gnu-install_only_stripped,
# checks it against the release's SHA256SUMS, removes what a plugin never uses,
# proves what is left still works, and writes
#
#   <out>/python-<version>-linux-<arch>.tar.zst   one top directory, python/
#   <out>/python-<version>-linux-<arch>.meta      version, abi, arch, upstream, sha256, size
#
# The runtime host unpacks the archive and runs python/bin/python3. Nothing in
# it depends on where it is unpacked.
set -euo pipefail

VERSION=""
UPSTREAM=""
ARCH="x86_64"
OUT="dist"

die() { echo "build-python: $*" >&2; exit 1; }
note() { echo "build-python: $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version)  VERSION="${2:?}"; shift 2 ;;
        --upstream) UPSTREAM="${2:?}"; shift 2 ;;
        --arch)     ARCH="${2:?}"; shift 2 ;;
        --out)      OUT="${2:?}"; shift 2 ;;
        -h|--help)  sed -n '2,15p' "$0"; exit 0 ;;
        *) die "unknown argument $1" ;;
    esac
done

[ -n "$VERSION" ] || die "--version is required, e.g. 3.13.18"
[ -n "$UPSTREAM" ] || die "--upstream is required: the python-build-standalone release, e.g. 20261110"
[[ "$VERSION" =~ ^3\.([0-9]+)\.([0-9]+)$ ]] || die "--version must be a final release like 3.13.18, not $VERSION"
MINOR="3.${BASH_REMATCH[1]}"
ABI="cp3${BASH_REMATCH[1]}"
case "$ARCH" in
    x86_64|aarch64) ;;
    *) die "--arch must be x86_64 or aarch64" ;;
esac
for tool in curl tar zstd sha256sum; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

NAME="cpython-${VERSION}+${UPSTREAM}-${ARCH}-unknown-linux-gnu-install_only_stripped.tar.gz"
BASE="https://github.com/astral-sh/python-build-standalone/releases/download/${UPSTREAM}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

note "downloading $NAME"
curl -fsSL --retry 3 -o "$WORK/$NAME" "$BASE/$NAME" || die "could not download $BASE/$NAME"
curl -fsSL --retry 3 -o "$WORK/SHA256SUMS" "$BASE/SHA256SUMS" || die "could not download the release's SHA256SUMS"

want="$(awk -v n="$NAME" '$2 == n || $2 == "*"n {print $1}' "$WORK/SHA256SUMS")"
[ -n "$want" ] || die "$NAME is not listed in the release's SHA256SUMS"
have="$(sha256sum "$WORK/$NAME" | cut -d' ' -f1)"
[ "$want" = "$have" ] || die "$NAME does not match SHA256SUMS: expected $want, got $have"
note "upstream checksum matches"

mkdir -p "$WORK/root"
tar -xzf "$WORK/$NAME" -C "$WORK/root"
PY="$WORK/root/python"
[ -x "$PY/bin/python3" ] || die "the archive has no python/bin/python3"
LIB="$PY/lib/python${MINOR}"
[ -d "$LIB" ] || die "the archive has no lib/python${MINOR}"

before="$(du -sk "$PY" | cut -f1)"

# What a plugin never uses. Each entry is optional, because a module that left
# the standard library (lib2to3 in 3.13) or moved should not fail the build.
# The license files stay.
prune=(
    "$LIB/test"
    "$LIB/idlelib"
    "$LIB/tkinter"
    "$LIB/turtle.py"
    "$LIB/turtledemo"
    "$LIB/ensurepip"
    "$LIB/lib2to3"
    "$LIB/pydoc_data"
    "$PY/include"
    "$PY/share"
    "$PY/lib/pkgconfig"
    "$PY/bin/idle3"
    "$PY/bin/idle${MINOR}"
    "$PY/bin/pydoc3"
    "$PY/bin/pydoc${MINOR}"
    "$PY/bin/pip3"
    "$PY/bin/pip"
    "$PY/bin/pip${MINOR}"
)
for p in "${prune[@]}"; do
    rm -rf "$p"
done
# pip came with ensurepip's install; uv makes and fills the environments.
rm -rf "$LIB"/site-packages/pip "$LIB"/site-packages/pip-*.dist-info
# Tk and Tcl: the C extension and the libraries it loads.
rm -rf "$LIB"/lib-dynload/_tkinter*.so "$PY"/lib/libtcl* "$PY"/lib/libtk* \
    "$PY"/lib/tcl* "$PY"/lib/tk* "$PY"/lib/itcl* "$PY"/lib/thread[0-9]*
# The shared and static libpython, and the build config. bin/python3 is linked
# statically and never loads the shared one, and manylinux forbids wheels from
# linking it, so they only matter for embedding Python or compiling against it.
rm -f "$PY"/lib/libpython*.so* "$LIB"/config-"${MINOR}"*/libpython*.a \
    "$PY"/bin/python*-config
# Tests that ship inside packages other than test/.
find "$LIB" -depth -type d \( -name tests -o -name idle_test \) -path "$LIB/*" -exec rm -rf {} +

after="$(du -sk "$PY" | cut -f1)"
note "pruned $(( (before - after) / 1024 )) MB, $(( after / 1024 )) MB left"

# Prove the prune went no further than it should: everything a plugin and uv
# rely on still imports, and the interpreter is the version it claims.
note "checking the result"
"$PY/bin/python3" - "$VERSION" <<'PY'
import importlib, sys
want = sys.argv[1]
have = "%d.%d.%d" % sys.version_info[:3]
if have != want:
    sys.exit(f"interpreter is {have}, expected {want}")
mods = ["ssl", "sqlite3", "ctypes", "zlib", "lzma", "bz2", "venv", "asyncio",
        "json", "hashlib", "uuid", "decimal", "zoneinfo", "concurrent.futures",
        "multiprocessing", "socket", "select", "email", "http.client",
        "urllib.request", "xml.etree.ElementTree", "unittest", "logging.handlers",
        "tomllib", "readline", "curses"]
missing = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception as e:
        missing.append(f"{m} ({e})")
if missing:
    sys.exit("missing after pruning: " + ", ".join(missing))
import ssl
ssl.create_default_context()
print("ok:", have, len(mods), "modules")
PY
# A venv made from it works without ensurepip.
"$PY/bin/python3" -m venv --without-pip "$WORK/venv-check"
"$WORK/venv-check/bin/python" -c "import sys; assert sys.prefix != sys.base_prefix"

mkdir -p "$OUT"
FILE="python-${VERSION}-linux-${ARCH}.tar.zst"
# Sorted, numeric owners and a fixed mtime, so the same input packs to the
# same bytes.
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
    -C "$WORK/root" -cf - python | zstd -19 -T0 -q -o "$OUT/$FILE"
sha256="$(sha256sum "$OUT/$FILE" | cut -d' ' -f1)"
size="$(stat -c %s "$OUT/$FILE")"
{
    echo "version=$VERSION"
    echo "abi=$ABI"
    echo "arch=$ARCH"
    echo "upstream=$UPSTREAM"
    echo "file=$FILE"
    echo "sha256=$sha256"
    echo "size=$size"
} > "$OUT/python-${VERSION}-linux-${ARCH}.meta"
note "wrote $OUT/$FILE ($(( size / 1024 / 1024 )) MB, sha256 $sha256)"
