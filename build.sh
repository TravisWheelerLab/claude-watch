#!/bin/sh
# Build ClaudeWatch.app into ./build/
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="ClaudeWatch.app"
BIN="claude-watch"
OUT="$DIR/build"

rm -rf "$OUT/$APP"
mkdir -p "$OUT/$APP/Contents/MacOS"

swiftc "$DIR/ClaudeWatch.swift" -O -o "$OUT/$APP/Contents/MacOS/$BIN" -framework Cocoa
cp "$DIR/Info.plist" "$OUT/$APP/Contents/Info.plist"

echo "Built $OUT/$APP"
