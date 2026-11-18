#!/bin/zsh
# Rebuild the vendored, patched libmtp from a libmtp-1.1.23 source tarball.
# Usage: scripts/build-libmtp.sh /path/to/libmtp-1.1.23.tar.gz
# (e.g. from `brew fetch --build-from-source libmtp`). Needs pkg-config.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$ROOT/Vendor/libmtp"
WORK="$(mktemp -d)"
tar -xzf "$1" -C "$WORK"
cd "$WORK"/libmtp-1.1.23
patch -p1 < "$V/patches/libmtp-1.1.23-mtt.patch"
export MACOSX_DEPLOYMENT_TARGET=27.0
./configure --prefix="$WORK/install" --disable-mtpz --disable-static --enable-shared \
  LIBUSB_CFLAGS="-I$V/include/libusb-1.0" LIBUSB_LIBS="-L$V/lib -lusb-1.0" CFLAGS="-O2 -arch arm64"
make -C src -j8
make -C src install
cp "$WORK/install/lib/libmtp.9.dylib" "$V/lib/libmtp.9.dylib"
install_name_tool -id @rpath/libmtp.9.dylib "$V/lib/libmtp.9.dylib"
codesign --force --sign - "$V/lib/libmtp.9.dylib"
echo "Rebuilt $V/lib/libmtp.9.dylib"
