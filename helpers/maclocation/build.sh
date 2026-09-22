#!/usr/bin/env bash
# Builds a universal maclocation binary. Needs Xcode Command Line Tools. Output: helpers/maclocation/maclocation
set -euo pipefail
cd "$(dirname "$0")"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" -framework CoreLocation main.swift -o "maclocation-$arch" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
done
lipo -create maclocation-arm64 maclocation-x86_64 -output maclocation
rm -f maclocation-arm64 maclocation-x86_64
codesign --force --sign - maclocation
echo "built $(pwd)/maclocation"
