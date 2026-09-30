#!/usr/bin/env bash
# Builds the emulator's window helper (emuwindow.m) for Apple Silicon, the only Mac the
# emulator runtime runs on. Needs Xcode Command Line Tools. Output, committed:
# helpers/emuwindow/libtakwerx-window.dylib
set -euo pipefail
cd "$(dirname "$0")"
clang -arch arm64 -mmacosx-version-min=13.0 -dynamiclib -fobjc-arc -O2 -Wall \
  -framework AppKit emuwindow.m -o libtakwerx-window.dylib
codesign --force --sign - libtakwerx-window.dylib
echo "built $(pwd)/libtakwerx-window.dylib"
