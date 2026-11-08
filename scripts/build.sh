#!/bin/bash
# 编译二进制 → 组装 CalendarHelper.app → ad-hoc 签名。
# 必须打包成 .app 用 open 启动，日历权限才会归属到它自己；直接跑裸二进制时，
# TCC 会把请求算到父进程（DeepSeek Harness）头上，而它没有日历的授权说明，会被静默拒绝。
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/CalendarHelper.app"
mkdir -p "$DIR/bin"

# 模块缓存必须显式指到可写目录（默认缓存目录会被沙箱挡住），放临时目录并自动清理，
# 否则会在 skill 目录里堆上百兆缓存。
CACHE="$(mktemp -d -t dsh-swift-cache)"
trap 'rm -rf "$CACHE"' EXIT

swiftc -O -swift-version 5 \
  -module-cache-path "$CACHE" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist" \
  "$DIR/src/main.swift" \
  -o "$DIR/bin/calendar"

codesign --force --sign - "$DIR/bin/calendar" >/dev/null 2>&1 || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$DIR/bin/calendar" "$APP/Contents/MacOS/calendar"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "built: $DIR/bin/calendar"
echo "app:   $APP"
